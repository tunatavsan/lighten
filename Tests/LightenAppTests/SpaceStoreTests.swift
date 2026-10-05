import Darwin
import Foundation
import LightenKit
import Synchronization
import Testing

@testable import Lighten

@Suite("Space scan state")
struct SpaceStoreTests {
  private struct FixtureApplicationActivity: ApplicationActivitySource {
    func activity(applicationPath: String) async -> ApplicationActivity {
      ApplicationActivity(state: .clearObservedProcesses)
    }
  }

  @MainActor @Test("Space timing waits for positive current-appearance geometry after treemap calculation")
  func firstLayoutRequiresGeometryEndpoint() async throws {
    let root = "/private/tmp/LightenQA-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: root + "/data.bin"))
    let store = SpaceStore(cache: nil)
    store.selectRoot(URL(fileURLWithPath: root))
    store.startScan()
    try await waitForPhase(store, .complete)
    store.spaceDidAppear()
    store.updateLayout(width: 300, height: 200)
    _ = try await waitForLayout(store)
    #expect(store.firstLayoutMilliseconds == nil)
    let firstAppearance = try #require(store.appearanceToken)
    store.spaceDidLayout(appearance: firstAppearance, width: 0, height: 200)
    #expect(store.firstLayoutMilliseconds == nil)
    store.spaceDidLayout(appearance: firstAppearance, width: 300, height: 200)
    let measured = try #require(store.firstLayoutMilliseconds)
    store.spaceDidLayout(appearance: firstAppearance, width: 300, height: 200)
    #expect(store.firstLayoutMilliseconds == measured)
    // A ready cached layout at another appearance still needs its geometry callback.
    store.spaceDidAppear()
    #expect(store.layout != nil)
    #expect(store.firstLayoutMilliseconds == nil)
    store.spaceDidLayout(appearance: firstAppearance, width: 300, height: 200)
    #expect(store.firstLayoutMilliseconds == nil)
    store.spaceDidLayout(appearance: store.appearanceToken, width: 300, height: 200)
    #expect(store.firstLayoutMilliseconds != nil)
  }

  private actor RecordingMover: TrashMoving {
    let destination: String
    private(set) var moves = 0

    init(destination: String) { self.destination = destination }

    func moveToTrash(path: String) async throws -> String {
      moves += 1
      try FileManager.default.moveItem(atPath: path, toPath: destination)
      return destination
    }
  }

