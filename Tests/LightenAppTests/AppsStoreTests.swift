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
  store.select(path, actions: actions, selectPackage: false)
  #expect(store.selectedReport?.path == path)
  continuation.yield(.measured([measured]))
  await waitForApps { store.measuredCount == 1 }
  #expect(store.reports[0].logical.completeTotal == 512)
  store.cancelScan()
  continuation.yield(.completed(inventory, [measured]))
  continuation.finish()
  await Task.yield()
  #expect(!store.needsRescan)
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

  var requestCount: Int { received }

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
  store.select(appPath, actions: actions, selectPackage: false)
  store.toggleData(dataPath, actions: actions)

  let staleResult = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForRequest(1)
  store.toggleData(dataPath, actions: actions)
  store.toggleData(dataPath, actions: actions)
  await gate.waitForRequest(2)
  await gate.finish(.success(plan))
  await staleResult.value
  #expect(actions.pending == nil && store.preparing)
  await gate.finish(.success(plan))
  #expect(await appsEventually { actions.pending?.plan == plan })
  store.deactivate(actions: actions)

  let staleError = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForRequest(3)
  store.deactivate(actions: actions)
  await gate.finish(.failure(AppsGateFailure.injected))
  await staleError.value
  #expect(actions.pending == nil)
  #expect(store.message == nil)

  let current = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForRequest(4)
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

private actor SelectedRunningGate: RunningApplicationSource {
  private var continuation: CheckedContinuation<Bool?, Never>?
  private var released = false
  func isRunning(bundleID: String) async -> Bool? {
    if released { return false }
    return await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    released = true
    continuation?.resume(returning: false)
    continuation = nil
  }
}

@Test("Shallow empty results draw and package preparation works while running status and sizes are stalled")
@MainActor func appsShallowDrawAndPreparationPrecedeRunningCheck() async throws {
  let path = "/Applications/LightenQA-independent.app"
  let app = InstalledApplication(bundleID: "qa.lighten.independent", path: path, version: "1")
  let metadata = selectedAppReport(path, bundleID: app.bundleID)
  let gate = SelectedAppReviewGate()
  let running = SelectedRunningGate()
  let plan = ActionPlan(
    snapshotRunID: UUID(), kind: .trash,
    items: [
      PlanItem(
        id: UUID(), sourcePath: path, inventory: [], ancestors: [], policy: .wholeBundle,
        applicationBundleID: app.bundleID)
    ])
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    availableUninstallPlanBuilder: { _, _, _ in
      RelatedDataService.AvailableUninstallPlan(plan: plan, rejections: [])
    }, selectedReview: { path, progress in try await gate.review(path: path, progress: progress) },
    running: running, events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [metadata]
  store.select(path, actions: actions, selectPackage: false)
  let started = try #require(store.selectedReviewRequestedAt)
  await gate.waitForRequests(1)
  await gate.publish(ApplicationRelatedReview(application: app, candidates: [], phase: .shallow), request: 0)
  await waitForApps { store.selectedShallowComplete }
  #expect(store.selectedReviewRequestedAt == started)
  #expect(store.selectedReviewPending)
  #expect(store.runningCheckedIDs.isEmpty)
  let viewport = CGRect(x: 0, y: 0, width: 300, height: 500)
  store.selectedListDidDraw(
    RelatedListViewportSnapshot(frames: [:], candidatePaths: [], viewport: viewport),
    revision: store.selectedDrawRevision)
  #expect(store.selectedListDrawnAt == nil)
  store.selectedListDidDraw(
    RelatedListViewportSnapshot(
      frames: [RelatedListViewportSnapshot.emptyResultID: CGRect(x: 0, y: 280, width: 250, height: 20)],
      candidatePaths: [], viewport: viewport), revision: store.selectedDrawRevision)
  #expect(store.selectedListDrawnAt != nil)
  store.togglePackage(actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending?.plan == plan)
  #expect(store.selectedReviewPending && store.runningCheckedIDs.isEmpty)
  await gate.finish(ApplicationRelatedReview(application: app, candidates: [], phase: .initialComplete), request: 0)
  await store.waitForSelectedReview()
  await running.release()
}

@Test("Late automatic evidence and package toggles honor an explicit related-data deselection")
@MainActor func appsLateEvidencePreservesDeselection() async throws {
  let name = "LightenQA-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = RemovalPreferences(defaults: defaults, persistentDomainName: name)
  preferences.automaticallySelectRelatedData = true
  let path = "/Applications/LightenQA-deselection.app"
  let app = InstalledApplication(bundleID: "qa.lighten.deselection", path: path, version: "1")
  let candidate = selectedAppCandidate("/tmp/LightenQA-deselection-cache")
  let gate = SelectedAppReviewGate()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    selectedReview: { path, progress in try await gate.review(path: path, progress: progress) },
    preferences: preferences, running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [selectedAppReport(path, bundleID: app.bundleID)]
  store.select(path, actions: actions, selectPackage: false)
  await gate.waitForRequests(1)
  let update = ApplicationRelatedReview(application: app, candidates: [candidate], ownershipPending: false)
  await gate.publish(update, request: 0)
  await waitForApps { store.selectedReport?.related.count == 1 }
  store.togglePackage(actions: actions)
  #expect(store.selectedDataPaths == [candidate.path])
  store.toggleData(candidate.path, actions: actions)
  #expect(store.selectedDataPaths.isEmpty)
  await gate.publish(update, request: 0)
  await gate.finish(update, request: 0)
  await store.waitForSelectedReview()
  #expect(store.selectedDataPaths.isEmpty)
  store.togglePackage(actions: actions)
  store.togglePackage(actions: actions)
  #expect(store.selectedDataPaths.isEmpty)
  store.toggleData(candidate.path, actions: actions)
  #expect(store.selectedDataPaths == [candidate.path])
}

