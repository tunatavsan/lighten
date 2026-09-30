import Darwin
import Foundation
import Testing

@testable import LightenKit

private struct PictureFixture {
  let root: String
  var directory: String { root + "/results" }
  var file: String { directory + "/apps.json" }
  var store: ResultPictureStore { ResultPictureStore(directory: directory) }

  init() throws {
    guard let temporary = realpath(NSTemporaryDirectory(), nil) else { throw FileSystemFailure.invalidPath }
    defer { free(temporary) }
    root = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }

  func picture(bytes: Int64 = 123, date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ResultPicture<
    AppsPicture
  > {
    let report = ApplicationReport(
      path: root + "/LightenQA.app", bundleID: "qa.lighten.picture", version: "1.2", signerTeamID: "DISPLAY",
      logical: ByteAggregate(knownLowerBound: bytes, completeTotal: bytes),
      allocated: ByteAggregate(knownLowerBound: bytes, completeTotal: nil),
      knownItemCount: 4, partial: true, related: [], manualUninstallerSuggested: false)
    return ResultPicture(observedAt: date, content: AppsPicture(reports: [report], inventoryComplete: true))
  }

  func rewrite(_ body: (inout [String: Any]) throws -> Void) throws {
    let url = URL(fileURLWithPath: file)
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    try body(&object)
    try JSONSerialization.data(withJSONObject: object).write(to: url)
  }
}

@Test("A cold load preserves the picture timestamp and display metadata")
func resultPictureColdLoad() throws {
  let fixture = try PictureFixture()
  defer { fixture.remove() }
  let original = fixture.picture()
  try fixture.store.save(original, named: "apps")
  let cold = ResultPictureStore(directory: fixture.directory)
  let loaded = try #require(cold.load(AppsPicture.self, named: "apps"))
  #expect(loaded.observedAt == original.observedAt)
  #expect(loaded.content == original.content)
  #expect(loaded.content.rows.first?.bundleID == "qa.lighten.picture")
  #expect(loaded.content.rows.first?.logical.knownLowerBound == 123)
}

@Test("Atomic replacement leaves one complete private picture and no temporary files")
func resultPictureAtomicOverwrite() throws {
  let fixture = try PictureFixture()
  defer { fixture.remove() }
  try fixture.store.save(fixture.picture(), named: "apps")
  let originalIdentity = try DescriptorFileSystem.identity(at: fixture.file)
  try fixture.store.save(fixture.picture(bytes: 456), named: "apps")
  let replacedIdentity = try DescriptorFileSystem.identity(at: fixture.file)
  #expect(originalIdentity.inode != replacedIdentity.inode)
  #expect(fixture.store.load(AppsPicture.self, named: "apps")?.content.rows.first?.logical.knownLowerBound == 456)
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory) == ["apps.json"])
  var fileDetails = stat()
  var directoryDetails = stat()
  #expect(lstat(fixture.file, &fileDetails) == 0)
  #expect(lstat(fixture.directory, &directoryDetails) == 0)
  #expect(fileDetails.st_mode & 0o777 == 0o600)
  #expect(directoryDetails.st_mode & 0o777 == 0o700)
}

@Test("Independent tools can create their shared picture directory concurrently")
func resultPictureConcurrentCreation() async throws {
  let fixture = try PictureFixture()
  defer { fixture.remove() }
  let store = fixture.store
  let picture = fixture.picture()
  try await withThrowingTaskGroup(of: Void.self) { group in
    for index in 0..<12 {
      group.addTask { try store.save(picture, named: "tool-\(index)") }
    }
    try await group.waitForAll()
  }
  for index in 0..<12 {
    #expect(store.load(AppsPicture.self, named: "tool-\(index)")?.content == picture.content)
  }
}

@Test("Loading a missing picture creates no directories")
func resultPictureMissingIsReadOnly() throws {
  let fixture = try PictureFixture()
  defer { fixture.remove() }
  #expect(fixture.store.load(AppsPicture.self, named: "apps") == nil)
  #expect(!FileManager.default.fileExists(atPath: fixture.directory))
}

@Test(
  "Corrupt, future, and unsupported-schema pictures are ignored without alteration",
  arguments: ["corrupt", "future", "schema"])
func resultPictureInvalidIsReadOnly(fault: String) throws {
  let fixture = try PictureFixture()
  defer { fixture.remove() }
  try fixture.store.save(fixture.picture(), named: "apps")
  if fault == "corrupt" {
    try Data("{broken".utf8).write(to: URL(fileURLWithPath: fixture.file))
  } else {
    try fixture.rewrite { object in
      if fault == "schema" {
        object["schema"] = 2
      } else {
        var picture = try #require(object["picture"] as? [String: Any])
        picture["observedAt"] = Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate
        object["picture"] = picture
      }
    }
  }
  let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.file))
  let identity = try DescriptorFileSystem.identity(at: fixture.file)
  #expect(fixture.store.load(AppsPicture.self, named: "apps") == nil)
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.file)) == bytes)
  #expect(try DescriptorFileSystem.identity(at: fixture.file) == identity)
}

