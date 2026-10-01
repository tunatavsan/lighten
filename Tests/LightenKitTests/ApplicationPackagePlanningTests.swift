import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private enum PackageLayout: String, CaseIterable, Sendable { case contents, flat, wrapper }

private struct PackageFixture: Sendable {
  let home: String
  let app: String
  let link: String
  let info: String
  let payload: String
  let bundleID: String?
  let layout: PackageLayout

  init(layout: PackageLayout = .contents, identified: Bool = true) throws {
    let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(temporary) }
    let token = UUID().uuidString
    home = String(cString: temporary) + "/LightenQA-" + token
    app = home + "/Physical/LightenQA-" + token + ".app"
    link = home + "/Applications/LightenQA-Link-" + token + ".app"
    bundleID = identified ? "qa.lighten." + token : nil
    self.layout = layout
    switch layout {
    case .contents: info = app + "/Contents/Info.plist"
    case .flat: info = app + "/Info.plist"
    case .wrapper: info = app + "/Wrapper/LightenQA-Inner.app/Info.plist"
    }
    payload = (info as NSString).deletingLastPathComponent + "/Payload.bin"
    try FileManager.default.createDirectory(
      atPath: (info as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: home + "/Applications", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: home + "/Trash", withIntermediateDirectories: true)
    var dictionary: [String: Any] = ["CFBundleName": "LightenQA", "CFBundleVersion": "1"]
    if let bundleID { dictionary["CFBundleIdentifier"] = bundleID }
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
      .write(to: URL(fileURLWithPath: info))
    try Data(repeating: 0x42, count: 65_536).write(to: URL(fileURLWithPath: payload))
  }

  var planner: ApplicationPackagePlanning {
    ApplicationPackagePlanning(
      homeDirectory: home, runningApplications: PackageNotRunning(),
      applicationActivity: FixtureClearApplicationActivity())
  }

  func makeLink(relative: Bool = false) throws {
    let target = relative ? "../Physical/" + (app as NSString).lastPathComponent : app
    guard symlink(target, link) == 0 else { throw FileSystemFailure.systemCall("symlink", errno) }
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: home) }
}

private struct PackageNotRunning: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
}

private struct PackageClearSpaceActivity: SpaceActivitySource {
  func activity(rootPath: String) async -> ProcessActivity { ProcessActivity(state: .clearObservedCurrentUID) }
}

private struct PackageFixedActivity: ApplicationActivitySource {
  let state: ApplicationActivityState
  func activity(applicationPath: String) async -> ApplicationActivity {
    ApplicationActivity(state: state, processNames: ["LightenQA-helper"])
  }
}

private actor PackageLocalTrash: TrashMoving {
  let directory: String
  private var attempts: [String] = []
  init(directory: String) { self.directory = directory }
  func moveToTrash(path: String) async throws -> String {
    attempts.append(path)
    let target = directory + "/" + (path as NSString).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: target)
    return target
  }
  func paths() -> [String] { attempts }
}

private final class PackageNativeTrash: TrashMoving {
  private let moved = Mutex<[String: String]>([:])

  func moveToTrash(path: String) async throws -> String {
    let target = try await Task.detached {
      var returned: NSURL?
      try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &returned)
      guard let returned else { throw FileSystemFailure.invalidPath }
      return (returned as URL).path
    }.value
    moved.withLock { $0[path] = target }
    return target
  }

  func restoreOwnFixtures() {
    for (source, target) in moved.withLock({ $0 }) {
      if MovedApplicationOwner.isAbsent(source), (try? KnownPathFileSystem.identity(at: target)) != nil {
        try? FileManager.default.moveItem(atPath: target, toPath: source)
      }
    }
  }
}

private func packageExecutor(
  fixture: PackageFixture, journal: JSONLActionJournal, trash: any TrashMoving,
  beforeMutation: (@Sendable (PlanItem) async throws -> Void)? = nil
) -> ActionExecutor {
  ActionExecutor(
    journal: journal, trash: trash, guardService: ActionGuard(homeDirectory: fixture.home),
    beforeMutation: beforeMutation, runningApplications: PackageNotRunning(),
    spaceActivity: PackageClearSpaceActivity(), applicationActivity: FixtureClearApplicationActivity())
}

