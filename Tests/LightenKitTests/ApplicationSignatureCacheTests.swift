import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

struct SignatureFixture: Sendable {
  let home: String
  let app: String
  let executable: String
  let resources: String
  let bundleID: String
  let groupID: String
  let group: String
  let cache: String

  init() throws {
    let temporary = try #require(realpath("/tmp", nil))
    defer { free(temporary) }
    let token = UUID().uuidString
    home = String(cString: temporary) + "/LightenQA-" + token
    bundleID = "qa.lighten." + token
    groupID = "group." + bundleID
    app = home + "/Applications/LightenQA-" + token + ".app"
    executable = app + "/Contents/MacOS/LightenQA-" + token
    resources = app + "/Contents/_CodeSignature/CodeResources"
    group = RelatedLocation.groupContainers.path(domain: groupID, homeDirectory: home)
    cache = RelatedLocation.caches.path(domain: bundleID, homeDirectory: home)
    for path in [app + "/Contents/MacOS", app + "/Contents/_CodeSignature", group, cache, home + "/Trash"] {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": bundleID, "CFBundleExecutable": "LightenQA-" + token,
        "CFBundleVersion": "1",
      ], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
    try Data("signed resource manifest".utf8).write(to: URL(fileURLWithPath: resources))
    try Data("group data".utf8).write(to: URL(fileURLWithPath: group + "/record"))
    try Data("cache data".utf8).write(to: URL(fileURLWithPath: cache + "/record"))
  }

  func service(reader: @escaping @Sendable (String) -> ApplicationSigningMetadata?) -> RelatedDataService {
    RelatedDataService(
      homeDirectory: home, applicationRoots: [home + "/Applications"], writeVerifiedReceipts: false,
      signingMetadata: reader, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: home) }
}

private func rewriteRestoringModification(_ path: String) throws {
  var original = stat()
  #expect(lstat(path, &original) == 0)
  var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
  bytes[bytes.startIndex] ^= 1
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
  defer { try? handle.close() }
  try handle.write(contentsOf: bytes)
  var times = [original.st_atimespec, original.st_mtimespec]
  #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)
}

private struct SignatureNotRunning: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
}

private actor SignatureTrash: TrashMoving {
  let directory: String
  private var attempts: [String] = []
  init(directory: String) { self.directory = directory }
  func moveToTrash(path: String) async throws -> String {
    attempts.append(path)
    let destination = directory + "/" + (path as NSString).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: destination)
    return destination
  }
  func paths() -> [String] { attempts }
}

private final class SignatureLeaseState: Sendable {
  let value = Mutex(false)
}

private actor SignatureLeaseSpy: ActionJournal {
  let base: JSONLActionJournal
  let leased: SignatureLeaseState
  let onAcquire: (@Sendable () throws -> Void)?

  init(base: JSONLActionJournal, leased: SignatureLeaseState, onAcquire: (@Sendable () throws -> Void)? = nil) {
    self.base = base
    self.leased = leased
    self.onAcquire = onAcquire
  }
  func acquireMutationLease() async throws -> JournalLease {
    let lease = try await base.acquireMutationLease()
    leased.value.withLock { $0 = true }
    do { try onAcquire?() } catch {
      leased.value.withLock { $0 = false }
      await base.releaseMutationLease(lease)
      throw error
    }
    return lease
  }
  func releaseMutationLease(_ lease: JournalLease) async {
    leased.value.withLock { $0 = false }
    await base.releaseMutationLease(lease)
  }
  func append(_ record: JournalRecord) async throws { try await base.append(record) }
  func read() async throws -> JournalReadout { try await base.read() }
  func readSummary() async throws -> JournalReadout { try await base.readSummary() }
  func loadPlan(id: UUID) async throws -> ActionPlan { try await base.loadPlan(id: id) }
}

