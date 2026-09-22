import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private enum TestFailure: Error { case injected }

private actor TestJournal: ActionJournal {
  private var records: [JournalRecord] = []
  private var failing: JournalEventKind?
  private var lease: JournalLease?
  private var leaseFailure = false
  private var afterAppend: (@Sendable (JournalRecord) async throws -> Void)?

  init(failing: JournalEventKind? = nil) { self.failing = failing }

  func setFailure(_ kind: JournalEventKind?) { failing = kind }
  func setLeaseFailure(_ enabled: Bool) { leaseFailure = enabled }
  func setAppendHook(_ hook: (@Sendable (JournalRecord) async throws -> Void)?) {
    afterAppend = hook
  }

  func acquireMutationLease() throws -> JournalLease {
    guard lease == nil, !leaseFailure else { throw JournalFailure.leaseBusy }
    let acquired = JournalLease()
    lease = acquired
    return acquired
  }

  func releaseMutationLease(_ acquired: JournalLease) {
    if lease == acquired { lease = nil }
  }

  func append(_ record: JournalRecord) async throws {
    guard lease != nil else { throw JournalFailure.leaseRequired }
    if record.kind == failing { throw TestFailure.injected }
    records.append(record)
    try await afterAppend?(record)
  }

  func read() -> JournalReadout { JournalReadout(records: records, issues: []) }
}

private struct TestMover: TrashMoving {
  let move: @Sendable (String) async throws -> String
  func moveToTrash(path: String) async throws -> String { try await move(path) }
}

private actor StartSignal {
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    started = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }

  func wait() async {
    if started { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

private struct NativeTestMover: TrashMoving {
  func moveToTrash(path: String) async throws -> String {
    try await Task.detached {
      var returned: NSURL?
      try FileManager.default.trashItem(
        at: URL(fileURLWithPath: path), resultingItemURL: &returned)
      guard let returned else { throw TestFailure.injected }
      return (returned as URL).path
    }.value
  }
}

private func actionFixture() throws -> String {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
    throw FileSystemFailure.invalidPath
  }
  defer { free(resolved) }
  let root = String(cString: resolved) + "/lighten-test-action-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  return root
}

private func put(_ path: String, _ value: String = "fixture") throws {
  try Data(value.utf8).write(to: URL(fileURLWithPath: path))
}

private func makeAction(_ root: String, paths: [String]) async throws -> ActionPlan {
  let scan = try await ScanService().scan(rootPath: root)
  let ids = try paths.map { path in
    try #require(scan.entries.first { $0.path == path }).id
  }
  return try PlanService().makePlan(snapshot: scan, selectedIDs: Set(ids))
}

private func localMover(destination: String) -> TestMover {
  TestMover { path in
    let target = destination + "/" + (path as NSString).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: target)
    return target
  }
}

@Test func intentFailureLeavesEverySourceUntouched() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/item"
  try put(source)
  let action = try await makeAction(root, paths: [source])
  let journal = TestJournal(failing: .intent)
  let executor = ActionExecutor(
    journal: journal,
    trash: TestMover { _ in
      Issue.record("Trash called without durable intent")
      throw TestFailure.injected
    })
  await #expect(throws: TestFailure.self) { try await executor.execute(action) }
  #expect(FileManager.default.fileExists(atPath: source))
  #expect((await journal.read()).records.isEmpty)
}

@Test func catalogDeleteValueIsDeniedBeforeIntent() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/item"
  try put(source)
  let trashPlan = try await makeAction(root, paths: [source])
  let deletePlan = ActionPlan(
    snapshotRunID: trashPlan.snapshotRunID,
    kind: .catalogDelete, items: trashPlan.items)
  let journal = TestJournal()
  let executor = ActionExecutor(
    journal: journal,
    trash: TestMover { _ in
      Issue.record("catalog delete reached mover")
      throw TestFailure.injected
    })
  await #expect(throws: ExecutionFailure.self) { try await executor.execute(deletePlan) }
  #expect(FileManager.default.fileExists(atPath: source))
  #expect((await journal.read()).records.isEmpty)
}