  @MainActor @Test("Confirmed plan executes once after the sheet clears pending state")
  func confirmationSurvivesDismissal() async throws {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
      Issue.record("temporary fixture root unavailable")
      return
    }
    defer { free(resolved) }
    let container = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
    let root = container + "/source"
    let source = root + "/inside.bin"
    let destination = container + "/returned.bin"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: container) }
    try Data(repeating: 7, count: 128).write(to: URL(fileURLWithPath: source))

    let run = try ScanEngine().start(root: root)
    await run.waitUntilFinished()
    let item = try #require(run.tree.children(of: run.tree.rootID, metric: .logical).first)
    let mover = RecordingMover(destination: destination)
    let store = ActionStore(
      journal: JSONLActionJournal(path: container + "/journal/actions-v1.jsonl"),
      trash: mover, applicationActivity: FixtureApplicationActivity())
    store.add(item)
    #expect(store.basket[item.path] != nil)
    await store.prepare(scanRoot: root, runID: run.runID)
    #expect(store.message == nil, "Fresh writable fixture should have no planning rejection")
    let presentation = try #require(
      store.pending, "basket=\(store.basket.count), busy=\(store.busy), message=\(store.message ?? "none")")
    #expect(presentation.plan.items.map(\.userSelection) == [true])
    #expect(presentation.plan.items.map { $0.inventory.count } == [1])
    let selectedRoot = try #require(presentation.plan.items.first?.inventory.first)
    #expect(selectedRoot.path == item.path && selectedRoot.parentID == nil)
    #expect(selectedRoot.identity?.device == item.device && selectedRoot.identity?.inode == item.inode)
    let confirmed = try #require(store.takeConfirmedPlan(presentation))
    store.pending = nil  // SwiftUI's sheet dismissal clears its binding.
    #expect(store.takeConfirmedPlan(presentation) == nil)
    let altered = ActionPlan(
      id: confirmed.id, snapshotRunID: confirmed.snapshotRunID,
      kind: .trash, createdAt: confirmed.createdAt, items: [])
    await store.executeConfirmed(altered)
    #expect(await mover.moves == 0)
    await store.executeConfirmed(confirmed)
    #expect(await mover.moves == 1)
    #expect(store.result?.items.map(\.outcome) == [.applied], "\(store.result?.items.map(\.detail) as Any)")
    #expect(store.basket.isEmpty)
    #expect(FileManager.default.fileExists(atPath: destination))
    #expect(!FileManager.default.fileExists(atPath: source))
    await store.executeConfirmed(confirmed)
    #expect(await mover.moves == 1)
  }

  @MainActor @Test("A new scan replaces the previous run and its late updates")
  func newScanReplacesRun() async throws {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
      Issue.record("temporary fixture root unavailable")
      return
    }
    defer { free(resolved) }
    let root = String(cString: resolved) + "/lighten-rescan-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root + "/folder", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try Data(repeating: 1, count: 64).write(to: URL(fileURLWithPath: root + "/folder/file"))
    let store = SpaceStore(cache: nil)
    store.selectRoot(URL(fileURLWithPath: root))
    store.startScan()
    let previous = try #require(store.currentScanRunID)
    let previousTree = store.tree
    store.startScan()
    #expect(previous != store.currentScanRunID)
    #expect(store.tree !== previousTree)
    try await waitForPhase(store, .complete)
    #expect(store.current?.logical.completeTotal == 64)
    #expect(store.tree?.runID == store.currentScanRunID)
  }

  @MainActor @Test("Other maps only remaining items and back rejects its stale layout")
  func otherLayoutAndBack() async throws {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
      Issue.record("temporary fixture root unavailable")
      return
    }
    defer { free(resolved) }
    let root = String(cString: resolved) + "/lighten-other-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    for number in 1...31 {
      try FileManager.default.createDirectory(atPath: root + "/item-\(number)", withIntermediateDirectories: true)
      try Data(repeating: UInt8(number), count: number).write(
        to: URL(fileURLWithPath: root + "/item-\(number)/data.bin"))
    }
    let store = SpaceStore(cache: nil)
    store.selectRoot(URL(fileURLWithPath: root))
    store.startScan()
    try await waitForPhase(store, .complete)
    let group = try #require(store.group)
    #expect(group.items.count == 24)
    #expect(group.other.count == 7)
    store.updateLayout(width: 400, height: 300)
    let top = try await waitForLayout(store)
    #expect(Set(top.tiles.map(\.id)) == Set(group.items.map(\.id) + [SpaceView.otherID]))

    store.selectedID = group.items.first?.id
    #expect(store.selected?.id == group.items.first?.id)
    store.showOther()
    #expect(store.selectedID == nil)
    store.updateLayout(width: 400, height: 300)
    let other = try await waitForLayout(store) { Set($0.tiles.map(\.id)) == Set(group.other.map(\.id)) }
    let first = try #require(group.other.first)
    let last = try #require(group.other.last)
    let firstArea = try #require(other.tiles.first(where: { $0.id == first.id })?.area)
    let lastArea = try #require(other.tiles.first(where: { $0.id == last.id })?.area)
    #expect(
      abs(firstArea / lastArea - Double(first.logical.knownLowerBound) / Double(last.logical.knownLowerBound))
        < 0.000001)

    store.back()
    #expect(!store.showingOther)
    let returned = try await waitForLayout(store) { Set($0.tiles.map(\.id)) == Set(top.tiles.map(\.id)) }
    #expect(Set(returned.tiles.map(\.id)) == Set(top.tiles.map(\.id)))

    let folder = try #require(group.items.first)
    store.navigate(to: folder.id)
    #expect(store.crumbs.map(\.id) == [store.tree!.rootID, folder.id])
    store.back()
    #expect(store.currentID == store.tree?.rootID)
  }

  @MainActor private func waitForPhase(_ store: SpaceStore, _ phase: ScanPhase) async throws {
    for _ in 0..<300 {
      if store.phase == phase { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.phase == phase)
  }

  @MainActor private func waitForLayout(
    _ store: SpaceStore, matching: (TreemapLayout) -> Bool = { _ in true }
  ) async throws -> TreemapLayout {
    for _ in 0..<200 {
      if let layout = store.layout, matching(layout) { return layout }
      try await Task.sleep(for: .milliseconds(10))
    }
    return try #require(store.layout)
  }
}