private func copiedPackageItem(
  _ item: PlanItem, observation: ApplicationPackageObservation? = nil, linkTarget: UUID? = nil,
  observedSize: ObservedPlanSize? = nil
) -> PlanItem {
  PlanItem(
    id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID, inventory: item.inventory,
    ancestors: item.ancestors, policy: item.policy, applicationBundleID: item.applicationBundleID,
    nestedApplicationIDs: item.nestedApplicationIDs, snapshotRunID: item.snapshotRunID,
    observedSize: observedSize ?? item.observedSize, sizeMetadataVersion: item.sizeMetadataVersion,
    applicationPackageObservation: observation ?? item.applicationPackageObservation,
    packageLinkTargetItemID: linkTarget ?? item.packageLinkTargetItemID)
}

@Test("Supported layouts have fresh package authority and measured contents", arguments: PackageLayout.allCases)
private func supportedPackageLayoutsHaveCurrentMetadataAndContents(layout: PackageLayout) async throws {
  let fixture = try PackageFixture(layout: layout)
  defer { fixture.cleanup() }
  let built = try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: fixture.bundleID)
  let item = built.physicalPackage
  #expect(item.policy == .wholeBundle && item.applicationBundleID == fixture.bundleID)
  #expect(item.applicationPackageObservation?.infoIdentity == (try DescriptorFileSystem.identity(at: fixture.info)))
  #expect(item.displaySize.logical?.completeTotal ?? 0 > 65_536)
  #expect(item.displaySize.allocated?.completeTotal != nil)
  #expect(built.physicalApplication?.path == fixture.app)
  try ActionGuard(homeDirectory: fixture.home).validate(item)
  let refreshed = try ActionGuard(homeDirectory: fixture.home).refreshedSpaceItem(item)
  #expect(refreshed.applicationPackageObservation == item.applicationPackageObservation)
  #expect(refreshed.observedSize == item.observedSize && refreshed.sizeMetadataVersion == item.sizeMetadataVersion)
}

@Test("An absent identifier remains package-only without a fake application", arguments: PackageLayout.allCases)
private func identifierlessPackagesHaveNoInventedApplication(layout: PackageLayout) async throws {
  let fixture = try PackageFixture(layout: layout, identified: false)
  defer { fixture.cleanup() }
  let built = try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: nil)
  #expect(built.physicalApplication == nil)
  #expect(built.plan.items.count == 1 && built.physicalPackage.applicationBundleID == nil)
  #expect(built.physicalPackage.applicationPackageObservation?.bundleIdentifier == nil)
  #expect(built.physicalPackage.installedRelatedProof == nil && built.physicalPackage.relatedProof == nil)
  #expect(built.physicalPackage.orphanRelatedProof == nil && built.physicalPackage.catalogProof == nil)
  try ActionGuard(homeDirectory: fixture.home).validate(built.physicalPackage)
}

@Test("Only an absent key is identifierless; invalid values refuse", arguments: ["", "bad id", "1000"])
private func invalidPackageIdentifiersDoNotBecomeIdentifierless(identifier: String) async throws {
  let fixture = try PackageFixture(identified: false)
  defer { fixture.cleanup() }
  try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: fixture.info))
  await #expect(throws: (any Error).self) {
    try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: nil)
  }
}

@Test("An unsupported identifier preserves every native package boundary", arguments: PackageLayout.allCases)
private func unsupportedIdentifierRemainsAnOpaquePackage(layout: PackageLayout) async throws {
  let fixture = try PackageFixture(layout: layout, identified: false)
  defer { fixture.cleanup() }
  try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "1000"], format: .xml, options: 0)
    .write(to: URL(fileURLWithPath: fixture.info))
  #expect(ApplicationPackage.isApplication(fixture.app))
  #expect(ScanService.isPackage(fixture.app))
  #expect(ScanService.isInsidePackage(fixture.payload))
  let identity = try DescriptorFileSystem.identity(at: fixture.app)
  #expect(ExactInventory.isOpaquePackage(path: fixture.app, identity: identity, policy: .wholeBundle))
  let observed = try ExactInventory(homeDirectory: fixture.home).collect(rootPath: fixture.app, expected: nil)
  #expect(observed.policy == .wholeBundle && observed.entries.count == 1)
  await #expect(throws: PlanRejection(.missingMetadata, path: fixture.info, ruleID: "application-identifier-invalid")) {
    try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: nil)
  }
}

