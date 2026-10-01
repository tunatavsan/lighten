import Darwin
import Foundation
import Synchronization
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
    case .session, .related, .ownershipReady: break
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

@Test(
  "Duplicate IDs refuse data while unrelated metadata stays scoped",
  arguments: ["missing", "malformed"])
func installedDataRequiresUniqueCompleteExactOwner(_ unknownMetadata: String) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let candidate = try await fixture.candidate()
  let app = try fixture.installedApp()
  let similar = fixture.home + "/Library/Caches/" + fixture.bundleID + "-similar"
  try FileManager.default.createDirectory(atPath: similar, withIntermediateDirectories: true)
  #expect((await fixture.service.discover()).first { $0.path == similar }?.classification == .uncertain)
  let sibling = fixture.appRoot + "/Sibling.app"
  try FileManager.default.copyItem(atPath: fixture.app, toPath: sibling)
  #expect(throws: RelatedFailure.ambiguousOwner) {
    try fixture.service.planInstalled(app: app, candidate: candidate)
  }
  try FileManager.default.removeItem(atPath: sibling)
  let bad = fixture.appRoot + "/Unknown.app"
  try FileManager.default.createDirectory(atPath: bad, withIntermediateDirectories: true)
  if unknownMetadata == "malformed" {
    try FileManager.default.createDirectory(atPath: bad + "/Contents", withIntermediateDirectories: true)
    try Data("malformed application metadata".utf8).write(to: URL(fileURLWithPath: bad + "/Contents/Info.plist"))
  }
  #expect(!fixture.service.inventory().complete)
  let plan = try fixture.service.planInstalled(app: app, candidate: candidate)
  #expect(plan.items.first?.installedRelatedProof?.appPath == fixture.app)
  #expect(fixture.service.prepareInstalledOwners(plan: plan).failures.isEmpty)
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

@Test("Linked apps resolve read-only; hidden app folders remain incomplete and dangling links contain no owner")
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
  #expect(fixture.service.inventory().complete)
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

@Test("Readable identifierless registry launchers and flat application metadata are observations, not I/O errors")
func registeredMetadataKindsRemainHonest() throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let launcher = fixture.home + "/External/LightenQA-launcher.app"
  let phone = fixture.home + "/External/LightenQA-phone.app"
  try FileManager.default.createDirectory(atPath: launcher + "/Contents", withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: phone, withIntermediateDirectories: true)
  try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Launcher"], format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: launcher + "/Contents/Info.plist"))
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "qa.lighten.phone", "CFBundleSupportedPlatforms": ["iPhoneOS"]],
    format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: phone + "/Info.plist"))
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    registration: { ApplicationRegistrationObservation(paths: [launcher, phone], complete: true) })
  let inventory = service.inventory()
  #expect(inventory.complete)
  #expect(inventory.unidentifiedPaths.contains(launcher))
  #expect(inventory.applications.contains { $0.path == phone && $0.bundleID == "qa.lighten.phone" })
  #expect(inventory.ownershipCandidates.contains { $0.path == launcher && $0.packagePath == launcher })
  #expect(inventory.ownershipIssues.isEmpty && inventory.metadataIssues.isEmpty)
  try Data("invalid plist".utf8).write(to: URL(fileURLWithPath: phone + "/Info.plist"))
  let unknown = service.inventory()
  #expect(!unknown.complete)
  #expect(unknown.metadataIssues.contains { $0.path == phone && $0.reason == "invalidInfoPlist" })
  #expect(!unknown.ownershipIssues.contains { $0.path == phone && $0.code == EIO })
  try FileManager.default.removeItem(atPath: phone + "/Info.plist")
  let missing = service.inventory()
  #expect(!missing.complete)
  #expect(missing.metadataIssues.contains { $0.path == phone && $0.reason == "missingInfoPlist" })
}

@Test("Unidentified applications never inherit nil-ID related observations")
func unidentifiedReportsHaveNoPhantomData() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let launcher = fixture.appRoot + "/LightenQA-launcher.app"
  let groupRoot = RelatedLocation.groupContainers.parent(homeDirectory: fixture.home)
  try FileManager.default.createDirectory(atPath: launcher + "/Contents", withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: groupRoot, withIntermediateDirectories: true)
  try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Launcher"], format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: launcher + "/Contents/Info.plist"))
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil })
  let session = ApplicationDiscovery(related: service).scanSession()
  var reports: [ApplicationReport] = []
  for await event in await session.events() {
    if case .completed(_, let final) = event { reports = final }
  }
  #expect(try #require(reports.first { $0.path == launcher }).related.isEmpty)
  #expect(try #require(reports.first { $0.path == fixture.app }).related.contains { $0.path == fixture.cache })
  let observed = await session.observedRelatedCandidates()
  #expect(observed.contains { $0.path == groupRoot && $0.bundleID == nil && $0.reason == .sharedGroup })
  await session.cancel()
}

@Test(
  "Only relevant installed-owner changes invalidate exact-ID decisions",
  arguments: ["data", "unrelated-ID", "second-owner-ID"])
func standardContextIgnoresUnrelatedOwnerChurn(_ change: String) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let other = fixture.appRoot + "/LightenQA-other.app"
  let mutable = fixture.home + "/Library/Application Support/LightenQA-data"
  try FileManager.default.createDirectory(atPath: other + "/Contents", withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: mutable, withIntermediateDirectories: true)
  func writeOther(_ id: String) throws {
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
      .write(to: URL(fileURLWithPath: other + "/Contents/Info.plist"))
  }
  try writeOther("qa.lighten.other")
  let walks = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot],
    ownershipApplicationRoots: [fixture.appRoot, mutable], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    ownershipCollected: { walks.withLock { $0 += 1 } })
  let context = service.makeContext()
  let app = try #require(service.application(at: fixture.app))
  let candidate = try #require((await service.discover(context: context)).first { $0.path == fixture.cache })
  if change == "data" {
    try Data("unrelated data".utf8).write(to: URL(fileURLWithPath: mutable + "/new-record"))
  } else {
    try writeOther(change == "second-owner-ID" ? fixture.bundleID : "qa.lighten.changed")
  }
  let available = await service.makeAvailableUninstallPlan(
    app: app, selectedRelated: [candidate], includePackage: false, context: context)
  if change == "second-owner-ID" {
    #expect(available.plan == nil && !available.rejections.isEmpty)
  } else {
    #expect(available.plan?.items.count == 1 && available.rejections.isEmpty)
    #expect(service.prepareInstalledOwners(plan: try #require(available.plan)).failures.isEmpty)
  }
  #expect(walks.withLock { $0 } == 1)
}