extension SpaceStoreTests {
  private actor FullRefreshGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
      entered = true
      await withCheckedContinuation { continuation = $0 }
    }

    func release() {
      continuation?.resume()
      continuation = nil
    }
  }

  @MainActor
  @Test(
    "Picture fallback installs the entire read-only cache and preserves navigation after cancel",
    arguments: ["no-baseline", "legacy-baseline", "unavailable-history"])
  func fallbackCacheNavigation(_ variant: String) async throws {
    let fixture = "/private/tmp/LightenQA-" + UUID().uuidString
    let root = fixture + "/home"
    try FileManager.default.createDirectory(atPath: root + "/folder/deep", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: fixture) }
    try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: root + "/folder/deep/data.bin"))
    let run = try ScanEngine().start(root: root)
    await run.waitUntilFinished()
    let pictures = ResultPictureStore(directory: fixture + "/pictures")
    try pictures.saveSpace(tree: run.tree)
    let cache = ScanCache(directory: fixture + "/cache", homeDirectory: root)
    let baseline: ScanReplayBaseline? =
      variant == "no-baseline"
      ? nil
      : ScanReplayBaseline(
        eventID: UInt64.max, volumeUUID: UUID(), storeUUID: variant == "legacy-baseline" ? nil : UUID())
    try cache.save(run.tree, baseline: baseline)
    let gate = FullRefreshGate()
    let store = SpaceStore(cache: cache, pictures: pictures, beforeFullRefresh: { await gate.wait() })
    store.selectRoot(URL(fileURLWithPath: root))
    for _ in 0..<200 {
      if await gate.entered { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await gate.entered)
    let cached = try #require(store.tree)
    let observedAt = try #require(store.cachedAt)
    #expect(store.phase == .scanning)
    #expect(store.isShowingCache)
    let folder = try #require(cached.find(path: root + "/folder"))
    let deep = try #require(cached.find(path: root + "/folder/deep"))
    store.navigate(to: folder)
    store.navigate(to: deep)
    #expect(store.crumbs.map(\.path) == [root, root + "/folder", root + "/folder/deep"])
    #expect(store.current?.logical.completeTotal == 4096)
    #expect(store.group?.items.first?.name == "data.bin")
    // The same state used by the action buttons stays read-only after cancel.
    store.cancel()
    await gate.release()
    for _ in 0..<20 { await Task.yield() }
    #expect(store.phase == .cancelled)
    #expect(store.currentScanRunID == nil)
    #expect(store.tree === cached)
    #expect(store.cachedAt == observedAt)
    #expect(store.isShowingCache)
    store.back()
    #expect(store.current?.path == root + "/folder")
    store.navigate(to: deep)
    #expect(store.current?.path == root + "/folder/deep")
  }

  @MainActor @Test("A successful full refresh replaces a fallback cache at the browsed path")
  func fallbackCacheCompletes() async throws {
    let fixture = "/private/tmp/LightenQA-" + UUID().uuidString
    let root = fixture + "/home"
    try FileManager.default.createDirectory(atPath: root + "/folder", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: fixture) }
    let file = URL(fileURLWithPath: root + "/folder/data.bin")
    try Data(repeating: 1, count: 70).write(to: file)
    let run = try ScanEngine().start(root: root)
    await run.waitUntilFinished()
    let cache = ScanCache(directory: fixture + "/cache", homeDirectory: root)
    let pictures = ResultPictureStore(directory: fixture + "/pictures")
    try cache.save(run.tree)
    try pictures.saveSpace(tree: run.tree)
    try Data(repeating: 2, count: 130).write(to: file)
    let gate = FullRefreshGate()
    let store = SpaceStore(cache: cache, pictures: pictures, beforeFullRefresh: { await gate.wait() })
    store.selectRoot(URL(fileURLWithPath: root))
    for _ in 0..<200 {
      if await gate.entered { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await gate.entered)
    let cached = try #require(store.tree)
    store.navigate(to: try #require(cached.find(path: root + "/folder")))
    #expect(store.current?.logical.completeTotal == 70)
    #expect(store.isShowingCache)
    await gate.release()
    try await waitForPhase(store, .complete)
    #expect(store.tree !== cached)
    #expect(store.current?.path == root + "/folder")
    #expect(store.current?.logical.completeTotal == 130)
    #expect(!store.isShowingCache)
    #expect(store.cachedAt == nil)
    store.cancel()
  }

  @MainActor @Test("Overview decodes only the shared Space picture")
  func overviewPicture() async throws {
    let fixture = "/private/tmp/LightenQA-" + UUID().uuidString
    let root = fixture + "/home"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: fixture) }
    try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: root + "/data.bin"))
    let run = try ScanEngine().start(root: root)
    await run.waitUntilFinished()
    let pictures = ResultPictureStore(directory: fixture + "/pictures")
    try pictures.saveSpace(tree: run.tree)
    let cache = ScanCache(directory: fixture + "/cache", homeDirectory: root)
    let store = SpaceStore(cache: cache, pictures: pictures)
    store.selectedRoot = URL(fileURLWithPath: root)
    store.showCachedSummary()
    for _ in 0..<100 {
      if store.rootSummary != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.tree == nil)
    #expect(store.rootSummary?.logical.completeTotal == 4096)
    #expect(store.rootSummary?.inode == 0)
    #expect(store.isShowingCache)
    await store.clearScanCache()
    #expect(pictures.loadSpace(root: root) == nil)
  }
}

