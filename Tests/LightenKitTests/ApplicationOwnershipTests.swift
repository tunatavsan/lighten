import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private func ownerFixture() throws -> String {
  let resolved = try #require(realpath("/tmp", nil))
  defer { free(resolved) }
  let root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  return root
}

private func ownerApp(_ path: String, id: String) throws {
  try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
  try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
}

@Suite("Application-group ownership")
struct ApplicationOwnershipTests {
  @Test("An unverifiable second owner cannot authorize group removal")
  func unknownSecondOwner() async throws {
    let home = try ownerFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let apps = home + "/Applications"
    let chosen = apps + "/LightenQA-selected.app"
    let unknown = apps + "/LightenQA-unknown.app"
    try ownerApp(chosen, id: "qa.lighten.selected")
    try ownerApp(unknown, id: "qa.lighten.unknown")
    let domain = "group.qa.lighten.shared"
    let group = RelatedLocation.groupContainers.path(domain: domain, homeDirectory: home)
    try FileManager.default.createDirectory(atPath: group, withIntermediateDirectories: true)
    let service = RelatedDataService(
      homeDirectory: home, applicationRoots: [apps], writeVerifiedReceipts: false,
      signingMetadata: { path in
        path == unknown ? nil : ApplicationSigningMetadata(teamID: nil, groupIdentifiers: [domain])
      }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
    let app = try #require(service.application(at: chosen))
    let candidate = try #require((await service.discover(for: app)).first { $0.path == group })
    #expect(candidate.classification == .shared)
    #expect(candidate.reason == .ownershipUnavailable)
    #expect(!candidate.canSelect && !candidate.defaultSelected)
    #expect(throws: RelatedFailure.self) { try service.planInstalled(app: app, candidate: candidate) }
  }

  @Test(
    "System and another package's extension count as independent owners",
    arguments: ["system", "extension", "login", "helper"])
  func anotherOwner(_ variant: String) async throws {
    let home = try ownerFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let apps = home + "/Applications"
    let system = home + "/System/Applications"
    let chosen = apps + "/LightenQA-selected.app"
    let other = (variant == "system" ? system : apps) + "/LightenQA-other.app"
    try ownerApp(chosen, id: "qa.lighten.selected")
    try ownerApp(other, id: "qa.lighten.other")
    let claimed =
      switch variant {
      case "extension": other + "/Contents/PlugIns/LightenQA-extension.appex"
      case "login": other + "/Contents/Library/LoginItems/LightenQA-login.app"
      case "helper": other + "/Contents/Helpers/LightenQA-helper.app"
      default: other
      }
    if claimed != other { try ownerApp(claimed, id: "qa.lighten.inner") }
    let domain = "group.qa.lighten.shared"
    let group = RelatedLocation.groupContainers.path(domain: domain, homeDirectory: home)
    try FileManager.default.createDirectory(atPath: group, withIntermediateDirectories: true)
    let service = RelatedDataService(
      homeDirectory: home, applicationRoots: [apps], ownershipApplicationRoots: [apps, system],
      writeVerifiedReceipts: false,
      signingMetadata: { path in
        ApplicationSigningMetadata(teamID: nil, groupIdentifiers: path == chosen || path == claimed ? [domain] : [])
      }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
    let app = try #require(service.application(at: chosen))
    let inventory = service.inventory()
    #expect(inventory.ownershipCandidates.contains { $0.path == claimed && $0.packagePath == other })
    let candidate = try #require((await service.discover(for: app)).first { $0.path == group })
    #expect(candidate.classification == .shared && !candidate.canSelect && !candidate.defaultSelected)
    #expect(candidate.reason == .sharedGroup)
    #expect(throws: RelatedFailure.self) { try service.planInstalled(app: app, candidate: candidate) }
  }

  @Test("A selected package and its own extension form one owner without preselection")
  func ownExtensionIsOneOwner() async throws {
    let home = try ownerFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let apps = home + "/Applications"
    let chosen = apps + "/LightenQA-selected.app"
    let nested = chosen + "/Contents/PlugIns/LightenQA-extension.appex"
    try ownerApp(chosen, id: "qa.lighten.selected")
    try ownerApp(nested, id: "qa.lighten.inner")
    let domain = "group.qa.lighten.owned"
    let group = RelatedLocation.groupContainers.path(domain: domain, homeDirectory: home)
    try FileManager.default.createDirectory(atPath: group, withIntermediateDirectories: true)
    let service = RelatedDataService(
      homeDirectory: home, applicationRoots: [apps], writeVerifiedReceipts: false,
      signingMetadata: { _ in ApplicationSigningMetadata(teamID: nil, groupIdentifiers: [domain]) },
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
    let app = try #require(service.application(at: chosen))
    let candidate = try #require((await service.discover(for: app)).first { $0.path == group })
    #expect(candidate.classification == .installed && candidate.canSelect)
    #expect(!candidate.defaultSelected)
    #expect(try service.planInstalled(app: app, candidate: candidate).items[0].policy == .relatedGroupContainer)
  }

  @Test("Apple group data remains report-only even with one verified owner")
  func appleGroupIsNeverEligible() async throws {
    let home = try ownerFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let apps = home + "/Applications"
    let chosen = apps + "/LightenQA-selected.app"
    try ownerApp(chosen, id: "qa.lighten.selected")
    let domain = "group.com.apple.tipsnext"
    let group = RelatedLocation.groupContainers.path(domain: domain, homeDirectory: home)
    try FileManager.default.createDirectory(atPath: group, withIntermediateDirectories: true)
    let service = RelatedDataService(
      homeDirectory: home, applicationRoots: [apps], writeVerifiedReceipts: false,
      signingMetadata: { _ in ApplicationSigningMetadata(teamID: nil, groupIdentifiers: [domain]) },
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
    let app = try #require(service.application(at: chosen))
    let candidate = try #require((await service.discover(for: app)).first { $0.path == group })
    #expect(candidate.classification == .shared && !candidate.canSelect && !candidate.defaultSelected)
    #expect(throws: RelatedFailure.self) { try service.planInstalled(app: app, candidate: candidate) }
  }
  @Test("Descriptor traversal retains native and linked owners while ignoring only dangling links")
  func descriptorTraversalRetainsCoverage() throws {
    let home = try ownerFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let apps = home + "/Applications"
    let chosen = apps + "/LightenQA-selected.app"
    try ownerApp(chosen, id: "qa.lighten.selected")
    let helpers = chosen + "/Contents/Helpers"
    try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
    let native = helpers + "/LightenQA-native"
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: native)
    try Data("plain data".utf8).write(to: URL(fileURLWithPath: helpers + "/record"))
    let other = home + "/System/Applications/LightenQA-other.app"
    try ownerApp(other, id: "qa.lighten.other")
    let otherHelper = other + "/Contents/LightenQA-native"
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: otherHelper)
    let linked = helpers + "/LightenQA-linked.app"
    #expect(symlink(other, linked) == 0)
    let owners = ApplicationOwnershipInventory.collect(roots: [apps], applications: [])
    #expect(owners.complete)
    #expect(
      owners.candidates
        == [
          ApplicationOwnerCandidate(path: chosen, packagePath: chosen),
          ApplicationOwnerCandidate(path: native, packagePath: chosen),
          ApplicationOwnerCandidate(path: other, packagePath: other),
          ApplicationOwnerCandidate(path: otherHelper, packagePath: other),
        ].sorted { $0.path < $1.path })
    #expect(symlink(home + "/missing", helpers + "/LightenQA-unresolved") == 0)
    #expect(ApplicationOwnershipInventory.collect(roots: [apps], applications: []).complete)
    let loop = helpers + "/LightenQA-loop"
    #expect(symlink(loop, loop) == 0)
    let unresolved = ApplicationOwnershipInventory.collect(roots: [apps], applications: [])
    #expect(!unresolved.complete)
    #expect(unresolved.issues.contains { $0.path == loop && $0.code == ELOOP })
  }

  @Test("Non-executable resources never receive a native-header read")
  func nativeHeaderReadsOnlyExecutableFiles() throws {
    let home = try ownerFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let app = home + "/Applications/LightenQA-selected.app"
    try ownerApp(app, id: "qa.lighten.selected")
    let native = app + "/Contents/LightenQA-native"
    let resource = app + "/Contents/LightenQA-resource"
    let magic = Data([0xcf, 0xfa, 0xed, 0xfe])
    try magic.write(to: URL(fileURLWithPath: native))
    try magic.write(to: URL(fileURLWithPath: resource))
    #expect(chmod(native, 0o755) == 0 && chmod(resource, 0o644) == 0)
    let reads = Mutex<[String]>([])
    let owners = ApplicationOwnershipInventory.collect(
      roots: [home + "/Applications"], applications: [],
      onNativeRead: { path in reads.withLock { $0.append(path) } })
    #expect(owners.complete)
    #expect(reads.withLock { $0 } == [native])
    #expect(owners.candidates.contains { $0.path == native })
    #expect(!owners.candidates.contains { $0.path == resource })
  }

  @Test("A real unreadable third-party directory preserves its scoped errno without blocking exact-ID data")
  func unreadableOwnershipIsScoped() async throws {
    let home = try ownerFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let apps = home + "/Applications"
    let appPath = apps + "/LightenQA-selected.app"
    try ownerApp(appPath, id: "qa.lighten.selected")
    let unreadable = home + "/Library/Helpers/LightenQA-unreadable"
    try FileManager.default.createDirectory(atPath: unreadable, withIntermediateDirectories: true)
    #expect(chmod(unreadable, 0) == 0)
    defer { _ = chmod(unreadable, 0o700) }
    let cache = RelatedLocation.caches.path(domain: "qa.lighten.selected", homeDirectory: home)
    try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    let service = RelatedDataService(
      homeDirectory: home, applicationRoots: [apps], ownershipApplicationRoots: [apps, unreadable],
      writeVerifiedReceipts: false, signingMetadata: { _ in nil },
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
    let inventory = service.inventory()
    #expect(inventory.complete && !inventory.ownershipComplete)
    #expect(inventory.ownershipIssues.contains { $0.path == unreadable && $0.code == EACCES && !$0.systemScope })
    let app = try #require(service.application(at: appPath))
    let candidate = try #require((await service.discover(for: app)).first { $0.path == cache })
    #expect(candidate.defaultSelected)
    #expect(try service.planInstalled(app: app, candidate: candidate).items.count == 1)
  }

  @Test("System uncertainty does not poison third-party group ownership")
  func systemFailureIsSeparateFromThirdParty() throws {
    let home = try ownerFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let chosen = home + "/Applications/LightenQA-selected.app"
    try ownerApp(chosen, id: "qa.lighten.selected")
    let groupID = "group.qa.lighten.owned"
    let service = RelatedDataService(
      homeDirectory: home, applicationRoots: [home + "/Applications"], writeVerifiedReceipts: false,
      signingMetadata: { _ in ApplicationSigningMetadata(teamID: nil, groupIdentifiers: [groupID]) })
    let app = try #require(service.application(at: chosen))
    let owners = ApplicationOwnershipInventory(
      candidates: [ApplicationOwnerCandidate(path: chosen, packagePath: chosen)], complete: false,
      issues: [ApplicationOwnershipIssue(path: "/System/Library/CoreServices/unreadable", code: EACCES)], roots: [:],
      directories: [:])
    #expect(owners.thirdPartyComplete)
    let inventory = BundleInventory(
      applications: [app], unidentifiedPaths: [], complete: true, observedAt: Date(),
      ownershipCandidates: owners.candidates, ownershipComplete: owners.thirdPartyComplete,
      ownershipIssues: owners.issues)
    #expect(
      service.installedPolicy(
        app: app,
        relatedPath: RelatedLocation.groupContainers.path(
          domain: groupID, homeDirectory: home), inventory: inventory) == .relatedGroupContainer)
  }

  @Test("Launch plist executable leads include code outside the enumerated roots")
  func launchProgramLeadAddsOwner() throws {
    let home = try ownerFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let agents = home + "/Library/LaunchAgents"
    try FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
    let program = home + "/LightenQA-helper"
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: program)
    try PropertyListSerialization.data(
      fromPropertyList: ["ProgramArguments": [program, "1"]], format: .xml, options: 0
    )
    .write(to: URL(fileURLWithPath: agents + "/qa.lighten.helper.plist"))
    let inventory = ApplicationOwnershipInventory.collect(roots: [agents], applications: [])
    #expect(inventory.complete)
    #expect(inventory.candidates == [ApplicationOwnerCandidate(path: program, packagePath: program)])
  }

  @Test(
    "Actual System code-owner traversal ignores stock dangling links",
    .enabled(
      if: ProcessInfo.processInfo.environment["CI"] == nil,
      "The local acceptance gate reads this Mac's real System tree; CI has a different immutable image."))
  func actualSystemDanglingLinksReadOnly() {
    let inventory = ApplicationOwnershipInventory.collect(roots: ["/System/Library/CoreServices"], applications: [])
    #expect(inventory.complete)
    #expect(!inventory.candidates.isEmpty)
    #expect(!inventory.issues.contains { $0.code == ENOENT })
  }

}
