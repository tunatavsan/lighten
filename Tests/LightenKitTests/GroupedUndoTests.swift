import Darwin
import Foundation
import Testing

@testable import LightenKit

private struct PartialUndoFixture {
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
    let selected = try paths.map { path in
      let identity = try DescriptorFileSystem.identity(at: path)
      return PlanService.Selection(path: path, device: identity.device, inode: identity.inode)
    }
    return try PlanService().makeSpacePlan(selections: selected, scanRootPath: root, runID: UUID())
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

private struct PartialUndoTrash: TrashMoving {
  let directory: String
  func moveToTrash(path: String) async throws -> String {
    let result = directory + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: result)
    return result
  }
}

@Test("A changed first Trash item does not prevent the remaining verified items from being restored")
func groupedUndoContinuesAfterChangedFirstItem() async throws {
  let fixture = try PartialUndoFixture()
  defer { fixture.cleanup() }
  let plan = try fixture.plan()
  let applied = try await ActionExecutor(journal: fixture.journal, trash: PartialUndoTrash(directory: fixture.trash))
    .execute(plan)
  #expect(applied.items.allSatisfy { $0.outcome == .applied })
  try Data("changed".utf8).write(to: URL(fileURLWithPath: fixture.trash + "/first"))
  let history = ActionHistory(journal: fixture.journal)
  let result = try await history.undo(planID: plan.id)
  #expect(result.restoredCount == 2 && result.remainingCount == 1)
  #expect(result.items[0].failure == .changedTrashItem)
  #expect(result.items[0].outcome == .skipped)
  #expect(!FileManager.default.fileExists(atPath: fixture.paths[0]))
  #expect(FileManager.default.fileExists(atPath: fixture.paths[1]))
  #expect(FileManager.default.fileExists(atPath: fixture.paths[2]))
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.trash + "/first")) == Data("changed".utf8))
  let remaining = try #require(try await history.reconcile().plans.first)
  #expect(!remaining.canUndo)
  #expect(remaining.items[0].detail == "changedTrashItem")
  #expect(try await fixture.journal.readSummary().issues.isEmpty)
}

@Test("A name collision in the middle preserves both copies while the first and third items restore")
func groupedUndoContinuesAfterMiddleCollision() async throws {
  let fixture = try PartialUndoFixture()
  defer { fixture.cleanup() }
  let plan = try fixture.plan()
  _ = try await ActionExecutor(journal: fixture.journal, trash: PartialUndoTrash(directory: fixture.trash)).execute(
    plan)
  try Data("occupied".utf8).write(to: URL(fileURLWithPath: fixture.paths[1]))
  let history = ActionHistory(journal: fixture.journal)
  let before = try #require(try await history.reconcile().plans.first)
  #expect(before.canUndo && !before.items[1].canUndo)
  let result = try await history.undo(planID: plan.id)
  #expect(result.restoredCount == 2 && result.remainingCount == 1)
  #expect(result.items[1].failure == .nameOccupied)
  #expect(FileManager.default.fileExists(atPath: fixture.paths[0]))
  #expect(FileManager.default.fileExists(atPath: fixture.paths[2]))
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.paths[1])) == Data("occupied".utf8))
  #expect(FileManager.default.fileExists(atPath: fixture.trash + "/second"))
  #expect(try await history.reconcile().plans.first?.canUndo == false)
  try FileManager.default.removeItem(atPath: fixture.paths[1])
  #expect(try await history.reconcile().plans.first?.canUndo == true)
  let retried = try await history.undo(planID: plan.id)
  #expect(retried.restoredCount == 1 && retried.remainingCount == 0)
  #expect(try await fixture.journal.readSummary().issues.isEmpty)
}

@Test("History counts and bytes include applied items and exclude refused selections")
func historyTotalsOnlyIncludeAppliedItems() async throws {
  let fixture = try PartialUndoFixture()
  defer { fixture.cleanup() }
  let plan = try fixture.plan()
  let result = try await ActionExecutor(
    journal: fixture.journal,
    trash: PartialUndoTrash(directory: fixture.trash),
    beforeMutation: { item in
      if item.sourcePath == fixture.paths[1] { throw GuardFailure.changedItem }
    }
  ).execute(plan)
  #expect(result.items.map(\.outcome) == [.applied, .skipped, .applied])
  let recorded = try #require(try await ActionHistory(journal: fixture.journal).reconcile().plans.first)
  #expect(recorded.metadata.count == 3)
  #expect(recorded.appliedCount == 2)
  #expect(recorded.logicalBytes == 22)
  #expect(recorded.items.map(\.applied) == [true, false, true])
}

private actor LateCollisionJournal: ActionJournal {
  let base: JSONLActionJournal
  let path: String
  private var fired = false

  init(base: JSONLActionJournal, path: String) {
    self.base = base
    self.path = path
  }

  func acquireMutationLease() async throws -> JournalLease { try await base.acquireMutationLease() }
  func releaseMutationLease(_ lease: JournalLease) async { await base.releaseMutationLease(lease) }
  func read() async throws -> JournalReadout { try await base.read() }
  func readSummary() async throws -> JournalReadout { try await base.readSummary() }
  func loadPlan(id: UUID) async throws -> ActionPlan { try await base.loadPlan(id: id) }
  func append(_ record: JournalRecord) async throws {
    try await base.append(record)
    if record.kind == .undoIntent && !fired {
      fired = true
      try Data("late collision".utf8).write(to: URL(fileURLWithPath: path))
    }
  }
}

@Test("A collision after complete preflight remains untouched and is reported without blocking other restores")
func groupedUndoPreservesLateCollision() async throws {
  let fixture = try PartialUndoFixture()
  defer { fixture.cleanup() }
  let plan = try fixture.plan()
  _ = try await ActionExecutor(journal: fixture.journal, trash: PartialUndoTrash(directory: fixture.trash)).execute(
    plan)
  let wrapped = LateCollisionJournal(base: fixture.journal, path: fixture.paths[2])
  let result = try await ActionHistory(journal: wrapped).undo(planID: plan.id)
  #expect(result.restoredCount == 2 && result.items[2].failure == .nameOccupied)
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.paths[2])) == Data("late collision".utf8))
  #expect(FileManager.default.fileExists(atPath: fixture.trash + "/third"))
  #expect(FileManager.default.fileExists(atPath: fixture.paths[0]))
  #expect(FileManager.default.fileExists(atPath: fixture.paths[1]))
  #expect(try await fixture.journal.readSummary().issues.isEmpty)
}
