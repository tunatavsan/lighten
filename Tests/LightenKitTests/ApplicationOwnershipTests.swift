import Darwin
import Foundation
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
}
