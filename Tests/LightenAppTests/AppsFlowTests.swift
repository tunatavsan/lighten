import Darwin
import Foundation
import LightenKit
import Testing

@testable import Lighten
@testable import LightenKit

private struct AppsClosedSource: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
}

private func flowReport(
  path: String, candidates: [RelatedDataCandidate] = [], bundleID: String = "qa.lighten.flow"
) -> ApplicationReport {
  ApplicationReport(
    path: path, bundleID: bundleID, version: "1", signerTeamID: nil,
    logical: ByteAggregate(knownLowerBound: 64, completeTotal: 64),
    allocated: ByteAggregate(knownLowerBound: 64, completeTotal: 64),
    knownItemCount: 1, partial: false, related: candidates, manualUninstallerSuggested: false)
}

private func flowCandidate(_ path: String) -> RelatedDataCandidate {
  RelatedDataCandidate(
    id: path, path: path, classification: .installed, reason: .installed,
    snapshot: ScanSnapshot(rootPath: path, volumeDevice: 1, entries: [], nodes: []), receipt: nil)
}

private func flowPictures(_ root: String) -> ResultPictureStore {
  ResultPictureStore(directory: root + "/results")
}

@MainActor private func waitFlow(_ condition: @escaping @MainActor () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !condition() {
    try #require(ContinuousClock.now < deadline)
    try await Task.sleep(for: .milliseconds(1))
  }
}

@Test("Apps opening restores 92 display rows and refreshes without giving the picture plan authority")
@MainActor func appsPictureHasNoSelectionAuthority() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let pictures = flowPictures(root)
  let reports = (0..<92).map { flowReport(path: root + "/LightenQA-\($0).app") }
  let observedAt = Date().addingTimeInterval(-60)
  try pictures.save(
    ResultPicture(
      observedAt: observedAt,
      content: AppsPicture(reports: reports, inventoryComplete: true)), named: "apps")
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let store = AppsStore(pictures: pictures, running: AppsClosedSource(), events: { stream })
  let actions = ActionStore()
  let began = ContinuousClock.now
  store.open(actions: actions)
  try await waitFlow { store.pictureRows.count == 92 }
  let elapsed = began.duration(to: .now)
  let timing = try #require(store.pictureOpeningTiming)
  print(
    "Apps picture timing: queue \(timing.requestedAt.duration(to: timing.loadStartedAt)); read \(timing.loadStartedAt.duration(to: timing.loadFinishedAt)); publication \(timing.loadFinishedAt.duration(to: timing.publishedAt)); observation \(timing.publishedAt.duration(to: .now))"
  )
  print("Apps 92-row cold picture display: \(elapsed)")
  #expect(elapsed < .milliseconds(300))
  #expect(store.pictureObservedAt == observedAt)
  #expect(store.busy)
  #expect(store.reports.isEmpty)
  store.select(reports[0].path, actions: actions)
  store.togglePackage(actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending == nil)
  #expect(store.selectedPath == nil)
  continuation.yield(
    .completed(
      BundleInventory(
        applications: [], unidentifiedPaths: [], complete: true,
        observedAt: Date()), []))
  continuation.finish()
  try await waitFlow { !store.busy }
  #expect(store.pictureRows.isEmpty)
}

@Test("Apps reviews all selected data once and drops only applied paths without requiring another scan")
@MainActor func appsMultipleDataAndTargetedResult() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-fixture.app"
  let first = flowCandidate(root + "/Library/Caches/qa.lighten.flow")
  let second = flowCandidate(root + "/Library/Preferences/qa.lighten.flow.plist")
  let firstItem = PlanItem(id: UUID(), sourcePath: first.path, inventory: [], ancestors: [])
  let secondItem = PlanItem(id: UUID(), sourcePath: second.path, inventory: [], ancestors: [])
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [firstItem, secondItem])
  let store = AppsStore(
    pictures: flowPictures(root),
    uninstallPlanBuilder: { report, candidates, package in
      #expect(report.path == app)
      #expect(Set(candidates.map(\.path)) == [first.path, second.path])
      #expect(!package)
      return plan
    }, running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [flowReport(path: app, candidates: [first, second])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions)
  store.toggleData(first.path, actions: actions)
  store.toggleData(second.path, actions: actions)
  #expect(store.selectedDataPaths == [first.path, second.path])
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending?.plan == plan)
  actions.pending = nil
  actions.result = ActionResult(
    planID: plan.id,
    items: [
      ItemActionResult(itemID: firstItem.id, outcome: .applied),
      ItemActionResult(itemID: secondItem.id, outcome: .skipped),
    ])
  store.observeResult(actions: actions)
  #expect(!store.needsRescan)
  #expect(store.selectedDataPaths.isEmpty)
  #expect(store.selectedReport?.related.map(\.path) == [second.path])
  store.toggleData(second.path, actions: actions)
  #expect(store.selectedDataPaths == [second.path])
  store.observeResult(actions: actions)
  #expect(store.selectedDataPaths == [second.path])
}

