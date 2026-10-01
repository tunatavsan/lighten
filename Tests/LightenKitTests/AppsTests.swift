import Darwin
import Foundation
import Testing

@testable import LightenKit

private struct AppsFixture {
  let home: String
  let appRoot: String
  let app: String
  let bundleID: String
  let cache: String
  let trash: String

  init() throws {
    guard let root = realpath(NSTemporaryDirectory(), nil) else {
      throw FileSystemFailure.invalidPath
    }
    defer { free(root) }
    home = String(cString: root) + "/LightenQA-" + UUID().uuidString
    appRoot = home + "/Applications"
    app = appRoot + "/Fixture.app"
    bundleID = "com.example.fixture" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    cache = home + "/Library/Caches/" + bundleID
    trash = home + "/Trash"
    try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      atPath: app + "/Contents/Resources/en.lproj", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
    try writeInfo()
    try Data("executable".utf8).write(to: URL(fileURLWithPath: app + "/Contents/MacOS/fixture"))
    try Data("localized".utf8).write(to: URL(fileURLWithPath: app + "/Contents/Resources/en.lproj/text"))
    try Data("cache".utf8).write(to: URL(fileURLWithPath: cache + "/record"))
  }

  func writeInfo() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": bundleID,
        "CFBundleShortVersionString": "2.4.1",
      ], format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
  }

  var service: RelatedDataService {
    RelatedDataService(
      homeDirectory: home, applicationRoots: [appRoot],
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  }

  func candidate() async throws -> RelatedDataCandidate {
    try #require((await service.discover()).first { $0.path == cache })
  }

  func installedApp() throws -> InstalledApplication {
    try #require(service.inventory().applications.first { $0.path == app })
  }

  func remove() { try? FileManager.default.removeItem(atPath: home) }
}

private struct AppsRunning: RunningApplicationSource {
  let value: Bool?
  func isRunning(bundleID: String) async -> Bool? { value }
}

@Test("Package sizes are exact, including protected interiors summed from metadata")
func appSizeIsExactWithoutBudget() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let (_, reports) = await ApplicationDiscovery(related: fixture.service).discover()
  let report = try #require(reports.first { $0.path == fixture.app })
  let info = try Data(contentsOf: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist")).count
  #expect(!report.partial)
  #expect(report.logical.completeTotal == Int64("executable".utf8.count + "localized".utf8.count + info))
  // Contents, MacOS, Resources, en.lproj, three files.
  #expect(report.knownItemCount == 7)
}

@Test("Inventory metadata is published before sizes and the final event carries the review")
func inventoryPrecedesMeasurement() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let discovery = ApplicationDiscovery(related: fixture.service)
  var sawInventory = false
  var finished: [ApplicationReport]?
  for await event in discovery.events() {
    switch event {
    case .inventory(let inventory, let metadata):
      sawInventory = inventory.complete && metadata.contains { $0.path == fixture.app }
      #expect(metadata.first?.logical.completeTotal == nil)
    case .measured:
      #expect(sawInventory)
    case .orphans:
      #expect(sawInventory)
    case .completed(let inventory, let reports):
      #expect(inventory.complete)
      finished = reports
    }
  }
  #expect(sawInventory)
  let report = try #require(finished?.first { $0.path == fixture.app })
  #expect(report.bundleID == fixture.bundleID)
  #expect(report.version == "2.4.1")
  #expect(report.logical.completeTotal != nil)
}

private actor MutatingRunning: RunningApplicationSource {
  let infoPath: String
  private var calls = 0
  init(infoPath: String) { self.infoPath = infoPath }
  func isRunning(bundleID: String) async -> Bool? {
    calls += 1
    if calls == 2 {
      try? Data("changed metadata".utf8).write(to: URL(fileURLWithPath: infoPath))
    }
    return false
  }
}

private struct AppsTrash: TrashMoving {
  let destination: String
  func moveToTrash(path: String) async throws -> String {
    let target = destination + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: target)
    return target
  }
}

