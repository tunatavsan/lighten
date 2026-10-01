import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private struct CollisionHash: DuplicateHashing {
  func digest(fd: Int32, size: Int64) throws -> Data { Data(repeating: 7, count: 32) }
}

private struct ChangingHash: DuplicateHashing {
  let path: String

  func digest(fd: Int32, size: Int64) throws -> Data {
    let writer = open(path, O_WRONLY)
    guard writer >= 0 else { throw DuplicateFailure.unavailable }
    defer { close(writer) }
    var byte: UInt8 = 88
    guard pwrite(writer, &byte, 1, 0) == 1 else { throw DuplicateFailure.unavailable }
    return try SHA256DuplicateHashing().digest(fd: fd, size: size)
  }
}

private struct NoMove: TrashMoving {
  func moveToTrash(path: String) async throws -> String {
    Issue.record("Invalid duplicate plan reached Trash")
    throw DuplicateFailure.invalidSelection
  }
}

private struct FailingMove: TrashMoving {
  func moveToTrash(path: String) async throws -> String { throw DuplicateFailure.unavailable }
}

private struct NativeDuplicateTrash: TrashMoving {
  func moveToTrash(path: String) async throws -> String {
    try await Task.detached {
      var returned: NSURL?
      try FileManager.default.trashItem(
        at: URL(fileURLWithPath: path), resultingItemURL: &returned)
      guard let returned else { throw DuplicateFailure.unavailable }
      return (returned as URL).path
    }.value
  }
}

private func duplicateFixture() throws -> String {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
    throw DuplicateFailure.unavailable
  }
  defer { free(resolved) }
  let path = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

private func writeDuplicate(_ path: String, bytes: [UInt8] = Array("same fixture".utf8)) throws {
  try Data(bytes).write(to: URL(fileURLWithPath: path))
}

private func duplicateReport(
  _ root: String, comparator: DuplicateFileComparator = DuplicateFileComparator()
) async throws -> DuplicateReport {
  for try await event in DuplicateService(comparator: comparator).events(rootPath: root) {
    if case .completed(let report) = event { return report }
  }
  throw DuplicateFailure.unavailable
}

private func pair(_ root: String) async throws -> (ScanEntry, ScanEntry, UUID) {
  let snapshot = try await ScanService().scan(rootPath: root)
  let a = try #require(snapshot.entries.first { $0.path == root + "/a" })
  let b = try #require(snapshot.entries.first { $0.path == root + "/b" })
  return (a, b, try #require(snapshot.volumeID))
}

private func addACL(_ path: String) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/chmod")
  process.arguments = ["+a", "everyone allow read", path]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw DuplicateFailure.unavailable }
}

@Test func sameSizeDifferenceOutsideSampleAndDigestCollisionNeverGroups() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  var a = [UInt8](repeating: 42, count: 32_768)
  var b = a
  b[8_192] = 43
  try writeDuplicate(root + "/a", bytes: a)
  try writeDuplicate(root + "/b", bytes: b)
  let (first, second, volumeID) = try await pair(root)
  let collision = DuplicateFileComparator(hasher: CollisionHash())
  #expect(try collision.sample(first, volumeID: volumeID) == collision.sample(second, volumeID: volumeID))
  #expect(try collision.compare(first, second, volumeID: volumeID) == .dataDifferent)
  let report = try await duplicateReport(root, comparator: collision)
  #expect(report.groups.isEmpty)
  a[8_192] = 43
  try writeDuplicate(root + "/a", bytes: a)
}

@Test func hashTimeMutationIsRejected() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let (a, _, volumeID) = try await pair(root)
  let comparator = DuplicateFileComparator(hasher: ChangingHash(path: a.path))
  #expect(throws: DuplicateFailure.self) { _ = try comparator.digest(a, volumeID: volumeID) }
}

@Test func hardlinkIsOnePhysicalRepresentative() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  guard link(root + "/a", root + "/b") == 0 else { throw DuplicateFailure.unavailable }
  #expect(try await duplicateReport(root).groups.isEmpty)
}

