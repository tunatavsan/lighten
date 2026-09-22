import Darwin
import Foundation
import Testing

@testable import LightenKit

private struct FixedActivity: ProcessActivitySource {
  let state: ProcessActivityState
  func activity(for rowID: String) async -> ProcessActivity { ProcessActivity(state: state) }
}

private struct FixedRunning: RunningApplicationSource {
  let value: Bool?
  func isRunning(bundleID: String) async -> Bool? { value }
}

private struct ForbiddenTrash: TrashMoving {
  func moveToTrash(path: String) async throws -> String {
    Issue.record("Catalog action entered Trash mover")
    throw CatalogFailure.invalidProof
  }
}

private actor CountedTrash: TrashMoving {
  private var count = 0
  func moveToTrash(path: String) async throws -> String {
    count += 1
    throw CatalogFailure.invalidProof
  }
  func calls() -> Int { count }
}

private actor MutableActivity: ProcessActivitySource {
  private var state: ProcessActivityState
  init(_ state: ProcessActivityState) { self.state = state }
  func set(_ next: ProcessActivityState) { state = next }
  func activity(for rowID: String) async -> ProcessActivity { ProcessActivity(state: state) }
}

private actor CleanJournal: ActionJournal {
  private var records: [JournalRecord] = []
  private var lease: JournalLease?
  let failIntent: Bool
  let afterProgress: (@Sendable () async -> Void)?

  init(failIntent: Bool = false, afterProgress: (@Sendable () async -> Void)? = nil) {
    self.failIntent = failIntent
    self.afterProgress = afterProgress
  }

  func acquireMutationLease() throws -> JournalLease {
    guard lease == nil else { throw JournalFailure.leaseBusy }
    let next = JournalLease()
    lease = next
    return next
  }
  func releaseMutationLease(_ value: JournalLease) {
    if lease == value { lease = nil }
  }
  func append(_ record: JournalRecord) async throws {
    guard lease != nil else { throw JournalFailure.leaseRequired }
    if failIntent && record.kind == .intent { throw JournalFailure.corruptHistory }
    records.append(record)
    if record.kind == .deleteProgress && record.deletedCount == 1 {
      await afterProgress?()
    }
  }
  func read() -> JournalReadout { JournalReadout(records: records, issues: []) }
}

private func cleanFixture() throws -> (home: String, root: String, candidate: String) {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
    throw FileSystemFailure.invalidPath
  }
  defer { free(resolved) }
  let home = String(cString: resolved) + "/lighten-clean-" + UUID().uuidString
  let root = home + "/Library/Caches/pip/http-v2"
  let candidate = root + "/" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: candidate, withIntermediateDirectories: true)
  try Data("a".utf8).write(to: URL(fileURLWithPath: candidate + "/a"))
  try Data("b".utf8).write(to: URL(fileURLWithPath: candidate + "/b"))
  return (home, root, candidate)
}

@Test("Packaged catalog locator never falls back to a build resource")
func packagedCatalogLocatorIsFailClosed() {
  let app = URL(fileURLWithPath: "/tmp/Lighten.app")
  let source = URL(fileURLWithPath: "/tmp/build/catalog.json")
  #expect(
    CatalogResourceLocator.url(
      mainBundleURL: app,
      mainResourceURL: nil, moduleURL: source) == nil)
  let packaged = CatalogResourceLocator.url(
    mainBundleURL: app,
    mainResourceURL: URL(fileURLWithPath: "/tmp/Lighten.app/Contents/Resources"),
    moduleURL: source)
  #expect(packaged?.path == "/tmp/Lighten.app/Contents/Resources/Lighten_LightenKit.bundle/catalog.json")
  #expect(
    CatalogResourceLocator.url(
      mainBundleURL: URL(fileURLWithPath: "/tmp/TestRunner"),
      mainResourceURL: nil, moduleURL: source) == source)
}

private func cleanPlan(_ fixture: (home: String, root: String, candidate: String)) async throws -> ActionPlan {
  let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: fixture.root)
  let id = try #require(snapshot.entries.first { $0.path == fixture.candidate }).id
  return try CleanCatalog(homeDirectory: fixture.home).plan(
    snapshot: snapshot, selectedIDs: [id], rowID: "pip-http-v2")
}

