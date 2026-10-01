import Darwin
import Foundation
import Testing

@testable import Lighten
@testable import LightenKit

private enum CleanTestFailure: Error { case injected }

private struct ClearCleanActivity: ProcessActivitySource {
  func activity(for rowID: String) async -> ProcessActivity { ProcessActivity(state: .clearObservedCurrentUID) }
}

private struct CleanFixture {
  let home: String
  let catalog: CleanCatalog

  init() throws {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw CleanTestFailure.injected }
    defer { free(resolved) }
    home = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    catalog = try CleanCatalog(homeDirectory: home)
    for row in catalog.rows.prefix(2) {
      let root = catalog.root(for: row)
      try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
      try Data("temporary cache".utf8).write(to: URL(fileURLWithPath: root + "/cache-item"))
    }
  }

  func remove() { try? FileManager.default.removeItem(atPath: home) }

  @MainActor func store(
    scanner: @escaping CleanStore.Scanner = { path, home in
      try await ScanService(homeDirectory: home).scan(rootPath: path)
    },
    planBuilder: @escaping CleanStore.PlanBuilder = { catalog, selections, kind in
      try catalog.plan(selections: selections, kind: kind)
    }
  ) -> CleanStore {
    CleanStore(
      activity: ClearCleanActivity(), homeDirectory: home, scanner: scanner,
      discoverRelated: { [] }, planBuilder: planBuilder)
  }

  @MainActor func actions() -> ActionStore {
    ActionStore(journal: JSONLActionJournal(path: home + "/journal.jsonl"))
  }
}

private actor CleanScanGate {
  private var blocked: CheckedContinuation<Void, Never>?
  private var arrival: CheckedContinuation<Void, Never>?
  private var received = false

  func pause() async {
    await withCheckedContinuation { continuation in
      blocked = continuation
      received = true
      arrival?.resume()
      arrival = nil
    }
  }
  func waitForArrival() async {
    if received { return }
    await withCheckedContinuation { arrival = $0 }
  }
  func release() {
    blocked?.resume()
    blocked = nil
  }
}

private actor CleanPlanGate {
  private var blocked: CheckedContinuation<ActionPlan, Error>?
  private var arrival: CheckedContinuation<Void, Never>?
  private var received = false
  private(set) var requests = 0

  func plan() async throws -> ActionPlan {
    try await withCheckedThrowingContinuation { continuation in
      blocked = continuation
      requests += 1
      received = true
      arrival?.resume()
      arrival = nil
    }
  }
  func waitForArrival() async {
    if received { return }
    await withCheckedContinuation { arrival = $0 }
  }
  func release(_ plan: ActionPlan) {
    blocked?.resume(returning: plan)
    blocked = nil
  }
}

private actor CleanDiscoverySequence {
  let first = CleanScanGate()
  let second = CleanScanGate()
  private var calls = 0

  func discover() async -> [RelatedDataCandidate] {
    calls += 1
    let current = calls
    await (current == 1 ? first : second).pause()
    return [
      RelatedDataCandidate(
        id: "discovery-\(current)", path: "/report-only-\(current)",
        classification: .uncertain, reason: .nameOnly, snapshot: nil, receipt: nil)
    ]
  }
}

@Test("Clean catalog becomes ready while removed app discovery is delayed")
@MainActor func cleanReadyBeforeRelatedDiscovery() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let gate = CleanScanGate()
  let store = CleanStore(
    activity: ClearCleanActivity(), homeDirectory: fixture.home,
    discoverRelated: {
      await gate.pause()
      return []
    })
  store.startScan()
  await store.waitForScan()
  await gate.waitForArrival()
  #expect(store.phase == .ready)
  #expect(!store.busy)
  #expect(store.actionableCandidates.count == 2)
  #expect(!store.selected.isEmpty)
  #expect(store.scannedAt != nil)
  #expect(store.discoveringRelated)
  await gate.release()
  await store.waitForRelatedDiscovery()
  #expect(!store.discoveringRelated)
  #expect(store.phase == .ready)
}

