import Darwin
import Foundation
import LightenKit
import Testing

@testable import Lighten
@testable import LightenKit

private struct HistoryStoreFixture {
  let root: String
  let paths: [String]
  let trash: String
  let journal: JSONLActionJournal

  init() throws {
    let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(temporary) }
    root = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
    paths = [root + "/first", root + "/second", root + "/third"]
    trash = root + "/Trash"
    journal = JSONLActionJournal(path: root + "/Journal/actions.jsonl")
    try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
    for (offset, path) in paths.enumerated() {
      try Data(repeating: UInt8(offset + 1), count: offset + 10).write(to: URL(fileURLWithPath: path))
    }
  }

  func plan() throws -> ActionPlan {
    let selections = try paths.map { path in
      let identity = try DescriptorFileSystem.identity(at: path)
      return PlanService.Selection(path: path, device: identity.device, inode: identity.inode)
    }
    return try PlanService().makeSpacePlan(selections: selections, scanRootPath: root, runID: UUID())
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

private struct HistoryFixtureTrash: TrashMoving {
  let directory: String
  func moveToTrash(path: String) async throws -> String {
    let result = directory + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: result)
    return result
  }
}

private actor HistoryStoreJournalSpy: ActionJournal {
  let base: JSONLActionJournal
  private var fullReads = 0
  private var loadedPlans: [UUID] = []

  init(base: JSONLActionJournal) { self.base = base }
  func acquireMutationLease() async throws -> JournalLease { try await base.acquireMutationLease() }
  func releaseMutationLease(_ lease: JournalLease) async { await base.releaseMutationLease(lease) }
  func append(_ record: JournalRecord) async throws { try await base.append(record) }
  func read() async throws -> JournalReadout {
    fullReads += 1
    return try await base.read()
  }
  func readSummary() async throws -> JournalReadout { try await base.readSummary() }
  func loadPlan(id: UUID) async throws -> ActionPlan {
    loadedPlans.append(id)
    return try await base.loadPlan(id: id)
  }
  func calls() -> (fullReads: Int, loadedPlans: [UUID]) { (fullReads, loadedPlans) }
}

@MainActor private func applyHistoryFixture(_ fixture: HistoryStoreFixture) async throws -> (ActionStore, ActionPlan) {
  let store = ActionStore(
    journal: fixture.journal, trash: HistoryFixtureTrash(directory: fixture.trash),
    historyService: ActionHistory(journal: fixture.journal, homeDirectory: fixture.root))
  let plan = try fixture.plan()
  store.present(
    plan: plan,
    items: plan.items.map {
      ActionItemSummary(
        id: $0.id, label: URL(fileURLWithPath: $0.sourcePath).lastPathComponent,
        path: $0.sourcePath, reason: "Fixture selection", logicalBytes: PlanItemSize.measure($0).logical,
        allocatedBytes: PlanItemSize.measure($0).allocated)
    })
  let presentation = try #require(store.pending)
  let confirmed = try #require(store.takeConfirmedPlan(presentation))
  await store.executeConfirmed(confirmed)
  #expect(store.result?.items.allSatisfy { $0.outcome == .applied } == true)
  return (store, plan)
}

