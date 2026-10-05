import Darwin
import Foundation
import LightenKit
import Synchronization
import Testing

@testable import Lighten

private enum GateFailure: Error { case injected }

private struct DuplicateFixtureApplicationActivity: ApplicationActivitySource {
  func activity(applicationPath: String) async -> ApplicationActivity {
    ApplicationActivity(state: .clearObservedProcesses)
  }
}

private struct LocalDuplicateMover: TrashMoving {
  let destination: String

  func moveToTrash(path: String) async throws -> String {
    let target = destination + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: target)
    return target
  }
}

private actor PlanGate {
  private var requests: [CheckedContinuation<ActionPlan, Error>] = []
  private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
  private var received = 0

  func next() async throws -> ActionPlan {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(continuation)
      received += 1
      let ready = waiting.filter { received >= $0.0 }
      waiting.removeAll { received >= $0.0 }
      for (_, waiter) in ready { waiter.resume() }
    }
  }

  func waitForRequest(_ count: Int) async {
    if received >= count { return }
    await withCheckedContinuation { waiting.append((count, $0)) }
  }

  func finish(_ result: Result<ActionPlan, Error>) {
    guard !requests.isEmpty else { return }
    requests.removeFirst().resume(with: result)
  }
}

@Test("Stale duplicate preparation cannot present a result or error")
@MainActor func staleDuplicatePreparationIsDiscarded() async throws {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw GateFailure.injected }
  defer { free(resolved) }
  let root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: root) }
  for name in ["a", "b"] {
    try Data("same".utf8).write(to: URL(fileURLWithPath: root + "/" + name))
  }
  var report: DuplicateReport?
  for try await event in DuplicateService().events(rootPath: root) {
    if case .completed(let value) = event { report = value }
  }
  let found = try #require(report)
  let group = try #require(found.groups.first)
  let keeper = try #require(group.members.first)
  let target = try #require(group.members.first { $0.id != keeper.id })
  let validPlan = try await DuplicateService().makePlan(
    report: found, groupID: group.id, keeperID: keeper.id, targetIDs: [target.id])
  let gate = PlanGate()
  let domain = "LightenQA." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: domain))
  defer { defaults.removePersistentDomain(forName: domain) }
  let store = DuplicateStore(
    planBuilder: { _, _ in try await gate.next() }, preferences: RemovalPreferences(defaults: defaults),
    pictures: ResultPictureStore(directory: root + "/results", maximumBytes: 0))
  let trashDirectory = root + "/trash"
  try FileManager.default.createDirectory(atPath: trashDirectory, withIntermediateDirectories: true)
  let actions = ActionStore(
    journal: JSONLActionJournal(path: root + "/journal.jsonl"),
    trash: LocalDuplicateMover(destination: trashDirectory),
    applicationActivity: DuplicateFixtureApplicationActivity())
  store.report = found
  store.tool.phase = .ready
  store.chooseKeeper(keeper.id, for: group, actions: actions)
  store.toggleTarget(target.id, in: group, actions: actions)

  let staleResult = Task { await store.prepare(actions: actions) }
  await gate.waitForRequest(1)
  store.toggleTarget(target.id, in: group, actions: actions)
  store.toggleTarget(target.id, in: group, actions: actions)
  await gate.finish(.success(validPlan))
  await staleResult.value
  #expect(actions.pending == nil)
  #expect(store.message == nil)
  #expect(!store.preparing)

  let staleError = Task { await store.prepare(actions: actions) }
  await gate.waitForRequest(2)
  store.deactivate(actions: actions)
  await gate.finish(.failure(GateFailure.injected))
  await staleError.value
  #expect(actions.pending == nil)
  #expect(store.message == nil)

  let latest = Task { await store.prepare(actions: actions) }
  await gate.waitForRequest(3)
  await gate.finish(.success(validPlan))
  await latest.value
  #expect(actions.pending?.plan == validPlan)
  #expect(store.presentedPlanID == validPlan.id)

  let presentation = try #require(actions.pending)
  let confirmed = try #require(actions.takeConfirmedPlan(presentation))
  store.deactivate(actions: actions)
  #expect(store.presentedPlanID == validPlan.id)
  await actions.executeConfirmed(confirmed)
  #expect(actions.result?.items.map(\.outcome) == [.applied])
  store.observeResult(actions: actions)
  #expect(!store.needsRescan)
  #expect(store.targets.isEmpty)
  #expect(store.keepers.isEmpty)
  #expect(store.presentedPlanID == validPlan.id)
  #expect(actions.pending == nil)
}