private func cleanTrashPlan(_ fixture: (home: String, root: String, candidate: String)) async throws -> ActionPlan {
  let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: fixture.root)
  let id = try #require(snapshot.entries.first { $0.path == fixture.candidate }).id
  return try CleanCatalog(homeDirectory: fixture.home).plan(
    snapshot: snapshot, selectedIDs: [id], rowID: "pip-http-v2", kind: .trash)
}

@Test("Clean Trash carries exact proof and vetoes activity at both execution windows")
func cleanTrashActivityVeto() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let plan = try await cleanTrashPlan(fixture)
  #expect(plan.kind == .trash)
  #expect(plan.items[0].catalogProof?.method == .trash)
  for state in [ProcessActivityState.active, .unknown] {
    let mover = CountedTrash()
    let executor = ActionExecutor(
      journal: CleanJournal(), trash: mover,
      guardService: ActionGuard(homeDirectory: fixture.home),
      activity: FixedActivity(state: state),
      catalog: try CleanCatalog(homeDirectory: fixture.home))
    let result = try await executor.execute(plan)
    #expect(result.items[0].outcome == .skipped)
    #expect(await mover.calls() == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate + "/a"))
  }
  for state in [ProcessActivityState.active, .unknown] {
    let source = MutableActivity(.clearObservedCurrentUID)
    let mover = CountedTrash()
    let executor = ActionExecutor(
      journal: CleanJournal(), trash: mover,
      guardService: ActionGuard(homeDirectory: fixture.home),
      beforeMutation: { _ in await source.set(state) },
      activity: source, catalog: try CleanCatalog(homeDirectory: fixture.home))
    let result = try await executor.execute(plan)
    #expect(result.items[0].outcome == .skipped)
    #expect(await mover.calls() == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate + "/a"))
  }
}

@Test("Clean Trash is reversible and a forged method cannot become delete authority")
func cleanTrashProofAndUndo() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let plan = try await cleanTrashPlan(fixture)
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let changedKind = ActionPlan(
    snapshotRunID: plan.snapshotRunID, kind: .catalogDelete, items: plan.items)
  let forgedExecutor = ActionExecutor(
    journal: CleanJournal(), trash: CountedTrash(),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID), catalog: catalog)
  await #expect(throws: CatalogFailure.self) {
    try await forgedExecutor.execute(
      changedKind,
      confirmation: IrreversibleConfirmation(planID: changedKind.id, method: .catalogDelete))
  }
  let item = plan.items[0]
  let oldProof = try #require(item.catalogProof)
  let wrongProof = CatalogProof(
    version: oldProof.version, rowID: oldProof.rowID, allowedRoot: oldProof.allowedRoot,
    method: .catalogDelete, snapshotRunID: oldProof.snapshotRunID)
  let wrongItem = PlanItem(
    id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
    inventory: item.inventory, ancestors: item.ancestors, catalogProof: wrongProof)
  let wrongMethod = ActionPlan(
    snapshotRunID: plan.snapshotRunID, kind: .trash, items: [wrongItem])
  await #expect(throws: CatalogFailure.self) {
    try await forgedExecutor.execute(wrongMethod)
  }
  let trashDirectory = fixture.home + "/Trash"
  try FileManager.default.createDirectory(atPath: trashDirectory, withIntermediateDirectories: true)
  let journal = CleanJournal()
  let executor = ActionExecutor(
    journal: journal, trash: LocalTrash(directory: trashDirectory),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID), catalog: catalog)
  let result = try await executor.execute(plan)
  #expect(result.items[0].outcome == .applied)
  #expect(!FileManager.default.fileExists(atPath: fixture.candidate))
  try await ActionHistory(journal: journal, homeDirectory: fixture.home).undo(
    planID: plan.id, itemID: item.id)
  #expect(FileManager.default.fileExists(atPath: fixture.candidate + "/a"))
}

