import Darwin
import Foundation
import Testing

@testable import LightenKit

private actor HistoryJournalSpy: ActionJournal {
  let base: JSONLActionJournal
  private var fullReads = 0
  private var summaryReads = 0
  private var loadedPlans: [UUID] = []

  init(base: JSONLActionJournal) { self.base = base }

  func acquireMutationLease() async throws -> JournalLease { try await base.acquireMutationLease() }
  func releaseMutationLease(_ lease: JournalLease) async { await base.releaseMutationLease(lease) }
  func append(_ record: JournalRecord) async throws { try await base.append(record) }
  func read() async throws -> JournalReadout {
    fullReads += 1
    return try await base.read()
  }
  func readSummary() async throws -> JournalReadout {
    summaryReads += 1
    return try await base.readSummary()
  }
  func loadPlan(id: UUID) async throws -> ActionPlan {
    loadedPlans.append(id)
    return try await base.loadPlan(id: id)
  }
  func calls() -> (fullReads: Int, summaryReads: Int, loadedPlans: [UUID]) {
    (fullReads, summaryReads, loadedPlans)
  }
}

private struct LazyHistoryFixture: Sendable {
  let root: String
  let journal: JSONLActionJournal
  let spy: HistoryJournalSpy

  init() throws {
    let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(temporary) }
    root = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
    journal = JSONLActionJournal(path: root + "/Journal/actions.jsonl")
    spy = HistoryJournalSpy(base: journal)
    try FileManager.default.createDirectory(atPath: root + "/Trash", withIntermediateDirectories: true)
  }

  func applyPlans(count: Int) async throws -> [ActionPlan] {
    var result: [ActionPlan] = []
    for index in 0..<count {
      let directory = root + "/Source-" + String(index)
      let path = directory + "/file"
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try Data(repeating: UInt8(index + 1), count: 20 + index).write(to: URL(fileURLWithPath: path))
      let identity = try DescriptorFileSystem.identity(at: path)
      let plan = try PlanService(homeDirectory: root).makeSpacePlan(
        selections: [.init(path: path, device: identity.device, inode: identity.inode)],
        scanRootPath: directory, runID: UUID())
      let item = plan.items[0]
      let destination = root + "/Trash/file-" + String(index)
      try await journal.withMutationLease {
        try await journal.append(JournalRecord(kind: .intent, planID: plan.id, plan: plan))
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        let moved = try DescriptorFileSystem.identity(at: destination)
        try await journal.append(
          JournalRecord(
            kind: .applied, planID: plan.id, itemID: item.id,
            returnedTrashPath: destination, movedIdentity: moved))
      }
      result.append(plan)
    }
    return result
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

@Test("History refresh loads no inventories; opening one group loads only that group's plan")
func historyRefreshAndGroupLoadingAreSeparate() async throws {
  let fixture = try LazyHistoryFixture()
  defer { fixture.cleanup() }
  let plans = try await fixture.applyPlans(count: 3)
  let history = ActionHistory(journal: fixture.spy, homeDirectory: fixture.root)
  let summary = try await history.reconcile()
  #expect(summary.plans.count == 3)
  #expect(summary.plans.allSatisfy { !$0.detailsLoaded && !$0.canUndo && $0.state == .inTrash })
  #expect(summary.items.allSatisfy { $0.detail == nil })
  let initialCalls = await fixture.spy.calls()
  #expect(initialCalls.fullReads == 0 && initialCalls.summaryReads == 1 && initialCalls.loadedPlans.isEmpty)
  let opened = try await history.loadGroup(planID: plans[1].id)
  #expect(opened.detailsLoaded && opened.canUndo)
  #expect(opened.items.allSatisfy { $0.canUndo })
  let merged = summary.replacingGroup(opened)
  #expect(merged.plans.map(\.detailsLoaded) == [false, true, false])
  #expect(merged.items.filter(\.canUndo).count == 1)
  let refreshed = try await history.reconcile()
  #expect(refreshed.plans.allSatisfy { !$0.detailsLoaded && !$0.canUndo })
  let calls = await fixture.spy.calls()
  #expect(calls.fullReads == 0 && calls.summaryReads == 3)
  #expect(calls.loadedPlans == [plans[1].id])
}

@Test(
  "Loaded History details never authorize Undo after a source, parent, or Trash change",
  arguments: [UndoFailure.nameOccupied, .unsafeParent, .changedTrashItem])
func historyLoadedDetailsNeverAuthorizeUndo(failure: UndoFailure) async throws {
  let fixture = try LazyHistoryFixture()
  defer { fixture.cleanup() }
  let plan = try #require(try await fixture.applyPlans(count: 1).first)
  let history = ActionHistory(journal: fixture.spy, homeDirectory: fixture.root)
  let opened = try await history.loadGroup(planID: plan.id)
  #expect(opened.detailsLoaded && opened.canUndo)
  let source = plan.items[0].sourcePath
  let destination = fixture.root + "/Trash/file-0"
  let original = try Data(contentsOf: URL(fileURLWithPath: destination))
  switch failure {
  case .nameOccupied:
    try Data("occupied".utf8).write(to: URL(fileURLWithPath: source))
  case .unsafeParent:
    let parent = (source as NSString).deletingLastPathComponent
    try FileManager.default.moveItem(atPath: parent, toPath: parent + "-original")
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
  case .changedTrashItem:
    try Data("changed".utf8).write(to: URL(fileURLWithPath: destination))
  default: Issue.record("Unsupported fixture case")
  }
  let result = try await history.undo(planID: plan.id)
  #expect(result.restoredCount == 0 && result.remainingCount == 1)
  #expect(result.items.first?.failure == failure)
  #expect(FileManager.default.fileExists(atPath: destination))
  #expect((await fixture.spy.calls()).loadedPlans == [plan.id, plan.id])
  if failure == .nameOccupied {
    #expect(try Data(contentsOf: URL(fileURLWithPath: source)) == Data("occupied".utf8))
    #expect(try await history.loadGroup(planID: plan.id).canUndo == false)
    try FileManager.default.removeItem(atPath: source)
    let available = try await history.loadGroup(planID: plan.id)
    #expect(available.detailsLoaded && available.canUndo)
    let restored = try await history.undo(planID: plan.id)
    #expect(restored.restoredCount == 1 && restored.remainingCount == 0)
    #expect(try Data(contentsOf: URL(fileURLWithPath: source)) == original)
  } else {
    #expect(!FileManager.default.fileExists(atPath: source))
  }
}

@Test("An unavailable inventory does not break summary refresh or another group's detail load")
func historyUnavailableInventoryIsIsolatedToItsGroup() async throws {
  let fixture = try LazyHistoryFixture()
  defer { fixture.cleanup() }
  let plans = try await fixture.applyPlans(count: 2)
  try Data("corrupt inventory".utf8).write(
    to: URL(fileURLWithPath: fixture.root + "/Journal/plans/" + plans[0].id.uuidString + ".json"))
  let history = ActionHistory(journal: fixture.spy, homeDirectory: fixture.root)
  #expect(try await history.reconcile().plans.count == 2)
  #expect((await fixture.spy.calls()).loadedPlans.isEmpty)
  await #expect(throws: JournalFailure.self) { try await history.loadGroup(planID: plans[0].id) }
  let other = try await history.loadGroup(planID: plans[1].id)
  #expect(other.detailsLoaded && other.canUndo)
  #expect((await fixture.spy.calls()).loadedPlans == plans.map(\.id))
  await #expect(throws: UndoFailure.unknownItem) { try await history.loadGroup(planID: UUID()) }
  #expect((await fixture.spy.calls()).loadedPlans == plans.map(\.id))
}
