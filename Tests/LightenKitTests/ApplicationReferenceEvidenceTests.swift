import Darwin
import Foundation
import Testing

@testable import LightenKit

private struct ReferenceFixture {
  let home: String
  let app: String
  let bundleID: String
  let executable: String
  let cache: String
  let temporary: String

  init() throws {
    let physical = try #require(realpath("/tmp", nil))
    defer { free(physical) }
    let token = UUID().uuidString
    home = String(cString: physical) + "/LightenQA-" + token
    app = home + "/Applications/LightenQA-" + token + ".app"
    bundleID = "qa.lighten." + token
    executable = "LightenQA-" + token
    cache = home + "/native/C"
    temporary = home + "/native/T"
    try package(app, id: bundleID, executable: executable)
    try directory(cache)
    try directory(temporary)
  }

  var crashParent: String { home + "/Library/Application Support/CrashReporter" }
  var recentParent: String {
    home + "/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
  }
  var crash: String { crashParent + "/" + executable + "_" + UUID().uuidString + ".plist" }
  var installed: InstalledApplication { InstalledApplication(bundleID: bundleID, path: app, version: nil) }

  func directory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }

  func write(_ path: String, value: String = "fixture") throws {
    try directory((path as NSString).deletingLastPathComponent)
    try Data(value.utf8).write(to: URL(fileURLWithPath: path))
  }

  func package(_ path: String, id: String, executable: String?) throws {
    try directory(path + "/Contents")
    var info = ["CFBundleIdentifier": id, "CFBundleName": "LightenQA"]
    if let executable {
      info["CFBundleExecutable"] = executable
      try write(path + "/Contents/MacOS/" + executable)
    }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
  }

  func helper(id: String? = nil, executable: String? = nil) throws -> String {
    let path = app + "/Contents/Frameworks/LightenQA-helper.app"
    try package(path, id: id ?? bundleID + ".helper", executable: executable ?? self.executable + " Helper")
    return path
  }

  func discover(
    signing: @Sendable (String) -> ApplicationSigningMetadata? = { _ in nil }
  ) -> ApplicationReferenceDiscovery {
    ApplicationReferenceEvidenceProducer.discover(
      app: installed, homeDirectory: home,
      directories: ApplicationReferenceDirectories(cache: cache, temporary: temporary),
      signingMetadata: signing)
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: home) }
}

enum ReferenceArtifactMutation: String, CaseIterable, Sendable {
  case data, info, executable, root
}