@Test("Bundled catalog grants only exact immediate cache children")
func catalogProofRejectsForgedPathAndWrongConfirmation() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let plan = try await cleanPlan(fixture)
  let journal = CleanJournal()
  let executor = ActionExecutor(
    journal: journal, trash: ForbiddenTrash(),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID),
    catalog: try CleanCatalog(homeDirectory: fixture.home))
  await #expect(throws: ExecutionFailure.self) { try await executor.execute(plan) }
  await #expect(throws: ExecutionFailure.self) {
    try await executor.execute(
      plan,
      confirmation: IrreversibleConfirmation(planID: UUID(), method: .catalogDelete))
  }
  #expect(FileManager.default.fileExists(atPath: fixture.candidate))
  #expect((await journal.read()).records.isEmpty)
  let item = plan.items[0]
  let forged = PlanItem(
    id: item.id, sourcePath: fixture.home + "/outside",
    volumeID: item.volumeID, inventory: item.inventory, ancestors: item.ancestors,
    catalogProof: item.catalogProof)
  let forgedPlan = ActionPlan(
    snapshotRunID: plan.snapshotRunID,
    kind: .catalogDelete, items: [forged])
  await #expect(throws: CatalogFailure.self) {
    try await executor.execute(
      forgedPlan,
      confirmation: IrreversibleConfirmation(planID: forgedPlan.id, method: .catalogDelete))
  }
  #expect(FileManager.default.fileExists(atPath: fixture.candidate))
}

@Test("Catalog intent and activity veto prevent deletion")
func catalogIntentAndActivityVeto() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let plan = try await cleanPlan(fixture)
  let confirmation = IrreversibleConfirmation(planID: plan.id, method: .catalogDelete)
  let failing = CleanJournal(failIntent: true)
  let denied = ActionExecutor(
    journal: failing, trash: ForbiddenTrash(),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID),
    catalog: try CleanCatalog(homeDirectory: fixture.home))
  await #expect(throws: JournalFailure.self) {
    try await denied.execute(plan, confirmation: confirmation)
  }
  #expect(FileManager.default.fileExists(atPath: fixture.candidate + "/a"))
  for state in [ProcessActivityState.active, .unknown] {
    let executor = ActionExecutor(
      journal: CleanJournal(), trash: ForbiddenTrash(),
      guardService: ActionGuard(homeDirectory: fixture.home),
      activity: FixedActivity(state: state),
      catalog: try CleanCatalog(homeDirectory: fixture.home))
    let result = try await executor.execute(plan, confirmation: confirmation)
    #expect(result.items[0].outcome == .skipped)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate + "/a"))
  }
}

@Test("A changed descendant before deletion skips the whole catalog candidate")
func catalogChangedInventorySkipsWithoutMutation() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let plan = try await cleanPlan(fixture)
  try Data("changed".utf8).write(to: URL(fileURLWithPath: fixture.candidate + "/a"))
  let executor = ActionExecutor(
    journal: CleanJournal(), trash: ForbiddenTrash(),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID),
    catalog: try CleanCatalog(homeDirectory: fixture.home))
  let result = try await executor.execute(
    plan,
    confirmation: IrreversibleConfirmation(planID: plan.id, method: .catalogDelete))
  #expect(result.items[0].outcome == .skipped)
  #expect(result.items[0].deletedCount == 0)
  #expect(FileManager.default.fileExists(atPath: fixture.candidate + "/a"))
  #expect(FileManager.default.fileExists(atPath: fixture.candidate + "/b"))
}

@Test("Permanent deletion journals exact progress and has no undo")
func catalogDeletesOnlySelectedChild() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let sibling = fixture.root + "/untouched"
  try Data("keep".utf8).write(to: URL(fileURLWithPath: sibling))
  let plan = try await cleanPlan(fixture)
  let journal = CleanJournal()
  let executor = ActionExecutor(
    journal: journal, trash: ForbiddenTrash(),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID),
    catalog: try CleanCatalog(homeDirectory: fixture.home))
  let result = try await executor.execute(
    plan,
    confirmation: IrreversibleConfirmation(planID: plan.id, method: .catalogDelete))
  #expect(result.items[0].outcome == .applied)
  #expect(result.items[0].deletedCount == 3)
  #expect(result.items[0].deletedLogicalBytes >= 2)
  #expect(!FileManager.default.fileExists(atPath: fixture.candidate))
  #expect(FileManager.default.fileExists(atPath: sibling))
  let history = ActionHistory(journal: journal, homeDirectory: fixture.home)
  #expect(try await history.reconcile().items[0].state == .deleted)
  await #expect(throws: UndoFailure.self) {
    try await history.undo(planID: plan.id, itemID: plan.items[0].id)
  }
}

