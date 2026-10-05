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

private actor RelatedMeasurementGate {
  private var pending: [CheckedContinuation<ApplicationDiscovery.Measurement, Never>] = []
  private var arrival: CheckedContinuation<Void, Never>?
  private var released = false
  func measure() async -> ApplicationDiscovery.Measurement {
    if released {
      return (
        ByteAggregate(knownLowerBound: 0, completeTotal: 0), ByteAggregate(knownLowerBound: 0, completeTotal: 0), 0,
        false
      )
    }
    return await withCheckedContinuation { continuation in
      pending.append(continuation)
      arrival?.resume()
      arrival = nil
    }
  }
  func waitUntilStarted() async {
    if !pending.isEmpty { return }
    await withCheckedContinuation { arrival = $0 }
  }
  func release() {
    released = true
    for continuation in pending {
      continuation.resume(
        returning: (
          ByteAggregate(knownLowerBound: 0, completeTotal: 0), ByteAggregate(knownLowerBound: 0, completeTotal: 0), 0,
          false
        ))
    }
    pending.removeAll()
  }
}

@Test("Complete shallow associations are visible before stalled sizes, signatures, or process evidence")
func selectedShallowListPrecedesMeasurement() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let support = fixture.home + "/Library/Application Support/Fixture2"
  let crash = fixture.home + "/Library/Application Support/CrashReporter/Fixture_" + UUID().uuidString + ".plist"
  let recent =
    fixture.home
    + "/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/"
    + fixture.bundleID + ".sfl4"
  for path in [support, (crash as NSString).deletingLastPathComponent, (recent as NSString).deletingLastPathComponent] {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }
  try Data().write(to: URL(fileURLWithPath: crash))
  try Data().write(to: URL(fileURLWithPath: recent))
  let signingReads = Mutex(0)
  let liveReads = Mutex(0)
  let shallowReads = Mutex<(signing: Int, live: Int)?>(nil)
  let gate = RelatedMeasurementGate()
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in
      signingReads.withLock { $0 += 1 }
      return nil
    },
    liveData: {
      liveReads.withLock { $0 += 1 }
      return ApplicationLiveDataObservation(records: [], complete: true)
    },
    relatedMeasurement: { _, _ in await gate.measure() })
  let app = try #require(service.application(at: fixture.app))
  let updates = AsyncStream<ApplicationRelatedReview>.makeStream()
  let finished = Mutex(false)
  let review = Task {
    let result = await service.initialReview(for: app) { update in
      if update.phase == .shallow {
        let signing = signingReads.withLock { $0 }
        let live = liveReads.withLock { $0 }
        shallowReads.withLock { $0 = (signing, live) }
      }
      updates.continuation.yield(update)
    }
    finished.withLock { $0 = true }
    return result
  }
  defer { Task { await gate.release() } }
  var iterator = updates.stream.makeAsyncIterator()
  let shallow = try #require(await iterator.next())
  #expect(shallow.phase == .shallow)
  let countsBeforeShallow = try #require(shallowReads.withLock { $0 })
  #expect(countsBeforeShallow.signing == 0 && countsBeforeShallow.live == 0)
  #expect(Set(shallow.candidates.map(\.path)).isSuperset(of: [fixture.cache, support, crash, recent]))
  #expect(shallow.candidates.allSatisfy { $0.snapshot == nil && $0.displayRootIdentity != nil && !$0.defaultSelected })
  await gate.waitUntilStarted()
  #expect(!finished.withLock { $0 })
  #expect(signingReads.withLock { $0 } == 0)
  #expect(liveReads.withLock { $0 } == 1)
  var fastExact: RelatedDataCandidate?
  while let update = await iterator.next() {
    if let candidate = update.candidates.first(where: { $0.path == fixture.cache }), candidate.defaultSelected {
      fastExact = candidate
      break
    }
  }
  #expect(fastExact?.snapshot != nil && fastExact?.observation == nil)
  await gate.release()
  let measured = await review.value
  #expect(measured.candidates.first { $0.path == fixture.cache }?.defaultSelected == true)
  #expect(measured.candidates.first { $0.path == support }?.defaultSelected == false)
  #expect(signingReads.withLock { $0 } == 0)
  #expect(liveReads.withLock { $0 } == 1)
}

@Test(
  "Shallow helper associations retain app paths without generic helper or framework floods",
  arguments: ["Discord", "Obsidian"])
func shallowHelperAssociationsAreAppSpecific(name: String) throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let bundleID = name == "Discord" ? "com.hnc.Discord" : "md.obsidian"
  let appPath = fixture.appRoot + "/" + name + ".app"
  func writePackage(_ path: String, id: String, bundleName: String, displayName: String) throws {
    try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": id, "CFBundleName": bundleName,
        "CFBundleDisplayName": displayName, "CFBundleExecutable": displayName,
      ], format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
  }
  try writePackage(appPath, id: bundleID, bundleName: name, displayName: name)
  try writePackage(
    appPath + "/Contents/Frameworks/" + name + " Helper.app", id: bundleID + ".helper",
    bundleName: name == "Obsidian" ? "Electron Helper" : name + " Helper", displayName: name + " Helper")
  try writePackage(
    appPath + "/Contents/Frameworks/Framework Helper.app", id: "com.github.electron.helper",
    bundleName: "Electron Helper", displayName: "Electron Helper")
  let library = fixture.home + "/Library/"
  let retained = [
    "Application Support/" + name.lowercased(),
    "Application Support/CrashReporter/" + name + "_78E2FF69-EFB0-5593-A527-2BE153A46CA1.plist",
    "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/"
      + bundleID.lowercased() + ".sfl4",
    "Preferences/" + bundleID + ".plist",
    "Caches/" + bundleID + ".helper.GPU",
    "HTTPStorages/" + bundleID + ".binarycookies",
    "Preferences/ByHost/" + bundleID + ".ShipIt.78E2FF69-EFB0-5593-A527-2BE153A46CA1.plist",
    "Application Support/CrashReporter/" + name + " Helper_78E2FF69-EFB0-5593-A527-2BE153A46CA1.plist",
  ].map { library + $0 }
  let unrelated = [
    "Application Support/Cold Turkey/data-helper.db", "Caches/com.other.helper",
    "LaunchAgents/com.other.helper.plist", "Logs/CrashReporter/Helium Helper.log",
    "Caches/electron", "Application Support/Electron Helper", "Caches/com.github.electron.helper",
  ].map { library + $0 }
  for path in retained + unrelated {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false)
  let app = try #require(service.application(at: appPath))
  let candidates = service.shallowCandidates(for: app).filter { $0.path.hasPrefix(fixture.home + "/") }
  #expect(Set(candidates.map(\.path)) == Set(retained))
  #expect(candidates.count == 8)
  #expect(
    candidates.allSatisfy {
      $0.classification == .unprovenNameOnly && !$0.defaultSelected && $0.snapshot == nil && $0.receipt == nil
        && $0.explicitManualChoiceAvailable
    })
}

