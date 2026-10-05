import CryptoKit
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
  let home = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
  let root = home + "/Library/Caches/pip/http-v2"
  let candidate = root + "/" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: candidate, withIntermediateDirectories: true)
  try Data("a".utf8).write(to: URL(fileURLWithPath: candidate + "/a"))
  try Data("b".utf8).write(to: URL(fileURLWithPath: candidate + "/b"))
  return (home, root, candidate)
}

@Test("App catalog locator accepts flat and nested bundle layouts without external fallback")
func packagedCatalogLocatorIsFailClosed() throws {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
    throw FileSystemFailure.invalidPath
  }
  defer { free(resolved) }
  let root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
  let app = URL(fileURLWithPath: root + "/Lighten.app")
  let resources = app.appendingPathComponent("Contents/Resources")
  let bundle = resources.appendingPathComponent("Lighten_LightenKit.bundle")
  let flat = bundle.appendingPathComponent("catalog.json")
  let nested = bundle.appendingPathComponent("Contents/Resources/catalog.json")
  let info = bundle.appendingPathComponent("Contents/Info.plist")
  let external = URL(fileURLWithPath: root + "/build/catalog.json")
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: root) }
  try Data("external".utf8).write(to: external, options: .atomic)
  #expect(CatalogResourceLocator.url(mainBundleURL: app, mainResourceURL: nil, moduleURL: external) == nil)
  #expect(CatalogResourceLocator.url(mainBundleURL: app, mainResourceURL: resources, moduleURL: external) == nil)

  try Data("flat".utf8).write(to: flat)
  #expect(CatalogResourceLocator.url(mainBundleURL: app, mainResourceURL: resources, moduleURL: external) == flat)

  try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("bundle metadata".utf8).write(to: info)
  try Data("nested".utf8).write(to: nested)
  #expect(CatalogResourceLocator.url(mainBundleURL: app, mainResourceURL: resources, moduleURL: external) == nested)

  try FileManager.default.removeItem(at: nested)
  #expect(CatalogResourceLocator.url(mainBundleURL: app, mainResourceURL: resources, moduleURL: external) == nil)
  #expect(
    CatalogResourceLocator.url(
      mainBundleURL: app, mainResourceURL: external.deletingLastPathComponent(), moduleURL: external) == nil)
  #expect(
    CatalogResourceLocator.url(
      mainBundleURL: app, mainResourceURL: resources, moduleURL: external,
      probe: { $0 == info.path ? .unsafe : .regular }) == nil)
  #expect(
    CatalogResourceLocator.url(
      mainBundleURL: URL(fileURLWithPath: root + "/TestRunner"),
      mainResourceURL: nil, moduleURL: external) == external)
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
  await #expect(throws: ExecutionFailure.self) {
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