@Test("Explicit name-only choices retain the same observed root across size and evidence upgrades")
@MainActor func appsShallowChoiceRetainsObservedRoot() async throws {
  let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
  defer { free(temporary) }
  let root = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let identity = try DescriptorFileSystem.identity(at: root)
  let app = InstalledApplication(
    bundleID: "qa.lighten.choice", path: "/Applications/LightenQA-choice.app", version: "1")
  var shallow = RelatedDataCandidate(
    id: root, path: root, classification: .unprovenNameOnly, reason: .nameOnly, snapshot: nil, receipt: nil)
  shallow.displayRootIdentity = identity
  shallow.matchStrength = .weak
  shallow.explicitManualChoiceAvailable = true
  let gate = SelectedAppReviewGate()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    selectedReview: { path, progress in try await gate.review(path: path, progress: progress) },
    running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [selectedAppReport(app.path, bundleID: app.bundleID)]
  store.select(app.path, actions: actions, selectPackage: false)
  await gate.waitForRequests(1)
  await gate.publish(ApplicationRelatedReview(application: app, candidates: [shallow], phase: .shallow), request: 0)
  await waitForApps { store.selectedShallowComplete }
  store.toggleData(root, actions: actions)
  let entry = ScanEntry(parentID: nil, path: root, identity: identity, issues: [], readable: true)
  let snapshot = ScanSnapshot(rootPath: root, volumeDevice: identity.device, entries: [entry], nodes: [])
  var measured = RelatedDataCandidate(
    id: root, path: root, classification: .unprovenNameOnly, reason: .nameOnly, snapshot: snapshot, receipt: nil)
  measured.matchStrength = .weak
  measured.explicitManualChoiceAvailable = true
  await gate.publish(
    ApplicationRelatedReview(application: app, candidates: [measured], phase: .measuring(completed: 1, total: 1)),
    request: 0)
  await waitForApps { store.selectedReport?.related.first?.snapshot != nil }
  #expect(store.selectedDataPaths == [root])
  #expect(measured.defaultSelected == false)
  let enriched = RelatedDataCandidate(
    id: root, path: root, classification: .installed, reason: .installed, snapshot: snapshot, receipt: nil)
  await gate.publish(
    ApplicationRelatedReview(application: app, candidates: [enriched], ownershipPending: false, phase: .enriched),
    request: 0)
  await waitForApps { store.selectedReport?.related.first?.classification == .installed }
  #expect(store.selectedDataPaths == [root])
  await gate.finish(
    ApplicationRelatedReview(application: app, candidates: [measured], phase: .initialComplete), request: 0)
  await store.waitForSelectedReview()
  #expect(store.selectedReport?.related.first?.classification == .installed)
  #expect(store.selectedDataPaths == [root])
  #expect(!store.selectedEvidencePending)
}

private func selectedAppReport(
  _ path: String, bundleID: String, bytes: Int64 = 0, identity: FileIdentity? = nil
) -> ApplicationReport {
  ApplicationReport(
    path: path, bundleID: bundleID, version: "1", signerTeamID: nil,
    logical: ByteAggregate(knownLowerBound: bytes, completeTotal: bytes == 0 ? nil : bytes),
    allocated: ByteAggregate(knownLowerBound: bytes, completeTotal: bytes == 0 ? nil : bytes),
    knownItemCount: bytes == 0 ? 0 : 1, partial: bytes == 0, related: [], manualUninstallerSuggested: false,
    displayRootIdentity: identity)
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
  store.select(path, actions: actions, selectPackage: false)
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
  store.select(firstPath, actions: actions, selectPackage: false)
  await gate.waitForRequests(1)
  store.select(secondPath, actions: actions, selectPackage: false)
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
  #expect(!store.needsRescan)
  #expect(store.selectedReviewPublishedAt == nil)
  #expect(store.backgroundCancelledAt != nil)
  #expect(!store.canSelect(candidate, app: try #require(store.selectedReport)))
  #expect(!store.packageSelected && store.selectedDataPaths.isEmpty)
  #expect(actions.pending == nil)
}

@Test("Shared data opens the other installation through fresh review without selecting any action")
@MainActor func appsSharedOwnerNavigationRefreshesDestination() async throws {
  let firstPath = "/Applications/LightenQA-first.app"
  let otherPath = "/Applications/LightenQA-other.app"
  let bundleID = "qa.lighten.shared"
  let candidatePath = "/tmp/LightenQA-shared/Library/Caches/qa.lighten.shared"
  let evidence = RelatedOwnershipRefusalEvidence(
    candidatePath: candidatePath, bundleID: bundleID, reason: .sharedInstalledOwners,
    ownerPaths: [firstPath, otherPath], nextStep: "review-other-installations", detail: nil)
  let candidate = RelatedDataCandidate(
    id: candidatePath, path: candidatePath, classification: .shared,
    reason: .sharedInstalledData, snapshot: nil, receipt: nil, bundleID: bundleID,
    refusalEvidence: [evidence])
  var first = selectedAppReport(firstPath, bundleID: bundleID)
  first.related = [candidate]
  let fresh = selectedAppReport(otherPath, bundleID: bundleID, bytes: 123)
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    selectedReview: { path, _ in
      #expect(path == otherPath)
      return ApplicationRelatedReview(
        application: InstalledApplication(bundleID: bundleID, path: path, version: "1"),
        candidates: [])
    },
    droppedReport: { path in
      #expect(path == otherPath)
      return fresh
    }, running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [first]
  store.inventoryComplete = true
  store.runningCheckedIDs = [bundleID]
  store.selectedPath = firstPath
  store.packageSelected = true
  #expect(store.selectedAppPaths == [firstPath])
  #expect(store.canSelect(candidate, app: first))
  #expect(!store.automaticSelectionAllowed(candidate))
  #expect(store.otherInstallationPaths(candidate: candidate, app: first) == [otherPath])
  await store.openOtherInstallation(otherPath, candidate: candidate, app: first, actions: actions)
  #expect(store.selectedAppPaths == [firstPath])
  await store.waitForSelectedReview()
  #expect(store.selectedReport?.path == otherPath)
  #expect(store.selectedReport?.logical.completeTotal == 123)
  #expect(store.selectedReviewReadyAt != nil)
  #expect(store.selectedDataPaths.isEmpty && !store.packageSelected)
  #expect(actions.pending == nil)
}

@Test("Unknown owners offer no navigation or automatic choice but allow explicit selection")
@MainActor func appsUnknownOwnerRemainsUnavailable() async {
  let path = "/Applications/LightenQA-first.app"
  let other = "/Applications/LightenQA-unknown.app"
  let candidatePath = "/tmp/LightenQA-unknown/Library/Caches/qa.lighten.unknown"
  let evidence = RelatedOwnershipRefusalEvidence(
    candidatePath: candidatePath, bundleID: "qa.lighten.unknown",
    reason: .unknownMetadata, ownerPaths: [path, other], nextStep: "inspect-owner-metadata",
    detail: "unreadable")
  let candidate = RelatedDataCandidate(
    id: candidatePath, path: candidatePath, classification: .uncertain,
    reason: .ownershipUnavailable, snapshot: nil, receipt: nil, refusalEvidence: [evidence])
  var app = selectedAppReport(path, bundleID: "qa.lighten.unknown")
  app.related = [candidate]
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    droppedReport: { _ in
      Issue.record("Unknown metadata offered installed-owner navigation")
      return nil
    }, running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [app]
  store.inventoryComplete = true
  store.selectedPath = path
  #expect(store.otherInstallationPaths(candidate: candidate, app: app).isEmpty)
  #expect(store.canSelect(candidate, app: app))
  #expect(!store.automaticSelectionAllowed(candidate))
  await store.openOtherInstallation(other, candidate: candidate, app: app, actions: actions)
  #expect(store.selectedPath == path && actions.pending == nil)
}

@Test(
  "Selected linked review accepts fresh physical metadata while preserving the listed request path")