@Test("Malformed or non-string metadata never becomes an identifierless package", arguments: [false, true])
private func invalidDictionaryDoesNotAuthorizePackage(nonString: Bool) async throws {
  let fixture = try PackageFixture(identified: false)
  defer { fixture.cleanup() }
  let data: Data
  if nonString {
    data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": 123], format: .xml, options: 0)
  } else {
    data = Data("not a property list".utf8)
  }
  try data.write(to: URL(fileURLWithPath: fixture.info))
  await #expect(throws: (any Error).self) {
    try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: nil)
  }
}

@Test("Ambiguous metadata keeps the old Contents boundary without gaining action authority")
private func ambiguousLayoutRetainsItsOpaqueBoundary() async throws {
  let fixture = try PackageFixture()
  defer { fixture.cleanup() }
  try Data(contentsOf: URL(fileURLWithPath: fixture.info)).write(to: URL(fileURLWithPath: fixture.app + "/Info.plist"))
  #expect(ApplicationPackage.isApplication(fixture.app))
  #expect(ScanService.isInsidePackage(fixture.payload))
  let observed = try ExactInventory(homeDirectory: fixture.home).collect(rootPath: fixture.app, expected: nil)
  #expect(observed.policy == .wholeBundle && observed.entries.count == 1)
  await #expect(throws: PlanRejection(.missingMetadata, path: fixture.app, ruleID: "application-layout")) {
    try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: fixture.bundleID)
  }
}

@Test("An extra layout cannot hide a nested protected application's self identifier")
private func ambiguousLayoutCannotHideNestedSelfIdentifier() throws {
  let fixture = try PackageFixture()
  defer { fixture.cleanup() }
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": LightenIdentity.bundleIdentifier], format: .xml, options: 0
  )
  .write(to: URL(fileURLWithPath: fixture.info))
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "qa.lighten.extra"], format: .xml, options: 0
  )
  .write(to: URL(fileURLWithPath: fixture.app + "/Info.plist"))
  #expect(
    try ApplicationPackagePlanning.observedBundleIdentifiers(at: fixture.app).contains(LightenIdentity.bundleIdentifier)
  )
  #expect(throws: PlanRejection(.lightenItself, path: fixture.home + "/Physical")) {
    try ExactInventory(homeDirectory: fixture.home).collect(rootPath: fixture.home + "/Physical", expected: nil)
  }
}

@Test("Normal linked-app plans contain a physical root and a privately bound leaf", arguments: [false, true])
private func linkedPackageRequiresWholePlan(relative: Bool) async throws {
  let fixture = try PackageFixture()
  defer { fixture.cleanup() }
  try fixture.makeLink(relative: relative)
  let built = try await fixture.planner.makePlan(path: fixture.link, expectedBundleID: fixture.bundleID)
  let leaf = try #require(built.linkItem)
  #expect(built.plan.items.map(\.sourcePath) == [fixture.app, fixture.link])
  #expect(leaf.packageLinkTargetItemID == built.physicalPackage.id)
  #expect(leaf.policy == .applicationLink && leaf.catalogProof == nil)
  #expect(built.physicalApplication?.path == fixture.app)
  #expect(throws: GuardFailure.unsupportedItem) { try ActionGuard(homeDirectory: fixture.home).validate(leaf) }
  let prepared = fixture.planner.prepare(plan: built.plan)
  let proof = try #require(prepared.links[leaf.id])
  try ActionGuard(homeDirectory: fixture.home).validate(leaf, plan: built.plan, preparedLink: proof)
  let otherPlan = ActionPlan(snapshotRunID: built.plan.snapshotRunID, kind: .trash, items: built.plan.items)
  #expect(throws: GuardFailure.self) {
    try ActionGuard(homeDirectory: fixture.home).validate(leaf, plan: otherPlan, preparedLink: proof)
  }
  let alone = ActionPlan(snapshotRunID: built.plan.snapshotRunID, kind: .trash, items: [leaf])
  #expect(fixture.planner.prepare(plan: alone).failures[leaf.id] != nil)
  let permanent = ActionPlan(snapshotRunID: built.plan.snapshotRunID, kind: .catalogDelete, items: built.plan.items)
  let journal = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
  let trash = PackageLocalTrash(directory: fixture.home + "/Trash")
  await #expect(throws: ExecutionFailure.self) {
    try await packageExecutor(fixture: fixture, journal: journal, trash: trash).execute(permanent)
  }
  #expect(await trash.paths().isEmpty)
}

