import Darwin
import Foundation
import Testing

@testable import LightenKit

private func fixtureRoot() throws -> String {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
    throw FileSystemFailure.invalidPath
  }
  defer { free(resolved) }
  let base = String(cString: resolved)
  let path = base + "/lighten-test-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

private func writeFixture(_ path: String, _ text: String = "fixture") throws {
  try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private func snapshot(_ root: String, home: String? = nil) async throws -> ScanSnapshot {
  try await ScanService(homeDirectory: home ?? NSHomeDirectory()).scan(rootPath: root)
}

private func plan(_ snapshot: ScanSnapshot, path: String, home: String? = nil) throws -> ActionPlan {
  let entry = try #require(snapshot.entries.first { $0.path == path })
  return try PlanService(homeDirectory: home ?? NSHomeDirectory())
    .makePlan(snapshot: snapshot, selectedIDs: [entry.id])
}

private struct StubAttributes: FileAttributeSource {
  let values: [String: FileAttributes]
  let names: [String: [String]]
  let delay: Duration

  func volumeID(at path: String) async throws -> UUID? {
    if path.contains("unknown-volume") { return nil }
    return UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
  }

  func inspect(at path: String) async throws -> FileAttributes {
    try Task.checkCancellation()
    if delay > .zero { try await Task.sleep(for: delay) }
    guard let value = values[path] else { throw FileSystemFailure.invalidPath }
    return value
  }

  func children(at path: String, expected: FileIdentity) async throws -> [String] {
    if delay > .zero { try await Task.sleep(for: delay) }
    try Task.checkCancellation()
    return names[path] ?? []
  }
}

private func fakeIdentity(
  device: UInt64 = 1, inode: UInt64 = 1, kind: EntryKind = .directory,
  flags: UInt32 = 0
) -> FileIdentity {
  FileIdentity(
    device: device, inode: inode, changeSeconds: 1,
    changeNanoseconds: 0, logicalBytes: 5, allocatedBytes: 512,
    linkCount: 1, flags: flags, kind: kind)
}

@Test func descriptorIdentityPreservesSignedDeviceBits() throws {
  let devices: [UInt32] = [0, 1, 0x7fff_ffff, 0x8000_0000, 0x8000_0001, 0xffff_fffe, 0xffff_ffff]
  var identities: [FileIdentity] = []
  for bits in devices {
    var details = stat()
    details.st_dev = dev_t(bitPattern: bits)
    details.st_ino = 17
    details.st_mode = mode_t(S_IFREG)
    details.st_nlink = 1
    details.st_size = 5
    details.st_blocks = 1
    details.st_ctimespec = timespec(tv_sec: 1, tv_nsec: 2)
    details.st_mtimespec = timespec(tv_sec: 3, tv_nsec: 4)
    let identity = DescriptorFileSystem.identity(from: details)
    // Bulk and live vnode readers expose the same device bits as uint32_t.
    let bulk = RawEntry(
      name: "fixture", kind: .regular, device: UInt64(bits), inode: 17,
      flags: 0, linkCount: 1, logical: 5, allocated: 512, error: 0,
      modificationTime: FileTimestamp(seconds: 3, nanoseconds: 4),
      changeTime: FileTimestamp(seconds: 1, nanoseconds: 2), identityLogicalBytes: 5)
    #expect(identity.device == UInt64(bits))
    #expect(identity == DescriptorFileSystem.identity(from: details))
    #expect(identity == bulk.identity)
    #expect(try JSONDecoder().decode(FileIdentity.self, from: JSONEncoder().encode(identity)) == identity)
    identities.append(identity)
  }
  // The inode and all other metadata are identical; each distinct device stays distinct.
  for first in identities.indices {
    for second in identities.indices where first != second {
      #expect(identities[first] != identities[second])
    }
  }
}

@Test func snapshotRoundTripAndCompleteTotals() async throws {
  let root = try fixtureRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeFixture(root + "/one")
  try writeFixture(root + "/two", "longer fixture")
  let scan = try await snapshot(root)
  #expect(scan.schema == 1)
  #expect(scan.volumeID != nil)
  #expect(scan.entries.count == 3)
  let rootNode = try #require(scan.nodes.first { $0.parentID == nil })
  #expect(rootNode.completeItemCount == 3)
  #expect(rootNode.logical.completeTotal == rootNode.logical.knownLowerBound)
  let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: JSONEncoder().encode(scan))
  #expect(decoded == scan)
  let action = try plan(scan, path: root + "/one")
  #expect(action.items[0].inventory.count == 1)
  #expect(try JSONDecoder().decode(ActionPlan.self, from: JSONEncoder().encode(action)) == action)
}

