import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private func sinkFixture() throws -> String {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw FileSystemFailure.invalidPath }
  defer { free(resolved) }
  let root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  return root
}

private func sinkWrite(_ path: String, bytes: Int) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try Data(repeating: 0x62, count: bytes).write(to: URL(fileURLWithPath: path))
}

private func sinkScan(
  _ root: String, home: String? = nil, min: Int64 = 0, olderThan: Date? = nil
) async throws -> (ScanRun, [FileFact]) {
  let facts = Mutex<[FileFact]>([])
  let run = try ScanEngine(
    configuration: ScanConfiguration(
      workers: 4, homeDirectory: home ?? NSHomeDirectory(),
      fileSink: FileSink(minLogicalBytes: min, olderThan: olderThan) { fact in
        facts.withLock { $0.append(fact) }
      })
  ).start(root: root)
  await run.waitUntilFinished()
  return (run, facts.withLock { $0 })
}

private func addedTimestamp(_ path: String) -> FileTimestamp? {
  var attributes = attrlist()
  attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
  attributes.commonattr = UInt32(ATTR_CMN_ADDEDTIME)
  var bytes = [UInt8](repeating: 0, count: 20)
  let result = bytes.withUnsafeMutableBytes {
    getattrlist(path, &attributes, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW))
  }
  guard result == 0 else { return nil }
  return bytes.withUnsafeBytes { buffer in
    let seconds = buffer.loadUnaligned(fromByteOffset: 4, as: Int64.self)
    let nanoseconds = buffer.loadUnaligned(fromByteOffset: 12, as: Int64.self)
    guard seconds > 0, (0..<1_000_000_000).contains(nanoseconds) else { return nil }
    return FileTimestamp(seconds: seconds, nanoseconds: nanoseconds)
  }
}

@Test func fileSinkMatchesEveryFileInOneHundredThousandFileManifest() async throws {
  let root = try sinkFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  var manifest = Set<String>()
  for directory in 0..<100 {
    let parent = root + "/d\(directory)"
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    for file in 0..<1000 {
      let path = parent + "/f\(file)"
      let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw FileSystemFailure.systemCall("create fixture file", errno) }
      guard close(fd) == 0 else { throw FileSystemFailure.systemCall("close fixture file", errno) }
      manifest.insert(path)
    }
  }
  let (run, facts) = try await sinkScan(root)
  #expect(facts.count == 100_000)
  #expect(Set(facts.map(\.path)) == manifest)
  #expect(run.counters.snapshot["fallbackStats"] == 0)
  #expect(facts.allSatisfy { $0.identity.kind == .regular && $0.modTime != nil })
}