@Test("Current native Info identity is mandatory even when the ID is unchanged")
private func stalePackageInfoRefusesBeforeAnyTrashCall() async throws {
  let fixture = try PackageFixture()
  defer { fixture.cleanup() }
  let built = try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: fixture.bundleID)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": try #require(fixture.bundleID), "CFBundleVersion": "replacement"],
    format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: fixture.info))
  let journal = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
  let trash = PackageLocalTrash(directory: fixture.home + "/Trash")
  let result = try await packageExecutor(fixture: fixture, journal: journal, trash: trash).execute(built.plan)
  #expect(result.items.map(\.outcome) == [.skipped])
  #expect(await trash.paths().isEmpty)
  #expect(FileManager.default.fileExists(atPath: fixture.app))
}

@Test("IDless metadata is rebound after the final hook, including a newly added ID")
private func identifierlessMetadataSwapInFinalWindowRefuses() async throws {
  let fixture = try PackageFixture(identified: false)
  defer { fixture.cleanup() }
  let built = try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: nil)
  let journal = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
  let trash = PackageLocalTrash(directory: fixture.home + "/Trash")
  let result = try await packageExecutor(
    fixture: fixture, journal: journal, trash: trash,
    beforeMutation: { _ in
      try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "qa.lighten.replacement"], format: .xml, options: 0
      )
      .write(to: URL(fileURLWithPath: fixture.info))
    }
  ).execute(built.plan)
  #expect(result.items.map(\.outcome) == [.skipped])
  #expect(await trash.paths().isEmpty)
}

@Test("Unrelated physical packages cannot satisfy a leaf's expected item association")
private func linkAssociationCannotSubstituteAnUnrelatedPackage() async throws {
  let fixture = try PackageFixture()
  let other = try PackageFixture()
  defer {
    fixture.cleanup()
    other.cleanup()
  }
  try fixture.makeLink()
  let built = try await fixture.planner.makePlan(path: fixture.link, expectedBundleID: fixture.bundleID)
  try FileManager.default.removeItem(atPath: fixture.link)
  #expect(symlink(other.app, fixture.link) == 0)
  let replacementIdentity = try DescriptorFileSystem.identity(at: fixture.link)
  let leaf = try #require(built.linkItem)
  let replacementEntry = ScanEntry(
    id: leaf.id, parentID: nil, path: leaf.sourcePath, identity: replacementIdentity, issues: [], readable: true)
  let declaredLeaf = PlanItem(
    id: leaf.id, sourcePath: leaf.sourcePath, volumeID: leaf.volumeID, inventory: [replacementEntry],
    ancestors: leaf.ancestors, policy: .applicationLink, snapshotRunID: leaf.snapshotRunID,
    packageLinkTargetItemID: built.physicalPackage.id)
  let plan = ActionPlan(
    snapshotRunID: built.plan.snapshotRunID, kind: .trash, items: [declaredLeaf, built.physicalPackage])
  let journal = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
  let trash = PackageLocalTrash(directory: fixture.home + "/Trash")
  let result = try await packageExecutor(fixture: fixture, journal: journal, trash: trash).execute(plan)
  #expect(result.items.allSatisfy { $0.outcome == .skipped })
  #expect(await trash.paths().isEmpty)
  #expect(FileManager.default.fileExists(atPath: fixture.app) && FileManager.default.fileExists(atPath: other.app))
}

