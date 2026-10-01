import CoreServices
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import LightenKit

@Suite("Historical scan refresh")
struct ScanReplayTests {
  private func fixture() throws -> String {
    let path = "/private/tmp/LightenQA-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  @Test("Adds, grows, deletes, renames, and moves match a fresh scan")
  func changes() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    for name in ["one", "two", "one/sub"] {
      try FileManager.default.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
    }
    for name in ["one/grow", "one/delete", "one/rename", "one/sub/inside"] {
      try Data(repeating: 1, count: 10).write(to: URL(fileURLWithPath: root + "/" + name))
    }
    let engine = ScanEngine(configuration: ScanConfiguration(homeDirectory: root))
    let baseline = try #require(ScanReplayBaseline.capture(root: root, storeUUIDForDevice: { _ in UUID() }))
    let before = try engine.start(root: root)
    await before.waitUntilFinished()
    let unchangedID = before.tree.find(path: root + "/two")
    try Data(repeating: 2, count: 70).write(to: URL(fileURLWithPath: root + "/one/grow"))
    try Data(repeating: 3, count: 30).write(to: URL(fileURLWithPath: root + "/one/add"))
    try FileManager.default.removeItem(atPath: root + "/one/delete")
    try FileManager.default.moveItem(atPath: root + "/one/rename", toPath: root + "/one/renamed")
    try FileManager.default.moveItem(atPath: root + "/one/sub", toPath: root + "/two/moved")
    let events = ["one", "two"].map {
      FileEvent(
        path: root + "/" + $0 + "/changed", flags: UInt32(kFSEventStreamEventFlagItemIsFile), id: baseline.eventID + 1)
    }
    let result = engine.reconcile(
      tree: before.tree, replay: FileEventReplay(events: events, latestID: baseline.eventID + 1),
      baseline: baseline, currentBaseline: baseline)
    #expect(result == .refreshed(directories: 2))
    #expect(before.tree.find(path: root + "/two") == unchangedID)
    let after = try engine.start(root: root)
    await after.waitUntilFinished()
    let old = try #require(before.tree.item(before.tree.rootID))
    let fresh = try #require(after.tree.item(after.tree.rootID))
    #expect(old.logical == fresh.logical)
    #expect(old.allocated == fresh.allocated)
    #expect(old.itemCount == fresh.itemCount)
    #expect(before.tree.find(path: root + "/one/sub") == nil)
    #expect(before.tree.find(path: root + "/two/moved") != nil)
  }