@Test func unknownVolumeIsVisibleAndNotActionable() async throws {
  let root = "/test/unknown-volume-" + UUID().uuidString
  let source = StubAttributes(
    values: [root: FileAttributes(identity: fakeIdentity(), readable: true)],
    names: [root: []], delay: .zero)
  let scan = try await ScanService(attributes: source).scan(rootPath: root)
  #expect(scan.volumeID == nil)
  #expect(scan.entries[0].issues.contains(.unknownVolume))
  #expect(scan.nodes[0].partial)
}

@Test func progressAndCallerCancellation() async throws {
  let root = "/test/" + UUID().uuidString
  let source = StubAttributes(
    values: [root: FileAttributes(identity: fakeIdentity(), readable: true)],
    names: [root: []], delay: .seconds(10))
  let service = ScanService(attributes: source)
  let work = Task { try await service.scan(rootPath: root) }
  try await Task.sleep(for: .milliseconds(20))
  work.cancel()
  do {
    _ = try await work.value
    Issue.record("cancelled scan completed")
  } catch is CancellationError {
    // Expected: caller cancellation reaches detached traversal.
  }

  let fast = ScanService(
    attributes: StubAttributes(
      values: [root: FileAttributes(identity: fakeIdentity(), readable: true)],
      names: [root: []], delay: .zero))
  var progress = 0
  var completed = false
  for try await event in fast.events(rootPath: root) {
    switch event {
    case .progress(let count, _): progress = count
    case .completed: completed = true
    }
  }
  #expect(progress == 1)
  #expect(completed)
}

@Test func diskRootCanBeObservedButNeverSelected() async throws {
  #expect(try DescriptorFileSystem.identity(at: "/").kind == .directory)
  let source = StubAttributes(
    values: [
      "/": FileAttributes(identity: fakeIdentity(), readable: true),
      "/probe": FileAttributes(identity: fakeIdentity(inode: 2, kind: .regular), readable: true),
    ],
    names: ["/": ["probe"]], delay: .zero)
  let scan = try await ScanService(attributes: source).scan(rootPath: "/")
  #expect(scan.entries.count == 2)
  #expect(scan.entries[0].path == "/")
  #expect(scan.entries[1].path == "/probe")
  #expect(throws: PlanFailure.self) {
    try PlanService().makePlan(snapshot: scan, selectedIDs: [scan.entries[0].id])
  }
}

@Test func injectedUnknownUnreadableMountAndDatalessArePartial() async throws {
  let root = "/test/" + UUID().uuidString
  let values: [String: FileAttributes] = [
    root: FileAttributes(identity: fakeIdentity(), readable: true),
    root + "/unreadable": FileAttributes(identity: fakeIdentity(inode: 2, kind: .regular), readable: false),
    root + "/mount": FileAttributes(identity: fakeIdentity(device: 2, inode: 3), readable: true),
    root + "/cloud": FileAttributes(identity: fakeIdentity(inode: 4, flags: UInt32(SF_DATALESS)), readable: true),
  ]
  let source = StubAttributes(
    values: values,
    names: [root: ["unreadable", "mount", "cloud", "missing"]], delay: .zero)
  let scan = try await ScanService(attributes: source).scan(rootPath: root)
  #expect(scan.entries.count == 5)
  #expect(scan.entries.first { $0.path == root + "/unreadable" }?.issues.contains(.unreadable) == true)
  #expect(scan.entries.first { $0.path == root + "/mount" }?.issues.contains(.mountBoundary) == true)
  #expect(scan.entries.first { $0.path == root + "/cloud" }?.issues.contains(.dataless) == true)
  #expect(scan.entries.first { $0.path == root + "/missing" }?.issues.contains(.unknownMetadata) == true)
  let node = try #require(scan.nodes.first { $0.parentID == nil })
  #expect(node.partial)
  #expect(node.logical.completeTotal == nil)
  #expect(node.logical.knownLowerBound > 0)
  for entry in scan.entries where entry.parentID != nil {
    #expect(throws: PlanFailure.self) {
      try PlanService().makePlan(snapshot: scan, selectedIDs: [entry.id])
    }
  }
}

