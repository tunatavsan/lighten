import Darwin
import Foundation
import Testing

@testable import LightenKit

private func engineRoot() throws -> String {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw FileSystemFailure.invalidPath }
  defer { free(resolved) }
  let path = String(cString: resolved) + "/lighten-engine-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

private func write(_ path: String, bytes: Int) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
}

private func scan(_ root: String, home: String? = nil, workers: Int = 4) async throws -> ScanRun {
  let run = try ScanEngine(
    configuration: ScanConfiguration(workers: workers, homeDirectory: home ?? NSHomeDirectory())
  ).start(root: root)
  await run.waitUntilFinished()
  return run
}

private func child(_ run: ScanRun, _ name: String, under id: ScanItemID? = nil) throws -> SpaceItem {
  try #require(run.tree.children(of: id ?? run.tree.rootID, metric: .logical).first { $0.name == name })
}

/// Sum of lstat block allocation for every object below root, hard links once.
private func duAllocated(_ root: String) -> Int64 {
  var seen = Set<[UInt64]>()
  var total: Int64 = 0
  let enumerator = FileManager.default.enumerator(atPath: root)
  while let relative = enumerator?.nextObject() as? String {
    var details = stat()
    guard lstat(root + "/" + relative, &details) == 0 else { continue }
    guard seen.insert([UInt64(details.st_dev), details.st_ino]).inserted else { continue }
    total += Int64(details.st_blocks) * 512
  }
  return total
}

@Test func engineTotalsAreExactAndAllocatedMatchesBlocks() async throws {
  let root = try engineRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write(root + "/a/one", bytes: 1000)
  try write(root + "/a/b/two", bytes: 5000)
  try write(root + "/c/three", bytes: 0)
  try write(root + "/four", bytes: 12345)
  let run = try await scan(root)
  let top = try #require(run.tree.item(run.tree.rootID))
  #expect(top.state == .complete)
  #expect(top.logical.completeTotal == 18345)
  #expect(top.allocated.completeTotal == duAllocated(root))
  #expect(top.itemCount == 7)
  #expect(try child(run, "a").logical.completeTotal == 6000)
  #expect(try child(run, "four").kind == .file)
}

@Test func hardLinksCountOnceAcrossFolders() async throws {
  let root = try engineRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write(root + "/x/original", bytes: 4096)
  try FileManager.default.createDirectory(atPath: root + "/y", withIntermediateDirectories: true)
  #expect(link(root + "/x/original", root + "/x/second") == 0)
  #expect(link(root + "/x/original", root + "/y/third") == 0)
  let run = try await scan(root)
  let top = try #require(run.tree.item(run.tree.rootID))
  #expect(top.logical.completeTotal == 4096)
  #expect(top.itemCount == 3)  // x, y and one inode
}

@Test func symlinksAreLeavesAndNeverFollowed() async throws {
  let root = try engineRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write(root + "/big/data", bytes: 50_000)
  try FileManager.default.createDirectory(atPath: root + "/links", withIntermediateDirectories: true)
  #expect(symlink(root + "/big", root + "/links/to-big") == 0)
  #expect(symlink("/etc/hosts", root + "/links/outward") == 0)
  let run = try await scan(root)
  let links = try child(run, "links")
  #expect(links.state == .complete)
  #expect(links.logical.completeTotal == Int64((root + "/big").utf8.count + "/etc/hosts".utf8.count))
  let entries = run.tree.children(of: links.id, metric: .logical)
  #expect(entries.allSatisfy { $0.kind == .symlink })
  #expect(try #require(run.tree.item(run.tree.rootID)).logical.completeTotal == 50_000 + links.logical.completeTotal!)
}

@Test func packagesAreSingleMeasuredNodes() async throws {
  let root = try engineRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write(root + "/Tool.bundle/Contents/Resources/r", bytes: 700)
  try write(root + "/Tool.bundle/Contents/Info.plist", bytes: 300)
  let run = try await scan(root)
  let package = try child(run, "Tool.bundle")
  #expect(package.kind == .package)
  #expect(package.logical.completeTotal == 1000)
  #expect(package.itemCount == 4)
  #expect(!package.canInspect)
  #expect(run.tree.children(of: package.id, metric: .logical).isEmpty)
  #expect(package.canSelect)
}