  @Test(
    "Unsafe event histories require a full scan",
    arguments: [
      UInt32(kFSEventStreamEventFlagMustScanSubDirs), UInt32(kFSEventStreamEventFlagUserDropped),
      UInt32(kFSEventStreamEventFlagKernelDropped), UInt32(kFSEventStreamEventFlagEventIdsWrapped),
      UInt32(kFSEventStreamEventFlagItemIsHardlink), UInt32(kFSEventStreamEventFlagItemIsLastHardlink),
    ])
  func unsafeFlags(_ flag: UInt32) async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let run = try ScanEngine().start(root: root)
    await run.waitUntilFinished()
    let baseline = ScanReplayBaseline(eventID: 50, volumeUUID: UUID(), storeUUID: UUID())
    let result = ScanEngine().reconcile(
      tree: run.tree, replay: FileEventReplay(events: [FileEvent(path: root, flags: flag, id: 51)], latestID: 51),
      baseline: baseline, currentBaseline: baseline)
    #expect(result == .requiresFullScan)
  }

  @Test("UUID, backwards ids, incomplete history, and event limit fail closed")
  func invalidHistory() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let run = try ScanEngine().start(root: root)
    await run.waitUntilFinished()
    let baseline = ScanReplayBaseline(eventID: 50, volumeUUID: UUID(), storeUUID: UUID())
    let engine = ScanEngine()
    for replay in [
      FileEventReplay(events: [], latestID: 49), FileEventReplay(events: [], latestID: 51, complete: false),
      FileEventReplay(events: [FileEvent(path: root, flags: 0, id: 49)], latestID: 51),
      FileEventReplay(events: Array(repeating: FileEvent(path: root, flags: 0, id: 51), count: 50_001), latestID: 51),
    ] {
      #expect(
        engine.reconcile(tree: run.tree, replay: replay, baseline: baseline, currentBaseline: baseline)
          == .requiresFullScan)
    }
    #expect(
      engine.reconcile(
        tree: run.tree, replay: FileEventReplay(events: [], latestID: 50), baseline: baseline,
        currentBaseline: ScanReplayBaseline(eventID: 50, volumeUUID: UUID(), storeUUID: baseline.storeUUID))
        == .requiresFullScan)
  }

  @Test("Private v3 cache retains home and rejects corruption")
  func cache() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture) }
    let cache = ScanCache(directory: fixture + "/cache", homeDirectory: fixture + "/home")
    try FileManager.default.createDirectory(
      atPath: cache.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data("legacy format".utf8).write(to: URL(fileURLWithPath: cache.directory + "/legacy.bin"))
    var saved: [String] = []
    for name in ["home", "one", "two", "three", "four"] {
      let root = fixture + "/" + name
      try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
      let run = try ScanEngine().start(root: root)
      await run.waitUntilFinished()
      let baseline = try #require(ScanReplayBaseline.capture(root: root, storeUUIDForDevice: { _ in UUID() }))
      try cache.save(run.tree, baseline: baseline)
      #expect(cache.loadEntry(root: root)?.baseline == baseline)
      saved.append(root)
    }
    #expect(cache.load(root: fixture + "/home") != nil)
    #expect(!FileManager.default.fileExists(atPath: cache.directory + "/legacy.bin"))
    let limited = ScanCache(directory: cache.directory, homeDirectory: fixture + "/home", maximumBytes: 32)
    let retained = try #require(cache.load(root: fixture + "/home"))
    #expect(throws: ScanCache.Failure.tooLarge) { try limited.save(retained.tree) }
    #expect(cache.load(root: fixture + "/home") != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directory).count == 3)
    var mode = stat()
    #expect(lstat(cache.directory, &mode) == 0)
    #expect(mode.st_mode & 0o777 == 0o700)
    let path = cache.file(for: saved.last!)
    #expect(lstat(path, &mode) == 0)
    #expect(mode.st_mode & 0o777 == 0o600)
    var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    bytes[15] ^= 1
    try bytes.write(to: URL(fileURLWithPath: path))
    #expect(cache.loadEntry(root: saved.last!) == nil)
    try cache.clear()
    #expect(cache.usageBytes() == 0)
  }
}