@Test("Oversized files and saves respect the bound without replacing the previous picture")
func resultPictureSizeBound() throws {
  let fixture = try PictureFixture()
  defer { fixture.remove() }
  try fixture.store.save(fixture.picture(), named: "apps")
  let original = try Data(contentsOf: URL(fileURLWithPath: fixture.file))
  let bounded = ResultPictureStore(directory: fixture.directory, maximumBytes: original.count - 1)
  #expect(bounded.load(AppsPicture.self, named: "apps") == nil)
  #expect(throws: ResultPictureFailure.tooLarge) { try bounded.save(fixture.picture(), named: "apps") }
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.file)) == original)
}

@Test(
  "Unsafe files cannot be loaded or replaced", arguments: ["symlink", "hardlink", "permissions", "directory", "fifo"])
func resultPictureUnsafeFile(fault: String) throws {
  let fixture = try PictureFixture()
  defer { fixture.remove() }
  try fixture.store.save(fixture.picture(), named: "apps")
  let outside = fixture.root + "/outside"
  try Data("outside".utf8).write(to: URL(fileURLWithPath: outside))
  if fault == "permissions" {
    #expect(chmod(fixture.file, 0o644) == 0)
  } else if fault == "hardlink" {
    #expect(link(fixture.file, fixture.root + "/linked") == 0)
  } else {
    try FileManager.default.removeItem(atPath: fixture.file)
    switch fault {
    case "symlink": #expect(symlink(outside, fixture.file) == 0)
    case "fifo": #expect(mkfifo(fixture.file, 0o600) == 0)
    default:
      try FileManager.default.createDirectory(atPath: fixture.file, withIntermediateDirectories: false)
    }
  }
  let before = try DescriptorFileSystem.identity(at: fixture.file)
  #expect(fixture.store.load(AppsPicture.self, named: "apps") == nil)
  #expect(throws: (any Error).self) { try fixture.store.save(fixture.picture(bytes: 456), named: "apps") }
  #expect(try DescriptorFileSystem.identity(at: fixture.file) == before)
  #expect(try String(contentsOfFile: outside, encoding: .utf8) == "outside")
}

@Test("Nonprivate and linked result directories are rejected", arguments: ["permissions", "symlink"])
func resultPictureUnsafeDirectory(fault: String) throws {
  let fixture = try PictureFixture()
  defer { fixture.remove() }
  try fixture.store.save(fixture.picture(), named: "apps")
  let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.file))
  if fault == "permissions" {
    #expect(chmod(fixture.directory, 0o755) == 0)
  } else {
    let moved = fixture.root + "/moved"
    try FileManager.default.moveItem(atPath: fixture.directory, toPath: moved)
    #expect(symlink(moved, fixture.directory) == 0)
  }
  #expect(fixture.store.load(AppsPicture.self, named: "apps") == nil)
  #expect(throws: (any Error).self) { try fixture.store.save(fixture.picture(), named: "apps") }
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.file)) == bytes)
}

@Test("Keys cannot escape the result directory", arguments: ["", "../apps", "/apps", "apps/test", "Apps", "apps.json"])
func resultPictureKeyBound(name: String) throws {
  let fixture = try PictureFixture()
  defer { fixture.remove() }
  #expect(fixture.store.load(AppsPicture.self, named: name) == nil)
  #expect(throws: ResultPictureFailure.invalidPicture) { try fixture.store.save(fixture.picture(), named: name) }
  #expect(!FileManager.default.fileExists(atPath: fixture.directory))
}

@Test("Apps pictures encode no inventory, receipts, identities, snapshots, or action plans")
func resultPictureHasDisplayFieldsOnly() throws {
  let fixture = try PictureFixture()
  defer { fixture.remove() }
  let app = ApplicationReport(
    path: fixture.root + "/LightenQA.app", bundleID: "qa.lighten.picture", version: nil, signerTeamID: nil,
    logical: ByteAggregate(knownLowerBound: 123, completeTotal: nil),
    allocated: ByteAggregate(knownLowerBound: 123, completeTotal: nil), knownItemCount: 1, partial: true,
    related: [
      RelatedDataCandidate(
        id: "display", path: fixture.root + "/cache", classification: .installed, reason: .installed,
        snapshot: nil, receipt: nil)
    ], manualUninstallerSuggested: false)
  try fixture.store.save(
    ResultPicture(
      observedAt: fixture.picture().observedAt, content: AppsPicture(reports: [app], inventoryComplete: true)),
    named: "apps")
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture.file))) as? [String: Any])
  let envelope = try #require(object["picture"] as? [String: Any])
  let content = try #require(envelope["content"] as? [String: Any])
  let rows = try #require(content["rows"] as? [[String: Any]])
  #expect(Set(content.keys) == ["rows", "inventoryComplete"])
  #expect(
    Set(rows[0].keys) == [
      "path", "bundleID", "logical", "allocated", "knownItemCount", "partial", "manualUninstallerSuggested",
    ])
}