@Test("A superseded removed app discovery cannot publish into a newer Clean scan")
@MainActor func cleanStaleRelatedDiscoveryIsDiscarded() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let discovery = CleanDiscoverySequence()
  let store = CleanStore(
    activity: ClearCleanActivity(), homeDirectory: fixture.home,
    discoverRelated: { await discovery.discover() })
  store.startScan()
  await store.waitForScan()
  await discovery.first.waitForArrival()
  // The main-actor waiter captures the first task before this continuation resumes.
  var firstWaiter: Task<Void, Never>?
  await withCheckedContinuation { started in
    firstWaiter = Task {
      started.resume()
      await store.waitForRelatedDiscovery()
    }
  }
  store.startScan()
  await store.waitForScan()
  await discovery.second.waitForArrival()
  await discovery.first.release()
  await firstWaiter?.value
  #expect(store.relatedCandidates.isEmpty)
  #expect(store.discoveringRelated)
  #expect(store.phase == .ready)
  await discovery.second.release()
  await store.waitForRelatedDiscovery()
  #expect(store.relatedCandidates.map(\.id) == ["discovery-2"])
  #expect(!store.discoveringRelated)
}

@Test("Clean scan finds complete cache candidates using injected activity and home")
@MainActor func cleanScanCandidates() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let store = fixture.store()
  store.startScan()
  #expect(store.phase == .scanning)
  await store.waitForScan()
  #expect(store.phase == .ready)
  #expect(store.scannedAt != nil)
  #expect(store.actionableCandidates.count == 2)
  #expect(store.toolSummary.logicalBytes == 30)
  #expect(store.selected == Set(store.actionableCandidates.filter { $0.row.defaultSelected }.map(\.id)))
}

@Test("Cancelling retains partial results without plan authority")
@MainActor func cleanCancellationKeepsPartial() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let gate = CleanScanGate()
  let firstRoot = fixture.catalog.root(for: fixture.catalog.rows[0])
  let store = fixture.store(scanner: { path, home in
    if path != firstRoot { await gate.pause() }
    return try await ScanService(homeDirectory: home).scan(rootPath: path)
  })
  let actions = fixture.actions()
  store.startScan()
  await gate.waitForArrival()
  let retained = store.candidates.count
  #expect(retained == 1)
  store.cancelScan(actions: actions)
  #expect(store.phase == .partial)
  #expect(store.candidates.count == retained)
  #expect(store.selected.isEmpty)
  store.selected = Set(store.candidates.map(\.id))
  await store.prepare(actions: actions)
  #expect(actions.pending == nil)
  #expect(store.message?.contains("Partial") == true)
  await gate.release()
}

@Test("Missing catalog is a visible failure and does not discover related data")
@MainActor func cleanMissingCatalog() async {
  let store = CleanStore(
    activity: ClearCleanActivity(), homeDirectory: "/nonexistent",
    catalogLoader: { _ in throw CleanTestFailure.injected },
    discoverRelated: {
      Issue.record("must not discover")
      return []
    })
  store.startScan()
  await store.waitForScan()
  #expect(store.phase == .failed)
  #expect(!store.busy)
  #expect(store.candidates.isEmpty)
  #expect(store.message?.isEmpty == false)
}

@Test("Double scan clicks start one generation")
@MainActor func cleanDoubleScanClick() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let gate = CleanScanGate()
  let store = fixture.store(scanner: { _, _ in
    await gate.pause()
    throw CleanTestFailure.injected
  })
  store.startScan()
  store.startScan()
  await gate.waitForArrival()
  #expect(store.phase == .scanning)
  store.cancelScan()
  await gate.release()
  #expect(store.phase == .partial)
}

@Test("Selection changes invalidate a pending preparation and suppress its result")
@MainActor func cleanPreparationInvalidation() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let gate = CleanPlanGate()
  let store = fixture.store(planBuilder: { _, _, _ in try await gate.plan() })
  let actions = fixture.actions()
  store.startScan()
  await store.waitForScan()
  store.selectAll(actions: actions)
  if store.selected.isEmpty { store.selectAll(actions: actions) }
  let validPlan = try fixture.catalog.plan(
    selections: store.actionableCandidates.map {
      CatalogSelection(snapshot: $0.snapshot, selectedIDs: [$0.id], rowID: $0.row.id)
    }, kind: .trash)
  let preparation = Task { await store.prepare(actions: actions) }
  await gate.waitForArrival()
  await store.prepare(actions: actions)
  #expect(await gate.requests == 1)
  store.toggleCategory(store.candidates[0].row.id, actions: actions)
  await gate.release(validPlan)
  await preparation.value
  #expect(actions.pending == nil)
  #expect(store.presentedPlanID == nil)
  #expect(!store.busy)
}