@Test("Application window rejects non-app drops with a reason before discovery")
@MainActor func appsRejectsNonApplicationDrop() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let store = AppsStore(
    pictures: flowPictures(root),
    droppedReport: { _ in
      Issue.record("Non-app drop reached application discovery")
      return nil
    })
  let actions = ActionStore()
  await store.acceptDrop([URL(fileURLWithPath: root + "/document.txt")], actions: actions)
  #expect(store.message?.isEmpty == false)
  #expect(actions.pending == nil)
  #expect(!store.dropping)
}

@Test("A dropped closed application opens one removal review with its strong data")
@MainActor func appsDropBuildsSingleReview() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-fixture.app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
  let candidate = flowCandidate(root + "/Library/Caches/qa.lighten.flow")
  let report = flowReport(path: app, candidates: [candidate])
  let package = PlanItem(
    id: UUID(), sourcePath: app, inventory: [], ancestors: [], policy: .wholeBundle,
    applicationBundleID: "qa.lighten.flow")
  let data = PlanItem(id: UUID(), sourcePath: candidate.path, inventory: [], ancestors: [])
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [data, package])
  let store = AppsStore(
    pictures: flowPictures(root),
    uninstallPlanBuilder: { _, candidates, includePackage in
      #expect(includePackage)
      #expect(candidates.map(\.path) == [candidate.path])
      return plan
    }, droppedReport: { _ in report }, running: AppsClosedSource())
  let actions = ActionStore()
  let began = ContinuousClock.now
  await store.acceptDrop([URL(fileURLWithPath: app)], actions: actions)
  let elapsed = began.duration(to: .now)
  print("Apps injected application drop to confirmation: \(elapsed)")
  #expect(elapsed < .seconds(1))
  #expect(actions.pending?.plan == plan)
  #expect(store.packageSelected)
  #expect(store.selectedDataPaths == [candidate.path])
}

private func flowRoot() throws -> String {
  let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
  defer { free(temporary) }
  let root = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(
    atPath: root, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  return root
}

@Test("An external application uses the default fresh package planner without an installed-root entry")
@MainActor func appsExternalDropDefaultPlanner() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-external.app"
  let bundleID = "qa.lighten." + UUID().uuidString.lowercased()
  try FileManager.default.createDirectory(atPath: app + "/Contents", withIntermediateDirectories: true)
  let plist = ["CFBundleIdentifier": bundleID, "CFBundleName": "LightenQA", "CFBundlePackageType": "APPL"]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
  try Data("owned fixture".utf8).write(to: URL(fileURLWithPath: app + "/Contents/payload"))
  let fixtureReport = flowReport(path: app, bundleID: bundleID)
  let store = AppsStore(
    pictures: flowPictures(root), droppedReport: { _ in fixtureReport }, running: AppsClosedSource())
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  let began = ContinuousClock.now
  await store.acceptDrop([URL(fileURLWithPath: app)], actions: actions)
  print("Apps external fixture default drop to confirmation: \(began.duration(to: .now))")
  let plan = try #require(actions.pending?.plan)
  #expect(plan.kind == .trash)
  #expect(plan.items.count == 1)
  let package = try #require(plan.items.first)
  #expect(package.sourcePath == app)
  #expect(package.applicationBundleID == bundleID)
  #expect(package.policy == .wholeBundle)
  #expect(package.inventory.contains { $0.path == app + "/Contents/payload" })
  #expect(FileManager.default.fileExists(atPath: app))
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
}