extension ScanReplayTests {
  @Test(
    "Deleting the counted hardlink requests a full scan and retains the surviving bytes",
    arguments: [UInt32(kFSEventStreamEventFlagItemIsHardlink), UInt32(kFSEventStreamEventFlagItemIsLastHardlink)])
  func countedHardLinkDeletion(_ linkFlag: UInt32) async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
    try Data(repeating: 4, count: 500_000).write(to: URL(fileURLWithPath: root + "/counted"))
    try FileManager.default.linkItem(atPath: root + "/counted", toPath: root + "/sub/survivor")
    let engine = ScanEngine(configuration: ScanConfiguration(workers: 1))
    let run = try engine.start(root: root)
    await run.waitUntilFinished()
    let sub = try #require(run.tree.find(path: root + "/sub"))
    #expect(run.tree.item(sub)?.logical.completeTotal == 0)
    #expect(run.tree.item(run.tree.rootID)?.logical.completeTotal == 500_000)
    try FileManager.default.removeItem(atPath: root + "/counted")
    let baseline = ScanReplayBaseline(eventID: 10, volumeUUID: UUID(), storeUUID: UUID())
    let replay = FileEventReplay(
      events: [
        FileEvent(path: root + "/counted", flags: UInt32(kFSEventStreamEventFlagItemRemoved) | linkFlag, id: 11)
      ], latestID: 11)
    #expect(
      engine.reconcile(tree: run.tree, replay: replay, baseline: baseline, currentBaseline: baseline)
        == .requiresFullScan)
    let fresh = try engine.start(root: root)
    await fresh.waitUntilFinished()
    #expect(fresh.tree.item(fresh.tree.rootID)?.logical.completeTotal == 500_000)
    let survivor = try #require(fresh.tree.find(path: root + "/sub"))
    #expect(fresh.tree.item(survivor)?.logical.completeTotal == 500_000)
  }

  @Test("Missing and changed event-store UUIDs cannot reuse a volume's history")
  func eventStoreContinuity() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let run = try ScanEngine().start(root: root)
    await run.waitUntilFinished()
    let volume = UUID()
    let store = UUID()
    let valid = ScanReplayBaseline(eventID: 10, volumeUUID: volume, storeUUID: store)
    let legacy = ScanReplayBaseline(eventID: 10, volumeUUID: volume)
    let changed = ScanReplayBaseline(eventID: 11, volumeUUID: volume, storeUUID: UUID())
    let replay = FileEventReplay(events: [], latestID: 11)
    let engine = ScanEngine()
    for (old, current) in [(valid, legacy), (legacy, valid), (legacy, legacy), (valid, changed)] {
      #expect(
        engine.reconcile(tree: run.tree, replay: replay, baseline: old, currentBaseline: current)
          == .requiresFullScan)
    }
    #expect(
      engine.reconcile(tree: run.tree, replay: replay, baseline: valid, currentBaseline: valid)
        == .refreshed(directories: 0))
    var details = stat()
    try #require(lstat(root, &details) == 0)
    let captured = try #require(
      ScanReplayBaseline.capture(
        root: root,
        storeUUIDForDevice: { device in
          #expect(device == details.st_dev)
          return store
        }))
    #expect(captured.storeUUID == store)
    #expect(ScanReplayBaseline.capture(root: root, storeUUIDForDevice: { _ in nil }) == nil)
  }

  @Test("A v2 cached tree remains browsable without granting history continuity")
  func legacyCache() async throws {
    let container = try fixture()
    defer { try? FileManager.default.removeItem(atPath: container) }
    let root = container + "/home"
    try FileManager.default.createDirectory(atPath: root + "/folder", withIntermediateDirectories: true)
    try Data(repeating: 7, count: 123).write(to: URL(fileURLWithPath: root + "/folder/data"))
    let engine = ScanEngine()
    let run = try engine.start(root: root)
    await run.waitUntilFinished()
    let cache = ScanCache(directory: container + "/cache", homeDirectory: root)
    try cache.save(run.tree)
    let volume = UUID()
    var header = Data([0x32, 0x43, 0x53, 0x4C])
    withUnsafeBytes(of: UInt64(10).littleEndian) { header.append(contentsOf: $0) }
    header.append(1)
    let uuid = Data(volume.uuidString.utf8)
    withUnsafeBytes(of: UInt32(uuid.count).littleEndian) { header.append(contentsOf: $0) }
    header.append(uuid)
    let payload = ScanCache.encode(run.tree.storage.withLock { $0 }, savedAt: Date())
    let legacy = header + Data(SHA256.hash(data: header + payload)) + payload
    try legacy.write(to: URL(fileURLWithPath: cache.file(for: root)))
    let loaded = try #require(cache.loadEntry(root: root))
    let baseline = try #require(loaded.baseline)
    #expect(baseline.volumeUUID == volume)
    #expect(baseline.storeUUID == nil)
    #expect(loaded.tree.find(path: root + "/folder") != nil)
    #expect(loaded.tree.item(loaded.tree.rootID)?.logical.completeTotal == 123)
    #expect(
      engine.reconcile(
        tree: loaded.tree, replay: FileEventReplay(events: [], latestID: 10), baseline: baseline,
        currentBaseline: ScanReplayBaseline(eventID: 10, volumeUUID: volume, storeUUID: UUID())) == .requiresFullScan)
    try cache.save(loaded.tree, baseline: baseline)
    #expect(
      try Data(contentsOf: URL(fileURLWithPath: cache.file(for: root))).prefix(4)
        == Data([0x33, 0x43, 0x53, 0x4C]))
  }

  @Test("HOME replay keeps unchanged SSH, Keychains, and cloud boundaries closed")
  func protectedHomeReplay() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    for name in [".ssh", "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "normal/sub"] {
      try FileManager.default.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
      try Data(repeating: 8, count: 120).write(to: URL(fileURLWithPath: root + "/" + name + "/hidden"))
    }
    try Data(repeating: 1, count: 10).write(to: URL(fileURLWithPath: root + "/.zsh_history"))
    let engine = ScanEngine(configuration: ScanConfiguration(workers: 1, homeDirectory: root))
    let run = try engine.start(root: root)
    await run.waitUntilFinished()
    let opaquePaths = [".ssh", "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage"]
    let originals = try opaquePaths.map { name -> SpaceItem in
      let id = try #require(run.tree.find(path: root + "/" + name))
      return try #require(run.tree.item(id))
    }
    #expect(originals.allSatisfy { $0.childCount == 0 && $0.logical.knownLowerBound == 0 })
    try Data(repeating: 2, count: 70).write(to: URL(fileURLWithPath: root + "/.zsh_history"))
    try Data(repeating: 3, count: 30).write(to: URL(fileURLWithPath: root + "/Library/changed"))
    let baseline = ScanReplayBaseline(eventID: 10, volumeUUID: UUID(), storeUUID: UUID())
    let events = [".zsh_history", "Library/changed"].map {
      FileEvent(path: root + "/" + $0, flags: UInt32(kFSEventStreamEventFlagItemIsFile), id: 11)
    }
    #expect(
      engine.reconcile(
        tree: run.tree, replay: FileEventReplay(events: events, latestID: 11),
        baseline: baseline, currentBaseline: baseline) == .refreshed(directories: 2))
    for original in originals { #expect(run.tree.item(original.id) == original) }
    let fresh = try engine.start(root: root)
    await fresh.waitUntilFinished()
    #expect(run.tree.item(run.tree.rootID)?.logical == fresh.tree.item(fresh.tree.rootID)?.logical)
    #expect(run.tree.item(run.tree.rootID)?.allocated == fresh.tree.item(fresh.tree.rootID)?.allocated)
    #expect(run.tree.item(run.tree.rootID)?.itemCount == fresh.tree.item(fresh.tree.rootID)?.itemCount)
    #expect(run.tree.item(run.tree.rootID)?.logical.knownLowerBound == 220)
  }

  @Test(
    "New, replaced, or differently classified opaque boundaries require a full scan",
    arguments: ["new", "replaced", "reason", "kind"])
  func changedProtectedBoundary(_ change: String) async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    if change != "new" {
      try FileManager.default.createDirectory(atPath: root + "/.ssh", withIntermediateDirectories: true)
    }
    let engine = ScanEngine(configuration: ScanConfiguration(homeDirectory: root))
    let run = try engine.start(root: root)
    await run.waitUntilFinished()
    if change == "replaced" || change == "kind" {
      // Retain the old directory so inode reuse cannot make this test ambiguous.
      try FileManager.default.moveItem(atPath: root + "/.ssh", toPath: root + "/old-boundary")
    }
    if change == "kind" {
      try Data("replacement file".utf8).write(to: URL(fileURLWithPath: root + "/.ssh"))
    } else if change != "reason" {
      try FileManager.default.createDirectory(atPath: root + "/.ssh", withIntermediateDirectories: true)
    }
    let currentEngine =
      change == "reason" ? ScanEngine(configuration: ScanConfiguration(homeDirectory: root + "/other")) : engine
    let baseline = ScanReplayBaseline(eventID: 10, volumeUUID: UUID(), storeUUID: UUID())
    #expect(
      currentEngine.reconcile(
        tree: run.tree,
        replay: FileEventReplay(
          events: [
            FileEvent(path: root + "/changed", flags: UInt32(kFSEventStreamEventFlagItemIsFile), id: 11)
          ], latestID: 11), baseline: baseline, currentBaseline: baseline) == .requiresFullScan)
  }

  @Test(
    "An event inside an opaque region never opens that region",
    arguments: [".ssh", "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage"])
  func opaqueRegionEvent(_ name: String) async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/" + name
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try Data(repeating: 9, count: 9876).write(to: URL(fileURLWithPath: path + "/secret"))
    let engine = ScanEngine(configuration: ScanConfiguration(homeDirectory: root))
    let run = try engine.start(root: root)
    await run.waitUntilFinished()
    let id = try #require(run.tree.find(path: path))
    let original = try #require(run.tree.item(id))
    #expect(original.logical.knownLowerBound == 0)
    let baseline = ScanReplayBaseline(eventID: 10, volumeUUID: UUID(), storeUUID: UUID())
    #expect(
      engine.reconcile(
        tree: run.tree,
        replay: FileEventReplay(
          events: [
            FileEvent(path: path + "/secret", flags: UInt32(kFSEventStreamEventFlagItemIsFile), id: 11)
          ], latestID: 11), baseline: baseline, currentBaseline: baseline) == .requiresFullScan)
    #expect(run.tree.item(id) == original)
    #expect(run.tree.children(of: id, metric: .logical).isEmpty)
  }

  @Test("Encoding a large cache does not block tree readers")
  func cacheReadProbe() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let tree = ScanTree(runID: UUID(), rootPath: root, root: ScanTree.rootNode(name: root, device: 1, inode: 1))
    tree.storage.withLock { storage in
      storage.nodes[0].lifecycle = .done
      for number in 1...30_000 {
        var node = ScanTree.Node(
          name: "directory-\(number)", parent: 0, kind: .directory, device: 1, inode: UInt64(number + 1))
        node.lifecycle = .done
        node.files = (0..<32).map {
          ScanTree.FileRecord(
            name: "file-\($0)", logical: 1024, allocated: 4096, kind: .file, protectedRule: nil, inode: UInt64($0 + 1),
            error: false)
        }
        storage.nodes.append(node)
        storage.nodes[0].childNodes.append(Int32(number))
      }
      storage.finished = true
    }
    let cache = ScanCache(directory: root + "/cache", homeDirectory: root)
    let saving = Task.detached(priority: .utility) { try cache.save(tree) }
    var longest = Duration.zero
    for _ in 0..<1000 {
      let start = ContinuousClock.now
      _ = tree.item(tree.rootID)
      longest = max(longest, start.duration(to: .now))
      try await Task.sleep(for: .milliseconds(1))
    }
    try await saving.value
    print("CACHE_READER_PROBE longest=\(longest)")
    #expect(longest < .milliseconds(5), "Reader probe: \(longest)")
  }
}