private actor SpaceReplayTestGate {
  private var arrived = false
  private var released = false
  private var arrivals: [CheckedContinuation<Void, Never>] = []
  private var waits: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    arrived = true
    for arrival in arrivals { arrival.resume() }
    arrivals.removeAll()
    guard !released else { return }
    await withCheckedContinuation { waits.append($0) }
  }

  func waitForArrival() async {
    guard !arrived else { return }
    await withCheckedContinuation { arrivals.append($0) }
  }

  func release() {
    released = true
    for wait in waits { wait.resume() }
    waits.removeAll()
  }
}

private final class SpaceReplayNativeGate: Sendable {
  private struct State: Sendable {
    var arrived = false
    var tree: ScanTree?
    var arrivals: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Mutex(State())
  private let semaphore = DispatchSemaphore(value: 0)

  func hold(tree: ScanTree? = nil) {
    #expect(!Thread.isMainThread)
    let arrivals = state.withLock { state -> [CheckedContinuation<Void, Never>]? in
      guard !state.arrived else { return nil }
      state.arrived = true
      state.tree = tree
      defer { state.arrivals.removeAll() }
      return state.arrivals
    }
    guard let arrivals else { return }
    for arrival in arrivals { arrival.resume() }
    semaphore.wait()
  }

  func waitForArrival() async {
    await withCheckedContinuation { continuation in
      let resume = state.withLock { state -> Bool in
        if state.arrived { return true }
        state.arrivals.append(continuation)
        return false
      }
      if resume { continuation.resume() }
    }
  }

