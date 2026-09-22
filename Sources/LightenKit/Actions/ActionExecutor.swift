import Darwin
import Foundation

public protocol TrashMoving: Sendable {
  /// Returns the actual URL path chosen by the OS, including any collision rename.
  func moveToTrash(path: String) async throws -> String
}

public enum ActionOutcome: String, Codable, Sendable {
  case applied, skipped, failed, uncertain, notAttempted
}

public struct ItemActionResult: Codable, Sendable {
  public let itemID: UUID
  public let outcome: ActionOutcome
  public let detail: String?
  public let deletedCount: Int
  public let deletedLogicalBytes: Int64

  public init(
    itemID: UUID, outcome: ActionOutcome, detail: String? = nil,
    deletedCount: Int = 0, deletedLogicalBytes: Int64 = 0
  ) {
    self.itemID = itemID
    self.outcome = outcome
    self.detail = detail
    self.deletedCount = deletedCount
    self.deletedLogicalBytes = deletedLogicalBytes
  }
}

public struct ActionResult: Codable, Sendable {
  public let planID: UUID
  public let items: [ItemActionResult]
}

public enum ExecutionFailure: Error, Sendable {
  case catalogDeleteDenied, invalidPlan, corruptHistory, alreadyRunning, planAlreadyUsed
}

public struct IrreversibleConfirmation: Sendable, Equatable {
  public let planID: UUID
  public let method: ActionKind

  public init(planID: UUID, method: ActionKind) {
    self.planID = planID
    self.method = method
  }
}