@Test func changedVolumeIdentifierIsRejectedAtFinalGuard() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/item"
  try put(source)
  let action = try await makeAction(root, paths: [source])
  let original = action.items[0]
  let forged = PlanItem(
    id: original.id, sourcePath: original.sourcePath,
    volumeID: UUID(), inventory: original.inventory, ancestors: original.ancestors)
  #expect(throws: GuardFailure.self) { try ActionGuard().validate(forged) }
}

@Test func replayedPlanDoesNotAlterEarlierHistory() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let destination = root + "/local-trash"
  try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
  let source = root + "/item"
  try put(source)
  let plan = try await makeAction(root, paths: [source])
  let journal = JSONLActionJournal(path: root + "/journal.jsonl")
  let executor = ActionExecutor(journal: journal, trash: localMover(destination: destination))
  #expect((try await executor.execute(plan)).items.map(\.outcome) == [.applied])
  let before = try await journal.read()
  await #expect(throws: ExecutionFailure.self) { try await executor.execute(plan) }
  let after = try await journal.read()
  #expect(after.records == before.records)
  #expect((try await ActionHistory(journal: journal).reconcile()).items[0].state == .inTrash)
}

@Test func earlyStopReturnsAnOutcomeForEveryItem() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let destination = root + "/local-trash"
  try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
  let paths = ["first", "second", "third"].map { root + "/" + $0 }
  for path in paths { try put(path) }
  let plan = try await makeAction(root, paths: paths)
  let journal = TestJournal(failing: .applied)
  let result = try await ActionExecutor(
    journal: journal,
    trash: localMover(destination: destination)
  ).execute(plan)
  #expect(result.items.count == 3)
  #expect(result.items.map(\.outcome) == [.uncertain, .notAttempted, .notAttempted])
  #expect(FileManager.default.fileExists(atPath: paths[1]))
  #expect(FileManager.default.fileExists(atPath: paths[2]))
}

@Test func leaseFailurePreventsAnyUserMutation() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/item"
  try put(source)
  let plan = try await makeAction(root, paths: [source])
  let journal = TestJournal()
  await journal.setLeaseFailure(true)
  await #expect(throws: JournalFailure.self) {
    try await ActionExecutor(
      journal: journal,
      trash: TestMover { _ in
        Issue.record("Trash called without a mutation lease")
        throw TestFailure.injected
      }
    ).execute(plan)
  }
  #expect(FileManager.default.fileExists(atPath: source))
  #expect((await journal.read()).records.isEmpty)
}

@Test func injectedIntentFsyncFailurePreventsTrash() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/item"
  try put(source)
  let plan = try await makeAction(root, paths: [source])
  let calls = Mutex(0)
  let journal = JSONLActionJournal(
    path: root + "/journal.jsonl",
    syncFD: { fd in
      let number = calls.withLock { count in
        count += 1
        return count
      }
      if number == 3 { throw JournalFailure.systemCall("injected fsync", EIO) }
      guard fsync(fd) == 0 else { throw JournalFailure.systemCall("fsync", errno) }
    })
  await #expect(throws: JournalFailure.self) {
    try await ActionExecutor(
      journal: journal,
      trash: TestMover { _ in
        Issue.record("Trash called after failed intent fsync")
        throw TestFailure.injected
      }
    ).execute(plan)
  }
  #expect(calls.withLock { $0 } >= 3)
  #expect(FileManager.default.fileExists(atPath: source))
}

@Test func newlyCreatedJournalDirectoriesAreSynced() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let calls = Mutex(0)
  let journal = JSONLActionJournal(
    path: root + "/new/deeper/journal.jsonl",
    syncFD: { fd in
      calls.withLock { $0 += 1 }
      guard fsync(fd) == 0 else { throw JournalFailure.systemCall("fsync", errno) }
    })
  let lease = try await journal.acquireMutationLease()
  await journal.releaseMutationLease(lease)
  #expect(calls.withLock { $0 } >= 6)
  #expect(FileManager.default.fileExists(atPath: root + "/new/deeper/journal.jsonl.lock"))
}