@Test("A leaf replaced after physical move stays untouched and is reported separately")
private func finalLinkReplacementIsTruthfulPartialSuccess() async throws {
  let fixture = try PackageFixture()
  let other = try PackageFixture()
  defer {
    fixture.cleanup()
    other.cleanup()
  }
  try fixture.makeLink()
  let built = try await fixture.planner.makePlan(path: fixture.link, expectedBundleID: fixture.bundleID)
  let leaf = try #require(built.linkItem)
  let journal = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
  let trash = PackageLocalTrash(directory: fixture.home + "/Trash")
  let result = try await packageExecutor(
    fixture: fixture, journal: journal, trash: trash,
    beforeMutation: { item in
      if item.id == leaf.id {
        try FileManager.default.removeItem(atPath: fixture.link)
        guard symlink(other.app, fixture.link) == 0 else { throw FileSystemFailure.systemCall("symlink", errno) }
      }
    }
  ).execute(built.plan)
  #expect(result.items.map(\.outcome) == [.applied, .skipped])
  #expect(await trash.paths() == [fixture.app])
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link) == other.app)
  #expect(FileManager.default.fileExists(atPath: other.app))
  let undo = try await ActionHistory(journal: journal, homeDirectory: fixture.home).undo(planID: built.plan.id)
  #expect(undo.restoredCount == 1)
}

@Test("A reappeared physical source invalidates the private moved-package context")
private func returnedMoveDoesNotAuthorizeAReplacedOriginalSource() async throws {
  let fixture = try PackageFixture()
  defer { fixture.cleanup() }
  try fixture.makeLink()
  let built = try await fixture.planner.makePlan(path: fixture.link, expectedBundleID: fixture.bundleID)
  let leaf = try #require(built.linkItem)
  let journal = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
  let trash = PackageLocalTrash(directory: fixture.home + "/Trash")
  let result = try await packageExecutor(
    fixture: fixture, journal: journal, trash: trash,
    beforeMutation: { item in
      if item.id == leaf.id {
        try FileManager.default.createDirectory(atPath: fixture.app, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: fixture.app + "/marker"))
      }
    }
  ).execute(built.plan)
  #expect(result.items.map(\.outcome) == [.applied, .skipped])
  #expect(await trash.paths() == [fixture.app])
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.app + "/marker")) == Data("replacement".utf8))
  #expect((try? DescriptorFileSystem.identity(at: fixture.link))?.kind == .symbolicLink)
}

@Test("Every supported layout preserves Lighten's self-removal veto", arguments: PackageLayout.allCases)
private func selfIdentifierAcrossLayoutsNeverPlans(layout: PackageLayout) async throws {
  let fixture = try PackageFixture(layout: layout)
  defer { fixture.cleanup() }
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": LightenIdentity.bundleIdentifier], format: .xml, options: 0
  )
  .write(to: URL(fileURLWithPath: fixture.info))
  await #expect(throws: PlanRejection(.lightenItself, path: fixture.app)) {
    try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: LightenIdentity.bundleIdentifier)
  }
}

@Test("Every supported layout preserves a named Never refusal", arguments: PackageLayout.allCases)
private func neverProtectedLayoutsKeepTheBlockingRule(layout: PackageLayout) async throws {
  let fixture = try PackageFixture(layout: layout)
  defer { fixture.cleanup() }
  let protected = fixture.home + "/Library/Keychains/" + (fixture.app as NSString).lastPathComponent
  try FileManager.default.createDirectory(
    atPath: (protected as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try FileManager.default.moveItem(atPath: fixture.app, toPath: protected)
  await #expect(throws: PlanRejection(.protectedItem, path: protected, ruleID: "keychains")) {
    try await fixture.planner.makePlan(path: protected, expectedBundleID: fixture.bundleID)
  }
}

@Test("Preparation retains named owner, protection, volume and permission refusals")
private func packageRefusalMappingKeepsNamedSafetyReasons() {
  let path = "/Applications/LightenQA-" + UUID().uuidString + ".app"
  let reasons: [RejectionReason] = [
    .needsAdministrator, .protectedItem, .differentVolume, .userPermissionDenied, .lightenItself,
  ]
  for reason in reasons {
    let rejection = PlanRejection(reason, path: path, ruleID: "native-check")
    #expect(ApplicationPackagePlanning.refusal(rejection, path: path) == rejection)
  }
  #expect(ApplicationPackagePlanning.refusal(GuardFailure.protectedItem, path: path).reason == .protectedItem)
  #expect(ApplicationPackagePlanning.refusal(GuardFailure.unsupportedItem, path: path).reason == .unavailable)
  #expect(ApplicationPackagePlanning.refusal(SecureMetadataFailure.unsafe, path: path).reason == .missingMetadata)
  #expect(
    ApplicationPackagePlanning.refusal(FileSystemFailure.systemCall("open metadata", EACCES), path: path).reason
      == .unreadableFolder)
}