@Test("Cached owner metadata rechecks alternate native layouts and wrapper child membership")
func cachedMetadataRechecksLayoutStructure() throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let metadata = ApplicationContextMetadata()
  let service = fixture.service
  let reads = Mutex(0)
  func read() -> InstalledApplication? {
    reads.withLock { $0 += 1 }
    return service.application(at: fixture.app)
  }
  #expect(try metadata.application(at: fixture.app, registered: false, read: read)?.bundleID == fixture.bundleID)
  #expect(try metadata.application(at: fixture.app, registered: false, read: read)?.bundleID == fixture.bundleID)
  #expect(reads.withLock { $0 } == 1)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": fixture.bundleID], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: fixture.app + "/Info.plist"))
  #expect(throws: (any Error).self) { try metadata.application(at: fixture.app, registered: false, read: read) }
  try FileManager.default.removeItem(atPath: fixture.app + "/Info.plist")
  let original = try Data(contentsOf: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist"))
  try FileManager.default.removeItem(atPath: fixture.app + "/Contents")
  let inner = fixture.app + "/Wrapper/Inner.app"
  try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
  try original.write(to: URL(fileURLWithPath: inner + "/Info.plist"))
  #expect(try metadata.application(at: fixture.app, registered: false, read: read)?.bundleID == fixture.bundleID)
  #expect(try metadata.application(at: fixture.app, registered: false, read: read)?.bundleID == fixture.bundleID)
  #expect(reads.withLock { $0 } == 2)
  try FileManager.default.createDirectory(
    atPath: fixture.app + "/Wrapper/Another.app", withIntermediateDirectories: true)
  #expect(throws: (any Error).self) { try metadata.application(at: fixture.app, registered: false, read: read) }
}

@Test("Cached unrelated Info is reparsed when an in-place edit claims the selected ID")
func cachedSiblingMetadataCannotHideSecondOwner() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let sibling = fixture.appRoot + "/LightenQA-sibling.app"
  let info = sibling + "/Contents/Info.plist"
  let unrelatedID = String(fixture.bundleID.dropLast()) + (fixture.bundleID.hasSuffix("0") ? "1" : "0")
  func bytes(_ id: String) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
  }
  try FileManager.default.createDirectory(atPath: sibling + "/Contents", withIntermediateDirectories: true)
  try bytes(unrelatedID).write(to: URL(fileURLWithPath: info))
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let context = service.makeContext()
  let app = try #require(service.application(at: fixture.app))
  let candidate = try #require((await service.discover(context: context)).first { $0.path == fixture.cache })
  let selected = await service.makeAvailableUninstallPlan(
    app: app, selectedRelated: [candidate], includePackage: false, context: context)
  let plan = try #require(selected.plan)
  #expect(selected.rejections.isEmpty)
  #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
  #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
  let extraReads = Mutex(0)
  let reused = try context.metadata.application(at: sibling, registered: false) {
    extraReads.withLock { $0 += 1 }
    return service.application(at: sibling)
  }
  #expect(reused?.bundleID == unrelatedID && extraReads.withLock { $0 } == 0)
  var before = stat()
  #expect(lstat(info, &before) == 0)
  let replacement = try bytes(fixture.bundleID)
  #expect(replacement.count == (try Data(contentsOf: URL(fileURLWithPath: info))).count)
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: info))
  try handle.write(contentsOf: replacement)
  try handle.close()
  var times = [before.st_atimespec, before.st_mtimespec]
  #expect(utimensat(AT_FDCWD, info, &times, 0) == 0)
  let prepared = service.prepareInstalledOwners(plan: plan)
  #expect(prepared.owners.isEmpty && prepared.failures.values.contains("ambiguousOwner"))
  let reparsed = try context.metadata.application(at: sibling, registered: false) {
    extraReads.withLock { $0 += 1 }
    return service.application(at: sibling)
  }
  #expect(reparsed?.bundleID == fixture.bundleID && extraReads.withLock { $0 } == 0)
  let retry = await service.makeAvailableUninstallPlan(
    app: app, selectedRelated: [candidate], includePackage: false, context: context)
  #expect(retry.plan == nil && !retry.rejections.isEmpty)
}

@Test("Report-only absence retains the actual incomplete metadata cause")
func unknownOrphanReportsMetadataCause() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  try FileManager.default.removeItem(atPath: fixture.app)
  let unknown = fixture.home + "/External/" + fixture.bundleID + ".app"
  try FileManager.default.createDirectory(atPath: unknown + "/Contents", withIntermediateDirectories: true)
  try Data("malformed plist".utf8).write(to: URL(fileURLWithPath: unknown + "/Contents/Info.plist"))
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    registration: { ApplicationRegistrationObservation(paths: [unknown], complete: true) },
    registeredByID: { _ in ApplicationRegistrationObservation(paths: [], complete: true) })
  let context = service.makeContext()
  let candidate = try #require((await service.discover(context: context)).first { $0.path == fixture.cache })
  #expect(!candidate.canSelect && candidate.reason == .incompleteInventory)
  let refused = await service.availableOrphanPlan(candidate: candidate, context: context)
  #expect(refused.plan == nil)
  #expect(
    refused.rejections.contains {
      $0.path == fixture.cache && $0.ruleID?.contains("invalidInfoPlist: " + unknown) == true
    })
}