@Test func metadataPartitionsAreKeeperRelativeAndLinearForEqualCopies() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  for name in ["a", "b", "c", "d"] { try writeDuplicate(root + "/" + name) }
  for name in ["c", "d"] {
    let value = Array("other metadata".utf8)
    guard setxattr(root + "/" + name, "com.lighten.test", value, value.count, 0, 0) == 0
    else { throw DuplicateFailure.unavailable }
  }
  let report = try await duplicateReport(root)
  let group = try #require(report.groups.first)
  #expect(group.members.count == 4)
  let members = Dictionary(
    uniqueKeysWithValues: group.members.map {
      (URL(fileURLWithPath: $0.entry.path).lastPathComponent, $0)
    })
  let a = try #require(members["a"])
  let b = try #require(members["b"])
  let c = try #require(members["c"])
  let d = try #require(members["d"])
  #expect(group.canTarget(b.id, keeperID: a.id))
  #expect(group.canTarget(d.id, keeperID: c.id))
  #expect(!group.canTarget(c.id, keeperID: a.id))
  #expect(a.compatibilityID != c.compatibilityID)
  #expect(report.comparisonCount <= 12)

  let equalRoot = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: equalRoot) }
  for index in 0..<12 { try writeDuplicate(equalRoot + "/\(index)") }
  let equal = try await duplicateReport(equalRoot)
  #expect(equal.groups.first?.members.count == 12)
  #expect(equal.comparisonCount <= 24)
}

@Test func resourceForkXattrAndModeDifferencesAreReportOnly() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  var (a, b, volumeID) = try await pair(root)
  let comparator = DuplicateFileComparator()
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .equal)
  var fork = Array("fork".utf8)
  guard setxattr(root + "/a", "com.apple.ResourceFork", &fork, fork.count, 0, 0) == 0
  else { throw DuplicateFailure.unavailable }
  (a, b, volumeID) = try await pair(root)
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .metadataDifferent)
  guard setxattr(root + "/b", "com.apple.ResourceFork", &fork, fork.count, 0, 0) == 0
  else { throw DuplicateFailure.unavailable }
  (a, b, volumeID) = try await pair(root)
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .equal)
  var tag = Array("private tag payload".utf8)
  guard setxattr(root + "/b", "com.lighten.test", &tag, tag.count, 0, 0) == 0
  else { throw DuplicateFailure.unavailable }
  (a, b, volumeID) = try await pair(root)
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .metadataDifferent)
  guard setxattr(root + "/a", "com.lighten.test", &tag, tag.count, 0, 0) == 0
  else { throw DuplicateFailure.unavailable }
  tag[0] = 90
  guard setxattr(root + "/b", "com.lighten.test", &tag, tag.count, 0, 0) == 0
  else { throw DuplicateFailure.unavailable }
  (a, b, volumeID) = try await pair(root)
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .metadataDifferent)
  guard removexattr(root + "/b", "com.lighten.test", 0) == 0 else { throw DuplicateFailure.unavailable }
  guard removexattr(root + "/a", "com.lighten.test", 0) == 0 else { throw DuplicateFailure.unavailable }
  guard chmod(root + "/b", 0o600) == 0 else { throw DuplicateFailure.unavailable }
  (a, b, volumeID) = try await pair(root)
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .metadataDifferent)
}

@Test func aclAndFlagsDifferencesAreReportOnly() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let comparator = DuplicateFileComparator()
  try addACL(root + "/a")
  var (a, b, volumeID) = try await pair(root)
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .metadataDifferent)
  try addACL(root + "/b")
  (a, b, volumeID) = try await pair(root)
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .equal)
  guard chflags(root + "/b", UInt32(UF_NODUMP)) == 0 else { throw DuplicateFailure.unavailable }
  (a, b, volumeID) = try await pair(root)
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .metadataDifferent)
}

@Test func oversizedXattrAndResourceForkAreMetadataUnknown() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let oversizedValue = [UInt8](repeating: 1, count: 1_048_577)
  for name in ["a", "b"] {
    let path = root + "/" + name
    guard setxattr(path, "com.lighten.cap", oversizedValue, oversizedValue.count, 0, 0) == 0
    else { throw DuplicateFailure.unavailable }
  }
  var (a, b, volumeID) = try await pair(root)
  let comparator = DuplicateFileComparator()
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .metadataUnknown)
  for name in ["a", "b"] {
    guard removexattr(root + "/" + name, "com.lighten.cap", 0) == 0
    else { throw DuplicateFailure.unavailable }
    try writeForkLargerThanCap(root + "/" + name)
  }
  (a, b, volumeID) = try await pair(root)
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .metadataUnknown)
}

