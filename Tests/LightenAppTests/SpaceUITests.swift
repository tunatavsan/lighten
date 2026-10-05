import Darwin
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
      (
        "incompleteInventory", "could not check every possible app owner of this data. Inspect it in Finder.",
        "bu verinin olası tüm uygulama sahiplerini denetleyemedi. Finder’da inceleyin."
      ),
      (
        "invalidReceipt", "could not confirm which app created this data. Inspect it in Finder.",
        "bu veriyi hangi uygulamanın oluşturduğunu doğrulayamadı. Finder’da inceleyin."
      ),
      (
        "ownerPresent", "may still use this data. Review the app in Apps.",
        "bu veriyi hâlâ kullanıyor olabilir. Uygulamayı Uygulamalar’da inceleyin."
      ),
      (
        "changedItem", "changed after it was checked. Scan again before cleaning.",
        "denetlendikten sonra değişti. Temizlemeden önce yeniden tarayın."
      ),
      (
        "runningOrUnknown", "could not confirm that the app is closed. Check the app in Activity Monitor.",
        "uygulamanın kapalı olduğunu doğrulayamadı. Uygulamayı Etkinlik Monitörü’nde kontrol edin."
      ),
      (
        "ambiguousOwner", "may still use this data. Review the app in Apps.",
        "bu veriyi hâlâ kullanıyor olabilir. Uygulamayı Uygulamalar’da inceleyin."
      ),
      (
        "unsupportedInstalledData", "not eligible for this action. Review it in Applications.",
        "bu işlem için uygun değil. Uygulamalar’da inceleyin."
      ),
    ])
  func confirmationRelatedRefusal(code: String, english: String, turkish: String) throws {
    let path = "/private/tmp/LightenQA-" + UUID().uuidString + "/Library/Caches/qa.lighten." + code
    let presentation = ActionPresentation(
      plan: ActionPlan(snapshotRunID: UUID(), kind: .trash, items: []), items: [],
      rejectedItems: [PlanRejection(.unavailable, path: path, ruleID: code)])
    let refusal = try #require(presentation.rejectedItems.first)
    #expect(refusal.ruleID == code)
    let englishCopy = SpaceText.rejection(refusal, turkish: false)
    let turkishCopy = SpaceText.rejection(refusal, turkish: true)
    #expect(englishCopy.contains(english) && englishCopy.hasSuffix(path))
    #expect(turkishCopy.contains(turkish) && turkishCopy.hasSuffix(path))
    #expect(!englishCopy.contains("no longer available"))
    #expect(!turkishCopy.contains("artık mevcut değil"))
  }

  @MainActor @Test("Wrapper confirmation has its Finder reason and unknown codes stay internal")
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
    let english = SpaceText.rejection(unknown, turkish: false)
    let turkish = SpaceText.rejection(unknown, turkish: true)
    #expect(english.contains("could not determine why this action failed. Inspect the item in Finder."))
    #expect(turkish.contains("bu işlemin neden başarısız olduğunu belirleyemedi. Öğeyi Finder’da inceleyin."))
    #expect(!english.contains("future-refusal") && english.hasSuffix(path))
    #expect(!turkish.contains("future-refusal") && turkish.hasSuffix(path))
    #expect(!english.contains("no longer available") && !turkish.contains("artık mevcut değil"))
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