@Test func fileSinkPreservesPreciseIdentityDatesResourceForksAndHardLinkPaths() async throws {
  let root = try sinkFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let original = root + "/original"
  try sinkWrite(original, bytes: 512)
  let fork = Data(repeating: 0x7a, count: 8192)
  let result = fork.withUnsafeBytes {
    setxattr(original, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
  }
  #expect(result == 0)
  #expect(link(original, root + "/alias") == 0)
  var dates = [
    timespec(tv_sec: 1_234_567_890, tv_nsec: 123_456_789),
    timespec(tv_sec: 1_234_567_890, tv_nsec: 987_654_321),
  ]
  #expect(utimensat(AT_FDCWD, original, &dates, AT_SYMLINK_NOFOLLOW) == 0)
  let expected = try DescriptorFileSystem.identity(at: original)
  let (run, facts) = try await sinkScan(root)
  #expect(Set(facts.map(\.path)) == [original, root + "/alias"])
  #expect(facts.allSatisfy { $0.identity == expected })
  let modified = FileTimestamp(seconds: 1_234_567_890, nanoseconds: 987_654_321).date
  #expect(facts.allSatisfy { $0.modTime == modified })
  #expect(facts.allSatisfy { $0.addedTime == addedTimestamp($0.path)?.date })
  let total = try #require(run.tree.item(run.tree.rootID)?.logical.completeTotal)
  #expect(total == Int64(512 + 8192))
  #expect(run.counters.snapshot["fallbackStats"] == 0)
}

@Test func fileSinkFiltersUseLogicalSizeAndStrictModificationCutoff() async throws {
  let root = try sinkFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  for (name, size, seconds) in [
    ("old-large", 100, 1000), ("old-small", 99, 1000),
    ("cutoff", 100, 2000), ("new-large", 100, 3000),
  ] {
    let path = root + "/" + name
    try sinkWrite(path, bytes: size)
    var times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
    #expect(utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) == 0)
  }
  let (_, facts) = try await sinkScan(root, min: 100, olderThan: Date(timeIntervalSince1970: 2000))
  #expect(facts.map(\.path) == [root + "/old-large"])
  let unknown = RawEntry(
    name: "unknown", kind: .regular, device: 1, inode: 1, flags: 0, linkCount: 1,
    logical: 100, allocated: 0, error: 0, identityLogicalBytes: 100)
  #expect(unknown.identity == nil)
  #expect(!FileSink(olderThan: Date()) { _ in }.accepts(unknown))
  #expect(unknown.addedTime == nil && unknown.modificationTime == nil)
}

@Test func fileSinkDoesNotEmitOpaqueProtectedPackageOrSymlinkInteriors() async throws {
  let home = try sinkFixture()
  defer { try? FileManager.default.removeItem(atPath: home) }
  try sinkWrite(home + "/normal/file", bytes: 1)
  try sinkWrite(home + "/Tool.bundle/Contents/data", bytes: 2)
  try sinkWrite(home + "/Library/Mail/V1/message", bytes: 3)
  try sinkWrite(home + "/.ssh/key", bytes: 4)
  try sinkWrite(home + "/Library/CloudStorage/Drive/remote", bytes: 5)
  try sinkWrite(home + "/disk.sparseimage", bytes: 6)
  try sinkWrite(home + "/installer.pkg", bytes: 7)
  #expect(symlink(home + "/normal", home + "/link") == 0)
  let (_, facts) = try await sinkScan(home, home: home)
  #expect(facts.map(\.path) == [home + "/normal/file"])
  let (_, packageFacts) = try await sinkScan(home + "/Tool.bundle/Contents", home: home)
  #expect(packageFacts.isEmpty)
  let (_, protectedFacts) = try await sinkScan(home + "/Library/Mail", home: home)
  #expect(protectedFacts.isEmpty)
}

@Test func fileSinkRejectsDatalessMountAndIncompleteEntries() throws {
  let root = try sinkFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let facts = Mutex<[FileFact]>([])
  let tree = ScanTree(runID: UUID(), rootPath: root, root: ScanTree.rootNode(name: root, device: 7, inode: 1))
  let counters = ScanCounters()
  let walker = ParallelWalker(
    tree: tree, counters: counters, automaton: ProtectionAutomaton(homeDirectory: root),
    boundaryDevice: 7, homeDirectory: root, firmlinks: nil, workers: 1,
    fileSink: FileSink { fact in facts.withLock { $0.append(fact) } }, onFinish: {})
  let job = WalkJob(owner: 0, path: root, device: 7, inode: 1, mode: .node, depth: 0, protection: nil)
  let entry = RawEntry(
    name: "plain", kind: .regular, device: 7, inode: 2, flags: 0, linkCount: 1,
    logical: 100, allocated: 0, error: 0,
    birthTime: FileTimestamp(seconds: 99, nanoseconds: 0),
    modificationTime: FileTimestamp(seconds: 100, nanoseconds: 0),
    changeTime: FileTimestamp(seconds: 100, nanoseconds: 1), identityLogicalBytes: 100)
  for flags in [UInt32(SF_DATALESS), UInt32(UF_DATAVAULT)] {
    var cloud = entry
    cloud.flags = flags
    walker.emit(cloud, in: job)
  }
  var mount = entry
  mount.device = 8
  walker.emit(mount, in: job)
  var unknown = entry
  unknown.changeTime = nil
  walker.emit(unknown, in: job)
  var unknownSize = entry
  unknownSize.identityLogicalBytes = nil
  walker.emit(unknownSize, in: job)
  #expect(counters.snapshot["sinkMetadataUnavailable"] == 2)
  #expect(counters.snapshot["sinkOmittedFiles"] == 2)
  var failed = entry
  failed.error = EIO
  walker.emit(failed, in: job)
  walker.emit(
    entry,
    in: WalkJob(
      owner: 0, path: root, device: 7, inode: 1, mode: .interior, depth: 1, protection: nil))
  #expect(facts.withLock { $0.isEmpty })
  walker.emit(entry, in: job)
  #expect(facts.withLock { $0.count } == 1)
  #expect(counters.snapshot["sinkMetadataUnavailable"] == 2)
  #expect(counters.snapshot["sinkOmittedFiles"] == 2)
  #expect(facts.withLock { $0.first?.addedTime } == nil)
  var incompleteDates = entry
  incompleteDates.birthTime = nil
  incompleteDates.modificationTime = nil
  walker.emit(incompleteDates, in: job)
  #expect(facts.withLock { $0.count } == 2)
  #expect(facts.withLock { $0.last?.modTime } == nil)
  #expect(counters.snapshot["sinkMetadataUnavailable"] == 3)
  #expect(counters.snapshot["sinkOmittedFiles"] == 2)
  walker.queue.cancel()
  walker.emit(entry, in: job)
  #expect(facts.withLock { $0.count } == 2)

  let filteredCounters = ScanCounters()
  let filtered = ParallelWalker(
    tree: tree, counters: filteredCounters, automaton: ProtectionAutomaton(homeDirectory: root),
    boundaryDevice: 7, homeDirectory: root, firmlinks: nil, workers: 1,
    fileSink: FileSink(minLogicalBytes: 100, olderThan: Date(timeIntervalSince1970: 200)) { _ in },
    onFinish: {})
  filtered.emit(incompleteDates, in: job)
  #expect(filteredCounters.snapshot["sinkMetadataUnavailable"] == 1)
  #expect(filteredCounters.snapshot["sinkOmittedFiles"] == 1)
  var small = unknown
  small.identityLogicalBytes = 99
  filtered.emit(small, in: job)
  var recent = unknown
  recent.modificationTime = FileTimestamp(seconds: 200, nanoseconds: 0)
  filtered.emit(recent, in: job)
  #expect(filteredCounters.snapshot["sinkMetadataUnavailable"] == 1)
  #expect(filteredCounters.snapshot["sinkOmittedFiles"] == 1)
}

@Test func discoverySnapshotKeepsAllDirectFilesAndDirectoryAggregatesOnly() async throws {
  let root = try sinkFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  for file in 0..<40 { try sinkWrite(root + "/f\(file)", bytes: file) }
  try sinkWrite(root + "/folder/nested/data", bytes: 1234)
  try sinkWrite(root + "/Tool.bundle/Contents/data", bytes: 456)
  #expect(symlink(root + "/folder", root + "/link") == 0)
  let engine = ScanEngine(configuration: ScanConfiguration(workers: 4))
  let snapshot = try await engine.discoverySnapshot(rootPath: root)
  let rootEntry = try #require(snapshot.entries.first { $0.parentID == nil })
  let direct = snapshot.entries.filter { $0.parentID == rootEntry.id }
  #expect(snapshot.entries.count == 44)
  #expect(direct.count == 43)
  #expect(direct.allSatisfy { ($0.path as NSString).deletingLastPathComponent == root })
  #expect(direct.filter { $0.identity?.kind == .regular }.count == 40)
  #expect(
    direct.filter { $0.identity?.kind == .regular }.allSatisfy {
      $0.identity == (try? DescriptorFileSystem.identity(at: $0.path))
    })
  let folder = try #require(direct.first { $0.path == root + "/folder" })
  let aggregate = try #require(snapshot.nodes.first { $0.id == folder.id })
  #expect(aggregate.logical.completeTotal == 1234)
  #expect(aggregate.knownItemCount == 3)
  #expect(snapshot.entries.allSatisfy { !$0.path.hasSuffix("/nested/data") })
  let package = try #require(direct.first { $0.path == root + "/Tool.bundle" })
  #expect(package.issues.contains(.packageBoundary))
  #expect(snapshot.nodes.first { $0.id == package.id }?.logical.knownLowerBound == 456)
  #expect(direct.first { $0.path == root + "/link" }?.issues.contains(.symbolicLink) == true)
}