private func writeForkLargerThanCap(_ path: String) throws {
  let fd = open(path, O_RDWR | O_NOFOLLOW)
  guard fd >= 0 else { throw DuplicateFailure.unavailable }
  defer { close(fd) }
  let chunk = [UInt8](repeating: 2, count: 1_048_576)
  var offset: UInt32 = 0
  while offset < 67_108_864 {
    guard fsetxattr(fd, "com.apple.ResourceFork", chunk, chunk.count, offset, 0) == 0
    else { throw DuplicateFailure.unavailable }
    offset += UInt32(chunk.count)
  }
  var last: UInt8 = 2
  guard fsetxattr(fd, "com.apple.ResourceFork", &last, 1, offset, 0) == 0
  else { throw DuplicateFailure.unavailable }
}

@Test func xattrAggregateAndNameCapsAreMetadataUnknown() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let paths = [root + "/a", root + "/b"]
  let value = [UInt8](repeating: 3, count: 1_048_576)
  for path in paths {
    for index in 0..<5 {
      let name = "com.lighten.cap\(index)"
      guard setxattr(path, name, value, value.count, 0, 0) == 0
      else { throw DuplicateFailure.unavailable }
    }
  }
  var (a, b, volumeID) = try await pair(root)
  let comparator = DuplicateFileComparator()
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .metadataUnknown)
  for path in paths {
    for index in 0..<5 {
      guard removexattr(path, "com.lighten.cap\(index)", 0) == 0
      else { throw DuplicateFailure.unavailable }
    }
    for index in 0..<610 {
      let name =
        "com.lighten." + String(format: "%04d", index)
        + String(repeating: "n", count: 95)
      var marker: UInt8 = 1
      guard setxattr(path, name, &marker, 1, 0, 0) == 0
      else { throw DuplicateFailure.unavailable }
    }
  }
  (a, b, volumeID) = try await pair(root)
  #expect(try comparator.compare(a, b, volumeID: volumeID) == .metadataUnknown)
}

@Test func cancellationReachesZeroByteComparator() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a", bytes: [])
  try writeDuplicate(root + "/b", bytes: [])
  let (a, b, volumeID) = try await pair(root)
  let gate = AsyncStream<Void>.makeStream()
  let worker = Task.detached {
    for await _ in gate.stream { break }
    return try DuplicateFileComparator().compare(a, b, volumeID: volumeID)
  }
  worker.cancel()
  gate.continuation.yield(())
  gate.continuation.finish()
  await #expect(throws: CancellationError.self) { try await worker.value }
}

@Test func sameInodeKeeperAliasIsRejectedBeforeIntent() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  guard link(root + "/a", root + "/alias") == 0 else { throw DuplicateFailure.unavailable }
  let report = try await duplicateReport(root)
  let group = try #require(report.groups.first)
  let keeper = try #require(group.members.first { $0.entry.path == root + "/b" })
  let target = try #require(group.members.first { $0.entry.path == root + "/a" })
  let plan = try await DuplicateService().makePlan(
    report: report, groupID: group.id, keeperID: keeper.id, targetIDs: [target.id])
  let alias = try #require(report.snapshot.entries.first { $0.path == root + "/alias" })
  let original = try #require(plan.items.first)
  let proof = try #require(original.duplicateProof)
  let forgedProof = DuplicateProof(
    groupID: proof.groupID, keeper: alias,
    keeperAncestors: try DescriptorFileSystem.ancestorIdentities(of: alias.path),
    keeperVolumeID: proof.keeperVolumeID,
    targetDigest: proof.targetDigest, keeperDigest: proof.keeperDigest)
  let forgedItem = PlanItem(
    id: original.id, sourcePath: original.sourcePath, volumeID: original.volumeID,
    inventory: original.inventory, ancestors: original.ancestors,
    duplicateProof: forgedProof)
  let forged = ActionPlan(snapshotRunID: plan.snapshotRunID, kind: .trash, items: [forgedItem])
  let journal = JSONLActionJournal(path: root + "/forged.jsonl")
  await #expect(throws: ExecutionFailure.self) {
    try await ActionExecutor(journal: journal, trash: NoMove()).execute(forged)
  }
  #expect((try await journal.read()).records.isEmpty)
}