@Test func protectedAreasAreMetadataOnlyAndSecretsAreNotOpened() async throws {
  let home = try engineRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  try write(home + "/Library/Mail/V10/mailbox", bytes: 2048)
  try write(home + "/.ssh/id_test", bytes: 100)
  try write(home + "/Library/CloudStorage/Drive/file", bytes: 100)
  try write(home + "/Pictures/Lib.photoslibrary/originals/p", bytes: 3000)
  let run = try await scan(home, home: home)
  let library = try child(run, "Library")
  let mail = try child(run, "Mail", under: library.id)
  #expect(mail.state == .protectedMetadataOnly(ruleID: "mail"))
  #expect(mail.logical.completeTotal == 2048)
  #expect(run.tree.children(of: mail.id, metric: .logical).isEmpty)
  #expect(!mail.canSelect && !mail.canInspect)
  let ssh = try child(run, ".ssh")
  #expect(ssh.state == .partial(.protectedNotTraversed))
  #expect(ssh.logical.knownLowerBound == 0)
  let cloud = try child(run, "CloudStorage", under: library.id)
  #expect(cloud.state == .partial(.cloudNotMeasured))
  let pictures = try child(run, "Pictures")
  let photos = try child(run, "Lib.photoslibrary", under: pictures.id)
  #expect(photos.state == .protectedMetadataOnly(ruleID: "photos-library"))
  #expect(photos.logical.completeTotal == 3000)
  let top = try #require(run.tree.item(run.tree.rootID))
  #expect(top.logical.completeTotal == nil)
  #expect(top.state == .partial(.descendant))
}

@Test func unreadableFolderMakesAncestorsLowerBounds() async throws {
  let root = try engineRoot()
  defer {
    chmod(root + "/closed", 0o755)
    try? FileManager.default.removeItem(atPath: root)
  }
  try write(root + "/closed/inside", bytes: 900)
  try write(root + "/open/file", bytes: 100)
  #expect(chmod(root + "/closed", 0o000) == 0)
  let run = try await scan(root)
  #expect(try child(run, "closed").state == .partial(.unreadable))
  let top = try #require(run.tree.item(run.tree.rootID))
  #expect(top.logical.completeTotal == nil)
  #expect(top.logical.knownLowerBound == 100)
  #expect(try child(run, "open").state == .complete)
}

@Test func mountBoundaryAndDatalessFoldersAreNotTraversed() throws {
  let tree = ScanTree(runID: UUID(), rootPath: "/r", root: ScanTree.rootNode(name: "/r", device: 7, inode: 1))
  let walker = ParallelWalker(
    tree: tree, counters: ScanCounters(), automaton: ProtectionAutomaton(homeDirectory: "/home"),
    boundaryDevice: 7, homeDirectory: "/home", firmlinks: nil, workers: 1, onFinish: {})
  let parent = WalkJob(
    owner: 0, path: "/r", device: 7, inode: 1, mode: .node, depth: 0,
    protection: ProtectionAutomaton(homeDirectory: "/home").state(forPath: "/r"))
  func entry(_ name: String, device: UInt64, flags: UInt32) -> RawEntry {
    RawEntry(
      name: name, kind: .directory, device: device, inode: 9, flags: flags, linkCount: 1, logical: 0,
      allocated: 0, error: 0)
  }
  let mount = walker.classify(entry("disk", device: 8, flags: 0), parent: parent)
  #expect(mount.reason == .mountBoundary && !mount.traverse)
  let cloud = walker.classify(entry("remote", device: 7, flags: UInt32(SF_DATALESS)), parent: parent)
  #expect(cloud.reason == .cloudNotMeasured && !cloud.traverse)
  let plain = walker.classify(entry("plain", device: 7, flags: 0), parent: parent)
  #expect(plain.reason == nil && plain.traverse && plain.kind == .directory)
}

@Test func largestFilesAreKeptAndTheRestSummarized() async throws {
  let root = try engineRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  for index in 0..<40 { try write(root + "/f\(index)", bytes: index + 1) }
  let run = try await scan(root)
  let rows = run.tree.children(of: run.tree.rootID, metric: .logical)
  #expect(rows.filter { $0.kind == .file }.count == ScanTree.filesPerDirectory)
  let summary = try #require(rows.first { $0.kind == .smallFiles })
  #expect(summary.summarizedFiles == 8)
  #expect(summary.logical.completeTotal == (1...8).reduce(0, +))
  #expect(rows.first?.name == "f39")
  #expect(!summary.canSelect)
}

@Test func cancellationStopsQuicklyAndLeavesLowerBounds() async throws {
  let root = try engineRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  for folder in 0..<200 {
    for file in 0..<50 { try write(root + "/d\(folder)/s\(file % 5)/f\(file)", bytes: 1) }
  }
  let run = try ScanEngine(configuration: ScanConfiguration(workers: 2)).start(root: root)
  let cancelledAt = ContinuousClock.now
  run.cancel()
  let start = ContinuousClock.now
  await run.waitUntilFinished()
  let resumed = ContinuousClock.now
  let finished = try #require(run.completionInstant)
  print(
    "Scan cancellation: worker finish \(cancelledAt.duration(to: finished)); await resumption \(cancelledAt.duration(to: resumed)); scheduling delay \(finished.duration(to: resumed))"
  )
  // Correctness bound for a loaded, shared test runner; the 250 ms p95 target is
  // measured on the release build with lighten-bench.
  #expect(ContinuousClock.now - start < .seconds(2))
  #expect(run.tree.wasCancelled)
  let fresh = try await scan(root)
  #expect(!fresh.tree.wasCancelled)
  #expect(fresh.runID != run.runID)
  #expect(try #require(fresh.tree.item(fresh.tree.rootID)).logical.completeTotal == 10_000)
}