@Test("Metadata links cannot provide a supported native layout", arguments: PackageLayout.allCases)
private func linkedInfoCannotAuthorizePackage(layout: PackageLayout) async throws {
  let fixture = try PackageFixture(layout: layout)
  defer { fixture.cleanup() }
  let realInfo = fixture.home + "/Metadata.plist"
  try FileManager.default.moveItem(atPath: fixture.info, toPath: realInfo)
  #expect(symlink(realInfo, fixture.info) == 0)
  await #expect(throws: (any Error).self) {
    try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: fixture.bundleID)
  }
}

@Test(
  "Identifierless packages still require fresh helper activity", arguments: [ApplicationActivityState.active, .unknown])
private func identifierlessActivityNeverUsesAnEmptyIDAsClear(state: ApplicationActivityState) async throws {
  let fixture = try PackageFixture(identified: false)
  defer { fixture.cleanup() }
  let planner = ApplicationPackagePlanning(
    homeDirectory: fixture.home, runningApplications: PackageNotRunning(),
    applicationActivity: PackageFixedActivity(state: state))
  await #expect(throws: PlanRejection.self) { try await planner.makePlan(path: fixture.app, expectedBundleID: nil) }
}

@Test("Fresh lower-bound contents stay lower-bound, and display bytes grant no authority")
private func observedContentsAreNotAnAuthorizationInput() async throws {
  let fixture = try PackageFixture()
  defer { fixture.cleanup() }
  let lowerBound = ObservedPlanSize(logical: ByteAggregate(knownLowerBound: 65_536, completeTotal: nil), allocated: nil)
  let planner = ApplicationPackagePlanning(
    homeDirectory: fixture.home, runningApplications: PackageNotRunning(),
    applicationActivity: FixtureClearApplicationActivity(),
    measure: { _, _ in lowerBound })
  let built = try await planner.makePlan(path: fixture.app, expectedBundleID: fixture.bundleID)
  #expect(built.physicalPackage.displaySize.logical?.completeTotal == nil)
  #expect(built.physicalPackage.displaySize.logical?.knownLowerBound == 65_536)
  try ActionGuard(homeDirectory: fixture.home).validate(
    copiedPackageItem(built.physicalPackage, observedSize: .unknown))
  #expect(fixture.planner.prepare(plan: built.plan).failures.isEmpty)
}

@Test("A public metadata expectation cannot choose an arbitrary Info path")
private func metadataExpectationCannotAuthorizeAnotherFile() async throws {
  let fixture = try PackageFixture()
  defer { fixture.cleanup() }
  let built = try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: fixture.bundleID)
  let actual = try #require(built.physicalPackage.applicationPackageObservation)
  let forged = ApplicationPackageObservation(
    infoRelativePath: "../Metadata.plist", infoIdentity: actual.infoIdentity, bundleIdentifier: actual.bundleIdentifier)
  #expect(throws: (any Error).self) {
    try ActionGuard(homeDirectory: fixture.home).validate(copiedPackageItem(built.physicalPackage, observation: forged))
  }
}

