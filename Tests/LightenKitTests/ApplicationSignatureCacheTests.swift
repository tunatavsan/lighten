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

}
