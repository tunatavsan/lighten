import Darwin
import Foundation
import Testing

@testable import LightenKit

private struct ScopedOwnerFixture {
  let home: String
  var apps: String { home + "/Applications" }
  let bundleID: String

  init() throws {
    let temporary = try #require(realpath("/tmp", nil))
    defer { free(temporary) }
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    home = String(cString: temporary) + "/LightenQA-" + token
    bundleID = "qa.lighten." + token
    try FileManager.default.createDirectory(atPath: apps, withIntermediateDirectories: true)
  }

  func info(_ path: String, id: String?, executable: String? = nil) throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var dictionary: [String: String] = [:]
    if let id { dictionary["CFBundleIdentifier"] = id }
    if let executable { dictionary["CFBundleExecutable"] = executable }
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
      .write(to: URL(fileURLWithPath: path))
  }

  func application(_ path: String, id: String) throws {
    try info(path + "/Contents/Info.plist", id: id)
  }

  func data(_ id: String) throws -> String {
    let path = RelatedLocation.caches.path(domain: id, homeDirectory: home)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try Data("owned fixture data".utf8).write(to: URL(fileURLWithPath: path + "/record"))
    return path
  }

  func service(registered: [String] = []) -> RelatedDataService {
    RelatedDataService(
      homeDirectory: home, applicationRoots: [apps], writeVerifiedReceipts: false,
      signingMetadata: { _ in nil }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
      registration: { ApplicationRegistrationObservation(paths: registered, complete: true) },
      registeredByID: { _ in ApplicationRegistrationObservation(paths: registered, complete: true) })
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: home) }
}

private struct ScopedRunningCopy: RunningApplicationSource {
  let bundleID: String
  func isRunning(bundleID: String) async -> Bool? { bundleID == self.bundleID }
}

private actor ScopedTrashSpy: TrashMoving {
  private var attempts = 0
  func moveToTrash(path: String) async throws -> String {
    attempts += 1
    throw FileSystemFailure.invalidPath
  }
  func count() -> Int { attempts }
}