@MainActor func appsLinkedReviewKeepsListedPath() async {
  let listed = "/Applications/LightenQA-link.app"
  let physical = "/tmp/LightenQA-physical.app"
  let bundleID = "qa.lighten.alias"
  let candidate = selectedAppCandidate("/tmp/LightenQA-alias-cache/qa.lighten.alias")
  var report = selectedAppReport(listed, bundleID: bundleID)
  report.linkTarget = physical
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    selectedReview: { path, _ in
      #expect(path == listed)
      return ApplicationRelatedReview(
        application: InstalledApplication(bundleID: bundleID, path: physical, version: "1"),
        candidates: [candidate])
    }, running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [report]
  store.select(listed, actions: actions, selectPackage: false)
  await store.waitForSelectedReview()
  #expect(store.selectedPath == listed)
  #expect(store.selectedReport?.linkTarget == physical)
  #expect(store.selectedReport?.related.map(\.path) == [candidate.path])
  #expect(store.message == nil && actions.pending == nil)
}

private func storeUnprovenCandidate(
  _ path: String, classification: RelatedClassification = .unprovenNameOnly,
  reason: RelatedReason = .nameOnly, inode: UInt64 = 2
) -> RelatedDataCandidate {
  let identity = FileIdentity(
    device: 1, inode: inode, changeSeconds: 1, changeNanoseconds: 0,
    logicalBytes: 64, allocatedBytes: 64, linkCount: 1, flags: 0, kind: .directory,
    birthSeconds: 1, birthNanoseconds: 0)
  return RelatedDataCandidate(
    id: path, path: path, classification: classification, reason: reason,
    snapshot: ScanSnapshot(
      rootPath: path, volumeDevice: 1,
      entries: [ScanEntry(parentID: nil, path: path, identity: identity, issues: [], readable: true)], nodes: []),
    receipt: nil, explicitManualChoiceAvailable: true)
}

@Test(
  "Discovery vetoes block recommendations while allowing explicit user choices",
  arguments: [
    (RelatedClassification.uncertain, RelatedReason.literalIdentifierOwner),
    (.shared, .sharedInstalledData), (.protected, .protected), (.protected, .foreignOwner),
    (.uncertain, .ownershipUnavailable), (.unprovenNameOnly, .literalIdentifierOwner),
  ])
@MainActor func appsKnownVetoCannotBecomeManual(classification: RelatedClassification, reason: RelatedReason) {
  let path = "/Applications/LightenQA-name.app"
  let candidate = storeUnprovenCandidate(
    "/private/tmp/LightenQA-name-data", classification: classification, reason: reason)
  var app = selectedAppReport(path, bundleID: "qa.lighten.name")
  app.related = [candidate]
  let store = AppsStore(
    pictures: disabledAppsPictures(), running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [app]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.name"]
  store.select(path, actions: actions, selectPackage: false)
  #expect(store.canSelect(candidate, app: app))
  #expect(!store.automaticSelectionAllowed(candidate))
  store.toggleData(candidate.path, actions: actions)
  #expect(store.selectedDataPaths == [candidate.path] && actions.pending == nil)
}

@Test(
  "Earlier running observations do not disable explicit app-data review",
  arguments: ["running", "unknown", "unchecked"])
@MainActor func appsUnprovenKeepsRunningVeto(state: String) {
  let path = "/Applications/LightenQA-name.app"
  let id = "qa.lighten.name"
  let candidate = storeUnprovenCandidate("/private/tmp/LightenQA-name-data")
  var app = selectedAppReport(path, bundleID: id)
  app.related = [candidate]
  let store = AppsStore(
    pictures: disabledAppsPictures(), running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  store.reports = [app]
  store.inventoryComplete = true
  if state != "unchecked" { store.runningCheckedIDs = [id] }
  if state == "running" { store.runningIDs = [id] }
  if state == "unknown" { store.runningUnknownIDs = [id] }
  #expect(store.canSelect(candidate, app: app))
  #expect(!store.automaticSelectionAllowed(candidate))
}

@Test("A fresh name-only row preserves a choice only for the same observed identity", arguments: [false, true])
@MainActor func appsUnprovenRefreshRequiresNewChoice(changedIdentity: Bool) async throws {
  let path = "/Applications/LightenQA-name.app"
  let id = "qa.lighten.name"
  let candidate = storeUnprovenCandidate("/private/tmp/LightenQA-name-data")
  let replacement = storeUnprovenCandidate(candidate.path, inode: changedIdentity ? 3 : 2)
  var app = selectedAppReport(path, bundleID: id)
  app.related = [candidate]
  let inventory = BundleInventory(
    applications: [InstalledApplication(bundleID: id, path: path, version: "1")],
    unidentifiedPaths: [], complete: true, observedAt: Date())
  let plan = ActionPlan(
    snapshotRunID: UUID(), kind: .trash,
    items: [PlanItem(id: UUID(), sourcePath: candidate.path, inventory: [], ancestors: [])])
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    explicitUninstallPlanBuilder: { _, automatic, _, manual in
      #expect(automatic.isEmpty && manual.count == 1)
      return .init(plan: plan, rejections: [])
    }, running: ClosedAppSource(), events: { stream })
  let actions = ActionStore()
  store.startScan(actions: actions)
  continuation.yield(.inventory(inventory, [app]))
  await waitForApps { store.reports.count == 1 }
  store.inventoryComplete = true
  store.runningCheckedIDs = [id]
  store.select(path, actions: actions, selectPackage: false)
  store.toggleData(candidate.path, actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending?.id == plan.id)
  continuation.yield(.related(path: path, candidates: [replacement], ownershipPending: false))
  await waitForApps {
    store.selectedReport?.related.first?.snapshot?.entries.first?.identity?.inode == (changedIdentity ? 3 : 2)
      && (!changedIdentity || store.selectedDataPaths.isEmpty)
  }
  if changedIdentity {
    #expect(store.selectedDataPaths.isEmpty && actions.pending == nil)
    #expect(store.message?.contains("select it again") == true)
    store.toggleData(replacement.path, actions: actions)
    #expect(store.selectedDataPaths == [replacement.path])
  } else {
    #expect(store.selectedDataPaths == [candidate.path])
    #expect(actions.pending?.id == plan.id)
  }
  continuation.yield(.completed(inventory, [app]))
  continuation.finish()
  await waitForApps { !store.busy }
}

@Test(
  "Provenance labels distinguish package-derived evidence from a user's name-only choice",
  arguments: [
    (RelatedDataProvenanceKind.bundleIdentifier, "bundle identifier"),
    (.electron, "Electron"), (.mozilla, "Mozilla"), (.explicitUserChoice, "unproven"),
  ])
func appsProvenanceLabelsAreHonest(kind: RelatedDataProvenanceKind, phrase: String) {
  #expect(AppsStore.provenanceLabel(kind).contains(phrase))
}

@Test("Selecting an app chooses its package immediately while related review is suspended")
@MainActor func appsSelectionDefaultsToPackage() async throws {
  let path = "/Applications/LightenQA-default.app"
  let app = InstalledApplication(bundleID: "qa.lighten.default", path: path, version: "1")
  let gate = SelectedAppReviewGate()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    selectedReview: { path, progress in try await gate.review(path: path, progress: progress) },
    running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [selectedAppReport(path, bundleID: app.bundleID)]
  store.busy = true
  store.measuringPaths = [path]
  store.select(path, actions: actions)
  await gate.waitForRequests(1)
  #expect(store.packageSelected)
  #expect(store.selectedReviewPending && !store.inventoryComplete && store.busy)
  store.togglePackage(actions: actions)
  #expect(!store.packageSelected)
  await gate.finish(ApplicationRelatedReview(application: app, candidates: []), request: 0)
  await store.waitForSelectedReview()
  #expect(!store.packageSelected)
}

@Test("Late automatic related data cannot replace the selection being prepared or confirmed")
@MainActor func appsEnrichmentPreservesPreparingSelection() async throws {
  let name = "LightenQA-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = RemovalPreferences(defaults: defaults, persistentDomainName: name)
  preferences.automaticallySelectRelatedData = true
  let path = "/Applications/LightenQA-confirmation.app"
  let app = InstalledApplication(bundleID: "qa.lighten.confirmation", path: path, version: "1")
  let ready = selectedAppCandidate("/tmp/LightenQA-ready")
  let late = selectedAppCandidate("/tmp/LightenQA-late")
  let latest = selectedAppCandidate("/tmp/LightenQA-latest")
  let review = SelectedAppReviewGate()
  let planning = AppsPlanGate()
  let package = PlanItem(
    id: UUID(), sourcePath: path, inventory: [], ancestors: [], policy: .wholeBundle,
    applicationBundleID: app.bundleID)
  let data = PlanItem(id: UUID(), sourcePath: ready.path, inventory: [], ancestors: [])
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [package, data])
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    uninstallPlanBuilder: { _, candidates, includePackage in
      #expect(includePackage && candidates.map(\.path) == [ready.path])
      return try await planning.next()
    }, selectedReview: { path, progress in try await review.review(path: path, progress: progress) },
    preferences: preferences, running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [selectedAppReport(path, bundleID: app.bundleID)]
  store.select(path, actions: actions)
  // Start with an explicit package choice to isolate enrichment from selection defaults.
  store.packageSelected = true
  await review.waitForRequests(1)
  await review.publish(
    ApplicationRelatedReview(application: app, candidates: [ready], ownershipPending: false), request: 0)
  await waitForApps { store.selectedDataPaths.contains(ready.path) }
  try #require(store.selectedDataPaths == [ready.path])
  #expect(store.selectedReviewPending)
  let preparation = Task { await store.prepareSelectedData(actions: actions) }
  await planning.waitForRequest(1)
  await review.publish(
    ApplicationRelatedReview(application: app, candidates: [ready, late], ownershipPending: false), request: 0)
  await waitForApps { store.selectedReport?.related.count == 2 }
  await planning.finish(.success(plan))
  await preparation.value
  #expect(actions.pending?.plan == plan)
  #expect(store.selectedDataPaths == [ready.path])
  await review.finish(
    ApplicationRelatedReview(application: app, candidates: [ready, late, latest], ownershipPending: false), request: 0)
  await store.waitForSelectedReview()
  #expect(actions.pending?.plan == plan)
  #expect(store.selectedDataPaths == [ready.path])
  store.toggleData(late.path, actions: actions)
  #expect(actions.pending == nil)
  #expect(store.selectedDataPaths == [ready.path, late.path])
}