@Test("Recreated objects refuse old receipts while unknown owners stay candidate scoped")
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
  let installedIgnoringDanglingLink = try #require((await service.discover()).first { $0.path == related })
  #expect(service.inventory().complete)
  #expect(installedIgnoringDanglingLink.classification == .installed)
  #expect(installedIgnoringDanglingLink.snapshot != nil)
  try FileManager.default.removeItem(atPath: unclassified)
  try FileManager.default.createDirectory(atPath: unclassified + "/Contents", withIntermediateDirectories: true)
  try Data("not a property list".utf8).write(to: URL(fileURLWithPath: unclassified + "/Contents/Info.plist"))
  let partialInventory = service.inventory()
  #expect(!partialInventory.complete)
  #expect(partialInventory.unidentifiedPaths == [unclassified])
  let installedWithPartialInventory = try #require((await service.discover()).first { $0.path == related })
  #expect(installedWithPartialInventory.classification == .installed)
  #expect(installedWithPartialInventory.snapshot != nil)
  try FileManager.default.removeItem(atPath: app)
  let absentWithPartialInventory = try #require((await service.discover()).first { $0.path == related })
  #expect(absentWithPartialInventory.classification == .historicallyVerifiedAbsent)
  #expect(absentWithPartialInventory.reason == .historicallyVerified)
  #expect(absentWithPartialInventory.snapshot != nil && absentWithPartialInventory.canSelect)
  let historical = try service.plan(candidate: absentWithPartialInventory)
  try service.validate(historical.items[0], plan: historical)
  let relevant = appRoot + "/" + id + ".app"
  try FileManager.default.createDirectory(atPath: relevant + "/Contents", withIntermediateDirectories: true)
  try Data("unknown relevant metadata".utf8).write(to: URL(fileURLWithPath: relevant + "/Contents/Info.plist"))
  let relevantUnknown = try #require((await service.discover()).first { $0.path == related })
  #expect(relevantUnknown.classification == .uncertain && relevantUnknown.reason == .incompleteInventory)
  #expect(relevantUnknown.snapshot == nil && !relevantUnknown.canSelect)
  #expect(relevantUnknown.refusalEvidence.contains { $0.reason == .unknownMetadata && $0.ownerPaths == [relevant] })
  #expect(throws: RelatedFailure.self) { try service.plan(candidate: relevantUnknown) }
  try FileManager.default.removeItem(atPath: relevant)
  try FileManager.default.removeItem(atPath: unclassified)
  let orphan = try #require((await service.discover()).first { $0.path == related })
  #expect(orphan.classification == .historicallyVerifiedAbsent)
  try FileManager.default.removeItem(atPath: appRoot)
  try Data("not a directory".utf8).write(to: URL(fileURLWithPath: appRoot))
  #expect((await service.discover()).first { $0.path == related }?.classification == .uncertain)
  try FileManager.default.moveItem(atPath: related, toPath: fixture.home + "/Original-related")
  try FileManager.default.createDirectory(atPath: related, withIntermediateDirectories: true)
  #expect((await service.discover()).first { $0.path == related }?.classification == .uncertain)
  #expect(throws: RelatedFailure.invalidReceipt) { try service.validate(historical.items[0], plan: historical) }
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
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [appRoot],
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  #expect(!service.inventory().complete)
  let unsafeMetadata = try #require((await service.discover()).first { $0.path == related })
  #expect(unsafeMetadata.classification == .uncertain && !unsafeMetadata.canSelect)
  #expect(unsafeMetadata.snapshot == nil)
  try FileManager.default.removeItem(atPath: contents + "/Info.plist")
  try plist.write(to: URL(fileURLWithPath: contents + "/Info.plist"))
  _ = await service.discover()
  let receiptPath = fixture.home + "/Library/Application Support/com.tavsn.lighten/related-receipts.json"
  try FileManager.default.removeItem(atPath: receiptPath)
  try FileManager.default.createSymbolicLink(
    atPath: receiptPath,
    withDestinationPath: external)
  let installedWithUnsafeReceipt = try #require((await service.discover()).first { $0.path == related })
  #expect(installedWithUnsafeReceipt.classification == .installed && installedWithUnsafeReceipt.defaultSelected)
  #expect(installedWithUnsafeReceipt.snapshot?.rootPath == related)
  let app = try #require(service.application(at: appRoot + "/Fixture.app"))
  let installedPlan = try service.planInstalled(app: app, candidate: installedWithUnsafeReceipt)
  #expect(installedPlan.items.first?.installedRelatedProof?.bundleID == id)
  #expect(installedPlan.items.first?.relatedProof == nil)
  try FileManager.default.removeItem(atPath: appRoot + "/Fixture.app")
  let result = await service.discover()
  let unsafeReceipt = try #require(result.first { $0.path == related })
  #expect(unsafeReceipt.classification == .uncertain && !unsafeReceipt.canSelect)
  #expect(throws: RelatedFailure.self) { try service.plan(candidate: unsafeReceipt) }
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

@Test("Catalog v2 loads many independent rows and rejects unsafe roots or methods")
func catalogV2ValidatesDataRatherThanKnownIdentifiers() throws {
  let catalog = try CleanCatalog()
  #expect(catalog.version == 2)
  #expect(catalog.rows.count >= 15)
  #expect(catalog.rows.allSatisfy { !$0.evidenceURL.isEmpty })
  func manifest(_ rows: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["version": 2, "rows": rows])
  }
  let rows = try #require(
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog.rows)) as? [[String: Any]])
  var renamed = rows
  renamed[0]["id"] = "independent-cache-name"
  #expect(try CleanCatalog(data: manifest(renamed)).row(id: "independent-cache-name") != nil)
  for mode in 0..<3 {
    var changed = rows
    switch mode {
    case 0: changed[0]["relativeRoot"] = "Library/Caches/../Mail"
    case 1: changed[0]["relativeRoot"] = "Library/Keychains"
    default: changed[0]["class"] = "userDataRisk"
    }
    #expect(throws: CatalogFailure.self) { try CleanCatalog(data: manifest(changed)) }
  }
}

