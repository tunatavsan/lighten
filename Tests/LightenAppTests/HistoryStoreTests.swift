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