private struct UIFixtureApplicationActivity: ApplicationActivitySource {
  func activity(applicationPath: String) async -> ApplicationActivity {
    ApplicationActivity(state: .clearObservedProcesses)
  }
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
        homeDirectory: root, runningApplications: UIClosedApplications(), spaceActivity: UIObservedSpaceActivity()),
      applicationActivity: UIFixtureApplicationActivity())
    for item in run.tree.children(of: run.tree.rootID, metric: .logical) { store.add(item) }
    try FileManager.default.removeItem(atPath: root + "/missing.bin")
    await store.prepare(scanRoot: root, runID: run.runID)
    let presentation = try #require(store.pending)
    #expect(Set(presentation.plan.items.map(\.sourcePath)) == Set([root + "/good.jpg", root + "/fail.bin"]))
    #expect(presentation.rejectedItems.count == 1)
    #expect(store.result == nil && store.resultRejections.isEmpty)
    #expect(presentation.items.first { $0.path == root + "/good.jpg" }?.warning == .copyUnknown)
    let confirmed = try #require(store.takeConfirmedPlan(presentation))
    await store.executeConfirmed(confirmed)
    #expect(Set(store.basket.keys) == Set([root + "/missing.bin", root + "/fail.bin"]))
    #expect(store.result?.items.filter { $0.outcome == .applied }.count == 1)
    #expect(store.result?.items.filter { $0.outcome == .failed }.count == 1)
    #expect(store.resultRejections.map(\.path) == [root + "/missing.bin"])
    try FileManager.default.removeItem(atPath: trash + "/good.jpg")
    await store.reloadHistory()
    let missingTrash = try #require(
      store.history?.items.first { $0.detail == String(describing: UndoFailure.trashItemMissing) })
    #expect(!missingTrash.canUndo)
    #expect(missingTrash.state == .uncertain)
    #expect(
      SpaceText.trashMissing(turkish: false)
        == "This item is no longer at its recorded Trash location. Check Trash in Finder.")
    #expect(
      SpaceText.trashMissing(turkish: true) == "Bu öğe artık kayıtlı Çöp konumunda değil. Finder’da Çöp’ü kontrol edin."
    )
  }
}

extension SpaceUITests {
  @MainActor
  @Test("An all-rejected Space review publishes kept paths only when the review is current", arguments: [false, true])
  func allRejectedBasket(cancelled: Bool) async throws {
    let fixture = "/private/tmp/LightenQA-" + UUID().uuidString
    let root = fixture + "/home"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: fixture) }
    let journalPath = fixture + "/journal/actions.jsonl"
    let actions = ActionStore(
      journal: JSONLActionJournal(path: journalPath), planService: PlanService(homeDirectory: root))
    let paths = [root + "/first.bin", root + "/second.bin"]
    for path in paths {
      try Data([1]).write(to: URL(fileURLWithPath: path))
      let identity = try DescriptorFileSystem.identity(at: path)
      actions.basket[path] = BasketEntry(
        path: path, label: URL(fileURLWithPath: path).lastPathComponent,
        device: identity.device, inode: identity.inode,
        logical: ByteAggregate(knownLowerBound: 1, completeTotal: 1), identity: identity)
      try FileManager.default.removeItem(atPath: path)
    }
    let preparation = Task { await actions.prepare(scanRoot: root, runID: nil) }
    if cancelled { preparation.cancel() }
    await preparation.value
    #expect(actions.pending == nil && actions.result == nil && actions.resultKind == nil)
    #expect(actions.basket.keys.sorted() == paths)
    #expect(actions.resultFailures.isEmpty && actions.resultSummaries.isEmpty)
    #expect(actions.message == nil && !actions.busy && !actions.canUndoLatest)
    #expect(!FileManager.default.fileExists(atPath: journalPath))
    if cancelled {
      #expect(actions.resultRejections.isEmpty && actions.completedSummary == nil)
    } else {
      #expect(actions.resultRejections.map(\.path) == paths)
      #expect(actions.completedSummary == String(localized: "No items were removed."))
      for path in paths { #expect(actions.failure(at: path)?.hasSuffix(path) == true) }
      actions.remove(paths[0])
      #expect(actions.resultRejections.isEmpty && actions.completedSummary == nil)
    }
  }

  @MainActor
  @Test(
    "An administrator preflight refusal replaces stale success without changing History or Undo",
    .enabled(if: geteuid() != 0))
  func administratorRefusalPreservesHistory() async throws {
    let fixture = "/private/tmp/LightenQA-" + UUID().uuidString
    let root = fixture + "/home"
    let trash = fixture + "/Trash"
    for path in [root, trash] {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(atPath: fixture) }
    let journalPath = fixture + "/journal/actions.jsonl"
    let preferencesName = "qa.lighten." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: preferencesName))
    defer { defaults.removePersistentDomain(forName: preferencesName) }
    let preferences = RemovalPreferences(defaults: defaults, persistentDomainName: preferencesName)
    preferences.deletionDefault = .trash
    let actions = ActionStore(
      journal: JSONLActionJournal(path: journalPath), trash: UIFixtureTrash(directory: trash),
      planService: PlanService(homeDirectory: root), preferences: preferences,
      applicationActivity: UIFixtureApplicationActivity())
    let removable = root + "/good.bin"
    try Data([1]).write(to: URL(fileURLWithPath: removable))
    let identity = try DescriptorFileSystem.identity(at: removable)
    actions.basket[removable] = BasketEntry(
      path: removable, label: "Good", device: identity.device, inode: identity.inode,
      logical: ByteAggregate(knownLowerBound: 1, completeTotal: 1), identity: identity)
    await actions.prepare(scanRoot: root, runID: nil)
    let selected = try #require(actions.pending)
    let plan = try #require(actions.takeConfirmedPlan(selected))
    await actions.executeConfirmed(plan)
    try #require(actions.result?.items.first?.outcome == .applied)
    await actions.setHistoryGroupExpanded(plan.id, expanded: true)
    let historyPlan = try #require(actions.history?.plans.first)
    try #require(historyPlan.detailsLoaded && historyPlan.canUndo && actions.canUndoLatest)
    let journalBefore = try Data(contentsOf: URL(fileURLWithPath: journalPath))

    // Read-only system metadata supplies a real foreign-owned root; it is never executed.
    let protectedPath = "/usr/bin/true"
    var details = stat()
    try #require(lstat(protectedPath, &details) == 0 && details.st_uid != geteuid())
    let protectedIdentity = try DescriptorFileSystem.identity(at: protectedPath)
    actions.basket[protectedPath] = BasketEntry(
      path: protectedPath, label: "true", device: protectedIdentity.device, inode: protectedIdentity.inode,
      logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil), identity: protectedIdentity)
    await actions.prepare(scanRoot: root, runID: nil)
    #expect(actions.pending == nil && actions.result == nil && actions.resultKind == nil)
    #expect(actions.resultRejections == [PlanRejection(.needsAdministrator, path: protectedPath)])
    #expect(actions.message == nil && actions.completedSummary == String(localized: "No items were removed."))
    #expect(!actions.canUndoLatest && actions.latestTrashPaths.isEmpty)
    #expect(actions.history?.plans.map(\.id) == [historyPlan.id])
    #expect(actions.history?.plans.first?.detailsLoaded == true)
    #expect(actions.history?.plans.first?.canUndo == true)
    #expect(try Data(contentsOf: URL(fileURLWithPath: journalPath)) == journalBefore)
    #expect(try DescriptorFileSystem.identity(at: protectedPath) == protectedIdentity)
    actions.clearBasket()
    #expect(actions.resultRejections.isEmpty && actions.completedSummary == nil)
    await actions.undo(historyPlan)
    #expect(FileManager.default.fileExists(atPath: removable))
    #expect(actions.undoResults[historyPlan.id]?.restoredCount == 1)
  }
}