@Test("One Clean plan contains multiple categories and moved candidates disappear")
@MainActor func cleanMultiCategoryResult() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let store = fixture.store()
  let actions = fixture.actions()
  store.startScan()
  await store.waitForScan()
  store.selected = Set(store.actionableCandidates.map(\.id))
  await store.prepare(actions: actions)
  let presentation = try #require(actions.pending)
  #expect(presentation.plan.kind == .trash)
  #expect(Set(presentation.plan.items.compactMap { $0.catalogProof?.rowID }).count == 2)
  let before = store.candidates.count
  let selectedBefore = store.selected
  let movedID = try #require(store.actionableCandidates.first?.id)
  let encoded: [String: Any] = [
    "planID": presentation.id.uuidString,
    "items": [["itemID": movedID.uuidString, "outcome": "applied", "deletedCount": 0, "deletedLogicalBytes": 0]],
  ]
  actions.result = try JSONDecoder().decode(ActionResult.self, from: JSONSerialization.data(withJSONObject: encoded))
  store.observeResult(actions: actions)
  #expect(store.candidates.count == before - 1)
  #expect(!store.candidates.contains { $0.id == movedID })
  #expect(store.selected == selectedBefore.subtracting([movedID]))
  #expect(actions.pending == nil)
  store.observeResult(actions: actions)
  #expect(store.candidates.count == before - 1)
}

@Test("Installed app data is excluded and related report-only entries remain visible")
@MainActor func cleanInstalledDataExcluded() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let installed = RelatedDataCandidate(
    id: "installed", path: fixture.home + "/Library/Caches/qa.lighten.installed",
    classification: .installed, reason: .installed, snapshot: nil, receipt: nil)
  let uncertain = RelatedDataCandidate(
    id: "unknown", path: fixture.home + "/Library/Caches/qa.lighten.unknown",
    classification: .uncertain, reason: .nameOnly, snapshot: nil, receipt: nil)
  let store = CleanStore(
    activity: ClearCleanActivity(), homeDirectory: fixture.home,
    discoverRelated: { [installed, uncertain] })
  store.startScan()
  await store.waitForScan()
  await store.waitForRelatedDiscovery()
  #expect(store.relatedCandidates.map(\.id) == ["unknown"])
  #expect(store.toolSummary.count == store.actionableCandidates.count)
}

@Test("Partial package scans are preflighted and a protected descendant is report-only")
@MainActor func cleanPartialCandidatePreflight() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let root = fixture.catalog.root(for: fixture.catalog.rows[0])
  let package = root + "/LightenQA-" + UUID().uuidString + ".app"
  try FileManager.default.createDirectory(atPath: package + "/Contents", withIntermediateDirectories: true)
  let plist: [String: Any] = ["CFBundleIdentifier": "qa.lighten.partial", "CFBundleName": "LightenQA"]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: package + "/Contents/Info.plist"))
  try Data("fixture".utf8).write(to: URL(fileURLWithPath: package + "/Contents/payload"))
  let store = fixture.store()
  store.startScan()
  await store.waitForScan()
  let candidate = try #require(store.candidates.first { $0.entry.path == package })
  #expect(candidate.node.partial)
  #expect(candidate.canAct)
  #expect(candidate.exactLogicalBytes == nil)
  #expect(candidate.logicalBytes == candidate.node.logical.knownLowerBound)
  #expect(candidate.logicalBytes > 7)

  // A Photos library remains protected even when nested in a cache package.
  let protectedPath = package + "/Contents/fixture.photoslibrary"
  try FileManager.default.createDirectory(atPath: protectedPath, withIntermediateDirectories: true)
  try Data("sensitive fixture".utf8).write(to: URL(fileURLWithPath: protectedPath + "/original"))
  store.startScan()
  await store.waitForScan()
  let refused = try #require(store.candidates.first { $0.entry.path == package })
  #expect(!refused.canAct)
  #expect(refused.refusal?.isEmpty == false)
  #expect(!store.selected.contains(refused.id))
}

