import CryptoKit
import Darwin
import Foundation
import LightenKit
import Testing

@testable import Lighten
@testable import LightenKit

private struct AppsClosedSource: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
}

private struct AppsUnknownSource: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { nil }
}

@Test("An unknown earlier running observation does not block explicit root review")
@MainActor func appsFinalRunningCheckIsHonest() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-unknown.app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
  let package = PlanItem(
    id: UUID(), sourcePath: app, inventory: [], ancestors: [], policy: .wholeBundle,
    applicationBundleID: "qa.lighten.flow")
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [package])
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { _, _, _ in
      RelatedDataService.AvailableUninstallPlan(plan: plan, rejections: [])
    }, running: AppsUnknownSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: app)]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
  store.togglePackage(actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending?.plan == plan)
  #expect(store.message == nil)
}

private func flowReport(
  path: String, candidates: [RelatedDataCandidate] = [], bundleID: String = "qa.lighten.flow",
  identity: FileIdentity? = nil
) -> ApplicationReport {
  ApplicationReport(
    path: path, bundleID: bundleID, version: "1", signerTeamID: nil,
    logical: ByteAggregate(knownLowerBound: 64, completeTotal: 64),
    allocated: ByteAggregate(knownLowerBound: 64, completeTotal: 64),
    knownItemCount: 1, partial: false, related: candidates, manualUninstallerSuggested: false,
    displayRootIdentity: identity)
}

private func flowCandidate(_ path: String) -> RelatedDataCandidate {
  RelatedDataCandidate(
    id: path, path: path, classification: .installed, reason: .installed,
    snapshot: ScanSnapshot(rootPath: path, volumeDevice: 1, entries: [], nodes: []), receipt: nil)
}

private func flowPictures(_ root: String) -> ResultPictureStore {
  ResultPictureStore(directory: root + "/results")
}

@Test("Apps presents one remaining uninstall plan with exact refused data paths")
@MainActor func appsAvailablePlanKeepsRemainingItemsAndRefusals() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-partial.app"
  let accepted = flowCandidate(root + "/Library/Caches/qa.lighten.flow")
  let refused = flowCandidate(root + "/Library/Preferences/qa.lighten.flow.plist")
  let missing = root + "/Library/Logs/qa.lighten.missing"
  let item = PlanItem(id: UUID(), sourcePath: accepted.path, inventory: [], ancestors: [])
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [item])
  let rejection = PlanRejection(.unavailable, path: refused.path, ruleID: "unsupportedInstalledData")
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { report, candidates, package in
      #expect(report.path == app)
      #expect(Set(candidates.map(\.path)) == [accepted.path, refused.path])
      #expect(!package)
      return RelatedDataService.AvailableUninstallPlan(plan: plan, rejections: [rejection])
    }, running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: app, candidates: [accepted, refused])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
  store.toggleData(accepted.path, actions: actions)
  store.toggleData(refused.path, actions: actions)
  store.selectedDataPaths.insert(missing)
  await store.prepareSelectedData(actions: actions)
  let presentation = try #require(actions.pending)
  #expect(presentation.plan == plan)
  #expect(presentation.items.map(\.path) == [accepted.path])
  #expect(Set(presentation.rejectedItems.map(\.path)) == [refused.path, missing])
  #expect(presentation.rejectedItems.contains(rejection))
  #expect(actions.result == nil && actions.resultRejections.isEmpty)
  #expect(store.selectedDataPaths == [accepted.path, refused.path, missing])
  #expect(store.message == nil)
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
}

@Test("A fresh package refusal blocks selected app data and preserves its concrete reason")
@MainActor func appsPackageRefusalStopsEntireReview() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-refused.app"
  let candidate = flowCandidate(root + "/Library/Caches/qa.lighten.flow")
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { _, candidates, package in
      #expect(candidates.map(\.path) == [candidate.path])
      #expect(!package)
      return RelatedDataService.AvailableUninstallPlan(
        plan: nil, rejections: [PlanRejection(.processActive, path: app, ruleID: "Fixture Helper")])
    }, running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: app, candidates: [candidate])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
  store.toggleData(candidate.path, actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending == nil)
  #expect(actions.failure(at: app)?.contains("Quit") == true)
  #expect(actions.failure(at: app)?.contains("Fixture Helper") == false)
  #expect(actions.resultRejections.map(\.path) == [app])
  #expect(actions.result == nil && store.message == nil)
  #expect(store.selectedDataPaths == [candidate.path])
  #expect(!store.preparing)
}

@Test("All refused app data explains known related failure codes and exact paths")
@MainActor func appsAllDataRefusedShowsSpecificFailure() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-data-refused.app"
  let candidate = flowCandidate(root + "/Library/Caches/qa.lighten.flow")
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { _, _, _ in
      RelatedDataService.AvailableUninstallPlan(
        plan: nil, rejections: [PlanRejection(.unavailable, path: candidate.path, ruleID: "unsupportedInstalledData")])
    }, running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: app, candidates: [candidate])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
  store.toggleData(candidate.path, actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending == nil)
  #expect(actions.failure(at: candidate.path)?.contains("not eligible") == true)
  #expect(actions.resultRejections.map(\.path) == [candidate.path])
  #expect(actions.result == nil && store.message == nil)
}

private actor AppsAvailableGate {
  private var request: CheckedContinuation<RelatedDataService.AvailableUninstallPlan, Never>?
  private var arrival: CheckedContinuation<Void, Never>?
  func outcome() async -> RelatedDataService.AvailableUninstallPlan {
    await withCheckedContinuation {
      request = $0
      arrival?.resume()
      arrival = nil
    }
  }
  func waitForArrival() async {
    if request != nil { return }
    await withCheckedContinuation { arrival = $0 }
  }
  func finish(_ outcome: RelatedDataService.AvailableUninstallPlan) {
    request?.resume(returning: outcome)
    request = nil
  }
}

@Test(
  "An all-rejected Apps review keeps the selected app with a Finder step and no action record",
  arguments: [false, true])
@MainActor func appsAdministratorRefusalIsKeptFeedback(throwsRefusal: Bool) async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-administrator.app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
  let identity = try DescriptorFileSystem.identity(at: app)
  let rejection = PlanRejection(.needsAdministrator, path: app)
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { _, _, _ in
      if throwsRefusal { throw rejection }
      return .init(plan: nil, rejections: [rejection])
    }, running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let journalPath = root + "/journal.jsonl"
  let actions = ActionStore(journal: JSONLActionJournal(path: journalPath))
  store.reports = [flowReport(path: app, identity: identity)]
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
  store.togglePackage(actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending == nil && actions.result == nil && actions.resultKind == nil)
  #expect(actions.resultRejections == [rejection])
  #expect(actions.completedSummary == String(localized: "No items were removed."))
  #expect(actions.resultFailures.isEmpty && actions.resultSummaries.isEmpty)
  #expect(!actions.canUndoLatest && actions.latestTrashPaths.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: journalPath))
  #expect(store.selectedReport?.path == app && store.packageSelected && store.packageItemResults.isEmpty)
  #expect(store.message == nil && actions.message == nil)
  #expect(try DescriptorFileSystem.identity(at: app) == identity)
  store.togglePackage(actions: actions)
  #expect(actions.resultRejections.isEmpty && actions.completedSummary == nil)
  #expect(actions.failure(at: app) == nil)
  #expect(store.selectedReport?.path == app)
}