@Test("A UUID-named app does not inherit a shared short launcher name")
func shallowUniqueNameDoesNotMatchSiblingLaunchers() throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let name = "ScopedFixture-" + UUID().uuidString
  let appPath = fixture.appRoot + "/" + name + ".app"
  try FileManager.default.createDirectory(atPath: appPath + "/Contents", withIntermediateDirectories: true)
  let data = try PropertyListSerialization.data(
    fromPropertyList: [
      "CFBundleIdentifier": "qa.scoped.root-fixture", "CFBundleName": name, "CFBundleExecutable": "ScopedFixture",
    ], format: .xml, options: 0)
  try data.write(to: URL(fileURLWithPath: appPath + "/Contents/Info.plist"))
  let support = fixture.home + "/Library/Application Support/"
  let retained = [support + name, support + "CrashReporter/" + name + ".plist"]
  let unrelated = [support + "ScopedFixture-" + UUID().uuidString, support + "ScopedFixture"]
  for path in retained + unrelated {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false)
  let app = try #require(service.application(at: appPath))
  let candidates = service.shallowCandidates(for: app).filter { $0.path.hasPrefix(fixture.home + "/") }
  #expect(Set(candidates.map(\.path)) == Set(retained))
  #expect(candidates.count == 2)
  #expect(candidates.allSatisfy { !$0.defaultSelected && $0.snapshot == nil && $0.receipt == nil })
}

@Test(
  "Bundle identifier validation preserves ASCII and component length boundaries",
  arguments: [
    ("com.example.App-123", true), ("a.-", true),
    ("a." + String(repeating: "Z", count: 63), true),
    ("a." + String(repeating: "Z", count: 64), false),
    ("a", false), (".a", false), ("a.", false), ("a..b", false),
    ("com.example_app", true), ("com.apple.Image_Capture", true), ("com.ex ample", false), ("com.é", false),
    ("com.e\u{301}", false), ("com.１２３", false), ("com.app/other", false),
  ])
func bundleIdentifierValidationBoundaries(identifier: String, valid: Bool) {
  #expect(RelatedDataService.validBundleID(identifier) == valid)
}

@Test("Stalled native evidence leaves explicit root planning schedulable and cancelled reads are skipped")
func nativeEvidenceDoesNotBlockUserSelection() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let started = AsyncStream<Void>.makeStream()
  let release = DispatchSemaphore(value: 0)
  let nativeReads = Mutex(0)
  let insideSwiftTask = Mutex(false)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in
      nativeReads.withLock { $0 += 1 }
      insideSwiftTask.withLock { $0 = withUnsafeCurrentTask { $0 != nil } }
      started.continuation.yield(())
      _ = release.wait(timeout: .now() + 5)
      return nil
    })
  let app = try #require(service.application(at: fixture.app))
  let context = service.makeContext()
  let evidence = Task { await service.review(for: app, context: context) }
  defer { release.signal() }
  var iterator = started.stream.makeAsyncIterator()
  _ = await iterator.next()
  let queued = Task { await service.review(for: app, context: context) }
  queued.cancel()
  let selection = await PlanService(homeDirectory: fixture.home).makeAvailableUserSelectionPlan(
    selections: [UserSelection(path: fixture.app), UserSelection(path: fixture.cache)])
  #expect(selection.plan?.items.count == 2)
  #expect(selection.rejections.isEmpty)
  #expect(!insideSwiftTask.withLock { $0 })
  evidence.cancel()
  release.signal()
  _ = await evidence.value
  _ = await queued.value
  #expect(nativeReads.withLock { $0 } == 1)
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
    case .session, .listed, .related, .ownershipReady: break
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

@Test("Exact identifier preselection ignores unrelated broken packages, root plists and incomplete open-file coverage")
func exactIdentifierPreselectionIsClaimScoped() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let unknown = fixture.appRoot + "/Unrelated.app"
  try FileManager.default.createDirectory(atPath: unknown + "/Contents", withIntermediateDirectories: true)
  try Data("broken plist".utf8).write(to: URL(fileURLWithPath: unknown + "/Contents/Info.plist"))
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    registration: { ApplicationRegistrationObservation(paths: [], complete: false) },
    registeredByID: { _ in ApplicationRegistrationObservation(paths: [], complete: true) },
    liveData: { ApplicationLiveDataObservation(records: [], complete: false) })
  let app = try #require(service.application(at: fixture.app))
  var inventory = service.installedListing()
  inventory.ownershipIssues.append(
    ApplicationOwnershipIssue(path: "/Library/LaunchDaemons/qa.unrelated.plist", code: EACCES))
  let observedInventory = inventory
  let initial = await service.initialReview(for: app, listing: { observedInventory }, progress: nil)
  let exact = try #require(initial.candidates.first { $0.path == fixture.cache })
  #expect(exact.defaultSelected && exact.refusalEvidence.isEmpty)
  let context = service.makeContext(base: inventory)
  let enriched = await service.review(for: app, context: context)
  let final = try #require(enriched.candidates.first { $0.path == fixture.cache })
  #expect(final.defaultSelected && final.refusalEvidence.isEmpty)
  #expect(enriched.openFilesComplete == false)
  let available = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [exact], includePackage: false)
  let plan = try #require(available.plan)
  #expect(available.rejections.isEmpty && service.prepareInstalledOwners(plan: plan).failures.isEmpty)
}

