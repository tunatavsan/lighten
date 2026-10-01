import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private struct RemovalFixture {
  let home: String
  let storage: String
  let appRoot: String
  let app: String
  let bundleID: String
  let groupID: String
  let paths: [String]
  let realHome: Bool

  init(realHome: Bool = false) throws {
    let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(temporary) }
    let token = UUID().uuidString
    storage = String(cString: temporary) + "/LightenQA-" + token
    self.realHome = realHome
    home = realHome ? NSHomeDirectory() : storage
    appRoot = home + "/Applications/LightenQA-" + token
    app = appRoot + "/LightenQA-" + token + ".app"
    bundleID = "qa.lighten." + token
    groupID = "group." + bundleID
    let fixtureHome = home
    let fixtureBundleID = bundleID
    let fixtureGroupID = groupID
    paths = RelatedLocation.allCases.map {
      $0.path(domain: $0 == .groupContainers ? fixtureGroupID : fixtureBundleID, homeDirectory: fixtureHome)
    }
    if realHome { print("QA fixture paths: " + ([appRoot] + paths + [storage]).joined(separator: " | ")) }
    try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: storage + "/Trash", withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/bin/echo", toPath: app + "/Contents/MacOS/fixture")
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": bundleID, "CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL",
      ], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
    let entitlementPath = storage + "/entitlements.plist"
    try PropertyListSerialization.data(
      fromPropertyList: [
        "com.apple.security.app-sandbox": true,
        "com.apple.security.application-groups": [groupID],
      ], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: entitlementPath))
    let signer = Process()
    signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signer.arguments = ["--force", "--sign", "-", "--timestamp=none", "--entitlements", entitlementPath, app]
    signer.standardOutput = FileHandle.nullDevice
    signer.standardError = FileHandle.nullDevice
    try signer.run()
    signer.waitUntilExit()
    try #require(signer.terminationStatus == 0)
    try #require(ApplicationSigningMetadata.read(path: app)?.groupIdentifiers.contains(groupID) == true)
    for (location, path) in zip(RelatedLocation.allCases, paths) {
      if location == .preferences {
        try FileManager.default.createDirectory(
          atPath: (path as NSString).deletingLastPathComponent,
          withIntermediateDirectories: true)
        try Data("preferences".utf8).write(to: URL(fileURLWithPath: path))
      } else {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data(location.rawValue.utf8).write(to: URL(fileURLWithPath: path + "/record"))
      }
    }
    let container = RelatedLocation.containers.path(domain: bundleID, homeDirectory: home)
    try FileManager.default.createDirectory(atPath: container + "/Data/Documents", withIntermediateDirectories: true)
    try Data("user document".utf8).write(to: URL(fileURLWithPath: container + "/Data/Documents/document"))
    try FileManager.default.createSymbolicLink(atPath: container + "/Data/Library", withDestinationPath: "../../")
    try FileManager.default.createSymbolicLink(
      atPath: container + "/Data/Desktop", withDestinationPath: "/missing-target")
  }

  var service: RelatedDataService {
    RelatedDataService(
      homeDirectory: home, applicationRoots: [appRoot], writeVerifiedReceipts: false,
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  }

  func cleanup() {
    for path in paths { try? FileManager.default.removeItem(atPath: path) }
    try? FileManager.default.removeItem(atPath: appRoot)
    try? FileManager.default.removeItem(atPath: storage)
  }

  func hashes() throws -> [String: String] {
    var result: [String: String] = [:]
    func visit(_ path: String) throws {
      let identity = try DescriptorFileSystem.identity(at: path)
      switch identity.kind {
      case .regular:
        result[path] = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
          .map { String(format: "%02x", $0) }.joined()
      case .symbolicLink:
        result[path] = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: path))
      case .directory:
        for name in try DescriptorFileSystem.children(at: path, expected: identity) { try visit(path + "/" + name) }
      case .other: break
      }
    }
    for path in paths + [app] { try visit(path) }
    return result
  }
}

private struct RemovalRunning: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
}

private struct RemovalTrash: TrashMoving {
  let directory: String
  let native: Bool

  func moveToTrash(path: String) async throws -> String {
    if native {
      var result: NSURL?
      try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
      return try #require(result?.path)
    }
    let target = directory + "/" + UUID().uuidString + "-" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: target)
    return target
  }
}

