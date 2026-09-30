import Foundation
import LightenKit
import Testing

@testable import Lighten

@Suite("Space presentation")
struct SpaceUITests {
  @MainActor @Test("SI byte buckets are fixed at every boundary")
  func buckets() {
    #expect(LightenStyle.SizeBucket.forBytes(99_999_999) == .under100MB)
    #expect(LightenStyle.SizeBucket.forBytes(100_000_000) == .under1GB)
    #expect(LightenStyle.SizeBucket.forBytes(1_000_000_000) == .under5GB)
    #expect(LightenStyle.SizeBucket.forBytes(5_000_000_000) == .under20GB)
    #expect(LightenStyle.SizeBucket.forBytes(20_000_000_000) == .under60GB)
    #expect(LightenStyle.SizeBucket.forBytes(60_000_000_000) == .atLeast60GB)
    #expect(LightenStyle.SizeBucket.forBytes(142_000_000_000) != LightenStyle.SizeBucket.forBytes(5_000_000_000))
    #expect(
      LightenStyle.SizeBucket.allCases.map(\.lightHex) == [0xE7F0F8, 0xC4DAF2, 0xB0B5EE, 0xB97FC6, 0xC34E54, 0x9A4312])
    #expect(
      LightenStyle.SizeBucket.allCases.map(\.darkHex) == [0x2F3F4F, 0x375479, 0x635EA5, 0xAC63B1, 0xF17871, 0xFEB354])
  }

  @MainActor @Test("Both warning languages avoid claiming a sole copy")
  func copy() {
    #expect(SpaceText.warning(.copyUnknown, turkish: false).contains("another copy is not known"))
    #expect(SpaceText.warning(.copyUnknown, turkish: true).contains("başka bir kopyası bilinmiyor"))
    #expect(!SpaceText.warning(.copyUnknown, turkish: false).contains("only copy"))
    #expect(SpaceText.warning(.secrets, turkish: false) != SpaceText.warning(.secrets, turkish: true))
  }

  @MainActor
  @Test(
    "Confirmation preserves each related-data refusal's concrete reason and path",
    arguments: [
      ("incompleteInventory", "inventory is incomplete", "envanteri eksik"),
      ("invalidReceipt", "prepared action is no longer valid", "Hazırlanan işlem artık geçerli değil"),
      ("ownerPresent", "may own this data", "verinin sahibi olabilir"),
      ("changedItem", "changed after it was checked", "denetlendikten sonra değişti"),
      (
        "runningOrUnknown", "app is running or its state could not be checked",
        "Uygulama çalışıyor veya durumu denetlenemedi"
      ),
      ("ambiguousOwner", "may own this data", "verinin sahibi olabilir"),
      ("unsupportedInstalledData", "not eligible for this action", "bu işlem için uygun değil"),
    ])
  func confirmationRelatedRefusal(code: String, english: String, turkish: String) throws {
    let path = "/private/tmp/LightenQA-" + UUID().uuidString + "/Library/Caches/qa.lighten." + code
    let presentation = ActionPresentation(
      plan: ActionPlan(snapshotRunID: UUID(), kind: .trash, items: []), items: [],
      rejectedItems: [PlanRejection(.unavailable, path: path, ruleID: code)])
    let refusal = try #require(presentation.rejectedItems.first)
    let englishCopy = SpaceText.rejection(refusal, turkish: false)
    let turkishCopy = SpaceText.rejection(refusal, turkish: true)
    #expect(englishCopy.contains(english) && englishCopy.hasSuffix(path))
    #expect(turkishCopy.contains(turkish) && turkishCopy.hasSuffix(path))
    #expect(!englishCopy.contains("no longer available"))
    #expect(!turkishCopy.contains("artık mevcut değil"))
  }

  @MainActor @Test("Wrapper confirmation uses its Finder reason and unknown rule codes retain the generic refusal")
  func confirmationWrapperRefusal() {
    let path = "/private/tmp/LightenQA-" + UUID().uuidString + "/LightenQA-" + UUID().uuidString + ".app"
    let wrapper = PlanRejection(.unavailable, path: path, ruleID: "ios-wrapper")
    #expect(
      SpaceText.rejection(wrapper, turkish: false)
        == "This iPhone or iPad application cannot be removed here. Use Show in Finder. — " + path)
    #expect(
      SpaceText.rejection(wrapper, turkish: true)
        == "Bu iPhone veya iPad uygulaması buradan kaldırılamaz. Finder’da Göster'i kullanın. — " + path)
    let unknown = PlanRejection(.unavailable, path: path, ruleID: "future-refusal")
    #expect(SpaceText.rejection(unknown, turkish: false).contains("no longer available"))
    #expect(SpaceText.rejection(unknown, turkish: true).contains("artık mevcut değil"))
    let cache = PlanRejection(.protectedItem, path: path, ruleID: "apple-system-cache")
    #expect(SpaceText.rejection(cache, turkish: false) == "Apple system cache. Inspect it in Finder. — " + path)
  }
}