extension SpaceUITests {
  @MainActor @Test("Confirmation replaces legacy opaque zero totals with observation or unknown")
  func opaqueConfirmationObservation() throws {
    let path = "/private/tmp/LightenQA-" + UUID().uuidString + ".app"
    let entry = ScanEntry(
      parentID: nil, path: path,
      identity: FileIdentity(
        device: 1, inode: 2, changeSeconds: 0, changeNanoseconds: 0,
        logicalBytes: 4096, allocatedBytes: 4096, linkCount: 1, flags: 0, kind: .directory),
      issues: [], readable: true)
    let store = ActionStore(journal: JSONLActionJournal(path: path + "/journal/actions.jsonl"))
    for size in [
      ObservedPlanSize.unknown,
      ObservedPlanSize(logical: ByteAggregate(knownLowerBound: 12_000_000_000, completeTotal: nil), allocated: nil),
      ObservedPlanSize(
        logical: ByteAggregate(knownLowerBound: 12_000_000_000, completeTotal: 12_000_000_000), allocated: nil),
    ] {
      let item = PlanItem(
        id: entry.id, sourcePath: path, inventory: [entry], ancestors: [],
        policy: .wholeBundle, observedSize: size == .unknown ? nil : size)
      store.present(
        plan: ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [item]),
        items: [
          ActionItemSummary(
            id: entry.id, label: "Fixture app", path: path, reason: "Fixture selection",
            logicalBytes: 0, allocatedBytes: 0)
        ])
      let summary = try #require(store.pending?.items.first)
      #expect(summary.observedSize == size)
      #expect(summary.logicalBytes == (size.logical?.completeTotal ?? size.logical?.knownLowerBound))
      if size == .unknown {
        #expect(PlanItemSize.text(summary.observedSize.logical) == String(localized: "Size unknown"))
      } else if size.logical?.completeTotal == nil {
        #expect(PlanItemSize.text(summary.observedSize.logical).hasPrefix(String(localized: "At least")))
      } else {
        #expect(PlanItemSize.text(summary.observedSize.logical) == format(12_000_000_000))
      }
    }
  }

  @MainActor @Test("Display totals preserve exact zero and never wrap on overflow")
  func confirmationSizeTotals() {
    let zero = ObservedPlanSize(logical: ByteAggregate(knownLowerBound: 0, completeTotal: 0), allocated: nil)
    #expect(PlanItemSize.text(zero.logical) == format(0))
    let huge = ObservedPlanSize(
      logical: ByteAggregate(knownLowerBound: Int64.max, completeTotal: Int64.max), allocated: nil)
    let one = ObservedPlanSize(logical: ByteAggregate(knownLowerBound: 1, completeTotal: 1), allocated: nil)
    #expect(PlanItemSize.text(ObservedPlanSize.total([huge, one]).logical) == String(localized: "Size unknown"))
    #expect(ObservedPlanSize.total([one, .unknown]).logical?.completeTotal == nil)
  }
}