@Test("Resource roots resolve aliases while catalog and mutation parents remain no-follow")
func catalogAliasResolutionDoesNotWeakenActionPaths() throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let physical = fixture.home + "/physical/Lighten_LightenKit.bundle"
  try FileManager.default.createDirectory(atPath: physical, withIntermediateDirectories: true)
  let data = Data("catalog".utf8)
  try data.write(to: URL(fileURLWithPath: physical + "/catalog.json"))
  let alias = fixture.home + "/alias"
  #expect(symlink(fixture.home + "/physical", alias) == 0)
  let resolved = CatalogResourceLocator.url(
    mainBundleURL: URL(fileURLWithPath: fixture.home + "/runner"), mainResourceURL: nil,
    moduleURL: URL(fileURLWithPath: alias + "/Lighten_LightenKit.bundle/catalog.json"))
  #expect(resolved?.path == physical + "/catalog.json")
  let nestedResources = physical + "/Contents/Resources"
  let externalResources = fixture.home + "/external-resources"
  try FileManager.default.createDirectory(atPath: physical + "/Contents", withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: externalResources, withIntermediateDirectories: true)
  try data.write(to: URL(fileURLWithPath: externalResources + "/catalog.json"))
  #expect(symlink(externalResources, nestedResources) == 0)
  #expect(
    CatalogResourceLocator.url(
      mainBundleURL: URL(fileURLWithPath: fixture.home + "/runner"), mainResourceURL: nil,
      moduleURL: URL(fileURLWithPath: alias + "/Lighten_LightenKit.bundle/Contents/Resources/catalog.json")) == nil)
  #expect(try SecureMetadataFile.read(path: try #require(resolved).path, limit: 1024, ownerOnly: false) == data)
  #expect(throws: FileSystemFailure.self) { try DescriptorFileSystem.openParent(of: alias + "/mutation") }
  try FileManager.default.removeItem(atPath: physical + "/catalog.json")
  #expect(symlink(fixture.candidate + "/a", physical + "/catalog.json") == 0)
  #expect(
    CatalogResourceLocator.url(
      mainBundleURL: URL(fileURLWithPath: fixture.home + "/runner"), mainResourceURL: nil,
      moduleURL: URL(fileURLWithPath: alias + "/Lighten_LightenKit.bundle/catalog.json")) == nil)
}

@Test("Generic application caches exclude Apple caches and every dedicated row")
func catalogGenericRowsCannotOverlapOrGrantReportOnlyAuthority() throws {
  let catalog = try CleanCatalog()
  let generic = try #require(catalog.row(id: "user-app-caches"))
  let root = catalog.root(for: generic)
  #expect(!catalog.allowsCandidate(path: root + "/com.apple.Safari", row: generic))
  #expect(!catalog.allowsCandidate(path: root + "/pip", row: generic))
  #expect(!catalog.allowsCandidate(path: root + "/Homebrew", row: generic))
  #expect(catalog.allowsCandidate(path: root + "/com.example.closed", row: generic))
  let devices = try #require(catalog.row(id: "simulator-devices"))
  #expect(devices.methods.isEmpty)
  #expect(!devices.defaultSelected)
  #expect(!catalog.allowsCandidate(path: catalog.root(for: devices) + "/device", row: devices))
  #expect(try #require(catalog.row(id: "xcode-derived-data")).methods == [.trash])
}

@Test("Two category observations bind their own proof runs in one reversible plan")
func catalogMultipleRunProofAndOneUndo() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let otherRow = try #require(catalog.row(id: "homebrew-downloads"))
  let otherRoot = catalog.root(for: otherRow)
  try FileManager.default.createDirectory(atPath: otherRoot, withIntermediateDirectories: true)
  let otherPath = otherRoot + "/LightenQA-" + UUID().uuidString
  let bytes = Data("other cache archive".utf8)
  try bytes.write(to: URL(fileURLWithPath: otherPath))
  let first = try await ScanService(homeDirectory: fixture.home).scan(rootPath: fixture.root)
  let second = try await ScanService(homeDirectory: fixture.home).scan(rootPath: otherRoot)
  let firstID = try #require(first.entries.first { $0.path == fixture.candidate }).id
  let secondID = try #require(second.entries.first { $0.path == otherPath }).id
  let plan = try catalog.plan(selections: [
    CatalogSelection(snapshot: first, selectedIDs: [firstID], rowID: "pip-http-v2"),
    CatalogSelection(snapshot: second, selectedIDs: [secondID], rowID: otherRow.id),
  ])
  #expect(plan.items.count == 2)
  #expect(Set(plan.items.compactMap(\.snapshotRunID)) == [first.runID, second.runID])
  for item in plan.items { _ = try catalog.validate(item, in: plan) }
  let item = try #require(plan.items.first)
  let proof = try #require(item.catalogProof)
  let forged = PlanItem(
    id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
    inventory: item.inventory, ancestors: item.ancestors,
    catalogProof: CatalogProof(
      version: proof.version, rowID: proof.rowID, allowedRoot: proof.allowedRoot,
      method: proof.method, snapshotRunID: UUID()), policy: item.policy,
    snapshotRunID: item.snapshotRunID)
  #expect(throws: CatalogFailure.self) { try catalog.validate(forged, in: plan) }
  let trash = fixture.home + "/Trash"
  try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
  let journal = CleanJournal()
  let result = try await ActionExecutor(
    journal: journal, trash: LocalTrash(directory: trash),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID), catalog: catalog
  ).execute(plan)
  #expect(result.items.allSatisfy { $0.outcome == .applied })
  try await ActionHistory(journal: journal, homeDirectory: fixture.home).undo(planID: plan.id)
  #expect(try Data(contentsOf: URL(fileURLWithPath: otherPath)) == bytes)
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.candidate + "/a")) == Data("a".utf8))
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.candidate + "/b")) == Data("b".utf8))
}