@MainActor private struct DuplicatePictureFixture {
  let root: String
  let domain: String
  let defaults: UserDefaults
  let preferences: RemovalPreferences
  var pictures: ResultPictureStore { ResultPictureStore(directory: root + "/results") }

  init() throws {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw GateFailure.injected }
    defer { free(resolved) }
    root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    domain = "LightenQA." + UUID().uuidString
    defaults = try #require(UserDefaults(suiteName: domain))
    preferences = RemovalPreferences(defaults: defaults)
  }

  func remove() {
    defaults.removePersistentDomain(forName: domain)
    try? FileManager.default.removeItem(atPath: root)
  }

  func actions() -> ActionStore {
    ActionStore(
      journal: JSONLActionJournal(path: root + "/journal.jsonl"),
      trash: LocalDuplicateMover(destination: root + "/trash"),
      applicationActivity: DuplicateFixtureApplicationActivity())
  }

  func report(names: [String] = ["a", "b", "c"], partial: Bool = false) -> DuplicateReport {
    let entries = names.map { name in
      ScanEntry(parentID: nil, path: root + "/" + name, identity: nil, issues: [], readable: true)
    }
    return DuplicateReport(
      snapshot: ScanSnapshot(rootPath: root, volumeDevice: 0, entries: entries, nodes: []),
      groups: entries.isEmpty
        ? []
        : [
          DuplicateGroup(
            logicalBytes: 64, members: entries.map { DuplicateMember(entry: $0, eligibility: .metadataUnknown) })
        ],
      skippedCount: partial ? 2 : 0, partial: partial, comparisonCount: entries.count)
  }
}

private final class DuplicateEventGate: Sendable {
  private struct State {
    var streams: [AsyncThrowingStream<DuplicateEvent, Error>.Continuation] = []
    var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
  }
  private let state = Mutex(State())

  func next(_ path: String) -> AsyncThrowingStream<DuplicateEvent, Error> {
    let (stream, continuation) = AsyncThrowingStream<DuplicateEvent, Error>.makeStream()
    let waiters = state.withLock { state in
      state.streams.append(continuation)
      let ready = state.waiters.filter { state.streams.count >= $0.0 }
      state.waiters.removeAll { state.streams.count >= $0.0 }
      return ready.map(\.1)
    }
    for waiter in waiters { waiter.resume() }
    return stream
  }

  var count: Int { state.withLock { $0.streams.count } }

  func waitForRequest(_ count: Int) async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state in
        if state.streams.count >= count { return true }
        state.waiters.append((count, continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  }

  func complete(_ index: Int, report: DuplicateReport) {
    let continuation = state.withLock { $0.streams[index] }
    continuation.yield(.completed(report))
    continuation.finish()
  }

  func fail(_ index: Int) { state.withLock { $0.streams[index] }.finish(throwing: GateFailure.injected) }
}

// The injected synchronous disk operation blocks only the dedicated native IO queue.
private final class DuplicatePictureIOGate: Sendable {
  private struct State {
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
  }
  private let state = Mutex(State())
  private let signal = DispatchSemaphore(value: 0)

  func block() {
    #expect(!Thread.isMainThread)
    let waiter = state.withLock { state in
      state.entered = true
      let waiter = state.waiter
      state.waiter = nil
      return waiter
    }
    waiter?.resume()
    signal.wait()
  }

  func waitForArrival() async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state in
        if state.entered { return true }
        state.waiter = continuation
        return false
      }
      if ready { continuation.resume() }
    }
  }
  func release() { signal.signal() }
}