@Test("Readable launch and receipt claims survive unrelated global source failures", arguments: ["launch", "receipt"])
func readableArtifactClaimsHaveScopedSelection(_ kind: String) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let app = try #require(fixture.service.application(at: fixture.app))
  let path: String
  let observed: ApplicationAuxiliaryDiscovery
  if kind == "launch" {
    let parent = fixture.home + "/Library/LaunchAgents"
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    path = parent + "/qa.own.plist"
    try PropertyListSerialization.data(
      fromPropertyList: ["Program": fixture.app + "/Contents/MacOS/fixture"], format: .xml, options: 0
    )
    .write(to: URL(fileURLWithPath: path))
    observed = ApplicationAuxiliaryEvidenceProducer.discover(app: app, homeDirectory: fixture.home)
  } else {
    let directory = fixture.home + "/Receipts"
    let prefix = fixture.home + "/Payload"
    for root in [directory, prefix] {
      try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    path = prefix + "/own-file"
    try Data("payload".utf8).write(to: URL(fileURLWithPath: path))
    try PropertyListSerialization.data(
      fromPropertyList: ["PackageIdentifier": fixture.bundleID, "InstallPrefixPath": prefix], format: .xml, options: 0
    )
    .write(to: URL(fileURLWithPath: directory + "/" + fixture.bundleID + ".plist"))
    try Data("BOM identity".utf8).write(to: URL(fileURLWithPath: directory + "/" + fixture.bundleID + ".bom"))
    let receipts = ApplicationInstallerReceipts(
      identifiers: [fixture.bundleID], complete: true, receiptDirectory: directory,
      query: { arguments, _, _ in arguments == ["--files", fixture.bundleID] ? Data("own-file\n".utf8) : nil })
    observed = ApplicationAuxiliaryEvidenceProducer.discover(app: app, homeDirectory: fixture.home, receipts: receipts)
  }
  let claim = try #require(observed.evidence.first { $0.dataPath == path })
  try claim.validate()
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil }, registration: { ApplicationRegistrationObservation(paths: [], complete: false) },
    registeredByID: { _ in ApplicationRegistrationObservation(paths: [], complete: true) })
  let context = service.makeContext()
  context.recordDataClaims(
    [path: [.auxiliary(claim)]],
    sources: [
      ApplicationPathObservation(
        path: fixture.home + "/UnrelatedUnavailableSource", identity: try DescriptorFileSystem.identity(at: fixture.app)
      )
    ],
    issues: [])
  #expect(throws: (any Error).self) { try context.validateDataSources() }
  let review = await service.review(for: app, context: context)
  #expect(review.globalEvidenceUnavailable)
  let candidate = try #require(review.candidates.first { $0.path == path })
  #expect(candidate.defaultSelected && candidate.refusalEvidence.isEmpty)
  #expect(candidate.evidenceKinds.contains(kind == "launch" ? .launchService : .installerReceipt))
}

@Test("Identifier-scoped registration must complete before any automatic exact selection", arguments: [false, true])
func exactIdentifierSelectionWaitsForRegisteredCopies(complete: Bool) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    registration: { ApplicationRegistrationObservation(paths: [], complete: true) },
    registeredByID: { _ in ApplicationRegistrationObservation(paths: [], complete: complete) },
    liveData: { ApplicationLiveDataObservation(records: [], complete: false) })
  let app = try #require(service.application(at: fixture.app))
  let initial = await service.initialReview(for: app, progress: nil)
  let exact = try #require(initial.candidates.first { $0.path == fixture.cache })
  #expect(exact.defaultSelected == complete)
  if !complete { #expect(exact.reason == .registrationUnavailable) }
  let enriched = await service.review(for: app, context: service.makeContext())
  let final = try #require(enriched.candidates.first { $0.path == fixture.cache })
  #expect(final.defaultSelected == complete)
  if !complete { #expect(final.reason == .registrationUnavailable) }
}

@Test(
  "Unreadable matching application entries veto only the plausible owner's exact selection", arguments: [false, true])
func unreadableApplicationEntryIsPlausibleCopy(matching: Bool) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    registeredByID: { _ in
      ApplicationRegistrationObservation(paths: [], complete: true)
    })
  let app = try #require(service.application(at: fixture.app))
  let unreadable = fixture.home + "/Unreadable/" + (matching ? "Fixture.APP" : "Unrelated.app")
  var listing = service.installedListing()
  // The directory entry was enumerated, but its metadata could not be read.
  listing.ownershipIssues.append(ApplicationOwnershipIssue(path: unreadable, code: EACCES))
  let observed = listing
  let review = await service.initialReview(for: app, listing: { observed }, progress: nil)
  let exact = try #require(review.candidates.first { $0.path == fixture.cache })
  #expect(exact.defaultSelected == !matching)
  #expect(exact.refusalEvidence.contains { $0.ownerPaths == [unreadable] } == matching)
}

@Test(
  "A plausible unidentified copy closes only its own exact identifier preselection",
  arguments: ["package", "executable", "display", "bundleName", "identifierless"])
func exactIdentificationRefusesPlausibleUnknownCopies(_ matching: String) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let selectedInfo = try PropertyListSerialization.data(
    fromPropertyList: [
      "CFBundleIdentifier": fixture.bundleID, "CFBundleExecutable": "fixture",
      "CFBundleDisplayName": "Fixture Friendly", "CFBundleName": "Fixture Internal",
    ], format: .xml, options: 0)
  try selectedInfo.write(to: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist"))
  let copies = fixture.home + "/Other Applications"
  let copy = copies + (matching == "package" ? "/Fixture.app" : "/Unidentified.app")
  try FileManager.default.createDirectory(atPath: copy + "/Contents", withIntermediateDirectories: true)
  if matching != "package" {
    var info: [String: Any] = matching == "identifierless" ? [:] : ["CFBundleIdentifier": 42]
    if matching == "executable" { info["CFBundleExecutable"] = "fixture" }
    if matching == "display" || matching == "identifierless" { info["CFBundleDisplayName"] = "Fixture Friendly" }
    if matching == "bundleName" { info["CFBundleName"] = "Fixture Internal" }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: URL(fileURLWithPath: copy + "/Contents/Info.plist"))
  }
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot, copies], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let app = try #require(service.application(at: fixture.app))
  let initial = await service.initialReview(for: app, progress: nil)
  let exact = try #require(initial.candidates.first { $0.path == fixture.cache })
  #expect(!exact.defaultSelected && !exact.canSelect)
  #expect(exact.refusalEvidence.contains { $0.reason == .unknownMetadata && $0.ownerPaths == [copy] })
  let enriched = await service.review(for: app, context: service.makeContext())
  #expect(enriched.candidates.first { $0.path == fixture.cache }?.defaultSelected == false)
}

@Test("An unknown package that becomes a plausible copy closes existing exact-ID action authority")
func exactIdentifierActionRechecksPlausibleUnknownCopy() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  try PropertyListSerialization.data(
    fromPropertyList: [
      "CFBundleIdentifier": fixture.bundleID, "CFBundleExecutable": "fixture",
      "CFBundleDisplayName": "Fixture Friendly",
    ], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist"))
  let unknown = fixture.appRoot + "/Unknown.app"
  try FileManager.default.createDirectory(atPath: unknown + "/Contents", withIntermediateDirectories: true)
  func writeUnknown(displayName: String) throws {
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": 42, "CFBundleExecutable": "unrelated-helper",
        "CFBundleDisplayName": displayName,
      ], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: unknown + "/Contents/Info.plist"))
  }
  try writeUnknown(displayName: "Unrelated Friendly")
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    registration: { ApplicationRegistrationObservation(paths: [], complete: true) },
    registeredByID: { _ in ApplicationRegistrationObservation(paths: [], complete: true) })
  let app = try #require(service.application(at: fixture.app))
  let context = service.makeContext()
  let exact = try #require((await service.discover(context: context)).first { $0.path == fixture.cache })
  #expect(exact.defaultSelected && exact.refusalEvidence.isEmpty)
  let available = await service.makeAvailableUninstallPlan(
    app: app, selectedRelated: [exact], includePackage: false, context: context)
  let plan = try #require(available.plan)
  #expect(available.rejections.isEmpty && service.prepareInstalledOwners(plan: plan).failures.isEmpty)
  // No package or installation-directory entry changes. Only the previously
  // unrelated unknown owner's display name becomes a plausible copy.
  try writeUnknown(displayName: "Fixture Friendly")
  #expect(!service.prepareInstalledOwners(plan: plan).failures.isEmpty)
  #expect(throws: RelatedFailure.self) { try service.validateInstalled(plan.items[0], plan: plan) }
  let refused = await service.makeAvailableUninstallPlan(
    app: app, selectedRelated: [exact], includePackage: false, context: context)
  #expect(refused.plan == nil && !refused.rejections.isEmpty)
  #expect(refused.refusalEvidence.contains { $0.reason == .unknownMetadata && $0.ownerPaths == [unknown] })
}

