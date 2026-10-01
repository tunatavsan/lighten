import Darwin
import Foundation
import LightenKit
import Testing

@testable import Lighten
@testable import LightenKit

private enum AppsGateFailure: Error { case injected }

private struct ClosedAppSource: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
}

@Test("Apps leaves identification visible but closes action choices after cancellation")
@MainActor func appsCancelledSelectionHasNoAuthority() {
  let path = "/Applications/LightenQA-characterization.app"
  let store = AppsStore(
    pictures: disabledAppsPictures(), running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.busy = true
  store.selectedPath = path
  store.packageSelected = true
  store.selectedDataPath = "/tmp/LightenQA-characterization"
  store.cancelScan()
  store.togglePackage(actions: actions)
  store.toggleData("/tmp/LightenQA-other", actions: actions)
  #expect(store.selectedPath == path)
  #expect(!store.packageSelected)
  #expect(store.selectedDataPath == nil)
  #expect(store.needsRescan)
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
  let store = AppsStore(pictures: disabledAppsPictures(), running: ClosedAppSource(), events: { stream })
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
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    events: {
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
    pictures: disabledAppsPictures(),
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

private func disabledAppsPictures() -> ResultPictureStore {
  ResultPictureStore(directory: NSTemporaryDirectory() + "LightenQA-" + UUID().uuidString, maximumBytes: 0)
}

private actor SelectedAppReviewGate {
  struct Request: Sendable {
    let path: String
    let progress: (@Sendable (ApplicationRelatedReview) -> Void)?
    let continuation: CheckedContinuation<ApplicationRelatedReview?, Error>
  }
  private var requests: [Request] = []
  private var arrival: [(Int, CheckedContinuation<Void, Never>)] = []

  func review(path: String, progress: (@Sendable (ApplicationRelatedReview) -> Void)?) async throws
    -> ApplicationRelatedReview?
  {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(Request(path: path, progress: progress, continuation: continuation))
      let ready = arrival.filter { requests.count >= $0.0 }
      arrival.removeAll { requests.count >= $0.0 }
      for (_, waiter) in ready { waiter.resume() }
    }
  }

  func waitForRequests(_ count: Int) async {
    if requests.count >= count { return }
    await withCheckedContinuation { arrival.append((count, $0)) }
  }

  func publish(_ review: ApplicationRelatedReview, request: Int) { requests[request].progress?(review) }
  func finish(_ review: ApplicationRelatedReview?, request: Int) {
    requests[request].continuation.resume(returning: review)
  }
}

private func selectedAppReport(_ path: String, bundleID: String, bytes: Int64 = 0) -> ApplicationReport {
  ApplicationReport(
    path: path, bundleID: bundleID, version: "1", signerTeamID: nil,
    logical: ByteAggregate(knownLowerBound: bytes, completeTotal: bytes == 0 ? nil : bytes),
    allocated: ByteAggregate(knownLowerBound: bytes, completeTotal: bytes == 0 ? nil : bytes),
    knownItemCount: bytes == 0 ? 0 : 1, partial: bytes == 0, related: [], manualUninstallerSuggested: false)
}

private func selectedAppCandidate(_ path: String) -> RelatedDataCandidate {
  RelatedDataCandidate(
    id: path, path: path, classification: .installed, reason: .installed,
    snapshot: ScanSnapshot(
      rootPath: (path as NSString).deletingLastPathComponent, volumeDevice: 1, entries: [], nodes: []),
    receipt: nil)
}

@Test("A selected unsigned app can review its package while global and related discovery remain pending")
@MainActor func appsSelectedReviewIndependentOfBackground() async throws {
  let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
  defer { free(temporary) }
  let root = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/LightenQA-selected.app"
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  let bundleID = "qa.lighten.selected"
  let app = InstalledApplication(bundleID: bundleID, path: path, version: "1")
  let metadata = selectedAppReport(path, bundleID: bundleID)
  let inventory = BundleInventory(applications: [app], unidentifiedPaths: [], complete: false, observedAt: Date())
  let candidate = selectedAppCandidate(root + "/Library/Caches/" + bundleID)
  let review = ApplicationRelatedReview(application: app, candidates: [candidate], ownershipPending: true)
  let gate = SelectedAppReviewGate()
  let package = PlanItem(
    id: UUID(), sourcePath: path, inventory: [], ancestors: [], policy: .wholeBundle, applicationBundleID: bundleID)
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [package])
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    availableUninstallPlanBuilder: { report, candidates, includePackage in
      #expect(report.signerTeamID == nil)
      #expect(candidates.isEmpty)
      #expect(includePackage)
      return RelatedDataService.AvailableUninstallPlan(plan: plan, rejections: [])
    }, selectedReview: { path, progress in try await gate.review(path: path, progress: progress) },
    running: ClosedAppSource(), events: { stream })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.startScan(actions: actions)
  continuation.yield(.inventory(inventory, [metadata]))
  await waitForApps { store.reports.count == 1 }
  #expect(store.inventoryPublishedAt != nil)
  #expect(!store.inventoryComplete)
  store.select(path, actions: actions)
  await gate.waitForRequests(1)
  #expect(store.busy && store.selectedReviewPending)
  #expect(store.packageUnavailableReason(metadata) == nil)
  store.togglePackage(actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending?.plan == plan)
  #expect(store.busy)
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))

  await gate.publish(review, request: 0)
  await waitForApps { store.selectedReport?.related.count == 1 }
  #expect(store.canSelect(candidate, app: try #require(store.selectedReport)))
  store.toggleData(candidate.path, actions: actions)
  #expect(actions.pending == nil)
  continuation.yield(.measured([selectedAppReport(path, bundleID: bundleID, bytes: 512)]))
  await waitForApps { store.measuredCount == 1 }
  #expect(store.selectedReport?.related.map(\.path) == [candidate.path])
  #expect(store.selectedDataPaths == [candidate.path])
  #expect(store.selectedReviewPublishedAt != nil)
  #expect(store.selectedReviewReadyAt == nil)
  continuation.yield(.completed(inventory, [selectedAppReport(path, bundleID: bundleID, bytes: 512)]))
  continuation.finish()
  await waitForApps { !store.busy }
  #expect(store.selectedReport?.related.map(\.path) == [candidate.path])
  #expect(store.selectedDataPaths == [candidate.path])
  await gate.finish(review, request: 0)
  await store.waitForSelectedReview()
  #expect(store.selectedReviewReadyAt != nil)
  #expect(store.backgroundStartedAt != nil && store.backgroundFinishedAt != nil)
}