@Test(
  "Duplicates cold opening keeps empty and partial pictures separate from fresh evidence", arguments: [false, true])
@MainActor func duplicateColdPictureHasNoAuthority(empty: Bool) async throws {
  let fixture = try DuplicatePictureFixture()
  defer { fixture.remove() }
  let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
  let report = fixture.report(names: empty ? [] : ["a", "b"], partial: true)
  let content = DuplicatePicture(report)
  try fixture.pictures.save(ResultPicture(observedAt: observedAt, content: content), named: "duplicates")
  let scans = DuplicateEventGate()
  let planCalls = Mutex(0)
  let store = DuplicateStore(
    planBuilder: { _, _ in
      planCalls.withLock { $0 += 1 }
      throw GateFailure.injected
    }, preferences: fixture.preferences, pictures: fixture.pictures, events: { scans.next($0) })
  store.open()
  await store.waitForPicture()
  store.open()
  #expect(store.picture?.content == content && store.picture?.observedAt == observedAt)
  #expect(store.folderPath == fixture.root && store.report == nil && store.scannedAt == nil)
  #expect(store.keepers.isEmpty && store.targets.isEmpty && store.phase == .idle)
  #expect(store.toolSummary.observedAt == observedAt && store.toolSummary.partial)
  #expect(!store.tool.allowsPreparation && scans.count == 0)
  store.tool.phase = .ready
  store.targets = [UUID()]
  store.keepers = [UUID(): UUID()]
  await store.prepare(actions: fixture.actions())
  #expect(planCalls.withLock { $0 } == 0 && !store.preparing)
}

@Test("A held duplicate picture load neither blocks a fresh scan nor replaces its report")
@MainActor func duplicateLatePictureLoadIsDiscarded() async throws {
  let fixture = try DuplicatePictureFixture()
  defer { fixture.remove() }
  let io = DuplicatePictureIOGate()
  defer { io.release() }
  let scans = DuplicateEventGate()
  let old = ResultPicture(
    observedAt: Date(timeIntervalSince1970: 1_700_000_000), content: DuplicatePicture(fixture.report()))
  let store = DuplicateStore(
    preferences: fixture.preferences, pictures: fixture.pictures,
    loadPicture: {
      io.block()
      return old
    }, events: { scans.next($0) })
  store.open()
  await io.waitForArrival()
  store.startScan(folder: fixture.root, actions: fixture.actions())
  await scans.waitForRequest(1)
  let fresh = fixture.report(names: ["new-a", "new-b"], partial: true)
  scans.complete(0, report: fresh)
  await store.waitForScan()
  #expect(store.report?.snapshot.runID == fresh.snapshot.runID && store.phase == .ready)
  #expect(store.picture == nil && store.scannedAt != nil && store.toolSummary.partial)
  io.release()
  await store.waitForPicture()
  await store.waitForPictureSaves()
  #expect(store.picture == nil)
  #expect(fixture.pictures.load(DuplicatePicture.self, named: "duplicates")?.content == DuplicatePicture(fresh))
  let group = try #require(fresh.groups.first)
  let keeper = try #require(group.members.first)
  store.chooseKeeper(keeper.id, for: group, actions: fixture.actions())
  #expect(store.keepers[group.id] == keeper.id)
}

@Test("Ordered duplicate saves retain the newest scan when an older write stalls")
@MainActor func duplicatePictureSavesKeepNewestResult() async throws {
  let fixture = try DuplicatePictureFixture()
  defer { fixture.remove() }
  let io = DuplicatePictureIOGate()
  defer { io.release() }
  let scans = DuplicateEventGate()
  let calls = Mutex(0)
  let pictures = fixture.pictures
  let store = DuplicateStore(
    preferences: fixture.preferences, pictures: pictures,
    savePicture: { picture in
      let first = calls.withLock {
        $0 += 1
        return $0 == 1
      }
      if first { io.block() }
      try pictures.save(picture, named: "duplicates")
    }, events: { scans.next($0) })
  store.startScan(folder: fixture.root)
  await scans.waitForRequest(1)
  scans.complete(0, report: fixture.report(names: ["old-a", "old-b"]))
  await store.waitForScan()
  await io.waitForArrival()
  store.startScan(folder: fixture.root)
  await scans.waitForRequest(2)
  let newest = fixture.report(names: ["new-a", "new-b"])
  scans.complete(1, report: newest)
  await store.waitForScan()
  let observedAt = store.scannedAt
  io.release()
  await store.waitForPictureSaves()
  let saved = try #require(pictures.load(DuplicatePicture.self, named: "duplicates"))
  #expect(saved.content == DuplicatePicture(newest) && saved.observedAt == observedAt)
}

