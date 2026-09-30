import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private struct JournalFixture {
  let root: String
  let trash: String
  let journalPath: String

  init() throws {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw FileSystemFailure.invalidPath }
    defer { free(resolved) }
    root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
    trash = root + "/Trash"
    journalPath = root + "/actions-v1.jsonl"
    try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
  }

  func plan(paths: [String]) async throws -> ActionPlan {
    let scan = try await ScanService().scan(rootPath: root)
    let ids = try paths.map { path in try #require(scan.entries.first { $0.path == path }).id }
    return try PlanService().makePlan(snapshot: scan, selectedIDs: Set(ids))
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }
}

private struct JournalFixtureTrash: TrashMoving {
  let directory: String
  func moveToTrash(path: String) async throws -> String {
    let destination = directory + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: destination)
    return destination
  }
}

private func fixtureSHA(_ path: String) throws -> SHA256.Digest {
  SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
}

@Test("One history action restores every file and keeps its content")
func groupedPlanUndoRestoresAllSHA() async throws {
  let fixture = try JournalFixture()
  defer { fixture.remove() }
  let paths = [fixture.root + "/first", fixture.root + "/second", fixture.root + "/third"]
  for (offset, path) in paths.enumerated() {
    try Data(repeating: UInt8(offset + 1), count: 20_001 + offset).write(to: URL(fileURLWithPath: path))
  }
  let hashes = try paths.map(fixtureSHA)
  let plan = try await fixture.plan(paths: paths)
  let journal = JSONLActionJournal(path: fixture.journalPath)
  let result = try await ActionExecutor(journal: journal, trash: JournalFixtureTrash(directory: fixture.trash)).execute(
    plan)
  #expect(result.items.allSatisfy { $0.outcome == .applied })
  let history = ActionHistory(journal: JSONLActionJournal(path: fixture.journalPath))
  let before = (try await history.reconcile()).replacingGroup(try await history.loadGroup(planID: plan.id))
  #expect(before.plans.count == 1)
  #expect(before.plans[0].items.count == 3)
  #expect(before.plans[0].canUndo)
  try await history.undo(planID: plan.id)
  #expect(try paths.map(fixtureSHA) == hashes)
  #expect((try await history.reconcile()).plans[0].items.allSatisfy { $0.state == .reversed })
  let intent = try #require((try await journal.readSummary()).records.first)
  #expect(intent.schema == 2)
  #expect(intent.plan == nil)
  #expect(intent.planReference?.summary.id == plan.id)
  #expect(try await journal.loadPlan(id: plan.id) == plan)
}

@Test("Archive a truncated journal without losing pending Trash undo")
func recoverTruncatedJournalPreservesUndoAndNewActions() async throws {
  let fixture = try JournalFixture()
  defer { fixture.remove() }
  let paths = [fixture.root + "/first", fixture.root + "/second"]
  for path in paths { try Data(path.utf8).write(to: URL(fileURLWithPath: path)) }
  let hashes = try paths.map(fixtureSHA)
  let plan = try await fixture.plan(paths: paths)
  let journal = JSONLActionJournal(path: fixture.journalPath)
  _ = try await ActionExecutor(journal: journal, trash: JournalFixtureTrash(directory: fixture.trash)).execute(plan)
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.journalPath))
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("{\"schema\":1,".utf8))
  try handle.close()
  let damaged = try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath))
  #expect((try await journal.readSummary()).issues.count == 1)
  let archive = try await journal.archiveAndRestart()
  #expect(archive.contains("actions-v1.corrupt-"))
  #expect(try Data(contentsOf: URL(fileURLWithPath: archive)) == damaged)
  #expect((try await journal.readSummary()).issues.isEmpty)
  try await ActionHistory(journal: journal).undo(planID: plan.id)
  #expect(try paths.map(fixtureSHA) == hashes)
  let nextPath = fixture.root + "/next"
  try Data("new action".utf8).write(to: URL(fileURLWithPath: nextPath))
  let next = try await fixture.plan(paths: [nextPath])
  #expect(
    (try await ActionExecutor(journal: journal, trash: JournalFixtureTrash(directory: fixture.trash))
      .execute(next)).items[0].outcome == .applied)
  try await ActionHistory(journal: journal).undo(planID: next.id)
}