@Test func unreadableKeeperSkipsTrash() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let report = try await duplicateReport(root)
  let group = try #require(report.groups.first)
  let keeper = try #require(group.members.first)
  let target = try #require(group.members.first { $0.id != keeper.id })
  let plan = try await DuplicateService().makePlan(
    report: report, groupID: group.id, keeperID: keeper.id, targetIDs: [target.id])
  guard chmod(keeper.entry.path, 0) == 0 else { throw DuplicateFailure.unavailable }
  let journal = JSONLActionJournal(path: root + "/journal.jsonl")
  let result = try await ActionExecutor(journal: journal, trash: NoMove()).execute(plan)
  #expect(result.items.map(\.outcome) == [.skipped])
  #expect(FileManager.default.fileExists(atPath: keeper.entry.path))
  #expect(FileManager.default.fileExists(atPath: target.entry.path))
}

@Test func fifoSwapFailsWithoutWaitingForWriter() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let (a, _, volumeID) = try await pair(root)
  try FileManager.default.removeItem(atPath: a.path)
  guard mkfifo(a.path, 0o600) == 0 else { throw DuplicateFailure.unavailable }
  #expect(throws: DuplicateFailure.self) {
    _ = try DuplicateFileComparator().digest(a, volumeID: volumeID)
  }
}

@Test func duplicatePlanMovesUUIDFixtureToTrashAndUndoRestoresIt() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let report = try await duplicateReport(root)
  let group = try #require(report.groups.first)
  let keeper = try #require(group.members.first)
  let target = try #require(group.members.first { $0.id != keeper.id })
  let plan = try await DuplicateService().makePlan(
    report: report, groupID: group.id, keeperID: keeper.id, targetIDs: [target.id])
  let journalPath = root + "/journal.jsonl"
  let journal = JSONLActionJournal(path: journalPath)
  let result = try await ActionExecutor(journal: journal, trash: NativeDuplicateTrash()).execute(plan)
  #expect(result.items.map(\.outcome) == [.applied])
  #expect(FileManager.default.fileExists(atPath: keeper.entry.path))
  #expect(!FileManager.default.fileExists(atPath: target.entry.path))
  let applied = try #require((try await journal.read()).records.first { $0.kind == .applied })
  let trashPath = try #require(applied.returnedTrashPath)
  #expect(FileManager.default.fileExists(atPath: trashPath))
  try await ActionHistory(journal: JSONLActionJournal(path: journalPath))
    .undo(planID: plan.id, itemID: target.id)
  #expect(FileManager.default.fileExists(atPath: target.entry.path))
  #expect(!FileManager.default.fileExists(atPath: trashPath))
}

@Test func changedKeeperSkipsTargetAndForgedCrossKeeperPlanRejectsBeforeIntent() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let report = try await duplicateReport(root)
  let group = try #require(report.groups.first)
  let a = try #require(group.members.first { $0.entry.path == root + "/a" })
  let b = try #require(group.members.first { $0.entry.path == root + "/b" })
  let service = DuplicateService()
  let aTarget = try await service.makePlan(
    report: report, groupID: group.id, keeperID: b.id, targetIDs: [a.id])
  let bTarget = try await service.makePlan(
    report: report, groupID: group.id, keeperID: a.id, targetIDs: [b.id])
  let forged = ActionPlan(
    snapshotRunID: report.snapshot.runID, kind: .trash,
    items: aTarget.items + bTarget.items)
  let journal = JSONLActionJournal(path: root + "/forged.jsonl")
  await #expect(throws: ExecutionFailure.self) {
    try await ActionExecutor(journal: journal, trash: NoMove()).execute(forged)
  }
  #expect((try await journal.read()).records.isEmpty)
  #expect(FileManager.default.fileExists(atPath: a.entry.path))
  #expect(FileManager.default.fileExists(atPath: b.entry.path))

  try writeDuplicate(b.entry.path, bytes: Array("changed file".utf8))
  let secondJournal = JSONLActionJournal(path: root + "/changed.jsonl")
  let result = try await ActionExecutor(journal: secondJournal, trash: NoMove()).execute(aTarget)
  #expect(result.items.map(\.outcome) == [.skipped])
  #expect(FileManager.default.fileExists(atPath: a.entry.path))
}