private actor ScopedCleanActivity: ProcessActivitySource {
  private(set) var roots: [String] = []
  let blockedPath: String

  init(blockedPath: String) { self.blockedPath = blockedPath }
  func activity(for rowID: String) async -> ProcessActivity { ProcessActivity(state: .clearObservedCurrentUID) }
  func activity(for row: CatalogRow, rootPath: String) async -> ProcessActivity {
    roots.append(rootPath)
    return ProcessActivity(
      state: rootPath == blockedPath ? .active : .clearObservedCurrentUID,
      processNames: rootPath == blockedPath ? ["LightenQA"] : [])
  }
}

@Test("An active app cache or log pauses only its child", arguments: ["Library/Caches", "Library/Logs"])
@MainActor func cleanGenericActivityScope(relativeRoot: String) async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let caches = fixture.home + "/" + relativeRoot
  let activePath = caches + "/qa.lighten.active"
  let clearPath = caches + "/qa.lighten.clear"
  for path in [activePath, clearPath] {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: URL(fileURLWithPath: path + "/payload"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: path + "/payload")
  }
  let activity = ScopedCleanActivity(blockedPath: activePath)
  let store = CleanStore(activity: activity, homeDirectory: fixture.home, discoverRelated: { [] })
  store.startScan()
  await store.waitForScan()
  let blocked = try #require(store.candidates.first { $0.entry.path == activePath })
  let clear = try #require(store.candidates.first { $0.entry.path == clearPath })
  #expect(!blocked.canAct)
  #expect(blocked.processNames == ["LightenQA"])
  #expect(clear.canAct)
  let roots = await activity.roots
  #expect(!roots.contains(caches))
  #expect(roots.contains(activePath) && roots.contains(clearPath))
}

@Test("Clean reviews remaining selected items when one source disappears")
@MainActor func cleanUnavailableSelectionRetainsOthers() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let store = CleanStore(
    activity: ClearCleanActivity(), homeDirectory: fixture.home, discoverRelated: { [] })
  let actions = fixture.actions()
  store.startScan()
  await store.waitForScan()
  let chosen = store.actionableCandidates
  let candidateCount = store.candidates.count
  #expect(chosen.count == 2)
  store.selected = Set(chosen.map(\.id))
  let disappeared = try #require(chosen.first)
  try FileManager.default.removeItem(atPath: disappeared.entry.path)
  await store.prepare(actions: actions)
  let presentation = try #require(actions.pending)
  #expect(presentation.plan.items.count == 1)
  #expect(!presentation.plan.items.contains { $0.sourcePath == disappeared.entry.path })
  #expect(presentation.permanentPlanBuilder != nil)
  #expect(presentation.rejectedItems.map(\.path) == [disappeared.entry.path])
  await actions.requestPermanent(presentation)
  let permanent = try #require(actions.pending)
  #expect(permanent.plan.kind == .catalogDelete)
  #expect(permanent.id != presentation.id)
  #expect(permanent.plan.items.count == 1)
  #expect(permanent.plan.items.allSatisfy { $0.catalogProof?.method == .catalogDelete && $0.policy == nil })
  #expect(permanent.rejectedItems.map(\.path) == [disappeared.entry.path])
  #expect(store.scannedAt != nil)
  #expect(store.candidates.count == candidateCount)
}

@Test("Clean retains refusal paths when all selected sources disappear")
@MainActor func cleanAllUnavailableSelections() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let store = CleanStore(activity: ClearCleanActivity(), homeDirectory: fixture.home, discoverRelated: { [] })
  let actions = fixture.actions()
  store.startScan()
  await store.waitForScan()
  let chosen = store.actionableCandidates
  store.selected = Set(chosen.map(\.id))
  for candidate in chosen { try FileManager.default.removeItem(atPath: candidate.entry.path) }
  await store.prepare(actions: actions)
  #expect(actions.pending == nil)
  #expect(chosen.allSatisfy { store.message?.contains($0.entry.path) == true })
  #expect(!store.busy)
}