@Test("Inline legacy plans still decode, recover, and undo")
func legacyJournalRecoveryKeepsInlinePlanUndo() async throws {
  let fixture = try JournalFixture()
  defer { fixture.remove() }
  let source = fixture.root + "/legacy"
  try Data("legacy content".utf8).write(to: URL(fileURLWithPath: source))
  let hash = try fixtureSHA(source)
  let plan = try await fixture.plan(paths: [source])
  let destination = try await JournalFixtureTrash(directory: fixture.trash).moveToTrash(path: source)
  let moved = try KnownPathFileSystem.identity(at: destination)
  var data = Data()
  for record in [
    JournalRecord(kind: .intent, planID: plan.id, plan: plan),
    JournalRecord(
      kind: .applied, planID: plan.id, itemID: plan.items[0].id,
      returnedTrashPath: destination, movedIdentity: moved),
  ] {
    data.append(try JSONEncoder().encode(record))
    data.append(0x0A)
  }
  data.append(Data("{broken".utf8))
  try data.write(to: URL(fileURLWithPath: fixture.journalPath))
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.journalPath)
  let journal = JSONLActionJournal(path: fixture.journalPath)
  #expect((try await journal.read()).records.first?.plan == plan)
  _ = try await journal.archiveAndRestart()
  try await ActionHistory(journal: journal).undo(planID: plan.id)
  #expect(try fixtureSHA(source) == hash)
}

@Test("Only an owned, unlinked regular journal gets its public permissions repaired")
func ownedJournalPermissionsRepairAndHardlinkRefusal() async throws {
  let fixture = try JournalFixture()
  defer { fixture.remove() }
  try Data().write(to: URL(fileURLWithPath: fixture.journalPath))
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.journalPath)
  let journal = JSONLActionJournal(path: fixture.journalPath)
  #expect((try await journal.readSummary()).issues.isEmpty)
  var details = stat()
  #expect(lstat(fixture.journalPath, &details) == 0)
  #expect(details.st_mode & 0o777 == 0o600)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.journalPath)
  #expect(link(fixture.journalPath, fixture.root + "/alias") == 0)
  await #expect(throws: JournalFailure.self) { try await journal.readSummary() }
  #expect(lstat(fixture.journalPath, &details) == 0)
  #expect(details.st_mode & 0o777 == 0o644)
}

@Test("A changed or symlinked external inventory cannot authorize Undo")
func alteredExternalInventoryBlocksUndo() async throws {
  let fixture = try JournalFixture()
  defer { fixture.remove() }
  let source = fixture.root + "/source"
  try Data("protected content".utf8).write(to: URL(fileURLWithPath: source))
  let plan = try await fixture.plan(paths: [source])
  let journal = JSONLActionJournal(path: fixture.journalPath)
  _ = try await ActionExecutor(journal: journal, trash: JournalFixtureTrash(directory: fixture.trash)).execute(plan)
  let planPath = fixture.root + "/plans/" + plan.id.uuidString + ".json"
  let original = try Data(contentsOf: URL(fileURLWithPath: planPath))
  var altered = original
  altered.append(0x20)
  try altered.write(to: URL(fileURLWithPath: planPath))
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: planPath)
  await #expect(throws: JournalFailure.self) { try await ActionHistory(journal: journal).undo(planID: plan.id) }
  #expect(!FileManager.default.fileExists(atPath: source))
  try FileManager.default.removeItem(atPath: planPath)
  let alias = fixture.root + "/payload"
  try original.write(to: URL(fileURLWithPath: alias))
  try FileManager.default.createSymbolicLink(atPath: planPath, withDestinationPath: alias)
  await #expect(throws: JournalFailure.self) { try await ActionHistory(journal: journal).undo(planID: plan.id) }
  #expect(FileManager.default.fileExists(atPath: fixture.trash + "/source"))
}

private final class MeasuredNativeTrash: TrashMoving {
  private let returned = Synchronization.Mutex<String?>(nil)
  func moveToTrash(path: String) async throws -> String {
    var result: NSURL?
    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
    guard let result else { throw FileSystemFailure.invalidPath }
    let path = (result as URL).path
    returned.withLock { $0 = path }
    return path
  }
  var path: String? { returned.withLock { $0 } }
}