@Test func genericDirectoryContainingKeeperCannotShareDuplicatePlan() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let directory = root + "/keeper-folder"
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let keeperPath = directory + "/a"
  let targetPath = root + "/b"
  try writeDuplicate(keeperPath)
  try writeDuplicate(targetPath)
  let report = try await duplicateReport(root)
  let group = try #require(report.groups.first)
  let keeper = try #require(group.members.first { $0.entry.path == keeperPath })
  let target = try #require(group.members.first { $0.entry.path == targetPath })
  let duplicate = try await DuplicateService().makePlan(
    report: report, groupID: group.id, keeperID: keeper.id, targetIDs: [target.id])
  let directorySnapshot = try await ScanService().scanImmediateChild(parentPath: root, name: "keeper-folder")
  let directoryID = try #require(directorySnapshot.entries.first { $0.path == directory }).id
  let generic = try PlanService().makePlan(
    snapshot: directorySnapshot, selectedIDs: [directoryID])
  for items in [duplicate.items + generic.items, generic.items + duplicate.items] {
    let forged = ActionPlan(snapshotRunID: report.snapshot.runID, kind: .trash, items: items)
    let journal = JSONLActionJournal(path: root + "/" + UUID().uuidString + ".jsonl")
    await #expect(throws: ExecutionFailure.self) {
      try await ActionExecutor(journal: journal, trash: NoMove()).execute(forged)
    }
    #expect((try await journal.read()).records.isEmpty)
    #expect(FileManager.default.fileExists(atPath: keeperPath))
    #expect(FileManager.default.fileExists(atPath: targetPath))
  }
}

@Test func encodedProofAndJournalExcludePayload() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let payload = "secret-fixture-" + UUID().uuidString
  try writeDuplicate(root + "/a", bytes: Array(payload.utf8))
  try writeDuplicate(root + "/b", bytes: Array(payload.utf8))
  let metadataPayload = "metadata-fixture-" + UUID().uuidString
  let forkPayload = "fork-fixture-" + UUID().uuidString
  for name in ["a", "b"] {
    let value = Array(metadataPayload.utf8)
    guard setxattr(root + "/" + name, "com.lighten.test", value, value.count, 0, 0) == 0
    else { throw DuplicateFailure.unavailable }
    let fork = Array(forkPayload.utf8)
    guard setxattr(root + "/" + name, "com.apple.ResourceFork", fork, fork.count, 0, 0) == 0
    else { throw DuplicateFailure.unavailable }
  }
  let report = try await duplicateReport(root)
  let group = try #require(report.groups.first)
  let keeper = try #require(group.members.first)
  let target = try #require(group.members.first { $0.id != keeper.id })
  let plan = try await DuplicateService().makePlan(
    report: report, groupID: group.id, keeperID: keeper.id, targetIDs: [target.id])
  let encoded = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
  #expect(!encoded.contains(payload))
  #expect(!encoded.contains(metadataPayload))
  #expect(!encoded.contains(forkPayload))
  let journal = JSONLActionJournal(path: root + "/journal.jsonl")
  let result = try await ActionExecutor(journal: journal, trash: FailingMove()).execute(plan)
  #expect(result.items.map(\.outcome) == [.failed])
  let saved = try String(contentsOfFile: root + "/journal.jsonl", encoding: .utf8)
  #expect(!saved.contains(payload))
  #expect(!saved.contains(metadataPayload))
  #expect(!saved.contains(forkPayload))
}

private final class DuplicateProofReads: FileAttributeSource, Sendable {
  let inspected = Mutex<[String]>([])
  private let native = DescriptorAttributeSource()

  func volumeID(at path: String) async throws -> UUID? { try await native.volumeID(at: path) }
  func inspect(at path: String) async throws -> FileAttributes {
    inspected.withLock { $0.append(path) }
    return try await native.inspect(at: path)
  }
  func children(at path: String, expected: FileIdentity) async throws -> [String] {
    try await native.children(at: path, expected: expected)
  }
}