@Test("Superseded selected review callbacks and cancelled discovery never restore action authority")
@MainActor func appsSelectedReviewDiscardsStaleCallbacks() async throws {
  let firstPath = "/Applications/LightenQA-first.app"
  let secondPath = "/Applications/LightenQA-second.app"
  let first = InstalledApplication(bundleID: "qa.lighten.first", path: firstPath, version: "1")
  let second = InstalledApplication(bundleID: "qa.lighten.second", path: secondPath, version: "1")
  let candidate = selectedAppCandidate("/tmp/LightenQA-cache/qa.lighten.first")
  let oldReview = ApplicationRelatedReview(application: first, candidates: [candidate])
  let newReview = ApplicationRelatedReview(application: second, candidates: [])
  let gate = SelectedAppReviewGate()
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    selectedReview: { path, progress in
      try await gate.review(path: path, progress: progress)
    }, running: ClosedAppSource(), events: { stream })
  let actions = ActionStore()
  store.startScan(actions: actions)
  continuation.yield(
    .inventory(
      BundleInventory(applications: [first, second], unidentifiedPaths: [], complete: false, observedAt: Date()),
      [
        selectedAppReport(firstPath, bundleID: first.bundleID),
        selectedAppReport(secondPath, bundleID: second.bundleID),
      ]))
  await waitForApps { store.reports.count == 2 }
  store.select(firstPath, actions: actions)
  await gate.waitForRequests(1)
  store.select(secondPath, actions: actions)
  await gate.waitForRequests(2)
  await gate.publish(oldReview, request: 0)
  await gate.finish(oldReview, request: 0)
  await Task.yield()
  #expect(store.selectedPath == secondPath)
  #expect(store.reports.allSatisfy { $0.related.isEmpty })
  #expect(store.selectedReviewPublishedAt == nil)
  store.cancelScan()
  await gate.publish(newReview, request: 1)
  await gate.finish(newReview, request: 1)
  continuation.yield(.related(path: secondPath, candidates: [candidate], ownershipPending: false))
  continuation.finish()
  await Task.yield()
  #expect(store.needsRescan)
  #expect(store.selectedReviewPublishedAt == nil)
  #expect(store.backgroundCancelledAt != nil)
  #expect(!store.canSelect(candidate, app: try #require(store.selectedReport)))
  #expect(!store.packageSelected && store.selectedDataPaths.isEmpty)
  #expect(actions.pending == nil)
}
