import Foundation
import Testing

@testable import LightenKit

@Suite("Metadata removal reminders")
struct ProtectiveWarningTests {
  private func libraryEntry(_ path: String, kind: EntryKind = .directory) -> ScanEntry {
    ScanEntry(
      parentID: nil, path: path,
      identity: FileIdentity(
        device: 1, inode: 2, changeSeconds: 1, changeNanoseconds: 0,
        logicalBytes: 12, allocatedBytes: 4096, linkCount: 1, flags: 0, kind: kind),
      issues: [], readable: true)
  }

  private func item(_ names: [String], folder: String = "/private/tmp/LightenQA-home/personal") -> PlanItem {
    PlanItem(
      id: UUID(), sourcePath: folder,
      inventory: names.map { name in
        ScanEntry(
          parentID: nil, path: folder + "/" + name,
          identity: FileIdentity(
            device: 1, inode: 2, changeSeconds: 1, changeNanoseconds: 0,
            logicalBytes: 12, allocatedBytes: 4096, linkCount: 1, flags: 0, kind: .regular),
          issues: [], readable: true)
      }, ancestors: [])
  }

  @Test(
    "Secret file names produce a reminder",
    arguments: ["key.pem", "cert.p12", "vault.kdbx", "secret.gpg", "id_rsa", ".env"])
  func secrets(_ name: String) {
    #expect(ProtectiveWarning.evaluate(item([name])) == .secrets)
  }

  @Test("Personal file majority says copy unknown, never sole copy")
  func personal() {
    #expect(ProtectiveWarning.evaluate(item(["a.jpg", "b.pdf", "build.swift", "data.bin"])) == .copyUnknown)
    #expect(ProtectiveWarning.evaluate(item(["a.jpg", "data.bin"])) == nil)
    #expect(ProtectiveWarning.evaluate(item(["a.jpg"]), knownOtherCopy: true) == nil)
  }