@Test("Cancelled or changed Apps choices discard a late all-rejected review", arguments: [false, true])
@MainActor func appsLateRefusalIsDiscarded(cancelTask: Bool) async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-late-refusal.app"
  let gate = AppsAvailableGate()
  let store = AppsStore(
    pictures: flowPictures(root), availableUninstallPlanBuilder: { _, _, _ in await gate.outcome() },
    running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: app), flowReport(path: root + "/LightenQA-other.app")]
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
  store.togglePackage(actions: actions)
  let preparation = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForArrival()
  if cancelTask {
    preparation.cancel()
  } else {
    store.select(root + "/LightenQA-other.app", actions: actions, selectPackage: false)
  }
  await gate.finish(.init(plan: nil, rejections: [PlanRejection(.needsAdministrator, path: app)]))
  await preparation.value
  #expect(actions.pending == nil && actions.result == nil && actions.resultRejections.isEmpty)
  #expect(actions.completedSummary == nil && !store.preparing)
  #expect(
    store.message
      == (cancelTask ? nil : String(localized: "Selection changed. Select an item to continue the removal review.")))
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
}

@Test("A new all-rejected Apps review replaces prior package outcome rows")
@MainActor func appsKeptFeedbackReplacesPackageRows() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-prior-result.app"
  let item = PlanItem(
    id: UUID(), sourcePath: app, inventory: [], ancestors: [], policy: .wholeBundle,
    applicationBundleID: "qa.lighten.flow")
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [item])
  let gate = AppsAvailableGate()
  let store = AppsStore(
    pictures: flowPictures(root), availableUninstallPlanBuilder: { _, _, _ in await gate.outcome() },
    running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: app)]
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
  store.togglePackage(actions: actions)
  let firstReview = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForArrival()
  await gate.finish(.init(plan: plan, rejections: []))
  await firstReview.value
  #expect(actions.pending?.plan == plan)
  actions.pending = nil
  actions.publishExecution(
    plan: plan,
    result: ActionResult(
      planID: plan.id, items: [ItemActionResult(itemID: item.id, outcome: .failed, detail: "userPermissionDenied")]),
    summaries: [])
  store.observeResult(actions: actions)
  #expect(store.packageItemResults.map(\.sourcePath) == [app])
  let secondReview = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForArrival()
  await gate.finish(.init(plan: nil, rejections: [PlanRejection(.needsAdministrator, path: app)]))
  await secondReview.value
  #expect(store.packageItemResults.isEmpty)
  #expect(actions.result == nil && actions.resultFailures.isEmpty)
  #expect(actions.resultRejections == [PlanRejection(.needsAdministrator, path: app)])
  #expect(store.selectedReport?.path == app && store.packageSelected)
}

@Test("Changing an Apps choice discards a late available plan and its skipped reasons")
@MainActor func appsLateAvailableReviewIsDiscarded() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-late-review.app"
  let candidate = flowCandidate(root + "/Library/Caches/qa.lighten.flow")
  let item = PlanItem(id: UUID(), sourcePath: candidate.path, inventory: [], ancestors: [])
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [item])
  let gate = AppsAvailableGate()
  let store = AppsStore(
    pictures: flowPictures(root), availableUninstallPlanBuilder: { _, _, _ in await gate.outcome() },
    running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: app, candidates: [candidate])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
  store.toggleData(candidate.path, actions: actions)
  let preparation = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForArrival()
  store.toggleData(candidate.path, actions: actions)
  await gate.finish(
    RelatedDataService.AvailableUninstallPlan(
      plan: plan, rejections: [PlanRejection(.unavailable, path: root + "/late-refusal")]))
  await preparation.value
  #expect(actions.pending == nil)
  #expect(store.message == String(localized: "Selection changed. Select an item to continue the removal review."))
  #expect(!store.preparing)
}

@Test(
  "Linked and wrapper application choices reach one fresh package review", arguments: [false, true])
@MainActor func appsNormalPackagesReachReview(isWrapper: Bool) async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let appPath = root + "/LightenQA-listed.app"
  let physicalPath = isWrapper ? appPath : root + "/LightenQA-physical.app"
  try FileManager.default.createDirectory(atPath: physicalPath, withIntermediateDirectories: false)
  if !isWrapper {
    try FileManager.default.createSymbolicLink(atPath: appPath, withDestinationPath: physicalPath)
  }
  let candidate = flowCandidate(root + "/Library/Caches/qa.lighten.flow")
  var report = flowReport(path: appPath, candidates: [candidate])
  report.isIOSWrapper = isWrapper
  report.linkTarget = isWrapper ? nil : physicalPath
  let physical = PlanItem(
    id: UUID(), sourcePath: physicalPath, inventory: [], ancestors: [], policy: .wholeBundle,
    applicationBundleID: report.bundleID)
  let link = PlanItem(
    id: UUID(), sourcePath: appPath, inventory: [], ancestors: [], policy: .applicationLink,
    packageLinkTargetItemID: physical.id)
  let data = PlanItem(id: UUID(), sourcePath: candidate.path, inventory: [], ancestors: [])
  let plan = ActionPlan(
    snapshotRunID: UUID(), kind: .trash, items: [physical, data] + (isWrapper ? [] : [link]))
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { requested, candidates, includePackage in
      #expect(requested.path == appPath && includePackage)
      #expect(candidates.map(\.path) == [candidate.path])
      return .init(plan: plan, rejections: [])
    }, running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [report]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(appPath, actions: actions, selectPackage: false)
  #expect(store.selectedPath == appPath)
  #expect(store.canSelect(candidate, app: report))
  store.togglePackage(actions: actions)
  #expect(store.selectedDataPaths.isEmpty)
  store.toggleData(candidate.path, actions: actions)
  await store.prepareSelectedData(actions: actions)
  let presentation = try #require(actions.pending)
  #expect(presentation.plan == plan)
  #expect(Set(presentation.items.map(\.path)) == Set(plan.items.map(\.sourcePath)))
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
}

@Test("Identifierless package review keeps its missing ID and selects no related data")
@MainActor func appsIdentifierlessPackageReview() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-identifierless.app"
  try FileManager.default.createDirectory(
    atPath: app + "/Contents", withIntermediateDirectories: true)
  let info = app + "/Contents/Info.plist"
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleName": "LightenQA"], format: .xml, options: 0
  )
  .write(to: URL(fileURLWithPath: info))
  let candidate = flowCandidate(root + "/Library/Caches/qa.lighten.unmatched")
  let report = ApplicationReport(
    path: app, bundleID: nil, version: nil, signerTeamID: nil,
    logical: ByteAggregate(knownLowerBound: 64, completeTotal: 64),
    allocated: ByteAggregate(knownLowerBound: 64, completeTotal: 64),
    knownItemCount: 1, partial: false, related: [candidate], manualUninstallerSuggested: false)
  let observation = ApplicationPackageObservation(
    infoRelativePath: "Contents/Info.plist",
    infoIdentity: try DescriptorFileSystem.identity(at: info), bundleIdentifier: nil)
  let package = PlanItem(
    id: UUID(), sourcePath: app, inventory: [], ancestors: [], policy: .wholeBundle,
    applicationPackageObservation: observation)
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [package])
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { requested, candidates, includePackage in
      #expect(requested.bundleID == nil && candidates.isEmpty && includePackage)
      return .init(plan: plan, rejections: [])
    },
    selectedReview: { _, _ in
      Issue.record("Identifierless app acquired an ID-based review")
      return nil
    },
    running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [report]
  store.inventoryComplete = true
  store.select(app, actions: actions, selectPackage: false)
  store.togglePackage(actions: actions)
  #expect(store.canSelect(candidate, app: report) && store.selectedDataPaths.isEmpty)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending?.plan == plan)
  #expect(actions.pending?.plan.items.first?.applicationBundleID == nil)
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
}