private actor AppsManualDeadline {
  private var signalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if signalled { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func reset() { signalled = false }
  func signal() {
    signalled = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

@MainActor private func appsEventually(_ condition: @escaping @MainActor () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !(await condition()) {
    if ContinuousClock.now >= deadline { return false }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return true
}

private func appsPackagePlan(_ path: String, bundleID: String) -> ActionPlan {
  ActionPlan(
    snapshotRunID: UUID(), kind: .trash,
    items: [
      PlanItem(
        id: UUID(), sourcePath: path, inventory: [], ancestors: [], policy: .wholeBundle,
        applicationBundleID: bundleID)
    ])
}

@Test("An injected deadline returns preparation promptly and discards a late non-cancellable builder")
@MainActor func appsPreparationDeadlineDiscardsLateBuilder() async throws {
  let path = "/fixture/LightenQA-timeout.app"
  let bundleID = "qa.lighten.timeout"
  let plan = appsPackagePlan(path, bundleID: bundleID)
  let planning = AppsPlanGate()
  let deadline = AppsManualDeadline()
  let store = AppsStore(
    pictures: disabledAppsPictures(), uninstallPlanBuilder: { _, _, _ in try await planning.next() },
    preparationTimeout: { await deadline.wait() }, running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [selectedAppReport(path, bundleID: bundleID)]
  store.select(path, actions: actions)
  var finished = false
  let preparation = Task {
    await store.prepareSelectedData(actions: actions)
    finished = true
  }
  await planning.waitForRequest(1)
  #expect(store.reviewExplanation(actions: actions).contains("Checking selected items"))
  await deadline.signal()
  #expect(await appsEventually { finished })
  #expect(!store.preparing && store.packageSelected && store.selectedPath == path)
  #expect(actions.pending == nil && store.message?.contains("took too long") == true)
  #expect(store.canReviewSelectedData(actions: actions))
  await preparation.value
  await deadline.reset()
  let retryPlan = appsPackagePlan(path, bundleID: bundleID)
  let retry = Task { await store.prepareSelectedData(actions: actions) }
  await planning.waitForRequest(2)
  await planning.finish(.success(plan))
  #expect(actions.pending == nil)
  await planning.finish(.success(retryPlan))
  await retry.value
  #expect(actions.pending?.plan == retryPlan && retryPlan.id != plan.id)
  await deadline.signal()
}

@Test("Changing an explicit choice while preparation is pending starts a new review of that choice")
@MainActor func appsSelectionChangeContinuesReviewIntent() async throws {
  let firstPath = "/fixture/LightenQA-first-choice.app"
  let secondPath = "/fixture/LightenQA-second-choice.app"
  let bundleID = "qa.lighten.choice"
  let oldPlan = appsPackagePlan(firstPath, bundleID: bundleID)
  let newPlan = appsPackagePlan(secondPath, bundleID: bundleID)
  let planning = AppsPlanGate()
  let deadline = AppsManualDeadline()
  let store = AppsStore(
    pictures: disabledAppsPictures(), uninstallPlanBuilder: { _, _, _ in try await planning.next() },
    preparationTimeout: { await deadline.wait() }, running: ClosedAppSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [selectedAppReport(firstPath, bundleID: bundleID), selectedAppReport(secondPath, bundleID: bundleID)]
  store.select(firstPath, actions: actions)
  let oldPreparation = Task { await store.prepareSelectedData(actions: actions) }
  await planning.waitForRequest(1)
  store.select(secondPath, actions: actions)
  #expect(await appsEventually { await planning.requestCount == 2 })
  await planning.finish(.success(oldPlan))
  await oldPreparation.value
  #expect(actions.pending == nil)
  await planning.finish(.success(newPlan))
  #expect(await appsEventually { actions.pending?.plan.id == newPlan.id })
  #expect(store.selectedPath == secondPath && store.packageSelected)
  await deadline.signal()
}

@Test(
  "Late related data becomes unselected retained data with independent restoration orders",
  arguments: [false, true], [false, true])
@MainActor func appsLateRelatedDataSupportsIndependentUndo(restorePackageFirst: Bool, hasSnapshot: Bool) async throws {
  let path = "/fixture/LightenQA-late-data.app"
  let otherPath = "/fixture/LightenQA-other-data.app"
  let bundleID = "qa.lighten.late.data"
  let app = InstalledApplication(bundleID: bundleID, path: path, version: "1")
  let identity = FileIdentity(
    device: 1, inode: 11, changeSeconds: 2, changeNanoseconds: 0,
    logicalBytes: 0, allocatedBytes: 0, linkCount: 1, flags: 0, kind: .directory,
    birthSeconds: 2, birthNanoseconds: 0)
  let candidatePath = "/fixture/LightenQA-late-cache"
  var candidate = RelatedDataCandidate(
    id: candidatePath, path: candidatePath, classification: .uncertain, reason: .ownershipUnavailable,
    snapshot: hasSnapshot
      ? ScanSnapshot(
        rootPath: candidatePath, volumeDevice: 1,
        entries: [ScanEntry(parentID: nil, path: candidatePath, identity: identity, issues: [], readable: true)],
        nodes: []) : nil,
    receipt: nil, bundleID: bundleID)
  candidate.displayRootIdentity = identity
  let lateCandidate = candidate
  let package = PlanItem(
    id: UUID(), sourcePath: path, inventory: [], ancestors: [], policy: .wholeBundle,
    applicationBundleID: bundleID)
  let packagePlan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [package])
  let data = PlanItem(id: UUID(), sourcePath: candidatePath, inventory: [], ancestors: [])
  let dataPlan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [data])
  let reviews = SelectedAppReviewGate()
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  defer { continuation.finish() }
  let store = AppsStore(
    pictures: disabledAppsPictures(), uninstallPlanBuilder: { _, _, _ in packagePlan },
    selectedReview: { path, progress in try await reviews.review(path: path, progress: progress) },
    remainingDataPlanBuilder: { selected in
      #expect(selected.map(\.path) == [candidatePath])
      return .init(plan: dataPlan, rejections: [])
    }, running: ClosedAppSource(), events: { stream })
  let actions = ActionStore()
  store.startScan(actions: actions)
  continuation.yield(
    .inventory(
      BundleInventory(applications: [app], unidentifiedPaths: [], complete: false, observedAt: Date()),
      [selectedAppReport(path, bundleID: bundleID), selectedAppReport(otherPath, bundleID: bundleID)]))
  #expect(await appsEventually { store.reports.count == 2 })
  store.select(path, actions: actions)
  await reviews.waitForRequests(1)
  await store.prepareSelectedData(actions: actions)
  try #require(actions.pending?.plan == packagePlan)
  actions.pending = nil
  actions.result = ActionResult(
    planID: packagePlan.id, items: [ItemActionResult(itemID: package.id, outcome: .applied)])
  store.observeResult(actions: actions)
  store.select(otherPath, actions: actions)
  await reviews.waitForRequests(2)
  await reviews.publish(ApplicationRelatedReview(application: app, candidates: [lateCandidate]), request: 0)
  #expect(await appsEventually { store.orphanCandidates.contains { $0.path == candidatePath } })
  continuation.yield(.related(path: path, candidates: [candidate], ownershipPending: true))
  continuation.yield(.orphans([]))
  await reviews.finish(ApplicationRelatedReview(application: app, candidates: [candidate]), request: 0)
  await reviews.finish(
    ApplicationRelatedReview(
      application: InstalledApplication(bundleID: bundleID, path: otherPath, version: "1"), candidates: []), request: 1)
  await store.waitForSelectedReview()
  #expect(store.retainedAppData[candidatePath]?.appPath == path)
  #expect(store.retainedAppData[candidatePath]?.wasSelected == false)
  #expect(store.selectedOrphanPaths.isEmpty && !store.selectedDataPaths.contains(candidatePath))
  store.toggleOrphan(candidatePath, actions: actions)
  await store.prepareOrphans(actions: actions)
  try #require(actions.pending?.plan == dataPlan && dataPlan.id != packagePlan.id)
  let dataChange = ActionDisplayItem(
    planID: dataPlan.id, itemID: data.id, path: candidatePath,
    identity: identity, size: .unknown, label: "Late data", returnedTrashPath: nil)
  store.applyDisplayChange(ActionDisplayChange(kind: .applied, items: [dataChange]))
  actions.pending = nil
  actions.result = ActionResult(planID: dataPlan.id, items: [ItemActionResult(itemID: data.id, outcome: .applied)])
  store.observeResult(actions: actions)
  let packageChange = ActionDisplayItem(
    planID: packagePlan.id, itemID: package.id, path: path,
    identity: nil, size: .unknown, label: "App", returnedTrashPath: nil)
  if restorePackageFirst {
    store.applyDisplayChange(ActionDisplayChange(kind: .restored, items: [packageChange]))
    #expect(store.reports.first { $0.path == path }?.related.isEmpty == true)
    store.applyDisplayChange(ActionDisplayChange(kind: .restored, items: [dataChange]))
  } else {
    store.applyDisplayChange(ActionDisplayChange(kind: .restored, items: [dataChange]))
    #expect(store.retainedAppData[candidatePath]?.appPath == path)
    #expect(store.selectedOrphanPaths.isEmpty)
    store.applyDisplayChange(ActionDisplayChange(kind: .restored, items: [packageChange]))
  }
  #expect(store.reports.first { $0.path == path }?.related.map(\.path) == [candidatePath])
  #expect(!store.orphanCandidates.contains { $0.path == candidatePath })
  #expect(store.retainedAppData[candidatePath] == nil)
  store.cancelScan()
  continuation.finish()
}

private actor AppsSuspendedFinalActivity: ApplicationActivitySource {
  private var continuation: CheckedContinuation<ApplicationActivity, Never>?
  private var arrival: CheckedContinuation<Void, Never>?
  func activity(applicationPath: String) async -> ApplicationActivity {
    await withCheckedContinuation {
      continuation = $0
      arrival?.resume()
      arrival = nil
    }
  }
  func waitForArrival() async {
    if continuation != nil { return }
    await withCheckedContinuation { arrival = $0 }
  }
  func finish() {
    continuation?.resume(returning: ApplicationActivity(state: .clearObservedProcesses, scope: .currentUser))
    continuation = nil
  }
}

@Test("A final running-app observation has the same bounded deadline and cannot present a late result")
@MainActor func appsRunningObservationDeadlineIsNamed() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightenQA-\(UUID())").path
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/LightenQA-running-timeout.app"
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  let bundleID = "qa.lighten.running.timeout"
  let planner = PlanService(homeDirectory: root)
  let deadline = AppsManualDeadline()
  let activity = AppsSuspendedFinalActivity()
  let store = AppsStore(
    pictures: disabledAppsPictures(), preparationTimeout: { await deadline.wait() }, userPlanner: planner)
  let actions = ActionStore(planService: planner, userSelectionApplicationActivity: activity)
  store.reports = [selectedAppReport(path, bundleID: bundleID)]
  store.select(path, actions: actions)
  let preparation = Task { await store.prepareSelectedData(actions: actions) }
  await activity.waitForArrival()
  #expect(store.reviewExplanation(actions: actions).contains("apps are running"))
  await deadline.signal()
  await preparation.value
  #expect(!store.preparing && store.canReviewSelectedData(actions: actions))
  #expect(store.message?.contains("Checking running apps took too long") == true)
  #expect(actions.pending == nil && store.packageSelected)
  await activity.finish()
  #expect(actions.pending == nil)
}

@Test("Late data for a failed package removal remains app data rather than becoming removed-app data")
@MainActor func appsFailedRemovalNeverCreatesLateOrphans() async throws {
  let path = "/fixture/LightenQA-kept.app"
  let bundleID = "qa.lighten.kept"
  let plan = appsPackagePlan(path, bundleID: bundleID)
  let candidate = selectedAppCandidate("/fixture/LightenQA-kept-data")
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  defer { continuation.finish() }
  let store = AppsStore(pictures: disabledAppsPictures(), uninstallPlanBuilder: { _, _, _ in plan }, events: { stream })
  let actions = ActionStore()
  store.startScan(actions: actions)
  continuation.yield(
    .inventory(
      BundleInventory(applications: [], unidentifiedPaths: [], complete: false, observedAt: Date()),
      [selectedAppReport(path, bundleID: bundleID)]))
  #expect(await appsEventually { store.reports.count == 1 })
  store.select(path, actions: actions)
  await store.prepareSelectedData(actions: actions)
  try #require(actions.pending?.plan == plan)
  actions.pending = nil
  actions.result = ActionResult(
    planID: plan.id, items: [ItemActionResult(itemID: plan.items[0].id, outcome: .failed, detail: "changedItem")])
  store.observeResult(actions: actions)
  continuation.yield(.related(path: path, candidates: [candidate], ownershipPending: false))
  #expect(await appsEventually { store.reports.first?.related.count == 1 })
  #expect(store.orphanCandidates.isEmpty && store.retainedAppData.isEmpty)
  #expect(store.reports.first?.related.first?.classification == candidate.classification)
  store.cancelScan()
}

@Test("Each app keeps explicit data choices and deselections across browse and re-add")
@MainActor func appsBasketRetainsIndependentChoices() throws {
  let a = "/fixture/LightenQA-choices-a.app"
  let b = "/fixture/LightenQA-choices-b.app"
  let first = selectedAppCandidate("/fixture/LightenQA-choice-first")
  let second = selectedAppCandidate("/fixture/LightenQA-choice-second")
  let name = "qa.lighten.basket." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = RemovalPreferences(defaults: defaults, persistentDomainName: name)
  preferences.automaticallySelectRelatedData = true
  let store = AppsStore(pictures: disabledAppsPictures(), preferences: preferences, running: ClosedAppSource())
  let actions = ActionStore()
  var reportA = selectedAppReport(a, bundleID: "qa.lighten.a")
  var reportB = selectedAppReport(b, bundleID: "qa.lighten.b")
  reportA.related = [first]
  reportB.related = [second]
  store.reports = [reportA, reportB]
  store.selectApp(a, actions: actions)
  store.toggleData(first.path, actions: actions)
  #expect(store.selectedDataPaths.isEmpty)
  store.selectApp(b, actions: actions)
  #expect(store.selectedDataPaths == [second.path])
  store.selectApp(a, actions: actions)
  #expect(store.selectedDataPaths.isEmpty)
  store.selectApp(b, intent: .toggle, actions: actions)
  #expect(store.selectedAppPaths == [a, b] && store.selectedDataPaths == [second.path])
  store.selectApp(b, intent: .toggle, actions: actions)
  store.selectApp(b, intent: .toggle, actions: actions)
  #expect(store.selectedDataPaths == [second.path])
}

@Test(
  "The lightweight installed-app list stays stable when ownership inventory includes other packages",
  arguments: [false, true])
@MainActor func appsOwnershipInventoryDoesNotExpandDefaultList(ownershipComplete: Bool) async throws {
  let primary = "/Applications/LightenQA-visible.app"
  let home = "/fixture/home"
  let other = "/Volumes/Fixture/LightenQA-external.app"
  let excluded = [
    "/System/Applications/LightenQA-system.app",
    "/Applications/Host.app/Contents/Helpers/LightenQA-helper.app",
    home + "/dev/product/.build/debug/LightenQA-built.app",
    home + "/.Trash/LightenQA-trashed.app",
  ]
  let all = [primary, other] + excluded
  let metadata = all.map { selectedAppReport($0, bundleID: "qa.lighten.scope") }
  let inventory = BundleInventory(
    applications: all.map { InstalledApplication(bundleID: "qa.lighten.scope", path: $0, version: nil) },
    unidentifiedPaths: [], complete: ownershipComplete, observedAt: Date())
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  defer { continuation.finish() }
  let store = AppsStore(
    pictures: disabledAppsPictures(), userPlanner: PlanService(homeDirectory: home), events: { stream })
  let actions = ActionStore()
  store.startScan(actions: actions)
  continuation.yield(
    .listed([
      ApplicationListEntry(
        path: primary, name: "Visible", bundleID: "qa.lighten.scope", version: nil, displayRootIdentity: nil)
    ]))
  #expect(await appsEventually { store.reports.count == 1 })
  #expect(store.defaultApplicationReports.map(\.path) == [primary])
  continuation.yield(.inventory(inventory, metadata))
  #expect(await appsEventually { store.inventoryPublishedAt != nil })
  #expect(store.defaultApplicationReports.map(\.path) == [primary])
  #expect(store.otherLocationReports.map(\.path) == [other])
  #expect(Set(store.reports.map(\.path)) == [primary, other])
  continuation.yield(.completed(inventory, metadata))
  continuation.finish()
  await store.waitForScan()
  #expect(!store.busy)
  #expect(store.displayListingFinished && !store.toolSummary.partial)
  #expect(store.inventoryComplete == ownershipComplete && !store.externalVolumesUnchecked)
  #expect(store.defaultApplicationReports.map(\.path) == [primary])
  #expect(store.otherLocationReports.map(\.path) == [other])
}

@Test("Default app-data selection uses existing proof eligibility without selecting excluded evidence")
@MainActor func appsNewPreferenceOnlySelectsEligibleProof() throws {
  let name = "LightenQA-preferences-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = RemovalPreferences(defaults: defaults, persistentDomainName: name)
  let accepted = selectedAppCandidate("/fixture/LightenQA-accepted")
  var weak = selectedAppCandidate("/fixture/LightenQA-weak")
  weak.matchStrength = .weak
  var live = selectedAppCandidate("/fixture/LightenQA-live")
  live.evidenceKinds = [.liveProcess]
  var vendor = selectedAppCandidate("/fixture/LightenQA-vendor")
  vendor.evidenceKinds = [.vendorDirectory]
  var configured = selectedAppCandidate("/fixture/LightenQA-configured")
  configured.evidenceKinds = [.configuredDirectory]
  configured.provenance = RelatedDataProvenance(
    kind: .configuredDirectory, sourcePath: "/fixture/settings", detail: nil)
  let unproven = RelatedDataCandidate(
    id: "/fixture/LightenQA-name", path: "/fixture/LightenQA-name", classification: .unprovenNameOnly,
    reason: .nameOnly,
    snapshot: accepted.snapshot, receipt: nil)
  var report = selectedAppReport("/Applications/LightenQA-default.app", bundleID: "qa.lighten.default")
  report.related = [accepted, weak, live, vendor, configured, unproven]
  let store = AppsStore(pictures: disabledAppsPictures(), preferences: preferences)
  store.reports = [report]
  store.select(report.path, actions: ActionStore())
  #expect(store.selectedDataPaths == [accepted.path])
  #expect(report.related.count == 6)
}

@Test("Signer presentation distinguishes pending evidence from a returned signer")
@MainActor func appsSignerDoesNotSayUnavailableWhileEvidenceIsPending() async {
  let path = "/Applications/LightenQA-signer.app"
  let bundleID = "qa.lighten.signer"
  let review = SelectedAppReviewGate()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    selectedReview: { path, progress in
      try await review.review(path: path, progress: progress)
    }, running: ClosedAppSource())
  let actions = ActionStore()
  store.reports = [selectedAppReport(path, bundleID: bundleID)]
  store.select(path, actions: actions, selectPackage: false)
  await review.waitForRequests(1)
  #expect(store.signerDescription(for: store.reports[0]) == String(localized: "Checking app signature…"))
  await review.finish(
    ApplicationRelatedReview(
      application: InstalledApplication(bundleID: bundleID, path: path, version: nil), candidates: [],
      signerTeamID: "FIXTURETEAM", phase: .enriched), request: 0)
  await store.waitForSelectedReview()
  #expect(store.signerDescription(for: store.reports[0]) == "FIXTURETEAM")
}

private func appsBasketPlan(_ paths: [String]) -> ActionPlan {
  ActionPlan(
    snapshotRunID: UUID(), kind: .trash,
    items: paths.map {
      PlanItem(
        id: UUID(), sourcePath: $0, inventory: [], ancestors: [], policy: .wholeBundle,
        applicationBundleID: "qa.lighten.basket")
    })
}

@Test("A basket deadline keeps every choice and only a fresh explicit retry may present")
@MainActor func appsBasketDeadlineDiscardsLatePlan() async throws {
  let paths = ["/fixture/LightenQA-deadline-a.app", "/fixture/LightenQA-deadline-b.app"]
  let planning = AppsPlanGate()
  let deadline = AppsManualDeadline()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    basketPlanBuilder: { selections, _ in
      #expect(Set(selections.map(\.path)) == Set(paths))
      return .init(plan: try? await planning.next(), rejections: [])
    }, preparationTimeout: { await deadline.wait() }, running: ClosedAppSource())
  let actions = ActionStore()
  store.reports = paths.map { selectedAppReport($0, bundleID: "qa.lighten.basket") }
  for path in paths { store.selectApp(path, intent: .toggle, actions: actions) }
  let old = Task { await store.prepareBasket(actions: actions) }
  await planning.waitForRequest(1)
  #expect(store.phase == .preparing)
  await deadline.signal()
  await old.value
  #expect(store.selectedAppPaths == Set(paths) && !store.preparing)
  #expect(store.message?.contains("took too long") == true && actions.pending == nil && actions.result == nil)
  await deadline.reset()
  let freshPlan = appsBasketPlan(paths)
  let retry = Task { await store.prepareBasket(actions: actions) }
  await planning.waitForRequest(2)
  await planning.finish(.success(appsBasketPlan(paths)))
  #expect(actions.pending == nil)
  await planning.finish(.success(freshPlan))
  await retry.value
  #expect(actions.pending?.plan == freshPlan && actions.result == nil)
  await deadline.signal()
}

@Test("Changing basket membership during preparation preserves the newest review intent")
@MainActor func appsBasketChangeContinuesLatestReview() async throws {
  let paths = ["/fixture/LightenQA-latest-a.app", "/fixture/LightenQA-latest-b.app"]
  let planning = AppsPlanGate()
  let deadline = AppsManualDeadline()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    basketPlanBuilder: { _, _ in .init(plan: try? await planning.next(), rejections: []) },
    preparationTimeout: { await deadline.wait() }, running: ClosedAppSource())
  let actions = ActionStore()
  store.reports = paths.map { selectedAppReport($0, bundleID: "qa.lighten.basket") }
  for path in paths { store.selectApp(path, intent: .toggle, actions: actions) }
  let old = Task { await store.prepareBasket(actions: actions) }
  await planning.waitForRequest(1)
  store.removeAppFromBasket(paths[0], actions: actions)
  await planning.waitForRequest(2)
  await planning.finish(.success(appsBasketPlan(paths)))
  await old.value
  #expect(actions.pending == nil && store.selectedAppPaths == [paths[1]])
  let latest = appsBasketPlan([paths[1]])
  await planning.finish(.success(latest))
  #expect(await appsEventually { actions.pending?.plan == latest })
  #expect(actions.result == nil)
  await deadline.signal()
}