@Test("Report-only Clean rows explain Apple cache and recent content refusals")
@MainActor func cleanEligibilityRefusalCopy() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let apple = fixture.home + "/Library/Caches/CloudKit"
  let recent = fixture.home + "/Library/Logs/qa.lighten.recent"
  for path in [apple, recent] {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: URL(fileURLWithPath: path + "/payload"))
  }
  let store = CleanStore(activity: ClearCleanActivity(), homeDirectory: fixture.home, discoverRelated: { [] })
  store.startScan()
  await store.waitForScan()
  let appleCandidate = try #require(store.candidates.first { $0.entry.path == apple })
  let recentCandidate = try #require(store.candidates.first { $0.entry.path == recent })
  #expect(!appleCandidate.canAct && !recentCandidate.canAct)
  #expect(appleCandidate.refusal?.contains("Apple system cache") == true)
  #expect(appleCandidate.refusal?.contains(apple) == true)
  #expect(recentCandidate.refusal?.contains("recently modified files") == true)
  #expect(recentCandidate.refusal?.contains(recent) == true)
}

@Test("Leaving Clean suppresses both a late available plan and its skipped reasons")
@MainActor func cleanAvailablePreparationInvalidation() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let gate = CleanPlanGate()
  let refusal = PlanRejection(.unavailable, path: fixture.home + "/disappeared")
  let store = CleanStore(
    activity: ClearCleanActivity(), homeDirectory: fixture.home, discoverRelated: { [] },
    availablePlanBuilder: { _, _, _ in
      CatalogPlanOutcome(plan: try await gate.plan(), rejections: [refusal])
    })
  let actions = fixture.actions()
  store.startScan()
  await store.waitForScan()
  store.selected = Set(store.actionableCandidates.map(\.id))
  let plan = try fixture.catalog.plan(
    selections: store.actionableCandidates.map {
      CatalogSelection(snapshot: $0.snapshot, selectedIDs: [$0.id], rowID: $0.row.id)
    })
  let preparation = Task { await store.prepare(actions: actions) }
  await gate.waitForArrival()
  store.deactivate(actions: actions)
  await gate.release(plan)
  await preparation.value
  #expect(actions.pending == nil)
  #expect(store.presentedPlanID == nil)
  #expect(store.message == nil)
  #expect(!store.busy)
}

@Test("Permanent cleanup is rebuilt only after the secondary confirmation choice")
@MainActor func cleanPermanentSecondaryRebuild() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let store = fixture.store()
  let actions = fixture.actions()
  store.startScan()
  await store.waitForScan()
  store.selected = Set(store.actionableCandidates.map(\.id))
  await store.prepare(actions: actions)
  let trash = try #require(actions.pending)
  #expect(trash.plan.kind == .trash)
  #expect(trash.permanentPlanBuilder != nil)
  await actions.requestPermanent(trash)
  let permanent = try #require(actions.pending)
  #expect(permanent.id != trash.id)
  #expect(permanent.plan.kind == .catalogDelete)
  #expect(permanent.permanentPlanBuilder == nil)
  #expect(permanent.plan.items.allSatisfy { $0.policy == nil && $0.catalogProof?.method == .catalogDelete })
  #expect(actions.result == nil)
}

@Test("Clean updates every category after another module's action and restores removed observations on Undo")
@MainActor func cleanCrossModuleLiveDisplayAndUndo() async throws {
  let fixture = try CleanFixture()
  defer { fixture.remove() }
  let store = fixture.store()
  store.startScan()
  await store.waitForScan()
  let before = store.candidates
  let candidate = try #require(before.first)
  let item = ActionDisplayItem(
    planID: UUID(), itemID: UUID(), path: candidate.entry.path, identity: candidate.entry.identity,
    size: ObservedPlanSize(
      logical: ByteAggregate(knownLowerBound: candidate.logicalBytes, completeTotal: candidate.logicalBytes),
      allocated: candidate.node.allocated), label: "Cache", returnedTrashPath: nil)
  let total = store.toolSummary.logicalBytes
  store.selected = Set(before.map(\.id))
  store.applyDisplayChange(ActionDisplayChange(kind: .applied, items: [item]))
  #expect(store.candidates.count == before.count - 1)
  #expect(store.toolSummary.logicalBytes == total - candidate.logicalBytes)
  #expect(!store.selected.contains(candidate.id))
  #expect(store.selected.count == before.count - 1)
  store.applyDisplayChange(ActionDisplayChange(kind: .restored, items: [item]))
  #expect(store.candidates.count == before.count)
  #expect(store.toolSummary.logicalBytes == total)
  #expect(!store.selected.contains(candidate.id))
}