private func buildFixture(_ home: String) throws -> (root: String, project: String) {
  let root = home + "/Library/Developer/Xcode/DerivedData"
  let project = root + "/LightenQA-" + UUID().uuidString
  let app = project + "/Build/Products/Debug/LightenQA-" + UUID().uuidString + ".app"
  let paths = [
    app + "/Contents/MacOS/tool": Data("binary".utf8),
    app + "/Contents/Resources/en.lproj/Localizable.strings": Data("text".utf8),
    project + "/Build/Products/Debug/Tool.dSYM/Contents/Resources/DWARF/Tool": Data("symbols".utf8),
    app + "/Contents/Info.plist": try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "qa.lighten." + UUID().uuidString], format: .xml, options: 0),
  ]
  for (path, data) in paths {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path))
  }
  return (root, project)
}

private func cleanFixtureHashes(_ root: String) throws -> [String: SHA256.Digest] {
  var hashes: [String: SHA256.Digest] = [:]
  func visit(_ path: String) throws {
    let identity = try DescriptorFileSystem.identity(at: path)
    if identity.kind == .regular {
      hashes[path] = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
    } else if identity.kind == .directory {
      for name in try FileManager.default.contentsOfDirectory(atPath: path) { try visit(path + "/" + name) }
    }
  }
  try visit(root)
  return hashes
}

@Test("Build output moves application products, symbols and symlink leaves together and restores exactly")
func catalogBuildOutputTrashAndUndo() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let build = try buildFixture(fixture.home)
  #expect(symlink(fixture.candidate, build.project + "/outside-link") == 0)
  let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: build.root)
  let entry = try #require(snapshot.entries.first { $0.path == build.project })
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let plan = try catalog.plan(snapshot: snapshot, selectedIDs: [entry.id], rowID: "xcode-derived-data", kind: .trash)
  let item = try #require(plan.items.first)
  #expect(item.policy == .catalogBuildOutput)
  #expect(item.inventory.contains { $0.path.hasSuffix("/Tool.dSYM") })
  #expect(item.inventory.contains { $0.path.hasSuffix(".app") })
  #expect(!item.inventory.contains { $0.path.contains(".dSYM/") || $0.path.contains(".app/") })
  #expect(!item.inventory.contains { $0.path.hasPrefix(build.project + "/outside-link/") })
  try ActionGuard(homeDirectory: fixture.home).validate(item)
  #expect(throws: CatalogFailure.self) {
    try catalog.plan(snapshot: snapshot, selectedIDs: [entry.id], rowID: "xcode-derived-data", kind: .catalogDelete)
  }
  let original = try cleanFixtureHashes(build.project)
  #expect(original.count == 4)
  #expect(original.keys.contains { $0.contains(".dSYM/Contents/Resources/DWARF") })
  let trash = fixture.home + "/Trash"
  try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
  let journal = CleanJournal()
  let result = try await ActionExecutor(
    journal: journal, trash: LocalTrash(directory: trash),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID), catalog: catalog,
    runningApplications: FixedRunning(value: false), applicationActivity: FixtureClearApplicationActivity()
  ).execute(plan)
  #expect(result.items[0].outcome == .applied)
  #expect(FileManager.default.fileExists(atPath: fixture.candidate + "/a"))
  try await ActionHistory(journal: journal, homeDirectory: fixture.home).undo(planID: plan.id)
  #expect(try cleanFixtureHashes(build.project) == original)
  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: build.project + "/outside-link") == fixture.candidate)
}

