import Darwin
import Foundation
import SwiftUI
import Testing

@testable import Lighten
@testable import LightenKit

private struct LiveDisplayFixture {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString

  init() throws {
    try FileManager.default.createDirectory(atPath: root + "/source/folder", withIntermediateDirectories: true)
    for (name, bytes) in [("folder/data.bin", 64), ("skipped.bin", 32), ("failed.bin", 16)] {
      try Data(repeating: 9, count: bytes).write(to: URL(fileURLWithPath: root + "/source/" + name))
    }
  }

  var source: String { root + "/source" }
  func remove() { try? FileManager.default.removeItem(atPath: root) }

  func plan() throws -> ActionPlan {
    let selections = try ["folder", "skipped.bin", "failed.bin"].map { name in
      let path = source + "/" + name
      let identity = try DescriptorFileSystem.identity(at: path)
      return PlanService.Selection(path: path, device: identity.device, inode: identity.inode)
    }
    return try PlanService().makeSpacePlan(selections: selections, scanRootPath: source, runID: UUID())
  }

  @MainActor func summaries(_ plan: ActionPlan) -> [ActionItemSummary] {
    plan.items.map {
      ActionItemSummary(
        id: $0.id, label: URL(fileURLWithPath: $0.sourcePath).lastPathComponent,
        path: $0.sourcePath, reason: "Fixture observation",
        logicalBytes: $0.displaySize.logical?.completeTotal, allocatedBytes: $0.displaySize.allocated?.completeTotal,
        observedSize: $0.displaySize)
    }
  }

  func result(_ plan: ActionPlan) -> ActionResult {
    ActionResult(
      planID: plan.id,
      items: plan.items.map { item in
        let outcome: ActionOutcome =
          item.sourcePath.hasSuffix("folder")
          ? .applied
          : item.sourcePath.hasSuffix("skipped.bin") ? .skipped : .failed
        return ItemActionResult(
          itemID: item.id, outcome: outcome,
          detail: outcome == .applied ? nil : outcome == .skipped ? "changedSinceScan" : "injected failure")
      })
  }
}

@Test(
  "Applied result updates map, ancestors and basket synchronously; failures remain named", arguments: [false, true])
