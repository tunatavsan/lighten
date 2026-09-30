import Foundation
import Testing

@testable import LightenKit

@Suite("Metadata removal reminders")
struct ProtectiveWarningTests {
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
}