@Test("App inventory exposes metadata and a complete package size")
func appInventoryMetadataAndPartialSize() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let (inventory, reports) = await ApplicationDiscovery(related: fixture.service).discover()
  #expect(inventory.complete)
  let app = try #require(reports.first { $0.path == fixture.app })
  #expect(app.bundleID == fixture.bundleID)
  #expect(app.version == "2.4.1")
  #expect(app.signerTeamID == nil)
  // Protected application interiors are summed from metadata, so the size is exact.
  #expect(!app.partial)
  #expect(app.logical.completeTotal == app.logical.knownLowerBound)
  #expect(app.logical.knownLowerBound > 0)
  #expect(app.related.first { $0.path == fixture.cache }?.classification == .installed)
  let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: fixture.appRoot)
  let id = try #require(snapshot.entries.first { $0.path == fixture.app }).id
  #expect(throws: PlanFailure.self) {
    _ = try PlanService(homeDirectory: fixture.home).makePlan(snapshot: snapshot, selectedIDs: [id])
  }
}

@Test("Installed related data requires separate proof and can be restored from Trash")
func installedDataTrashUndo() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let candidate = try await fixture.candidate()
  let plan = try fixture.service.planInstalled(app: fixture.installedApp(), candidate: candidate)
  #expect(plan.items.count == 1)
  #expect(plan.items[0].sourcePath == fixture.cache)
  #expect(plan.items[0].installedRelatedProof != nil)
  #expect(plan.items[0].relatedProof == nil)
  let journal = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
  let executor = ActionExecutor(
    journal: journal, trash: AppsTrash(destination: fixture.trash),
    guardService: ActionGuard(homeDirectory: fixture.home),
    related: fixture.service, runningApplications: AppsRunning(value: false),
    applicationActivity: FixtureClearApplicationActivity())
  let result = try await executor.execute(plan)
  #expect(result.items.first?.outcome == .applied)
  #expect(!FileManager.default.fileExists(atPath: fixture.cache))
  let history = ActionHistory(journal: journal, homeDirectory: fixture.home)
  try await history.undo(planID: plan.id, itemID: plan.items[0].id)
  #expect(FileManager.default.fileExists(atPath: fixture.cache + "/record"))
}

@Test("Running or unknown app and changed metadata never move installed data")
func installedDataVetoes() async throws {
  for value in [true, nil] as [Bool?] {
    let fixture = try AppsFixture()
    defer { fixture.remove() }
    let plan = try fixture.service.planInstalled(
      app: fixture.installedApp(), candidate: try await fixture.candidate())
    let executor = ActionExecutor(
      journal: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"),
      trash: AppsTrash(destination: fixture.trash),
      guardService: ActionGuard(homeDirectory: fixture.home),
      related: fixture.service, runningApplications: AppsRunning(value: value),
      applicationActivity: FixtureClearApplicationActivity())
    let result = try await executor.execute(plan)
    #expect(result.items.first?.outcome == .skipped)
    #expect(FileManager.default.fileExists(atPath: fixture.cache))
  }
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let plan = try fixture.service.planInstalled(
    app: fixture.installedApp(), candidate: try await fixture.candidate())
  let executor = ActionExecutor(
    journal: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"),
    trash: AppsTrash(destination: fixture.trash),
    guardService: ActionGuard(homeDirectory: fixture.home),
    related: fixture.service,
    runningApplications: MutatingRunning(infoPath: fixture.app + "/Contents/Info.plist"),
    applicationActivity: FixtureClearApplicationActivity())
  let result = try await executor.execute(plan)
  #expect(result.items.first?.outcome == .skipped)
  #expect(FileManager.default.fileExists(atPath: fixture.cache))
}

@Test("Duplicate ID, incomplete inventory, and similar names cannot authorize installed data")
func installedDataRequiresUniqueCompleteExactOwner() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let candidate = try await fixture.candidate()
  let app = try fixture.installedApp()
  let similar = fixture.home + "/Library/Caches/" + fixture.bundleID + "-similar"
  try FileManager.default.createDirectory(atPath: similar, withIntermediateDirectories: true)
  #expect((await fixture.service.discover()).first { $0.path == similar }?.classification == .uncertain)
  let sibling = fixture.appRoot + "/Sibling.app"
  try FileManager.default.copyItem(atPath: fixture.app, toPath: sibling)
  #expect(throws: RelatedFailure.self) {
    try fixture.service.planInstalled(app: app, candidate: candidate)
  }
  try FileManager.default.removeItem(atPath: sibling)
  let bad = fixture.appRoot + "/Unknown.app"
  try FileManager.default.createDirectory(atPath: bad, withIntermediateDirectories: true)
  #expect(!fixture.service.inventory().complete)
  #expect(throws: RelatedFailure.self) {
    try fixture.service.planInstalled(app: app, candidate: candidate)
  }
}