@Test("Real JSONL journal replays irreversible progress and rejects undo")
func catalogDurableJournalRoundTrip() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let plan = try await cleanPlan(fixture)
  let journal = JSONLActionJournal(path: fixture.home + "/catalog-journal.jsonl")
  let executor = ActionExecutor(
    journal: journal, trash: ForbiddenTrash(),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID),
    catalog: try CleanCatalog(homeDirectory: fixture.home))
  let result = try await executor.execute(
    plan,
    confirmation: IrreversibleConfirmation(planID: plan.id, method: .catalogDelete))
  #expect(result.items[0].outcome == .applied)
  let readout = try await journal.read()
  #expect(readout.issues.isEmpty)
  #expect(readout.records.filter { $0.kind == .deleteProgress }.count == 3)
  let restarted = ActionHistory(
    journal: JSONLActionJournal(path: fixture.home + "/catalog-journal.jsonl"),
    homeDirectory: fixture.home)
  let item = try #require(try await restarted.reconcile().items.first)
  #expect(item.state == .deleted)
  #expect(item.deletedCount == 3)
  await #expect(throws: UndoFailure.self) {
    try await restarted.undo(planID: plan.id, itemID: plan.items[0].id)
  }
}

@Test("New child after one unlink stops with an honest partial result")
func catalogPartialNewChild() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let plan = try await cleanPlan(fixture)
  let candidate = fixture.candidate
  let journal = CleanJournal(afterProgress: {
    try? Data("new".utf8).write(to: URL(fileURLWithPath: candidate + "/new"))
  })
  let executor = ActionExecutor(
    journal: journal, trash: ForbiddenTrash(),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID),
    catalog: try CleanCatalog(homeDirectory: fixture.home))
  let result = try await executor.execute(
    plan,
    confirmation: IrreversibleConfirmation(planID: plan.id, method: .catalogDelete))
  #expect(result.items[0].outcome == .failed)
  #expect(result.items[0].deletedCount == 1)
  #expect(FileManager.default.fileExists(atPath: candidate + "/new"))
  let history = ActionHistory(journal: journal, homeDirectory: fixture.home)
  #expect(try await history.reconcile().items[0].state == .partiallyDeleted)
}

@Test("A swapped selected directory after first unlink stops the remaining deletion")
func catalogPartialRootSwap() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let plan = try await cleanPlan(fixture)
  let candidate = fixture.candidate
  let journal = CleanJournal(afterProgress: {
    try? FileManager.default.moveItem(atPath: candidate, toPath: candidate + "-moved")
    try? FileManager.default.createDirectory(
      atPath: candidate,
      withIntermediateDirectories: true)
    try? Data("new".utf8).write(to: URL(fileURLWithPath: candidate + "/a"))
  })
  let executor = ActionExecutor(
    journal: journal, trash: ForbiddenTrash(),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID),
    catalog: try CleanCatalog(homeDirectory: fixture.home))
  let result = try await executor.execute(
    plan,
    confirmation: IrreversibleConfirmation(planID: plan.id, method: .catalogDelete))
  #expect(result.items[0].outcome == .failed)
  #expect(result.items[0].deletedCount == 1)
  #expect(FileManager.default.fileExists(atPath: candidate + "-moved/a"))
  #expect(FileManager.default.fileExists(atPath: candidate + "/a"))
}

@Test("Changed remaining leaf after first unlink stops the remaining deletion")
func catalogPartialChangedLeaf() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let plan = try await cleanPlan(fixture)
  let candidate = fixture.candidate
  let journal = CleanJournal(afterProgress: {
    try? Data("changed".utf8).write(to: URL(fileURLWithPath: candidate + "/a"))
  })
  let executor = ActionExecutor(
    journal: journal, trash: ForbiddenTrash(),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID),
    catalog: try CleanCatalog(homeDirectory: fixture.home))
  let result = try await executor.execute(
    plan,
    confirmation: IrreversibleConfirmation(planID: plan.id, method: .catalogDelete))
  #expect(result.items[0].outcome == .failed)
  #expect(result.items[0].deletedCount == 1)
  #expect(FileManager.default.fileExists(atPath: candidate + "/a"))
}

private struct LocalTrash: TrashMoving {
  let directory: String
  func moveToTrash(path: String) async throws -> String {
    let destination = directory + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: destination)
    return destination
  }
}