@Test("One application and all nine data domains share a single Trash action and SHA-identical Undo")
func relatedNineDomainsUndo() async throws {
  let realHome = ProcessInfo.processInfo.environment["LIGHTEN_QA_REAL_HOME"] == "1"
  let fixture = try RemovalFixture(realHome: realHome)
  defer { fixture.cleanup() }
  let before = try fixture.hashes()
  let candidates = await fixture.service.discover()
  let selected = candidates.filter { fixture.paths.contains($0.path) }
  #expect(selected.count == 9)
  #expect(selected.allSatisfy { $0.classification == .installed })
  #expect(selected.filter(\.defaultSelected).count == 8)
  #expect(selected.first { $0.path == fixture.paths[4] }?.defaultSelected == false)
  let app = try #require(fixture.service.inventory().applications.first)
  let plan = try fixture.service.planUninstall(app: app, selectedRelated: selected)
  #expect(plan.items.count == 10)
  for candidate in selected {
    let observedRun = try #require(candidate.snapshot?.runID)
    let related = try #require(plan.items.first { $0.sourcePath == candidate.path })
    #expect(related.snapshotRunID == observedRun)
    #expect(related.installedRelatedProof?.snapshotRunID == observedRun)
  }
  let package = try #require(plan.items.last)
  #expect(package.policy == .wholeBundle)
  let packageRun = try #require(package.snapshotRunID)
  #expect(!selected.contains { $0.snapshot?.runID == packageRun })
  #expect(Set(plan.items.compactMap(\.snapshotRunID)).count == 10)
  let journal = JSONLActionJournal(path: fixture.storage + "/Journal/actions.jsonl")
  let executor = ActionExecutor(
    journal: journal,
    trash: RemovalTrash(directory: fixture.storage + "/Trash", native: realHome),
    guardService: ActionGuard(homeDirectory: fixture.home), related: fixture.service,
    runningApplications: RemovalRunning(), applicationActivity: FixtureClearApplicationActivity())
  let moved = try await executor.execute(plan)
  #expect(moved.items.count == 10)
  #expect(moved.items.allSatisfy { $0.outcome == .applied }, "\(moved.items)")
  #expect(try await journal.readSummary().records.filter { $0.kind == .intent }.count == 1)
  let history = ActionHistory(journal: journal, homeDirectory: fixture.home)
  let recoverable = try await history.loadGroup(planID: plan.id)
  #expect(recoverable.canUndo && recoverable.items.allSatisfy(\.canUndo))
  let restored = try await history.undo(planID: plan.id)
  #expect(restored.restoredCount == 10 && restored.remainingCount == 0)
  let after = try fixture.hashes()
  let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
  #expect(after == before, "Changed paths: \(changed.map { ($0, before[$0], after[$0]) })")
}

@Test("Related container permissions require a matching proof and preserve other protected descendants")
func relatedContainerProofGuard() async throws {
  let fixture = try RemovalFixture()
  defer { fixture.cleanup() }
  let app = try #require(fixture.service.inventory().applications.first)
  let container = RelatedLocation.containers.path(domain: fixture.bundleID, homeDirectory: fixture.home)
  let candidate = try #require((await fixture.service.discover()).first { $0.path == container })
  let plan = try fixture.service.planInstalled(app: app, candidate: candidate)
  let item = plan.items[0]
  try ActionGuard(homeDirectory: fixture.home).validate(item)
  let forged = PlanItem(
    id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
    inventory: item.inventory, ancestors: item.ancestors, policy: .relatedContainer,
    nestedApplicationIDs: item.nestedApplicationIDs, snapshotRunID: item.snapshotRunID)
  #expect(throws: GuardFailure.self) { try ActionGuard(homeDirectory: fixture.home).validate(forged) }
  let permanent = ActionPlan(snapshotRunID: plan.snapshotRunID, kind: .catalogDelete, items: plan.items)
  #expect(throws: RelatedFailure.self) { try fixture.service.validateInstalled(item, plan: permanent) }
  let protected = container + "/Data/Documents/Album.photoslibrary"
  try FileManager.default.createDirectory(atPath: protected, withIntermediateDirectories: true)
  #expect(throws: PlanRejection.self) { try fixture.service.planInstalled(app: app, candidate: candidate) }
}