@Test("Case aliases remain owner evidence but never exclusive installed-data authority")
func appCaseAliasesBlockAbsenceAndAction() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let candidate = try await fixture.candidate()
  let app = try fixture.installedApp()
  let alias = fixture.appRoot + "/Alias.APP"
  try FileManager.default.createDirectory(atPath: alias + "/Contents", withIntermediateDirectories: true)
  let aliasData = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": fixture.bundleID.uppercased()],
    format: .xml, options: 0)
  try aliasData.write(to: URL(fileURLWithPath: alias + "/Contents/Info.plist"))
  let inventory = fixture.service.inventory()
  #expect(inventory.complete)
  #expect(inventory.applications.count == 2)
  #expect(throws: RelatedFailure.self) {
    try fixture.service.planInstalled(app: app, candidate: candidate)
  }
  try FileManager.default.removeItem(atPath: fixture.app)
  let after = try await fixture.candidate()
  #expect(after.classification != .historicallyVerifiedAbsent)
  #expect(fixture.service.inventory().contains(fixture.bundleID))
}

@Test("Exact standard app data is actionable through fresh related proof")
func appOtherDataUsesRelatedProof() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let support = fixture.home + "/Library/Application Support/" + fixture.bundleID
  let container = fixture.home + "/Library/Containers/" + fixture.bundleID
  let logs = fixture.home + "/Library/Logs/" + fixture.bundleID
  try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: container, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    atPath: (logs as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(atPath: logs, withDestinationPath: "/missing-log")
  let (_, reports) = await ApplicationDiscovery(related: fixture.service).discover()
  let app = try #require(reports.first { $0.path == fixture.app })
  #expect(app.related.first { $0.path == support }?.classification == .installed)
  #expect(app.related.first { $0.path == container }?.classification == .installed)
  #expect(app.related.first { $0.path == logs }?.reason == .recordUnsafe)
  for path in [support, container] {
    let candidate = try #require(app.related.first { $0.path == path })
    let plan = try fixture.service.planInstalled(app: fixture.installedApp(), candidate: candidate)
    #expect(plan.items[0].installedRelatedProof != nil)
  }
}

@Test("Linked apps resolve read-only; an unresolvable link keeps the inventory incomplete")
func linkedApplicationsResolveReadOnly() throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let elsewhere = fixture.home + "/Shared/Real.app"
  try FileManager.default.createDirectory(atPath: elsewhere + "/Contents", withIntermediateDirectories: true)
  let data = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "com.example.linked"], format: .xml, options: 0)
  try data.write(to: URL(fileURLWithPath: elsewhere + "/Contents/Info.plist"))
  #expect(symlink(elsewhere, fixture.appRoot + "/Linked.app") == 0)
  let inventory = fixture.service.inventory()
  #expect(inventory.complete)
  let linked = try #require(inventory.applications.first { $0.bundleID == "com.example.linked" })
  #expect(linked.path == fixture.appRoot + "/Linked.app")
  #expect(linked.linkTarget == elsewhere)

  try Data("doc".utf8).write(to: URL(fileURLWithPath: fixture.home + "/readme.html"))
  #expect(symlink(fixture.home + "/readme.html", fixture.appRoot + "/Readme.html") == 0)
  #expect(fixture.service.inventory().complete)

  #expect(symlink(fixture.home + "/Shared", fixture.appRoot + "/More Apps") == 0)
  #expect(!fixture.service.inventory().complete)
  #expect(unlink(fixture.appRoot + "/More Apps") == 0)
  #expect(symlink(fixture.home + "/missing.app", fixture.appRoot + "/Broken.app") == 0)
  #expect(!fixture.service.inventory().complete)
}