@Test func symlinkedJournalOrLockCannotAuthorizeTrash() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/item"
  try put(source)
  let plan = try await makeAction(root, paths: [source])
  let ordinary = root + "/ordinary"
  try put(ordinary)
  let path = root + "/journal.jsonl"
  try FileManager.default.createSymbolicLink(atPath: path + ".lock", withDestinationPath: ordinary)
  await #expect(throws: JournalFailure.self) {
    try await ActionExecutor(
      journal: JSONLActionJournal(path: path),
      trash: TestMover { _ in
        Issue.record("symlinked lock reached Trash")
        throw TestFailure.injected
      }
    ).execute(plan)
  }
  try FileManager.default.removeItem(atPath: path + ".lock")
  try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: ordinary)
  await #expect(throws: JournalFailure.self) {
    try await ActionExecutor(
      journal: JSONLActionJournal(path: path),
      trash: TestMover { _ in
        Issue.record("symlinked journal reached Trash")
        throw TestFailure.injected
      }
    ).execute(plan)
  }
  #expect(FileManager.default.fileExists(atPath: source))
}

@Test func separateJournalInstancesRejectOverlappingLease() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/journal.jsonl"
  let first = JSONLActionJournal(path: path)
  let second = JSONLActionJournal(path: path)
  let held = try await first.acquireMutationLease()
  await #expect(throws: JournalFailure.self) { try await second.acquireMutationLease() }
  await first.releaseMutationLease(held)
  let next = try await second.acquireMutationLease()
  await second.releaseMutationLease(next)
}

@Test func executorAndUndoCannotOverlapOnSharedJournal() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let destination = root + "/local-trash"
  try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
  let first = root + "/first"
  let second = root + "/second"
  try put(first)
  let journal = TestJournal()
  let firstPlan = try await makeAction(root, paths: [first])
  #expect(
    (try await ActionExecutor(
      journal: journal,
      trash: localMover(destination: destination)
    ).execute(firstPlan)).items.map(\.outcome) == [.applied])
  try put(second)
  let secondPlan = try await makeAction(root, paths: [second])
  let signal = StartSignal()
  let running = Task {
    try await ActionExecutor(
      journal: journal, trash: localMover(destination: destination),
      beforeMutation: { _ in
        await signal.signal()
        try await Task.sleep(for: .milliseconds(200))
      }
    ).execute(secondPlan)
  }
  await signal.wait()
  await #expect(throws: JournalFailure.self) {
    try await ActionHistory(journal: journal).undo(
      planID: firstPlan.id,
      itemID: firstPlan.items[0].id)
  }
  #expect(FileManager.default.fileExists(atPath: destination + "/first"))
  #expect((try await running.value).items.map(\.outcome) == [.applied])
  try await ActionHistory(journal: journal).undo(
    planID: firstPlan.id,
    itemID: firstPlan.items[0].id)
  #expect(FileManager.default.fileExists(atPath: first))
}

@Test func twoExecutorsCannotClaimTheSamePlanConcurrently() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let destination = root + "/local-trash"
  try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
  let source = root + "/item"
  try put(source)
  let plan = try await makeAction(root, paths: [source])
  let journal = TestJournal()
  let signal = StartSignal()
  let first = Task {
    try await ActionExecutor(
      journal: journal, trash: localMover(destination: destination),
      beforeMutation: { _ in
        await signal.signal()
        try await Task.sleep(for: .milliseconds(200))
      }
    ).execute(plan)
  }
  await signal.wait()
  await #expect(throws: JournalFailure.self) {
    try await ActionExecutor(
      journal: journal,
      trash: localMover(destination: destination)
    ).execute(plan)
  }
  #expect((try await first.value).items.map(\.outcome) == [.applied])
  #expect((await journal.read()).records.filter { $0.kind == .intent }.count == 1)
}