@Test("Multiple readable exact owners block shallow preselection without waiting for signing")
func shallowExactOwnersAreDisjointPackages() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let copy = fixture.appRoot + "/Previous Fixture.app"
  try FileManager.default.copyItem(atPath: fixture.app, toPath: copy)
  let app = try #require(fixture.service.application(at: fixture.app))
  let candidate = try #require(
    (await fixture.service.initialReview(for: app, progress: nil)).candidates.first { $0.path == fixture.cache })
  #expect(candidate.classification == .shared && !candidate.defaultSelected)
  #expect(candidate.refusalEvidence.contains { Set($0.ownerPaths) == [fixture.app, copy] })
}

@Test("Incomplete open-file coverage retains positive shared-owner observations")
func partialLiveCoveragePreservesPositiveSharing() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let other = fixture.appRoot + "/Other.app"
  try FileManager.default.copyItem(atPath: fixture.app, toPath: other)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "qa.lighten.other", "CFBundleExecutable": "fixture"], format: .xml,
    options: 0
  )
  .write(to: URL(fileURLWithPath: other + "/Contents/Info.plist"))
  let held = try DescriptorFileSystem.identity(at: fixture.cache + "/record")
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    liveData: {
      ApplicationLiveDataObservation(
        records: [
          .init(
            pid: 123, executable: other + "/Contents/MacOS/fixture", path: fixture.cache + "/record",
            isCWD: false, device: held.device, inode: held.inode)
        ], complete: false)
    })
  let candidate = try #require((await service.discover()).first { $0.path == fixture.cache })
  #expect(candidate.classification == .shared && !candidate.defaultSelected)
  #expect(candidate.refusalEvidence.contains { Set($0.ownerPaths) == [fixture.app, other] })
  let app = try #require(service.application(at: fixture.app))
  let initial = await service.initialReview(for: app, progress: nil)
  let initiallyShared = try #require(initial.candidates.first { $0.path == fixture.cache })
  #expect(initiallyShared.classification == .shared && !initiallyShared.defaultSelected)
  #expect(initiallyShared.refusalEvidence.contains { Set($0.ownerPaths) == [fixture.app, other] })
  let enriched = await service.review(for: app, context: service.makeContext())
  let shared = try #require(enriched.candidates.first { $0.path == fixture.cache })
  #expect(shared.classification == .shared && !shared.defaultSelected)
  #expect(shared.refusalEvidence.contains { Set($0.ownerPaths) == [fixture.app, other] })
  let scoped = await service.review(for: app, context: service.makeContext(), scopedOnly: true)
  #expect(scoped.candidates.first { $0.path == fixture.cache }?.classification == .shared)
}

@Test("Selected claim enrichment signs no unrelated package and retains strict group proof")
func scopedEnrichmentDoesNotSignUnrelatedPackages() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let other = fixture.appRoot + "/Other.app"
  try FileManager.default.copyItem(atPath: fixture.app, toPath: other)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "qa.lighten.unrelated", "CFBundleExecutable": "fixture"],
    format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: other + "/Contents/Info.plist"))
  let group = fixture.home + "/Library/Group Containers/group.qa.lighten.scoped"
  let team = fixture.home + "/Library/Caches/TEAM." + fixture.bundleID
  for path in [group, team] {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }
  let signed = Mutex<[String]>([])
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { path in
      signed.withLock { $0.append(path) }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: ["group.qa.lighten.scoped"])
    }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    liveData: { ApplicationLiveDataObservation(records: [], complete: true) })
  let app = try #require(service.application(at: fixture.app))
  let context = service.makeContext()
  for _ in 0..<2 {
    let scoped = await service.review(for: app, context: context, scopedOnly: true)
    #expect(scoped.ownershipPending)
    #expect(scoped.candidates.first { $0.path == fixture.cache }?.defaultSelected == true)
    #expect(scoped.candidates.first { $0.path == team }?.defaultSelected == true)
    #expect(scoped.candidates.first { $0.path == group }?.defaultSelected == false)
  }
  #expect(signed.withLock { $0 == [fixture.app] })
  #expect(context.observedDataClaims() == nil)
}

@Test("Changed signer identity expires an immutable context observation and a fresh context reads it again")
func contextSignatureRefreshesChangedCodeIdentity() throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let reads = Mutex(0)
  let cache = ApplicationSignatureCache(reader: { _ in
    reads.withLock { $0 += 1 }
    return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [])
  })
  let context = fixture.service.makeContext()
  #expect(context.signature(at: fixture.app, cache: cache) != nil)
  #expect(context.signature(at: fixture.app, cache: cache) != nil)
  #expect(reads.withLock { $0 } == 1)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": fixture.bundleID, "CFBundleShortVersionString": "updated-version"],
    format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist"))
  #expect(context.signature(at: fixture.app, cache: cache) == nil)
  #expect(reads.withLock { $0 } == 1)
  let fresh = fixture.service.makeContext()
  #expect(fresh.signature(at: fixture.app, cache: cache) != nil)
  #expect(reads.withLock { $0 } == 2)
}

@Test("Initial main-bundle native cache claims wait only for the live sharing census")
func initialNativeCacheClaimUsesCheapMainMetadata() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let parent = fixture.home + "/Native/C"
  let cache = parent + "/" + fixture.bundleID
  try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
  let heavyReads = Mutex(0)
  let liveReads = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in
      heavyReads.withLock { $0 += 1 }
      return nil
    },
    liveData: {
      liveReads.withLock { $0 += 1 }
      return ApplicationLiveDataObservation(records: [], complete: false)
    }, referenceDirectories: .init(cache: parent, temporary: nil))
  let app = try #require(service.application(at: fixture.app))
  let review = await service.initialReview(for: app, progress: nil)
  let native = try #require(review.candidates.first { $0.path == cache })
  #expect(native.defaultSelected && native.matchStrength == .strong)
  #expect(native.evidenceKinds.contains(.bundleIdentifier))
  #expect(heavyReads.withLock { $0 } == 0)
  #expect(liveReads.withLock { $0 } == 1)
}