@Test("Exact installed metadata creates a reusable relation receipt, then Trash can be undone")
func relatedReceiptRoundTrip() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let appRoot = fixture.home + "/Applications"
  let app = appRoot + "/Fixture.app"
  let contents = app + "/Contents"
  let id = "com.example.fixture" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  let related = fixture.home + "/Library/Caches/" + id
  let similar = related + "-similar"
  try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: related, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: similar, withIntermediateDirectories: true)
  let plist = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": id],
    format: .xml, options: 0)
  try plist.write(to: URL(fileURLWithPath: contents + "/Info.plist"))
  try Data("fixture".utf8).write(to: URL(fileURLWithPath: related + "/data"))
  let service = RelatedDataService(homeDirectory: fixture.home, applicationRoots: [appRoot])
  let first = await service.discover()
  #expect(first.first { $0.path == related }?.classification == .installed)
  #expect(first.first { $0.path == similar }?.classification == .uncertain)
  let receiptPath = fixture.home + "/Library/Application Support/com.tavsn.lighten/related-receipts.json"
  #expect(FileManager.default.fileExists(atPath: receiptPath))
  let removed = fixture.home + "/Removed"
  try FileManager.default.createDirectory(atPath: removed, withIntermediateDirectories: true)
  try FileManager.default.moveItem(atPath: app, toPath: removed + "/Fixture.app")
  let second = await service.discover()
  let candidate = try #require(second.first { $0.path == related })
  #expect(candidate.classification == .historicallyVerifiedAbsent)
  #expect(second.first { $0.path == similar }?.classification == .uncertain)
  let plan = try service.plan(candidate: candidate)
  let trashDirectory = fixture.home + "/Trash"
  try FileManager.default.createDirectory(atPath: trashDirectory, withIntermediateDirectories: true)
  for running in [true, nil] as [Bool?] {
    let blocked = ActionExecutor(
      journal: CleanJournal(),
      trash: LocalTrash(directory: trashDirectory),
      guardService: ActionGuard(homeDirectory: fixture.home),
      related: service, runningApplications: FixedRunning(value: running))
    let blockedResult = try await blocked.execute(plan)
    #expect(blockedResult.items[0].outcome == .skipped)
    #expect(FileManager.default.fileExists(atPath: related))
  }
  let journal = CleanJournal()
  let executor = ActionExecutor(
    journal: journal, trash: LocalTrash(directory: trashDirectory),
    guardService: ActionGuard(homeDirectory: fixture.home),
    related: service, runningApplications: FixedRunning(value: false))
  let result = try await executor.execute(plan)
  #expect(result.items[0].outcome == .applied)
  #expect(!FileManager.default.fileExists(atPath: related))
  let history = ActionHistory(journal: journal, homeDirectory: fixture.home)
  try await history.undo(planID: plan.id, itemID: plan.items[0].id)
  #expect(FileManager.default.fileExists(atPath: related + "/data"))
  // The application returning removes the orphan classification.
  try FileManager.default.moveItem(atPath: removed + "/Fixture.app", toPath: app)
  #expect((await service.discover()).first { $0.path == related }?.classification == .installed)
}

@Test("Recreated object and incomplete owner inventory remain report only")
func relatedReceiptRejectsChangedObjectAndPartialInventory() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let appRoot = fixture.home + "/Applications"
  let app = appRoot + "/Fixture.app"
  let contents = app + "/Contents"
  let id = "com.example.fixture" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  let related = fixture.home + "/Library/Caches/" + id
  try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: related, withIntermediateDirectories: true)
  let plist = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": id],
    format: .xml, options: 0)
  try plist.write(to: URL(fileURLWithPath: contents + "/Info.plist"))
  let service = RelatedDataService(homeDirectory: fixture.home, applicationRoots: [appRoot])
  _ = await service.discover()
  let unclassified = appRoot + "/Unclassified.app"
  try FileManager.default.createSymbolicLink(atPath: unclassified, withDestinationPath: "/missing-app")
  let installedWithPartialInventory = try #require((await service.discover()).first { $0.path == related })
  #expect(installedWithPartialInventory.classification == .installed)
  #expect(installedWithPartialInventory.snapshot == nil)
  try FileManager.default.removeItem(atPath: unclassified)
  try FileManager.default.removeItem(atPath: app)
  let orphan = try #require((await service.discover()).first { $0.path == related })
  #expect(orphan.classification == .historicallyVerifiedAbsent)
  try FileManager.default.removeItem(atPath: appRoot)
  try Data("not a directory".utf8).write(to: URL(fileURLWithPath: appRoot))
  #expect((await service.discover()).first { $0.path == related }?.classification == .uncertain)
  try FileManager.default.removeItem(atPath: related)
  try FileManager.default.createDirectory(atPath: related, withIntermediateDirectories: true)
  #expect((await service.discover()).first { $0.path == related }?.classification == .uncertain)
}