@Test func externalProcessLockRejectsMutation() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let journal = JSONLActionJournal(path: root + "/journal.jsonl")
  let initial = try await journal.acquireMutationLease()
  await journal.releaseMutationLease(initial)
  let child = Process()
  child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  child.arguments = [
    "-c",
    "import fcntl,os,sys; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX); print('READY',flush=True); sys.stdin.readline()",
    root + "/journal.jsonl.lock",
  ]
  let input = Pipe()
  let output = Pipe()
  child.standardInput = input
  child.standardOutput = output
  try child.run()
  let ready = output.fileHandleForReading.readData(ofLength: 6)
  #expect(String(decoding: ready, as: UTF8.self) == "READY\n")
  await #expect(throws: JournalFailure.self) { try await journal.acquireMutationLease() }
  input.fileHandleForWriting.write(Data("\n".utf8))
  child.waitUntilExit()
  #expect(child.terminationStatus == 0)
  let after = try await journal.acquireMutationLease()
  await journal.releaseMutationLease(after)
}

@Test func malformedJournalEventsRemainVisibleAndBlockMutation() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/item"
  try put(source)
  let plan = try await makeAction(root, paths: [source])
  let path = root + "/journal.jsonl"
  let journal = JSONLActionJournal(path: path)
  try await journal.withMutationLease {
    try await journal.append(JournalRecord(kind: .intent, planID: plan.id, plan: plan))
  }
  let invalid: [JournalRecord] = [
    JournalRecord(kind: .intent, planID: UUID()),
    JournalRecord(kind: .applied, planID: plan.id, itemID: plan.items[0].id),
    JournalRecord(kind: .failed, planID: plan.id, itemID: UUID()),
    JournalRecord(kind: .intent, planID: plan.id, plan: plan),
  ]
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
  try handle.seekToEnd()
  for record in invalid {
    var line = try JSONEncoder().encode(record)
    line.append(0x0A)
    try handle.write(contentsOf: line)
  }
  try handle.close()
  let readout = try await journal.read()
  #expect(readout.records.count == 1)
  #expect(readout.issues.count == 4)
  await #expect(throws: ExecutionFailure.self) {
    try await ActionExecutor(
      journal: journal,
      trash: TestMover { _ in
        Issue.record("corrupt history reached Trash")
        throw TestFailure.injected
      }
    ).execute(plan)
  }
  #expect(FileManager.default.fileExists(atPath: source))
}

@Test func parentRenameDuringUndoIntentStopsRestore() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let parent = root + "/parent"
  let destination = root + "/local-trash"
  try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
  let source = parent + "/item"
  try put(source)
  let plan = try await makeAction(root, paths: [source])
  let journal = TestJournal()
  #expect(
    (try await ActionExecutor(
      journal: journal,
      trash: localMover(destination: destination)
    ).execute(plan)).items.map(\.outcome) == [.applied])
  await journal.setAppendHook { record in
    if record.kind == .undoIntent {
      try FileManager.default.moveItem(atPath: parent, toPath: root + "/moved-parent")
    }
  }
  await #expect(throws: UndoFailure.self) {
    try await ActionHistory(journal: journal).undo(planID: plan.id, itemID: plan.items[0].id)
  }
  #expect(FileManager.default.fileExists(atPath: destination + "/item"))
  #expect(!FileManager.default.fileExists(atPath: root + "/moved-parent/item"))
}

@Test func twoSiblingsContinueAfterParentCtimeChanges() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let trash = root + "/local-trash"
  try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
  let first = root + "/first"
  let second = root + "/second"
  try put(first)
  try put(second)
  let action = try await makeAction(root, paths: [first, second])
  let journal = TestJournal()
  let result = try await ActionExecutor(journal: journal, trash: localMover(destination: trash))
    .execute(action)
  #expect(result.items.map(\.outcome) == [.applied, .applied])
  #expect(FileManager.default.fileExists(atPath: trash + "/first"))
  #expect(FileManager.default.fileExists(atPath: trash + "/second"))
}