@Test("Explicit session invalidation replaces cached registration and owner observations")
func sessionInvalidationRebuildsOwnerUniverse() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let registered = Mutex<[String]>([])
  let walks = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    registration: { ApplicationRegistrationObservation(paths: registered.withLock { $0 }, complete: true) },
    ownershipCollected: { walks.withLock { $0 += 1 } })
  let session = ApplicationDiscovery(related: service).scanSession()
  let first = try await session.context()
  let cached = try await session.context()
  #expect(first === cached && walks.withLock { $0 } == 1)
  let copy = fixture.home + "/Outside/Fixture.app"
  try FileManager.default.createDirectory(
    atPath: (copy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try FileManager.default.copyItem(atPath: fixture.app, toPath: copy)
  registered.withLock { $0 = [copy] }
  await session.invalidateCachedObservations()
  let fresh = try await session.context()
  #expect(first !== fresh && walks.withLock { $0 } == 2)
  #expect(fresh.inventory.applications.contains { $0.path == copy })
  await session.cancel()
}

private actor ApplicationEvidenceManualDeadline {
  private var signalled = false
  private var requests = 0
  private var pending: [UUID: AsyncStream<Void>.Continuation] = [:]
  private var arrivals: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func wait() async {
    guard !signalled else { return }
    let id = UUID()
    // Cancellation ends only this waiter's stream, never a later deadline.
    let waiter = AsyncStream<Void>.makeStream()
    pending[id] = waiter.continuation
    requests += 1
    let ready = arrivals.filter { $0.count <= requests }
    arrivals.removeAll { $0.count <= requests }
    for arrival in ready { arrival.continuation.resume() }
    var iterator = waiter.stream.makeAsyncIterator()
    _ = await iterator.next()
    pending.removeValue(forKey: id)
  }

  func waitForRequests(_ count: Int) async {
    guard requests < count else { return }
    await withCheckedContinuation { arrivals.append((count, $0)) }
  }

  func signal() {
    signalled = true
    for continuation in pending.values {
      continuation.yield(())
      continuation.finish()
    }
  }
}

@Test(
  "Global evidence survives selected cancellation and stalled work has a terminal deadline", arguments: [false, true])
func selectedGlobalEvidenceDeadlineIsTerminal(cancelSelection: Bool) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let other = fixture.appRoot + "/Other.app"
  try FileManager.default.copyItem(atPath: fixture.app, toPath: other)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "qa.lighten.other", "CFBundleExecutable": "fixture"],
    format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: other + "/Contents/Info.plist"))
  try FileManager.default.createDirectory(
    atPath: fixture.home + "/Library/Application Support/example", withIntermediateDirectories: true)
  let stalled = AsyncStream<Void>.makeStream()
  let deadline = ApplicationEvidenceManualDeadline()
  let release = DispatchSemaphore(value: 0)
  defer { release.signal() }
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { path in
      if path == other {
        stalled.continuation.yield(())
        _ = release.wait(timeout: .now() + 5)
      }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [])
    }, liveData: { ApplicationLiveDataObservation(records: [], complete: true) })
  let session = ApplicationScanSession(
    related: service, uptime: { 0 },
    evidenceTimeout: { await deadline.wait() })
  _ = try await session.context()
  var blocked = stalled.stream.makeAsyncIterator()
  _ = await blocked.next()
  let updates = AsyncStream<ApplicationRelatedReview>.makeStream()
  let requestID = UUID()
  _ = try await session.relatedReview(path: fixture.app, requestID: requestID) { updates.continuation.yield($0) }
  var iterator = updates.stream.makeAsyncIterator()
  var scoped: ApplicationRelatedReview?
  while let review = await iterator.next() {
    if review.globalEvidencePending {
      scoped = review
      break
    }
  }
  let available = try #require(scoped)
  #expect(available.candidates.first { $0.path == fixture.cache }?.defaultSelected == true)
  await deadline.waitForRequests(1)
  if cancelSelection {
    await session.cancelSelectedReview(requestID: requestID)
    _ = try await session.relatedReview(path: fixture.app) { updates.continuation.yield($0) }
    await deadline.waitForRequests(2)
    release.signal()
    var completed: ApplicationRelatedReview?
    while let review = await iterator.next() {
      if review.phase == .enriched && !review.globalEvidencePending {
        completed = review
        break
      }
    }
    let fresh = try #require(completed)
    #expect(!fresh.globalEvidenceUnavailable && !fresh.ownershipPending)
    await session.cancel()
    return
  }
  await deadline.signal()
  var terminal: ApplicationRelatedReview?
  while let review = await iterator.next() {
    if review.globalEvidenceUnavailable {
      terminal = review
      break
    }
  }
  let finished = try #require(terminal)
  #expect(!finished.globalEvidencePending && finished.ownershipPending)
  #expect(finished.candidates.first { $0.path == fixture.cache }?.defaultSelected == true)
  _ = try await session.relatedReview(path: fixture.app) { updates.continuation.yield($0) }
  var repeatedTerminal: ApplicationRelatedReview?
  while let review = await iterator.next() {
    if review.globalEvidenceUnavailable {
      repeatedTerminal = review
      break
    }
  }
  let repeated = try #require(repeatedTerminal)
  #expect(!repeated.globalEvidencePending && repeated.ownershipPending)
  release.signal()
  await session.cancel()
}