  @Test(
    "Regenerable locations and installers suppress reminders",
    arguments: ["Caches", "Logs", "node_modules", "DerivedData", "installer.dmg", "installer.pkg"])
  func suppress(_ folder: String) {
    #expect(
      ProtectiveWarning.evaluate(item(["a.jpg", "key.pem"], folder: "/private/tmp/LightenQA-home/" + folder)) == nil)
  }

  @Test("Explicit Trash data gets a valuable-data reminder")
  func explicit() {
    let home = "/private/tmp/LightenQA-home"
    let selected = item(["archive.bin"], folder: home + "/Library/Developer/Xcode/Archives/build.xcarchive")
    #expect(ProtectiveWarning.evaluate(selected, homeDirectory: home) == .valuableData)
  }

  @Test("A reminder does not change the plan or Guard result")
  func guardUnchanged() throws {
    let home = "/private/tmp/LightenQA-" + UUID().uuidString
    let path = home + "/personal/photo.jpg"
    try FileManager.default.createDirectory(atPath: home + "/personal", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }
    try Data("owned photo metadata fixture".utf8).write(to: URL(fileURLWithPath: path))
    let identity = try DescriptorFileSystem.identity(at: home + "/personal")
    let plan = try PlanService(homeDirectory: home).makeSpacePlan(
      selections: [PlanService.Selection(path: home + "/personal", device: identity.device, inode: identity.inode)],
      scanRootPath: home, runID: UUID())
    let selected = try #require(plan.items.first)
    let guardService = ActionGuard(homeDirectory: home)
    try guardService.validate(selected)
    #expect(ProtectiveWarning.evaluate(selected) == .copyUnknown)
    #expect(ProtectiveWarning.evaluate(selected, knownOtherCopy: true) == nil)
    try guardService.validate(selected)
    #expect(plan.items == [selected])
  }

  @Test(
    "An opaque personal library root warns without payload inventory",
    arguments: ["fcpbundle", "logicx", "band", "imovielibrary", "musiclibrary", "FCPBUNDLE"])
  func opaqueLibrary(_ suffix: String) {
    let path = "/private/tmp/LightenQA-home/Projects/Personal." + suffix
    let root = libraryEntry(path)
    let selected = PlanItem(
      id: root.id, sourcePath: path, inventory: [root], ancestors: [], policy: .spaceTrash)
    #expect(selected.inventory.count == 1)
    #expect(ProtectiveWarning.evaluate(selected) == .personalLibrary)
    #expect(ProtectiveWarning.personalLibrary.examplePaths(selected) == [path])
    #expect(ProtectiveWarning.evaluate(selected, knownOtherCopy: true) == nil)
  }

  @Test("A parent warns about an inventoried library and names its actual root")
  func nestedLibraryRoot() {
    let path = "/private/tmp/LightenQA-home/Projects/Personal.logicx"
    let root = libraryEntry(path)
    let selected = PlanItem(
      id: UUID(), sourcePath: "/private/tmp/LightenQA-home/Projects",
      inventory: [root], ancestors: [], policy: .spaceTrash)
    #expect(ProtectiveWarning.evaluate(selected) == .personalLibrary)
    #expect(ProtectiveWarning.personalLibrary.examplePaths(selected) == [path])
  }

  @Test("An explicit library still warns when its path contains a cache folder")
  func libraryInCacheFolder() {
    let path = "/private/tmp/LightenQA-home/Caches/Personal.band"
    let root = libraryEntry(path)
    let selected = PlanItem(id: root.id, sourcePath: path, inventory: [root], ancestors: [])
    #expect(ProtectiveWarning.evaluate(selected) == .personalLibrary)
  }

  @Test("Known secret names retain priority over a personal library reminder")
  func libraryDoesNotHideKnownSecrets() {
    let path = "/private/tmp/LightenQA-home/Projects"
    let library = libraryEntry(path + "/Personal.band")
    let secret = libraryEntry(path + "/key.pem", kind: .regular)
    let selected = PlanItem(
      id: UUID(), sourcePath: path, inventory: [library, secret], ancestors: [])
    #expect(ProtectiveWarning.evaluate(selected) == .secrets)
    #expect(ProtectiveWarning.secrets.examplePaths(selected) == [secret.path])
  }

  @Test(
    "A symlink or ordinary file with a library suffix is not followed or inferred",
    arguments: [
      EntryKind.symbolicLink, .regular,
    ])
  func libraryNameDoesNotGrantDirectoryFacts(_ kind: EntryKind) {
    let path = "/private/tmp/LightenQA-home/Personal.fcpbundle"
    let root = libraryEntry(path, kind: kind)
    let selected = PlanItem(id: root.id, sourcePath: path, inventory: [root], ancestors: [])
    #expect(ProtectiveWarning.evaluate(selected) == nil)
    #expect(ProtectiveWarning.personalLibrary.examplePaths(selected).isEmpty)
  }

  @Test("A library reminder preserves the complete safe plan and Guard validation")
  func libraryWarningIsNonblocking() throws {
    let home = "/private/tmp/LightenQA-" + UUID().uuidString
    let path = home + "/Projects/Personal.fcpbundle"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }
    try Data("owned library project".utf8).write(to: URL(fileURLWithPath: path + "/project.bin"))
    let identity = try DescriptorFileSystem.identity(at: path)
    let plan = try PlanService(homeDirectory: home).makeSpacePlan(
      selections: [.init(path: path, device: identity.device, inode: identity.inode)],
      scanRootPath: home, runID: UUID())
    let selected = try #require(plan.items.first)
    let guardService = ActionGuard(homeDirectory: home)
    try guardService.validate(selected)
    #expect(ProtectiveWarning.evaluate(selected, homeDirectory: home) == .personalLibrary)
    #expect(ProtectiveWarning.personalLibrary.examplePaths(selected, homeDirectory: home) == [path])
    try guardService.validate(selected)
    #expect(plan.items == [selected])
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/project.bin")) == Data("owned library project".utf8))
  }

  @Test("Photos libraries retain their NeverRule refusal instead of becoming a warning")
  func photosLibraryStaysProtected() throws {
    let home = "/private/tmp/LightenQA-" + UUID().uuidString
    let path = home + "/Pictures/Personal.photoslibrary"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }
    let identity = try DescriptorFileSystem.identity(at: path)
    do {
      _ = try PlanService(homeDirectory: home).makeSpacePlan(
        selections: [.init(path: path, device: identity.device, inode: identity.inode)],
        scanRootPath: home, runID: UUID())
      Issue.record("Photos library was selectable")
    } catch {
      #expect(error.rejections.first?.reason == .protectedItem)
      #expect(error.rejections.first?.ruleID == "photos-library")
    }
  }
}
