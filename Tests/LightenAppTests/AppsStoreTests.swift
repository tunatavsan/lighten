import Foundation
import LightenKit
import Testing

@testable import Lighten
@testable import LightenKit

private enum AppsGateFailure: Error { case injected }

private struct ClosedAppSource: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
}

@MainActor private func waitForApps(_ condition: @escaping @MainActor () -> Bool) async {
  for _ in 0..<1_000 {
    if condition() { return }
    await Task.yield()
  }
}

@Test("Apps publishes metadata before measurements and rejects stale completion after Cancel")
@MainActor func appsMetadataFirstAndStaleProgress() async {
  let path = "/Applications/Fixture.app"
  let bundleID = "com.example.fixture"
  let inventory = BundleInventory(
    applications: [InstalledApplication(bundleID: bundleID, path: path, version: "1")],
    unidentifiedPaths: [], complete: true, observedAt: Date())
  let metadata = ApplicationReport(
    path: path, bundleID: bundleID, version: "1", signerTeamID: nil,
    logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
    allocated: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
    knownItemCount: 0, partial: true, related: [], manualUninstallerSuggested: false)
  let measured = ApplicationReport(
    path: path, bundleID: bundleID, version: "1", signerTeamID: nil,
    logical: ByteAggregate(knownLowerBound: 512, completeTotal: 512),
    allocated: ByteAggregate(knownLowerBound: 512, completeTotal: 512),
    knownItemCount: 2, partial: false, related: [], manualUninstallerSuggested: false)
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let store = AppsStore(running: ClosedAppSource(), events: { stream })
  let actions = ActionStore()
  store.startScan(actions: actions)
  continuation.yield(.inventory(inventory, [metadata]))
  await waitForApps { store.reports.count == 1 }
  #expect(store.busy)
  #expect(store.measuringPaths == [path])
  #expect(store.reports[0].version == "1")
  #expect(!store.inventoryComplete)
  store.select(path, actions: actions)
  #expect(store.selectedReport?.path == path)
  continuation.yield(.measured([measured]))
  await waitForApps { store.measuredCount == 1 }
  #expect(store.reports[0].logical.completeTotal == 512)
  store.cancelScan()
  continuation.yield(.completed(inventory, [measured]))
  continuation.finish()
  await Task.yield()
  #expect(store.needsRescan)
  #expect(!store.inventoryComplete)
  #expect(store.scannedAt == nil)
  #expect(store.selectedReport?.path == path)
}

@Test("Unexpected end of Apps progress keeps review closed")
@MainActor func appsUnexpectedEndNeedsRescan() async {
  let inventory = BundleInventory(
    applications: [], unidentifiedPaths: [], complete: true, observedAt: Date())
  let store = AppsStore(events: {
    AsyncStream { continuation in
      continuation.yield(.inventory(inventory, []))
      continuation.finish()
    }
  })
  store.startScan(actions: ActionStore())
  await waitForApps { !store.busy }
  #expect(store.needsRescan)
  #expect(!store.inventoryComplete)
  #expect(store.scannedAt == nil)
}

private actor AppsPlanGate {
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

@Test("Stale Apps data preparation never presents a plan or error")
@MainActor func staleAppsPreparationIsDiscarded() async throws {
  let bundleID = "com.example.apps-store"
  let appPath = "/Applications/Test.app"
  let dataPath = "/tmp/Library/Caches/" + bundleID
  let snapshot = ScanSnapshot(
    rootPath: "/tmp/Library/Caches", volumeDevice: 1,
    entries: [], nodes: [])
  let candidate = RelatedDataCandidate(
    id: dataPath, path: dataPath, classification: .installed,
    reason: .installed, snapshot: snapshot, receipt: nil)
  let app = ApplicationReport(
    path: appPath, bundleID: bundleID, version: "1", signerTeamID: nil,
    logical: ByteAggregate(knownLowerBound: 1, completeTotal: nil),
    allocated: ByteAggregate(knownLowerBound: 1, completeTotal: nil),
    knownItemCount: 1, partial: true, related: [candidate],
    manualUninstallerSuggested: false)
  let item = PlanItem(id: UUID(), sourcePath: dataPath, inventory: [], ancestors: [])
  let plan = ActionPlan(snapshotRunID: snapshot.runID, kind: .trash, items: [item])
  let gate = AppsPlanGate()
  let store = AppsStore(
    running: ClosedAppSource(),
    events: { AsyncStream { $0.finish() } },
    planBuilder: { _, _ in try await gate.next() })
  let actions = ActionStore()
  store.reports = [app]
  store.inventoryComplete = true
  store.runningCheckedIDs = [bundleID]
  store.select(appPath, actions: actions)
  store.toggleData(dataPath, actions: actions)

  let staleResult = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForRequest(1)
  store.toggleData(dataPath, actions: actions)
  store.toggleData(dataPath, actions: actions)
  await gate.finish(.success(plan))
  await staleResult.value
  #expect(actions.pending == nil)
  #expect(store.message == nil)
  #expect(!store.preparing)

  let staleError = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForRequest(2)
  store.deactivate(actions: actions)
  await gate.finish(.failure(AppsGateFailure.injected))
  await staleError.value
  #expect(actions.pending == nil)
  #expect(store.message == nil)

  let current = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForRequest(3)
  await gate.finish(.success(plan))
  await current.value
  #expect(actions.pending?.plan == plan)
  store.togglePackage(actions: actions)
  #expect(actions.pending == nil)
}