  var tree: ScanTree? { state.withLock { $0.tree } }
  func release() { semaphore.signal() }
}

private struct SpaceReplayFixture: Sendable {
  let directory: String
  let root: String
  let cache: ScanCache
  let pictures: ResultPictureStore
  let baseline: ScanReplayBaseline

  static func make() async throws -> Self {
    let directory = "/private/tmp/LightenQA-" + UUID().uuidString
    let root = directory + "/home"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 20).write(to: URL(fileURLWithPath: root + "/data.bin"))
    let run = try ScanEngine(configuration: ScanConfiguration(homeDirectory: root)).start(root: root)
    await run.waitUntilFinished()
    let cache = ScanCache(directory: directory + "/cache", homeDirectory: root)
    let pictures = ResultPictureStore(directory: directory + "/pictures")
    let baseline = ScanReplayBaseline(eventID: 50, volumeUUID: UUID(), storeUUID: UUID())
    try cache.save(run.tree, baseline: baseline)
    try pictures.saveSpace(tree: run.tree)
    return Self(directory: directory, root: root, cache: cache, pictures: pictures, baseline: baseline)
  }

  func resize(_ bytes: Int) throws {
    try Data(repeating: 2, count: bytes).write(to: URL(fileURLWithPath: root + "/data.bin"))
  }

  func remove() { try? FileManager.default.removeItem(atPath: directory) }
}

extension SpaceStoreTests {
  @MainActor @Test("Replay deadline starts a fresh scan without waiting for a held reader")
  func replayDeadlineDoesNotAwaitReader() async throws {
    let fixture = try await SpaceReplayFixture.make()
    defer { fixture.remove() }
    let reader = SpaceReplayTestGate()
    let deadline = SpaceReplayTestGate()
    defer {
      Task {
        await reader.release()
        await deadline.release()
      }
    }
    let baseline = fixture.baseline
    let store = SpaceStore(
      cache: fixture.cache, pictures: fixture.pictures,
      readReplay: { _, _ in
        await reader.wait()
        return FileEventReplay(events: [], latestID: 50)
      }, captureReplayBaseline: { _ in baseline }, waitForReplayDeadline: { await deadline.wait() },
      elapsedReplay: { _ in .zero })
    defer { store.cancel() }
    store.selectRoot(URL(fileURLWithPath: fixture.root))
    await reader.waitForArrival()
    await deadline.waitForArrival()
    #expect(store.tree == nil)
    #expect(store.isShowingCache)
    #expect(store.rootSummary?.logical.completeTotal == 20)
    try fixture.resize(80)
    await deadline.release()
    await store.waitForReplayDeadline()
    #expect(store.currentScanRunID != nil)
    await store.waitForScanCompletion()
    #expect(store.phase == .complete)
    #expect(store.current?.logical.completeTotal == 80)
    let accepted = store.tree
    await reader.release()
    await store.waitForOpening()
    await store.waitForCacheWrites()
    #expect(store.tree === accepted)
    #expect(store.current?.logical.completeTotal == 80)
    #expect(fixture.cache.loadEntry(root: fixture.root)?.tree.item(ScanItemID(node: 0))?.logical.completeTotal == 80)
    #expect(fixture.pictures.loadSpace(root: fixture.root)?.content.root.logical.completeTotal == 80)
  }