@Test("Each related item binds its own run and rejects a forged proof run")
func relatedRunsAreBoundPerItem() async throws {
  let fixture = try RemovalFixture()
  defer { fixture.cleanup() }
  let candidates = await fixture.service.discover()
  let app = try #require(fixture.service.inventory().applications.first)
  let selected = candidates.filter { fixture.paths.prefix(2).contains($0.path) }
  let plans = try selected.map { try fixture.service.planInstalled(app: app, candidate: $0) }
  let combined = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: plans.flatMap(\.items))
  for item in combined.items { try fixture.service.validateInstalled(item, plan: combined) }
  let item = combined.items[0]
  let proof = try #require(item.installedRelatedProof)
  let changed = InstalledRelatedProof(
    bundleID: proof.bundleID, appPath: proof.appPath,
    appIdentity: proof.appIdentity, infoIdentity: proof.infoIdentity, relatedPath: proof.relatedPath,
    relatedIdentity: proof.relatedIdentity, snapshotRunID: UUID())
  let forged = PlanItem(
    id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
    inventory: item.inventory, ancestors: item.ancestors, installedRelatedProof: changed, policy: item.policy,
    snapshotRunID: item.snapshotRunID)
  #expect(throws: RelatedFailure.self) { try fixture.service.validateInstalled(forged, plan: combined) }
}

@Test("Unobserved orphan data is warned, unselected, freshly checked, and restorable")
func orphanRemovalRequiresCurrentAbsence() async throws {
  let fixture = try RemovalFixture()
  defer { fixture.cleanup() }
  try FileManager.default.removeItem(atPath: fixture.app)
  let service = fixture.service
  let candidates = await service.discover()
  let selected = candidates.filter { fixture.paths.prefix(3).contains($0.path) }
  #expect(selected.count == 3)
  #expect(
    selected.allSatisfy {
      $0.classification == .orphanVerified && $0.canSelect && !$0.defaultSelected && $0.modifiedAt != nil
    })
  let plans = try selected.map { try service.plan(candidate: $0) }
  let combined = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: plans.flatMap(\.items))
  for item in combined.items {
    #expect(throws: RelatedFailure.incompleteInventory) { try service.validateOrphan(item, plan: combined) }
  }
  let refused = await service.validatePlan(combined)
  #expect(
    refused.count == 3
      && refused.allSatisfy {
        $0.reason == .unavailable
          && $0.ruleID == "incompleteInventory: original private plan context unavailable; review again"
      })
  let journal = JSONLActionJournal(path: fixture.storage + "/Journal/actions.jsonl")
  let executor = ActionExecutor(
    journal: journal,
    trash: RemovalTrash(directory: fixture.storage + "/Trash", native: false),
    guardService: ActionGuard(homeDirectory: fixture.home), related: service,
    runningApplications: RemovalRunning(), applicationActivity: FixtureClearApplicationActivity()
  )
  for original in plans {
    let result = try await executor.execute(original)
    #expect(result.items.count == 1 && result.items.allSatisfy { $0.outcome == .applied }, "\(result.items)")
    let history = ActionHistory(journal: journal, homeDirectory: fixture.home)
    #expect(try await history.loadGroup(planID: original.id).canUndo)
    let restored = try await history.undo(planID: original.id)
    #expect(restored.restoredCount == 1 && restored.remainingCount == 0)
  }
  #expect(try await journal.readSummary().records.filter { $0.kind == .intent }.count == 3)
  for candidate in selected { #expect(FileManager.default.fileExists(atPath: candidate.path)) }
  let elsewhere = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot],
    writeVerifiedReceipts: false, installedElsewhere: { _ in true },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  #expect((await elsewhere.discover()).filter { fixture.paths.contains($0.path) }.allSatisfy { !$0.canSelect })
  #expect(throws: RelatedFailure.self) { try elsewhere.validateOrphan(plans[0].items[0], plan: plans[0]) }
}

@Test("Group ownership must be exclusive and exact observations never grant subtree authority")
func relatedSharedAndFreshInventory() async throws {
  let fixture = try RemovalFixture()
  defer { fixture.cleanup() }
  let candidate = try #require((await fixture.service.discover()).first { $0.path == fixture.paths[0] })
  #expect(candidate.snapshot?.entries.count == 1)
  try Data("new descendant".utf8).write(to: URL(fileURLWithPath: candidate.path + "/new-file"))
  let app = try #require(fixture.service.inventory().applications.first)
  let plan = try fixture.service.planInstalled(app: app, candidate: candidate)
  #expect(plan.items[0].inventory.contains { $0.path.hasSuffix("/new-file") })
  let sibling = fixture.appRoot + "/LightenQA-shared.app"
  try FileManager.default.copyItem(atPath: fixture.app, toPath: sibling)
  let group = try #require((await fixture.service.discover()).first { $0.path == fixture.paths[4] })
  #expect(group.classification == .shared)
  #expect(!group.canSelect)
}