@Test("Catalog package exceptions never apply to protected personal data or forged cache policy")
func catalogBuildOutputStillRejectsProtectedDataAndForgedPolicy() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let build = try buildFixture(fixture.home)
  let protected = build.project + "/Pictures.photoslibrary"
  try FileManager.default.createDirectory(atPath: protected, withIntermediateDirectories: true)
  let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: build.root)
  let entry = try #require(snapshot.entries.first { $0.path == build.project })
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  #expect(throws: PlanRejection.self) {
    try catalog.plan(snapshot: snapshot, selectedIDs: [entry.id], rowID: "xcode-derived-data", kind: .trash)
  }
  let base = try await cleanTrashPlan(fixture)
  let item = try #require(base.items.first)
  let forged = PlanItem(
    id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID, inventory: item.inventory,
    ancestors: item.ancestors, catalogProof: item.catalogProof, policy: .catalogBuildOutput,
    snapshotRunID: item.snapshotRunID)
  #expect(throws: CatalogFailure.self) { try catalog.validate(forged, in: base) }
  #expect(throws: GuardFailure.self) { try ActionGuard(homeDirectory: fixture.home).validate(forged) }
}

@Test("A catalog symlink root is a Trash leaf and never grants permanent or target authority")
func catalogSymlinkChildTrashPreservesTarget() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let path = fixture.root + "/LightenQA-" + UUID().uuidString
  #expect(symlink(fixture.candidate, path) == 0)
  let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: fixture.root)
  let id = try #require(snapshot.entries.first { $0.path == path }).id
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let plan = try catalog.plan(snapshot: snapshot, selectedIDs: [id], rowID: "pip-http-v2", kind: .trash)
  #expect(plan.items[0].inventory.count == 1)
  try ActionGuard(homeDirectory: fixture.home).validate(plan.items[0])
  #expect(throws: PlanFailure.self) {
    try catalog.plan(snapshot: snapshot, selectedIDs: [id], rowID: "pip-http-v2", kind: .catalogDelete)
  }
  let trash = fixture.home + "/Trash"
  try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
  let journal = CleanJournal()
  let result = try await ActionExecutor(
    journal: journal, trash: LocalTrash(directory: trash),
    guardService: ActionGuard(homeDirectory: fixture.home),
    activity: FixedActivity(state: .clearObservedCurrentUID), catalog: catalog
  ).execute(plan)
  #expect(result.items[0].outcome == .applied)
  #expect(FileManager.default.fileExists(atPath: fixture.candidate + "/a"))
  try await ActionHistory(journal: journal, homeDirectory: fixture.home).undo(planID: plan.id)
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == fixture.candidate)
}

@Test("A forged exact inventory cannot bypass protected descendants using a valid catalog proof")
func catalogGuardRejectsProtectedDescendantInForgedInventory() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let base = try await cleanTrashPlan(fixture)
  let original = try #require(base.items.first)
  let protected = fixture.candidate + "/Personal.photoslibrary"
  try FileManager.default.createDirectory(atPath: protected, withIntermediateDirectories: true)
  var entries = original.inventory
  entries[0] = ScanEntry(
    id: original.id, parentID: nil, path: fixture.candidate,
    identity: try DescriptorFileSystem.identity(at: fixture.candidate), issues: [], readable: true)
  entries.append(
    ScanEntry(
      parentID: original.id, path: protected,
      identity: try DescriptorFileSystem.identity(at: protected), issues: [], readable: true))
  let forged = PlanItem(
    id: original.id, sourcePath: original.sourcePath, volumeID: original.volumeID,
    inventory: entries, ancestors: original.ancestors, catalogProof: original.catalogProof,
    policy: original.policy, snapshotRunID: original.snapshotRunID)
  #expect(throws: PlanRejection(.containsProtectedItem, path: protected, ruleID: "photos-library")) {
    try ActionGuard(homeDirectory: fixture.home).validate(forged)
  }
}

private actor CountedItemActivity: ProcessActivitySource {
  private var observed = 0
  func activity(for rowID: String) async -> ProcessActivity {
    observed += 1
    return ProcessActivity(state: .clearObservedCurrentUID)
  }
  func count() -> Int { observed }
}