@Test("Basket preparation and confirmation freeze automatic additions for unfocused apps", arguments: [false, true])
@MainActor func appsBasketFreezesEveryAppDuringReview(alreadyPresented: Bool) async throws {
  let paths = ["/Applications/LightenQA-frozen-a.app", "/Applications/LightenQA-frozen-b.app"]
  let candidate = selectedAppCandidate("/fixture/LightenQA-frozen-data")
  let name = "qa.lighten.freeze." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = RemovalPreferences(defaults: defaults, persistentDomainName: name)
  let planning = AppsPlanGate()
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    basketPlanBuilder: { _, _ in .init(plan: try? await planning.next(), rejections: []) },
    preferences: preferences, running: ClosedAppSource(), events: { stream })
  let actions = ActionStore()
  store.startScan(actions: actions)
  // The fixture initially contains current rows while its controlled discovery stream is still open.
  let reports = paths.map { selectedAppReport($0, bundleID: "qa.lighten.basket") }
  store.reports = reports
  for path in paths { store.selectApp(path, intent: .toggle, actions: actions) }
  let preparation = Task { await store.prepareBasket(actions: actions) }
  await planning.waitForRequest(1)
  let plan = appsBasketPlan(paths)
  if alreadyPresented {
    await planning.finish(.success(plan))
    await preparation.value
  }
  let inventory = BundleInventory(applications: [], unidentifiedPaths: [], complete: false, observedAt: Date())
  continuation.yield(.related(path: paths[0], candidates: [candidate], ownershipPending: false))
  continuation.yield(.completed(inventory, reports))
  continuation.finish()
  await store.waitForScan()
  #expect(store.basketDataCount == 0 && store.reports.first?.related.map(\.path) == [candidate.path])
  if !alreadyPresented {
    await planning.finish(.success(plan))
    await preparation.value
  }
  #expect(actions.pending?.plan == plan && store.basketDataCount == 0)
  // Focusing/readding preserves the frozen per-app choices, then an explicit data toggle invalidates review.
  store.selectApp(paths[0], actions: actions)
  #expect(store.selectedDataPaths.isEmpty && actions.pending == nil)
  store.toggleData(candidate.path, actions: actions)
  #expect(store.selectedDataPaths == [candidate.path])
}