@Test("An app known elsewhere keeps its data from being called a leftover")
func installedElsewhereIsNotALeftover() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let orphan = fixture.home + "/Library/Caches/com.example.elsewhere"
  try FileManager.default.createDirectory(atPath: orphan, withIntermediateDirectories: true)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot],
    installedElsewhere: { $0 == "com.example.elsewhere" },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let candidate = try #require((await service.discover()).first { $0.path == orphan })
  #expect(candidate.classification == .uncertain)
  #expect(candidate.reason == .installedElsewhere)
}

@Test("Bundles without an identifier are listed without making the inventory incomplete")
func identifierlessAndWrappedApps() throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let plain = fixture.appRoot + "/Launcher.app/Contents"
  try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
  try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Launcher"], format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: plain + "/Info.plist"))
  let wrapped = fixture.appRoot + "/Phone.app/Wrapper/Phone.app"
  try FileManager.default.createDirectory(atPath: wrapped, withIntermediateDirectories: true)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "com.example.phone"], format: .xml, options: 0
  )
  .write(to: URL(fileURLWithPath: wrapped + "/Info.plist"))
  let inventory = fixture.service.inventory()
  #expect(inventory.complete)
  #expect(inventory.unidentifiedPaths.contains(fixture.appRoot + "/Launcher.app"))
  #expect(
    inventory.applications.contains { $0.bundleID == "com.example.phone" && $0.path == fixture.appRoot + "/Phone.app" })

  try FileManager.default.createDirectory(atPath: fixture.appRoot + "/Empty.app", withIntermediateDirectories: true)
  #expect(!fixture.service.inventory().complete)
}

private struct SelectiveRunning: RunningApplicationSource {
  let running: Set<String>
  func isRunning(bundleID: String) async -> Bool? { running.contains(bundleID) }
}

@Test("A whole app moves only when it and every nested app are closed, then Undo restores it")
func wholeApplicationMovesWhenClosed() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let helper = fixture.app + "/Contents/Helpers/Agent.app/Contents"
  try FileManager.default.createDirectory(atPath: helper, withIntermediateDirectories: true)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "com.example.agent"], format: .xml, options: 0
  )
  .write(to: URL(fileURLWithPath: helper + "/Info.plist"))
  let identity = try DescriptorFileSystem.identity(at: fixture.app)
  func plan() throws -> ActionPlan {
    try PlanService(homeDirectory: fixture.home).makeSpacePlan(
      selections: [PlanService.Selection(path: fixture.app, device: identity.device, inode: identity.inode)],
      scanRootPath: fixture.appRoot, runID: UUID())
  }
  let first = try plan()
  #expect(first.items.first?.nestedApplicationIDs == ["com.example.agent"])
  let journal = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
  let blocked = try await ActionExecutor(
    journal: journal, trash: AppsTrash(destination: fixture.trash),
    guardService: ActionGuard(homeDirectory: fixture.home), related: fixture.service,
    runningApplications: SelectiveRunning(running: ["com.example.agent"]),
    applicationActivity: FixtureClearApplicationActivity()
  ).execute(first)
  #expect(blocked.items.first?.outcome == .skipped)
  #expect(FileManager.default.fileExists(atPath: fixture.app))

  let second = try plan()
  let moved = try await ActionExecutor(
    journal: journal, trash: AppsTrash(destination: fixture.trash),
    guardService: ActionGuard(homeDirectory: fixture.home), related: fixture.service,
    runningApplications: SelectiveRunning(running: []), applicationActivity: FixtureClearApplicationActivity()
  ).execute(second)
  #expect(moved.items.first?.outcome == .applied)
  #expect(!FileManager.default.fileExists(atPath: fixture.app))
  let history = ActionHistory(journal: journal)
  let item = try #require(try await history.reconcile().items.first { $0.planID == second.id })
  try await history.undo(planID: item.planID, itemID: item.itemID)
  #expect(FileManager.default.fileExists(atPath: fixture.app + "/Contents/Info.plist"))
}