  @MainActor @Test("Replay deadline discards a privately mutating reconciliation and starts fresh work")
  func replayDeadlineDoesNotAwaitReconciliation() async throws {
    let fixture = try await SpaceReplayFixture.make()
    defer { fixture.remove() }
    let reconciliation = SpaceReplayNativeGate()
    let freshScan = SpaceReplayNativeGate()
    defer {
      reconciliation.release()
      freshScan.release()
    }
    let deadline = SpaceReplayTestGate()
    defer { Task { await deadline.release() } }
    let baseline = fixture.baseline
    let engine = ScanEngine(
      configuration: ScanConfiguration(homeDirectory: fixture.root, fileSink: FileSink { _ in freshScan.hold() }))
    let store = SpaceStore(
      engine: engine, cache: fixture.cache, pictures: fixture.pictures,
      readReplay: { _, _ in
        FileEventReplay(events: [FileEvent(path: fixture.root + "/data.bin", flags: 0, id: 51)], latestID: 51)
      },
      reconcileReplay: { engine, tree, replay, baseline, current in
        reconciliation.hold(tree: tree)
        return engine.reconcile(tree: tree, replay: replay, baseline: baseline, currentBaseline: current)
      }, captureReplayBaseline: { _ in baseline }, waitForReplayDeadline: { await deadline.wait() },
      elapsedReplay: { _ in .zero })
    defer { store.cancel() }
    store.selectRoot(URL(fileURLWithPath: fixture.root))
    await reconciliation.waitForArrival()
    await deadline.waitForArrival()
    let privateTree = try #require(reconciliation.tree)
    try fixture.resize(80)
    await deadline.release()
    await store.waitForReplayDeadline()
    await freshScan.waitForArrival()
    #expect(store.currentScanRunID != nil)
    #expect(store.tree !== privateTree)
    #expect(store.rootSummary?.logical.completeTotal == 20)
    #expect(store.isShowingCache)
    freshScan.release()
    await store.waitForScanCompletion()
    #expect(store.current?.logical.completeTotal == 80)
    let accepted = store.tree
    reconciliation.release()
    await store.waitForOpening()
    await store.waitForCacheWrites()
    #expect(store.tree === accepted)
    #expect(store.tree !== privateTree)
    #expect(privateTree.item(privateTree.rootID)?.logical.completeTotal == 80)
    #expect(fixture.pictures.loadSpace(root: fixture.root)?.content.root.logical.completeTotal == 80)
  }

  @MainActor @Test("Queued stale-generation saves cannot overwrite another root's accepted result")
  func replayQueuedStaleSaveIsDiscarded() async throws {
    let fixture = try await SpaceReplayFixture.make()
    defer { fixture.remove() }
    let otherRoot = fixture.directory + "/other"
    try FileManager.default.createDirectory(atPath: otherRoot, withIntermediateDirectories: true)
    try Data(repeating: 3, count: 120).write(to: URL(fileURLWithPath: otherRoot + "/other.bin"))
    let reconciliation = SpaceReplayNativeGate()
    defer { reconciliation.release() }
    let deadline = SpaceReplayTestGate()
    defer { Task { await deadline.release() } }
    let baseline = fixture.baseline
    let store = SpaceStore(
      cache: fixture.cache, pictures: fixture.pictures,
      readReplay: { _, _ in FileEventReplay(events: [], latestID: 50) },
      reconcileReplay: { engine, tree, replay, baseline, current in
        reconciliation.hold(tree: tree)
        return engine.reconcile(tree: tree, replay: replay, baseline: baseline, currentBaseline: current)
      }, captureReplayBaseline: { _ in baseline }, waitForReplayDeadline: { await deadline.wait() },
      elapsedReplay: { _ in .zero })
    defer { store.cancel() }
    store.selectRoot(URL(fileURLWithPath: fixture.root))
    await reconciliation.waitForArrival()
    await deadline.waitForArrival()
    try fixture.resize(80)
    await deadline.release()
    await store.waitForReplayDeadline()
    await store.waitForScanCompletion()  // Its save is queued behind the held reconciliation.
    #expect(store.current?.logical.completeTotal == 80)
    store.selectRoot(URL(fileURLWithPath: otherRoot))
    await store.waitForOpening()
    await store.waitForScanCompletion()
    #expect(store.selectedRoot.path == otherRoot)
    #expect(store.current?.logical.completeTotal == 120)
    reconciliation.release()
    await store.waitForCacheWrites()
    #expect(store.tree?.rootPath == otherRoot)
    #expect(store.current?.logical.completeTotal == 120)
    // The superseded scan's queued write was discarded, so the original root's files retain their old result.
    #expect(fixture.cache.loadEntry(root: fixture.root)?.tree.item(ScanItemID(node: 0))?.logical.completeTotal == 20)
    #expect(fixture.pictures.loadSpace(root: fixture.root)?.content.root.logical.completeTotal == 20)
    let other = try #require(fixture.cache.loadEntry(root: otherRoot))
    #expect(other.tree.item(other.tree.rootID)?.logical.completeTotal == 120)
    #expect(fixture.pictures.loadSpace(root: otherRoot)?.content.root.logical.completeTotal == 120)
  }