@Test("A cancelled or failed duplicate scan cannot replace the previous successful picture", arguments: [false, true])
@MainActor func duplicateUnfinishedScanPreservesPicture(failed: Bool) async throws {
  let fixture = try DuplicatePictureFixture()
  defer { fixture.remove() }
  let old = ResultPicture(
    observedAt: Date(timeIntervalSince1970: 1_700_000_000), content: DuplicatePicture(fixture.report()))
  try fixture.pictures.save(old, named: "duplicates")
  let scans = DuplicateEventGate()
  let store = DuplicateStore(preferences: fixture.preferences, pictures: fixture.pictures, events: { scans.next($0) })
  store.startScan(folder: fixture.root)
  await scans.waitForRequest(1)
  if failed {
    scans.fail(0)
  } else {
    store.cancelScan()
    scans.complete(0, report: fixture.report(names: []))
  }
  await store.waitForScan()
  await store.waitForPictureSaves()
  #expect(store.phase == (failed ? .failed : .partial))
  #expect(!store.tool.allowsPreparation && store.targets.isEmpty && store.keepers.isEmpty)
  #expect(fixture.pictures.load(DuplicatePicture.self, named: "duplicates")?.content == old.content)
}

@Test("A superseded duplicate scan cannot publish or persist a late completion")
@MainActor func duplicateSupersededScanCannotPublish() async throws {
  let fixture = try DuplicatePictureFixture()
  defer { fixture.remove() }
  let scans = DuplicateEventGate()
  let store = DuplicateStore(preferences: fixture.preferences, pictures: fixture.pictures, events: { scans.next($0) })
  store.startScan(folder: fixture.root)
  await scans.waitForRequest(1)
  store.startScan(folder: fixture.root)
  await scans.waitForRequest(2)
  let newest = fixture.report(names: ["new-a", "new-b"])
  scans.complete(1, report: newest)
  await store.waitForScan()
  scans.complete(0, report: fixture.report(names: ["old-a", "old-b"]))
  await store.waitForPictureSaves()
  #expect(store.report?.snapshot.runID == newest.snapshot.runID)
  #expect(fixture.pictures.load(DuplicatePicture.self, named: "duplicates")?.content == DuplicatePicture(newest))
}

@Test("A completed empty duplicate scan clears old groups and reopens without authority")
@MainActor func duplicateEmptyFreshResultRoundTrip() async throws {
  let fixture = try DuplicatePictureFixture()
  defer { fixture.remove() }
  try fixture.pictures.save(
    ResultPicture(observedAt: Date(timeIntervalSince1970: 1_700_000_000), content: DuplicatePicture(fixture.report())),
    named: "duplicates")
  let scans = DuplicateEventGate()
  let store = DuplicateStore(preferences: fixture.preferences, pictures: fixture.pictures, events: { scans.next($0) })
  store.startScan(folder: fixture.root)
  await scans.waitForRequest(1)
  scans.complete(0, report: fixture.report(names: []))
  await store.waitForScan()
  await store.waitForPictureSaves()
  let reopened = DuplicateStore(
    preferences: fixture.preferences, pictures: fixture.pictures, events: { scans.next($0) })
  reopened.open()
  await reopened.waitForPicture()
  #expect(reopened.picture?.content.groups.isEmpty == true && reopened.picture?.observedAt == store.scannedAt)
  #expect(reopened.report == nil && !reopened.tool.allowsPreparation && scans.count == 1)
}