@Test(
  "Linked application results retain the row whenever the physical and leaf outcomes differ",
  arguments: [true, false])
@MainActor func appsLinkedPartialResultsKeepBothPaths(physicalApplied: Bool) async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let listed = root + "/LightenQA-listed.app"
  let physicalPath = root + "/LightenQA-physical.app"
  try FileManager.default.createDirectory(atPath: physicalPath, withIntermediateDirectories: false)
  try FileManager.default.createSymbolicLink(atPath: listed, withDestinationPath: physicalPath)
  let identity = try DescriptorFileSystem.identity(at: physicalPath)
  var report = flowReport(path: listed, identity: identity)
  report.linkTarget = physicalPath
  let physical = PlanItem(
    id: UUID(), sourcePath: physicalPath,
    inventory: [ScanEntry(parentID: nil, path: physicalPath, identity: identity, issues: [], readable: true)],
    ancestors: [], policy: .wholeBundle,
    applicationBundleID: report.bundleID)
  let leaf = PlanItem(
    id: UUID(), sourcePath: listed, inventory: [], ancestors: [], policy: .applicationLink,
    packageLinkTargetItemID: physical.id)
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [physical, leaf])
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { _, _, _ in .init(plan: plan, rejections: []) },
    running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [report]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(listed, actions: actions, selectPackage: false)
  store.togglePackage(actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending?.plan == plan)
  actions.pending = nil
  actions.onDisplayChange = { change in
    store.applyDisplayChange(change)
    #expect(store.reports.map(\.path) == [listed])
  }
  let result = ActionResult(
    planID: plan.id,
    items: [
      ItemActionResult(
        itemID: physical.id, outcome: physicalApplied ? .applied : .failed,
        detail: physicalApplied ? nil : "fixtureMoveFailed"),
      ItemActionResult(
        itemID: leaf.id, outcome: physicalApplied ? .skipped : .applied,
        detail: physicalApplied ? "changedSinceScan" : nil),
    ])
  actions.publishExecution(plan: plan, result: result, summaries: [])
  store.observeResult(actions: actions)
  #expect(store.selectedReport?.path == listed)
  #expect(Set(store.packageItemResults.map(\.sourcePath)) == [listed, physicalPath])
  #expect(
    store.packageItemResults.first { !$0.isLink }?.outcome == (physicalApplied ? .applied : .failed)
  )
  #expect(
    store.packageItemResults.first { $0.isLink }?.outcome == (physicalApplied ? .skipped : .applied)
  )
  #expect(store.packageUnavailableReason(report) == nil)
  #expect(!store.packageSelected)
  #expect(
    store.packageItemResults.first { $0.outcome != .applied }?.detail
      == (physicalApplied ? "changedSinceScan" : "fixtureMoveFailed"))
  #expect(actions.pending == nil)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending == nil && store.selectedReport?.path == listed)
}

@Test("A linked review rejects a forged leaf without its same-plan physical item")
@MainActor func appsLinkedConfirmationRejectsMissingPair() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let listed = root + "/LightenQA-listed.app"
  let physicalPath = root + "/LightenQA-physical.app"
  try FileManager.default.createDirectory(atPath: physicalPath, withIntermediateDirectories: false)
  try FileManager.default.createSymbolicLink(atPath: listed, withDestinationPath: physicalPath)
  var report = flowReport(path: listed)
  report.linkTarget = physicalPath
  let leaf = PlanItem(
    id: UUID(), sourcePath: listed, inventory: [], ancestors: [], policy: .applicationLink,
    packageLinkTargetItemID: UUID())
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { _, _, _ in
      .init(plan: ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [leaf]), rejections: [])
    }, running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [report]
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(listed, actions: actions, selectPackage: false)
  store.togglePackage(actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending == nil)
  #expect(actions.resultRejections.map(\.path) == [listed])
  #expect(actions.result == nil && store.message == nil)
}

@Test("Discovery caches iOS wrapper metadata before measurements and preserves it in every report")
@MainActor func appsWrapperMetadataIsCachedAndPropagated() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let appPath = root + "/Applications/LightenQA-wrapper.app"
  let inner = appPath + "/Wrapper/LightenQA-inner.app"
  try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
  let plist = ["CFBundleIdentifier": "qa.lighten.wrapper", "CFBundleName": "LightenQA"]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: inner + "/Info.plist"))
  let related = RelatedDataService(
    homeDirectory: root, applicationRoots: [root + "/Applications"], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    packageActivity: { path in
      #expect(path == appPath)
      return ApplicationActivity(state: .clearObservedProcesses)
    })
  let discovery = ApplicationDiscovery(related: related)
  var metadataSeen = false
  var measuredSeen = false
  var completeSeen = false
  for await event in discovery.events() {
    switch event {
    case .inventory(_, let reports):
      let report = try #require(reports.first { $0.path == appPath })
      #expect(report.isIOSWrapper)
      metadataSeen = true
    case .measured(let reports):
      let report = try #require(reports.first { $0.path == appPath })
      #expect(report.isIOSWrapper)
      measuredSeen = true
    case .completed(_, let reports):
      let report = try #require(reports.first { $0.path == appPath })
      #expect(report.isIOSWrapper)
      completeSeen = true
    case .listed, .orphans, .session, .related, .ownershipReady: break
    }
  }
  #expect(metadataSeen && measuredSeen && completeSeen)
  let focused = try #require(await discovery.report(path: appPath))
  #expect(focused.isIOSWrapper)
  #expect(focused.bundleID == "qa.lighten.wrapper")
  #expect(focused.related.isEmpty)
  let store = AppsStore(
    pictures: flowPictures(root), relatedService: related,
    droppedReport: { _ in focused }, running: AppsClosedSource())
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  await store.acceptDrop([URL(fileURLWithPath: appPath)], actions: actions)
  #expect(store.reports.first?.isIOSWrapper == true)
  #expect(store.selectedPath == appPath)
  let plan = try #require(
    actions.pending?.plan, "Wrapper confirmation missing; Apps message: \(store.message ?? "none")")
  #expect(plan.items.count == 1 && plan.items[0].sourcePath == appPath)
  #expect(plan.items[0].userSelection == true)
  #expect(plan.items[0].applicationBundleID == nil && plan.items[0].applicationPackageObservation == nil)
  #expect(plan.items[0].inventory.count == 1)
  let rootIdentity = try #require(plan.items[0].inventory.first?.identity)
  expectSameFlowRoot(rootIdentity, try DescriptorFileSystem.identity(at: appPath))
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
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
  store.select(reports[0].path, actions: actions, selectPackage: false)
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
  store.select(app, actions: actions, selectPackage: false)
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
      ItemActionResult(itemID: secondItem.id, outcome: .skipped, detail: "changedSinceScan"),
    ])
  store.observeResult(actions: actions)
  #expect(!store.needsRescan)
  #expect(store.selectedDataPaths == [second.path])
  #expect(!store.selectedDataPaths.contains(first.path))
  #expect(store.selectedReport?.related.map(\.path) == [second.path])
  #expect(actions.result?.items.first { $0.itemID == secondItem.id }?.detail == "changedSinceScan")
  store.observeResult(actions: actions)
  #expect(store.selectedDataPaths == [second.path])
  store.toggleData(second.path, actions: actions)
  #expect(store.selectedDataPaths.isEmpty)
  store.observeResult(actions: actions)
  #expect(store.selectedDataPaths.isEmpty)
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
    }, droppedReport: { _ in report }, preferences: flowAutomaticPreferences(), running: AppsClosedSource())
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