@MainActor func liveMixedOutcomesAndMotionPolicy(reduceMotion: Bool) async throws {
  let fixture = try LiveDisplayFixture()
  defer { fixture.remove() }
  let space = SpaceStore(cache: nil)
  space.selectRoot(URL(fileURLWithPath: fixture.source))
  space.startScan()
  defer { space.cancel() }
  for _ in 0..<300 {
    if space.phase == .complete { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(space.phase == .complete)
  let tree = try #require(space.tree)
  let rawTotal = try #require(tree.item(tree.rootID)?.logical.completeTotal)
  let actions = ActionStore(journal: JSONLActionJournal(path: fixture.root + "/journal/actions.jsonl"))
  actions.reduceMotion = reduceMotion
  space.reduceMotion = reduceMotion
  #expect((actions.displayAnimation == nil) == reduceMotion)
  actions.onDisplayChange = { space.applyDisplayChange($0) }
  for item in tree.children(of: tree.rootID, metric: .logical) { actions.add(item) }
  let plan = try fixture.plan()
  let applied = try #require(plan.items.first { $0.sourcePath.hasSuffix("folder") })
  actions.publishExecution(plan: plan, result: fixture.result(plan), summaries: fixture.summaries(plan))
  // No await: the result and projection are one main-actor transaction.
  #expect(space.group?.items.contains { $0.path == applied.sourcePath } == false)
  #expect(space.current?.logical.completeTotal == rawTotal - 64)
  #expect(space.rootSummary?.logical.completeTotal == rawTotal - 64)
  #expect(space.group?.items.count == 2)
  #expect(actions.basket.count == 2)
  #expect(actions.basketLogical.completeTotal == 48)
  #expect(actions.resultFailures.count == 2)
  #expect(actions.failure(at: fixture.source + "/skipped.bin") != nil)
  #expect(actions.failure(at: fixture.source + "/failed.bin") != nil)
  #expect(actions.completedSummary?.contains("folder") == true)
  #expect(!actions.completedSummary!.contains("new files"))
  #expect(tree.item(tree.rootID)?.logical.completeTotal == rawTotal)
  actions.publishRestored(planID: plan.id, itemIDs: [applied.id])
  #expect(space.group?.items.contains { $0.path == applied.sourcePath } == true)
  #expect(space.current?.logical.completeTotal == rawTotal)
  #expect(!actions.canUndoLatest)
}

private func displaySpaceItem(
  id: Int32, parent: Int32?, path: String, bytes: Int64, complete: Bool = true, count: Int64 = 1
) -> SpaceItem {
  SpaceItem(
    id: ScanItemID(node: id), parentID: parent.map { ScanItemID(node: $0) },
    name: URL(fileURLWithPath: path).lastPathComponent, path: path, kind: .directory,
    logical: ByteAggregate(knownLowerBound: bytes, completeTotal: complete ? bytes : nil),
    allocated: ByteAggregate(knownLowerBound: bytes, completeTotal: complete ? bytes : nil),
    itemCount: count, state: complete ? .complete : .partial(.descendant), childCount: 2,
    device: 1, inode: UInt64(id + 1), summarizedFiles: 0)
}

@Test("Display totals deduplicate overlapping removals and preserve lower bounds and unknown sizes")
func liveAncestorProjectionIsHonest() throws {
  let root = displaySpaceItem(id: 0, parent: nil, path: "/fixture", bytes: 100, count: 5)
  let folder = displaySpaceItem(id: 1, parent: 0, path: "/fixture/folder", bytes: 60, count: 3)
  let child = displaySpaceItem(id: 2, parent: 1, path: "/fixture/folder/child", bytes: 20)
  let remaining = try #require(root.excludingFromDisplay([folder, child, folder]))
  #expect(remaining.logical.completeTotal == 40)
  #expect(remaining.itemCount == 2)
  #expect(folder.excludingFromDisplay([child])?.logical.completeTotal == 40)
  #expect(child.excludingFromDisplay([folder]) == nil)
  let partial = displaySpaceItem(id: 0, parent: nil, path: "/fixture", bytes: 100, complete: false, count: 5)
  #expect(partial.excludingFromDisplay([folder])?.logical == ByteAggregate(knownLowerBound: 40, completeTotal: nil))
  let unknown = displaySpaceItem(id: 0, parent: nil, path: "/fixture", bytes: 0, complete: false)
  #expect(unknown.excludingFromDisplay([folder])?.logical.completeTotal == nil)
  #expect(remaining.addingToDisplay([folder, child, folder]).logical.completeTotal == 100)
}

@Test("A newly observed app at the same path survives an old result and Undo")
@MainActor func liveApplicationReplacementIsNotHidden() throws {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  let old = FileIdentity(
    device: 1, inode: 10, changeSeconds: 1, changeNanoseconds: 0, logicalBytes: 0, allocatedBytes: 0,
    linkCount: 1, flags: 0, kind: .directory, birthSeconds: 1, birthNanoseconds: 0)
  let replacement = FileIdentity(
    device: 1, inode: 11, changeSeconds: 2, changeNanoseconds: 0, logicalBytes: 0, allocatedBytes: 0,
    linkCount: 1, flags: 0, kind: .directory, birthSeconds: 2, birthNanoseconds: 0)
  func report(_ identity: FileIdentity?) -> ApplicationReport {
    ApplicationReport(
      path: root + "/App.app", bundleID: "qa.lighten.display", version: "1", signerTeamID: nil,
      logical: ByteAggregate(knownLowerBound: 100, completeTotal: 100),
      allocated: ByteAggregate(knownLowerBound: 100, completeTotal: 100), knownItemCount: 1,
      partial: false, related: [], manualUninstallerSuggested: false, displayRootIdentity: identity)
  }
  let store = AppsStore(
    pictures: ResultPictureStore(directory: root + "/pictures", maximumBytes: 0),
    events: { AsyncStream { $0.finish() } })
  let item = ActionDisplayItem(
    planID: UUID(), itemID: UUID(), path: root + "/App.app", identity: old,
    size: ObservedPlanSize(logical: ByteAggregate(knownLowerBound: 100, completeTotal: 100), allocated: nil),
    label: "App", returnedTrashPath: nil)
  store.reports = [report(replacement)]
  store.applyDisplayChange(ActionDisplayChange(kind: .applied, items: [item]))
  #expect(store.reports.count == 1)
  #expect(store.reports.first?.displayRootIdentity == replacement)
  store.reports = [report(nil)]
  store.applyDisplayChange(ActionDisplayChange(kind: .applied, items: [item]))
  #expect(store.reports.count == 1)
  store.reports = [report(old)]
  store.applyDisplayChange(ActionDisplayChange(kind: .applied, items: [item]))
  #expect(store.reports.isEmpty)
  store.reports = [report(replacement)]
  store.applyDisplayChange(ActionDisplayChange(kind: .restored, items: [item]))
  #expect(store.reports.count == 1)
  #expect(store.reports.first?.displayRootIdentity == replacement)
}

@Test("Duplicates retain skipped and failed members and restore the applied member on Undo")
@MainActor func liveDuplicateMembersAndUndo() async throws {
  let fixture = try LiveDisplayFixture()
  defer { fixture.remove() }
  let snapshot = try await ScanService().scan(rootPath: fixture.source)
  let entries = snapshot.entries.filter { $0.identity?.kind == .regular }
  #expect(entries.count == 3)
  let group = DuplicateGroup(
    logicalBytes: 64, members: entries.map { DuplicateMember(entry: $0, eligibility: .eligible) })
  let store = DuplicateStore(
    preferences: RemovalPreferences(defaults: try #require(UserDefaults(suiteName: "LightenQA." + UUID().uuidString))),
    pictures: ResultPictureStore(directory: fixture.root + "/results", maximumBytes: 0))
  store.report = DuplicateReport(
    snapshot: snapshot, groups: [group], skippedCount: 0, partial: false, comparisonCount: 3)
  store.targets = Set(entries.map(\.id))
  let applied = entries[0]
  let item = ActionDisplayItem(
    planID: UUID(), itemID: UUID(), path: applied.path, identity: applied.identity,
    size: ObservedPlanSize.inventory([applied]), label: "Applied", returnedTrashPath: nil)
  store.applyDisplayChange(ActionDisplayChange(kind: .applied, items: [item]))
  #expect(store.report?.groups.first?.members.count == 2)
  #expect(!store.targets.contains(applied.id))
  #expect(store.targets.count == 2)
  #expect(store.report?.snapshot.entries.count == snapshot.entries.count)
  store.applyDisplayChange(ActionDisplayChange(kind: .restored, items: [item]))
  #expect(store.report?.groups.first?.members.count == 3)
}

@Test("Protective warnings show only actual triggering paths and limit the examples")
@MainActor func liveWarningExamplesAreConcrete() throws {
  let fixture = try LiveDisplayFixture()
  defer { fixture.remove() }
  let paths = ["license.key", "id_rsa", "private.pem", ".env", "ordinary.bin"]
  let entries = try paths.map { name in
    let path = fixture.source + "/folder/" + name
    try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
    return ScanEntry(
      parentID: nil, path: path, identity: try DescriptorFileSystem.identity(at: path), issues: [], readable: true)
  }
  let item = PlanItem(id: UUID(), sourcePath: fixture.source + "/folder", inventory: entries, ancestors: [])
  let warning = try #require(ProtectiveWarning.evaluate(item, homeDirectory: fixture.root))
  #expect(warning == .secrets)
  let examples = warning.examplePaths(item, homeDirectory: fixture.root)
  #expect(examples.count == 3)
  #expect(examples.allSatisfy { path in entries.contains { $0.path == path } })
  #expect(!examples.contains { $0.hasSuffix("ordinary.bin") })
  #expect(SpaceText.warning(warning, paths: examples, turkish: false).contains(examples[0]))
}

@Test("Space observations size opaque selections without changing fresh exact inventory", arguments: [true, false])
@MainActor func liveSpaceObservedSizingRemainsDisplayOnly(complete: Bool) throws {
  let fixture = try LiveDisplayFixture()
  defer { fixture.remove() }
  let parent = fixture.source + "/folder"
  let bundle = parent + "/Archive.bundle"
  try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
  try Data(repeating: 7, count: 4096).write(to: URL(fileURLWithPath: bundle + "/payload.bin"))
  let identity = try DescriptorFileSystem.identity(at: parent)
  let observation = ObservedPlanSize(
    logical: ByteAggregate(knownLowerBound: 12_000_000_000, completeTotal: complete ? 12_000_000_000 : nil),
    allocated: nil)
  let plan = try PlanService().makeSpacePlan(
    selections: [
      PlanService.Selection(path: parent, device: identity.device, inode: identity.inode, observedSize: observation)
    ],
    scanRootPath: fixture.source, runID: UUID())
  let item = try #require(plan.items.first)
  #expect(item.containsOpaquePackages)
  #expect(item.displaySize == observation)
  #expect(!item.inventory.contains { $0.path == bundle + "/payload.bin" })
  #expect(item.inventory.first?.identity == identity)
  let actions = ActionStore(journal: JSONLActionJournal(path: fixture.root + "/journal/actions.jsonl"))
  actions.present(plan: plan, items: fixture.summaries(plan))
  #expect(actions.pending?.items.first?.observedSize.logical == observation.logical)
  let unknown = try PlanService().makeSpacePlan(
    selections: [PlanService.Selection(path: parent, device: identity.device, inode: identity.inode)],
    scanRootPath: fixture.source, runID: UUID())
  #expect(unknown.items.first?.displaySize == .unknown)
}

@Test(
  "Ancestor basket subtracts logical and allocated once, preserving partial size observations",
  arguments: [false, true])
@MainActor func liveBasketAncestorMetricsAndOverlap(partial: Bool) throws {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  let identity = FileIdentity(
    device: 1, inode: 10, changeSeconds: 1, changeNanoseconds: 0,
    logicalBytes: 20, allocatedBytes: 40, linkCount: 1, flags: 0, kind: .regular)
  func item(_ suffix: String) -> PlanItem {
    let entry = ScanEntry(parentID: nil, path: root + suffix, identity: identity, issues: [], readable: true)
    return PlanItem(id: entry.id, sourcePath: entry.path, inventory: [entry], ancestors: [])
  }
  let parent = item("/parent")
  let child = item("/parent/child")
  let failed = item("/failed")
  let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [parent, child, failed])
  let size = ObservedPlanSize(
    logical: ByteAggregate(knownLowerBound: 20, completeTotal: partial ? nil : 20),
    allocated: ByteAggregate(knownLowerBound: 40, completeTotal: partial ? nil : 40))
  let summaries = plan.items.map {
    ActionItemSummary(
      id: $0.id, label: "Root", path: $0.sourcePath, reason: "Fixture",
      logicalBytes: nil, allocatedBytes: nil, observedSize: size)
  }
  let actions = ActionStore(journal: JSONLActionJournal(path: root + "/journal/actions.jsonl"))
  actions.basket[root] = BasketEntry(
    path: root, label: "Ancestor", device: 1, inode: 1,
    logical: ByteAggregate(knownLowerBound: 100, completeTotal: 100),
    allocated: ByteAggregate(knownLowerBound: 200, completeTotal: 200))
  actions.publishExecution(
    plan: plan,
    result: ActionResult(
      planID: plan.id,
      items: [
        ItemActionResult(itemID: parent.id, outcome: .applied),
        ItemActionResult(itemID: child.id, outcome: .applied),
        ItemActionResult(itemID: failed.id, outcome: .failed, detail: "fixture failure"),
      ]),
    summaries: summaries)
  #expect(actions.basket[root]?.logical == ByteAggregate(knownLowerBound: 80, completeTotal: partial ? nil : 80))
  #expect(actions.basket[root]?.allocated == ByteAggregate(knownLowerBound: 160, completeTotal: partial ? nil : 160))
}

@Test("Preflight rejections remain named after accepted items execute without changing the executor result")
@MainActor func livePreflightRejectionsRemainVisible() throws {
  let fixture = try LiveDisplayFixture()
  defer { fixture.remove() }
  let original = try fixture.plan()
  let item = try #require(original.items.first { $0.sourcePath.hasSuffix("folder") })
  let plan = ActionPlan(snapshotRunID: original.snapshotRunID, kind: .trash, items: [item])
  let rejection = PlanRejection(.protectedItem, path: fixture.source + "/skipped.bin", ruleID: "fixture-only")
  let actions = ActionStore(journal: JSONLActionJournal(path: fixture.root + "/journal/actions.jsonl"))
  let result = ActionResult(planID: plan.id, items: [ItemActionResult(itemID: item.id, outcome: .applied)])
  actions.publishExecution(plan: plan, result: result, summaries: fixture.summaries(plan), rejections: [rejection])
  #expect(actions.result?.items.count == 1)
  #expect(actions.resultRejections == [rejection])
  #expect(actions.failure(at: rejection.path) != nil)
  #expect(actions.resultFailures.isEmpty)
}