@Test("Mutable ownership data does not invalidate freshly checked orphan absence")
func orphanAbsenceIgnoresUnrelatedOwnerDirectories() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let mutable = fixture.home + "/Library/Application Support/LightenQA-data"
  try FileManager.default.createDirectory(atPath: mutable, withIntermediateDirectories: true)
  try FileManager.default.removeItem(atPath: fixture.app)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot],
    ownershipApplicationRoots: [fixture.appRoot, mutable], writeVerifiedReceipts: false, signingMetadata: { _ in nil })
  let context = service.makeContext()
  let candidate = try #require((await service.discover(context: context)).first { $0.path == fixture.cache })
  #expect(candidate.classification == .orphanVerified)
  try Data("new unrelated data".utf8).write(to: URL(fileURLWithPath: mutable + "/record"))
  let available = await service.availableOrphanPlan(candidate: candidate, context: context)
  #expect(available.plan?.items.count == 1 && available.rejections.isEmpty)
}

@Test(
  "Unknown metadata blocks its registered ID while unrelated absence remains scoped",
  arguments: [false, true])
func orphanAbsenceUsesRelevantRegisteredMetadata(relevant: Bool) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  try FileManager.default.removeItem(atPath: fixture.app)
  let external = fixture.home + "/External/LightenQA-unreadable.app"
  try FileManager.default.createDirectory(atPath: external + "/Contents", withIntermediateDirectories: true)
  try Data("invalid metadata".utf8).write(to: URL(fileURLWithPath: external + "/Contents/Info.plist"))
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    registration: { ApplicationRegistrationObservation(paths: [external], complete: true) },
    registeredByID: { _ in ApplicationRegistrationObservation(paths: relevant ? [external] : [], complete: true) })
  let context = service.makeContext()
  #expect(!context.inventory.complete)
  #expect(context.inventory.metadataIssues.contains { $0.path == external })
  #expect(context.inventory.ownershipCandidates.contains { $0.path == external })
  let candidate = try #require((await service.discover(context: context)).first { $0.path == fixture.cache })
  let outcome = await service.availableOrphanPlan(candidate: candidate, context: context)
  if relevant {
    #expect(candidate.classification == .uncertain && candidate.reason == .incompleteInventory)
    #expect(outcome.plan == nil && !outcome.rejections.isEmpty)
    #expect(candidate.refusalEvidence.contains { $0.reason == .unknownMetadata && $0.ownerPaths == [external] })
  } else {
    #expect(candidate.classification == .orphanVerified && candidate.canSelect)
    let plan = try #require(outcome.plan)
    #expect(outcome.rejections.isEmpty)
    try service.validateOrphan(plan.items[0], plan: plan)
  }
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

@Test("A discovery session shares one owner inventory across discovery, reviews, plan and preparation")
func oneInventoryAcrossSession() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let walks = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    ownershipCollected: { walks.withLock { $0 += 1 } })
  let session = ApplicationDiscovery(related: service).scanSession()
  var completed: [ApplicationReport] = []
  var sawSession = false
  for await event in await session.events() {
    if case .session(let emitted) = event { sawSession = emitted.id == session.id }
    if case .completed(_, let reports) = event { completed = reports }
  }
  #expect(sawSession)
  #expect(walks.withLock { $0 } == 1)
  let app = try #require(service.application(at: fixture.app))
  let candidate = try #require(completed.first { $0.path == fixture.app }?.related.first { $0.path == fixture.cache })
  for _ in 0..<2 {
    let review = try await session.relatedReview(path: app.path)
    #expect(review?.application == app)
    #expect(review?.candidates.first { $0.path == fixture.cache }?.defaultSelected == true)
  }
  let available = await session.makeAvailableUninstallPlan(app: app, selectedRelated: [candidate])
  let plan = try #require(available.plan)
  #expect(available.rejections.isEmpty)
  #expect(await session.validatePlan(plan).isEmpty)
  let prepared = service.prepareInstalledOwners(plan: plan)
  #expect(prepared.failures.isEmpty && prepared.owners.count == 1)
  #expect(walks.withLock { $0 } == 1)
  await session.cancel()
  // Cancelling a scan invalidates future requests, not a concrete plan which
  // retains its exact proof and fresh validation requirements.
  #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
  #expect(walks.withLock { $0 } == 1)
  #expect((await session.makeAvailableUninstallPlan(app: app, selectedRelated: [])).plan == nil)
}

@Test("Unsigned package-only preparation never builds an owner inventory")
func packageOnlyNeedsNoOwnershipWalk() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let walks = Mutex(0)
  let signatures = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in
      signatures.withLock { $0 += 1 }
      return nil
    },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    ownershipCollected: { walks.withLock { $0 += 1 } })
  let app = try #require(service.application(at: fixture.app))
  let session = ApplicationDiscovery(related: service).scanSession()
  let available = await session.makeAvailableUninstallPlan(app: app, selectedRelated: [])
  let plan = try #require(available.plan)
  #expect(available.rejections.isEmpty && plan.items.map(\.sourcePath) == [fixture.app])
  #expect(service.prepareInstalledOwners(plan: plan).owners.isEmpty)
  #expect(await session.validatePlan(plan).isEmpty)
  #expect(try service.planUninstall(app: app, selectedRelated: []).items.count == 1)
  #expect(walks.withLock { $0 } == 0 && signatures.withLock { $0 } == 0)
  await session.cancel()
}

private func ownershipWalkStarted(_ signal: DispatchSemaphore) -> Bool {
  signal.wait(timeout: .now() + 2) == .success
}