@Test("An external application uses explicit root review without an installed-root entry")
@MainActor func appsExternalDropDefaultPlanner() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-external.app"
  let bundleID = "qa.lighten." + UUID().uuidString.lowercased()
  try FileManager.default.createDirectory(
    atPath: app + "/Contents", withIntermediateDirectories: true)
  let plist = [
    "CFBundleIdentifier": bundleID, "CFBundleName": "LightenQA", "CFBundlePackageType": "APPL",
  ]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
  try Data("owned fixture".utf8).write(to: URL(fileURLWithPath: app + "/Contents/payload"))
  let fixtureReport = flowReport(path: app, bundleID: bundleID)
  let related = RelatedDataService(
    homeDirectory: root, applicationRoots: [], writeVerifiedReceipts: false,
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let store = AppsStore(
    pictures: flowPictures(root), relatedService: related,
    droppedReport: { _ in fixtureReport }, running: AppsClosedSource())
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  let began = ContinuousClock.now
  await store.acceptDrop([URL(fileURLWithPath: app)], actions: actions)
  print("Apps external fixture default drop to confirmation: \(began.duration(to: .now))")
  let plan = try #require(actions.pending?.plan)
  #expect(plan.kind == .trash)
  #expect(plan.items.count == 1)
  let package = try #require(plan.items.first)
  #expect(package.sourcePath == app)
  #expect(package.userSelection == true)
  #expect(package.applicationBundleID == nil && package.policy == nil)
  let packageRoot = try #require(package.inventory.first { $0.path == app && $0.parentID == nil })
  let packageIdentity = try #require(packageRoot.identity)
  let currentIdentity = try DescriptorFileSystem.identity(at: app)
  #expect(packageIdentity.kind == .directory)
  expectSameFlowRoot(packageIdentity, currentIdentity)
  #expect(!package.containsOpaquePackages)
  #expect(package.inventory.count == 1)
  #expect(FileManager.default.fileExists(atPath: app))
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))

  // A fresh execution plan moves only this owned fixture; native history Undo must preserve its files.
  let before = try appFileManifest(app)
  #expect(Set(before.keys) == ["Contents/Info.plist", "Contents/payload"])
  let trash = root + "/trash"
  try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: false)
  let journal = JSONLActionJournal(path: root + "/journal.jsonl")
  let executionPlan = try related.planUninstall(
    app: InstalledApplication(bundleID: bundleID, path: app, version: nil), selectedRelated: [])
  let executionPackage = try #require(executionPlan.items.first)
  #expect(executionPlan.id != plan.id)
  let moved = try await ActionExecutor(
    journal: journal, trash: OwnedFlowTrash(destination: trash),
    guardService: ActionGuard(homeDirectory: root), related: related,
    runningApplications: AppsClosedSource(), applicationActivity: ClearFlowApplicationActivity()
  ).execute(executionPlan)
  #expect(moved.items.map(\.outcome) == [.applied])
  #expect(!FileManager.default.fileExists(atPath: app))
  let history = ActionHistory(journal: journal, homeDirectory: root)
  let historyItem = try #require(
    try await history.reconcile().items.first { $0.planID == executionPlan.id })
  #expect(historyItem.state == .inTrash)
  let undoGroup = try await history.loadGroup(planID: executionPlan.id)
  #expect(undoGroup.canUndo)
  try await history.undo(planID: executionPlan.id, itemID: executionPackage.id)
  #expect(try appFileManifest(app) == before)
  expectSameFlowRoot(try DescriptorFileSystem.identity(at: app), currentIdentity)
}

private func expectSameFlowRoot(_ actual: FileIdentity, _ expected: FileIdentity) {
  #expect(actual.kind == .directory)
  #expect(expected.kind == .directory)
  #expect(actual.device == expected.device)
  #expect(actual.inode == expected.inode)
  #expect(actual.birthSeconds != nil)
  #expect(actual.birthNanoseconds != nil)
  #expect(actual.birthSeconds == expected.birthSeconds)
  #expect(actual.birthNanoseconds == expected.birthNanoseconds)
  #expect(actual.flags == expected.flags)
}

private struct OwnedFlowTrash: TrashMoving {
  let destination: String
  func moveToTrash(path: String) async throws -> String {
    let target = destination + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: target)
    return target
  }
}

private struct ClearFlowApplicationActivity: ApplicationActivitySource {
  func activity(applicationPath: String) async -> ApplicationActivity {
    ApplicationActivity(state: .clearObservedProcesses)
  }
}