@Test("Permanent deletion checks activity per item and detects new children in a nested directory")
func catalogPermanentItemActivityAndNestedUnknownChild() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let nested = fixture.candidate + "/nested"
  try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
  try Data("c".utf8).write(to: URL(fileURLWithPath: nested + "/c"))
  try Data("d".utf8).write(to: URL(fileURLWithPath: nested + "/d"))
  let plan = try await cleanPlan(fixture)
  let activity = CountedItemActivity()
  let journal = CleanJournal(afterProgress: {
    try? Data("unplanned".utf8).write(to: URL(fileURLWithPath: nested + "/new-child"))
  })
  let result = try await ActionExecutor(
    journal: journal, trash: ForbiddenTrash(), guardService: ActionGuard(homeDirectory: fixture.home),
    activity: activity, catalog: try CleanCatalog(homeDirectory: fixture.home)
  ).execute(plan, confirmation: IrreversibleConfirmation(planID: plan.id, method: .catalogDelete))
  #expect(result.items[0].outcome == .failed)
  #expect(result.items[0].deletedCount == 1)
  #expect(await activity.count() == 2)
  #expect(FileManager.default.fileExists(atPath: nested + "/new-child"))
  #expect(FileManager.default.fileExists(atPath: nested + "/c"))
  #expect(FileManager.default.fileExists(atPath: fixture.candidate + "/a"))
}

private actor CandidateScopedActivity: ProcessActivitySource {
  let clearPath: String
  private var observedPaths: [String] = []

  init(clearPath: String) { self.clearPath = clearPath }
  func activity(for rowID: String) -> ProcessActivity { ProcessActivity(state: .unknown) }
  func activity(for row: CatalogRow, rootPath: String) -> ProcessActivity {
    observedPaths.append(rootPath)
    return ProcessActivity(state: rootPath == clearPath ? .clearObservedCurrentUID : .active)
  }
  func paths() -> [String] { observedPaths }
}

@Test("Log candidates use their own activity root and current content age at execution")
func catalogLogsUseCandidateActivityAndFreshContentAge() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let row = try #require(catalog.row(id: "user-app-logs"))
  let root = catalog.root(for: row)
  let oldLogs = root + "/qa.lighten.old"
  let activeSibling = root + "/qa.lighten.active"
  try FileManager.default.createDirectory(atPath: oldLogs + "/archive", withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: activeSibling, withIntermediateDirectories: true)
  let log = oldLogs + "/archive/history.log"
  try Data("older diagnostics".utf8).write(to: URL(fileURLWithPath: log))
  let oldDate = Date(timeIntervalSinceNow: -30 * 86_400)
  try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: log)
  // The candidate folder was just created. Its old contents, rather than that
  // folder's fresh mtime, make this candidate eligible.
  #expect(catalog.allowsCandidate(path: oldLogs, row: row))
  #expect(catalog.activityRoot(for: row, candidatePath: oldLogs) == oldLogs)
  let tool = try #require(catalog.row(id: "pip-http-v2"))
  #expect(catalog.activityRoot(for: tool, candidatePath: fixture.candidate) == fixture.root)
  let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: root)
  let id = try #require(snapshot.entries.first { $0.path == oldLogs }).id
  let plan = try catalog.plan(snapshot: snapshot, selectedIDs: [id], rowID: row.id, kind: .trash)
  let item = try #require(plan.items.first)
  try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: log)
  #expect(catalog.candidateRejection(path: oldLogs, row: row)?.ruleID == "minimum-age")
  #expect(throws: CatalogFailure.self) { try catalog.validate(item, in: plan) }
  try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: log)
  let freshPlan = try catalog.plan(snapshot: snapshot, selectedIDs: [id], rowID: row.id, kind: .trash)
  let trash = fixture.home + "/Trash"
  try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
  let activity = CandidateScopedActivity(clearPath: oldLogs)
  let result = try await ActionExecutor(
    journal: CleanJournal(), trash: LocalTrash(directory: trash),
    guardService: ActionGuard(homeDirectory: fixture.home), activity: activity, catalog: catalog
  ).execute(freshPlan)
  #expect(result.items.map(\.outcome) == [.applied])
  #expect(await activity.paths() == [oldLogs, oldLogs])
  #expect(FileManager.default.fileExists(atPath: activeSibling))
}