@Test("Native session reports expose exact row selection before stalled sizes and reuse one ownership walk")
func nativeInitialReportsPrecedeHeavyWork() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let gate = RelatedMeasurementGate()
  let walks = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil }, ownershipCollected: { walks.withLock { $0 += 1 } },
    relatedMeasurement: { _, _ in await gate.measure() })
  let session = ApplicationDiscovery(related: service).scanSession()
  defer {
    Task {
      await gate.release()
      await session.cancel()
    }
  }
  for _ in 0..<2 {
    let report = try #require(try await session.initialReport(path: fixture.app))
    let exact = try #require(report.related.first { $0.path == fixture.cache })
    #expect(exact.defaultSelected && exact.observation == nil && report.partial)
  }
  await gate.release()
  _ = try await session.context()
  #expect(walks.withLock { $0 } == 1)
  await session.cancel()
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
  for await event in await session.events(includeAllRelated: true) {
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
  for await event in await session.events(includeAllRelated: true) {
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
  let observed = Task { for await _ in await session.events(includeAllRelated: true) {} }
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

@Test("Blocking ownership runs outside Swift tasks and cancellation leaves listed roots actionable")
func blockingOwnershipDoesNotOccupyCooperativeTask() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let started = AsyncStream<Void>.makeStream()
  let finished = AsyncStream<Void>.makeStream()
  let release = DispatchSemaphore(value: 0)
  let insideSwiftTask = Mutex(false)
  let walkFinished = Mutex(false)
  let nativeReads = Mutex(0)
  let ownershipReadyEvents = Mutex(0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    ownershipCollected: {
      insideSwiftTask.withLock { $0 = withUnsafeCurrentTask { $0 != nil } }
      started.continuation.yield(())
      started.continuation.finish()
      _ = release.wait(timeout: .now() + 5)
      walkFinished.withLock { $0 = true }
      finished.continuation.yield(())
      finished.continuation.finish()
    },
    nativeRead: { _ in nativeReads.withLock { $0 += 1 } })
  let session = ApplicationDiscovery(related: service).scanSession()
  let observed = Task {
    for await event in await session.events(includeAllRelated: true) {
      if case .ownershipReady = event { ownershipReadyEvents.withLock { $0 += 1 } }
    }
  }
  defer { release.signal() }
  var arrival = started.stream.makeAsyncIterator()
  _ = try #require(await arrival.next())
  #expect(!insideSwiftTask.withLock { $0 })
  let review = try #require(try await session.relatedReview(path: fixture.app))
  #expect(review.candidates.contains { $0.path == fixture.cache })
  let available = await session.makeAvailableUninstallPlan(
    path: fixture.app, expectedBundleID: fixture.bundleID, selectedRelated: [], includePackage: true)
  #expect(available.rejections.isEmpty && available.plan?.items.map(\.sourcePath) == [fixture.app])
  await session.cancel()
  #expect(!walkFinished.withLock { $0 })
  release.signal()
  var completed = finished.stream.makeAsyncIterator()
  _ = try #require(await completed.next())
  await observed.value
  _ = try await ApplicationOwnershipWork.shared.perform { _ in () }
  #expect(nativeReads.withLock { $0 } == 0)
  #expect(ownershipReadyEvents.withLock { $0 } == 0)
}

@Test("Cancelling queued and active ownership work never waits for the blocked native call")
func cancelledOwnershipWorkSkipsNativeReads() async throws {
  let lane = ApplicationOwnershipWork(label: "lighten.tests.ownership." + UUID().uuidString)
  let started = AsyncStream<Void>.makeStream()
  let queued = AsyncStream<Void>.makeStream()
  let release = DispatchSemaphore(value: 0)
  let nativeReturned = Mutex(false)
  let sawCancellation = Mutex(false)
  let skippedReads = Mutex(0)
  let active = Task {
    try await lane.perform { cancelled in
      started.continuation.yield(())
      started.continuation.finish()
      _ = release.wait(timeout: .now() + 5)
      nativeReturned.withLock { $0 = true }
      sawCancellation.withLock { $0 = cancelled() }
      return 1
    }
  }
  defer { release.signal() }
  var arrival = started.stream.makeAsyncIterator()
  _ = try #require(await arrival.next())
  let waiting = Task {
    queued.continuation.yield(())
    queued.continuation.finish()
    return try await lane.perform { _ in
      skippedReads.withLock { $0 += 1 }
      return 2
    }
  }
  var submitted = queued.stream.makeAsyncIterator()
  _ = try #require(await submitted.next())
  waiting.cancel()
  switch await waiting.result {
  case .success: Issue.record("Cancelled queued ownership work returned a result")
  case .failure(let error): #expect(error is CancellationError)
  }
  active.cancel()
  switch await active.result {
  case .success: Issue.record("Cancelled active ownership work returned a result")
  case .failure(let error): #expect(error is CancellationError)
  }
  #expect(!nativeReturned.withLock { $0 })
  release.signal()
  _ = try await lane.perform { _ in 3 }
  #expect(sawCancellation.withLock { $0 })
  #expect(skippedReads.withLock { $0 } == 0)
}

@Test("Direct async discovery runs ownership and signature callbacks outside Swift tasks", arguments: [false, true])
func directDiscoveryUsesBlockingLanes(focused: Bool) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let ownershipTasks = Mutex<[Bool]>([])
  let signatureTasks = Mutex<[Bool]>([])
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in
      signatureTasks.withLock { $0.append(withUnsafeCurrentTask { $0 != nil }) }
      return nil
    },
    ownershipCollected: {
      ownershipTasks.withLock { $0.append(withUnsafeCurrentTask { $0 != nil }) }
    })
  let candidates: [RelatedDataCandidate]
  if focused {
    let app = try #require(service.application(at: fixture.app))
    candidates = await service.discover(for: app)
  } else {
    candidates = await service.discover()
  }
  #expect(candidates.contains { $0.path == fixture.cache })
  #expect(ownershipTasks.withLock { !$0.isEmpty && $0.allSatisfy { !$0 } })
  #expect(signatureTasks.withLock { !$0.isEmpty && $0.allSatisfy { !$0 } })
}