private func appFileManifest(_ path: String) throws -> [String: String] {
  let enumerator = try #require(FileManager.default.enumerator(atPath: path))
  var manifest: [String: String] = [:]
  while let name = enumerator.nextObject() as? String {
    let file = path + "/" + name
    if try DescriptorFileSystem.identity(at: file).kind == .regular {
      let data = try Data(contentsOf: URL(fileURLWithPath: file))
      manifest[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
  }
  return manifest
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
    }, preferences: flowAutomaticPreferences(), running: AppsClosedSource())
  let actions = ActionStore()
  store.reports = [flowReport(path: app, candidates: [first, skipped, medium])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
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
  #expect(store.selectedOrphanPaths == [skipped.path])
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

private func flowUnprovenCandidate(_ path: String, inode: UInt64 = 2) -> RelatedDataCandidate {
  let identity = FileIdentity(
    device: 1, inode: inode, changeSeconds: 1, changeNanoseconds: 0,
    logicalBytes: 64, allocatedBytes: 64, linkCount: 1, flags: 0, kind: .directory,
    birthSeconds: 1, birthNanoseconds: 0)
  return RelatedDataCandidate(
    id: path, path: path, classification: .unprovenNameOnly, reason: .nameOnly,
    snapshot: ScanSnapshot(
      rootPath: path, volumeDevice: 1,
      entries: [ScanEntry(parentID: nil, path: path, identity: identity, issues: [], readable: true)], nodes: []),
    receipt: nil, explicitManualChoiceAvailable: true)
}

@Test("Name-only app data needs an explicit choice and enters review without app ownership", arguments: [false, true])
@MainActor func appsUnprovenRequiresExplicitChoice(includePackage: Bool) async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/LightenQA-name.app"
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  let candidate = flowUnprovenCandidate(root + "/Library/Application Support/LightenQA-name")
  let package = PlanItem(
    id: UUID(), sourcePath: path, inventory: [], ancestors: [], policy: .wholeBundle,
    applicationBundleID: "qa.lighten.flow")
  let data = PlanItem(id: UUID(), sourcePath: candidate.path, inventory: [], ancestors: [])
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: includePackage ? [package, data] : [data])
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { _, candidates, _ in
      #expect(candidates.allSatisfy { $0.classification != .unprovenNameOnly })
      Issue.record("An explicit name-only choice reached the automatic ownership planner")
      return .init(plan: nil, rejections: [])
    },
    explicitUninstallPlanBuilder: { report, candidates, packageSelected, manual in
      #expect(report.path == path)
      #expect(candidates.isEmpty)
      #expect(packageSelected == includePackage)
      #expect(manual.map(\.path) == [candidate.path])
      #expect(manual.first?.snapshot?.entries.first?.identity == candidate.snapshot?.entries.first?.identity)
      return .init(plan: plan, rejections: [])
    }, running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: path, candidates: [candidate])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(path, actions: actions, selectPackage: false)
  #expect(!candidate.canSelect && !candidate.defaultSelected)
  store.togglePackage(actions: actions)
  #expect(store.packageSelected && store.selectedDataPaths.isEmpty)
  if !includePackage { store.togglePackage(actions: actions) }
  store.toggleData(candidate.path, actions: actions)
  #expect(store.selectedDataPaths == [candidate.path])
  await store.prepareSelectedData(actions: actions)
  let pending = try #require(actions.pending)
  #expect(pending.plan == plan && pending.plan.kind == .trash)
  #expect(pending.permanentPlanBuilder != nil)
  let summary = try #require(pending.items.first { $0.path == candidate.path })
  #expect(summary.reason.contains("ownership is unproven"))
  #expect(summary.reason.contains("Undo"))
  #expect(data.installedRelatedProof == nil && data.orphanRelatedProof == nil && data.relatedProof == nil)
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
  store.toggleData(candidate.path, actions: actions)
  #expect(store.selectedDataPaths.isEmpty && actions.pending == nil)
}

@Test("Assigning a name-only path cannot fabricate the user's explicit choice")
@MainActor func appsUnprovenPathAssignmentIsNotAuthorization() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/LightenQA-name.app"
  let candidate = flowUnprovenCandidate(root + "/Library/Application Support/LightenQA-name")
  let store = AppsStore(
    pictures: flowPictures(root),
    explicitUninstallPlanBuilder: { _, _, _, _ in
      Issue.record("A path assignment impersonated an explicit user choice")
      return .init(plan: nil, rejections: [])
    }, running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: path, candidates: [candidate])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(path, actions: actions, selectPackage: false)
  store.selectedDataPaths = [candidate.path]
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending == nil)
  #expect(actions.resultRejections.map(\.path) == [candidate.path])
  store.selectedDataPaths = []
  store.toggleData(candidate.path, actions: actions)
  #expect(store.selectedDataPaths == [candidate.path])
  store.selectedDataPaths = []
  store.selectedDataPaths = [candidate.path]
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending == nil)
  #expect(actions.resultRejections.map(\.path) == [candidate.path])
}

@Test("Revoking a name-only choice discards a late plan even if its path is assigned again")
@MainActor func appsRevokedUnprovenChoiceDiscardsLatePlan() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/LightenQA-name.app"
  let candidate = flowUnprovenCandidate(root + "/Library/Application Support/LightenQA-name")
  let plan = ActionPlan(
    snapshotRunID: UUID(), kind: .trash,
    items: [PlanItem(id: UUID(), sourcePath: candidate.path, inventory: [], ancestors: [])])
  let gate = AppsAvailableGate()
  let store = AppsStore(
    pictures: flowPictures(root),
    explicitUninstallPlanBuilder: { _, _, _, manual in
      #expect(manual.map(\.path) == [candidate.path])
      return await gate.outcome()
    }, running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: path, candidates: [candidate])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(path, actions: actions, selectPackage: false)
  store.toggleData(candidate.path, actions: actions)
  let preparation = Task { await store.prepareSelectedData(actions: actions) }
  await gate.waitForArrival()
  store.selectedDataPaths = []
  store.selectedDataPaths = [candidate.path]
  await gate.finish(.init(plan: plan, rejections: []))
  await preparation.value
  #expect(actions.pending == nil && !store.preparing)
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
}

@Test("Real result publication preserves unselected, refused and failed app data before observeResult")
@MainActor func appsRealPublicationRetainsEveryRemainingReason() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-remaining.app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
  let identity = try DescriptorFileSystem.identity(at: app)
  let unselected = flowCandidate(root + "/unselected")
  let refused = flowCandidate(root + "/refused")
  let failed = flowCandidate(root + "/failed")
  let package = PlanItem(
    id: UUID(), sourcePath: app,
    inventory: [ScanEntry(parentID: nil, path: app, identity: identity, issues: [], readable: true)],
    ancestors: [], policy: .wholeBundle, applicationBundleID: "qa.lighten.flow")
  let data = PlanItem(id: UUID(), sourcePath: failed.path, inventory: [], ancestors: [])
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [data, package])
  let rejection = PlanRejection(.changedSinceScan, path: refused.path)
  let remaining = ActionPlan(
    snapshotRunID: UUID(), kind: .trash,
    items: [PlanItem(id: UUID(), sourcePath: unselected.path, inventory: [], ancestors: [])])
  let store = AppsStore(
    pictures: flowPictures(root),
    availableUninstallPlanBuilder: { _, _, _ in .init(plan: plan, rejections: [rejection]) },
    remainingDataPlanBuilder: { candidates in
      #expect(candidates.map(\.path) == [unselected.path])
      return .init(plan: remaining, rejections: [])
    }, preferences: flowAutomaticPreferences(), running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  let report = flowReport(path: app, candidates: [unselected, refused, failed], identity: identity)
  store.reports = [report]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
  store.togglePackage(actions: actions)
  store.toggleData(unselected.path, actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending?.plan == plan)
  actions.pending = nil
  actions.onDisplayChange = { change in
    store.applyDisplayChange(change)
    // This callback runs before the SwiftUI observer, which must not need the deleted app row.
    #expect(store.reports.isEmpty)
    #expect(Set(store.orphanCandidates.map(\.path)) == [unselected.path, refused.path, failed.path])
  }
  try FileManager.default.removeItem(atPath: app)
  actions.publishExecution(
    plan: plan,
    result: ActionResult(
      planID: plan.id,
      items: [
        ItemActionResult(itemID: package.id, outcome: .applied, mutationStage: .trashMoveObserved),
        ItemActionResult(itemID: data.id, outcome: .failed, detail: "changedItem", mutationStage: .sourceRetained),
      ]), summaries: [], rejections: [rejection])
  store.observeResult(actions: actions)
  for turkish in [false, true] {
    #expect(
      store.retainedReason(unselected, turkish: turkish)?.primaryReason.contains(turkish ? "seçilmedi" : "not selected")
        == true)
    #expect(
      store.retainedReason(refused, turkish: turkish)?.primaryReason.contains(turkish ? "reddedildi" : "refused")
        == true)
    #expect(
      store.retainedReason(failed, turkish: turkish)?.primaryReason.contains(turkish ? "taşınmadı" : "not moved")
        == true)
  }
  store.publishOrphans([])  // The exact .orphans event handler must preserve retained rows.
  #expect(store.orphanCandidates.count == 3)
  #expect(store.selectedOrphanPaths.isEmpty)
  store.toggleOrphan(unselected.path, actions: actions)
  await store.prepareOrphans(actions: actions)
  #expect(actions.pending?.plan == remaining)
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
}