@Test("Age checks use symlink metadata and reject unbounded trees")
func catalogAgeIsNoFollowAndBounded() throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let row = try #require(catalog.row(id: "user-app-logs"))
  let root = catalog.root(for: row)
  let candidate = root + "/qa.lighten.link"
  try FileManager.default.createDirectory(atPath: candidate, withIntermediateDirectories: true)
  let oldTarget = fixture.home + "/old-target"
  try Data("outside the log candidate".utf8).write(to: URL(fileURLWithPath: oldTarget))
  try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSinceNow: -30 * 86_400)], ofItemAtPath: oldTarget)
  #expect(symlink(oldTarget, candidate + "/recent-link") == 0)
  #expect(catalog.candidateRejection(path: candidate, row: row)?.ruleID == "minimum-age")
  #expect(catalog.newestContentModification(at: candidate, limit: 1) == nil)
  #expect(catalog.newestContentModification(at: candidate, limit: 2) != nil)
  #expect(try Data(contentsOf: URL(fileURLWithPath: oldTarget)) == Data("outside the log candidate".utf8))
}

@Test("Application-suffixed cache directories remain ordinary; actual and linked bundles stay distinct")
func catalogPlainApplicationSuffixIsNotPackageAuthority() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let row = try #require(catalog.row(id: "user-app-caches"))
  let root = catalog.root(for: row)
  let plain = root + "/qa.lighten.cache.app"
  try FileManager.default.createDirectory(atPath: plain + "/nested.app", withIntermediateDirectories: true)
  try Data("cache".utf8).write(to: URL(fileURLWithPath: plain + "/nested.app/data"))
  let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: root)
  let entry = try #require(snapshot.entries.first { $0.path == plain })
  #expect(!entry.issues.contains(.packageBoundary))
  #expect(snapshot.entries.contains { $0.path == plain + "/nested.app/data" })
  #expect(!ExactInventory.isApplicationName(plain))
  let plan = try catalog.plan(snapshot: snapshot, selectedIDs: [entry.id], rowID: row.id, kind: .trash)
  #expect(plan.items[0].policy == .catalogTrash)
  #expect(plan.items[0].nestedApplicationIDs?.isEmpty == true)
  try ActionGuard(homeDirectory: fixture.home).validate(plan.items[0])

  let actual = root + "/qa.lighten.package.app"
  try FileManager.default.createDirectory(atPath: actual + "/Contents", withIntermediateDirectories: true)
  let metadata = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "qa.lighten.package"], format: .xml, options: 0)
  try metadata.write(to: URL(fileURLWithPath: actual + "/Contents/Info.plist"))
  #expect(ExactInventory.isApplicationName(actual))
  #expect(ScanService.isPackage(actual))
  let link = root + "/qa.lighten.link.app"
  #expect(symlink(actual, link) == 0)
  #expect(!ExactInventory.isApplicationName(link))
  #expect(!ScanService.isPackage(link))
  let fresh = try await ScanService(homeDirectory: fixture.home).scan(rootPath: root)
  let actualID = try #require(fresh.entries.first { $0.path == actual }).id
  let actualPlan = try catalog.plan(snapshot: fresh, selectedIDs: [actualID], rowID: row.id, kind: .trash)
  #expect(actualPlan.items[0].nestedApplicationIDs == ["qa.lighten.package"])
  try ActionGuard(homeDirectory: fixture.home).validate(actualPlan.items[0])
}

@Test(
  "Known Apple daemon cache names are report-only with an explicit reason",
  arguments: [
    "CloudKit", "FamilyCircle", "PassKit", "askpermissiond", "GameKit", "SiriTTS", "GeoServices", "familycircled",
  ])
func catalogAppleDaemonCachesAreReportOnly(_ name: String) async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let row = try #require(catalog.row(id: "user-app-caches"))
  let root = catalog.root(for: row)
  let cache = root + "/" + name
  try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
  try Data("system cache".utf8).write(to: URL(fileURLWithPath: cache + "/data"))
  #expect(!catalog.allowsCandidate(path: cache, row: row))
  let refusal = try #require(catalog.candidateRejection(path: cache, row: row))
  #expect(refusal.reason == .protectedItem)
  #expect(refusal.ruleID == "apple-system-cache")
  let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: root)
  let id = try #require(snapshot.entries.first { $0.path == cache }).id
  let outcome = catalog.planAvailable(selections: [
    CatalogSelection(snapshot: snapshot, selectedIDs: [id], rowID: row.id)
  ])
  #expect(outcome.plan == nil)
  #expect(outcome.rejections == [refusal])
}

@Test(
  "One stale candidate is skipped while other categories share a plan", arguments: [ActionKind.trash, .catalogDelete])