@Test func finalHookRejectsChangedRootAndNewProtectedChild() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let folder = root + "/folder"
  try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
  try put(folder + "/old")
  let action = try await makeAction(root, paths: [folder])
  let journal = TestJournal()
  let result = try await ActionExecutor(
    journal: journal,
    trash: TestMover { _ in
      Issue.record("unsafe folder moved")
      throw TestFailure.injected
    },
    beforeMutation: { _ in
      try FileManager.default.createDirectory(
        atPath: folder + "/en.lproj",
        withIntermediateDirectories: true)
    }
  )
  .execute(action)
  #expect(result.items.map(\.outcome) == [.skipped])
  #expect(FileManager.default.fileExists(atPath: folder))
  #expect((await journal.read()).records.last?.kind == .skipped)

  let file = root + "/file"
  try put(file)
  let second = try await makeAction(root, paths: [file])
  let result2 = try await ActionExecutor(
    journal: TestJournal(),
    trash: TestMover { _ in
      Issue.record("changed file moved")
      throw TestFailure.injected
    },
    beforeMutation: { _ in try put(file, "changed") }
  )
  .execute(second)
  #expect(result2.items.map(\.outcome) == [.skipped])
}

@Test func finalHookRejectsAncestorSymlinkSwap() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let parent = root + "/parent"
  try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
  let source = parent + "/item"
  try put(source)
  let action = try await makeAction(root, paths: [source])
  let result = try await ActionExecutor(
    journal: TestJournal(),
    trash: TestMover { _ in
      Issue.record("ancestor symlink reached Trash")
      throw TestFailure.injected
    },
    beforeMutation: { _ in
      try FileManager.default.moveItem(atPath: parent, toPath: root + "/original-parent")
      try FileManager.default.createSymbolicLink(
        atPath: parent,
        withDestinationPath: root + "/original-parent")
    }
  ).execute(action)
  #expect(result.items.map(\.outcome) == [.skipped])
  #expect(FileManager.default.fileExists(atPath: root + "/original-parent/item"))
}

@Test func throwingMoverAfterMoveIsUncertain() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/item"
  let target = root + "/moved"
  try put(source)
  let action = try await makeAction(root, paths: [source])
  let journal = TestJournal()
  let result = try await ActionExecutor(
    journal: journal,
    trash: TestMover { path in
      try FileManager.default.moveItem(atPath: path, toPath: target)
      throw TestFailure.injected
    }
  ).execute(action)
  #expect(result.items.map(\.outcome) == [.uncertain])
  #expect(FileManager.default.fileExists(atPath: target))
  #expect((await journal.read()).records.map(\.kind) == [.intent])
}

@Test func partialOutcomeAndAppliedWriteFailure() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let trash = root + "/local-trash"
  try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
  let first = root + "/first"
  let second = root + "/second"
  try put(first)
  try put(second)
  let action = try await makeAction(root, paths: [first, second])
  let journal = TestJournal()
  let mover = TestMover { path in
    if path == first { throw TestFailure.injected }
    return try await localMover(destination: trash).moveToTrash(path: path)
  }
  let result = try await ActionExecutor(journal: journal, trash: mover).execute(action)
  #expect(result.items.map(\.outcome) == [.failed, .applied])
  #expect(FileManager.default.fileExists(atPath: first))
  #expect(FileManager.default.fileExists(atPath: trash + "/second"))

  let third = root + "/third"
  try put(third)
  let next = try await makeAction(root, paths: [third])
  let failing = TestJournal(failing: .applied)
  let uncertain = try await ActionExecutor(
    journal: failing,
    trash: localMover(destination: trash)
  ).execute(next)
  #expect(uncertain.items.map(\.outcome) == [.uncertain])
  #expect(!FileManager.default.fileExists(atPath: third))
  #expect((await failing.read()).records.map(\.kind) == [.intent])
  let restart = try await ActionHistory(journal: failing).reconcile()
  #expect(restart.items[0].state == .uncertain)
}

@Test func successfulMoveWithUnobservableResultIsUncertain() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/one"
  let destination = root + "/moved"
  try put(source)
  let action = try await makeAction(root, paths: [source])
  let journal = TestJournal()
  let mover = TestMover { path in
    try FileManager.default.moveItem(atPath: path, toPath: destination)
    return root + "/unobservable"
  }
  let result = try await ActionExecutor(journal: journal, trash: mover).execute(action)
  #expect(result.items.map(\.outcome) == [.uncertain])
  #expect(FileManager.default.fileExists(atPath: destination))
  #expect((await journal.read()).records.map(\.kind) == [.intent])
}

