import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private struct FrameworkFixture {
  let home: String
  let app: String
  let name: String
  let bundleID: String
  let dataPath: String

  init() throws {
    let temporary = try #require(realpath("/tmp", nil))
    defer { free(temporary) }
    let token = UUID().uuidString
    home = String(cString: temporary) + "/LightenQA-" + token
    name = "LightenQA-" + token
    bundleID = "qa.lighten." + token
    app = home + "/Applications/" + name + ".app"
    dataPath = home + "/Library/Application Support/" + name
    try directory(app + "/Contents/Resources")
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundleName": name], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
  }

  func directory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }

  func write(_ path: String, _ value: String) throws {
    try directory((path as NSString).deletingLastPathComponent)
    try Data(value.utf8).write(to: URL(fileURLWithPath: path))
  }

  func electron(json: String? = nil, localState: Bool = true) throws {
    try directory(app + "/Contents/Frameworks/Electron Framework.framework")
    try write(
      app + "/Contents/Resources/app/package.json", json ?? "{\"productName\":\"\(name)\",\"name\":\"fallback\"}")
    try chromium(localState: localState)
  }

  func chromium(localState: Bool = true) throws {
    try write(dataPath + "/Preferences", "{\"profile\":{\"name\":\"Default\"}}")
    try directory(dataPath + "/Cache")
    if localState {
      try write(dataPath + "/Local State", "{\"os_crypt\":{}}")
    } else {
      try directory(dataPath + "/Local Storage")
    }
  }

  func archive(package: String? = nil, header: String? = nil, sparseBytes: UInt64? = nil) throws {
    try directory(app + "/Contents/Frameworks/Electron Framework.framework")
    let json = Data((package ?? "{\"name\":\"\(name)\"}").utf8)
    let headerText = header ?? "{\"files\":{\"package.json\":{\"size\":\(json.count),\"offset\":\"0\"}}}"
    let headerJSON = Data(headerText.utf8)
    var headerPickle = Data()
    let padding = (4 - headerJSON.count % 4) % 4
    headerPickle.append(frameworkUInt32(UInt32(4 + headerJSON.count + padding)))
    headerPickle.append(frameworkUInt32(UInt32(headerJSON.count)))
    headerPickle.append(headerJSON)
    headerPickle.append(Data(repeating: 0, count: padding))
    var bytes = frameworkUInt32(4)
    bytes.append(frameworkUInt32(UInt32(headerPickle.count)))
    bytes.append(headerPickle)
    bytes.append(json)
    let path = app + "/Contents/Resources/app.asar"
    try bytes.write(to: URL(fileURLWithPath: path))
    if let sparseBytes {
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      try handle.truncate(atOffset: sparseBytes)
    }
    try chromium()
  }

  func mozilla(profilesINI: String? = nil, withINI: Bool = true) throws -> String {
    try write(
      app + "/Contents/Resources/application.ini", "[App]\nName=\(name)\nVendor=Mozilla\n[Gecko]\nMinVersion=1\n")
    let root = home + "/Library/" + name
    try directory(root + "/Profiles/qa.default")
    try write(root + "/Profiles/qa.default/prefs.js", "// Profile fixture; never executed.")
    try write(root + "/Profiles/qa.default/compatibility.ini", "[Compatibility]\nLastVersion=1\n")
    if withINI {
      try write(
        root + "/profiles.ini", profilesINI ?? "[Profile0]\nName=default\nIsRelative=1\nPath=Profiles/qa.default\n")
    }
    return root
  }

  func discover() -> ApplicationFrameworkDiscovery {
    ApplicationFrameworkEvidenceProducer.discover(packagePath: app, homeDirectory: home)
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: home) }
}

private func frameworkUInt32(_ value: UInt32) -> Data {
  Data([
    UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
    UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24),
  ])
}

enum FrameworkArtifactMutation: String, CaseIterable, Sendable {
  case replacement, contents, info, package, data, preferences, cache, absentMarker
  case artifactLink, dataLink
}