@Test("Selected standard data is published while the background owner walk is stalled")
func selectedReviewPrecedesOwnership() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let started = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    ownershipCollected: {
      started.signal()
      _ = release.wait(timeout: .now() + 5)
    })
  let session = ApplicationDiscovery(related: service).scanSession()
  let observed = Task { for await _ in await session.events() {} }
  // The semaphore is a test-only stall; no elapsed-time product claim is made.
  let didStart = await Task.detached { ownershipWalkStarted(started) }.value
  #expect(didStart)
  defer { release.signal() }
  let callbacks = Mutex<[ApplicationRelatedReview]>([])
  let review = try await session.relatedReview(path: fixture.app) { value in
    callbacks.withLock { $0.append(value) }
  }
  #expect(review?.ownershipPending == true)
  #expect(review?.candidates.first { $0.path == fixture.cache }?.defaultSelected == true)
  #expect(callbacks.withLock { !$0.isEmpty && $0.allSatisfy(\.ownershipPending) })
  let app = try #require(service.application(at: fixture.app))
  let candidate = try #require(review?.candidates.first { $0.path == fixture.cache })
  let available = await session.makeAvailableUninstallPlan(app: app, selectedRelated: [candidate])
  let plan = try #require(available.plan)
  #expect(available.rejections.isEmpty)
  #expect(await session.validatePlan(plan).isEmpty)
  release.signal()
  await observed.value
  await session.cancel()
}

@Test(
  "Current owner metadata, installation roots and registered lineage invalidate a session",
  arguments: ["info", "install", "registration"])
func sessionRefusesChangedOwnerUniverse(_ change: String) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let external = fixture.home + "/External/LightenQA-registered.app"
  try FileManager.default.createDirectory(
    atPath: (external as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try FileManager.default.copyItem(atPath: fixture.app, toPath: external)
  let registered = Mutex<[String]>([])
  let walks = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    registration: { ApplicationRegistrationObservation(paths: registered.withLock { $0 }, complete: true) },
    ownershipCollected: { walks.withLock { $0 += 1 } })
  let session = ApplicationDiscovery(related: service).scanSession()
  var candidate: RelatedDataCandidate?
  for await event in await session.events() {
    if case .completed(_, let reports) = event {
      candidate = reports.first { $0.path == fixture.app }?.related.first { $0.path == fixture.cache }
    }
  }
  let app = try #require(service.application(at: fixture.app))
  let chosen = try #require(candidate)
  switch change {
  case "info": try fixture.writeInfo()
  case "install": try FileManager.default.copyItem(atPath: fixture.app, toPath: fixture.appRoot + "/LightenQA-new.app")
  default: registered.withLock { $0 = [external] }
  }
  let available = await session.makeAvailableUninstallPlan(app: app, selectedRelated: [chosen], includePackage: false)
  #expect(available.plan == nil && !available.rejections.isEmpty)
  #expect(walks.withLock { $0 } == 1)
  await session.cancel()
}

@Test("Registry leads require current no-follow bundle metadata and extend installed listing")
func registrationLeadsHaveFreshMetadata() throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let external = fixture.home + "/External/LightenQA-registered.app"
  try FileManager.default.createDirectory(
    atPath: (external as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try FileManager.default.copyItem(atPath: fixture.app, toPath: external)
  let link = fixture.home + "/LightenQA-unsafe.app"
  #expect(symlink(external, link) == 0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    registration: {
      ApplicationRegistrationObservation(
        paths: [external, link, fixture.home + "/LightenQA-missing.app"], complete: true)
    })
  let inventory = service.inventory()
  #expect(inventory.applications.contains { $0.path == external && $0.bundleID == fixture.bundleID })
  #expect(!inventory.applications.contains { $0.path == link })
  #expect(inventory.complete)
  #expect(inventory.ownershipCandidates.contains { $0.path == external && $0.packagePath == external })
  let parsed = ApplicationRegistration.parseDump("bundle: 1\n  path: " + external + "\n  path: " + external + "\n")
  #expect(parsed.complete && parsed.paths == [external])
  #expect(!ApplicationRegistration.parseDump("path: relative/Unsafe.app\n").complete)
  #expect(!ApplicationRegistration.parseDump("no recognized records\n").complete)
}

@Test("Registry dump annotations preserve spaces and app-name parentheses while folding helpers into their package")
func registryDumpUsesActualPathGrammar() {
  let path = "/Applications/LightenQA Example (GPU).app"
  let nested = path + "/Contents/Frameworks/LightenQA Helper (GPU).app"
  let observation = ApplicationRegistration.parseDump(
    "path: " + path + " (0x2970)\npath: " + nested + " (0xA9f0)\n")
  #expect(observation.complete && observation.paths == [path])
  #expect(!ApplicationRegistration.parseDump("path: " + path + " (0xZZ)\n").complete)
  #expect(!ApplicationRegistration.parseDump("path: " + path + " (0x)\n").complete)
  #expect(!ApplicationRegistration.parseDump("path: " + path + " (0x123\n").complete)
  #expect(
    ApplicationRegistration.parseDump("path: /Applications/LightenQA (0x123).app (0xf)\n").paths
      == ["/Applications/LightenQA (0x123).app"])
  #expect(
    ApplicationRegistration.parseDump("path: " + NSHomeDirectory() + "/.Trash/LightenQA.app (0x1)\n").paths.isEmpty)
  #expect(
    ApplicationRegistration.parseDump(
      "path: /System/Volumes/Data" + NSHomeDirectory() + "/.Trash/LightenQA.app (0x1)\n"
    ).paths.isEmpty)
}

@Test("A session retains uncertain unmatched rows without a second related discovery")
func allRelatedRowsKeepUncertainDenominator() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let unmatched = fixture.home + "/Library/Caches/com.apple.LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: unmatched, withIntermediateDirectories: true)
  let walks = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    ownershipCollected: { walks.withLock { $0 += 1 } })
  let session = ApplicationDiscovery(related: service).scanSession()
  var orphanPaths: [String] = []
  for await event in await session.events() {
    if case .orphans(let rows) = event { orphanPaths = rows.map(\.path) }
  }
  let all = await session.observedRelatedCandidates()
  #expect(all.contains { $0.path == unmatched && $0.classification == .uncertain })
  #expect(!orphanPaths.contains(unmatched))
  #expect((await session.observedRelatedCandidates()).map(\.path) == all.map(\.path))
  #expect(walks.withLock { $0 } == 1)
  await session.cancel()
}