@Test("Self protection and stale pictures cannot contribute package authority to a basket")
@MainActor func appsBasketProtectsSelfAndPictures() async {
  let path = "/Applications/LightenQA-self.app"
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    basketPlanBuilder: { _, _ in
      Issue.record("A protected or stale basket reached planning")
      return .init(plan: nil, rejections: [])
    }, running: ClosedAppSource())
  let actions = ActionStore()
  store.reports = [selectedAppReport(path, bundleID: LightenIdentity.bundleIdentifier)]
  store.selectApp(path, actions: actions)
  #expect(store.selectedAppPaths.isEmpty && !store.packageSelected)
  // The preparation guard also rejects a choice assigned outside the ordinary row controls.
  store.selectedPath = path
  store.packageSelected = true
  await store.prepareBasket(actions: actions)
  #expect(actions.pending == nil && store.message == String(localized: "Lighten does not remove itself."))
  store.needsRescan = true
  #expect(!store.canReviewBasket(actions: actions))
  await store.prepareBasket(actions: actions)
  #expect(actions.pending == nil)
}

@Test("Replacing a focused app root or bundle invalidates its cached explicit data choices", arguments: [false, true])
@MainActor func appsBasketReplacementDropsCachedChoices(changeIdentity: Bool) {
  let path = "/fixture/LightenQA-replaced.app"
  let data = selectedAppCandidate("/fixture/LightenQA-replaced-data")
  let oldIdentity = FileIdentity(
    device: 1, inode: 10, changeSeconds: 1, changeNanoseconds: 0, logicalBytes: 0, allocatedBytes: 0,
    linkCount: 1, flags: 0, kind: .directory, birthSeconds: 1, birthNanoseconds: 0)
  let newIdentity = FileIdentity(
    device: 1, inode: 11, changeSeconds: 1, changeNanoseconds: 0, logicalBytes: 0, allocatedBytes: 0,
    linkCount: 1, flags: 0, kind: .directory, birthSeconds: 1, birthNanoseconds: 0)
  let store = AppsStore(pictures: disabledAppsPictures(), running: ClosedAppSource())
  let actions = ActionStore()
  var report = selectedAppReport(path, bundleID: "qa.lighten.original", identity: oldIdentity)
  report.related = [data]
  store.reports = [report]
  store.selectApp(path, actions: actions)
  if !store.selectedDataPaths.contains(data.path) { store.toggleData(data.path, actions: actions) }
  #expect(store.selectedDataPaths == [data.path])
  let replaced = selectedAppReport(
    path, bundleID: changeIdentity ? "qa.lighten.original" : "qa.lighten.replacement",
    identity: changeIdentity ? newIdentity : oldIdentity)
  store.reports = [replaced]
  store.selectApp(path, actions: actions)
  #expect(store.packageSelected && store.selectedDataPaths.isEmpty)
}