@Test("History store keeps partial Undo results and removes Undo until a collision is resolved")
@MainActor func historyStorePartialUndoAndRecovery() async throws {
  let fixture = try HistoryStoreFixture()
  defer { fixture.cleanup() }
  let (store, plan) = try await applyHistoryFixture(fixture)
  try Data("collision".utf8).write(to: URL(fileURLWithPath: fixture.paths[1]))
  await store.reloadHistory()
  await store.setHistoryGroupExpanded(plan.id, expanded: true)
  let history = try #require(store.history?.plans.first)
  #expect(history.canUndo)
  #expect(history.appliedCount == 3)
  await store.undo(history)
  let result = try #require(store.undoResults[plan.id])
  #expect(result.restoredCount == 2)
  #expect(result.remainingCount == 1)
  let second = try #require(plan.items.first { $0.sourcePath == fixture.paths[1] })
  #expect(result.items.first { $0.itemID == second.id }?.failure == .nameOccupied)
  #expect(store.message?.contains("2") == true && store.message?.contains("1") == true)
  let remaining = try #require(store.history?.plans.first)
  #expect(!remaining.canUndo)
  #expect(remaining.items.first { $0.itemID == second.id }?.canUndo == false)
  #expect(store.pendingTrashCount == 1)
  #expect(store.pendingTrashLogicalBytes == 11)
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.paths[1])) == Data("collision".utf8))
  #expect(FileManager.default.fileExists(atPath: fixture.paths[0]))
  #expect(FileManager.default.fileExists(atPath: fixture.paths[2]))
  try FileManager.default.removeItem(atPath: fixture.paths[1])
  await store.reloadHistory()
  let recovered = try #require(store.history?.plans.first)
  #expect(recovered.canUndo)
  await store.undo(recovered)
  #expect(store.undoResults[plan.id]?.restoredCount == 1)
  #expect(store.undoResults[plan.id]?.remainingCount == 0)
  #expect(store.history?.plans.first?.canUndo == false)
  #expect(store.pendingTrashCount == 0)
}

@Test("History totals exclude failed planned items and preserve applied sizes after Undo")
@MainActor func historyStoreTotalsCountAppliedItemsOnly() async throws {
  let fixture = try HistoryStoreFixture()
  defer { fixture.cleanup() }
  let plan = try fixture.plan()
  try FileManager.default.removeItem(atPath: fixture.paths[1])
  let store = ActionStore(
    journal: fixture.journal, trash: HistoryFixtureTrash(directory: fixture.trash),
    historyService: ActionHistory(journal: fixture.journal, homeDirectory: fixture.root))
  store.present(
    plan: plan,
    items: plan.items.map {
      ActionItemSummary(
        id: $0.id, label: $0.sourcePath, path: $0.sourcePath, reason: "Fixture selection",
        logicalBytes: PlanItemSize.measure($0).logical, allocatedBytes: PlanItemSize.measure($0).allocated)
    })
  let presentation = try #require(store.pending)
  let confirmed = try #require(store.takeConfirmedPlan(presentation))
  await store.executeConfirmed(confirmed)
  await store.setHistoryGroupExpanded(plan.id, expanded: true)
  let history = try #require(store.history?.plans.first)
  #expect(history.metadata.count == 3)
  #expect(history.appliedCount == 2)
  #expect(history.logicalBytes == 22)
  #expect(store.pendingTrashCount == 2)
  #expect(store.pendingTrashLogicalBytes == 22)
  #expect(history.items.contains { !$0.applied && $0.detail != nil })
  await store.undo(history)
  #expect(store.history?.plans.first?.appliedCount == 2)
  #expect(store.history?.plans.first?.logicalBytes == 22)
  #expect(store.pendingTrashLogicalBytes == 0)
}