@Test("Shared ownership remains unselected evidence after removal but the user can choose the row")
@MainActor func appsRemainingRowsPreserveOwnershipVeto() {
  let path = "/private/tmp/LightenQA-refused-data"
  var candidate = flowCandidate(path)
  candidate.refusalEvidence = [
    RelatedOwnershipRefusalEvidence(
      candidatePath: path, bundleID: "qa.other", reason: .sharedInstalledOwners,
      ownerPaths: ["/fixture/Other.app"], nextStep: "review-other-installations", detail: "internal detail")
  ]
  let store = AppsStore(events: { AsyncStream { $0.finish() } })
  let identity = FileIdentity(
    device: 1, inode: 11, changeSeconds: 2, changeNanoseconds: 0, logicalBytes: 0, allocatedBytes: 0,
    linkCount: 1, flags: 0, kind: .directory, birthSeconds: 2, birthNanoseconds: 0)
  let app = "/fixture/Removed.app"
  store.reports = [flowReport(path: app, candidates: [candidate], identity: identity)]
  store.applyDisplayChange(
    ActionDisplayChange(
      kind: .applied,
      items: [
        ActionDisplayItem(
          planID: UUID(), itemID: UUID(), path: app, identity: identity, size: .unknown,
          label: "Removed app", returnedTrashPath: nil)
      ]))
  #expect(store.retainedAppData[path] != nil)
  store.publishOrphans([flowCandidate(path)])
  #expect(store.orphanCandidates.first?.refusalEvidence == candidate.refusalEvidence)
  #expect(store.canSelectOrphan(candidate))
  #expect(!store.automaticSelectionAllowed(candidate))
}

@Test(
  "Package selection uses all evidence kinds and never selects vendor or live evidence alone",
  arguments: [
    ([RelatedDataProvenanceKind.vendorDirectory], false),
    ([RelatedDataProvenanceKind.liveProcess], false),
    ([RelatedDataProvenanceKind.vendorDirectory, .liveProcess], false),
    ([RelatedDataProvenanceKind.bundleIdentifier, .liveProcess], true),
    ([RelatedDataProvenanceKind.installerReceipt, .vendorDirectory], true),
  ])
@MainActor func appsPackageAutomaticEvidenceGate(_ kinds: [RelatedDataProvenanceKind], allowed: Bool) async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-auto.app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
  var candidate = flowCandidate(root + "/data")
  candidate.evidenceKinds = kinds
  let store = AppsStore(
    pictures: flowPictures(root), preferences: flowAutomaticPreferences(), running: AppsClosedSource())
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: app, candidates: [candidate])]
  store.inventoryComplete = true
  store.runningCheckedIDs = ["qa.lighten.flow"]
  store.select(app, actions: actions, selectPackage: false)
  store.togglePackage(actions: actions)
  #expect(store.selectedDataPaths.contains(candidate.path) == allowed)
}

@MainActor private func flowAutomaticPreferences() -> RemovalPreferences {
  let name = "LightenQA-auto-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set(true, forKey: RemovalPreferences.relatedKey)
  return RemovalPreferences(defaults: defaults, persistentDomainName: name)
}

@Test("An Info-only app row supports explicit removal before sizes or ownership are ready")
@MainActor func appsListedRowsAreImmediatelyReviewable() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/LightenQA-listed.app"
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  let identity = try DescriptorFileSystem.identity(at: path)
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let store = AppsStore(
    pictures: flowPictures(root), userPlanner: PlanService(homeDirectory: root),
    running: AppsClosedSource(), events: { stream })
  let actions = ActionStore(
    journal: JSONLActionJournal(path: root + "/journal.jsonl"),
    planService: PlanService(homeDirectory: root))
  store.startScan(actions: actions)
  continuation.yield(
    .listed([
      ApplicationListEntry(
        path: path, name: "Fixture display name",
        bundleID: "qa.lighten.listed", version: "1.2", displayRootIdentity: identity)
    ]))
  try await waitFlow { store.listedPublishedAt != nil }
  let report = try #require(store.reports.first)
  #expect(store.displayName(report) == "Fixture display name")
  #expect(report.logical.completeTotal == nil && report.version == "1.2")
  #expect(store.busy && !store.inventoryComplete)
  store.select(path, actions: actions)
  await store.prepareSelectedData(actions: actions)
  let pending = try #require(actions.pending)
  #expect(pending.plan.items.map(\.sourcePath) == [path])
  #expect(pending.plan.items.allSatisfy { $0.userSelection == true && $0.inventory.count == 1 })
  #expect(store.selectedDataPaths.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
  continuation.yield(
    .completed(
      BundleInventory(
        applications: [], unidentifiedPaths: [],
        complete: true, observedAt: Date()), [report]))
  continuation.finish()
  try await waitFlow { !store.busy }
}

@Test("Shared app data stays unselected but explicit row choice reaches a root confirmation")
@MainActor func appsSharedDataExplicitRootReview() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/shared-data"
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  let identity = try DescriptorFileSystem.identity(at: path)
  let candidate = RelatedDataCandidate(
    id: path, path: path, classification: .shared, reason: .sharedInstalledData,
    snapshot: ScanSnapshot(
      rootPath: path, volumeDevice: identity.device,
      entries: [ScanEntry(parentID: nil, path: path, identity: identity, issues: [], readable: true)], nodes: []),
    receipt: nil,
    refusalEvidence: [
      RelatedOwnershipRefusalEvidence(
        candidatePath: path, bundleID: "qa.other",
        reason: .sharedInstalledOwners, ownerPaths: [root + "/Other.app"], nextStep: "review-other-installations",
        detail: nil)
    ])
  let store = AppsStore(
    pictures: flowPictures(root), userPlanner: PlanService(homeDirectory: root),
    running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(
    journal: JSONLActionJournal(path: root + "/journal.jsonl"),
    planService: PlanService(homeDirectory: root))
  let app = root + "/LightenQA-shared.app"
  store.reports = [flowReport(path: app, candidates: [candidate])]
  store.select(app, actions: actions, selectPackage: false)
  #expect(!store.automaticSelectionAllowed(candidate))
  store.toggleData(path, actions: actions)
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending?.plan.items.map(\.sourcePath) == [path])
  #expect(actions.pending?.plan.items.first?.userSelection == true)
  #expect(candidate.refusalEvidence.count == 1)
}

