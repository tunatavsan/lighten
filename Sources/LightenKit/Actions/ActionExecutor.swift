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

  public init(itemID: UUID, outcome: ActionOutcome, detail: String? = nil) {
    self.itemID = itemID
    self.outcome = outcome
    self.detail = detail
  }
}

public struct ActionResult: Codable, Sendable {
  public let planID: UUID
  public let items: [ItemActionResult]
}

public enum ExecutionFailure: Error, Sendable {
  case catalogDeleteDenied, invalidPlan, corruptHistory, alreadyRunning, planAlreadyUsed
}

public actor ActionExecutor {
  private let journal: any ActionJournal
  private let trash: any TrashMoving
  private let guardService: ActionGuard
  private let beforeMutation: (@Sendable (PlanItem) async throws -> Void)?
  private var busy = false

  public init(
    journal: any ActionJournal, trash: any TrashMoving,
    guardService: ActionGuard = ActionGuard(),
    beforeMutation: (@Sendable (PlanItem) async throws -> Void)? = nil
  ) {
    self.journal = journal
    self.trash = trash
    self.guardService = guardService
    self.beforeMutation = beforeMutation
  }

  public func execute(_ plan: ActionPlan) async throws -> ActionResult {
    guard !busy else { throw ExecutionFailure.alreadyRunning }
    busy = true
    defer { busy = false }
    return try await journal.withMutationLease {
      try await self.executeLeased(plan)
    }
  }

  private func executeLeased(_ plan: ActionPlan) async throws -> ActionResult {
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
    guard plan.kind == .trash else { throw ExecutionFailure.catalogDeleteDenied }
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
        try guardService.validate(item)
        try await beforeMutation?(item)
        // The hook models the final window. Never move on its prior validation.
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
          moved.device == original.device, moved.inode == original.inode,
          moved.kind == original.kind
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
