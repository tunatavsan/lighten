import CryptoKit
import Darwin
import Foundation
import Testing

@testable import LightenKit

private struct SafetyClearActivity: ProcessActivitySource {
  func activity(for rowID: String) async -> ProcessActivity { ProcessActivity(state: .clearObservedCurrentUID) }
}

private struct SafetyClosedApplications: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
}

private struct SafetyLocalTrash: TrashMoving {
  let directory: String
  func moveToTrash(path: String) async throws -> String {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let target = directory + "/" + (path as NSString).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: target)
    return target
  }
}

@Suite("Safety document")
struct SafetyDocumentTests {
  @Test(
    "Catalog Trash exceptions never authorize permanent deletion",
    arguments: ["localization", "application", "symbols"])
  func wholeCandidateTrashKeepsPermanentStrict(_ content: String) async throws {
    let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(resolved) }
    let home = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: home) }
    let catalog = try CleanCatalog(homeDirectory: home)
    let rowID = content == "symbols" ? "xcode-derived-data" : "pip-http-v2"
    let row = try #require(catalog.row(id: rowID))
    let root = catalog.root(for: row)
    let candidate = root + "/LightenQA-" + UUID().uuidString
    let descendant =
      switch content {
      case "localization": "Resources/en.lproj/Localizable.strings"
      case "application": "LightenQA-product.app/Contents/MacOS/tool"
      default: "LightenQA-symbols.dSYM/Contents/Resources/DWARF/tool"
      }
    let protectedPath = candidate + "/" + descendant
    try FileManager.default.createDirectory(
      atPath: (protectedPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data("fixture contents".utf8).write(to: URL(fileURLWithPath: protectedPath))
    if content == "application" {
      let metadata = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "qa.lighten." + UUID().uuidString], format: .xml, options: 0)
      try metadata.write(to: URL(fileURLWithPath: candidate + "/LightenQA-product.app/Contents/Info.plist"))
    }
    let snapshot = try await ScanService(homeDirectory: home).scan(rootPath: root)
    let selectedID = try #require(snapshot.entries.first { $0.path == candidate }).id
    let trash = try catalog.plan(snapshot: snapshot, selectedIDs: [selectedID], rowID: rowID, kind: .trash)
    #expect(trash.items.count == 1)
    let observedRoot =
      content == "application"
      ? candidate + "/LightenQA-product.app"
      : content == "symbols" ? candidate + "/LightenQA-symbols.dSYM" : protectedPath
    #expect(trash.items[0].inventory.contains { $0.path == observedRoot })
    if content != "localization" {
      #expect(!trash.items[0].inventory.contains { $0.path.hasPrefix(observedRoot + "/") })
    }
    let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: protectedPath)))
    #expect(trash.items[0].policy == (content == "symbols" ? .catalogBuildOutput : .catalogTrash))
    #expect(throws: PlanFailure.unsafeSelection) {
      try PlanService(homeDirectory: home).makePlan(
        snapshot: snapshot, selectedIDs: [selectedID], kind: .catalogDelete)
    }
    if content == "symbols" {
      #expect(throws: CatalogFailure.self) {
        try catalog.plan(snapshot: snapshot, selectedIDs: [selectedID], rowID: rowID, kind: .catalogDelete)
      }
    } else {
      #expect(throws: PlanFailure.unsafeSelection) {
        try catalog.plan(snapshot: snapshot, selectedIDs: [selectedID], rowID: rowID, kind: .catalogDelete)
      }
    }
    let journal = JSONLActionJournal(path: home + "/Journal/actions.jsonl")
    let result = try await ActionExecutor(
      journal: journal, trash: SafetyLocalTrash(directory: home + "/Trash"),
      guardService: ActionGuard(homeDirectory: home), activity: SafetyClearActivity(), catalog: catalog,
      runningApplications: SafetyClosedApplications(), applicationActivity: FixtureClearApplicationActivity()
    ).execute(trash)
    #expect(result.items.first?.outcome == .applied)
    #expect(try await ActionHistory(journal: journal, homeDirectory: home).undo(planID: trash.id).restoredCount == 1)
    #expect(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: protectedPath))) == hash)
  }

  @Test("Checked-in safety document matches NeverRule.all")
  func checkedInDocumentMatchesRules() throws {
    let generated = SafetyDocument.markdown()

    let documentURL =
      repositoryRoot
      .appending(path: "docs")
      .appending(path: "SAFETY.md")

    let environment = ProcessInfo.processInfo.environment
    if environment["LIGHTEN_UPDATE_SAFETY_DOC"] == "1" {
      #expect(environment["CI"] == nil, "Safety document updates are forbidden in CI")
      guard environment["CI"] == nil else { return }
      try generated.write(to: documentURL, atomically: true, encoding: .utf8)
    }

    let checkedIn = try String(contentsOf: documentURL, encoding: .utf8)
    #expect(checkedIn == generated)
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