@Suite("Application signature identity cache")
struct ApplicationSignatureCacheTests {
  @Test("Exact-ID private ownership does not require an executable or a signature", arguments: [false, true])
  func exactIDAuthorityUsesOnlyCurrentOwnerMetadata(missingExecutable: Bool) async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    if missingExecutable { try FileManager.default.removeItem(atPath: fixture.executable) }
    let reads = Mutex(0)
    let service = fixture.service { _ in
      reads.withLock { $0 += 1 }
      return nil
    }
    let app = try #require(service.application(at: fixture.app))
    let candidate = try #require(
      (await service.initialReview(for: app, progress: nil)).candidates.first {
        $0.path == fixture.cache
      })
    let context = service.makeStandardContext(app: app, listing: service.installedListing())
    let available = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [candidate], includePackage: false, context: context)
    let plan = try #require(available.plan)
    #expect(available.rejections.isEmpty)
    let prepared = service.prepareInstalledOwners(plan: plan)
    #expect(prepared.failures.isEmpty && prepared.owners.count == 1)
    #expect(reads.withLock { $0 } == 0)
    try rewriteRestoringModification(fixture.app + "/Contents/Info.plist")
    #expect(!service.prepareInstalledOwners(plan: plan).failures.isEmpty)
  }

  @Test("One unchanged observation reads each signer once, including unsuccessful reads", arguments: [false, true])
  func unchangedSignerIsReadOnce(success: Bool) async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    let cache = ApplicationSignatureCache { _ in
      calls.withLock { $0 += 1 }
      return success ? ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID]) : nil
    }
    _ = cache.observation(at: fixture.app)
    _ = cache.observation(at: fixture.app)
    #expect(calls.withLock { $0 } == 1)
    let service = fixture.service { _ in
      calls.withLock { $0 += 1 }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID])
    }
    let app = try #require(service.application(at: fixture.app))
    _ = await service.discover(for: app)
    _ = await service.discover(for: app)
    #expect(calls.withLock { $0 } == 2)
  }

  @Test(
    "Restoring mtime cannot preserve a signature cache hit", arguments: ["executable", "CodeResources", "Info.plist"])
  func changedSignedIdentityInvalidatesCache(_ kind: String) throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    let cache = ApplicationSignatureCache { _ in
      calls.withLock { $0 += 1 }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID])
    }
    let before = try #require(cache.observation(at: fixture.app))
    let path =
      kind == "executable"
      ? fixture.executable
      : kind == "CodeResources"
        ? fixture.resources
        : fixture.app + "/Contents/Info.plist"
    let identity = try DescriptorFileSystem.identity(at: path)
    if kind == "Info.plist" {
      var data = try String(contentsOfFile: path, encoding: .utf8)
      data = data.replacingOccurrences(of: "<string>1</string>", with: "<string>2</string>")
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      try handle.write(contentsOf: Data(data.utf8))
      try handle.close()
      var times = [
        timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
        timespec(tv_sec: Int(identity.modificationSeconds!), tv_nsec: Int(identity.modificationNanoseconds!)),
      ]
      #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)
    } else {
      try rewriteRestoringModification(path)
    }
    let current = try DescriptorFileSystem.identity(at: path)
    #expect(current.device == identity.device && current.inode == identity.inode)
    #expect(current.modificationSeconds == identity.modificationSeconds)
    #expect(current.modificationNanoseconds == identity.modificationNanoseconds)
    #expect(current != identity)
    #expect(throws: RelatedFailure.self) { try before.identity.validate() }
    #expect(cache.observation(at: fixture.app)?.metadata != nil)
    #expect(calls.withLock { $0 } == 2)
  }

  @Test("Fast cached signing never performs a cold read and rejects changed signed metadata")
  func cachedSigningRequiresPreviousCurrentValidation() throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    let cache = ApplicationSignatureCache { _ in
      calls.withLock { $0 += 1 }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [])
    }
    #expect(cache.cachedMetadata(at: fixture.app) == nil && calls.withLock { $0 } == 0)
    #expect(cache.observation(at: fixture.app)?.metadata?.teamID == "TEAM")
    #expect(cache.cachedMetadata(at: fixture.app)?.teamID == "TEAM" && calls.withLock { $0 } == 1)
    try rewriteRestoringModification(fixture.resources)
    #expect(cache.cachedMetadata(at: fixture.app) == nil && calls.withLock { $0 } == 1)
    #expect(cache.observation(at: fixture.app)?.metadata?.teamID == "TEAM" && calls.withLock { $0 } == 2)
  }

  @Test("Unchanged team evidence enriches initial exact rows without another signing read")
  func cachedTeamPreselectsOnlyUniqueExactOwner() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    let service = fixture.service { _ in
      calls.withLock { $0 += 1 }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [])
    }
    let path = RelatedLocation.caches.path(domain: "TEAM." + fixture.bundleID, homeDirectory: fixture.home)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let app = try #require(service.application(at: fixture.app))
    let cold = await service.initialReview(for: app, progress: nil)
    #expect(cold.candidates.first { $0.path == path }?.defaultSelected != true && calls.withLock { $0 } == 0)
    _ = await service.discover(for: app)
    let reads = calls.withLock { $0 }
    let warm = await service.initialReview(for: app, progress: nil)
    #expect(warm.candidates.first { $0.path == path }?.defaultSelected == true)
    #expect(calls.withLock { $0 } == reads)
    let copy = fixture.home + "/Applications/Previous.app"
    try FileManager.default.copyItem(atPath: fixture.app, toPath: copy)
    let shared = await service.initialReview(for: app, progress: nil)
    #expect(shared.candidates.first { $0.path == path }?.defaultSelected == false)
    #expect(calls.withLock { $0 } == reads)
  }

  @Test("Reference helper evidence shares the service's validated signing cache")
  func referenceHelpersReuseValidatedServiceSigners() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let helperID = fixture.bundleID + ".helper"
    let helper = fixture.app + "/Contents/Frameworks/Fixture Helper.app"
    try FileManager.default.createDirectory(atPath: helper + "/Contents/MacOS", withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": helperID, "CFBundleExecutable": "helper"], format: .xml, options: 0
    )
    .write(to: URL(fileURLWithPath: helper + "/Contents/Info.plist"))
    try Data("helper".utf8).write(to: URL(fileURLWithPath: helper + "/Contents/MacOS/helper"))
    let parent =
      fixture.home
      + "/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    let recent = parent + "/" + helperID.lowercased() + ".sfl4"
    try Data("recent".utf8).write(to: URL(fileURLWithPath: recent))
    let calls = Mutex<[String: Int]>([:])
    let service = fixture.service { path in
      calls.withLock { $0[path, default: 0] += 1 }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [])
    }
    let app = try #require(service.application(at: fixture.app))
    let candidates = await service.discover(for: app)
    let claimed = try #require(candidates.first { $0.path == recent })
    #expect(claimed.defaultSelected && claimed.evidenceKinds.contains(.bundleIdentifier))
    #expect(calls.withLock { $0[fixture.app] } == 1 && calls.withLock { $0[helper] } == 1)
  }

  @Test("Moving an authorized package uses selected stats and no signer while journal is leased")
  func noSigningInsideLease() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let leased = SignatureLeaseState()
    let leaseCalls = Mutex(0)
    let calls = Mutex(0)
    let service = fixture.service { _ in
      calls.withLock { $0 += 1 }
      if leased.value.withLock({ $0 }) { leaseCalls.withLock { $0 += 1 } }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID])
    }
    let app = try #require(service.application(at: fixture.app))
    let group = try #require((await service.discover(for: app)).first { $0.path == fixture.group })
    let plan = try service.planUninstall(app: app, selectedRelated: [group])
    let trash = SignatureTrash(directory: fixture.home + "/Trash")
    let journal = SignatureLeaseSpy(
      base: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"), leased: leased)
    let result = try await ActionExecutor(
      journal: journal, trash: trash, guardService: ActionGuard(homeDirectory: fixture.home), related: service,
      runningApplications: SignatureNotRunning(), applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items.allSatisfy { $0.outcome == .applied })
    #expect(await trash.paths() == [fixture.app, fixture.group])
    #expect(calls.withLock { $0 } == 1)
    #expect(leaseCalls.withLock { $0 } == 0)
  }

  @Test("A selected signature change after acquiring the lease refuses data without re-signing")
  func signatureChangesAfterPreparation() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let leased = SignatureLeaseState()
    let leaseCalls = Mutex(0)
    let service = fixture.service { _ in
      if leased.value.withLock({ $0 }) { leaseCalls.withLock { $0 += 1 } }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID])
    }
    let app = try #require(service.application(at: fixture.app))
    let group = try #require((await service.discover(for: app)).first { $0.path == fixture.group })
    let plan = try service.planInstalled(app: app, candidate: group)
    let trash = SignatureTrash(directory: fixture.home + "/Trash")
    let journal = SignatureLeaseSpy(
      base: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"), leased: leased,
      onAcquire: { try rewriteRestoringModification(fixture.resources) })
    let result = try await ActionExecutor(
      journal: journal, trash: trash, guardService: ActionGuard(homeDirectory: fixture.home), related: service,
      runningApplications: SignatureNotRunning(), applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items.allSatisfy { $0.outcome == .skipped })
    #expect(await trash.paths().isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.app))
    #expect(FileManager.default.fileExists(atPath: fixture.group))
    #expect(leaseCalls.withLock { $0 } == 0)
  }

  @Test("Injected services cannot reuse another reader's private plan authority")
  func injectedPlanContextsAreIsolated() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let trusted = fixture.service { _ in
      ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID])
    }
    let app = try #require(trusted.application(at: fixture.app))
    let candidate = try #require((await trusted.discover(for: app)).first { $0.path == fixture.group })
    let plan = try trusted.planInstalled(app: app, candidate: candidate)
    #expect(trusted.prepareInstalledOwners(plan: plan).failures.isEmpty)
    let unverified = fixture.service { _ in nil }
    let other = unverified.prepareInstalledOwners(plan: plan)
    #expect(other.owners.isEmpty && other.failures.count == 1)
  }

  @Test("Changing a complete plan binding requires one fresh universe for the whole plan")
  func planBindingRequiresFullEquality() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let walks = Mutex(0)
    let service = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"], writeVerifiedReceipts: false,
      signingMetadata: { _ in ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID]) },
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
      ownershipCollected: { walks.withLock { $0 += 1 } })
    let session = ApplicationDiscovery(related: service).scanSession()
    var chosen: [RelatedDataCandidate] = []
    for await event in await session.events(includeAllRelated: true) {
      if case .completed(_, let reports) = event { chosen = reports.first { $0.path == fixture.app }?.related ?? [] }
    }
    let app = try #require(service.application(at: fixture.app))
    let available = await session.makeAvailableUninstallPlan(
      app: app,
      selectedRelated: chosen.filter { $0.path == fixture.group || $0.path == fixture.cache })
    let plan = try #require(available.plan)
    #expect(available.rejections.isEmpty && walks.withLock { $0 } == 1)
    let changed = ActionPlan(
      id: plan.id, snapshotRunID: plan.snapshotRunID, kind: plan.kind,
      createdAt: plan.createdAt.addingTimeInterval(1), items: plan.items)
    let prepared = service.prepareInstalledOwners(plan: changed)
    #expect(prepared.failures.isEmpty && prepared.owners.count == 2)
    #expect(walks.withLock { $0 } == 2)
    #expect(service.prepareInstalledOwners(plan: changed).failures.isEmpty)
    #expect(walks.withLock { $0 } == 2)
    await session.cancel()
  }

  @Test("A cached owner signature change before planning invalidates group authority without re-reading the signer")
  func changedSignatureInvalidatesSessionPlan() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let reads = Mutex(0)
    let service = fixture.service { _ in
      reads.withLock { $0 += 1 }
      return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID])
    }
    let session = ApplicationDiscovery(related: service).scanSession()
    var candidate: RelatedDataCandidate?
    for await event in await session.events(includeAllRelated: true) {
      if case .completed(_, let reports) = event {
        candidate = reports.first { $0.path == fixture.app }?.related.first { $0.path == fixture.group }
      }
    }
    let app = try #require(service.application(at: fixture.app))
    let selected = try #require(candidate)
    #expect(selected.canSelect && reads.withLock { $0 } == 1)
    try rewriteRestoringModification(fixture.resources)
    let available = await session.makeAvailableUninstallPlan(
      app: app, selectedRelated: [selected], includePackage: false)
    #expect(available.plan == nil && !available.rejections.isEmpty)
    #expect(reads.withLock { $0 } == 1)
    await session.cancel()
  }

  @Test("A group signature failure leaves exact-ID items independently prepared and selectable")
  func mixedPlanPreservesExactOwnerAfterGroupSignatureChange() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let reads = Mutex(0)
    let walks = Mutex(0)
    let service = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"], writeVerifiedReceipts: false,
      signingMetadata: { _ in
        reads.withLock { $0 += 1 }
        return ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID])
      }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
      ownershipCollected: { walks.withLock { $0 += 1 } })
    let session = ApplicationDiscovery(related: service).scanSession()
    var candidates: [RelatedDataCandidate] = []
    for await event in await session.events(includeAllRelated: true) {
      if case .completed(_, let reports) = event {
        candidates =
          reports.first { $0.path == fixture.app }?.related.filter {
            $0.path == fixture.cache || $0.path == fixture.group
          } ?? []
      }
    }
    #expect(candidates.count == 2 && candidates.allSatisfy(\.canSelect))
    let app = try #require(service.application(at: fixture.app))
    let original = await session.makeAvailableUninstallPlan(
      app: app, selectedRelated: candidates, includePackage: false)
    let plan = try #require(original.plan)
    #expect(original.rejections.isEmpty && plan.items.count == 2)
    let cacheItem = try #require(plan.items.first { $0.sourcePath == fixture.cache })
    let groupItem = try #require(plan.items.first { $0.sourcePath == fixture.group })
    try rewriteRestoringModification(fixture.resources)
    let prepared = service.prepareInstalledOwners(plan: plan)
    #expect(prepared.owners[cacheItem.id] != nil && prepared.failures[cacheItem.id] == nil)
    #expect(prepared.owners[groupItem.id] == nil && prepared.failures[groupItem.id] != nil)
    let dryRefusals = await service.validatePlan(plan)
    #expect(!dryRefusals.isEmpty && dryRefusals.allSatisfy { $0.path == fixture.group })
    let partial = await session.makeAvailableUninstallPlan(
      app: app, selectedRelated: candidates, includePackage: false)
    let surviving = try #require(partial.plan)
    #expect(surviving.items.map(\.sourcePath) == [fixture.cache])
    #expect(!partial.rejections.isEmpty && partial.rejections.allSatisfy { $0.path == fixture.group })
    #expect(service.prepareInstalledOwners(plan: surviving).failures.isEmpty)
    #expect(await service.validatePlan(surviving).isEmpty)
    #expect(reads.withLock { $0 } == 1 && walks.withLock { $0 } == 1)
    await session.cancel()
  }

  @Test("An incomplete group universe cannot poison a private exact-ID selection")
  func mixedPartialOwnershipPreservesStandardSelection() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let external = fixture.home + "/External/LightenQA-unknown.app"
    try FileManager.default.createDirectory(atPath: external + "/Contents", withIntermediateDirectories: true)
    try Data("malformed plist".utf8).write(to: URL(fileURLWithPath: external + "/Contents/Info.plist"))
    let loop = external + "/Contents/LightenQA-unresolved-owner"
    #expect(symlink(loop, loop) == 0)
    let walks = Mutex(0)
    let service = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"], writeVerifiedReceipts: false,
      signingMetadata: { path in
        path == fixture.app ? ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID]) : nil
      }, packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
      registration: { ApplicationRegistrationObservation(paths: [external], complete: true) },
      registeredByID: { _ in ApplicationRegistrationObservation(paths: [], complete: true) },
      ownershipCollected: { walks.withLock { $0 += 1 } })
    let context = service.makeContext()
    #expect(!context.inventory.complete && !context.inventory.ownershipComplete)
    #expect(context.inventory.ownershipIssues.contains { $0.path == loop && $0.code == ELOOP })
    #expect(context.inventory.unresolvedApplicationMetadata.contains { $0.path == external })
    let candidates = await service.discover(context: context)
    let cache = try #require(candidates.first { $0.path == fixture.cache })
    let group = try #require(candidates.first { $0.path == fixture.group })
    #expect(cache.canSelect && !group.canSelect)
    let app = try #require(service.application(at: fixture.app))
    let partial = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [group, cache], includePackage: false, context: context)
    let plan = try #require(partial.plan)
    #expect(plan.items.map(\.sourcePath) == [fixture.cache])
    #expect(!partial.rejections.isEmpty && partial.rejections.allSatisfy { $0.path == fixture.group })
    #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
    #expect(await service.validatePlan(plan).isEmpty)
    #expect(walks.withLock { $0 } == 1)
  }

  @Test("Private context lookup cannot borrow a sibling item binding")
  func planContextRequiresBoundItem() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let service = fixture.service { _ in ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID])
    }
    let context = service.makeContext()
    let app = try #require(service.application(at: fixture.app))
    let candidate = try #require((await service.discover(context: context)).first { $0.path == fixture.cache })
    let plan = try service.planInstalled(app: app, candidate: candidate)
    let bindings = ApplicationPlanContexts()
    try bindings.bind(plan, context: context)
    #expect(bindings.context(for: plan, scope: context.scope, itemID: plan.items[0].id) === context)
    #expect(bindings.context(for: plan, scope: context.scope, itemID: UUID()) == nil)
  }

  @Test("Strict group lineage changes name the actual native observation while independent exact data remains valid")
  func changedGroupLineageNamesNativePath() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let mutable = fixture.home + "/OwnerLocations"
    try FileManager.default.createDirectory(atPath: mutable, withIntermediateDirectories: true)
    let service = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"],
      ownershipApplicationRoots: [fixture.home + "/Applications", mutable], writeVerifiedReceipts: false,
      signingMetadata: { _ in ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID]) },
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
    let context = service.makeContext()
    let app = try #require(service.application(at: fixture.app))
    let candidates = await service.discover(context: context)
    let group = try #require(candidates.first { $0.path == fixture.group })
    let cache = try #require(candidates.first { $0.path == fixture.cache })
    try Data("changed potential code location".utf8).write(to: URL(fileURLWithPath: mutable + "/new-file"))
    let available = await service.makeAvailableUninstallPlan(
      app: app, selectedRelated: [group, cache], includePackage: false, context: context)
    let plan = try #require(available.plan)
    #expect(plan.items.map(\.sourcePath) == [fixture.cache])
    #expect(
      available.rejections.contains {
        $0.path == fixture.group && $0.ruleID == "changedItem: ownership observation changed: " + mutable
      })
    #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
  }

  @Test("Linked aliases of one native root retain unique group ownership; a simulator claimant remains a second owner")
  func linkedGroupOwnerUsesOnePhysicalRoot() async throws {
    let fixture = try SignatureFixture()
    defer { fixture.cleanup() }
    let shared = fixture.home + "/Shared"
    let physical = shared + "/LightenQA-physical.app"
    try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: fixture.app, toPath: physical)
    let alias = fixture.home + "/Applications/LightenQA-alias.app"
    #expect(symlink(physical, fixture.app) == 0 && symlink(physical, alias) == 0)
    let registered = Mutex<[String]>([])
    let service = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"], writeVerifiedReceipts: false,
      signingMetadata: { _ in ApplicationSigningMetadata(teamID: "TEAM", groupIdentifiers: [fixture.groupID]) },
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
      registration: { ApplicationRegistrationObservation(paths: registered.withLock { $0 }, complete: true) })
    let observed = try #require(service.application(at: fixture.app))
    let candidates = await service.discover(for: observed)
    let group = try #require(candidates.first { $0.path == fixture.group })
    let cache = try #require(candidates.first { $0.path == fixture.cache })
    #expect(group.canSelect && cache.canSelect)
    let session = ApplicationDiscovery(related: service).scanSession()
    let available = await session.makeAvailableUninstallPlan(
      path: fixture.app, expectedBundleID: fixture.bundleID, selectedRelated: [group, cache], includePackage: true)
    let plan = try #require(available.plan)
    #expect(available.rejections.isEmpty && plan.items.count == 4)
    #expect(
      plan.items.filter { $0.installedRelatedProof != nil }.allSatisfy { $0.installedRelatedProof?.appPath == physical }
    )
    #expect(service.prepareInstalledOwners(plan: plan).failures.isEmpty)
    #expect(await session.validatePlan(plan).isEmpty)
    let simulator =
      fixture.home + "/Library/Developer/CoreSimulator/Devices/" + UUID().uuidString
      + "/data/Containers/Bundle/Application/" + UUID().uuidString + "/LightenQA-claimant.app"
    try FileManager.default.createDirectory(
      atPath: (simulator as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: physical, toPath: simulator)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "qa.lighten.second." + UUID().uuidString,
        "CFBundleExecutable": (fixture.executable as NSString).lastPathComponent,
      ],
      format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: simulator + "/Contents/Info.plist"))
    registered.withLock { $0 = [simulator] }
    let fresh = service.makeContext()
    #expect(fresh.inventory.scopeExclusions.contains { $0.path == simulator })
    #expect(fresh.inventory.ownershipCandidates.contains { $0.packagePath == simulator })
    let current = await service.makeAvailableUninstallPlan(
      app: observed, selectedRelated: [group, cache], includePackage: false, context: fresh)
    let surviving = try #require(current.plan)
    #expect(surviving.items.map(\.sourcePath) == [fixture.cache])
    #expect(current.rejections.contains { $0.path == fixture.group })
    #expect(service.prepareInstalledOwners(plan: surviving).failures.isEmpty)
    #expect(await service.validatePlan(surviving).isEmpty)
    await session.cancel()
  }

}