@Test("Missing legacy package expectations retain only the original Contents layout", arguments: PackageLayout.allCases)
private func legacyPackageWithoutObservationNeverAcquiresNewLayoutAuthority(layout: PackageLayout) async throws {
  let fixture = try PackageFixture(layout: layout)
  defer { fixture.cleanup() }
  let built = try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: fixture.bundleID)
  let current = built.physicalPackage
  let legacy = PlanItem(
    id: current.id, sourcePath: current.sourcePath, volumeID: current.volumeID,
    inventory: current.inventory, ancestors: current.ancestors, policy: .wholeBundle,
    applicationBundleID: current.applicationBundleID, nestedApplicationIDs: current.nestedApplicationIDs,
    snapshotRunID: current.snapshotRunID, sizeMetadataVersion: nil)
  if layout == .contents {
    try ActionGuard(homeDirectory: fixture.home).validate(legacy)
  } else {
    #expect(throws: GuardFailure.self) { try ActionGuard(homeDirectory: fixture.home).validate(legacy) }
  }
}

@Test("A stale pair refuses only its intended package while an independent package moves")
private func refusedLinkDoesNotPoisonAnIndependentPackage() async throws {
  let fixture = try PackageFixture()
  let independent = try PackageFixture()
  defer {
    fixture.cleanup()
    independent.cleanup()
  }
  try fixture.makeLink()
  let paired = try await fixture.planner.makePlan(path: fixture.link, expectedBundleID: fixture.bundleID)
  let unpaired = try await independent.planner.makePlan(path: independent.app, expectedBundleID: independent.bundleID)
  try FileManager.default.removeItem(atPath: fixture.link)
  #expect(symlink(independent.app, fixture.link) == 0)
  let plan = ActionPlan(
    snapshotRunID: paired.plan.snapshotRunID, kind: .trash,
    items: paired.plan.items + [unpaired.physicalPackage])
  let journal = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
  let trash = PackageLocalTrash(directory: fixture.home + "/Trash")
  let result = try await packageExecutor(fixture: fixture, journal: journal, trash: trash).execute(plan)
  #expect(result.items.first { $0.itemID == paired.physicalPackage.id }?.outcome == .skipped)
  #expect(result.items.first { $0.itemID == paired.linkItem?.id }?.outcome == .skipped)
  #expect(result.items.first { $0.itemID == unpaired.physicalPackage.id }?.outcome == .applied)
  #expect(await trash.paths() == [independent.app])
  #expect(FileManager.default.fileExists(atPath: fixture.app))
  #expect(
    try await ActionHistory(journal: journal, homeDirectory: fixture.home).undo(planID: plan.id).restoredCount == 1)
}

@Test(
  "Mapped related-owner metadata follows the physical flat or wrapper package",
  arguments: [PackageLayout.flat, .wrapper])
private func movedOwnerBindsFreshNonContentsInfo(layout: PackageLayout) async throws {
  let fixture = try PackageFixture(layout: layout)
  defer { fixture.cleanup() }
  let built = try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: fixture.bundleID)
  let id = try #require(fixture.bundleID)
  let path = fixture.home + "/Library/Caches/" + id
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  try Data("cache".utf8).write(to: URL(fileURLWithPath: path + "/record"))
  let inventory = try ExactInventory(homeDirectory: fixture.home).collect(
    rootPath: path, expected: nil, policy: .relatedTrash)
  let rootIdentity = try #require(built.physicalPackage.inventory.first?.identity)
  let infoIdentity = try #require(built.physicalPackage.applicationPackageObservation?.infoIdentity)
  let proof = InstalledRelatedProof(
    bundleID: id, appPath: fixture.app, appIdentity: rootIdentity, infoIdentity: infoIdentity,
    relatedPath: path, relatedIdentity: try #require(inventory.entries.first?.identity),
    snapshotRunID: built.plan.snapshotRunID)
  let data = PlanItem(
    id: inventory.entries[0].id, sourcePath: path, volumeID: inventory.volumeID,
    inventory: inventory.entries, ancestors: inventory.ancestors, installedRelatedProof: proof, policy: .relatedTrash,
    nestedApplicationIDs: inventory.nestedApplicationIDs, snapshotRunID: built.plan.snapshotRunID)
  let plan = ActionPlan(snapshotRunID: built.plan.snapshotRunID, kind: .trash, items: [built.physicalPackage, data])
  let target = fixture.home + "/Trash/" + (fixture.app as NSString).lastPathComponent
  try FileManager.default.moveItem(atPath: fixture.app, toPath: target)
  let moved = try MovedApplicationOwner(
    planID: plan.id, package: built.physicalPackage, path: target, identity: KnownPathFileSystem.identity(at: target))
  let mapped = try moved.mapped(data, planID: plan.id)
  #expect(mapped.installedRelatedProof?.appPath == target)
  #expect(mapped.installedRelatedProof?.infoIdentity == infoIdentity)
  #expect(moved.movedPackage.observedSize == built.physicalPackage.observedSize)
  #expect(moved.movedPackage.applicationPackageObservation == built.physicalPackage.applicationPackageObservation)
  let prepared = PreparedInstalledOwner(planID: plan.id, item: data, signatures: [])
  try prepared.validate(data, plan: plan, movedOwner: moved)
}