@Test("Async refusal evidence runs fresh native validation outside Swift tasks")
func asyncRefusalEvidenceUsesBlockingLane() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let observing = Mutex(false)
  let registrationTasks = Mutex<[Bool]>([])
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
    registeredByID: { _ in
      if observing.withLock({ $0 }) {
        registrationTasks.withLock { $0.append(withUnsafeCurrentTask { $0 != nil }) }
      }
      return ApplicationRegistrationObservation(paths: [], complete: true)
    })
  let app = try #require(service.application(at: fixture.app))
  let candidate = try #require(
    (await service.initialReview(for: app, progress: nil)).candidates.first { $0.path == fixture.cache })
  let session = ApplicationDiscovery(related: service).scanSession()
  let available = await session.makeAvailableUninstallPlan(
    app: app, selectedRelated: [candidate], includePackage: false)
  let plan = try #require(available.plan)
  #expect(available.rejections.isEmpty)
  observing.withLock { $0 = true }
  #expect(await session.ownershipRefusalEvidence(for: plan).isEmpty)
  #expect(registrationTasks.withLock { !$0.isEmpty && $0.allSatisfy { !$0 } })
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
  for await event in await session.events(includeAllRelated: true) {
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

@Test("A root registration does not invalidate a complete LaunchServices application dump")
func registryDumpIgnoresNonapplicationRoot() {
  let observed = ApplicationRegistration.parseDump(
    "path: /\npath: /Applications\npath: /Applications/LightenQA.app (0x1)\n")
  #expect(observed.complete && observed.paths == ["/Applications/LightenQA.app"])
  #expect(!ApplicationRegistration.parseDump("path: relative/LightenQA.app\n").complete)
}

@Test("Underscore identifiers agree across installed and observed metadata")
func underscoreIdentifierIsInstalled() throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let id = "com.apple.Image_Capture"
  let bytes = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
  try bytes.write(to: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist"))
  let inventory = fixture.service.inventory()
  #expect(inventory.complete && inventory.installedRootsComplete == true)
  #expect(inventory.applications.first?.bundleID == id)
  #expect(ApplicationIdentity.bundleIdentifier(ofApplicationAt: fixture.app) == id)
  #expect(inventory.metadataIssues.isEmpty)
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
  for await event in await session.events(includeAllRelated: true) {
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

@Test(
  "Only an exclusive exact signed team and bundle identifier preselects team-prefixed data",
  arguments: ["exact", "suffix", "wrong-team", "unsigned", "shared-owner", "alias"])
func exactTeamIdentifierSelection(state: String) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let domain = "TEAM." + fixture.bundleID + (state == "suffix" ? ".helper" : state == "alias" ? "Alias" : "")
  let path = RelatedLocation.caches.path(domain: domain, homeDirectory: fixture.home)
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  if state == "shared-owner" {
    try FileManager.default.copyItem(atPath: fixture.app, toPath: fixture.appRoot + "/Second.app")
  }
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in
      state == "unsigned"
        ? nil : ApplicationSigningMetadata(teamID: state == "wrong-team" ? "OTHER" : "TEAM", groupIdentifiers: [])
    }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let candidate = try #require((await service.discover(context: service.makeContext())).first { $0.path == path })
  #expect(candidate.defaultSelected == (state == "exact"))
  if state == "exact" {
    #expect(candidate.classification == .installed && candidate.matchStrength == .strong)
    #expect(candidate.evidenceKinds == [.teamIdentifier] && candidate.automaticSelectionAllowed)
  } else if state == "suffix" {
    #expect(candidate.classification == .installed && candidate.matchStrength == .medium)
    #expect(!candidate.evidenceKinds.contains(.teamIdentifier) && !candidate.automaticSelectionAllowed)
  } else if state == "shared-owner" {
    #expect(candidate.classification == .shared && candidate.reason == .sharedInstalledData)
    #expect(!candidate.canSelect && !candidate.automaticSelectionAllowed)
  } else {
    #expect(!candidate.evidenceKinds.contains(.teamIdentifier) && !candidate.automaticSelectionAllowed)
  }
}

@Test("Exact bundle identifier preselection still requires a single physical owner", arguments: [false, true])
func exactBundleIdentifierSelection(shared: Bool) async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  if shared { try FileManager.default.copyItem(atPath: fixture.app, toPath: fixture.appRoot + "/Second.app") }
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { _ in nil }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let candidate = try #require(
    (await service.discover(context: service.makeContext())).first { $0.path == fixture.cache })
  #expect(candidate.evidenceKinds.contains(.bundleIdentifier))
  #expect(candidate.defaultSelected == !shared && candidate.automaticSelectionAllowed == !shared)
  if shared {
    #expect(candidate.classification == .shared && candidate.reason == .sharedInstalledData)
  } else {
    #expect(candidate.classification == .installed && candidate.matchStrength == .strong)
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
  for await event in await session.events(includeAllRelated: true) {
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

@Test("Daemon-container iOS placeholders are excluded while neighboring Mac apps remain installed")
func daemonPlaceholderExclusionIsExact() throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let container = fixture.home + "/Library/Daemon Containers/" + UUID().uuidString
  let placeholder = container + "/Data/Library/Caches/Placeholders-v6.noindex/qa.lighten.phone-1.0/LightenQA-phone.app"
  let ordinary = container + "/Data/Library/Caches/Placeholders-v6/qa.lighten.phone-1.0/LightenQA-Mac.app"
  for path in [placeholder, ordinary] {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: fixture.app, toPath: path)
  }
  let alias = fixture.appRoot + "/LightenQA-phone-alias.app"
  #expect(symlink(placeholder, alias) == 0)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    registration: { ApplicationRegistrationObservation(paths: [placeholder, ordinary], complete: true) })
  let inventory = service.inventory()
  #expect(!inventory.applications.contains { $0.path == placeholder || $0.path == alias })
  #expect(inventory.applications.contains { $0.path == ordinary })
  #expect(Set(inventory.scopeExclusions.map(\.path)) == [placeholder, alias])
  #expect(inventory.scopeExclusions.allSatisfy { $0.reason == "ios-daemon-placeholder" && !$0.nextStep.isEmpty })
  #expect(!inventory.unidentifiedPaths.contains(placeholder))
  #expect(RelatedDataService.isCachedApplication(placeholder, homeDirectory: fixture.home))
  #expect(!RelatedDataService.isCachedApplication(ordinary, homeDirectory: fixture.home))
}

@Test("Validated nested helper identifiers and ShipIt UUIDs supply exact claims")
func helperIdentityAndShipItClaimsArePackageBound() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let helperID = fixture.bundleID + ".helper"
  let helper = fixture.app + "/Contents/Helpers/Nested/Helper.app"
  try FileManager.default.createDirectory(atPath: helper + "/Contents", withIntermediateDirectories: true)
  let info = helper + "/Contents/Info.plist"
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": helperID], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: info))
  let helperCache = fixture.home + "/Library/Caches/" + helperID
  let unsupported = fixture.home + "/Library/Caches/" + fixture.bundleID + ".unverified"
  let byHost = fixture.home + "/Library/Preferences/ByHost"
  let updater = byHost + "/" + fixture.bundleID + ".ShipIt." + UUID().uuidString + ".plist"
  let invalidUpdater = byHost + "/" + fixture.bundleID + ".ShipIt.invalid.plist"
  for path in [helperCache, unsupported, byHost] {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }
  for path in [updater, invalidUpdater] { try Data("updater".utf8).write(to: URL(fileURLWithPath: path)) }
  let app = try #require(fixture.service.application(at: fixture.app))
  let initial = await fixture.service.initialReview(for: app, progress: nil)
  for path in [helperCache, updater] {
    let candidate = try #require(initial.candidates.first { $0.path == path })
    #expect(candidate.defaultSelected && candidate.matchStrength == .strong)
    #expect(candidate.evidenceKinds.contains(.bundleIdentifier))
  }
  for path in [unsupported, invalidUpdater] {
    #expect(initial.candidates.first { $0.path == path }?.defaultSelected != true)
  }
  let claim = try #require(
    ApplicationAuxiliaryEvidenceProducer.discover(app: app, homeDirectory: fixture.home).evidence.first {
      $0.dataPath == helperCache
    })
  try claim.validate()
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "com.unrelated.helper"], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: info))
  #expect(throws: (any Error).self) { try claim.validate() }
  #expect(
    !ApplicationAuxiliaryEvidenceProducer.discover(app: app, homeDirectory: fixture.home).evidence.contains {
      $0.dataPath == helperCache
    })
}