@Test("Explicit app removal keeps real remaining data visible and available for a separate root review")
@MainActor func appsExplicitRemovalRetainsActualData() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-explicit.app"
  let remainingPath = root + "/remaining-data"
  let trashPath = root + "/trash"
  for path in [app, remainingPath, trashPath] {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  }
  let appIdentity = try DescriptorFileSystem.identity(at: app)
  let dataIdentity = try DescriptorFileSystem.identity(at: remainingPath)
  let candidate = RelatedDataCandidate(
    id: remainingPath, path: remainingPath, classification: .installed, reason: .installed,
    snapshot: ScanSnapshot(
      rootPath: remainingPath, volumeDevice: dataIdentity.device,
      entries: [ScanEntry(parentID: nil, path: remainingPath, identity: dataIdentity, issues: [], readable: true)],
      nodes: []), receipt: nil)
  let name = "LightenQA-explicit-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = RemovalPreferences(defaults: defaults, persistentDomainName: name)
  let store = AppsStore(
    pictures: flowPictures(root), preferences: preferences,
    userPlanner: PlanService(homeDirectory: root), running: AppsClosedSource(), events: { AsyncStream { $0.finish() } })
  let actions = ActionStore(
    journal: JSONLActionJournal(path: root + "/journal.jsonl"),
    trash: OwnedFlowTrash(destination: trashPath), planService: PlanService(homeDirectory: root),
    preferences: preferences, applicationActivity: ClearFlowApplicationActivity())
  store.reports = [flowReport(path: app, candidates: [candidate], identity: appIdentity)]
  store.select(app, actions: actions, selectPackage: false)
  store.togglePackage(actions: actions)
  #expect(store.selectedDataPaths.isEmpty)
  await store.prepareSelectedData(actions: actions)
  actions.onDisplayChange = { store.applyDisplayChange($0) }
  let presentation = try #require(actions.pending)
  let claimed = try #require(actions.takeConfirmedPlan(presentation))
  await actions.executeConfirmed(claimed)
  store.observeResult(actions: actions)
  #expect(actions.result?.items.map(\.outcome) == [.applied])
  #expect(!FileManager.default.fileExists(atPath: app))
  #expect(FileManager.default.fileExists(atPath: remainingPath))
  #expect(store.reports.isEmpty && store.orphanCandidates.map(\.path) == [remainingPath])
  #expect(store.retainedReason(candidate, turkish: false)?.primaryReason.contains("not selected") == true)
  store.toggleOrphan(remainingPath, actions: actions)
  await store.prepareOrphans(actions: actions)
  #expect(actions.pending?.plan.items.map(\.sourcePath) == [remainingPath])
  #expect(actions.pending?.plan.items.first?.userSelection == true)
}

@Test("A blocked previous picture read does not delay fresh metadata rows")
@MainActor func appsFreshRowsDoNotWaitForPicture() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let gate = DispatchSemaphore(value: 0)
  let pictureStarted = AsyncStream<Void>.makeStream()
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let path = root + "/LightenQA-fresh.app"
  let store = AppsStore(
    pictures: flowPictures(root),
    loadPicture: {
      pictureStarted.continuation.yield(())
      _ = gate.wait(timeout: .now() + 5)
      return ResultPicture(
        observedAt: Date().addingTimeInterval(-60),
        content: AppsPicture(reports: [flowReport(path: root + "/LightenQA-old.app")], inventoryComplete: true))
    }, running: AppsClosedSource(), events: { stream })
  let actions = ActionStore()
  store.open(actions: actions)
  var pictureIterator = pictureStarted.stream.makeAsyncIterator()
  _ = await pictureIterator.next()
  defer { gate.signal() }
  continuation.yield(
    .listed([
      ApplicationListEntry(path: path, name: "Fresh", bundleID: nil, version: nil, displayRootIdentity: nil)
    ]))
  try await waitFlow { store.reports.count == 1 }
  #expect(store.reports.first?.path == path)
  #expect(store.pictureRows.isEmpty)
  #expect(store.listedPublishedAt != nil)
  #expect(store.openingTiming?.firstRowDrawnAt == nil)
  #expect(store.openingTiming?.visibleIconsDrawnAt == nil)
  store.cancelScan()
  continuation.finish()
}

@Test("Progressive display rows preserve cached sizes without gaining selection authority")
@MainActor func appsProgressiveRowsRetainPictureSizes() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let reports = (0..<2).map { flowReport(path: root + "/LightenQA-cached-\($0).app") }
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let store = AppsStore(
    pictures: flowPictures(root),
    loadPicture: {
      ResultPicture(
        observedAt: Date().addingTimeInterval(-60), content: AppsPicture(reports: reports, inventoryComplete: true))
    }, running: AppsClosedSource(), events: { stream })
  let actions = ActionStore()
  store.open(actions: actions)
  try await waitFlow { store.pictureRows.count == 2 }
  let entries = reports.map {
    ApplicationListEntry(path: $0.path, name: $0.path, bundleID: $0.bundleID, version: nil, displayRootIdentity: nil)
  }
  continuation.yield(.listed([entries[0]], isFinalBatch: false))
  try await waitFlow { store.reports.count == 1 }
  let firstPublishedAt = try #require(store.listedPublishedAt)
  continuation.yield(.listed(entries))
  try await waitFlow { store.reports.count == 2 }
  #expect(store.listedPublishedAt == firstPublishedAt)
  #expect(store.reports.map(\.logical) == reports.map(\.logical))
  #expect(store.reports.allSatisfy { $0.signerTeamID == nil && $0.related.isEmpty && $0.partial })
  #expect(!store.inventoryComplete)
  #expect(actions.pending == nil)
  store.cancelScan()
  continuation.finish()
}

@Test("Drawing partial or incomplete viewport snapshots cannot complete Apps icon timing")
@MainActor func appsOpeningRequiresCompleteDrawnViewport() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let store = AppsStore(pictures: flowPictures(root), running: AppsClosedSource(), events: { stream })
  let actions = ActionStore()
  store.open(actions: actions)
  let requestedAt = try #require(store.openingTiming?.requestedAt)
  let paths = (0..<85).map { root + "/LightenQA-\($0).app" }
  continuation.yield(
    .listed(
      paths.map {
        ApplicationListEntry(path: $0, name: $0, bundleID: nil, version: nil, displayRootIdentity: nil)
      }))
  try await waitFlow { store.reports.count == 85 }
  #expect(store.openingTiming?.firstRowDrawnAt == nil)
  #expect(store.openingTiming?.visibleIconsDrawnAt == nil)
  let viewport = CGRect(x: 0, y: 0, width: 300, height: 590)
  func snapshot(_ count: Int, lateIcon: Bool = false) -> ApplicationViewportSnapshot {
    ApplicationViewportSnapshot(
      rows: Dictionary(
        uniqueKeysWithValues: (0..<count).map { index in
          (
            paths[index],
            .init(
              frame: CGRect(x: 0, y: CGFloat(index) * 55, width: 300, height: 50),
              iconReady: !(lateIcon && index == 10))
          )
        }), orderedPaths: paths, viewport: viewport)
  }
  store.viewportDidDraw(snapshot(0), revision: store.openingRevision)
  #expect(store.openingTiming?.firstRowDrawnAt == nil)
  store.viewportDidDraw(snapshot(5), revision: store.openingRevision)
  #expect(store.openingTiming?.firstRowDrawnAt != nil)
  #expect(store.openingTiming?.visibleIconsDrawnAt == nil)
  store.viewportDidDraw(snapshot(22, lateIcon: true), revision: store.openingRevision)
  #expect(store.openingTiming?.visibleRowCount == 11)
  #expect(store.openingTiming?.visibleIconsDrawnAt == nil)
  store.viewportDidDraw(snapshot(22), revision: store.openingRevision - 1)
  #expect(store.openingTiming?.visibleIconsDrawnAt == nil)
  store.viewportDidDraw(snapshot(22), revision: store.openingRevision)
  #expect(store.openingTiming?.visibleIconsDrawnAt != nil)
  #expect(store.openingTiming?.visibleRowCount == 11)
  #expect(store.openingTiming?.requestedAt == requestedAt)
  store.cancelScan()
  continuation.finish()
}