@Test("A dropped application outside the inventory roots owns only freshly proved standard data")
func droppedApplicationDataIsInstalled() async throws {
  let fixture = try RemovalFixture()
  defer { fixture.cleanup() }
  let dropped = fixture.storage + "/Dropped/LightenQA-" + UUID().uuidString + ".app"
  try FileManager.default.createDirectory(
    atPath: (dropped as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true)
  try FileManager.default.moveItem(atPath: fixture.app, toPath: dropped)
  let report = try #require(await ApplicationDiscovery(related: fixture.service).report(path: dropped))
  #expect(report.related.filter(\.defaultSelected).count == 8)
  #expect(report.related.allSatisfy { $0.classification == .installed })
  #expect(report.related.first { $0.path == fixture.paths[4] }?.canSelect == true)
  #expect(report.related.first { $0.path == fixture.paths[4] }?.defaultSelected == false)
  let app = try #require(fixture.service.application(at: dropped))
  #expect(app.bundleID == fixture.bundleID)
  let plan = try fixture.service.planUninstall(app: app, selectedRelated: report.related.filter(\.defaultSelected))
  #expect(plan.items.count == 9)
  for item in plan.items.dropLast() { try fixture.service.validateInstalled(item, plan: plan) }
}

@Test("Apple domains and a current installed owner never become selectable orphan data")
func orphanDomainsRejectAppleAndInstalledOwner() async throws {
  let fixture = try RemovalFixture()
  defer { fixture.cleanup() }
  let apple = RelatedLocation.caches.path(
    domain: "com.apple.LightenQA-" + UUID().uuidString,
    homeDirectory: fixture.home)
  try FileManager.default.createDirectory(atPath: apple, withIntermediateDirectories: true)
  let candidates = await fixture.service.discover()
  #expect(candidates.first { $0.path == apple }?.canSelect == false)
  #expect(candidates.filter { fixture.paths.contains($0.path) }.allSatisfy { $0.classification == .installed })
  let cached = try #require(candidates.first { $0.path == fixture.paths[0] })
  let current = try DescriptorFileSystem.identity(at: cached.path)
  let run = try #require(cached.snapshot?.runID)
  let proof = OrphanRelatedProof(
    bundleID: fixture.bundleID, relatedPath: cached.path, identity: current,
    observedAt: Date(), snapshotRunID: run)
  let collected = try ExactInventory(homeDirectory: fixture.home).collect(
    rootPath: cached.path, expected: nil,
    policy: .relatedTrash)
  let item = PlanItem(
    id: collected.entries[0].id, sourcePath: cached.path, volumeID: collected.volumeID,
    inventory: collected.entries, ancestors: collected.ancestors, policy: .relatedTrash,
    snapshotRunID: run, orphanRelatedProof: proof)
  #expect(throws: RelatedFailure.self) {
    try fixture.service.validateOrphan(item, plan: ActionPlan(snapshotRunID: run, kind: .trash, items: [item]))
  }
}

@Test("Signed team prefixes are medium matches while display names never gain action authority")
func relatedMatchStrengths() async throws {
  let fixture = try RemovalFixture()
  defer { fixture.cleanup() }
  let app = try #require(fixture.service.inventory().applications.first)
  let medium = RelatedLocation.logs.path(
    domain: "TEAM123456." + fixture.bundleID + ".helper",
    homeDirectory: fixture.home)
  let weak = RelatedLocation.applicationSupport.path(
    domain: URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent, homeDirectory: fixture.home)
  try FileManager.default.createDirectory(atPath: medium, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: weak, withIntermediateDirectories: true)
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot],
    writeVerifiedReceipts: false,
    signingMetadata: { _ in ApplicationSigningMetadata(teamID: "TEAM123456", groupIdentifiers: []) },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let candidates = await service.discover()
  let team = try #require(candidates.first { $0.path == medium })
  let name = try #require(candidates.first { $0.path == weak })
  #expect(team.matchStrength == .medium && team.canSelect && !team.defaultSelected)
  #expect(name.matchStrength == .weak && !name.canSelect && !name.defaultSelected)
  #expect(throws: RelatedFailure.self) { try service.planInstalled(app: app, candidate: name) }
  let unrelated = fixture.home + "/Library/Other/" + fixture.bundleID
  try FileManager.default.createDirectory(atPath: unrelated, withIntermediateDirectories: true)
  var forged = team
  forged = RelatedDataCandidate(
    id: unrelated, path: unrelated, classification: .installed,
    reason: .installed, snapshot: team.snapshot, receipt: nil, bundleID: fixture.bundleID)
  #expect(throws: RelatedFailure.self) { try service.planInstalled(app: app, candidate: forged) }
}

