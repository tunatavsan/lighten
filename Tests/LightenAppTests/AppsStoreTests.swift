import Foundation
import LightenKit
import Testing

@testable import Lighten
@testable import LightenKit

private enum AppsGateFailure: Error { case injected }

private struct ClosedAppSource: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
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
    discover: {
      (
        BundleInventory(
          applications: [], unidentifiedPaths: [], complete: true, observedAt: Date()), []
      )
    },
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