@Test("Dry validation rechecks native activity and refuses unrelated plan scope without an owner walk")
func dryValidationUsesFreshActivityAndScope() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let activity = Mutex(ApplicationActivity(state: .clearObservedProcesses))
  let walks = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    packageActivity: { _ in activity.withLock { $0 } },
    ownershipCollected: { walks.withLock { $0 += 1 } })
  let app = try #require(service.application(at: fixture.app))
  let session = ApplicationDiscovery(related: service).scanSession()
  let available = await session.makeAvailableUninstallPlan(app: app, selectedRelated: [])
  let plan = try #require(available.plan)
  activity.withLock { $0 = ApplicationActivity(state: .active, processNames: ["LightenQA-helper"]) }
  let refusals = await session.validatePlan(plan)
  #expect(
    refusals.contains { $0.path == fixture.app && $0.reason == .processActive && $0.ruleID == "LightenQA-helper" })
  activity.withLock { $0 = ApplicationActivity(state: .clearObservedProcesses) }
  let original = try #require(plan.items.first)
  let foreign = PlanItem(
    id: original.id, sourcePath: fixture.cache, volumeID: original.volumeID,
    inventory: original.inventory, ancestors: original.ancestors, policy: .spaceTrash)
  let unrelated = ActionPlan(snapshotRunID: plan.snapshotRunID, kind: .trash, items: [foreign])
  #expect((await session.validatePlan(unrelated)).contains { $0.path == fixture.cache && $0.ruleID == "invalid-scope" })
  #expect(walks.withLock { $0 } == 0)
  await session.cancel()
}

@Test("A fresh registered second owner vetoes an exact-ID standard plan before any ownership walk")
func scopedStandardChecksRegisteredSecondOwner() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let second = fixture.home + "/External/LightenQA-second.app"
  try FileManager.default.createDirectory(
    atPath: (second as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try FileManager.default.copyItem(atPath: fixture.app, toPath: second)
  let walks = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    registeredByID: { _ in ApplicationRegistrationObservation(paths: [second], complete: true) },
    ownershipCollected: { walks.withLock { $0 += 1 } })
  let app = try #require(service.application(at: fixture.app))
  let review = await service.initialReview(for: app, progress: nil)
  let candidate = try #require(review.candidates.first { $0.path == fixture.cache })
  let session = ApplicationDiscovery(related: service).scanSession()
  let available = await session.makeAvailableUninstallPlan(
    app: app, selectedRelated: [candidate], includePackage: false)
  #expect(available.plan == nil && !available.rejections.isEmpty)
  #expect(walks.withLock { $0 } == 0)
  await session.cancel()
}

@Test("A private standard scope cannot authorize a forged group or team-prefixed selection")
func scopedStandardCannotGrantMixedAuthority() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: ["group.qa.lighten.fake"]) },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let app = try #require(service.application(at: fixture.app))
  let review = await service.initialReview(for: app, progress: nil)
  let candidate = try #require(review.candidates.first { $0.path == fixture.cache })
  let context = service.makeStandardContext(app: app, listing: service.installedListing())
  #expect(!context.inventory.ownershipComplete)
  for location in [RelatedLocation.caches, .groupContainers] {
    let path = location.path(
      domain: location == .caches ? "TEAM." + app.bundleID : "group.qa.lighten.fake", homeDirectory: fixture.home)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let forged = RelatedDataCandidate(
      id: path, path: path, classification: .installed, reason: .installed,
      snapshot: candidate.snapshot, receipt: nil, bundleID: app.bundleID)
    let outcome = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [candidate, forged], includePackage: false, context: context)
    #expect(!outcome.rejections.isEmpty)
    #expect(outcome.plan?.items.allSatisfy { $0.sourcePath == candidate.path } != false)
  }
}

private func writeSessionReceipt(fixture: AppsFixture) throws -> String {
  let identity = try DescriptorFileSystem.identity(at: fixture.cache)
  let receipt = RelatedReceipt(
    schema: 1, bundleID: fixture.bundleID, appPath: fixture.app, relatedPath: fixture.cache,
    identity: identity, observedAt: Date(), ruleSource: "exact-standard-domain-v1")
  let path = fixture.home + "/Library/Application Support/com.tavsn.lighten/related-receipts.json"
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try JSONEncoder().encode([receipt]).write(to: URL(fileURLWithPath: path))
  #expect(chmod(path, 0o600) == 0)
  return path
}

@Test("Leftover plans and dry validation reuse one session universe", arguments: [false, true])
func sessionAbsenceUsesOneUniverse(_ historical: Bool) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let receiptPath = historical ? try writeSessionReceipt(fixture: fixture) : nil
  try FileManager.default.removeItem(atPath: fixture.app)
  let walks = Mutex(0)
  let dumps = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    registration: {
      dumps.withLock { $0 += 1 }
      return ApplicationRegistrationObservation(paths: [], complete: true)
    }, registeredByID: { _ in ApplicationRegistrationObservation(paths: [], complete: true) },
    ownershipCollected: { walks.withLock { $0 += 1 } })
  let session = ApplicationDiscovery(related: service).scanSession()
  let candidate = try #require((await session.observedRelatedCandidates()).first { $0.path == fixture.cache })
  #expect(candidate.classification == (historical ? .historicallyVerifiedAbsent : .orphanVerified))
  for _ in 0..<3 {
    let outcome = await session.plan(candidate: candidate)
    let plan = try #require(outcome.plan)
    #expect(outcome.rejections.isEmpty)
    #expect((await session.validatePlan(plan)).isEmpty)
    #expect(plan.items.first?.installedRelatedProof == nil)
    #expect((plan.items.first?.relatedProof != nil) == historical)
    #expect((plan.items.first?.orphanRelatedProof != nil) != historical)
  }
  #expect(walks.withLock { $0 } == 1 && dumps.withLock { $0 } == 1)
  if let receiptPath {
    let outcome = await session.plan(candidate: candidate)
    let plan = try #require(outcome.plan)
    try FileManager.default.removeItem(atPath: receiptPath)
    #expect(!(await session.validatePlan(plan)).isEmpty)
    #expect((await session.plan(candidate: candidate)).plan == nil)
    #expect(walks.withLock { $0 } == 1 && dumps.withLock { $0 } == 1)
  }
  await session.cancel()
}