func catalogAvailablePlanKeepsValidCategories(_ kind: ActionKind) async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let stale = fixture.root + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: stale, withIntermediateDirectories: true)
  try Data("changed later".utf8).write(to: URL(fileURLWithPath: stale + "/data"))
  let other = try #require(catalog.row(id: "homebrew-downloads"))
  let otherRoot = catalog.root(for: other)
  try FileManager.default.createDirectory(atPath: otherRoot, withIntermediateDirectories: true)
  let archive = otherRoot + "/LightenQA-" + UUID().uuidString
  try Data("archive".utf8).write(to: URL(fileURLWithPath: archive))
  let first = try await ScanService(homeDirectory: fixture.home).scan(rootPath: fixture.root)
  let second = try await ScanService(homeDirectory: fixture.home).scan(rootPath: otherRoot)
  let goodID = try #require(first.entries.first { $0.path == fixture.candidate }).id
  let staleID = try #require(first.entries.first { $0.path == stale }).id
  let otherID = try #require(second.entries.first { $0.path == archive }).id
  try FileManager.default.removeItem(atPath: stale)
  let selections = [
    CatalogSelection(snapshot: first, selectedIDs: [goodID, staleID], rowID: "pip-http-v2"),
    CatalogSelection(snapshot: second, selectedIDs: [otherID], rowID: other.id),
  ]
  #expect(throws: (any Error).self) { try catalog.plan(selections: selections, kind: kind) }
  let outcome = catalog.planAvailable(selections: selections, kind: kind)
  let plan = try #require(outcome.plan)
  #expect(plan.kind == kind)
  #expect(Set(plan.items.map(\.sourcePath)) == [fixture.candidate, archive])
  #expect(Set(plan.items.compactMap(\.snapshotRunID)) == [first.runID, second.runID])
  #expect(outcome.rejections.count == 1)
  #expect(outcome.rejections[0].path == stale)
  #expect(outcome.rejections[0].reason == .changedSinceScan)
  for item in plan.items { try ActionGuard(homeDirectory: fixture.home).validate(item) }
}

@Test("Available planning does not grant permanent authority to package contents")
func catalogAvailablePermanentStillRejectsPackageCandidates() async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let app = fixture.root + "/LightenQA-" + UUID().uuidString + ".app"
  try FileManager.default.createDirectory(atPath: app + "/Contents", withIntermediateDirectories: true)
  let info = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "qa.lighten.permanent-package"], format: .xml, options: 0)
  try info.write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
  let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: fixture.root)
  let goodID = try #require(snapshot.entries.first { $0.path == fixture.candidate }).id
  let appID = try #require(snapshot.entries.first { $0.path == app }).id
  let selection = CatalogSelection(snapshot: snapshot, selectedIDs: [goodID, appID], rowID: "pip-http-v2")
  let permanent = catalog.planAvailable(selections: [selection], kind: .catalogDelete)
  let plan = try #require(permanent.plan)
  #expect(plan.items.map(\.sourcePath) == [fixture.candidate])
  #expect(plan.items[0].policy == nil)
  #expect(permanent.rejections.map(\.path) == [app])
  let trash = try #require(catalog.planAvailable(selections: [selection], kind: .trash).plan)
  #expect(Set(trash.items.map(\.sourcePath)) == [fixture.candidate, app])
  #expect(FileManager.default.fileExists(atPath: app + "/Contents/Info.plist"))
}

@Test(
  "Catalog discovery reports a dedicated cache parent without granting its generic row eligibility",
  arguments: [false, true])
func catalogDiscoveryPreservesReportOnlyOverlap(native: Bool) async throws {
  let fixture = try cleanFixture()
  defer { try? FileManager.default.removeItem(atPath: fixture.home) }
  let catalog = try CleanCatalog(homeDirectory: fixture.home)
  let generic = try #require(catalog.row(id: "user-app-caches"))
  let discovery: CatalogDiscovery
  if native {
    discovery = try await catalog.discover(rowID: generic.id)
  } else {
    let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: catalog.root(for: generic))
    discovery = try catalog.discovery(snapshot: snapshot, rowID: generic.id)
  }
  let parent = fixture.home + "/Library/Caches/pip"
  #expect(Set(discovery.candidates.map { $0.entry.path }) == [parent])
  #expect(!discovery.candidates.contains { $0.entry.path == discovery.snapshot.rootPath })
  let overlap = try #require(discovery.candidates.first)
  #expect(overlap.rejection?.reason == .unavailable)
  #expect(overlap.rejection?.ruleID == "catalog-overlap")
}
