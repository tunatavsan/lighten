import Foundation
import Testing

@testable import LightenKit

@Suite("Available uninstall plans")
struct AvailableUninstallPlanTests {
  @Test("A mixed uninstall keeps good data in one plan and names the refused data")
  func partialUninstallOutcome() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let service = fixture.service { _ in ApplicationSigningMetadata(teamID: nil, groupIdentifiers: [fixture.groupID]) }
    let app = try #require(service.application(at: fixture.app))
    let candidates = await service.discover(for: app)
    let cache = try #require(candidates.first { $0.path == fixture.cache })
    let group = try #require(candidates.first { $0.path == fixture.group })
    try FileManager.default.removeItem(atPath: fixture.cache)
    let outcome = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [cache, group])
    let plan = try #require(outcome.plan)
    #expect(plan.items.map(\.sourcePath) == [fixture.group, fixture.app])
    #expect(outcome.rejections.count == 1)
    #expect(outcome.rejections[0].path == fixture.cache)
    #expect(outcome.rejections[0].reason == .changedSinceScan)
    let dataOnly = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [group], includePackage: false)
    #expect(dataOnly.plan?.items.map(\.sourcePath) == [fixture.group])
    let unknown = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"], writeVerifiedReceipts: false,
      packageActivity: { _ in ApplicationActivity(state: .unknown) })
    let refused = await unknown.makeAvailableUninstallPlan(app: app, selectedRelated: [group], includePackage: false)
    #expect(refused.plan == nil)
    #expect(refused.rejections == [PlanRejection(.activityUnavailable, path: fixture.app)])
  }

  @Test("An iOS wrapper cannot create package or data-only uninstall plans")
  func wrapperIsRefused() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let wrapper = fixture.home + "/Applications/LightenQA-wrapper.app"
    let inner = wrapper + "/Wrapper/LightenQA-inner.app"
    try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": fixture.bundleID], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: inner + "/Info.plist"))
    let service = fixture.service { _ in nil }
    let app = InstalledApplication(bundleID: fixture.bundleID, path: wrapper, version: nil)
    for includePackage in [true, false] {
      let result = await service.makeAvailableUninstallPlan(
        app: app, selectedRelated: [], includePackage: includePackage)
      #expect(result.plan == nil)
      #expect(result.rejections == [PlanRejection(.unavailable, path: wrapper, ruleID: "ios-wrapper")])
    }
  }
  @Test("A linked application refuses its package and all data-only choices")
  func linkedApplicationIsRefused() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let link = fixture.home + "/Applications/LightenQA-link.app"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fixture.app)
    let service = fixture.service { _ in nil }
    let app = InstalledApplication(bundleID: fixture.bundleID, path: link, version: nil, linkTarget: fixture.app)
    for includePackage in [true, false] {
      let result = await service.makeAvailableUninstallPlan(
        app: app, selectedRelated: [], includePackage: includePackage)
      #expect(result.plan == nil)
      #expect(result.rejections == [PlanRejection(.symbolicLinkRoot, path: link)])
    }
  }

}