@Test("Fresh per-ID registration refuses owner absence without another global walk", arguments: [false, true])
func sessionAbsenceRefreshesRegistration(_ unknown: Bool) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let external = fixture.home + "/External/LightenQA-returned.app"
  try FileManager.default.createDirectory(
    atPath: (external as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try FileManager.default.copyItem(atPath: fixture.app, toPath: external)
  try FileManager.default.removeItem(atPath: fixture.app)
  let registration = Mutex(ApplicationRegistrationObservation(paths: [], complete: true))
  let walks = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    registeredByID: { _ in registration.withLock { $0 } },
    ownershipCollected: { walks.withLock { $0 += 1 } })
  let session = ApplicationDiscovery(related: service).scanSession()
  let candidate = try #require((await session.observedRelatedCandidates()).first { $0.path == fixture.cache })
  let plan = try #require((await session.plan(candidate: candidate)).plan)
  #expect((await session.validatePlan(plan)).isEmpty)
  registration.withLock {
    $0 = ApplicationRegistrationObservation(paths: unknown ? [] : [external], complete: !unknown)
  }
  let expected = unknown ? "incompleteInventory" : "ownerPresent"
  let refused = await session.plan(candidate: candidate)
  #expect(refused.plan == nil && refused.rejections.contains { $0.ruleID == expected })
  let dry = await session.validatePlan(plan)
  #expect(dry.contains { $0.ruleID == expected && $0.path == fixture.cache })
  #expect(walks.withLock { $0 } == 1)
  await session.cancel()
}

@Test("A selected standard context cannot grant an unrelated orphan's absence")
func standardContextCannotGrantAbsence() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let path = RelatedLocation.caches.path(domain: "qa.lighten.absent", homeDirectory: fixture.home)
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let app = try #require(service.application(at: fixture.app))
  let orphan = try #require((await service.discover()).first { $0.path == path })
  #expect(orphan.classification == .orphanVerified && orphan.canSelect)
  let selected = service.makeStandardContext(app: app, listing: service.installedListing())
  let outcome = await service.availableOrphanPlan(candidate: orphan, context: selected)
  #expect(outcome.plan == nil && outcome.rejections.contains { $0.ruleID == "unsupportedInstalledData" })
}

@Test("Historical rows cannot silently become orphan proofs or authorize unsafe rows")
func sessionLeftoverProofKindsStayDistinct() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  try FileManager.default.removeItem(atPath: fixture.app)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false)
  let session = ApplicationDiscovery(related: service).scanSession()
  let orphan = try #require((await session.observedRelatedCandidates()).first { $0.path == fixture.cache })
  for classification in [RelatedClassification.historicallyVerifiedAbsent, .shared, .protected, .uncertain] {
    let forged = RelatedDataCandidate(
      id: orphan.id, path: orphan.path, classification: classification, reason: orphan.reason,
      snapshot: orphan.snapshot, receipt: nil, bundleID: orphan.bundleID)
    let outcome = await session.plan(candidate: forged)
    #expect(outcome.plan == nil && outcome.rejections.contains { $0.ruleID == "invalidReceipt" })
  }
  let unavailable = RelatedDataCandidate(
    id: orphan.id, path: orphan.path, classification: .uncertain, reason: .recordUnavailable,
    snapshot: nil, receipt: nil, bundleID: orphan.bundleID)
  let reported = await session.plan(candidate: unavailable)
  #expect(reported.plan == nil && reported.rejections.contains { $0.ruleID == "recordUnavailable" })
  await session.cancel()
}

@Test("Leftover dry validation checks nested executable activity freshly")
func sessionLeftoverNativeActivityIsFresh() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let nested = fixture.cache + "/LightenQA-nested.app"
  try FileManager.default.copyItem(atPath: fixture.app, toPath: nested)
  try FileManager.default.removeItem(atPath: fixture.app)
  let activity = Mutex(ApplicationActivity(state: .clearObservedProcesses))
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    packageActivity: { _ in activity.withLock { $0 } })
  let session = ApplicationDiscovery(related: service).scanSession()
  let candidate = try #require((await session.observedRelatedCandidates()).first { $0.path == fixture.cache })
  let plan = try #require((await session.plan(candidate: candidate)).plan)
  #expect((await session.validatePlan(plan)).isEmpty)
  activity.withLock { $0 = ApplicationActivity(state: .active, processNames: ["LightenQA-helper"]) }
  let active = await session.validatePlan(plan)
  #expect(active.contains { $0.reason == .processActive && $0.ruleID == "LightenQA-helper" })
  activity.withLock { $0 = ApplicationActivity(state: .unknown) }
  #expect((await session.validatePlan(plan)).contains { $0.reason == .activityUnavailable })
  await session.cancel()
}

private enum PublicPackageLayout: String, CaseIterable, Sendable {
  case contents, flat, wrapper
}