  @MainActor @Test("An accepted replay cancels its deadline and publishes before the fresh-scan fallback")
  func replayAcceptedWinnerIgnoresLateDeadline() async throws {
    let fixture = try await SpaceReplayFixture.make()
    defer { fixture.remove() }
    let reader = SpaceReplayTestGate()
    let deadline = SpaceReplayTestGate()
    defer {
      Task {
        await reader.release()
        await deadline.release()
      }
    }
    let baseline = fixture.baseline
    let store = SpaceStore(
      cache: fixture.cache, pictures: fixture.pictures,
      readReplay: { _, _ in
        await reader.wait()
        return FileEventReplay(events: [], latestID: 50)
      },
      captureReplayBaseline: { _ in baseline }, waitForReplayDeadline: { await deadline.wait() },
      elapsedReplay: { _ in .zero })
    defer { store.cancel() }
    store.selectRoot(URL(fileURLWithPath: fixture.root))
    await reader.waitForArrival()
    await deadline.waitForArrival()
    let acceptedTask = Task {
      await reader.release()
      await store.waitForOpening()
      let accepted = store.tree
      #expect(store.phase == .complete)
      #expect(store.currentScanRunID == nil)
      #expect(!store.isShowingCache)
      await deadline.release()
      return accepted
    }
    // Join the timer while it is still held, then let the accepted winner cancel it.
    await store.waitForReplayDeadline()
    let accepted = try #require(await acceptedTask.value)
    await store.waitForCacheWrites()
    #expect(store.tree === accepted)
    #expect(store.currentScanRunID == nil)
    #expect(store.current?.logical.completeTotal == 20)
  }
}