@Test(
  "Large native Trash actions keep a compact journal and fast cold history",
  .enabled(if: ProcessInfo.processInfo.environment["LIGHTEN_JOURNAL_BENCH"] == "1"), .timeLimit(.minutes(5)))
func compactJournalFiftyThousandFilesMeasurement() async throws {
  let fixture = try JournalFixture()
  let source = fixture.root + "/LightenQA-" + UUID().uuidString
  let mover = MeasuredNativeTrash()
  defer {
    if let path = mover.path, FileManager.default.fileExists(atPath: path),
      !FileManager.default.fileExists(atPath: source)
    {
      try? FileManager.default.moveItem(atPath: path, toPath: source)
    }
    fixture.remove()
  }
  try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: false)
  for index in 0..<50_000 {
    let fd = open(source + "/file-" + String(index), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw FileSystemFailure.invalidPath }
    close(fd)
  }
  let plan = try await fixture.plan(paths: [source])
  #expect(plan.items[0].inventory.count == 50_001)
  let journal = JSONLActionJournal(path: fixture.journalPath)
  let result = try await ActionExecutor(journal: journal, trash: mover).execute(plan)
  #expect(result.items[0].outcome == .applied)
  let journalBytes = try Data(contentsOf: URL(fileURLWithPath: fixture.journalPath)).count
  let clock = ContinuousClock()
  let historyStart = clock.now
  let cold = try await ActionHistory(journal: JSONLActionJournal(path: fixture.journalPath)).reconcile()
  let historyDuration = historyStart.duration(to: clock.now)
  #expect(cold.plans.count == 1)
  #expect(cold.plans[0].state == .inTrash)
  #expect(journalBytes <= 65_536)
  #expect(historyDuration <= .milliseconds(200))

  let nextPath = fixture.root + "/next"
  try Data("next".utf8).write(to: URL(fileURLWithPath: nextPath))
  let next = try await fixture.plan(paths: [nextPath])
  let lease = try await journal.acquireMutationLease()
  let appendStart = clock.now
  try await journal.append(JournalRecord(kind: .intent, planID: next.id, plan: next))
  let appendDuration = appendStart.duration(to: clock.now)
  await journal.releaseMutationLease(lease)
  #expect(appendDuration <= .milliseconds(20))
  try await ActionHistory(journal: journal).undo(planID: plan.id)
  #expect(try FileManager.default.contentsOfDirectory(atPath: source).count == 50_000)
  print(
    "Journal measurement: files=50000 journalBytes=\(journalBytes) coldHistory=\(historyDuration) nextIntentAppend=\(appendDuration)"
  )
}

@Test(
  "A single append stays fast after one hundred actions",
  .enabled(if: ProcessInfo.processInfo.environment["LIGHTEN_JOURNAL_BENCH"] == "1"))
func journalOneHundredActionsAppendMeasurement() async throws {
  let fixture = try JournalFixture()
  defer { fixture.remove() }
  let source = fixture.root + "/source"
  try Data("history append".utf8).write(to: URL(fileURLWithPath: source))
  let original = try await fixture.plan(paths: [source])
  let journal = JSONLActionJournal(path: fixture.journalPath)
  let lease = try await journal.acquireMutationLease()
  var lastPlan = original
  for index in 0..<100 {
    let plan = ActionPlan(snapshotRunID: original.snapshotRunID, kind: .trash, items: original.items)
    try await journal.append(JournalRecord(kind: .intent, planID: plan.id, plan: plan))
    if index < 99 {
      try await journal.append(JournalRecord(kind: .failed, planID: plan.id, itemID: plan.items[0].id))
    }
    lastPlan = plan
  }
  await journal.releaseMutationLease(lease)
  // Include parsing the compact history for an instance that has not read it before.
  let coldJournal = JSONLActionJournal(path: fixture.journalPath)
  let coldLease = try await coldJournal.acquireMutationLease()
  let clock = ContinuousClock()
  let start = clock.now
  try await coldJournal.append(JournalRecord(kind: .failed, planID: lastPlan.id, itemID: lastPlan.items[0].id))
  let duration = start.duration(to: clock.now)
  await coldJournal.releaseMutationLease(coldLease)
  #expect(duration <= .milliseconds(5))
  print("Journal measurement: actions=100 coldSingleAppend=\(duration)")
}