private func publicPackageInfo(app: String, layout: PublicPackageLayout, identifier: String?) throws -> String {
  let relative: String
  switch layout {
  case .contents: relative = "Contents/Info.plist"
  case .flat:
    try FileManager.default.removeItem(atPath: app + "/Contents/Info.plist")
    try FileManager.default.moveItem(atPath: app + "/Contents", toPath: app + "/Payload")
    relative = "Info.plist"
  case .wrapper:
    try FileManager.default.removeItem(atPath: app + "/Contents/Info.plist")
    let inner = "Wrapper/LightenQA-" + UUID().uuidString + ".app"
    try FileManager.default.createDirectory(atPath: app + "/" + inner, withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: app + "/Contents", toPath: app + "/" + inner + "/Contents")
    relative = inner + "/Info.plist"
  }
  var dictionary: [String: String] = ["CFBundleVersion": "LightenQA-1"]
  if let identifier { dictionary["CFBundleIdentifier"] = identifier }
  try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: app + "/" + relative))
  return relative
}

@Test(
  "Public service and session plans bind and measure each native application layout",
  arguments: PublicPackageLayout.allCases)
private func publicUninstallBindsNativeLayout(layout: PublicPackageLayout) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let relative = try publicPackageInfo(app: fixture.app, layout: layout, identifier: fixture.bundleID)
  let service = fixture.service
  let app = try #require(service.application(at: fixture.app))
  let candidate = try #require(
    (await service.initialReview(for: app, progress: nil)).candidates.first { $0.path == fixture.cache })
  let session = ApplicationDiscovery(related: service).scanSession()
  defer { Task { await session.cancel() } }
  let available = await session.makeAvailableUninstallPlan(
    path: fixture.app, expectedBundleID: fixture.bundleID, selectedRelated: [candidate], includePackage: true)
  let plan = try #require(available.plan)
  #expect(available.rejections.isEmpty)
  #expect(Set(plan.items.map(\.sourcePath)) == [fixture.app, fixture.cache])
  let package = try #require(plan.items.first { $0.policy == .wholeBundle })
  #expect(package.applicationPackageObservation?.infoRelativePath == relative)
  #expect(package.observedSize?.logical?.knownLowerBound ?? 0 > 0)
  #expect(package.observedSize?.allocated?.knownLowerBound ?? 0 > 0)
  let data = try #require(plan.items.first { $0.installedRelatedProof != nil })
  #expect(
    data.installedRelatedProof?.infoIdentity == (try DescriptorFileSystem.identity(at: fixture.app + "/" + relative)))
  #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
  #expect(await session.validatePlan(plan) == [])
  let compatible = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [candidate])
  #expect(compatible.rejections.isEmpty && compatible.plan?.items.count == 2)
  #expect(compatible.plan?.items.first { $0.policy == .wholeBundle }?.observedSize?.logical?.knownLowerBound ?? 0 > 0)
  let replacement = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": fixture.bundleID, "CFBundleVersion": "LightenQA-changed"],
    format: .xml, options: 0)
  try replacement.write(to: URL(fileURLWithPath: fixture.app + "/" + relative))
  #expect(!service.prepareInstalledOwners(plan: plan).failures.isEmpty)
  #expect(!(await session.validatePlan(plan)).isEmpty)
}

@Test(
  "Identifierless public plans keep the measured package and name every unmatched related request",
  arguments: PublicPackageLayout.allCases)
private func identifierlessPublicPlanHasNoRelatedAuthority(layout: PublicPackageLayout) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let activity = Mutex(ApplicationActivity(state: .clearObservedProcesses))
  let walks = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    packageActivity: { _ in activity.withLock { $0 } }, ownershipCollected: { walks.withLock { $0 += 1 } })
  let original = try #require(service.application(at: fixture.app))
  let candidate = try #require(
    (await service.initialReview(for: original, progress: nil)).candidates.first { $0.path == fixture.cache })
  #expect(candidate.canSelect)
  let relative = try publicPackageInfo(app: fixture.app, layout: layout, identifier: nil)
  #expect(service.application(at: fixture.app) == nil)
  #expect(ApplicationIdentity.bundleIdentifier(ofApplicationAt: fixture.app) == nil)
  let discovery = ApplicationDiscovery(related: service)
  let report = try #require(await discovery.report(path: fixture.app))
  #expect(report.bundleID == nil && report.related.isEmpty)
  #expect(report.logical.knownLowerBound > 0 && !report.partial)
  #expect(report.isIOSWrapper == (layout == .wrapper))
  let session = discovery.scanSession()
  defer { Task { await session.cancel() } }
  let available = await session.makeAvailableUninstallPlan(
    path: fixture.app, expectedBundleID: nil, selectedRelated: [candidate], includePackage: true)
  let plan = try #require(available.plan)
  #expect(plan.items.count == 1 && plan.items[0].sourcePath == fixture.app)
  #expect(plan.items[0].applicationBundleID == nil && plan.items[0].installedRelatedProof == nil)
  #expect(plan.items[0].applicationPackageObservation?.infoRelativePath == relative)
  #expect(plan.items[0].observedSize?.logical?.knownLowerBound ?? 0 > 0)
  #expect(available.rejections.count == 1)
  #expect(
    available.rejections[0].path == fixture.cache && available.rejections[0].ruleID == "application-identifier-absent")
  #expect(walks.withLock { $0 } == 0)
  #expect(await session.validatePlan(plan) == [])
  let dataOnly = await service.makeAvailableUninstallPlan(
    path: fixture.app, expectedBundleID: nil, selectedRelated: [candidate], includePackage: false)
  #expect(dataOnly.plan == nil && dataOnly.rejections.count == 1)
  let staleID = await service.makeAvailableUninstallPlan(
    path: fixture.app, expectedBundleID: fixture.bundleID, selectedRelated: [], includePackage: true)
  #expect(staleID.plan == nil && staleID.rejections.contains { $0.reason == .changedSinceScan })
  activity.withLock { $0 = ApplicationActivity(state: .unknown) }
  #expect((await session.validatePlan(plan)).contains { $0.path == fixture.app && $0.reason == .activityUnavailable })
  activity.withLock { $0 = ApplicationActivity(state: .clearObservedProcesses) }
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": fixture.bundleID], format: .xml, options: 0
  )
  .write(to: URL(fileURLWithPath: fixture.app + "/" + relative))
  #expect(!(await session.validatePlan(plan)).isEmpty)
}