@Test("Selecting an app includes all strong data and retains skipped data when the package moves")
@MainActor func appsPackageSelectsStrongDataAndRetainsSkips() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-package.app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
  let first = flowCandidate(root + "/Library/Caches/qa.lighten.flow")
  let skipped = flowCandidate(root + "/Library/Preferences/qa.lighten.flow.plist")
  var medium = flowCandidate(root + "/Library/Application Support/qa.lighten.flow")
  medium.matchStrength = .medium
  let data = PlanItem(id: UUID(), sourcePath: first.path, inventory: [], ancestors: [])
  let retained = PlanItem(id: UUID(), sourcePath: skipped.path, inventory: [], ancestors: [])
  let package = PlanItem(
    id: UUID(), sourcePath: app, inventory: [], ancestors: [], policy: .wholeBundle,
    applicationBundleID: "qa.lighten.flow")
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [data, retained, package])
  let store = AppsStore(
    pictures: flowPictures(root),
    uninstallPlanBuilder: { _, candidates, includePackage in
      #expect(includePackage)
      #expect(Set(candidates.map(\.path)) == [first.path, skipped.path])
      return plan
    }, running: AppsClosedSource())
  let actions = ActionStore()
  store.reports = [flowReport(path: app, candidates: [first, skipped, medium])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions)
  store.togglePackage(actions: actions)
  #expect(store.selectedDataPaths == [first.path, skipped.path])
  await store.prepareSelectedData(actions: actions)
  actions.pending = nil
  actions.result = ActionResult(
    planID: plan.id,
    items: [
      ItemActionResult(itemID: package.id, outcome: .applied),
      ItemActionResult(itemID: data.id, outcome: .applied),
      ItemActionResult(itemID: retained.id, outcome: .skipped),
    ])
  store.observeResult(actions: actions)
  #expect(store.reports.isEmpty)
  #expect(store.selectedPath == nil)
  #expect(!store.packageSelected)
  #expect(!store.needsRescan)
  #expect(Set(store.orphanCandidates.map(\.path)) == [skipped.path, medium.path])
  store.toggleOrphan(skipped.path, actions: actions)
  #expect(store.selectedOrphanPaths.isEmpty)
}

private actor DroppedReportGate {
  private var pending: CheckedContinuation<ApplicationReport?, Never>?
  func report() async -> ApplicationReport? {
    await withCheckedContinuation { pending = $0 }
  }
  var waiting: Bool { pending != nil }
  func finish(_ report: ApplicationReport?) {
    pending?.resume(returning: report)
    pending = nil
  }
}

@Test("Leaving Apps discards a dropped app's late report without presenting a plan or error")
@MainActor func appsStaleDropDiscarded() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let gate = DroppedReportGate()
  let store = AppsStore(pictures: flowPictures(root), droppedReport: { _ in await gate.report() })
  let actions = ActionStore()
  let task = Task { await store.acceptDrop([URL(fileURLWithPath: root + "/LightenQA-late.app")], actions: actions) }
  while !(await gate.waiting) { await Task.yield() }
  store.deactivate(actions: actions)
  await gate.finish(flowReport(path: root + "/LightenQA-late.app"))
  await task.value
  #expect(store.reports.isEmpty)
  #expect(actions.pending == nil)
  #expect(store.message == nil)
  #expect(!store.dropping)
}

@Test("Orphan data arrives without preselection and its review invalidates when a choice changes")
@MainActor func appsOrphansAreNeverPreselected() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let installed = flowCandidate(root + "/Library/Caches/qa.lighten.orphan")
  let orphan = RelatedDataCandidate(
    id: installed.id, path: installed.path, classification: .orphanVerified,
    reason: .orphanVerified, snapshot: installed.snapshot, receipt: nil, bundleID: "qa.lighten.orphan")
  let inventory = BundleInventory(applications: [], unidentifiedPaths: [], complete: true, observedAt: Date())
  let plan = ActionPlan(
    snapshotRunID: UUID(), kind: .trash,
    items: [PlanItem(id: UUID(), sourcePath: orphan.path, inventory: [], ancestors: [])])
  let store = AppsStore(
    pictures: flowPictures(root),
    orphanPlanBuilder: { candidates in
      #expect(candidates.map(\.path) == [orphan.path])
      return plan
    }, running: AppsClosedSource(),
    events: {
      AsyncStream {
        $0.yield(.orphans([orphan]))
        $0.yield(.completed(inventory, []))
        $0.finish()
      }
    })
  let actions = ActionStore()
  store.startScan(actions: actions)
  try await waitFlow { !store.busy }
  #expect(store.orphanCandidates.count == 1)
  #expect(store.selectedOrphanPaths.isEmpty)
  store.toggleOrphan(orphan.path, actions: actions)
  await store.prepareOrphans(actions: actions)
  #expect(actions.pending?.plan == plan)
  store.toggleOrphan(orphan.path, actions: actions)
  #expect(actions.pending == nil)
}