@Test func resultsAreIndependentOfWorkerCount() async throws {
  let root = try engineRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  for folder in 0..<30 {
    for file in 0..<(folder % 7 + 1) {
      try write(root + "/d\(folder)/e\(file % 3)/f\(file)", bytes: folder * 10 + file)
    }
  }
  var signatures: [[String]] = []
  for workers in [1, 4, 12] {
    let run = try await scan(root, workers: workers)
    let rows = run.tree.children(of: run.tree.rootID, metric: .logical)
    signatures.append(rows.map { "\($0.name)=\($0.logical.completeTotal ?? -1)/\($0.itemCount)" })
  }
  #expect(signatures[0] == signatures[1])
  #expect(signatures[1] == signatures[2])
}

@Test func progressPublishesFirstScreenAndFinishes() async throws {
  let root = try engineRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write(root + "/x/file", bytes: 10)
  let run = try ScanEngine().start(root: root)
  var last: ScanProgress?
  for await update in run.progress { last = update }
  #expect(last?.finished == true)
  #expect(last?.cancelled == false)
  #expect(last?.rootLogicalLowerBound == 10)
}

@Test func diskRootUsesVisibleFirmlinkPaths() {
  var root = ScanTree.rootNode(name: "/", device: 1, inode: 2)
  root.childNodes = [1, 2, 3]
  let users = ScanTree.Node(name: "Users", parent: 0, kind: .directory, device: 1, inode: 3)
  let hidden = ScanTree.Node(name: ".fseventsd", parent: 0, kind: .directory, device: 1, inode: 4)
  let home = ScanTree.Node(name: "me", parent: 1, kind: .directory, device: 1, inode: 5)
  let nodes = [root, users, hidden, home]
  #expect(ScanTree.path(of: 3, in: nodes, rootPath: "/", firmlinks: ["Users"]) == "/Users/me")
  #expect(ScanTree.path(of: 2, in: nodes, rootPath: "/", firmlinks: ["Users"]) == "/System/Volumes/Data/.fseventsd")
  #expect(ScanEngine.firmlinkNames().contains("Users"))
}

@Test func automatonAgreesWithProtectionPolicy() {
  let home = "/Users/probe"
  let automaton = ProtectionAutomaton(homeDirectory: home)
  let paths = [
    "/System/Library/x", "/Users/probe/Library/Mail/V1", "/Users/probe/library/MAIL/x",
    "/Applications/Foo.app/Contents/MacOS/foo", "/Applications/Foo.app/Contents/Resources/en.lproj/a",
    "/Users/probe/Documents/report.pdf", "/Users/probe/VM.utm/disk", "/Users/probe/x/y.sparseimage",
    "/Users/probe/Library/Group Containers/g.orbstack/data.img", "/Volumes/Ext/Photos.photoslibrary/db",
    "/Users/probe/.ssh", "/Users/probe/Library/Containers/app/Data/Documents/n",
  ]
  for path in paths {
    let expected = ProtectionPolicy.rule(for: path, homeDirectory: home)?.id
    #expect(automaton.match(automaton.state(forPath: path))?.id == expected, "\(path)")
  }
}

@Test func cacheRoundTripsAFinishedTreeAndRefusesCancelledOnes() async throws {
  let root = try engineRoot()
  let cacheDirectory = try engineRoot()
  defer {
    try? FileManager.default.removeItem(atPath: root)
    try? FileManager.default.removeItem(atPath: cacheDirectory)
  }
  try write(root + "/folder/file", bytes: 321)
  for index in 0..<40 { try write(root + "/many/f\(index)", bytes: index) }
  #expect(symlink("folder", root + "/link") == 0)
  let cache = ScanCache(directory: cacheDirectory)
  let run = try await scan(root)
  try cache.save(run.tree)
  let loaded = try #require(cache.load(root: root))
  #expect(loaded.tree.isFinished)
  let original = run.tree.children(of: run.tree.rootID, metric: .logical)
  let restored = loaded.tree.children(of: loaded.tree.rootID, metric: .logical)
  #expect(original == restored)
  let many = try child(run, "many")
  #expect(
    run.tree.children(of: many.id, metric: .allocated)
      == loaded.tree.children(of: many.id, metric: .allocated))
  #expect(loaded.tree.find(path: root + "/folder") == (try child(run, "folder")).id)
  #expect(cache.load(root: root + "/other") == nil)

  let cancelled = try ScanEngine().start(root: root)
  cancelled.cancel()
  await cancelled.waitUntilFinished()
  let otherCache = ScanCache(directory: cacheDirectory + "/second")
  try otherCache.save(cancelled.tree)
  // A tiny tree can finish before the cancel lands; only a cancelled tree must be refused.
  #expect((otherCache.load(root: root) == nil) == cancelled.tree.wasCancelled)
}
