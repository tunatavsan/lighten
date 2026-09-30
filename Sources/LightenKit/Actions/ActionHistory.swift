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

public struct HistoryPlan: Sendable, Identifiable {
  public let id: UUID
  public let kind: ActionKind
  public let createdAt: Date
  public let items: [HistoryItem]
  public let metadata: [JournalItemSummary]

  public var canUndo: Bool { kind == .trash && items.contains { $0.state == .inTrash } }

  public var state: HistoryState {
    if items.contains(where: { $0.state == .uncertain }) { return .uncertain }
    if items.contains(where: { $0.state == .partiallyDeleted }) { return .partiallyDeleted }
    if items.contains(where: { $0.state == .inTrash }) { return .inTrash }
    if items.contains(where: { $0.state == .failed }) { return .failed }
    if items.contains(where: { $0.state == .skipped }) { return .skipped }
    return items.first?.state ?? .uncertain
  }

  public var logicalBytes: Int64 { metadata.reduce(0) { $0 &+ $1.logicalBytes } }
  public var deletedCount: Int { items.reduce(0) { $0 + $1.deletedCount } }
  public var deletedLogicalBytes: Int64 { items.reduce(0) { $0 &+ $1.deletedLogicalBytes } }
}

public struct HistoryReadout: Sendable {
  public let items: [HistoryItem]
  public let issues: [JournalIssue]
  public let plans: [HistoryPlan]
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
    let readout = try await journal.readSummary()
    var items: [HistoryItem] = []
    var plans: [HistoryPlan] = []
    var eventsByItem: [UUID: [UUID: [JournalRecord]]] = [:]
    for record in readout.records {
      if let itemID = record.itemID {
        eventsByItem[record.planID, default: [:]][itemID, default: []].append(record)
      }
    }
    for intent in readout.records where intent.kind == .intent {
      guard let plan = intent.summary, plan.id == intent.planID else { continue }
      let firstItem = items.count
      for item in plan.items {
        let events = eventsByItem[plan.id]?[item.id] ?? []
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
          if let original = item.rootIdentity,
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
      plans.append(
        HistoryPlan(
          id: plan.id, kind: plan.kind, createdAt: plan.createdAt,
          items: Array(items[firstItem...]), metadata: plan.items))
    }
    return HistoryReadout(items: items, issues: readout.issues, plans: plans)
  }

  public func undo(planID: UUID, itemID: UUID) async throws {
    guard !busy else { throw UndoFailure.alreadyRunning }
    busy = true
    defer { busy = false }
    try await journal.withMutationLease {
      try await self.undoLeased(planID: planID, itemID: itemID)
    }
  }

  /// Restores every pending item in the action under one mutation lease.
  public func undo(planID: UUID) async throws {
    guard !busy else { throw UndoFailure.alreadyRunning }
    busy = true
    defer { busy = false }
    try await journal.withMutationLease {
      let readout = try await self.journal.readSummary()
      guard readout.issues.isEmpty else { throw UndoFailure.corruptHistory }
      let plan = try await self.journal.loadPlan(id: planID)
      guard plan.kind == .trash else { throw UndoFailure.noAppliedRecord }
      let events = Dictionary(grouping: readout.records.filter { $0.planID == planID && $0.itemID != nil }) {
        $0.itemID!
      }
      var pending: [(PlanItem, [JournalRecord])] = []
      var completedInterruptedRestore = false
      for item in plan.items {
        let records = events[item.id] ?? []
        guard let applied = records.last(where: { $0.kind == .applied }),
          records.last?.kind != .reversed,
          let trashPath = applied.returnedTrashPath, let moved = applied.movedIdentity
        else { continue }
        if records.last?.kind == .undoIntent, Self.verifiedRestoredItem(item: item, moved: moved) {
          try await self.journal.append(JournalRecord(kind: .reversed, planID: planID, itemID: item.id))
          completedInterruptedRestore = true
          continue
        }
        guard Self.verifiedTrashItem(at: trashPath, item: item, moved: moved) else {
          throw UndoFailure.changedTrashItem
        }
        pending.append((item, records))
      }
      guard !pending.isEmpty || completedInterruptedRestore else { throw UndoFailure.noAppliedRecord }
      for (item, records) in pending {
        try await self.restoreLeased(plan: plan, item: item, records: records)
      }
    }
  }

  private func undoLeased(planID: UUID, itemID: UUID) async throws {
    let readout = try await journal.readSummary()
    guard readout.issues.isEmpty else { throw UndoFailure.corruptHistory }
    let plan = try await journal.loadPlan(id: planID)
    guard let item = plan.items.first(where: { $0.id == itemID }) else { throw UndoFailure.unknownItem }
    guard plan.kind == .trash else { throw UndoFailure.noAppliedRecord }
    let records = readout.records.filter { $0.planID == planID && $0.itemID == itemID }
    try await restoreLeased(plan: plan, item: item, records: records)
  }

  private func restoreLeased(plan: ActionPlan, item: PlanItem, records: [JournalRecord]) async throws {
    let planID = plan.id
    let itemID = item.id
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

  private static func verifiedTrashItem(at path: String, item: JournalItemSummary, moved: FileIdentity) -> Bool {
    guard let original = item.rootIdentity, let volumeID = item.volumeID,
      original.matchesStableTrashIdentity(moved),
      (try? DescriptorFileSystem.volumeID(at: path)) == volumeID,
      let observed = try? KnownPathFileSystem.identity(at: path)
    else { return false }
    return moved.matchesStableTrashIdentity(observed)
  }

  private static func verifiedRestoredItem(item: JournalItemSummary, moved: FileIdentity) -> Bool {
    guard let original = item.rootIdentity, let volumeID = item.volumeID,
      original.matchesStableTrashIdentity(moved),
      (try? DescriptorFileSystem.volumeID(at: item.sourcePath)) == volumeID,
      let observed = try? DescriptorFileSystem.identity(at: item.sourcePath)
    else { return false }
    return moved.matchesStableTrashIdentity(observed)
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