@Test("Duplicate picture display changes and Undo persist presentation without manufacturing evidence")
@MainActor func duplicatePictureDisplayChangeAndUndo() async throws {
  let fixture = try DuplicatePictureFixture()
  defer { fixture.remove() }
  let old = ResultPicture(
    observedAt: Date(timeIntervalSince1970: 1_700_000_000), content: DuplicatePicture(fixture.report()))
  try fixture.pictures.save(old, named: "duplicates")
  let store = DuplicateStore(preferences: fixture.preferences, pictures: fixture.pictures)
  store.open()
  await store.waitForPicture()
  let item = ActionDisplayItem(
    planID: UUID(), itemID: UUID(), path: fixture.root + "/a", identity: nil,
    size: ObservedPlanSize(logical: ByteAggregate(knownLowerBound: 64, completeTotal: 64), allocated: nil),
    label: "a", returnedTrashPath: nil)
  store.applyDisplayChange(ActionDisplayChange(kind: .applied, items: [item]))
  await store.waitForPictureSaves()
  #expect(store.picture?.content.groups.first?.members.count == 2 && store.report == nil)
  #expect(store.picture?.observedAt == old.observedAt && !store.tool.allowsPreparation)
  store.applyDisplayChange(ActionDisplayChange(kind: .restored, items: [item]))
  await store.waitForPictureSaves()
  #expect(store.picture?.content == old.content && store.report == nil)
  let reopened = DuplicateStore(preferences: fixture.preferences, pictures: fixture.pictures)
  reopened.open()
  await reopened.waitForPicture()
  #expect(reopened.picture?.content == old.content && reopened.report == nil && reopened.targets.isEmpty)
}

@Test("An obsolete queued duplicate save is rejected after cancellation")
@MainActor func duplicateCancelledScanRejectsQueuedSave() async throws {
  let fixture = try DuplicatePictureFixture()
  defer { fixture.remove() }
  let old = ResultPicture(
    observedAt: Date(timeIntervalSince1970: 1_700_000_000), content: DuplicatePicture(fixture.report()))
  try fixture.pictures.save(old, named: "duplicates")
  let io = DuplicatePictureIOGate()
  defer { io.release() }
  let scans = DuplicateEventGate()
  let store = DuplicateStore(
    preferences: fixture.preferences, pictures: fixture.pictures,
    loadPicture: {
      io.block()
      return old
    }, events: { scans.next($0) })
  store.open()
  await io.waitForArrival()
  store.startScan(folder: fixture.root)
  await scans.waitForRequest(1)
  scans.complete(0, report: fixture.report(names: []))
  await store.waitForScan()
  store.startScan(folder: fixture.root)
  await scans.waitForRequest(2)
  store.cancelScan()
  io.release()
  await store.waitForPicture()
  await store.waitForPictureSaves()
  #expect(fixture.pictures.load(DuplicatePicture.self, named: "duplicates")?.content == old.content)
}

@Test("A native duplicate scan persists its display while a reopened store has no scan evidence")
@MainActor func duplicateNativeScanPictureRoundTrip() async throws {
  let fixture = try DuplicatePictureFixture()
  defer { fixture.remove() }
  for name in ["a", "b"] {
    try Data("same".utf8).write(to: URL(fileURLWithPath: fixture.root + "/" + name))
  }
  let store = DuplicateStore(preferences: fixture.preferences, pictures: fixture.pictures)
  store.startScan(folder: fixture.root, actions: fixture.actions())
  await store.waitForScan()
  await store.waitForPictureSaves()
  let report = try #require(store.report)
  #expect(report.groups.count == 1 && store.tool.phase == .ready && store.picture == nil)
  let saved = try #require(fixture.pictures.load(DuplicatePicture.self, named: "duplicates"))
  #expect(saved.content == DuplicatePicture(report) && saved.observedAt == store.scannedAt)
  let reopened = DuplicateStore(preferences: fixture.preferences, pictures: fixture.pictures)
  reopened.open()
  await reopened.waitForPicture()
  #expect(reopened.picture?.content == saved.content && reopened.report == nil && !reopened.tool.allowsPreparation)
}
