import Darwin
import Foundation

public enum HistoryState: String, Sendable {
  case atSource, inTrash, reversed, failed, skipped, uncertain, deleted, partiallyDeleted
}

public struct HistoryItem: Sendable {
  public let planID: UUID
  public let itemID: UUID
  public let state: HistoryState
  public let returnedTrashPath: String?
  public let detail: String?
  public let deletedCount: Int
  public let deletedLogicalBytes: Int64
}

public struct HistoryReadout: Sendable {
  public let items: [HistoryItem]
  public let issues: [JournalIssue]
}

public enum UndoFailure: Error, Sendable {
  case corruptHistory, unknownItem, noAppliedRecord, changedTrashItem
  case unsafeParent, nameOccupied
  case renameFailed(Int32)
  case alreadyRunning
}

public actor ActionHistory {
  private let journal: any ActionJournal
  private let homeDirectory: String
  private var busy = false

  public init(journal: any ActionJournal, homeDirectory: String = NSHomeDirectory()) {
    self.journal = journal
    self.homeDirectory = homeDirectory
  }

  public func reconcile() async throws -> HistoryReadout {
    try await journal.withMutationLease {
      try await self.reconcileLeased()
    }
  }

  private func reconcileLeased() async throws -> HistoryReadout {
    let readout = try await journal.read()
    var items: [HistoryItem] = []
    for intent in readout.records where intent.kind == .intent {
      guard let plan = intent.plan, plan.id == intent.planID else { continue }
      for item in plan.items {
        let events = readout.records.filter {
          $0.planID == plan.id && $0.itemID == item.id
        }
        let terminal = events.last
        let applied = events.last { $0.kind == .applied }
        let state: HistoryState
        if plan.kind == .catalogDelete {
          switch terminal?.kind {
          case .applied: state = .deleted
          case .failed, .skipped:
            state =
              (terminal?.deletedCount ?? 0) > 0 ? .partiallyDeleted : (terminal?.kind == .skipped ? .skipped : .failed)
          case .deleteProgress: state = .uncertain
          default: state = .uncertain
          }
          items.append(
            HistoryItem(
              planID: plan.id, itemID: item.id, state: state,
              returnedTrashPath: nil, detail: terminal?.detail,
              deletedCount: terminal?.deletedCount ?? 0,
              deletedLogicalBytes: terminal?.deletedLogicalBytes ?? 0))
          continue
        }
        switch terminal?.kind {
        case .reversed: state = .reversed
        case .failed: state = .failed
        case .skipped: state = .skipped
        case .applied, .undoFailed, .undoIntent:
          if let applied, let path = applied.returnedTrashPath,
            let moved = applied.movedIdentity,
            Self.verifiedTrashItem(at: path, item: item, moved: moved)
          {
            state = .inTrash
          } else if terminal?.kind == .undoIntent,
            let moved = applied?.movedIdentity,
            Self.verifiedRestoredItem(item: item, moved: moved)
          {
            state = .reversed
          } else {
            state = .uncertain
          }
        case .intent, .deleteProgress, .none:
          if let original = item.inventory.first?.identity,
            (try? DescriptorFileSystem.identity(at: item.sourcePath)) == original
          {
            state = .atSource
          } else {
            state = .uncertain
          }
        }
        items.append(
          HistoryItem(
            planID: plan.id, itemID: item.id, state: state,
            returnedTrashPath: applied?.returnedTrashPath, detail: terminal?.detail,
            deletedCount: 0, deletedLogicalBytes: 0
          ))
      }
    }
    return HistoryReadout(items: items, issues: readout.issues)
  }

  public func undo(planID: UUID, itemID: UUID) async throws {
    guard !busy else { throw UndoFailure.alreadyRunning }
    busy = true
    defer { busy = false }
    try await journal.withMutationLease {
      try await self.undoLeased(planID: planID, itemID: itemID)
    }
  }

  private func undoLeased(planID: UUID, itemID: UUID) async throws {
    let readout = try await journal.read()
    guard readout.issues.isEmpty else { throw UndoFailure.corruptHistory }
    guard
      let plan = readout.records.first(where: {
        $0.kind == .intent && $0.planID == planID
      })?.plan, let item = plan.items.first(where: { $0.id == itemID })
    else { throw UndoFailure.unknownItem }
    guard plan.kind == .trash else { throw UndoFailure.noAppliedRecord }
    let records = readout.records.filter { $0.planID == planID && $0.itemID == itemID }
    guard let applied = records.last(where: { $0.kind == .applied }),
      records.last?.kind != .reversed,
      let trashPath = applied.returnedTrashPath,
      let moved = applied.movedIdentity
    else { throw UndoFailure.noAppliedRecord }
    guard Self.verifiedTrashItem(at: trashPath, item: item, moved: moved) else {
      throw UndoFailure.changedTrashItem
    }
    for ancestor in item.ancestors {
      guard let current = try? DescriptorFileSystem.identity(at: ancestor.path),
        current.device == ancestor.identity.device,
        current.inode == ancestor.identity.inode,
        current.kind == .directory,
        current.flags == ancestor.identity.flags,
        ProtectionPolicy.rule(for: ancestor.path, homeDirectory: homeDirectory) == nil
      else { throw UndoFailure.unsafeParent }
    }
    let (parentFD, name): (Int32, String)
    do { (parentFD, name) = try DescriptorFileSystem.openParent(of: item.sourcePath) } catch {
      throw UndoFailure.unsafeParent
    }
    defer { close(parentFD) }
    var openedParent = stat()
    guard fstat(parentFD, &openedParent) == 0,
      let expectedParent = item.ancestors.last?.identity,
      let volumeID = item.volumeID,
      let parentPath = item.ancestors.last?.path,
      (try? DescriptorFileSystem.volumeID(at: parentPath)) == volumeID,
      UInt64(openedParent.st_dev) == expectedParent.device,
      openedParent.st_ino == expectedParent.inode
    else { throw UndoFailure.unsafeParent }
    // A durable intent makes a crash after rename distinguishable on restart.
    try await journal.append(
      JournalRecord(
        kind: .undoIntent, planID: planID, itemID: itemID,
        returnedTrashPath: trashPath, movedIdentity: moved
      ))
    // An await can permit a source/parent change; pinning and rechecking precedes rename.
    guard Self.verifiedTrashItem(at: trashPath, item: item, moved: moved),
      fstat(parentFD, &openedParent) == 0,
      UInt64(openedParent.st_dev) == expectedParent.device,
      openedParent.st_ino == expectedParent.inode,
      (try? DescriptorFileSystem.volumeID(at: parentPath)) == volumeID
    else { throw UndoFailure.unsafeParent }
    // The pinned descriptor alone is insufficient if its directory was moved
    // while the journal was awaited. Re-resolve the original path before rename.
    for ancestor in item.ancestors {
      guard let current = try? DescriptorFileSystem.identity(at: ancestor.path),
        current.sameStableDirectory(as: ancestor.identity),
        ProtectionPolicy.rule(for: ancestor.path, homeDirectory: homeDirectory) == nil
      else { throw UndoFailure.unsafeParent }
    }
    let (freshFD, freshName): (Int32, String)
    do { (freshFD, freshName) = try DescriptorFileSystem.openParent(of: item.sourcePath) } catch {
      throw UndoFailure.unsafeParent
    }
    defer { close(freshFD) }
    var freshParent = stat()
    guard freshName == name, fstat(freshFD, &freshParent) == 0,
      freshParent.st_dev == openedParent.st_dev,
      freshParent.st_ino == openedParent.st_ino
    else { throw UndoFailure.unsafeParent }
    // The no-replace primitive returns EEXIST and preserves both objects.
    let result = renameatx_np(
      AT_FDCWD, trashPath, parentFD, name,
      UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
    )
    guard result == 0 else {
      if errno == EEXIST { throw UndoFailure.nameOccupied }
      throw UndoFailure.renameFailed(errno)
    }
    // The exclusive rename changes ctime; require the remaining durable proof.
    guard Self.verifiedRestoredItem(item: item, moved: moved) else {
      throw UndoFailure.changedTrashItem
    }
    try await journal.append(
      JournalRecord(
        kind: .reversed, planID: planID, itemID: itemID
      ))
  }

  private static func verifiedTrashItem(at path: String, item: PlanItem, moved: FileIdentity) -> Bool {
    guard let original = item.inventory.first?.identity,
      let volumeID = item.volumeID,
      original.matchesStableTrashIdentity(moved),
      (try? DescriptorFileSystem.volumeID(at: path)) == volumeID,
      let observed = try? KnownPathFileSystem.identity(at: path)
    else { return false }
    return moved.matchesStableTrashIdentity(observed)
  }

  private static func verifiedRestoredItem(item: PlanItem, moved: FileIdentity) -> Bool {
    guard let original = item.inventory.first?.identity,
      let volumeID = item.volumeID,
      original.matchesStableTrashIdentity(moved),
      (try? DescriptorFileSystem.volumeID(at: item.sourcePath)) == volumeID,
      let observed = try? DescriptorFileSystem.identity(at: item.sourcePath)
    else { return false }
    return moved.matchesStableTrashIdentity(observed)
  }
}