@Test("A bounded child snapshot never makes its parent actionable")
func boundedRelatedSnapshotKeepsParentPartial() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let sibling = fixture.root + "/sibling"
  try Data("keep".utf8).write(to: URL(fileURLWithPath: sibling))
  let name = URL(fileURLWithPath: fixture.candidate).lastPathComponent
  let snapshot = try await ScanService(homeDirectory: fixture.home)
    .scanImmediateChild(parentPath: fixture.root, name: name)
  let parent = try #require(snapshot.entries.first)
  let node = try #require(snapshot.nodes.first { $0.id == parent.id })
  #expect(node.partial)
  #expect(node.logical.completeTotal == nil)
  #expect(snapshot.entries.allSatisfy { !$0.path.hasSuffix("/sibling") })
  #expect(throws: PlanFailure.self) {
    try PlanService(homeDirectory: fixture.home).makePlan(
      snapshot: snapshot, selectedIDs: [parent.id])
  }
  let child = try #require(snapshot.entries.first { $0.path == fixture.candidate })
  let plan = try PlanService(homeDirectory: fixture.home).makePlan(
    snapshot: snapshot, selectedIDs: [child.id])
  #expect(plan.items.count == 1)
  #expect(FileManager.default.fileExists(atPath: sibling))
}

@Test("Symlinked app metadata and receipt cannot establish ownership")
func relatedMetadataAndReceiptSymlinksStayUncertain() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let appRoot = fixture.home + "/Applications"
  let contents = appRoot + "/Fixture.app/Contents"
  let id = "com.example.fixture" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  let related = fixture.home + "/Library/Caches/" + id
  try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: related, withIntermediateDirectories: true)
  let external = fixture.home + "/external.plist"
  let plist = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": id],
    format: .xml, options: 0)
  try plist.write(to: URL(fileURLWithPath: external))
  try FileManager.default.createSymbolicLink(
    atPath: contents + "/Info.plist",
    withDestinationPath: external)
  let service = RelatedDataService(homeDirectory: fixture.home, applicationRoots: [appRoot])
  #expect(!service.inventory().complete)
  #expect((await service.discover()).first { $0.path == related }?.classification == .uncertain)
  try FileManager.default.removeItem(atPath: contents + "/Info.plist")
  try plist.write(to: URL(fileURLWithPath: contents + "/Info.plist"))
  _ = await service.discover()
  let receiptPath = fixture.home + "/Library/Application Support/com.tavsn.lighten/related-receipts.json"
  try FileManager.default.removeItem(atPath: receiptPath)
  try FileManager.default.createSymbolicLink(
    atPath: receiptPath,
    withDestinationPath: external)
  let installedWithUnsafeReceipt = try #require((await service.discover()).first { $0.path == related })
  #expect(installedWithUnsafeReceipt.classification == .installed)
  #expect(installedWithUnsafeReceipt.snapshot == nil)
  try FileManager.default.removeItem(atPath: appRoot + "/Fixture.app")
  let result = await service.discover()
  #expect(result.first { $0.path == related }?.classification == .uncertain)
  #expect(result.contains { $0.reason == .recordUnsafe })
}

@Test("Group Containers remain shared report-only without content discovery")
func sharedGroupIsReportOnly() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let group = fixture.home + "/Library/Group Containers"
  try FileManager.default.createDirectory(
    atPath: group + "/hidden-group",
    withIntermediateDirectories: true)
  let service = RelatedDataService(
    homeDirectory: fixture.home,
    applicationRoots: [fixture.home + "/Applications"])
  let result = await service.discover()
  #expect(result.first { $0.path == group }?.classification == .shared)
  #expect(!result.contains { $0.path == group + "/hidden-group" })
}