@Test func discoveryCancellationWaitsForTheInFlightSinkWorker() async throws {
  let root = try sinkFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  for file in 0..<500 { try sinkWrite(root + "/f\(file)", bytes: 1) }
  let gate = DispatchSemaphore(value: 0)
  let (entered, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
  let received = Atomic<Int>(0)
  let engine = ScanEngine(
    configuration: ScanConfiguration(
      workers: 1,
      fileSink: FileSink { _ in
        received.add(1, ordering: .relaxed)
        continuation.yield(true)
        gate.wait()
      }))
  let operation = Task { try await engine.discoverySnapshot(rootPath: root) }
  for await _ in entered { break }
  operation.cancel()
  gate.signal()
  await #expect(throws: CancellationError.self) { try await operation.value }
  #expect(received.load(ordering: .relaxed) == 1)
  continuation.finish()
}

@Test func fileSinkDisabledKeepsTheOriginalBulkMetadataPath() throws {
  let root = try sinkFixture()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try sinkWrite(root + "/file", bytes: 1)
  let counters = ScanCounters()
  let reader = DirectoryReader(counters: counters)
  var entries: [RawEntry] = []
  try reader.read(path: root, expected: nil, isCancelled: { false }, visit: { entries.append($0) })
  let entry = try #require(entries.first)
  #expect(entry.changeTime == nil && entry.modificationTime == nil && entry.addedTime == nil)
  #expect(entry.identityLogicalBytes == nil)
  #expect(counters.snapshot["fallbackStats"] == 0)
  #expect(counters.snapshot["opens"] == 1)
}