@Test func protectedAliasAndPackageInteriorAreNotPlannable() async throws {
  let root = try fixtureRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try FileManager.default.createDirectory(atPath: root + "/.SSH", withIntermediateDirectories: true)
  try writeFixture(root + "/.SSH/key")
  try FileManager.default.createDirectory(atPath: root + "/Thing.playground", withIntermediateDirectories: true)
  try writeFixture(root + "/Thing.playground/file")
  let scan = try await snapshot(root, home: root)
  #expect(scan.entries.first { $0.path == root + "/.SSH" }?.issues.contains(.protected) == true)
  #expect(scan.entries.first { $0.path == root + "/Thing.playground" }?.issues.contains(.packageBoundary) == true)
  #expect(!scan.entries.contains { $0.path == root + "/Thing.playground/file" })
  let alias = try #require(scan.entries.first { $0.path == root + "/.SSH" })
  #expect(throws: PlanFailure.self) {
    try PlanService(homeDirectory: root).makePlan(snapshot: scan, selectedIDs: [alias.id])
  }
  let inside = try await snapshot(root + "/Thing.playground", home: root)
  #expect(inside.entries.count == 1)
  #expect(inside.entries[0].issues.contains(.packageBoundary))
}

@Test func guardRejectsNewChildChangedIdentityAndSymlink() async throws {
  let root = try fixtureRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let folder = root + "/folder"
  try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
  try writeFixture(folder + "/old")
  let action = try plan(await snapshot(root), path: folder)
  try ActionGuard().validate(action.items[0])
  try writeFixture(folder + "/new")
  #expect(throws: GuardFailure.self) { try ActionGuard().validate(action.items[0]) }
  try FileManager.default.removeItem(atPath: folder + "/new")
  try writeFixture(folder + "/old", "changed")
  #expect(throws: GuardFailure.self) { try ActionGuard().validate(action.items[0]) }

  let sibling = root + "/sibling"
  try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: true)
  try writeFixture(sibling + "/child")
  let second = try plan(await snapshot(root), path: sibling)
  try FileManager.default.moveItem(atPath: sibling, toPath: root + "/elsewhere")
  try FileManager.default.createSymbolicLink(atPath: sibling, withDestinationPath: root + "/elsewhere")
  #expect(throws: GuardFailure.self) { try ActionGuard().validate(second.items[0]) }
}

@Test func forgedBulkPackageAndProtectedAliasFailAtFinalGuard() async throws {
  let root = try fixtureRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try FileManager.default.createDirectory(atPath: root + "/Thing.rtfd", withIntermediateDirectories: true)
  try writeFixture(root + "/Thing.rtfd/file")
  try FileManager.default.createDirectory(atPath: root + "/.SSH", withIntermediateDirectories: true)
  let guardService = ActionGuard(homeDirectory: root)
  for path in [root, root + "/Thing.rtfd/file", root + "/.SSH"] {
    let identity = try DescriptorFileSystem.identity(at: path)
    let id = UUID()
    let entry = ScanEntry(
      id: id, parentID: nil, path: path, identity: identity,
      issues: [], readable: true)
    let item = PlanItem(
      id: id, sourcePath: path, inventory: [entry],
      ancestors: try DescriptorFileSystem.ancestorIdentities(of: path))
    #expect(throws: GuardFailure.self) { try guardService.validate(item) }
    if path == root {
      #expect(throws: GuardFailure.self) {
        try ActionGuard(homeDirectory: root.uppercased()).validate(item)
      }
    }
  }
}