@Test func nativeTrashCollisionUndoAndRestart() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let left = root + "/left"
  let right = root + "/right"
  try FileManager.default.createDirectory(atPath: left, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: right, withIntermediateDirectories: true)
  let name = "lighten-test-" + UUID().uuidString
  let a = left + "/" + name
  let b = right + "/" + name
  try put(a, "a")
  try put(b, "b")
  let action = try await makeAction(root, paths: [a, b])
  let journalPath = root + "/actions.jsonl"
  let journal = JSONLActionJournal(path: journalPath)
  let result = try await ActionExecutor(journal: journal, trash: NativeTestMover())
    .execute(action)
  #expect(result.items.map(\.outcome) == [.applied, .applied])
  let records = (try await journal.read()).records
  let applied = records.filter { $0.kind == .applied }
  #expect(applied.count == 2)
  let paths = applied.compactMap(\.returnedTrashPath)
  #expect(Set(paths).count == 2)
  #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
  let history = ActionHistory(journal: JSONLActionJournal(path: journalPath))
  let before = try await history.reconcile()
  #expect(before.items.map(\.state) == [.inTrash, .inTrash])
  try put(a, "collision")
  let aID = try #require(action.items.first { $0.sourcePath == a }).id
  await #expect(throws: UndoFailure.self) { try await history.undo(planID: action.id, itemID: aID) }
  #expect(FileManager.default.fileExists(atPath: a))
  #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
  try FileManager.default.removeItem(atPath: a)
  for item in action.items {
    try await history.undo(planID: action.id, itemID: item.id)
  }
  #expect(FileManager.default.fileExists(atPath: a))
  #expect(FileManager.default.fileExists(atPath: b))
  #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
  #expect(
    (try await ActionHistory(journal: JSONLActionJournal(path: journalPath))
      .reconcile()).items.map(\.state) == [.reversed, .reversed])
}

@Test func undoIntentFailurePreventsRestoreAndReconcileTracksCrashWindow() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/item"
  let trash = root + "/moved"
  try put(source)
  let action = try await makeAction(root, paths: [source])
  let journal = TestJournal()
  let mover = TestMover { path in
    try FileManager.default.moveItem(atPath: path, toPath: trash)
    return trash
  }
  #expect(
    (try await ActionExecutor(journal: journal, trash: mover)
      .execute(action)).items.map(\.outcome) == [.applied])
  let history = ActionHistory(journal: journal)
  await journal.setFailure(.undoIntent)
  await #expect(throws: TestFailure.self) {
    try await history.undo(planID: action.id, itemID: action.items[0].id)
  }
  #expect(!FileManager.default.fileExists(atPath: source))
  #expect(FileManager.default.fileExists(atPath: trash))
  await journal.setFailure(.reversed)
  await #expect(throws: TestFailure.self) {
    try await history.undo(planID: action.id, itemID: action.items[0].id)
  }
  #expect(FileManager.default.fileExists(atPath: source))
  #expect(!FileManager.default.fileExists(atPath: trash))
  let restart = try await ActionHistory(journal: journal).reconcile()
  #expect(restart.items[0].state == .reversed)
  #expect((await journal.read()).records.last?.kind == .undoIntent)
}

@Test func journalRetainsCorruptAndUnknownSchemaEvidence() async throws {
  let root = try actionFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/journal.jsonl"
  let journal = JSONLActionJournal(path: path)
  let source = root + "/item"
  try put(source)
  let plan = try await makeAction(root, paths: [source])
  try await journal.withMutationLease {
    try await journal.append(JournalRecord(kind: .intent, planID: plan.id, plan: plan))
  }
  var text = try String(contentsOfFile: path, encoding: .utf8)
  text += "{\"schema\":99}\n{broken"
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  let readout = try await journal.read()
  #expect(readout.records.count == 1)
  #expect(readout.issues.count == 2)
  await #expect(throws: JournalFailure.self) {
    try await journal.withMutationLease {
      try await journal.append(
        JournalRecord(
          kind: .failed, planID: plan.id,
          itemID: plan.items[0].id))
    }
  }
}