@Test("Focused reports skip unrelated signers without group data and never write receipts", arguments: [false, true])
func focusedReportIsReadOnlyWithoutGroupData(existingReceipts: Bool) async throws {
  let fixture = try RemovalFixture()
  defer { fixture.cleanup() }
  try FileManager.default.removeItem(atPath: fixture.paths[4])
  for index in 0..<4 {
    let path = fixture.appRoot + "/LightenQA-unrelated-\(index).app"
    try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "qa.lighten.unrelated.\(index)"], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
  }
  let calls = Mutex<[String: Int]>([:])
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: true,
    signingMetadata: { path in
      calls.withLock { $0[path, default: 0] += 1 }
      return ApplicationSigningMetadata(teamID: "TEAM123456", groupIdentifiers: [fixture.groupID])
    }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let receiptPath = fixture.home + "/Library/Application Support/com.tavsn.lighten/related-receipts.json"
  if existingReceipts { _ = await service.discover() }
  let beforeData = try? Data(contentsOf: URL(fileURLWithPath: receiptPath))
  let beforeIdentity = try? DescriptorFileSystem.identity(at: receiptPath)
  let parent = (receiptPath as NSString).deletingLastPathComponent
  let beforeParent = try? DescriptorFileSystem.identity(at: parent)
  calls.withLock { $0.removeAll() }
  let started = ProcessInfo.processInfo.systemUptime
  let report = try #require(await ApplicationDiscovery(related: service).report(path: fixture.app))
  print("Focused no-group report seconds: \(ProcessInfo.processInfo.systemUptime - started)")
  #expect(report.signerTeamID == "TEAM123456")
  #expect(report.related.count == 8)
  #expect(report.related.allSatisfy { $0.bundleID == fixture.bundleID && $0.defaultSelected })
  #expect(calls.withLock { $0 } == (existingReceipts ? [:] : [fixture.app: 1]))
  #expect((try? Data(contentsOf: URL(fileURLWithPath: receiptPath))) == beforeData)
  #expect((try? DescriptorFileSystem.identity(at: receiptPath)) == beforeIdentity)
  #expect((try? DescriptorFileSystem.identity(at: parent)) == beforeParent)
}

@Test("Focused group reports read every potential owner and leave a shared container unselectable")
func focusedReportChecksPresentGroupOwners() async throws {
  let fixture = try RemovalFixture()
  defer { fixture.cleanup() }
  let sibling = fixture.appRoot + "/LightenQA-other-owner.app"
  try FileManager.default.createDirectory(atPath: sibling + "/Contents", withIntermediateDirectories: true)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "qa.lighten.other-owner"], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: sibling + "/Contents/Info.plist"))
  let calls = Mutex<[String: Int]>([:])
  let service = RelatedDataService(
    homeDirectory: fixture.home, applicationRoots: [fixture.appRoot], writeVerifiedReceipts: true,
    signingMetadata: { path in
      calls.withLock { $0[path, default: 0] += 1 }
      return ApplicationSigningMetadata(teamID: nil, groupIdentifiers: [fixture.groupID])
    }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let report = try #require(await ApplicationDiscovery(related: service).report(path: fixture.app))
  let group = try #require(report.related.first { $0.path == fixture.paths[4] })
  #expect(group.classification == .shared && !group.canSelect && !group.defaultSelected)
  #expect(calls.withLock { $0 } == [fixture.app: 1, sibling: 1])
  let app = try #require(service.application(at: fixture.app))
  #expect(throws: RelatedFailure.self) { try service.planInstalled(app: app, candidate: group) }
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.home + "/Library/Application Support/com.tavsn.lighten/related-receipts.json"))
}