extension ScanReplayTests {
  @Test("Native historical replay delivers an owned file change and stops")
  func nativeReplay() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let baseline = try #require(ScanReplayBaseline.capture(root: root))
    let path = root + "/journal-probe"
    try Data("probe".utf8).write(to: URL(fileURLWithPath: path))
    try await Task.sleep(for: .milliseconds(300))
    let replay = await FileEventsReplay.replay(root: root, since: baseline.eventID)
    #expect(replay.complete)
    #expect(replay.latestID >= baseline.eventID)
    #expect(replay.events.contains { $0.path == path || $0.path == root })
  }
}

extension ScanReplayTests {
  @Test("A new subtree linking into unchanged data requests a full scan")
  func newSubtreeHardLink() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/unchanged", withIntermediateDirectories: true)
    try Data("owned source".utf8).write(to: URL(fileURLWithPath: root + "/unchanged/source"))
    let engine = ScanEngine()
    let run = try engine.start(root: root)
    await run.waitUntilFinished()
    let baseline = try #require(run.replayBaseline)
    try FileManager.default.createDirectory(atPath: root + "/new/subtree", withIntermediateDirectories: true)
    try FileManager.default.linkItem(atPath: root + "/unchanged/source", toPath: root + "/new/subtree/linked")
    let replay = FileEventReplay(
      events: [
        FileEvent(path: root + "/new", flags: UInt32(kFSEventStreamEventFlagItemIsDir), id: baseline.eventID + 1)
      ], latestID: baseline.eventID + 1)
    #expect(
      engine.reconcile(tree: run.tree, replay: replay, baseline: baseline, currentBaseline: baseline)
        == .requiresFullScan)
  }
}