private struct UIObservedSpaceActivity: SpaceActivitySource {
  func activity(rootPath: String) async -> ProcessActivity { ProcessActivity(state: .clearObservedCurrentUID) }
}

private struct UIClosedApplications: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
}

private struct UIFixtureTrash: TrashMoving {
  let directory: String
  func moveToTrash(path: String) async throws -> String {
    if URL(fileURLWithPath: path).lastPathComponent == "fail.bin" { throw CocoaError(.fileWriteUnknown) }
    let destination = directory + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: destination)
    return destination
  }
}

extension SpaceUITests {
  @MainActor @Test("Partial basket keeps rejected and failed selections after applying the remaining plan")
  func partialBasket() async throws {
    let fixture = "/private/tmp/LightenQA-" + UUID().uuidString
    let root = fixture + "/home"
    let trash = fixture + "/Trash"
    for path in [root, trash] {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(atPath: fixture) }
    for name in ["good.jpg", "missing.bin", "fail.bin"] {
      try Data(repeating: 1, count: 20).write(to: URL(fileURLWithPath: root + "/" + name))
    }
    let run = try ScanEngine().start(root: root)
    await run.waitUntilFinished()
    let journal = JSONLActionJournal(path: fixture + "/journal/actions.jsonl")
    let store = ActionStore(
      journal: journal, trash: UIFixtureTrash(directory: trash),
      planService: PlanService(
        homeDirectory: root, runningApplications: UIClosedApplications(), spaceActivity: UIObservedSpaceActivity()))
    for item in run.tree.children(of: run.tree.rootID, metric: .logical) { store.add(item) }
    try FileManager.default.removeItem(atPath: root + "/missing.bin")
    await store.prepare(scanRoot: root, runID: run.runID)
    let presentation = try #require(store.pending)
    #expect(Set(presentation.plan.items.map(\.sourcePath)) == Set([root + "/good.jpg", root + "/fail.bin"]))
    #expect(presentation.rejectedItems.count == 1)
    #expect(presentation.items.first { $0.path == root + "/good.jpg" }?.warning == .copyUnknown)
    let confirmed = try #require(store.takeConfirmedPlan(presentation))
    await store.executeConfirmed(confirmed)
    #expect(Set(store.basket.keys) == Set([root + "/missing.bin", root + "/fail.bin"]))
    #expect(store.result?.items.filter { $0.outcome == .applied }.count == 1)
    #expect(store.result?.items.filter { $0.outcome == .failed }.count == 1)
    try FileManager.default.removeItem(atPath: trash + "/good.jpg")
    await store.reloadHistory()
    let missingTrash = try #require(
      store.history?.items.first { $0.detail == String(describing: UndoFailure.trashItemMissing) })
    #expect(!missingTrash.canUndo)
    #expect(missingTrash.state == .uncertain)
    #expect(SpaceText.trashMissing(turkish: false).contains("cannot restore"))
    #expect(SpaceText.trashMissing(turkish: true).contains("geri yükleyemez"))
  }
}