@Test("Public linked plans bind data to the physical app and recheck the same-plan leaf", arguments: [false, true])
private func publicLinkedUninstallUsesPhysicalOwner(relative: Bool) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let physical = fixture.home + "/Shared/LightenQA-physical.app"
  try FileManager.default.createDirectory(atPath: fixture.home + "/Shared", withIntermediateDirectories: true)
  try FileManager.default.moveItem(atPath: fixture.app, toPath: physical)
  #expect(symlink(relative ? "../Shared/LightenQA-physical.app" : physical, fixture.app) == 0)
  let activities = Mutex<[String]>([])
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    packageActivity: { path in
      activities.withLock { $0.append(path) }
      return ApplicationActivity(state: .clearObservedProcesses)
    })
  let observed = try #require(service.application(at: fixture.app))
  #expect(observed.linkTarget == physical && observed.bundleID == fixture.bundleID)
  let candidate = try #require(
    (await service.initialReview(for: observed, progress: nil)).candidates.first { $0.path == fixture.cache })
  let report = try #require(await ApplicationDiscovery(related: service).report(path: fixture.app))
  #expect(report.linkTarget == physical && report.logical.knownLowerBound > 0)
  let session = ApplicationDiscovery(related: service).scanSession()
  defer { Task { await session.cancel() } }
  let available = await session.makeAvailableUninstallPlan(
    path: fixture.app, expectedBundleID: fixture.bundleID, selectedRelated: [candidate], includePackage: true)
  let plan = try #require(available.plan)
  #expect(available.rejections.isEmpty && plan.items.count == 3)
  let package = try #require(plan.items.first { $0.policy == .wholeBundle })
  let leaf = try #require(plan.items.first { $0.policy == .applicationLink })
  let data = try #require(plan.items.first { $0.installedRelatedProof != nil })
  #expect(package.sourcePath == physical && leaf.sourcePath == fixture.app)
  #expect(leaf.packageLinkTargetItemID == package.id && data.installedRelatedProof?.appPath == physical)
  #expect(activities.withLock { !$0.isEmpty && $0.allSatisfy { $0 == physical } })
  #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
  #expect(await session.validatePlan(plan) == [])
  #expect(throws: (any Error).self) { try ActionGuard(homeDirectory: fixture.home).validate(leaf) }
  let other = fixture.home + "/Shared/LightenQA-other.app"
  try FileManager.default.copyItem(atPath: physical, toPath: other)
  #expect(unlink(fixture.app) == 0 && symlink(other, fixture.app) == 0)
  let refused = await session.validatePlan(plan)
  #expect(refused.contains { $0.path == fixture.app })
  #expect(refused.contains { $0.path == physical })
  #expect(refused.contains { $0.path == fixture.cache })
  #expect(FileManager.default.fileExists(atPath: physical) && FileManager.default.fileExists(atPath: other))
}

@Test("Exact simulator-device exclusions survive inventory, owner enrichment and completion")
private func simulatorScopeObservationsSurviveDiscovery() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let device = fixture.home + "/Library/Developer/CoreSimulator/Devices/" + UUID().uuidString
  let installation = device + "/data/Containers/Bundle/Application/" + UUID().uuidString
  let simulator = installation + "/LightenQA-device.app"
  let daemon = fixture.home + "/Library/DaemonContainers/LightenQA-daemon.app"
  let ordinary = fixture.home + "/Library/Developer/CoreSimulator/LightenQA-Mac.app"
  for path in [simulator, daemon, ordinary] {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: fixture.app, toPath: path)
  }
  let alias = fixture.appRoot + "/LightenQA-device-alias.app"
  #expect(symlink(simulator, alias) == 0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot, installation], writeVerifiedReceipts: false,
    registration: { ApplicationRegistrationObservation(paths: [simulator, daemon, ordinary], complete: true) })
  let session = ApplicationDiscovery(related: service).scanSession()
  var seen: [BundleInventory] = []
  var reports: [ApplicationReport] = []
  for await event in await session.events() {
    switch event {
    case .inventory(let inventory, _), .ownershipReady(let inventory): seen.append(inventory)
    case .completed(let inventory, let final):
      seen.append(inventory)
      reports = final
    default: break
    }
  }
  #expect(seen.count == 3)
  for inventory in seen {
    #expect(Set(inventory.scopeExclusions.map(\.path)) == [simulator, alias])
    #expect(
      inventory.scopeExclusions.allSatisfy {
        $0.bundleID == fixture.bundleID && $0.reason == "simulator-device-application" && !$0.nextStep.isEmpty
      })
    #expect(!inventory.applications.contains { $0.path == simulator || $0.path == alias })
    #expect(!inventory.unidentifiedPaths.contains(simulator) && !inventory.unidentifiedPaths.contains(alias))
  }
  #expect(reports.contains { $0.path == daemon } && reports.contains { $0.path == ordinary })
  #expect(!reports.contains { $0.path == simulator || $0.path == alias })
  let final = try #require(seen.last)
  #expect(final.ownershipCandidates.contains { $0.path == simulator })
  #expect(final.applicationMetadata.contains { $0.path == simulator })
  #expect(!RelatedDataService.isSimulatorDeviceApplication(daemon, homeDirectory: fixture.home))
  #expect(!RelatedDataService.isSimulatorDeviceApplication(ordinary, homeDirectory: fixture.home))
  let discovery = ApplicationDiscovery(related: service)
  #expect(await discovery.report(path: simulator) == nil)
  let refused = await service.makeAvailableUninstallPlan(
    path: alias, expectedBundleID: fixture.bundleID, selectedRelated: [], includePackage: true)
  #expect(refused.plan == nil && refused.rejections.contains { $0.ruleID == "simulator-device-application" })
  await session.cancel()
}