@Test("Same-context source refresh preserves another app's new sharing claim")
func changedPreferencesRefreshOnlyCurrentDataClaims() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let other = fixture.appRoot + "/Other.app"
  let otherID = "qa.lighten.other"
  try FileManager.default.copyItem(atPath: fixture.app, toPath: other)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": otherID], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: other + "/Contents/Info.plist"))
  let preferences = fixture.home + "/Library/Preferences/" + otherID + ".plist"
  try FileManager.default.createDirectory(
    atPath: (preferences as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  func writePreferences(_ values: [String: Any]) throws {
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
      .write(to: URL(fileURLWithPath: preferences))
  }
  try writePreferences([:])
  let service = fixture.service
  let app = try #require(service.application(at: fixture.app))
  let context = service.makeContext()
  #expect(await service.prepareDataEvidence(context: context))
  #expect(
    (await service.review(for: app, context: context)).candidates.first {
      $0.path == fixture.cache
    }?.defaultSelected == true)
  try writePreferences(["StorageDirectoryPath": fixture.cache])
  #expect(await service.prepareDataEvidence(context: context))
  let shared = await service.review(for: app, context: context, scopedOnly: true)
  let sharedCandidate = try #require(shared.candidates.first { $0.path == fixture.cache })
  #expect(sharedCandidate.classification == .shared && !sharedCandidate.defaultSelected)
  #expect(!shared.globalEvidenceUnavailable)
  #expect(sharedCandidate.refusalEvidence.contains { Set($0.ownerPaths) == [fixture.app, other] })
  try Data("temporarily invalid preferences".utf8).write(to: URL(fileURLWithPath: preferences))
  #expect(!(await service.prepareDataEvidence(context: context)))
  let unavailable = await service.review(for: app, context: context, scopedOnly: true)
  #expect(unavailable.globalEvidenceUnavailable)
  #expect(context.observedDataClaims()?[fixture.cache]?.contains { $0.packagePath == other } == true)
  try writePreferences([:])
  #expect(await service.prepareDataEvidence(context: context))
  let recovered = await service.review(for: app, context: context, scopedOnly: true)
  #expect(!recovered.globalEvidenceUnavailable)
  #expect(recovered.candidates.first { $0.path == fixture.cache }?.defaultSelected == true)
}

@Test("Live sharing census expires, caches within its window and accepts explicit freshness")
func liveCensusCacheHasBoundedLifetime() {
  let cache = ApplicationDataEvidenceCache()
  let reads = Mutex(0)
  let clock = Mutex<TimeInterval>(10)
  let read: @Sendable () -> ApplicationLiveDataObservation = {
    reads.withLock { $0 += 1 }
    return ApplicationLiveDataObservation(records: [], complete: true)
  }
  let uptime: @Sendable () -> TimeInterval = { clock.withLock { $0 } }
  _ = cache.liveObservation(using: read, uptime: uptime)
  _ = cache.liveObservation(using: read, uptime: uptime)
  #expect(reads.withLock { $0 } == 1)
  clock.withLock { $0 = 11 }
  _ = cache.liveObservation(using: read, uptime: uptime)
  #expect(reads.withLock { $0 } == 2)
  _ = cache.liveObservation(using: read, fresh: true, uptime: uptime)
  #expect(reads.withLock { $0 } == 3)
}

@Test("Changed installer records are reread after a cached successful parse")
func changedInstallerRecordReparsesItsSource() throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let directory = fixture.home + "/Receipts"
  let prefix = fixture.home + "/Payload"
  for root in [directory, prefix] {
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }
  let plist = directory + "/" + fixture.bundleID + ".plist"
  try PropertyListSerialization.data(
    fromPropertyList: ["PackageIdentifier": fixture.bundleID, "InstallPrefixPath": prefix], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: plist))
  let bom = directory + "/" + fixture.bundleID + ".bom"
  try Data("original BOM".utf8).write(to: URL(fileURLWithPath: bom))
  let payload = Mutex("first\n")
  let reads = Mutex(0)
  let receipts = ApplicationInstallerReceipts(
    identifiers: [fixture.bundleID], complete: true, receiptDirectory: directory,
    query: { arguments, _, _ in
      guard arguments == ["--files", fixture.bundleID] else { return nil }
      reads.withLock { $0 += 1 }
      return Data(payload.withLock { $0 }.utf8)
    })
  #expect(receipts.entries(bundleID: fixture.bundleID).first?.paths == [prefix + "/first"])
  try Data("changed BOM with new membership".utf8).write(to: URL(fileURLWithPath: bom))
  payload.withLock { $0 = "second\n" }
  #expect(receipts.entries(bundleID: fixture.bundleID).first?.paths == [prefix + "/second"])
  #expect(reads.withLock { $0 } == 2)
}

@Test("A timed-out global evidence attempt retries and publishes a recovered final review")
func selectedGlobalEvidenceTimeoutRecoversAfterRetry() async throws {
  let fixture = try AppsFixture()
  defer { fixture.remove() }
  let other = fixture.appRoot + "/Other.app"
  try FileManager.default.copyItem(atPath: fixture.app, toPath: other)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "qa.lighten.other"], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: other + "/Contents/Info.plist"))
  try FileManager.default.createDirectory(
    atPath: fixture.home + "/Library/Application Support/example", withIntermediateDirectories: true)
  let stalled = AsyncStream<Void>.makeStream()
  let initialDeadline = ApplicationEvidenceManualDeadline()
  let retryDeadline = ApplicationEvidenceManualDeadline()
  let retryDelay = ApplicationEvidenceManualDeadline()
  let timeoutCalls = Mutex(0)
  let release = DispatchSemaphore(value: 0)
  defer { release.signal() }
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: false,
    signingMetadata: { path in
      if path == other {
        stalled.continuation.yield(())
        release.wait()
      }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [])
    }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let session = ApplicationScanSession(
    related: service, uptime: { 0 },
    evidenceTimeout: {
      let attempt = timeoutCalls.withLock {
        $0 += 1
        return $0
      }
      if attempt == 1 { await initialDeadline.wait() } else { await retryDeadline.wait() }
    }, evidenceRetryDelay: { await retryDelay.wait() })
  _ = try await session.context()
  var blocked = stalled.stream.makeAsyncIterator()
  _ = await blocked.next()
  let updates = AsyncStream<ApplicationRelatedReview>.makeStream()
  _ = try await session.relatedReview(path: fixture.app) { updates.continuation.yield($0) }
  await initialDeadline.waitForRequests(1)
  await initialDeadline.signal()
  var iterator = updates.stream.makeAsyncIterator()
  var unavailable = false
  while let review = await iterator.next() {
    if review.globalEvidenceUnavailable {
      unavailable = true
      break
    }
  }
  #expect(unavailable)
  await retryDelay.waitForRequests(1)
  release.signal()
  await retryDelay.signal()
  var recovered: ApplicationRelatedReview?
  while let review = await iterator.next() {
    if review.phase == .enriched && !review.globalEvidencePending && !review.globalEvidenceUnavailable {
      recovered = review
      break
    }
  }
  let final = try #require(recovered)
  #expect(!final.ownershipPending)
  #expect(final.candidates.first { $0.path == fixture.cache }?.defaultSelected == true)
  await session.cancel()
}
