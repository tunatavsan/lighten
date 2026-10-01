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
    let named = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"], writeVerifiedReceipts: false,
      packageActivity: { _ in ApplicationActivity(state: .unknown, processNames: ["LightenQA-unreadable-census"]) })
    let detailed = await named.makeAvailableUninstallPlan(app: app, selectedRelated: [group], includePackage: false)
    #expect(detailed.plan == nil)
    #expect(
      detailed.rejections == [
        PlanRejection(.activityUnavailable, path: fixture.app, ruleID: "LightenQA-unreadable-census")
      ])
  }

  @Test(
    "A native wrapper supports measured package and data-only plans while owner and metadata ambiguity still refuse")
  func wrapperPlansUseNativeMetadata() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let wrapper = fixture.home + "/Applications/LightenQA-wrapper.app"
    let inner = wrapper + "/Wrapper/LightenQA-inner.app"
    try FileManager.default.createDirectory(atPath: wrapper + "/Wrapper", withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: fixture.app, toPath: inner)
    try FileManager.default.moveItem(atPath: inner + "/Contents/Info.plist", toPath: inner + "/Info.plist")
    let service = fixture.service { _ in nil }
    let app = try #require(service.application(at: wrapper))
    let cache = try #require(
      (await service.initialReview(for: app, progress: nil)).candidates.first { $0.path == fixture.cache })
    let packageOnly = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [])
    let packagePlan = try #require(packageOnly.plan)
    let package = try #require(packagePlan.items.first)
    #expect(packageOnly.rejections.isEmpty && packageOnly.plan?.items.count == 1)
    #expect(package.sourcePath == wrapper && package.policy == .wholeBundle)
    #expect(package.applicationPackageObservation?.infoRelativePath == "Wrapper/LightenQA-inner.app/Info.plist")
    #expect(package.observedSize?.logical?.knownLowerBound ?? 0 > 0)
    #expect(await service.validatePlan(packagePlan).isEmpty)
    let noSelection = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [], includePackage: false)
    #expect(noSelection.plan == nil && noSelection.rejections.isEmpty)
    let dataOnly = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [cache], includePackage: false)
    let data = try #require(dataOnly.plan)
    #expect(dataOnly.rejections.isEmpty && data.items.map(\.sourcePath) == [fixture.cache])
    #expect(data.items[0].installedRelatedProof?.appPath == wrapper)
    #expect(
      data.items[0].installedRelatedProof?.infoIdentity
        == (try DescriptorFileSystem.identity(at: inner + "/Info.plist")))
    #expect(await service.validatePlan(data).isEmpty)
    let second = fixture.home + "/Applications/LightenQA-second-wrapper.app"
    try FileManager.default.copyItem(atPath: wrapper, toPath: second)
    let shared = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [cache], includePackage: false)
    #expect(
      shared.plan == nil && shared.rejections.contains { $0.path == fixture.cache && $0.ruleID == "ambiguousOwner" })
    #expect(
      shared.refusalEvidence.contains {
        $0.reason == .sharedInstalledOwners && Set($0.ownerPaths) == [wrapper, second]
      })
    try FileManager.default.removeItem(atPath: second)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "qa.lighten.changed." + UUID().uuidString], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: inner + "/Info.plist"))
    #expect(!(await service.validatePlan(packagePlan)).isEmpty)
    #expect(!(await service.validatePlan(data)).isEmpty)
    let stale = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [cache])
    #expect(stale.plan == nil && stale.rejections.contains { $0.reason == .changedSinceScan })
    let ambiguous = wrapper + "/Wrapper/LightenQA-second-inner.app"
    try FileManager.default.createDirectory(atPath: ambiguous, withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": fixture.bundleID], format: .xml, options: 0
    )
    .write(to: URL(fileURLWithPath: ambiguous + "/Info.plist"))
    let invalid = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [cache], includePackage: false)
    #expect(invalid.plan == nil)
    #expect(invalid.rejections.contains { $0.reason == .missingMetadata && $0.ruleID == "application-wrapper-layout" })
  }

  @Test("A native application link shares a physical package plan and retains actual data-only and retarget refusals")
  func linkedApplicationPlansUseFreshPhysicalOwner() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let link = fixture.home + "/Applications/LightenQA-link.app"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fixture.app)
    let service = fixture.service { _ in nil }
    let app = try #require(service.application(at: link))
    let cache = try #require(
      (await service.initialReview(for: app, progress: nil)).candidates.first { $0.path == fixture.cache })
    let packageOnly = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [])
    let pair = try #require(packageOnly.plan)
    #expect(packageOnly.rejections.isEmpty && pair.items.count == 2)
    let physical = try #require(pair.items.first { $0.policy == .wholeBundle })
    let leaf = try #require(pair.items.first { $0.policy == .applicationLink })
    #expect(physical.sourcePath == fixture.app && leaf.sourcePath == link)
    #expect(leaf.packageLinkTargetItemID == physical.id)
    #expect(physical.observedSize?.logical?.knownLowerBound ?? 0 > 0)
    #expect(await service.validatePlan(pair).isEmpty)
    let noSelection = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [], includePackage: false)
    #expect(noSelection.plan == nil && noSelection.rejections.isEmpty)
    let dataOnly = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [cache], includePackage: false)
    let data = try #require(dataOnly.plan)
    #expect(dataOnly.rejections.isEmpty && data.items.map(\.sourcePath) == [fixture.cache])
    #expect(data.items[0].installedRelatedProof?.appPath == fixture.app)
    #expect(await service.validatePlan(data).isEmpty)
    let other = fixture.home + "/Shared/LightenQA-retarget.app"
    try FileManager.default.createDirectory(atPath: fixture.home + "/Shared", withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: fixture.app, toPath: other)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "qa.lighten.other." + UUID().uuidString], format: .xml, options: 0
    )
    .write(to: URL(fileURLWithPath: other + "/Contents/Info.plist"))
    try FileManager.default.removeItem(atPath: link)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: other)
    let refusedPair = await service.validatePlan(pair)
    #expect(refusedPair.contains { $0.path == link } && refusedPair.contains { $0.path == fixture.app })
    #expect(!(await service.validatePlan(data)).isEmpty)
    let retargeted = await service.makeAvailableUninstallPlan(app: app, selectedRelated: [cache])
    #expect(retargeted.plan == nil && retargeted.rejections.contains { $0.reason == .changedSinceScan })
    #expect(FileManager.default.fileExists(atPath: fixture.app) && FileManager.default.fileExists(atPath: other))
  }

}