extension SpaceUITests {
  @MainActor @Test("Review groups only explicit app membership and preserves item order")
  func removalReviewUsesExplicitAppGroups() throws {
    let app = ActionApplicationGroup(path: "/fixture/One.app", name: "One")
    let other = ActionApplicationGroup(path: "/fixture/Two.app", name: "Two")
    func summary(_ path: String, group: ActionApplicationGroup?, size: ObservedPlanSize = .unknown) -> ActionItemSummary
    {
      ActionItemSummary(
        id: UUID(), label: URL(fileURLWithPath: path).lastPathComponent, path: path,
        reason: "Selected", logicalBytes: nil, allocatedBytes: nil, observedSize: size, applicationGroup: group)
    }
    let package = summary(app.path, group: app)
    let ungrouped = summary(app.path + "/unrelated-name.bin", group: nil)
    let data = summary("/fixture/Library/One.plist", group: app)
    let secondPackage = summary(other.path, group: other)
    let secondUngrouped = summary("/fixture/One copy.plist", group: nil)
    let items = [package, ungrouped, data, secondPackage, secondUngrouped]
    let groups = ConfirmationItemGroup.make(items)
    #expect(groups.count == 3)
    #expect(groups[0].application == app)
    #expect(groups[0].items.map(\.id) == [package.id, data.id])
    #expect(groups[1].application == nil)
    #expect(groups[1].items.map(\.id) == [ungrouped.id, secondUngrouped.id])
    #expect(groups[2].application == other)
    #expect(Set(groups.flatMap { $0.items.map(\.id) }) == Set(items.map(\.id)))
    #expect(ConfirmationItemGroup.make([]).isEmpty)
  }

  @MainActor @Test("App review group totals keep unknown and lower-bound data honest")
  func removalGroupIncompleteSize() throws {
    let app = ActionApplicationGroup(path: "/fixture/One.app", name: "One")
    let exact = ObservedPlanSize(logical: ByteAggregate(knownLowerBound: 100, completeTotal: 100), allocated: nil)
    let partial = ObservedPlanSize(logical: ByteAggregate(knownLowerBound: 25, completeTotal: nil), allocated: nil)
    func summary(_ size: ObservedPlanSize) -> ActionItemSummary {
      ActionItemSummary(
        id: UUID(), label: "Data", path: "/fixture/data", reason: "Selected",
        logicalBytes: nil, allocatedBytes: nil, observedSize: size, applicationGroup: app)
    }
    let partialGroup = try #require(ConfirmationItemGroup.make([summary(exact), summary(partial)]).first)
    #expect(partialGroup.size.logical?.knownLowerBound == 125)
    #expect(partialGroup.size.logical?.completeTotal == nil)
    #expect(PlanItemSize.text(partialGroup.size.logical).hasPrefix(String(localized: "At least")))
    let unknownGroup = try #require(ConfirmationItemGroup.make([summary(exact), summary(.unknown)]).first)
    #expect(unknownGroup.size.logical?.knownLowerBound == 100)
    #expect(unknownGroup.size.logical?.completeTotal == nil)
  }
}