@Suite("Scoped application owner observations")
struct ScopedApplicationOwnershipTests {
  @Test(
    "Readable unsupported IDs block their literal domain without granting action authority",
    arguments: ["deemd", "1000", "pinterest"])
  func literalIdentifiersAreOnlyOwnerObservations(_ literal: String) async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let owner = fixture.apps + "/LightenQA-literal.app"
    try fixture.application(owner, id: literal)
    let sameID = try fixture.data(literal.uppercased())
    let unrelated = try fixture.data(fixture.bundleID)
    let service = fixture.service()
    let context = service.makeContext()
    #expect(!context.inventory.complete && context.inventory.installedRootsComplete == true)
    #expect(context.inventory.applications.isEmpty)
    let observation = try #require(context.inventory.applicationMetadata.first { $0.path == owner })
    guard case .declaredID(let observed) = observation.state else {
      Issue.record("Readable literal identifier was lost")
      return
    }
    #expect(observed == literal)
    let candidates = await service.discover(context: context)
    let owned = try #require(candidates.first { $0.path == sameID })
    #expect(!owned.canSelect && !owned.defaultSelected)
    #expect(owned.refusalEvidence.contains { $0.reason == .observedLiteralOwner && $0.ownerPaths == [owner] })
    #expect(throws: RelatedFailure.self) { try service.plan(candidate: owned) }
    let orphan = try #require(candidates.first { $0.path == unrelated })
    #expect(orphan.classification == .orphanVerified)
    let available = await service.availableOrphanPlan(candidate: orphan, context: context)
    let plan = try #require(available.plan)
    #expect(available.rejections.isEmpty)
    try service.validateOrphan(plan.items[0], plan: plan)
    try fixture.info(owner + "/Contents/Info.plist", id: fixture.bundleID)
    #expect(throws: RelatedFailure.self) { try service.validateOrphan(plan.items[0], plan: plan) }
    #expect(service.ownershipRefusalEvidence(for: plan).contains { $0.reason == .observedLiteralOwner })
    try FileManager.default.removeItem(atPath: owner)
    let snapshot = try await ScanService(homeDirectory: fixture.home).scan(rootPath: sameID)
    let forged = RelatedDataCandidate(
      id: sameID, path: sameID, classification: .orphanVerified, reason: .orphanVerified,
      snapshot: snapshot, receipt: nil, bundleID: literal.uppercased())
    #expect(throws: RelatedFailure.invalidReceipt) { try service.plan(candidate: forged) }
  }

  @Test(
    "A known all-layout Info absence must remain absent through final validation",
    arguments: ["Contents/Info.plist", "Info.plist", "Resources/Info.plist", "Wrapper/Inner.app/Info.plist"])
  func absentInfoIsBoundAndRechecked(_ layout: String) async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let empty = fixture.apps + "/LightenQA-empty.app"
    try FileManager.default.createDirectory(atPath: empty + "/Contents", withIntermediateDirectories: true)
    let path = try fixture.data(fixture.bundleID)
    let service = fixture.service()
    let context = service.makeContext()
    #expect(!context.inventory.complete && context.inventory.installedRootsComplete == true)
    let observation = try #require(context.inventory.applicationMetadata.first { $0.path == empty })
    guard case .absentInfo = observation.state else {
      Issue.record("True Info absence was not retained")
      return
    }
    #expect(observation.root != nil && observation.volumeID != nil)
    let candidate = try #require((await service.discover(context: context)).first { $0.path == path })
    let available = await service.availableOrphanPlan(candidate: candidate, context: context)
    let plan = try #require(available.plan)
    try service.validateOrphan(plan.items[0], plan: plan)
    #expect(service.ownershipRefusalEvidence(for: plan).isEmpty)
    // Even an unrelated new ID invalidates the original negative observation.
    try fixture.info(empty + "/" + layout, id: "qa.lighten.unrelated")
    #expect(throws: RelatedFailure.changedItem) { try service.validateOrphan(plan.items[0], plan: plan) }
    let evidence = try #require(service.ownershipRefusalEvidence(for: plan).first { $0.reason == .infoAbsenceChanged })
    #expect(evidence.ownerPaths == [empty] && evidence.nextStep == "scan-again")
  }

  @Test("Unsafe Info links and ambiguous wrappers are unknown metadata, never an absence")
  func unsafeLayoutsCannotMintAbsence() throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let linked = fixture.apps + "/LightenQA-linked-info.app"
    let target = fixture.home + "/Info.plist"
    try fixture.info(target, id: nil)
    try FileManager.default.createDirectory(atPath: linked + "/Contents", withIntermediateDirectories: true)
    #expect(symlink(target, linked + "/Contents/Info.plist") == 0)
    let wrapper = fixture.apps + "/LightenQA-wrapper.app"
    for name in ["First.app", "Second.app"] {
      try FileManager.default.createDirectory(atPath: wrapper + "/Wrapper/" + name, withIntermediateDirectories: true)
    }
    for path in [linked, wrapper] {
      let observation = ApplicationMetadataObservation.read(at: path)
      guard case .unknown = observation.state else {
        Issue.record("Unsafe or ambiguous layout became known absence")
        continue
      }
      #expect(throws: RelatedFailure.changedItem) { try observation.validateAbsence() }
    }
  }

  @Test("Unknown metadata vetoes matching folder and executable names, with current owner evidence")
  func unknownMetadataIsCandidateScoped() async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let owner = fixture.apps + "/LightenQA-opaque.app"
    try fixture.info(owner + "/Contents/Info.plist", id: nil, executable: "LightenQA-helper")
    try Data("invalid plist".utf8).write(to: URL(fileURLWithPath: owner + "/Info.plist"))
    let byFolder = try fixture.data("qa.lighten.LightenQA-opaque")
    let byExecutable = try fixture.data("qa.lighten.LightenQA-helper")
    let unrelated = try fixture.data(fixture.bundleID)
    let service = fixture.service()
    let context = service.makeContext()
    let candidates = await service.discover(context: context)
    for path in [byFolder, byExecutable] {
      let candidate = try #require(candidates.first { $0.path == path })
      #expect(candidate.classification == .uncertain && candidate.reason == .incompleteInventory)
      let evidence = try #require(candidate.refusalEvidence.first { $0.reason == .unknownMetadata })
      #expect(evidence.ownerPaths == [owner] && evidence.detail == "invalidInfoPlist")
      #expect(!candidate.canSelect)
      let refused = await service.availableOrphanPlan(candidate: candidate, context: context)
      #expect(refused.plan == nil && !refused.rejections.isEmpty)
    }
    let orphan = try #require(candidates.first { $0.path == unrelated })
    let available = await service.availableOrphanPlan(candidate: orphan, context: context)
    let plan = try #require(available.plan)
    try service.validateOrphan(plan.items[0], plan: plan)
    // A formerly unrelated opaque package becomes a relevant owner in place.
    try fixture.info(owner + "/Contents/Info.plist", id: fixture.bundleID)
    try FileManager.default.removeItem(atPath: owner + "/Info.plist")
    #expect(throws: RelatedFailure.self) { try service.validateOrphan(plan.items[0], plan: plan) }
  }

  @Test("Verified signer teams scope unknown metadata without relaxing group ownership")
  func signerTeamScopesUnknownMetadata() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let unknown = fixture.home + "/Applications/LightenQA-opaque.app"
    try FileManager.default.copyItem(atPath: fixture.app, toPath: unknown)
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let executable = "LightenQA-opaque-executable-" + token
    try FileManager.default.moveItem(
      atPath: unknown + "/Contents/MacOS/" + (fixture.executable as NSString).lastPathComponent,
      toPath: unknown + "/Contents/MacOS/" + executable)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "qa.lighten.opaque" + token,
        "CFBundleExecutable": executable,
      ], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: unknown + "/Contents/Info.plist"))
    try Data("malformed alternate Info".utf8).write(to: URL(fileURLWithPath: unknown + "/Info.plist"))
    let teamPath = RelatedLocation.caches.path(domain: "TEAM.qa.lighten.absent" + token, homeDirectory: fixture.home)
    let unrelatedPath = RelatedLocation.caches.path(domain: "qa.lighten.absent" + token, homeDirectory: fixture.home)
    #expect(!teamPath.contains(executable) && !unrelatedPath.contains(executable))
    for path in [teamPath, unrelatedPath] {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    let service = fixture.service { _ in
      ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID])
    }
    let context = service.makeContext()
    let candidates = await service.discover(context: context)
    let related = try #require(candidates.first { $0.path == teamPath })
    #expect(related.reason == .incompleteInventory && !related.canSelect)
    #expect(related.refusalEvidence.contains { $0.reason == .unknownMetadata && $0.ownerPaths == [unknown] })
    let selected = try #require(candidates.first { $0.path == fixture.cache })
    #expect(selected.classification == .installed && selected.canSelect && selected.defaultSelected)
    #expect(selected.refusalEvidence.isEmpty)
    let app = try #require(service.application(at: fixture.app))
    let available = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [selected], includePackage: false, context: context)
    let plan = try #require(available.plan)
    #expect(available.rejections.isEmpty && service.prepareInstalledOwners(plan: plan).failures.isEmpty)
    let group = try #require(candidates.first { $0.path == fixture.group })
    #expect(group.classification == .shared && !group.canSelect && !group.defaultSelected)
    let refused = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [group], includePackage: false, context: context)
    #expect(refused.plan == nil && !refused.rejections.isEmpty)
    let unrelated = try #require(candidates.first { $0.path == unrelatedPath })
    #expect(unrelated.classification == .orphanVerified, "\(unrelated.reason): \(unrelated.refusalEvidence)")
    #expect(unrelated.refusalEvidence.isEmpty)
  }

  @Test("Orphan absence authority requires its original complete plan binding, including after eviction")
  func negativeEvidenceCannotBeRecreatedFromPublicPlan() async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let empty = fixture.apps + "/LightenQA-empty.app"
    try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
    let path = try fixture.data(fixture.bundleID)
    let service = fixture.service()
    let context = service.makeContext()
    let candidate = try #require((await service.discover(context: context)).first { $0.path == path })
    let available = await service.availableOrphanPlan(candidate: candidate, context: context)
    let original = try #require(available.plan)
    try service.validateOrphan(original.items[0], plan: original)
    let changed = ActionPlan(
      id: original.id, snapshotRunID: original.snapshotRunID, kind: original.kind,
      createdAt: original.createdAt.addingTimeInterval(1), items: original.items)
    #expect(throws: RelatedFailure.incompleteInventory) {
      try service.validateOrphan(changed.items[0], plan: changed)
    }
    #expect(service.ownershipRefusalEvidence(for: changed).isEmpty)
    #expect(throws: RelatedFailure.incompleteInventory) {
      try fixture.service().validateOrphan(original.items[0], plan: original)
    }
    for _ in 0..<65 {
      let next = await service.availableOrphanPlan(candidate: candidate, context: context)
      #expect(next.plan != nil && next.rejections.isEmpty)
    }
    #expect(throws: RelatedFailure.incompleteInventory) {
      try service.validateOrphan(original.items[0], plan: original)
    }
    #expect(service.ownershipRefusalEvidence(for: original).isEmpty)
  }

  @Test("A large shared native lineage retains original orphan authority and all fresh absence vetoes")
  func largeLineageKeepsOriginalAbsenceBinding() async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let empty = fixture.apps + "/LightenQA-empty.app"
    try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
    let path = try fixture.data(fixture.bundleID)
    let service = fixture.service()
    let original = service.makeContext()
    // A sparse observation models the large native code universe without
    // making this fixture create or walk one hundred thousand directories.
    let lineage =
      original.lineage
      + (0...100_000).map {
        ApplicationPathObservation(path: fixture.home + "/native-observation-" + String($0), identity: nil)
      }
    let context = AuthenticApplicationContext(
      scope: original.scope, inventory: original.inventory, lineage: lineage,
      registeredPaths: original.registeredPaths, installedListing: original.installedListing,
      metadata: original.metadata)
    let candidate = try #require((await service.discover(context: context)).first { $0.path == path })
    #expect(candidate.classification == .orphanVerified && context.lineage.count > 100_000)
    let first = await service.availableOrphanPlan(candidate: candidate, context: context)
    let firstPlan = try #require(first.plan)
    let second = await service.availableOrphanPlan(candidate: candidate, context: context)
    let secondPlan = try #require(second.plan)
    #expect(first.rejections.isEmpty && second.rejections.isEmpty)
    try service.validateOrphan(firstPlan.items[0], plan: firstPlan)
    try service.validateOrphan(secondPlan.items[0], plan: secondPlan)
    let sibling = fixture.apps + "/LightenQA-new-unregistered.app"
    try fixture.application(sibling, id: fixture.bundleID)
    #expect(throws: RelatedFailure.self) { try service.validateOrphan(firstPlan.items[0], plan: firstPlan) }
    #expect(throws: RelatedFailure.self) { try service.validateOrphan(secondPlan.items[0], plan: secondPlan) }
    #expect(service.ownershipRefusalEvidence(for: firstPlan).contains { $0.ownerPaths == [sibling] })
    try FileManager.default.removeItem(atPath: sibling)
    try fixture.info(empty + "/Resources/Info.plist", id: "qa.lighten.new-unrelated")
    #expect(throws: RelatedFailure.changedItem) { try service.validateOrphan(firstPlan.items[0], plan: firstPlan) }
    #expect(service.ownershipRefusalEvidence(for: firstPlan).contains { $0.reason == .infoAbsenceChanged })
  }

  @Test("A previously absent configured install root cannot acquire an unregistered owner after review")
  func absentInstalledRootRemainsBound() async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let absentRoot = fixture.home + "/NewApplications"
    let path = try fixture.data(fixture.bundleID)
    let service = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.apps, absentRoot], writeVerifiedReceipts: false,
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
    let context = service.makeContext()
    #expect(context.inventory.installedRootsComplete == true)
    #expect(context.inventory.observedDirectories.contains { $0.path == absentRoot && $0.identity == nil })
    let candidate = try #require((await service.discover(context: context)).first { $0.path == path })
    let available = await service.availableOrphanPlan(candidate: candidate, context: context)
    let plan = try #require(available.plan)
    try service.validateOrphan(plan.items[0], plan: plan)
    try fixture.application(absentRoot + "/LightenQA-unregistered.app", id: fixture.bundleID)
    #expect(throws: RelatedFailure.changedItem) { try service.validateOrphan(plan.items[0], plan: plan) }
  }

  @Test("An actually unreadable installed root remains incomplete with its native errno and exact path")
  func unreadableInstalledRootNamesActualFailure() async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let unreadable = fixture.apps + "/Unreadable"
    try FileManager.default.createDirectory(atPath: unreadable, withIntermediateDirectories: true)
    defer { _ = chmod(unreadable, 0o700) }
    let path = try fixture.data(fixture.bundleID)
    #expect(chmod(unreadable, 0) == 0)
    let service = fixture.service()
    let context = service.makeContext()
    #expect(context.inventory.installedRootsComplete == false)
    #expect(context.installedListing.ownershipIssues.contains { $0.path == unreadable && $0.code == EACCES })
    let candidate = try #require((await service.discover(context: context)).first { $0.path == path })
    #expect(!candidate.canSelect && candidate.reason == .incompleteInventory)
    let available = await service.availableOrphanPlan(candidate: candidate, context: context)
    #expect(available.plan == nil)
    #expect(
      available.rejections.contains {
        $0.ruleID?.contains("installed application listing incomplete") == true
          && $0.ruleID?.contains(unreadable + " (errno " + String(EACCES) + ")") == true
      })
  }

  @Test("Insufficient private context capacity refuses binding instead of returning stale authority")
  func contextCapacityRefusesExplicitly() async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let one = try fixture.data(fixture.bundleID)
    let two = try fixture.data(fixture.bundleID + ".other")
    let service = fixture.service()
    let context = service.makeContext()
    let candidates = await service.discover(context: context)
    let a = await service.availableOrphanPlan(
      candidate: try #require(candidates.first { $0.path == one }), context: context)
    let b = await service.availableOrphanPlan(
      candidate: try #require(candidates.first { $0.path == two }), context: context)
    let first = try #require(a.plan)
    let second = try #require(b.plan)
    let other = AuthenticApplicationContext(
      scope: context.scope, inventory: context.inventory, lineage: context.lineage,
      registeredPaths: context.registeredPaths)
    let combined = ActionPlan(snapshotRunID: first.snapshotRunID, kind: .trash, items: first.items + second.items)
    let bindings = ApplicationPlanContexts(maximumAdditionalPaths: 0)
    do {
      try bindings.bind(combined, contexts: [first.items[0].id: context, second.items[0].id: other])
      Issue.record("An over-capacity private context was silently accepted")
    } catch let refusal as PlanRejection {
      #expect(refusal.reason == .unavailable && refusal.ruleID?.hasPrefix("application-context-capacity:") == true)
    }
    #expect(bindings.context(for: combined, scope: context.scope, itemID: first.items[0].id) == nil)
    try bindings.bind(first, context: context)
    #expect(bindings.context(for: first, scope: context.scope, itemID: first.items[0].id) === context)
  }

  @Test("Shared installed data reports every current physical installation and a concrete next step")
  func sharedOwnersAreFreshPhysicalEvidence() async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let selected = fixture.apps + "/LightenQA-selected.app"
    let other = fixture.apps + "/LightenQA-other.app"
    try fixture.application(selected, id: fixture.bundleID)
    try fixture.application(other, id: fixture.bundleID.uppercased())
    let path = try fixture.data(fixture.bundleID)
    let service = fixture.service()
    let app = try #require(service.application(at: selected))
    let context = service.makeContext()
    let candidate = try #require((await service.discover(context: context)).first { $0.path == path })
    #expect(candidate.classification == .shared && candidate.reason == .sharedInstalledData && !candidate.canSelect)
    let evidence = try #require(candidate.refusalEvidence.first { $0.reason == .sharedInstalledOwners })
    #expect(evidence.ownerPaths == [other, selected].sorted() && evidence.nextStep == "review-other-installations")
    let refusal = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [candidate], includePackage: false, context: context)
    #expect(refusal.plan == nil && refusal.rejections.contains { $0.path == path && $0.ruleID == "ambiguousOwner" })
    #expect(refusal.refusalEvidence.contains { $0.ownerPaths == evidence.ownerPaths })
  }

  @Test(
    "Unrelated malformed, unreadable and literal metadata cannot poison fresh shared-owner evidence",
    arguments: ["malformed", "unreadable"])
  func sharedOwnersRemainCandidateScoped(_ failure: String) async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let selected = fixture.apps + "/LightenQA-selected.app"
    let other = fixture.apps + "/LightenQA-other.app"
    let unrelated = fixture.apps + "/LightenQA-unrelated.app"
    let literal = fixture.apps + "/LightenQA-literal.app"
    try fixture.application(selected, id: fixture.bundleID)
    try fixture.application(other, id: fixture.bundleID)
    try fixture.application(unrelated, id: "qa.lighten.unrelated")
    try fixture.application(literal, id: "pinterest")
    let path = try fixture.data(fixture.bundleID)
    let service = fixture.service()
    let context = service.makeContext()
    try Data("malformed unrelated metadata".utf8).write(to: URL(fileURLWithPath: unrelated + "/Contents/Info.plist"))
    if failure == "unreadable" { #expect(chmod(unrelated + "/Contents/Info.plist", 0) == 0) }
    let candidate = try #require((await service.discover(context: context)).first { $0.path == path })
    #expect(candidate.classification == .shared && candidate.reason == .sharedInstalledData)
    #expect(
      candidate.refusalEvidence.contains {
        $0.reason == .sharedInstalledOwners && $0.ownerPaths == [other, selected].sorted()
      })
    let app = try #require(service.application(at: selected))
    let refusal = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [candidate], includePackage: false, context: context)
    #expect(refusal.plan == nil && refusal.rejections.contains { $0.ruleID == "ambiguousOwner" })
    #expect(
      refusal.refusalEvidence.contains {
        $0.reason == .sharedInstalledOwners && $0.ownerPaths == [other, selected].sorted()
      })
    let related = fixture.apps + "/" + fixture.bundleID + ".app"
    try FileManager.default.createDirectory(atPath: related + "/Contents", withIntermediateDirectories: true)
    try Data("unknown related owner".utf8).write(to: URL(fileURLWithPath: related + "/Contents/Info.plist"))
    let fresh = service.makeContext()
    let unknown = try #require((await service.discover(context: fresh)).first { $0.path == path })
    #expect(unknown.classification == .uncertain && unknown.reason == .incompleteInventory)
    #expect(unknown.refusalEvidence.contains { $0.reason == .unknownMetadata && $0.ownerPaths == [related] })
    #expect(!unknown.refusalEvidence.contains { $0.reason == .sharedInstalledOwners })
  }

  @Test("A new second owner refuses a bound plan and fresh evidence does not retain a removed owner")
  func newAndRemovedOwnersRefreshEvidence() async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let selected = fixture.apps + "/LightenQA-selected.app"
    let other = fixture.apps + "/LightenQA-other.app"
    try fixture.application(selected, id: fixture.bundleID)
    let path = try fixture.data(fixture.bundleID)
    let service = fixture.service()
    let app = try #require(service.application(at: selected))
    let context = service.makeContext()
    let candidate = try #require((await service.discover(context: context)).first { $0.path == path })
    let available = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [candidate], includePackage: false, context: context)
    let plan = try #require(available.plan)
    #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
    try fixture.application(other, id: fixture.bundleID)
    #expect(service.prepareInstalledOwners(plan: plan).failures.values.contains("ambiguousOwner"))
    let evidence = service.ownershipRefusalEvidence(for: plan)
    #expect(evidence.contains { $0.reason == .sharedInstalledOwners && $0.ownerPaths == [other, selected].sorted() })
    let session = ApplicationScanSession(related: service, uptime: { 0 })
    #expect(await session.ownershipRefusalEvidence(for: plan) == evidence)
    try FileManager.default.removeItem(atPath: other)
    #expect(!service.ownershipRefusalEvidence(for: plan).contains { $0.reason == .sharedInstalledOwners })
    let unknown = fixture.apps + "/" + fixture.bundleID + ".app"
    try FileManager.default.createDirectory(atPath: unknown + "/Contents", withIntermediateDirectories: true)
    try Data("unknown owner metadata".utf8).write(to: URL(fileURLWithPath: unknown + "/Contents/Info.plist"))
    #expect(!service.prepareInstalledOwners(plan: plan).failures.isEmpty)
    let current = service.ownershipRefusalEvidence(for: plan)
    #expect(current.contains { $0.reason == .unknownMetadata && $0.ownerPaths == [unknown] })
    #expect(!current.contains { $0.reason == .sharedInstalledOwners })
    await session.cancel()
    #expect(await session.ownershipRefusalEvidence(for: plan).isEmpty)
  }

  @Test(
    "Build, simulator, Trash and cache copies cannot count as installed standard owners",
    arguments: ["Library/Caches", "Build/DerivedData", "Library/CoreSimulator", ".Trash", "vendor/node_modules"])
  func cachedCopiesAreNotInstalledStandardOwners(_ directory: String) async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let selected = fixture.apps + "/LightenQA-selected.app"
    let copy = fixture.home + "/" + directory + "/LightenQA-copy.app"
    try fixture.application(selected, id: fixture.bundleID)
    try fixture.application(copy, id: fixture.bundleID)
    let path = try fixture.data(fixture.bundleID)
    let service = fixture.service(registered: [selected, copy])
    let app = try #require(service.application(at: selected))
    let context = service.makeContext()
    #expect(context.inventory.applications.contains { $0.path == copy })
    let candidate = try #require((await service.discover(context: context)).first { $0.path == path })
    #expect(candidate.classification == .installed && candidate.canSelect)
    let available = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [candidate], includePackage: false, context: context)
    let plan = try #require(available.plan)
    #expect(available.rejections.isEmpty && service.prepareInstalledOwners(plan: plan).failures.isEmpty)
    let cachedApp = try #require(service.application(at: copy))
    #expect(throws: RelatedFailure.self) { try service.planInstalled(app: cachedApp, candidate: candidate) }
    let session = ApplicationDiscovery(related: service).scanSession()
    var reports: [ApplicationReport] = []
    var streamed: [RelatedDataCandidate] = []
    for await event in await session.events(includeAllRelated: true) {
      if case .related(let observedPath, let candidates, _) = event, observedPath == copy {
        #expect(!candidates.contains { $0.path == path })
      }
      if case .completed(_, let final) = event { reports = final }
    }
    streamed = await session.observedRelatedCandidates()
    #expect(reports.first { $0.path == selected }?.related.contains { $0.path == path } == true)
    #expect(reports.first { $0.path == copy }?.related.isEmpty == true)
    #expect(
      reports.first { $0.path == selected }?.displayRootIdentity == (try DescriptorFileSystem.identity(at: selected)))
    #expect(reports.first { $0.path == copy }?.displayRootIdentity == (try DescriptorFileSystem.identity(at: copy)))
    #expect(streamed.contains { $0.path == path && $0.snapshot != nil })
    let refusedCopy = await session.makeAvailableUninstallPlan(
      app: cachedApp, selectedRelated: [candidate], includePackage: false)
    #expect(refusedCopy.plan == nil)
    #expect(
      refusedCopy.rejections.contains {
        $0.path == path && $0.ruleID?.contains("cache-copy-is-not-installed-owner: " + copy) == true
          && $0.ruleID?.contains(selected) == true
      })
    await session.cancel()
    try FileManager.default.removeItem(atPath: selected)
    let fresh = service.makeContext()
    let orphan = try #require((await service.discover(context: fresh)).first { $0.path == path })
    #expect(orphan.classification == .orphanVerified)
    let absent = await service.availableOrphanPlan(candidate: orphan, context: fresh)
    let absentPlan = try #require(absent.plan)
    try service.validateOrphan(absentPlan.items[0], plan: absentPlan)
  }

  @Test("Fresh shared-owner evidence notices an unrelated sibling acquiring the ID without registry changes")
  func sharedEvidenceRechecksSiblingInfoInPlace() async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let selected = fixture.apps + "/LightenQA-selected.app"
    let sibling = fixture.apps + "/LightenQA-sibling.app"
    try fixture.application(selected, id: fixture.bundleID)
    try fixture.application(sibling, id: "qa.lighten.unrelated")
    let path = try fixture.data(fixture.bundleID)
    let service = fixture.service()
    let context = service.makeContext()
    let app = try #require(service.application(at: selected))
    let candidate = try #require((await service.discover(context: context)).first { $0.path == path })
    let available = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [candidate], includePackage: false, context: context)
    let plan = try #require(available.plan)
    #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
    try fixture.info(sibling + "/Contents/Info.plist", id: fixture.bundleID)
    #expect(service.prepareInstalledOwners(plan: plan).failures.values.contains("ambiguousOwner"))
    #expect(
      service.ownershipRefusalEvidence(for: plan).contains {
        $0.reason == .sharedInstalledOwners && $0.ownerPaths == [selected, sibling].sorted()
      })
  }

  @Test("A cached code owner still vetoes shared group data")
  func cachedCopiesRemainGroupOwners() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let copy = fixture.home + "/Library/Caches/LightenQA-copy.app"
    try FileManager.default.copyItem(atPath: fixture.app, toPath: copy)
    let service = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"],
      ownershipApplicationRoots: [fixture.home + "/Applications", fixture.home + "/Library/Caches"],
      writeVerifiedReceipts: false,
      signingMetadata: { _ in ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID]) },
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
      registration: { ApplicationRegistrationObservation(paths: [copy], complete: true) })
    let app = try #require(service.application(at: fixture.app))
    let candidate = try #require((await service.discover(for: app)).first { $0.path == fixture.group })
    #expect(candidate.classification == .shared && candidate.reason == .sharedGroup)
    #expect(!candidate.canSelect && !candidate.defaultSelected)
    #expect(throws: RelatedFailure.self) { try service.planInstalled(app: app, candidate: candidate) }
  }

  @Test("A running same-ID cache copy still refuses installed-data execution")
  func runningCachedCopyStillVetoesExecution() async throws {
    let fixture = try ScopedOwnerFixture()
    defer { fixture.cleanup() }
    let selected = fixture.apps + "/LightenQA-selected.app"
    let copy = fixture.home + "/Library/Caches/LightenQA-copy.app"
    try fixture.application(selected, id: fixture.bundleID)
    try fixture.application(copy, id: fixture.bundleID)
    let path = try fixture.data(fixture.bundleID)
    let service = fixture.service(registered: [selected, copy])
    let app = try #require(service.application(at: selected))
    #expect(ApplicationIdentity.bundleIdentifier(ofApplicationAt: copy) == fixture.bundleID)
    let candidate = try #require((await service.discover()).first { $0.path == path })
    let plan = try service.planInstalled(app: app, candidate: candidate)
    #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
    let trash = ScopedTrashSpy()
    let executor = ActionExecutor(
      journal: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"), trash: trash,
      guardService: ActionGuard(homeDirectory: fixture.home), related: service,
      runningApplications: ScopedRunningCopy(bundleID: fixture.bundleID),
      applicationActivity: FixtureClearApplicationActivity())
    let result = try await executor.execute(plan)
    #expect(result.items.first?.outcome == .skipped && result.items.first?.detail == "runningOrUnknown")
    #expect(await trash.count() == 0)
    #expect(FileManager.default.fileExists(atPath: path + "/record"))
  }
}
