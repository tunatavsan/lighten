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
    home = String(cString: root) + "/lighten-apps-" + UUID().uuidString
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
    RelatedDataService(homeDirectory: home, applicationRoots: [appRoot])
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

private final class AppsStepClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: TimeInterval = 0
  private let step: TimeInterval

  init(step: TimeInterval) { self.step = step }

  func now() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    let result = value
    value += step
    return result
  }
}

@Test("Per-app size budget keeps measured bytes as a partial lower bound")
func appSizeBudgetProducesPartialLowerBound() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let clock = AppsStepClock(step: 0.7)
  let (_, reports) = await ApplicationDiscovery(
    related: fixture.service, uptime: { clock.now() }
  ).discover()
  let report = try #require(reports.first { $0.path == fixture.app })
  #expect(report.sizeLimitReached)
  #expect(report.partial)
  #expect(report.logical.completeTotal == nil)
  #expect(report.logical.knownLowerBound >= 0)
}

@Test("Global size budget leaves metadata visible and still emits final review event")
func globalAppSizeBudgetKeepsInventory() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let clock = AppsStepClock(step: 21)
  let discovery = ApplicationDiscovery(related: fixture.service, uptime: { clock.now() })
  var sawInventory = false
  var finished: [ApplicationReport]?
  for await event in discovery.events() {
    switch event {
    case .inventory(let inventory, let metadata):
      sawInventory = inventory.complete && metadata.contains { $0.path == fixture.app }
      #expect(metadata.first?.logical.completeTotal == nil)
    case .measured:
      break
    case .completed(let inventory, let reports):
      #expect(inventory.complete)
      finished = reports
    }
  }
  #expect(sawInventory)
  let report = try #require(finished?.first { $0.path == fixture.app })
  #expect(report.bundleID == fixture.bundleID)
  #expect(report.version == "2.4.1")
  #expect(report.sizeLimitReached)
  #expect(report.logical.completeTotal == nil)
  #expect(report.logical.knownLowerBound == 0)
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

@Test("App inventory and package size expose metadata and protected lower bound")
func appInventoryMetadataAndPartialSize() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let (inventory, reports) = await ApplicationDiscovery(related: fixture.service).discover()
  #expect(inventory.complete)
  let app = try #require(reports.first { $0.path == fixture.app })
  #expect(app.bundleID == fixture.bundleID)
  #expect(app.version == "2.4.1")
  #expect(app.signerTeamID == nil)
  #expect(app.partial)
  #expect(app.logical.completeTotal == nil)
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
    related: fixture.service, runningApplications: AppsRunning(value: false))
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
      related: fixture.service, runningApplications: AppsRunning(value: value))
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
    runningApplications: MutatingRunning(infoPath: fixture.app + "/Contents/Info.plist"))
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

@Test("Other exact-name data is visible as report-only, never inherited Trash authority")
func appOtherDataStaysReportOnly() async throws {
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
  #expect(app.related.first { $0.path == support }?.classification == .uncertain)
  #expect(app.related.first { $0.path == container }?.classification == .uncertain)
  #expect(app.related.first { $0.path == logs }?.reason == .recordUnsafe)
  for path in [support, container, logs] {
    let candidate = try #require(app.related.first { $0.path == path })
    #expect(throws: RelatedFailure.self) {
      try fixture.service.planInstalled(app: fixture.installedApp(), candidate: candidate)
    }
  }
}