@Test func duplicateEngineFactsKeepPreciseIdentityAndPlanningReadsOnlySelections() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let unrelated = root + "/unrelated"
  try FileManager.default.createDirectory(atPath: unrelated, withIntermediateDirectories: true)
  try writeDuplicate(unrelated + "/noise", bytes: Array("different observation".utf8))
  let reads = DuplicateProofReads()
  let service = DuplicateService(scan: ScanService(homeDirectory: root, attributes: reads))
  var observed: DuplicateReport?
  for try await event in service.events(rootPath: root) {
    if case .completed(let report) = event { observed = report }
  }
  let report = try #require(observed)
  #expect(reads.inspected.withLock { $0.isEmpty })
  let group = try #require(report.groups.first)
  let keeper = try #require(group.members.first { $0.entry.path == root + "/a" })
  let target = try #require(group.members.first { $0.entry.path == root + "/b" })
  #expect(try keeper.entry.identity == DescriptorFileSystem.identity(at: keeper.entry.path))
  #expect(keeper.entry.identity?.hasStableTrashProof == true)
  #expect(report.snapshot.nodes.first?.logical.completeTotal != nil)
  // A change outside the selection cannot turn a complete-root observation
  // into a requirement to read the entire root again.
  try writeDuplicate(unrelated + "/noise", bytes: Array("updated unrelated data".utf8))
  let plan = try await service.makePlan(report: report, groupID: group.id, keeperID: keeper.id, targetIDs: [target.id])
  #expect(Set(reads.inspected.withLock { $0 }) == Set([root, keeper.entry.path, target.entry.path]))
  #expect(plan.items.map(\.id) == [target.id])
  #expect(plan.items.first?.inventory.count == 1)
  #expect(plan.items.first?.duplicateProof?.keeper.identity == keeper.entry.identity)
  let decoded = try JSONDecoder().decode(ActionPlan.self, from: JSONEncoder().encode(plan))
  for item in decoded.items { try ActionGuard(homeDirectory: root).validate(item) }
}

@Test(arguments: ["a", "b"])
func duplicateFreshPlanRefusesChangedKeeperOrTarget(_ changed: String) async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let report = try await duplicateReport(root)
  let group = try #require(report.groups.first)
  let keeper = try #require(group.members.first { $0.entry.path == root + "/a" })
  let target = try #require(group.members.first { $0.entry.path == root + "/b" })
  try writeDuplicate(root + "/" + changed, bytes: Array("changed selected observation".utf8))
  await #expect(throws: DuplicateFailure.self) {
    try await DuplicateService().makePlan(
      report: report, groupID: group.id, keeperID: keeper.id, targetIDs: [target.id])
  }
}

@Test func duplicateEngineOmitsBoundariesAndKeepsPartialRootLowerBound() async throws {
  let root = try duplicateFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeDuplicate(root + "/a")
  try writeDuplicate(root + "/b")
  let mail = root + "/Library/Mail"
  let package = root + "/LightenQA-" + UUID().uuidString + ".app"
  let unreadable = root + "/unreadable"
  try FileManager.default.createDirectory(atPath: unreadable, withIntermediateDirectories: true)
  guard chmod(unreadable, 0) == 0 else { throw DuplicateFailure.unavailable }
  defer { _ = chmod(unreadable, 0o700) }
  for directory in [mail, package + "/Contents"] {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try writeDuplicate(directory + "/copy")
  }
  try FileManager.default.createSymbolicLink(atPath: root + "/alias", withDestinationPath: root + "/a")
  var result: DuplicateReport?
  let service = DuplicateService(configuration: ScanConfiguration(homeDirectory: root))
  for try await event in service.events(rootPath: root) {
    if case .completed(let report) = event { result = report }
  }
  let report = try #require(result)
  #expect(Set(report.groups.flatMap { $0.members.map { $0.entry.path } }) == Set([root + "/a", root + "/b"]))
  #expect(report.snapshot.entries.filter { $0.identity?.kind == .regular }.count == 2)
  #expect(report.partial)
  #expect(report.snapshot.nodes.first?.partial == true)
  #expect(report.snapshot.nodes.first?.logical.completeTotal == nil)
  #expect((report.snapshot.nodes.first?.logical.knownLowerBound ?? 0) >= 24)
}