@Suite("Package-derived framework data ownership")
struct ApplicationFrameworkEvidenceTests {
  private func service(
    _ fixture: FrameworkFixture, ownershipCollected: @escaping @Sendable () -> Void = {},
    signingMetadata: @escaping @Sendable (String) -> ApplicationSigningMetadata? = { _ in nil }
  ) -> RelatedDataService {
    RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"],
      writeVerifiedReceipts: false, signingMetadata: signingMetadata,
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
      ownershipCollected: ownershipCollected)
  }

  @Test(
    "Framework data plans retain one owner census and native evidence through preparation", arguments: [false, true])
  func nativeFrameworkPlan(mozilla: Bool) async throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let dataPath: String
    if mozilla {
      dataPath = try fixture.mozilla()
    } else {
      try fixture.electron()
      dataPath = fixture.dataPath
    }
    let walks = Mutex(0)
    let related = service(fixture, ownershipCollected: { walks.withLock { $0 += 1 } })
    let session = ApplicationDiscovery(related: related).scanSession()
    let candidate = try #require((await session.observedRelatedCandidates()).first { $0.path == dataPath })
    let app = try #require(related.application(at: fixture.app))
    #expect(candidate.classification == .installed && candidate.canSelect)
    #expect(candidate.provenance?.kind == (mozilla ? .mozilla : .electron))
    for _ in 0..<2 {
      let outcome = await session.makeAvailableUninstallPlan(
        app: app, selectedRelated: [candidate], includePackage: false)
      let plan = try #require(outcome.plan)
      #expect(outcome.rejections.isEmpty)
      #expect(await session.validatePlan(plan).isEmpty)
      let prepared = related.prepareInstalledOwners(plan: plan)
      #expect(prepared.failures.isEmpty && prepared.owners.count == 1)
      let owner = try #require(prepared.owners[plan.items[0].id])
      try ActionGuard(homeDirectory: fixture.home).validate(plan.items[0], plan: plan, preparedOwner: owner)
    }
    #expect(walks.withLock { $0 } == 1)
    await session.cancel()
  }

  @Test("A second package claiming the same framework folder retains both physical owners")
  func sharedFrameworkData() async throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron()
    let second = fixture.home + "/Applications/LightenQA-second.app"
    try fixture.directory(second + "/Contents/Frameworks/Electron Framework.framework")
    try fixture.write(second + "/Contents/Resources/app/package.json", "{\"productName\":\"\(fixture.name)\"}")
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "qa.lighten.other"], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: second + "/Contents/Info.plist"))
    let session = ApplicationDiscovery(related: service(fixture)).scanSession()
    let candidate = try #require((await session.observedRelatedCandidates()).first { $0.path == fixture.dataPath })
    #expect(candidate.classification == .shared && candidate.reason == .sharedInstalledData)
    #expect(!candidate.canSelect && !candidate.explicitManualChoiceAvailable)
    let evidence = try #require(candidate.refusalEvidence.first)
    #expect(evidence.reason == .sharedInstalledOwners)
    #expect(evidence.ownerPaths == [fixture.app, second].sorted())
    await session.cancel()
  }

  @Test("A new configured claim invalidates previously selected framework data without reminting authority")
  func newSharedClaimInvalidatesPlan() async throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron()
    let second = fixture.home + "/Applications/LightenQA-second.app"
    try fixture.directory(second + "/Contents")
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "qa.lighten.other"], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: second + "/Contents/Info.plist"))
    try fixture.directory(fixture.home + "/Library/Preferences")
    let related = service(fixture)
    let session = ApplicationDiscovery(related: related).scanSession()
    let candidate = try #require((await session.observedRelatedCandidates()).first { $0.path == fixture.dataPath })
    let app = try #require(related.application(at: fixture.app))
    let outcome = await session.makeAvailableUninstallPlan(
      app: app, selectedRelated: [candidate], includePackage: false)
    let plan = try #require(outcome.plan)
    let prepared = related.prepareInstalledOwners(plan: plan)
    let owner = try #require(prepared.owners[plan.items[0].id])
    try PropertyListSerialization.data(
      fromPropertyList: ["dataDirectoryPath": fixture.dataPath], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: fixture.home + "/Library/Preferences/qa.lighten.other.plist"))
    #expect(!(await session.validatePlan(plan)).isEmpty)
    #expect(throws: (any Error).self) {
      try ActionGuard(homeDirectory: fixture.home).validate(plan.items[0], plan: plan, preparedOwner: owner)
    }
    await session.cancel()
  }

  @Test("A literal identifier owner vetoes a framework-derived name before manual or automatic selection")
  func literalOwnerVeto() async throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron()
    let literal = fixture.home + "/Applications/LightenQA-literal.app"
    try fixture.directory(literal + "/Contents")
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": fixture.name], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: literal + "/Contents/Info.plist"))
    let session = ApplicationDiscovery(related: service(fixture)).scanSession()
    let candidate = try #require((await session.observedRelatedCandidates()).first { $0.path == fixture.dataPath })
    #expect(candidate.reason == .literalIdentifierOwner && candidate.classification == .uncertain)
    #expect(!candidate.canSelect && !candidate.explicitManualChoiceAvailable)
    await session.cancel()
  }

  @Test("Moving the authenticated framework package to Trash preserves its data proof")
  func movedFrameworkOwner() async throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron()
    let related = service(fixture)
    let session = ApplicationDiscovery(related: related).scanSession()
    let candidate = try #require((await session.observedRelatedCandidates()).first { $0.path == fixture.dataPath })
    let app = try #require(related.application(at: fixture.app))
    let outcome = await session.makeAvailableUninstallPlan(app: app, selectedRelated: [candidate])
    let plan = try #require(outcome.plan)
    let item = try #require(plan.items.first { $0.installedRelatedProof != nil })
    let package = try #require(plan.items.first { $0.policy == .wholeBundle })
    let prepared = related.prepareInstalledOwners(plan: plan)
    let owner = try #require(prepared.owners[item.id])
    let trashPath = fixture.home + "/.Trash/" + fixture.name + ".app"
    try fixture.directory(fixture.home + "/.Trash")
    try FileManager.default.moveItem(atPath: fixture.app, toPath: trashPath)
    let moved = try MovedApplicationOwner(
      planID: plan.id, package: package, path: trashPath,
      identity: DescriptorFileSystem.identity(at: trashPath))
    try ActionGuard(homeDirectory: fixture.home).validate(item, plan: plan, preparedOwner: owner, movedOwner: moved)
    await session.cancel()
  }

  @Test("Live descriptor ownership binds the observed vnode instead of trusting a path", arguments: [false, true])
  func liveVnodeProof(replaced: Bool) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let executable = fixture.app + "/Contents/MacOS/helper"
    let held = fixture.dataPath + "/state.bin"
    try fixture.write(executable, "fixture executable")
    try fixture.write(held, "fixture state")
    let identity = try DescriptorFileSystem.identity(at: held)
    if replaced {
      try FileManager.default.moveItem(atPath: held, toPath: held + ".old")
      try fixture.write(held, "replacement state")
    }
    let observation = ApplicationLiveDataObservation(
      records: [
        .init(
          pid: 1, executable: executable, path: held, isCWD: false,
          device: identity.device, inode: identity.inode)
      ], complete: true)
    let app = InstalledApplication(bundleID: fixture.bundleID, path: fixture.app, version: nil)
    let discovered = ApplicationAuxiliaryEvidenceProducer.discover(
      app: app, homeDirectory: fixture.home, live: observation)
    #expect(
      discovered.evidence.contains { $0.dataPath == fixture.dataPath && $0.provenance.kind == .liveProcess }
        == !replaced)
  }

  @Test("Fresh live-sharing checks retain a different installed owner and reject stale vnode paths")
  func freshLiveSharedOwner() throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let executable = fixture.app + "/Contents/MacOS/helper"
    let held = fixture.dataPath + "/state.bin"
    try fixture.write(executable, "fixture executable")
    try fixture.write(held, "fixture state")
    let identity = try DescriptorFileSystem.identity(at: held)
    let observation = ApplicationLiveDataObservation(
      records: [
        .init(
          pid: 1, executable: executable, path: held, isCWD: false,
          device: identity.device, inode: identity.inode)
      ], complete: true)
    let app = InstalledApplication(bundleID: fixture.bundleID, path: fixture.app, version: nil)
    let owners = try ApplicationAuxiliaryEvidenceProducer.liveSharedOwnerPaths(
      dataPath: fixture.dataPath, excludingPackage: fixture.home + "/Other.app", applications: [app],
      home: fixture.home, observation: observation)
    #expect(owners == [fixture.app])
    #expect(
      try ApplicationAuxiliaryEvidenceProducer.liveSharedOwnerPaths(
        dataPath: fixture.dataPath, excludingPackage: fixture.app, applications: [app], home: fixture.home,
        observation: observation
      ).isEmpty)
    try FileManager.default.moveItem(atPath: held, toPath: held + ".old")
    try fixture.write(held, "replacement state")
    #expect(throws: (any Error).self) {
      try ApplicationAuxiliaryEvidenceProducer.liveSharedOwnerPaths(
        dataPath: fixture.dataPath, excludingPackage: fixture.home + "/Other.app", applications: [app],
        home: fixture.home, observation: observation)
    }
  }

  @Test("A bounded census failure is unknown sharing, never an empty owner proof")
  func incompleteLiveCensusRefusesSharing() throws {
    let observed = ApplicationLiveDataObservation.observe(maximumBytes: 1)
    #expect(!observed.complete && observed.records.isEmpty)
    let report = try #require(observed.report)
    #expect(report.incompleteReasons.contains("memory-limit"))
    #expect(!report.complete && report.recordCount == 0)
    #expect(throws: (any Error).self) {
      try ApplicationAuxiliaryEvidenceProducer.liveSharedOwnerPaths(
        dataPath: "/unobserved", excludingPackage: "/unobserved.app", applications: [], home: "/unobserved",
        observation: observed)
    }
  }

  @Test(
    "A live vnode cannot claim personal folders or unrelated Library areas",
    arguments: ["Documents", "Desktop", "Downloads", "Zotero", "Library/Mobile Documents", "Library/Developer"])
  func livePersonalFolderExcluded(area: String) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let executable = fixture.app + "/Contents/MacOS/helper"
    let held = fixture.home + "/" + area + "/LightenQA-user/state"
    try fixture.write(executable, "fixture executable")
    try fixture.write(held, "fixture state")
    let identity = try DescriptorFileSystem.identity(at: held)
    let observed = ApplicationLiveDataObservation(
      records: [
        .init(
          pid: 1, executable: executable, path: held, isCWD: false,
          device: identity.device, inode: identity.inode)
      ], complete: true)
    let app = InstalledApplication(bundleID: fixture.bundleID, path: fixture.app, version: nil)
    let discovery = ApplicationAuxiliaryEvidenceProducer.discover(
      app: app, homeDirectory: fixture.home, live: observed)
    #expect(!discovery.evidence.contains { $0.provenance.kind == .liveProcess })
  }

  @Test("Transient live and vendor proof alone never preselect data")
  func transientEvidenceNeedsIndependentProof() {
    let identity = FileIdentity(
      device: 1, inode: 1, changeSeconds: 1, changeNanoseconds: 0, logicalBytes: 1,
      allocatedBytes: 512, linkCount: 1, flags: 0, kind: .directory)
    let entry = ScanEntry(parentID: nil, path: "/fixture", identity: identity, issues: [], readable: true)
    let snapshot = ScanSnapshot(rootPath: "/fixture", volumeDevice: 1, entries: [entry], nodes: [])
    var candidate = RelatedDataCandidate(
      id: "/fixture", path: "/fixture", classification: .installed, reason: .installed, snapshot: snapshot, receipt: nil
    )
    let inputs: [[RelatedDataProvenanceKind]] = [[.liveProcess], [.vendorDirectory], [.vendorDirectory, .liveProcess]]
    for kinds in inputs {
      candidate.evidenceKinds = kinds
      #expect(candidate.canSelect && !candidate.automaticSelectionAllowed && !candidate.defaultSelected)
    }
    candidate.evidenceKinds = [.vendorDirectory, .configuredDirectory]
    candidate.provenance = RelatedDataProvenance(kind: .configuredDirectory)
    #expect(candidate.automaticSelectionAllowed && !candidate.defaultSelected)
    candidate.evidenceKinds = [.liveProcess, .electron]
    candidate.provenance = RelatedDataProvenance(kind: .liveProcess)
    #expect(candidate.automaticSelectionAllowed && candidate.defaultSelected)
  }

  @Test("General framework and tool names never become a vendor folder claim")
  func genericVendorFolderExcluded() throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let id = "com.electron.fixture"
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist"))
    let path = fixture.home + "/Library/Caches/electron"
    try fixture.directory(path)
    let app = InstalledApplication(bundleID: id, path: fixture.app, version: nil)
    let discovery = ApplicationAuxiliaryEvidenceProducer.discover(
      app: app, homeDirectory: fixture.home, vendorExclusive: true)
    #expect(!discovery.evidence.contains { $0.dataPath == path && $0.provenance.kind == .vendorDirectory })
  }

  @Test(
    "Vendor proof checks both the installed identifier prefix and signed team",
    arguments: ["only", "prefix", "team", "unrelated", "unsigned"])
  func vendorExclusivity(state: String) async throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let selectedID = "com.lightenqa.primary"
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": selectedID], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist"))
    let vendorPath = fixture.home + "/Library/Caches/lightenqa"
    try fixture.directory(vendorPath)
    let second = fixture.home + "/Applications/LightenQA-second.app"
    if state != "only" {
      try fixture.directory(second + "/Contents")
      try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": state == "prefix" ? "com.lightenqa.other" : "org.other.fixture"],
        format: .xml, options: 0
      ).write(to: URL(fileURLWithPath: second + "/Contents/Info.plist"))
    }
    let related = service(
      fixture,
      signingMetadata: { path in
        if path == second && state == "unsigned" { return nil }
        return ApplicationSigningMetadata(
          teamID: path == fixture.app || state == "team" ? "PRIMARY" : "OTHER", groupIdentifiers: [])
      })
    let candidates = await related.discover(context: related.makeContext())
    let candidate = candidates.first { $0.path == vendorPath && $0.provenance?.kind == .vendorDirectory }
    #expect((candidate != nil) == (state == "only" || state == "unrelated"))
    #expect(candidate?.automaticSelectionAllowed != true && candidate?.defaultSelected != true)
  }

  @Test("A discovery validates its broad evidence sources twice for many shared candidates")
  func discoveryValidatesSourcesOncePerSnapshot() async throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let second = fixture.home + "/Applications/LightenQA-second.app"
    let otherID = "qa.lighten.other"
    try fixture.directory(second + "/Contents")
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": otherID], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: second + "/Contents/Info.plist"))
    var settings: [String: String] = [:]
    for index in 0..<20 {
      let path = fixture.home + "/Library/Application Support/LightenQA-shared-\(index)"
      try fixture.directory(path)
      settings["data\(index)DirectoryPath"] = path
    }
    try fixture.directory(fixture.home + "/Library/Preferences")
    let bytes = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
    for id in [fixture.bundleID, otherID] {
      try bytes.write(to: URL(fileURLWithPath: fixture.home + "/Library/Preferences/" + id + ".plist"))
    }
    let related = service(fixture)
    let context = related.makeContext()
    let candidates = await related.discover(context: context)
    #expect(candidates.filter { $0.reason == .sharedInstalledData }.count == 20)
    #expect(context.dataSourceValidationCount == 2)
    #expect(candidates.filter { $0.reason == .sharedInstalledData }.allSatisfy { !$0.canSelect })
  }

  @Test("Registration has separate Spotlight, dump fallback and unavailable states", arguments: [0, 1, 2])
  func registrationSourceStates(state: Int) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let observed = ApplicationRegistration.observe(
      readIndexingStatus: { state == 0 ? "enabled" : state == 1 ? "disabled" : "unavailable" },
      readSpotlight: { ApplicationRegistrationObservation(paths: [fixture.app], complete: true) },
      readDump: { ApplicationRegistrationObservation(paths: state == 1 ? [fixture.app] : [], complete: state == 1) },
      byIdentifier: { _ in [fixture.app] })
    let report = try #require(observed.report)
    #expect(report.source == (state == 0 ? "public-spotlight" : state == 1 ? "launch-services-dump" : "unavailable"))
    #expect(observed.complete == (state != 2))
    #expect(report.gatheringCompleted == (state == 0))
    #expect(report.leadCount == (state == 2 ? 0 : 1))
    #expect(!ApplicationRegistration.parseDump("path: relative/LightenQA.app\n").complete)
  }

  @Test("Unknown global registration blocks group ownership while exact standard data remains available")
  func unknownRegistrationIsScoped() async throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let group = "group.qa.lighten.fixture"
    let exactPath = fixture.home + "/Library/Caches/" + fixture.bundleID
    let groupPath = fixture.home + "/Library/Group Containers/" + group
    try fixture.directory(exactPath)
    try fixture.directory(groupPath)
    let related = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"],
      writeVerifiedReceipts: false,
      signingMetadata: { _ in ApplicationSigningMetadata(teamID: "QA", groupIdentifiers: [group]) },
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
      registration: {
        ApplicationRegistrationObservation(
          paths: [], complete: false,
          report: ApplicationRegistrationReport(
            source: "unavailable", leadCount: 0, complete: false, gatheringCompleted: false,
            bootIndexingStatus: "disabled", externalVolumesUnchecked: true))
      },
      registeredByID: { id in
        ApplicationRegistrationObservation(paths: id == fixture.bundleID ? [fixture.app] : [], complete: true)
      })
    let context = related.makeContext()
    let candidates = await related.discover(context: context)
    let exact = try #require(candidates.first { $0.path == exactPath })
    let shared = try #require(candidates.first { $0.path == groupPath })
    #expect(exact.canSelect && exact.reason == .installed)
    #expect(!shared.canSelect && shared.reason == .registrationUnavailable)
    let app = try #require(related.application(at: fixture.app))
    let exactPlan = await related.makeAvailableUninstallPlan(
      app: app, selectedRelated: [exact], includePackage: false)
    #expect(exactPlan.plan != nil && exactPlan.rejections.isEmpty)
    let groupPlan = await related.makeAvailableUninstallPlan(
      app: app, selectedRelated: [shared], includePackage: false)
    #expect(groupPlan.plan == nil)
    #expect(groupPlan.rejections.contains { $0.ruleID == "registrationUnavailable" })
  }

  @Test("Explicit retained data keeps its original observation without requiring its former owner")
  func retainedFrameworkDataUsesUserSelection() async throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron()
    let related = service(fixture)
    let context = related.makeContext()
    let candidate = try #require((await related.discover(context: context)).first { $0.path == fixture.dataPath })
    try fixture.directory(fixture.home + "/.Trash")
    try FileManager.default.moveItem(atPath: fixture.app, toPath: fixture.home + "/.Trash/" + fixture.name + ".app")
    let available = await related.makeAvailableRemainingDataPlan(selected: [candidate])
    let plan = try #require(available.plan)
    #expect(available.rejections.isEmpty && plan.items[0].userSelection == true)
    #expect(plan.items[0].installedRelatedProof == nil && plan.items[0].orphanRelatedProof == nil)
    try ActionGuard(homeDirectory: fixture.home).validate(plan.items[0], plan: plan)
    let second = fixture.home + "/Applications/LightenQA-second.app"
    try fixture.directory(second + "/Contents")
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "qa.lighten.other"], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: second + "/Contents/Info.plist"))
    try fixture.directory(fixture.home + "/Library/Preferences")
    try PropertyListSerialization.data(
      fromPropertyList: ["dataDirectoryPath": fixture.dataPath], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: fixture.home + "/Library/Preferences/qa.lighten.other.plist"))
    try ActionGuard(homeDirectory: fixture.home).validate(plan.items[0], plan: plan)
    let explicit = await related.makeAvailableRemainingDataPlan(selected: [candidate])
    #expect(explicit.plan != nil && explicit.rejections.isEmpty)
  }

  @Test("Electron productName and native Chromium shape establish the exact derived folder", arguments: [false, true])
  func electronLayout(localState: Bool) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron(localState: localState)
    let result = fixture.discover()
    #expect(result.complete)
    let evidence = try #require(result.evidence.first)
    #expect(result.evidence.count == 1)
    #expect(evidence.framework == .electron && evidence.productName == fixture.name)
    #expect(evidence.packagePath == fixture.app && evidence.bundleIdentifier == fixture.bundleID)
    #expect(evidence.dataPath == fixture.dataPath)
    try evidence.validate()
  }

  @Test("Electron name fallback reads a bounded package from a large ASAR")
  func boundedASAR() throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.archive(sparseBytes: 130_678_921)
    let result = fixture.discover()
    #expect(result.complete)
    let evidence = try #require(result.evidence.first)
    #expect(evidence.productName == fixture.name && evidence.dataPath == fixture.dataPath)
    try evidence.validate()
  }

  @Test("Framework names emit the native directory spelling only when the filesystem resolves that name")
  func nativeDirectorySpelling() throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron(json: "{\"name\":\"\(fixture.name.lowercased())\"}")
    let requested = fixture.home + "/Library/Application Support/" + fixture.name.lowercased()
    let resolves =
      (try? DescriptorFileSystem.identity(at: requested))
      == (try? DescriptorFileSystem.identity(at: fixture.dataPath))
    let result = fixture.discover()
    #expect(result.evidence.count == (resolves ? 1 : 0))
    if resolves {
      let evidence = try #require(result.evidence.first)
      #expect(evidence.dataPath == fixture.dataPath)
      try evidence.validate()
    }
  }

  @Test(
    "Package metadata cannot choose traversal, absolute, control, duplicate or empty names",
    arguments: [
      "{\"productName\":\"../foreign\"}", "{\"productName\":\"/foreign\"}",
      "{\"productName\":\"a\\\\b\"}", "{\"productName\":\"\"}",
      "{\"productName\":\"a\\u0000b\"}", "{\"name\":\"one\",\"name\":\"two\"}",
      "{\"name\":\"one\",\"n\\u0061me\":\"two\"}", "{\"productName\":5,\"name\":\"fallback\"}",
    ])
  func unsafeMetadata(json: String) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron(json: json)
    let result = fixture.discover()
    #expect(result.evidence.isEmpty && !result.complete)
    #expect(result.issues.contains { $0.reason == .invalidMetadata })
  }

  @Test(
    "ASAR refuses duplicate/traversal entries, links, unpacked data and unsafe bounds",
    arguments: [
      "{\"files\":{\"package.json\":{\"size\":1,\"offset\":\"0\"},\"package.json\":{\"size\":1,\"offset\":\"0\"}}}",
      "{\"files\":{\"../package.json\":{\"size\":1,\"offset\":\"0\"}}}",
      "{\"files\":{\"package.json\":{\"size\":1,\"offset\":\"0\",\"link\":\"foreign\"}}}",
      "{\"files\":{\"package.json\":{\"size\":1,\"offset\":\"0\",\"unpacked\":true}}}",
      "{\"files\":{\"package.json\":{\"size\":1,\"offset\":\"18446744073709551615\"}}}",
      "{\"files\":{\"package.json\":{\"size\":1,\"offset\":\"-1\"}}}",
      "{\"files\":{\"package.json\":{\"size\":1048577,\"offset\":\"0\"}}}",
      "{\"files\":{\"package.json\":{\"size\":true,\"offset\":\"0\"}}}",
      "{\"files\":{\"package.json\":{\"size\":50000,\"offset\":\"0\"}}}",
      "{\"files\":{\"nested\":{\"files\":{\"..\":{\"size\":1,\"offset\":\"0\"}}}}}",
    ])
  func unsafeASAR(header: String) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.archive(header: header)
    let result = fixture.discover()
    #expect(result.evidence.isEmpty && !result.complete)
    #expect(result.issues.contains { $0.reason == .invalidArchive || $0.reason == .invalidMetadata })
  }

  @Test("ASAR size and string pickles must fit the bounded header", arguments: [0, 4, 8, 12])
  func malformedPickle(offset: Int) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.archive()
    let path = fixture.app + "/Contents/Resources/app.asar"
    var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    let value: UInt32 = offset == 4 ? 4 * 1024 * 1024 + 4 : UInt32.max
    bytes.replaceSubrange(offset..<(offset + 4), with: frameworkUInt32(value))
    try bytes.write(to: URL(fileURLWithPath: path))
    #expect(fixture.discover().evidence.isEmpty)
  }

  @Test("An ASAR must contain the entire declared header and root package.json")
  func truncatedArchive() throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.archive()
    let path = fixture.app + "/Contents/Resources/app.asar"
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.truncate(atOffset: 17)
    try handle.close()
    #expect(fixture.discover().evidence.isEmpty)
  }

  @Test("A Chromium-looking folder or app name without package proof never grants ownership")
  func missingPackageProof() throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.chromium()
    #expect(fixture.discover().issues.contains { $0.reason == .unsupportedFramework })
    try fixture.directory(fixture.app + "/Contents/Frameworks/Electron Framework.framework")
    let result = fixture.discover()
    #expect(result.evidence.isEmpty && result.issues.contains { $0.reason == .missingArtifact })
  }

  @Test("Metadata alone and empty or malformed data folders have no framework proof", arguments: [0, 1, 2, 3])
  func missingShape(fault: Int) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron()
    switch fault {
    case 0: try FileManager.default.removeItem(atPath: fixture.dataPath + "/Preferences")
    case 1: try FileManager.default.removeItem(atPath: fixture.dataPath + "/Cache")
    case 2: try fixture.write(fixture.dataPath + "/Preferences", "[]")
    default: try FileManager.default.removeItem(atPath: fixture.dataPath + "/Local State")
    }
    let result = fixture.discover()
    #expect(result.evidence.isEmpty && !result.complete)
  }

  @Test(
    "Package, artifact and data shape identity changes invalidate previously minted evidence",
    arguments: FrameworkArtifactMutation.allCases)
  func revalidation(mutation: FrameworkArtifactMutation) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron()
    let evidence = try #require(fixture.discover().evidence.first)
    let jsonPath = fixture.app + "/Contents/Resources/app/package.json"
    switch mutation {
    case .replacement:
      let bytes = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
      try FileManager.default.moveItem(atPath: jsonPath, toPath: jsonPath + ".old")
      try bytes.write(to: URL(fileURLWithPath: jsonPath))
    case .contents: try fixture.write(jsonPath, "{\"name\":\"foreign\"}")
    case .info: try fixture.write(fixture.app + "/Contents/Info.plist", "invalid replacement")
    case .package:
      try FileManager.default.moveItem(atPath: fixture.app, toPath: fixture.app + ".old")
      try fixture.directory(fixture.app)
    case .data:
      try FileManager.default.moveItem(atPath: fixture.dataPath, toPath: fixture.dataPath + ".old")
      try fixture.chromium()
    case .preferences: try fixture.write(fixture.dataPath + "/Preferences", "{\"changed\":true}")
    case .cache:
      try FileManager.default.moveItem(atPath: fixture.dataPath + "/Cache", toPath: fixture.dataPath + "/Cache.old")
      try fixture.directory(fixture.dataPath + "/Cache")
    case .absentMarker: try fixture.directory(fixture.dataPath + "/Code Cache")
    case .artifactLink:
      try FileManager.default.moveItem(atPath: jsonPath, toPath: jsonPath + ".target")
      try FileManager.default.createSymbolicLink(atPath: jsonPath, withDestinationPath: jsonPath + ".target")
    case .dataLink:
      try FileManager.default.moveItem(atPath: fixture.dataPath, toPath: fixture.dataPath + ".target")
      try FileManager.default.createSymbolicLink(
        atPath: fixture.dataPath, withDestinationPath: fixture.dataPath + ".target")
    }
    #expect(throws: (any Error).self) { try evidence.validate() }
  }

  @Test("ASAR replacement and in-place package bytes changes invalidate native evidence", arguments: [false, true])
  func archiveRevalidation(replace: Bool) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.archive()
    let evidence = try #require(fixture.discover().evidence.first)
    let path = fixture.app + "/Contents/Resources/app.asar"
    if replace {
      let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
      try FileManager.default.moveItem(atPath: path, toPath: path + ".old")
      try bytes.write(to: URL(fileURLWithPath: path))
    } else {
      let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      try handle.seek(toOffset: size - 2)
      try handle.write(contentsOf: Data("x".utf8))
    }
    #expect(throws: (any Error).self) { try evidence.validate() }
  }

  @Test(
    "Native artifact and data shape symlinks are refused",
    arguments: ["metadata", "framework", "data", "preferences", "ancestor"])
  func linksRefused(target: String) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron()
    let path: String
    switch target {
    case "metadata": path = fixture.app + "/Contents/Resources/app/package.json"
    case "framework": path = fixture.app + "/Contents/Frameworks/Electron Framework.framework"
    case "data": path = fixture.dataPath
    case "preferences": path = fixture.dataPath + "/Preferences"
    default: path = fixture.app + "/Contents/Resources"
    }
    try FileManager.default.moveItem(atPath: path, toPath: path + ".target")
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: path + ".target")
    #expect(fixture.discover().evidence.isEmpty)
  }

  @Test(
    "Mozilla binds application.ini and either relative profiles.ini or native profile structure",
    arguments: [false, true])
  func mozillaLayout(withINI: Bool) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let root = try fixture.mozilla(withINI: withINI)
    let result = fixture.discover()
    #expect(result.complete)
    let evidence = try #require(result.evidence.first)
    #expect(evidence.framework == .mozilla && evidence.dataPath == root)
    try evidence.validate()
    try fixture.write(root + "/Profiles/qa.default/compatibility.ini", "[Compatibility]\nLastVersion=2\n")
    #expect(throws: (any Error).self) { try evidence.validate() }
  }

  @Test(
    "Mozilla refuses external, traversal, duplicate and missing profile proof",
    arguments: [
      "[Profile0]\nIsRelative=0\nPath=/foreign\n",
      "[Profile0]\nIsRelative=1\nPath=../foreign\n",
      "[Profile0]\nIsRelative=1\nPath=Profiles/../../foreign\n",
      "[Profile0]\nIsRelative=1\nPath=Profiles/missing\n",
      "[Profile0]\nIsRelative=1\nPath=Profiles/qa.default\nPath=Profiles/other\n",
    ])
  func invalidProfiles(ini: String) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    _ = try fixture.mozilla(profilesINI: ini)
    #expect(fixture.discover().evidence.isEmpty)
  }

  @Test(
    "Mozilla package metadata and profile paths cannot introduce links",
    arguments: [
      "application.ini", "profiles.ini", "profile", "prefs.js", "compatibility.ini",
    ])
  func mozillaLinks(target: String) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let root = try fixture.mozilla()
    let path: String
    switch target {
    case "application.ini": path = fixture.app + "/Contents/Resources/application.ini"
    case "profiles.ini": path = root + "/profiles.ini"
    case "profile": path = root + "/Profiles/qa.default"
    default: path = root + "/Profiles/qa.default/" + target
    }
    try FileManager.default.moveItem(atPath: path, toPath: path + ".target")
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: path + ".target")
    #expect(fixture.discover().evidence.isEmpty)
  }

  @Test(
    "Mozilla names and vendors require unambiguous package metadata",
    arguments: [
      "[App]\nName=../foreign\nVendor=Mozilla\n", "[App]\nName=/foreign\nVendor=Mozilla\n",
      "[App]\nName=one\nName=two\nVendor=Mozilla\n", "[App]\nName=one\nVendor=\n",
    ])
  func invalidMozillaMetadata(ini: String) throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    _ = try fixture.mozilla()
    try fixture.write(fixture.app + "/Contents/Resources/application.ini", ini)
    let result = fixture.discover()
    #expect(result.evidence.isEmpty && result.issues.contains { $0.reason == .invalidMetadata })
  }

  @Test("Mozilla crash-report-only directories remain named unsupported data")
  func mozillaMissingShape() throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    _ = try fixture.mozilla()
    try fixture.directory(fixture.dataPath + "/Crash Reports")
    let result = fixture.discover()
    #expect(result.evidence.count == 1 && !result.complete)
    #expect(result.issues.contains { $0.path == fixture.dataPath && $0.reason == .missingDataShape })
  }

  @Test("Mozilla empty listed profiles do not hide a complete native profile")
  func mozillaEmptyListedProfile() throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    let root = try fixture.mozilla(
      profilesINI: "[Profile0]\nIsRelative=1\nPath=Profiles/qa.default\n[Profile1]\nIsRelative=1\nPath=Profiles/empty\n"
    )
    try fixture.directory(root + "/Profiles/empty")
    let result = fixture.discover()
    #expect(result.complete && result.evidence.count == 1)
    let evidence = try #require(result.evidence.first)
    try evidence.validate()
    try fixture.write(root + "/Profiles/empty/prefs.js", "// New profile.")
    #expect(throws: (any Error).self) { try evidence.validate() }
  }

  @Test("The same package proof can validate a relocation only with unchanged root and artifacts")
  func relocatedPackage() throws {
    let fixture = try FrameworkFixture()
    defer { fixture.cleanup() }
    try fixture.electron()
    let evidence = try #require(fixture.discover().evidence.first)
    let moved = fixture.home + "/Moved/" + fixture.name + ".app"
    try fixture.directory(fixture.home + "/Moved")
    try FileManager.default.moveItem(atPath: fixture.app, toPath: moved)
    try evidence.validate(relocatedPackagePath: moved)
    #expect(throws: (any Error).self) { try evidence.validate() }
    try fixture.write(moved + "/Contents/Resources/app/package.json", "{\"name\":\"foreign\"}")
    #expect(throws: (any Error).self) { try evidence.validate(relocatedPackagePath: moved) }
  }
}