@Suite("Exact native application data references")
struct ApplicationReferenceEvidenceTests {
  @Test("Crash, recent-list and native roots produce exact leaf observations")
  func exactLeaves() throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let crash = fixture.crash
    let recent = fixture.recentParent + "/" + fixture.bundleID.lowercased() + ".sfl4"
    try fixture.write(crash)
    try fixture.write(recent)
    try fixture.directory(fixture.cache + "/" + fixture.bundleID)
    try fixture.directory(fixture.temporary + "/" + fixture.bundleID)
    let discovery = fixture.discover()
    #expect(discovery.issues.isEmpty)
    #expect(
      Set(discovery.claims.map(\.dataPath)) == [
        crash, recent, fixture.cache + "/" + fixture.bundleID, fixture.temporary + "/" + fixture.bundleID,
      ])
    let physicalLeaves = try discovery.claims.map { claim in
      let identity = try DescriptorFileSystem.identity(at: claim.dataPath)
      return String(identity.device) + ":" + String(identity.inode)
    }
    #expect(Set(physicalLeaves).count == discovery.claims.count)
    for claim in discovery.claims {
      #expect(claim.sourcePath == fixture.app + "/Contents/Info.plist")
      #expect(claim.ownerBundleID == fixture.bundleID)
      #expect(claim.matchStrength == (claim.dataPath == crash ? .weak : .strong))
      #expect(claim.kind == (claim.dataPath == crash ? .executableName : .bundleIdentifier))
      #expect(claim.references.contains(fixture.app + "/Contents/MacOS/" + fixture.executable))
      try claim.validate()
      try claim.validateBinding(to: fixture.installed)
      let other = InstalledApplication(bundleID: "qa.lighten.other", path: fixture.app, version: nil)
      #expect(throws: (any Error).self) { try claim.validateBinding(to: other) }
    }
    let cache = ApplicationDataEvidenceCache()
    let bridged = cache.discover(
      app: fixture.installed, home: fixture.home,
      liveData: { ApplicationLiveDataObservation(records: [], complete: true) })
    let retained = try #require(bridged.evidence.first { $0.dataPath == recent })
    #expect(retained.matchStrength == .strong)
    try fixture.write(fixture.recentParent + "/qa.lighten.other.sfl4")
    try retained.validate()
    for source in bridged.sources { try source.validate() }
    let newCrash = fixture.crash
    try fixture.write(newCrash)
    let refreshed = cache.discover(
      app: fixture.installed, home: fixture.home,
      liveData: { ApplicationLiveDataObservation(records: [], complete: true) })
    #expect(refreshed.evidence.contains { $0.dataPath == newCrash })
    try fixture.package(fixture.app, id: "qa.lighten.changed", executable: fixture.executable)
    #expect(throws: (any Error).self) { try retained.validate() }
  }

  @Test(
    "Unrelated namespace siblings retain proof but invalidate discovery generations",
    arguments: [
      "cache", "temporary", "crash", "recent",
    ])
  func namespaceSiblingGrowth(namespace: String) throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let parent: String
    let path: String
    switch namespace {
    case "cache":
      parent = fixture.cache
      path = parent + "/" + fixture.bundleID
      try fixture.directory(path)
    case "temporary":
      parent = fixture.temporary
      path = parent + "/" + fixture.bundleID
      try fixture.directory(path)
    case "crash":
      parent = fixture.crashParent
      path = fixture.crash
      try fixture.write(path)
    default:
      parent = fixture.recentParent
      path = parent + "/" + fixture.bundleID.lowercased() + ".sfl4"
      try fixture.write(path)
    }
    let discovery = fixture.discover()
    let claim = try #require(discovery.claims.first { $0.dataPath == path })
    let source = try #require(discovery.sources.first { $0.path == parent })
    let census = try #require(discovery.censusSources.first { $0.path == parent })
    try fixture.write(parent + "/LightenQA-other")
    try claim.validate()
    try source.validate()
    #expect(throws: (any Error).self) { try census.validate() }
  }

  @Test(
    "Stable namespace observations reject type, link, owner and flags changes",
    arguments: [
      "file", "symlink", "owner", "flags",
    ])
  func namespaceGuards(change: String) throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let path = fixture.cache + "/" + fixture.bundleID
    try fixture.directory(path)
    let discovery = fixture.discover()
    let claim = try #require(discovery.claims.first { $0.dataPath == path })
    let source = try #require(discovery.sources.first { $0.path == fixture.cache })
    if change == "owner" {
      let foreign = ApplicationPathObservation(
        path: "/Library", identity: try DescriptorFileSystem.identity(at: "/Library"),
        namespaceOwnerID: geteuid())
      #expect(throws: (any Error).self) { try foreign.validate() }
      return
    }
    if change == "flags" {
      #expect(chflags(fixture.cache, UInt32(UF_HIDDEN)) == 0)
    } else {
      let moved = fixture.cache + ".old"
      try FileManager.default.moveItem(atPath: fixture.cache, toPath: moved)
      if change == "file" {
        try fixture.write(fixture.cache)
      } else {
        try FileManager.default.createSymbolicLink(atPath: fixture.cache, withDestinationPath: moved)
      }
    }
    #expect(throws: (any Error).self) { try claim.validate() }
    #expect(throws: (any Error).self) { try source.validate() }
  }

  @Test("Names, suffix guesses and another app's exact ID never produce observations")
  func rejectsBroadMatches() throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    try fixture.write(fixture.crashParent + "/" + fixture.executable + " Helper_" + UUID().uuidString + ".plist")
    try fixture.write(fixture.crashParent + "/" + fixture.executable + "_not-a-uuid.plist")
    try fixture.write(fixture.crashParent + "/prefix" + fixture.executable + "_" + UUID().uuidString + ".plist")
    try fixture.write(fixture.recentParent + "/" + fixture.bundleID + ".other.sfl4")
    try fixture.directory(fixture.cache + "/" + fixture.bundleID + ".helper")
    try fixture.directory(fixture.temporary + "/" + fixture.bundleID + ".ShipIt.random")
    #expect(fixture.discover().claims.isEmpty)
  }

  @Test(
    "Embedded helper metadata requires a same-team signature and a literal parent identifier",
    arguments: [
      "same", "different", "unsigned", "generic", "foreign", "hyphen",
    ])
  func helperOwnership(mode: String) throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let id =
      mode == "generic"
      ? "com.github.Electron.helper"
      : mode == "foreign"
        ? "qa.lighten.foreign.helper" : fixture.bundleID + (mode == "hyphen" ? "-gpu-helper" : ".helper")
    let helper = try fixture.helper(id: id)
    let path = fixture.cache + "/" + id
    try fixture.directory(path)
    let package = fixture.app
    let discovery = fixture.discover { source in
      if mode == "unsigned" { return nil }
      let team = mode == "different" && source == helper ? "OTHER" : "TESTTEAM"
      return ApplicationSigningMetadata(teamID: team, groupIdentifiers: [])
    }
    let accepted = mode == "same" || mode == "hyphen"
    #expect(discovery.claims.contains { $0.dataPath == path } == accepted)
    if accepted {
      let claim = try #require(discovery.claims.first { $0.dataPath == path })
      #expect(claim.ownerBundleID == id && claim.matchStrength == .strong)
      #expect(claim.sourcePath == helper + "/Contents/Info.plist")
      #expect(claim.references.contains(package + "/Contents/Info.plist"))
      #expect(claim.references.contains(helper + "/Contents/MacOS/" + fixture.executable + " Helper"))
      try claim.validate()
    }
  }

  @Test(
    "Only actual helper packages in fixed native bundle locations supply IDs",
    arguments: [
      "Contents/MacOS/LightenQA-gpu.app", "Contents/PlugIns/LightenQA-extension.appex",
      "Contents/XPCServices/LightenQA-service.xpc",
    ])
  func helperLocations(relative: String) throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let helper = fixture.app + "/" + relative
    let id = fixture.bundleID + "-helper"
    try fixture.package(helper, id: id, executable: "LightenQA-helper")
    let path = fixture.cache + "/" + id
    try fixture.directory(path)
    let discovery = fixture.discover { _ in ApplicationSigningMetadata(teamID: "TESTTEAM", groupIdentifiers: []) }
    let claim = try #require(discovery.claims.first { $0.dataPath == path })
    #expect(claim.ownerBundleID == id)
    #expect(claim.sourcePath == helper + "/Contents/Info.plist")
    try claim.validate()
  }

  @Test("Previously absent signature artifacts remain private validation observations")
  func signatureAbsenceInvalidation() throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let helper = try fixture.helper()
    let path = fixture.cache + "/" + fixture.bundleID + ".helper"
    try fixture.directory(path)
    let discovery = fixture.discover { _ in ApplicationSigningMetadata(teamID: "TESTTEAM", groupIdentifiers: []) }
    let claim = try #require(discovery.claims.first { $0.dataPath == path })
    #expect(claim.sourceObservations.contains { $0.path == helper + "/Contents/_CodeSignature" && $0.identity == nil })
    try fixture.directory(helper + "/Contents/_CodeSignature")
    #expect(throws: (any Error).self) { try claim.validate() }
  }

  @Test("Relocation retains package-bound metadata and helper signature observations")
  func relocatedPackageValidation() throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    _ = try fixture.helper()
    let path = fixture.cache + "/" + fixture.bundleID + ".helper"
    try fixture.directory(path)
    let discovery = fixture.discover { _ in ApplicationSigningMetadata(teamID: "TESTTEAM", groupIdentifiers: []) }
    let claim = try #require(discovery.claims.first { $0.dataPath == path })
    let moved = fixture.home + "/LightenQA-moved.app"
    try FileManager.default.moveItem(atPath: fixture.app, toPath: moved)
    try claim.validate(relocatedPackagePath: moved)
    try fixture.package(
      moved + "/Contents/Frameworks/LightenQA-helper.app", id: "qa.lighten.changed", executable: "changed")
    #expect(throws: (any Error).self) { try claim.validate(relocatedPackagePath: moved) }
  }

  @Test("A verified login item supplies its own recent-list identity")
  func loginItemRecentList() throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let helper = fixture.app + "/Contents/Library/LoginItems/LightenQA-login.app"
    let id = fixture.bundleID + ".startuphelper"
    try fixture.package(helper, id: id, executable: "LightenQA-login")
    let path = fixture.recentParent + "/" + id.lowercased() + ".sfl4"
    try fixture.write(path)
    let discovery = fixture.discover { _ in ApplicationSigningMetadata(teamID: "TESTTEAM", groupIdentifiers: []) }
    let claim = try #require(discovery.claims.first { $0.dataPath == path })
    #expect(claim.sourcePath == helper + "/Contents/Info.plist")
    #expect(claim.ownerBundleID == id && claim.matchStrength == .strong)
  }

  @Test("A missing executable cannot supply a name-based crash leaf")
  func executableMustExist() throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    try fixture.write(fixture.crash)
    try FileManager.default.removeItem(atPath: fixture.app + "/Contents/MacOS/" + fixture.executable)
    let discovery = fixture.discover()
    #expect(discovery.claims.isEmpty)
    #expect(!discovery.issues.isEmpty)
  }

  @Test(
    "Leaf, namespace and metadata replacements invalidate captured evidence",
    arguments: ReferenceArtifactMutation.allCases)
  func staleProof(mutation: ReferenceArtifactMutation) throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let path = fixture.cache + "/" + fixture.bundleID
    try fixture.directory(path)
    let claim = try #require(fixture.discover().claims.first { $0.dataPath == path })
    switch mutation {
    case .data:
      try FileManager.default.moveItem(atPath: path, toPath: path + ".old")
      try fixture.directory(path)
    case .info:
      try fixture.package(fixture.app, id: "qa.lighten.replaced", executable: fixture.executable)
    case .executable:
      try fixture.write(fixture.app + "/Contents/MacOS/" + fixture.executable, value: "changed executable")
    case .root:
      try FileManager.default.moveItem(atPath: fixture.cache, toPath: fixture.cache + ".old")
      try fixture.directory(path)
    }
    #expect(throws: (any Error).self) { try claim.validate() }
  }

  @Test("Native cache and namespace symlinks are never followed", arguments: [false, true])
  func symlinkRejected(namespace: Bool) throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let path = fixture.cache + "/" + fixture.bundleID
    let target = fixture.home + "/LightenQA-target"
    try fixture.directory(target)
    if namespace {
      try FileManager.default.removeItem(atPath: fixture.cache)
      try FileManager.default.createSymbolicLink(atPath: fixture.cache, withDestinationPath: target)
    } else {
      try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }
    let discovery = fixture.discover()
    #expect(discovery.claims.isEmpty)
    #expect(!discovery.issues.isEmpty)
  }

  @Test("Metadata and executable symlinks cannot establish a package identity", arguments: [false, true])
  func packageSymlinks(executable: Bool) throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let path = fixture.cache + "/" + fixture.bundleID
    try fixture.directory(path)
    let source =
      executable ? fixture.app + "/Contents/MacOS/" + fixture.executable : fixture.app + "/Contents/Info.plist"
    let target = fixture.home + "/LightenQA-source"
    try FileManager.default.moveItem(atPath: source, toPath: target)
    try FileManager.default.createSymbolicLink(atPath: source, withDestinationPath: target)
    let discovery = fixture.discover()
    #expect(discovery.claims.isEmpty)
    #expect(!discovery.issues.isEmpty)
  }

  @Test("Hard-linked crash files cannot become observations")
  func hardLinkRejected() throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let path = fixture.crash
    try fixture.write(path)
    #expect(link(path, fixture.home + "/LightenQA-hardlink") == 0)
    let discovery = fixture.discover()
    #expect(discovery.claims.isEmpty)
    #expect(discovery.issues.contains { $0.path == path })
  }

  @Test("Another user's namespace is rejected before any leaf is considered")
  func foreignNamespaceRejected() throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let discovery = ApplicationReferenceEvidenceProducer.discover(
      app: fixture.installed, homeDirectory: fixture.home,
      directories: ApplicationReferenceDirectories(cache: "/Library", temporary: nil))
    #expect(discovery.claims.isEmpty)
    #expect(discovery.issues.contains { $0.path == "/Library" })
  }

  @Test("Absent namespaces remain source observations for cache invalidation")
  func absenceInvalidation() throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let discovery = fixture.discover()
    let absent = try #require(discovery.sources.first { $0.path == fixture.crashParent })
    #expect(absent.identity == nil)
    try fixture.write(fixture.crash)
    #expect(throws: (any Error).self) { try absent.validate() }
  }

  @Test("Two physical packages with one crash executable retain the shared-owner veto")
  func sharedOwnerPipeline() async throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let path = fixture.crash
    try fixture.write(path)
    let second = fixture.home + "/Applications/LightenQA-second.app"
    try fixture.package(second, id: "qa.lighten.second", executable: fixture.executable)
    let related = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"],
      writeVerifiedReceipts: false,
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
    let session = ApplicationDiscovery(related: related).scanSession()
    let candidate = try #require((await session.observedRelatedCandidates()).first { $0.path == path })
    #expect(candidate.classification == .shared && candidate.reason == .sharedInstalledData)
    #expect(!candidate.canSelect)
    #expect(!candidate.automaticSelectionAllowed && !candidate.defaultSelected)
    #expect(!candidate.explicitManualChoiceAvailable)
    #expect(candidate.refusalEvidence.contains { $0.ownerPaths == [fixture.app, second].sorted() })
    await session.cancel()
  }

  @Test("An exact executable filename remains visible for explicit manual choice")
  func crashNameRemainsManual() async throws {
    let fixture = try ReferenceFixture()
    defer { fixture.cleanup() }
    let path = fixture.crash
    try fixture.write(path)
    let related = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"],
      writeVerifiedReceipts: false,
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
    let session = ApplicationDiscovery(related: related).scanSession()
    let candidate = try #require((await session.observedRelatedCandidates()).first { $0.path == path })
    #expect(candidate.classification == .unprovenNameOnly && candidate.reason == .nameOnly)
    #expect(candidate.matchStrength == .weak)
    #expect(candidate.provenance?.kind == .executableName)
    #expect(!candidate.canSelect && !candidate.automaticSelectionAllowed && !candidate.defaultSelected)
    #expect(candidate.explicitManualChoiceAvailable)
    #expect(candidate.snapshot != nil)
    await session.cancel()
  }
}