public actor ActionExecutor {
  private let journal: any ActionJournal
  private let trash: any TrashMoving
  private let guardService: ActionGuard
  private let beforeMutation: (@Sendable (PlanItem) async throws -> Void)?
  private let activity: any ProcessActivitySource
  private let catalog: CleanCatalog?
  private let related: RelatedDataService
  private let runningApplications: any RunningApplicationSource
  private var busy = false

  public init(
    journal: any ActionJournal, trash: any TrashMoving,
    guardService: ActionGuard = ActionGuard(),
    beforeMutation: (@Sendable (PlanItem) async throws -> Void)? = nil,
    activity: any ProcessActivitySource = UnknownProcessActivitySource(),
    catalog: CleanCatalog? = try? CleanCatalog(),
    related: RelatedDataService = RelatedDataService(),
    runningApplications: any RunningApplicationSource = UnknownRunningApplicationSource()
  ) {
    self.journal = journal
    self.trash = trash
    self.guardService = guardService
    self.beforeMutation = beforeMutation
    self.activity = activity
    self.catalog = catalog
    self.related = related
    self.runningApplications = runningApplications
  }

  public func execute(
    _ plan: ActionPlan, confirmation: IrreversibleConfirmation? = nil
  ) async throws -> ActionResult {
    guard !busy else { throw ExecutionFailure.alreadyRunning }
    busy = true
    defer { busy = false }
    return try await journal.withMutationLease {
      try await self.executeLeased(plan, confirmation: confirmation)
    }
  }

  private func executeLeased(
    _ plan: ActionPlan, confirmation: IrreversibleConfirmation?
  ) async throws -> ActionResult {
    guard plan.schema == 1, !plan.items.isEmpty,
      Set(plan.items.map(\.id)).count == plan.items.count,
      plan.items.allSatisfy({ !$0.inventory.isEmpty }),
      !plan.items.enumerated().contains(where: { index, item in
        plan.items.dropFirst(index + 1).contains { other in
          other.sourcePath == item.sourcePath
            || other.sourcePath.hasPrefix(item.sourcePath + "/")
            || item.sourcePath.hasPrefix(other.sourcePath + "/")
        }
      })
    else { throw ExecutionFailure.invalidPlan }
    if plan.kind == .catalogDelete {
      guard confirmation == IrreversibleConfirmation(planID: plan.id, method: .catalogDelete),
        let catalog
      else { throw ExecutionFailure.catalogDeleteDenied }
      for item in plan.items { _ = try catalog.validate(item, in: plan) }
    }
    for item in plan.items where item.catalogProof != nil {
      guard let catalog else { throw CatalogFailure.unavailable }
      _ = try catalog.validate(item, in: plan)
    }
    for item in plan.items where item.relatedProof != nil {
      try related.validate(item, plan: plan)
    }
    let existing = try await journal.read()
    guard existing.issues.isEmpty else { throw ExecutionFailure.corruptHistory }
    guard
      !existing.records.contains(where: {
        $0.kind == .intent && $0.planID == plan.id
      })
    else { throw ExecutionFailure.planAlreadyUsed }
    // The complete immutable inventory is durable before any OS mutation.
    try await journal.append(JournalRecord(kind: .intent, planID: plan.id, plan: plan))

    var results: [ItemActionResult] = []
    for item in plan.items {
      do {
        if item.catalogProof != nil {
          guard let row = try catalog?.validate(item, in: plan),
            await activity.activity(for: row.id).state == .clearObservedCurrentUID
          else { throw ExecutionFailure.catalogDeleteDenied }
        }
        if let proof = item.relatedProof {
          try related.validate(item, plan: plan)
          guard await runningApplications.isRunning(bundleID: proof.bundleID) == false
          else { throw RelatedFailure.runningOrUnknown }
        }
        try guardService.validate(item)
        try await beforeMutation?(item)
        // The hook models the final window. Never move on its prior validation.
        if item.catalogProof != nil {
          guard let row = try catalog?.validate(item, in: plan),
            await activity.activity(for: row.id).state == .clearObservedCurrentUID
          else { throw ExecutionFailure.catalogDeleteDenied }
        }
        if let proof = item.relatedProof {
          try related.validate(item, plan: plan)
          guard await runningApplications.isRunning(bundleID: proof.bundleID) == false
          else { throw RelatedFailure.runningOrUnknown }
        }
        try guardService.validate(item)
      } catch {
        let detail = String(describing: error)
        do {
          try await journal.append(
            JournalRecord(
              kind: .skipped, planID: plan.id, itemID: item.id, detail: detail
            ))
          results.append(ItemActionResult(itemID: item.id, outcome: .skipped, detail: detail))
          continue
        } catch {
          results.append(ItemActionResult(itemID: item.id, outcome: .uncertain, detail: "journal failure"))
          break
        }
      }
      if plan.kind == .catalogDelete {
        let outcome = await deleteCatalogItem(item, planID: plan.id)
        results.append(outcome)
        if outcome.outcome == .uncertain { break }
        continue
      }
      let returnedPath: String
      do {
        returnedPath = try await trash.moveToTrash(path: item.sourcePath)
      } catch {
        let detail = String(describing: error)
        // A throwing path-based OS call does not prove that the source stayed put.
        guard let original = item.inventory.first?.identity,
          (try? DescriptorFileSystem.identity(at: item.sourcePath)) == original
        else {
          results.append(
            ItemActionResult(
              itemID: item.id, outcome: .uncertain,
              detail: "Trash call failed and source identity is unverified"))
          break
        }
        do {
          try await journal.append(
            JournalRecord(
              kind: .failed, planID: plan.id, itemID: item.id, detail: detail
            ))
          results.append(ItemActionResult(itemID: item.id, outcome: .failed, detail: detail))
        } catch {
          results.append(ItemActionResult(itemID: item.id, outcome: .uncertain, detail: "journal failure"))
          break
        }
        continue
      }
      // The move has happened. Any later error is uncertain, never a failed move.
      do {
        let moved = try KnownPathFileSystem.identity(at: returnedPath)
        guard let original = item.inventory.first?.identity,
          let volumeID = item.volumeID,
          (try? DescriptorFileSystem.volumeID(at: returnedPath)) == volumeID,
          moved.matchesStableTrashIdentity(original)
        else {
          results.append(
            ItemActionResult(
              itemID: item.id, outcome: .uncertain, detail: "moved identity mismatch"
            ))
          break
        }
        do {
          try await journal.append(
            JournalRecord(
              kind: .applied, planID: plan.id, itemID: item.id,
              returnedTrashPath: returnedPath, movedIdentity: moved
            ))
          results.append(ItemActionResult(itemID: item.id, outcome: .applied))
        } catch {
          results.append(ItemActionResult(itemID: item.id, outcome: .uncertain, detail: "applied journal failure"))
          break
        }
      } catch {
        results.append(
          ItemActionResult(
            itemID: item.id, outcome: .uncertain,
            detail: "moved result could not be verified"))
        break
      }
    }
    let completed = Set(results.map(\.itemID))
    for item in plan.items where !completed.contains(item.id) {
      results.append(
        ItemActionResult(
          itemID: item.id, outcome: .notAttempted,
          detail: "stopped after an uncertain result"))
    }
    return ActionResult(planID: plan.id, items: results)
  }

  private func deleteCatalogItem(_ item: PlanItem, planID: UUID) async -> ItemActionResult {
    var count = 0
    var bytes: Int64 = 0
    // Children precede their parent. Each leaf is pinned through its parent FD
    // and checked again immediately before unlinkat; no path-based recursive delete.
    let leaves = item.inventory.sorted {
      let left = $0.path.split(separator: "/").count
      let right = $1.path.split(separator: "/").count
      return left == right ? $0.path > $1.path : left > right
    }
    let byPath = Dictionary(uniqueKeysWithValues: item.inventory.map { ($0.path, $0) })
    var remaining = Set(item.inventory.map(\.path))
    for entry in leaves {
      do {
        guard let expected = entry.identity,
          ProtectionPolicy.rule(for: entry.path, homeDirectory: guardService.homeDirectory) == nil,
          !ScanService.isPackage(entry.path), !ScanService.isInsidePackage(entry.path),
          let row = try catalog?.validate(
            item,
            in: ActionPlan(
              snapshotRunID: item.catalogProof?.snapshotRunID ?? UUID(),
              kind: .catalogDelete, items: [item])),
          await activity.activity(for: row.id).state == .clearObservedCurrentUID
        else { throw CatalogFailure.invalidProof }
        // Re-resolve the original ancestor chain after each journal await.
        // Within the selected subtree, only our already removed descendants
        // may be absent; a newly added child stops the operation as partial.
        for ancestor in item.ancestors {
          guard let observed = try? DescriptorFileSystem.identity(at: ancestor.path),
            Self.stableDeleteDirectory(observed, ancestor.identity),
            ProtectionPolicy.rule(
              for: ancestor.path,
              homeDirectory: guardService.homeDirectory) == nil
          else { throw GuardFailure.changedAncestor }
        }
        for directory in item.inventory
        where directory.identity?.kind == .directory
          && remaining.contains(directory.path)
          && (entry.path == directory.path || entry.path.hasPrefix(directory.path + "/"))
        {
          guard let expectedDirectory = directory.identity,
            let observed = try? DescriptorFileSystem.identity(at: directory.path),
            Self.stableDeleteDirectory(observed, expectedDirectory),
            (try? DescriptorFileSystem.volumeID(at: directory.path)) == item.volumeID
          else { throw GuardFailure.changedInventory }
          let observedNames = try DescriptorFileSystem.children(
            at: directory.path,
            expected: observed)
          let expectedNames = remaining.filter {
            ($0 as NSString).deletingLastPathComponent == directory.path
          }.map { ($0 as NSString).lastPathComponent }.sorted()
          guard observedNames == expectedNames else { throw GuardFailure.changedInventory }
        }
        let (parentFD, name) = try DescriptorFileSystem.openParent(of: entry.path)
        defer { close(parentFD) }
        var pinnedParent = stat()
        guard fstat(parentFD, &pinnedParent) == 0,
          (try? DescriptorFileSystem.volumeID(at: (entry.path as NSString).deletingLastPathComponent)) == item.volumeID,
          let expectedParent =
            (byPath[(entry.path as NSString).deletingLastPathComponent]?.identity
              ?? item.ancestors.last?.identity),
          Self.stableDeleteDirectory(
            DescriptorFileSystem.identity(from: pinnedParent),
            expectedParent)
        else { throw GuardFailure.changedAncestor }
        // A deleted sibling can change its directory's ctime. All other identity
        // fields and the descendant inventory were checked before the first unlink.
        let current = try DescriptorFileSystem.identity(name: name, relativeTo: parentFD)
        guard
          expected.kind == .directory
            ? Self.stableDeleteDirectory(current, expected) : current == expected
        else { throw GuardFailure.changedItem }
        if expected.kind == .directory {
          guard try DescriptorFileSystem.children(at: entry.path, expected: current).isEmpty
          else { throw GuardFailure.changedInventory }
        }
        let flags: Int32 = expected.kind == .directory ? AT_REMOVEDIR : 0
        guard unlinkat(parentFD, name, flags) == 0 else {
          throw FileSystemFailure.systemCall("unlinkat", errno)
        }
        remaining.remove(entry.path)
        count += 1
        let value = max(0, expected.logicalBytes)
        let (next, overflow) = bytes.addingReportingOverflow(value)
        bytes = overflow ? Int64.max : next
        try await journal.append(
          JournalRecord(
            kind: .deleteProgress, planID: planID, itemID: item.id,
            deletedCount: count, deletedLogicalBytes: bytes))
      } catch {
        let detail = String(describing: error)
        do {
          try await journal.append(
            JournalRecord(
              kind: .failed, planID: planID, itemID: item.id, detail: detail,
              deletedCount: count, deletedLogicalBytes: bytes))
          return ItemActionResult(
            itemID: item.id, outcome: .failed, detail: detail,
            deletedCount: count, deletedLogicalBytes: bytes)
        } catch {
          return ItemActionResult(
            itemID: item.id, outcome: .uncertain,
            detail: "journal failure after irreversible deletion",
            deletedCount: count, deletedLogicalBytes: bytes)
        }
      }
    }
    do {
      try await journal.append(
        JournalRecord(
          kind: .applied, planID: planID, itemID: item.id,
          detail: "irreversible; undo unavailable", deletedCount: count,
          deletedLogicalBytes: bytes))
      return ItemActionResult(
        itemID: item.id, outcome: .applied,
        detail: "irreversible; undo unavailable", deletedCount: count,
        deletedLogicalBytes: bytes)
    } catch {
      return ItemActionResult(
        itemID: item.id, outcome: .uncertain,
        detail: "journal failure after irreversible deletion",
        deletedCount: count, deletedLogicalBytes: bytes)
    }
  }

  private static func stableDeleteDirectory(
    _ current: FileIdentity,
    _ expected: FileIdentity
  ) -> Bool {
    current.device == expected.device && current.inode == expected.inode
      && current.kind == .directory && expected.kind == .directory
      && current.birthSeconds != nil && current.birthSeconds == expected.birthSeconds
      && current.birthNanoseconds == expected.birthNanoseconds
      && current.flags == expected.flags
      && current.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
  }
}

/// lstat of a known absolute Trash result does not require opening ~/.Trash.
/// It is only an observation; renameatx_np separately enforces no-follow.
public enum KnownPathFileSystem {
  public static func identity(at path: String) throws -> FileIdentity {
    _ = try DescriptorFileSystem.validatedComponents(path)
    var details = stat()
    guard lstat(path, &details) == 0 else {
      throw FileSystemFailure.systemCall("lstat", errno)
    }
    return DescriptorFileSystem.identity(from: details)
  }
}