@Test("Collapsed History refresh loads no plans and refreshes details only for opened groups")
@MainActor func historyStoreLoadsOnlyExpandedGroups() async throws {
  let fixture = try HistoryStoreFixture()
  defer { fixture.cleanup() }
  let selection = try fixture.plan()
  let plans = selection.items.map { ActionPlan(snapshotRunID: selection.snapshotRunID, kind: .trash, items: [$0]) }
  for plan in plans {
    let item = plan.items[0]
    let destination = fixture.trash + "/" + URL(fileURLWithPath: item.sourcePath).lastPathComponent
    try await fixture.journal.withMutationLease {
      try await fixture.journal.append(JournalRecord(kind: .intent, planID: plan.id, plan: plan))
      try FileManager.default.moveItem(atPath: item.sourcePath, toPath: destination)
      let moved = try DescriptorFileSystem.identity(at: destination)
      try await fixture.journal.append(
        JournalRecord(
          kind: .applied, planID: plan.id, itemID: item.id,
          returnedTrashPath: destination, movedIdentity: moved))
    }
  }
  let spy = HistoryStoreJournalSpy(base: fixture.journal)
  let store = ActionStore(
    journal: fixture.journal,
    historyService: ActionHistory(journal: spy, homeDirectory: fixture.root))
  await store.reloadHistory()
  #expect(store.history?.plans.count == 3)
  #expect(store.history?.plans.allSatisfy { !$0.detailsLoaded && !$0.canUndo } == true)
  #expect((await spy.calls()).loadedPlans.isEmpty)
  await store.setHistoryGroupExpanded(plans[1].id, expanded: true)
  #expect(store.expandedHistoryGroups == [plans[1].id])
  #expect(store.loadingHistoryGroups.isEmpty)
  #expect(store.history?.plans.map(\.detailsLoaded) == [false, true, false])
  #expect((await spy.calls()).loadedPlans == [plans[1].id])
  await store.reloadHistory()
  #expect((await spy.calls()).loadedPlans == [plans[1].id, plans[1].id])
  #expect(store.history?.plans.first { $0.id == plans[1].id }?.canUndo == true)
  await store.setHistoryGroupExpanded(plans[1].id, expanded: false)
  await store.reloadHistory()
  #expect(store.history?.plans.allSatisfy { !$0.detailsLoaded } == true)
  #expect((await spy.calls()).loadedPlans == [plans[1].id, plans[1].id])
  #expect((await spy.calls()).fullReads == 0)
}

@Test("History display preserves unknown opaque sizes and counts only applied observations")
@MainActor func historyObservedSizesStayHonest() {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  func metadata(_ suffix: String, bytes: Int64?) -> JournalItemSummary {
    let entry = ScanEntry(
      parentID: nil, path: root + "/" + suffix + ".app",
      identity: FileIdentity(
        device: 1, inode: 2, changeSeconds: 0, changeNanoseconds: 0,
        logicalBytes: 4096, allocatedBytes: 4096, linkCount: 1, flags: 0, kind: .directory),
      issues: [], readable: true)
    return JournalItemSummary(
      PlanItem(
        id: entry.id, sourcePath: entry.path, inventory: [entry], ancestors: [], policy: .wholeBundle,
        observedSize: bytes.map {
          ObservedPlanSize(logical: ByteAggregate(knownLowerBound: $0, completeTotal: $0), allocated: nil)
        }))
  }
  let known = metadata("known", bytes: 12_000_000_000)
  let unknown = metadata("unknown", bytes: nil)
  let failed = metadata("failed", bytes: 20_000_000_000)
  let planID = UUID()
  let summaries = [known, unknown, failed]
  let items = summaries.map {
    HistoryItem(
      planID: planID, itemID: $0.id, state: $0.id == failed.id ? .failed : .inTrash,
      returnedTrashPath: nil, detail: nil, deletedCount: 0, deletedLogicalBytes: 0,
      applied: $0.id != failed.id)
  }
  let plan = HistoryPlan(id: planID, kind: .trash, createdAt: Date(), items: items, metadata: summaries)
  let store = ActionStore(journal: JSONLActionJournal(path: root + "/journal/actions.jsonl"))
  store.history = HistoryReadout(items: items, issues: [], plans: [plan])
  store.historyMetadata = Dictionary(
    uniqueKeysWithValues: summaries.map {
      (
        $0.id,
        HistoryMetadata(
          path: $0.sourcePath, logicalBytes: $0.logicalBytes, allocatedBytes: $0.allocatedBytes,
          observedSize: $0.displaySize)
      )
    })
  #expect(store.historySize(plan).logical == ByteAggregate(knownLowerBound: 12_000_000_000, completeTotal: nil))
  #expect(store.pendingTrashSize == store.historySize(plan))
  #expect(store.pendingTrashCount == 2)
  store.historyMetadata.removeValue(forKey: known.id)
  #expect(store.pendingTrashSize == .unknown)
  #expect(PlanItemSize.text(store.pendingTrashSize.logical) == String(localized: "Size unknown"))
}