@Test(
  "Unrelated cached changes and same-root proof upgrades preserve the requested basket review",
  arguments: [false, true])
@MainActor func appsBasketEnrichmentPreservesReview(upgradeSelectedChoice: Bool) async {
  let paths = ["/Applications/LightenQA-enrichment-a.app", "/Applications/LightenQA-enrichment-b.app"]
  let candidate = storeUnprovenCandidate("/fixture/LightenQA-enrichment-data", inode: 10)
  let planning = AppsPlanGate()
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let store = AppsStore(
    pictures: disabledAppsPictures(),
    basketPlanBuilder: { _, _ in .init(plan: try? await planning.next(), rejections: []) },
    running: ClosedAppSource(), events: { stream })
  let actions = ActionStore()
  store.startScan(actions: actions)
  var reports = paths.map { selectedAppReport($0, bundleID: "qa.lighten.basket") }
  reports[0].related = [candidate]
  store.reports = reports
  store.selectApp(paths[0], actions: actions)
  store.toggleData(candidate.path, actions: actions)
  store.selectApp(paths[1], intent: upgradeSelectedChoice ? .toggle : .single, actions: actions)
  let preparation = Task { await store.prepareBasket(actions: actions) }
  await planning.waitForRequest(1)
  let fresh =
    upgradeSelectedChoice
    ? RelatedDataCandidate(
      id: candidate.path, path: candidate.path, classification: .installed,
      reason: .installed, snapshot: candidate.snapshot, receipt: nil)
    : storeUnprovenCandidate(candidate.path, inode: 11)
  let inventory = BundleInventory(applications: [], unidentifiedPaths: [], complete: false, observedAt: Date())
  continuation.yield(.related(path: paths[0], candidates: [fresh], ownershipPending: false))
  continuation.yield(.completed(inventory, reports))
  continuation.finish()
  await store.waitForScan()
  let plan = appsBasketPlan(upgradeSelectedChoice ? paths + [candidate.path] : [paths[1]])
  await planning.finish(.success(plan))
  await preparation.value
  #expect(actions.pending?.plan == plan && store.message == nil)
  #expect(store.basketDataCount == (upgradeSelectedChoice ? 1 : 0))
  #expect(actions.result == nil)
}