@Test(
  "Measured opaque contents survive execution refresh, restart History and grouped Undo",
  arguments: PackageLayout.allCases)
private func packageExecutionAndHistoryRetainMeasuredContents(layout: PackageLayout) async throws {
  let fixture = try PackageFixture(layout: layout, identified: false)
  defer { fixture.cleanup() }
  let built = try await fixture.planner.makePlan(path: fixture.app, expectedBundleID: nil)
  let measured = try #require(built.physicalPackage.observedSize)
  #expect(measured.logical?.completeTotal ?? 0 > 65_536)
  let journalPath = fixture.home + "/Journal/actions.jsonl"
  let journal = JSONLActionJournal(path: journalPath)
  let trash = PackageLocalTrash(directory: fixture.home + "/Trash")
  let applied = try await packageExecutor(fixture: fixture, journal: journal, trash: trash).execute(built.plan)
  #expect(applied.items.map(\.outcome) == [.applied])
  let durable = try await journal.loadPlan(id: built.plan.id)
  #expect(durable.items[0].observedSize == measured)
  #expect(durable.items[0].applicationPackageObservation == built.physicalPackage.applicationPackageObservation)
  #expect(durable.items[0].sizeMetadataVersion == built.physicalPackage.sizeMetadataVersion)
  let relaunched = ActionHistory(journal: JSONLActionJournal(path: journalPath), homeDirectory: fixture.home)
  let history = try await relaunched.loadGroup(planID: built.plan.id)
  #expect(history.items.map(\.state) == [.inTrash])
  #expect(history.metadata[0].displaySize == measured)
  #expect(try await relaunched.undo(planID: built.plan.id).restoredCount == 1)
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.payload)) == Data(repeating: 0x42, count: 65_536))
  let restored = try await relaunched.loadGroup(planID: built.plan.id)
  #expect(restored.items.map(\.state) == [.reversed])
  #expect(restored.metadata[0].displaySize == measured)
}

@Test("Native Trash moves a package and its own dangling link as separate items, then Undo restores both")
private func nativePackageLinkTrashAndRestartUndo() async throws {
  let fixture = try PackageFixture()
  let trash = PackageNativeTrash()
  defer {
    trash.restoreOwnFixtures()
    fixture.cleanup()
  }
  try fixture.makeLink(relative: true)
  let originalLinkBytes = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link)
  let built = try await fixture.planner.makePlan(path: fixture.link, expectedBundleID: fixture.bundleID)
  let journalPath = fixture.home + "/Journal/actions.jsonl"
  let journal = JSONLActionJournal(path: journalPath)
  let applied = try await packageExecutor(fixture: fixture, journal: journal, trash: trash).execute(built.plan)
  #expect(applied.items.map(\.outcome) == [.applied, .applied])
  let relaunched = ActionHistory(journal: JSONLActionJournal(path: journalPath), homeDirectory: fixture.home)
  let loaded = try await relaunched.loadGroup(planID: built.plan.id)
  #expect(loaded.items.map(\.state) == [.inTrash, .inTrash])
  #expect(loaded.metadata[0].displaySize == built.physicalPackage.displaySize)
  #expect(try await relaunched.undo(planID: built.plan.id).restoredCount == 2)
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link) == originalLinkBytes)
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.payload)) == Data(repeating: 0x42, count: 65_536))
}