@Test("Package and ready roots are reviewed while ownership is pending; missing choices get an exact reason")
@MainActor func appsPendingOwnershipReviewsReadyRoots() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let app = root + "/LightenQA-pending.app"
  let readyPath = root + "/ready-data"
  let missingPath = root + "/not-discovered"
  for path in [app, readyPath] {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  }
  var ready = RelatedDataCandidate(
    id: readyPath, path: readyPath, classification: .uncertain, reason: .ownershipUnavailable,
    snapshot: nil, receipt: nil)
  ready.displayRootIdentity = try DescriptorFileSystem.identity(at: readyPath)
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let planner = PlanService(homeDirectory: root)
  let store = AppsStore(pictures: flowPictures(root), userPlanner: planner, events: { stream })
  let actions = ActionStore(
    journal: JSONLActionJournal(path: root + "/journal.jsonl"), planService: planner,
    applicationActivity: ClearFlowApplicationActivity())
  store.startScan(actions: actions)
  let report = flowReport(path: app, identity: try DescriptorFileSystem.identity(at: app))
  let inventory = BundleInventory(applications: [], unidentifiedPaths: [], complete: false, observedAt: Date())
  continuation.yield(.inventory(inventory, [report]))
  try await waitFlow { store.selectedReport == nil && store.reports.count == 1 }
  store.select(app, actions: actions)
  continuation.yield(.related(path: app, candidates: [ready], ownershipPending: true))
  try await waitFlow { store.ownershipPendingPaths.contains(app) }
  store.toggleData(readyPath, actions: actions)
  store.selectedDataPaths.insert(missingPath)
  #expect(store.busy && !store.inventoryComplete && store.measuringPaths.contains(app))
  await store.prepareSelectedData(actions: actions)
  let presentation = try #require(actions.pending)
  #expect(Set(presentation.plan.items.map(\.sourcePath)) == [app, readyPath])
  #expect(presentation.rejectedItems.map(\.path) == [missingPath])
  #expect(presentation.rejectedItems.first?.reason == .unavailable)
  #expect(!store.preparing && store.ownershipPendingPaths.contains(app))
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
  store.cancelScan()
  continuation.finish()
  #expect(actions.pending == nil)
}

@Test("Lighten remains unselected and refuses its own package in every preparation path", arguments: [false, true])
@MainActor func appsDefaultSelectionPreservesSelfProtection(injected: Bool) async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/LightenQA-self.app"
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  let builder: AppsStore.AvailableUninstallPlanBuilder? =
    injected
    ? { @Sendable _, _, _ in
      Issue.record("Self removal reached the plan builder")
      return .init(plan: nil, rejections: [])
    } : nil
  let store = AppsStore(pictures: flowPictures(root), availableUninstallPlanBuilder: builder)
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal.jsonl"))
  store.reports = [flowReport(path: path, bundleID: LightenIdentity.bundleIdentifier.uppercased())]
  store.select(path, actions: actions)
  #expect(!store.packageSelected && !store.canReviewSelectedData(actions: actions))
  store.packageSelected = true
  await store.prepareSelectedData(actions: actions)
  #expect(actions.pending == nil && !store.preparing)
  #expect(store.message == String(localized: "Lighten does not remove itself."))
}

private struct AppsActiveSelectionActivity: ApplicationActivitySource {
  func activity(applicationPath: String) async -> ApplicationActivity {
    ApplicationActivity(state: .active, scope: .currentUser)
  }
}

@Test("Default app selection preserves the running-application close confirmation")
@MainActor func appsDefaultSelectionKeepsRunningConfirmation() async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/LightenQA-running.app"
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  let planner = PlanService(homeDirectory: root)
  let store = AppsStore(pictures: flowPictures(root), userPlanner: planner)
  let actions = ActionStore(
    journal: JSONLActionJournal(path: root + "/journal.jsonl"), planService: planner,
    userSelectionApplicationActivity: AppsActiveSelectionActivity())
  store.reports = [flowReport(path: path, identity: try DescriptorFileSystem.identity(at: path))]
  store.select(path, actions: actions)
  await store.prepareSelectedData(actions: actions)
  let presentation = try #require(actions.pending)
  #expect(presentation.plan.items.map(\.sourcePath) == [path])
  #expect(presentation.hasRunningApplications)
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
}

@Test("Stopping background discovery retains fresh observed roots and explicit choices", arguments: [false, true])
@MainActor func appsStoppedDiscoveryKeepsRootReview(cancel: Bool) async throws {
  let root = try flowRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/LightenQA-stopped.app"
  let dataPath = root + "/data"
  for path in [path, dataPath] {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  }
  var candidate = RelatedDataCandidate(
    id: dataPath, path: dataPath, classification: .uncertain,
    reason: .ownershipUnavailable, snapshot: nil, receipt: nil)
  candidate.displayRootIdentity = try DescriptorFileSystem.identity(at: dataPath)
  let (stream, continuation) = AsyncStream<ApplicationDiscovery.Event>.makeStream()
  let planner = PlanService(homeDirectory: root)
  let store = AppsStore(pictures: flowPictures(root), userPlanner: planner, events: { stream })
  let actions = ActionStore(
    journal: JSONLActionJournal(path: root + "/journal.jsonl"),
    planService: planner, applicationActivity: ClearFlowApplicationActivity())
  store.startScan(actions: actions)
  continuation.yield(
    .listed([
      ApplicationListEntry(
        path: path, name: "Stopped fixture",
        bundleID: "qa.lighten.stopped", version: "1", displayRootIdentity: try DescriptorFileSystem.identity(at: path))
    ]))
  try await waitFlow { store.reports.count == 1 }
  continuation.yield(.related(path: path, candidates: [candidate], ownershipPending: true))
  try await waitFlow { store.reports.first?.related.count == 1 }
  store.select(path, actions: actions)
  store.toggleData(dataPath, actions: actions)
  if cancel {
    store.cancelScan()
    continuation.finish()
  } else {
    continuation.finish()
  }
  try await waitFlow { !store.busy }
  #expect(!store.needsRescan && store.packageSelected && store.selectedDataPaths == [dataPath])
  #expect(store.canReviewSelectedData(actions: actions))
  await store.prepareSelectedData(actions: actions)
  #expect(Set(actions.pending?.plan.items.map(\.sourcePath) ?? []) == [path, dataPath])
  #expect(actions.pending?.plan.items.allSatisfy { $0.userSelection == true } == true)
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
}