extension SpaceStoreTests {
  @MainActor @Test("Replay timeout retains exact applied and Undo display projections until fresh completion")
  func replayTimeoutPreservesUndoProjection() async throws {
    let fixture = try await SpaceReplayFixture.make()
    defer { fixture.remove() }
    let cached = try #require(fixture.cache.loadEntry(root: fixture.root))
    try fixture.cache.save(cached.tree)  // First opening supplies an independent read-only display tree.
    let initialRefresh = SpaceReplayTestGate()
    let reader = SpaceReplayTestGate()
    let deadline = SpaceReplayTestGate()
    let verification = SpaceReplayTestGate()
    let freshScan = SpaceReplayNativeGate()
    defer {
      freshScan.release()
      Task {
        await initialRefresh.release()
        await reader.release()
        await deadline.release()
        await verification.release()
      }
    }
    let baseline = fixture.baseline
    let engine = ScanEngine(
      configuration: ScanConfiguration(homeDirectory: fixture.root, fileSink: FileSink { _ in freshScan.hold() }))
    let store = SpaceStore(
      engine: engine, cache: fixture.cache, pictures: fixture.pictures,
      beforeFullRefresh: { await initialRefresh.wait() },
      readReplay: { _, _ in
        await reader.wait()
        return FileEventReplay(events: [], latestID: 50)
      }, captureReplayBaseline: { _ in baseline }, waitForReplayDeadline: { await deadline.wait() },
      elapsedReplay: { _ in .zero },
      waitForDisplayVerification: { await verification.wait() })
    defer { store.cancel() }
    store.selectRoot(URL(fileURLWithPath: fixture.root))
    await initialRefresh.waitForArrival()
    let displayed = try #require(store.tree)
    store.cancel()
    await initialRefresh.release()
    await store.waitForOpening()
    try fixture.cache.save(cached.tree, baseline: baseline)
    store.loadVolumes()
    await reader.waitForArrival()
    await deadline.waitForArrival()
    let path = fixture.root + "/data.bin"
    let trashPath = fixture.directory + "/returned.bin"
    let identity = try DescriptorFileSystem.identity(at: path)
    let item = ActionDisplayItem(
      planID: UUID(), itemID: UUID(), path: path, identity: identity,
      size: ObservedPlanSize(logical: ByteAggregate(knownLowerBound: 20, completeTotal: 20), allocated: nil),
      label: "Data", returnedTrashPath: trashPath)
    try FileManager.default.moveItem(atPath: path, toPath: trashPath)
    store.applyDisplayChange(ActionDisplayChange(kind: .applied, items: [item]))
    #expect(store.group?.items.contains { $0.path == path } == false)
    #expect(store.current?.logical.completeTotal == 0)
    #expect(displayed.item(displayed.rootID)?.logical.completeTotal == 20)
    try FileManager.default.moveItem(atPath: trashPath, toPath: path)
    store.applyDisplayChange(ActionDisplayChange(kind: .restored, items: [item]))
    #expect(store.group?.items.map(\.path) == [path])
    #expect(store.current?.logical.completeTotal == 20)
    await deadline.release()
    await store.waitForReplayDeadline()
    await freshScan.waitForArrival()
    #expect(store.tree === displayed)
    #expect(store.isShowingCache)
    #expect(store.group?.items.map(\.path) == [path])
    #expect(store.current?.logical.completeTotal == 20)
    await reader.release()
    await store.waitForOpening()
    #expect(store.tree === displayed)
    freshScan.release()
    await store.waitForScanCompletion()
    await store.waitForCacheWrites()
    #expect(store.phase == .complete)
    #expect(store.tree !== displayed)
    #expect(store.current?.logical.completeTotal == 20)
    #expect(store.displayMessage == nil)
    store.cancel()
    await verification.release()
  }
}

extension SpaceStoreTests {
  @MainActor
  @Test("Replay callback at or after two seconds starts fresh even while its timer is held", arguments: [2, 3])
  func replayElapsedBoundaryRejectsLateWinner(_ elapsedSeconds: Int) async throws {
    let fixture = try await SpaceReplayFixture.make()
    defer { fixture.remove() }
    try fixture.resize(80)
    let deadline = SpaceReplayTestGate()
    defer { Task { await deadline.release() } }
    let baseline = fixture.baseline
    let store = SpaceStore(
      cache: fixture.cache, pictures: fixture.pictures,
      readReplay: { _, _ in FileEventReplay(events: [], latestID: 50) },
      captureReplayBaseline: { _ in baseline }, waitForReplayDeadline: { await deadline.wait() },
      elapsedReplay: { _ in .seconds(elapsedSeconds) })
    defer { store.cancel() }
    store.selectRoot(URL(fileURLWithPath: fixture.root))
    await store.waitForOpening()
    #expect(store.currentScanRunID != nil)
    await store.waitForScanCompletion()
    #expect(store.phase == .complete)
    #expect(store.current?.logical.completeTotal == 80)
    await deadline.release()
    await store.waitForCacheWrites()
    #expect(fixture.pictures.loadSpace(root: fixture.root)?.content.root.logical.completeTotal == 80)
  }
}
