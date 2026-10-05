import Foundation
import LightenKit
import Testing

@testable import Lighten

@Test("New removal settings start with Trash and automatic eligible app-data selection")
@MainActor func removalDefaultsAreConservative() throws {
  let name = "LightenQA-preferences-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let fallbackName = "LightenQA-preferences-fallback-" + UUID().uuidString
  let fallback = try #require(UserDefaults(suiteName: fallbackName))
  fallback.set(false, forKey: RemovalPreferences.relatedKey)
  fallback.set("permanent", forKey: RemovalPreferences.deletionKey)
  defaults.addSuite(named: fallbackName)
  defer {
    defaults.removeSuite(named: fallbackName)
    fallback.removePersistentDomain(forName: fallbackName)
  }
  #expect(!defaults.bool(forKey: RemovalPreferences.relatedKey))
  let preferences = RemovalPreferences(defaults: defaults, persistentDomainName: name)
  #expect(preferences.deletionDefault == .trash)
  #expect(preferences.automaticallySelectRelatedData)
}

@Test("Saved app-data selection preferences survive the new default", arguments: [false, true])
@MainActor func removalRelatedPreferencePreservesSavedValue(saved: Bool) throws {
  let name = "LightenQA-preferences-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set(saved, forKey: RemovalPreferences.relatedKey)
  #expect(RemovalPreferences(defaults: defaults, persistentDomainName: name).automaticallySelectRelatedData == saved)
  #expect(RemovalPreferences(defaults: defaults).automaticallySelectRelatedData == saved)
}

@Test("Removal settings persist independently and survive a new store")
@MainActor func removalPreferencesPersist() throws {
  let name = "LightenQA-preferences-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let original = RemovalPreferences(defaults: defaults, persistentDomainName: name)
  original.deletionDefault = .permanent
  original.automaticallySelectRelatedData = true
  let restored = RemovalPreferences(defaults: defaults, persistentDomainName: name)
  #expect(restored.deletionDefault == .permanent)
  #expect(restored.automaticallySelectRelatedData)
  restored.deletionDefault = .trash
  #expect(RemovalPreferences(defaults: defaults, persistentDomainName: name).automaticallySelectRelatedData)
}

@Test("An unknown stored removal method falls back to Trash")
@MainActor func unknownRemovalPreferenceFallsBack() throws {
  let name = "LightenQA-preferences-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set("future-method", forKey: RemovalPreferences.deletionKey)
  #expect(RemovalPreferences(defaults: defaults, persistentDomainName: name).deletionDefault == .trash)
}

@Test("A selection warning uses an already observed personal-data example")
func selectionWarningUsesObservedNames() {
  #expect(SelectionWarning.example(in: ["/chosen/cache", "/chosen/.ssh", "/chosen/Mail"]) == "/chosen/.ssh")
  #expect(SelectionWarning.example(in: ["/chosen/Photos.photoslibrary"]) == "/chosen/Photos.photoslibrary")
  #expect(SelectionWarning.example(in: ["/chosen/cache", "/chosen/data.bin"]) == nil)
}

@Test("Space carries the observed warning example into root confirmation without opening it")
@MainActor func spaceWarningSurvivesRootReview() async throws {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root + "/chosen/.ssh", withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/chosen"
  let identity = try DescriptorFileSystem.identity(at: path)
  let actions = ActionStore(
    journal: JSONLActionJournal(path: root + "/journal.jsonl"), planService: PlanService(homeDirectory: root),
    applicationActivity: PreferencesClearActivity())
  actions.basket[path] = BasketEntry(
    path: path, label: "Chosen", device: identity.device, inode: identity.inode,
    logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil), allocated: nil, identity: identity,
    warningPaths: [path + "/.ssh"])
  await actions.prepare(scanRoot: root, runID: nil)
  let review = try #require(actions.pending)
  #expect(review.items.first?.warningPaths == [path + "/.ssh"])
  #expect(review.plan.items.first?.inventory.count == 1)
  #expect(FileManager.default.fileExists(atPath: path + "/.ssh"))
}

private struct PreferencesClearActivity: LightenKit.ApplicationActivitySource {
  func activity(applicationPath: String) async -> LightenKit.ApplicationActivity {
    LightenKit.ApplicationActivity(state: .clearObservedProcesses)
  }
}

@Test("Permanent removal needs a second confirmation and preserves original item identities")
@MainActor func permanentRemovalSecondConfirmation() async throws {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/owned"
  try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
  let plan = try #require(
    await LightenKit.PlanService(homeDirectory: root).makeAvailableUserSelectionPlan(
      selections: [LightenKit.UserSelection(path: path)]).plan)
  let actions = ActionStore(
    journal: LightenKit.JSONLActionJournal(path: root + "/journal.jsonl"),
    planService: LightenKit.PlanService(homeDirectory: root), applicationActivity: PreferencesClearActivity())
  actions.present(
    plan: plan,
    items: plan.items.map {
      ActionItemSummary(
        id: $0.id, label: "Owned fixture", path: $0.sourcePath,
        reason: "Explicit selection", logicalBytes: 7, allocatedBytes: nil)
    })
  let trash = try #require(actions.pending)
  await actions.requestPermanent(trash)
  let permanent = try #require(actions.pending)
  #expect(permanent.plan.kind == .catalogDelete)
  #expect(permanent.id == trash.id)
  #expect(permanent.plan.items.map(\.id) == trash.plan.items.map(\.id))
  #expect(actions.takeConfirmedPlan(permanent) == nil)
  #expect(FileManager.default.fileExists(atPath: path))
  let claimed = try #require(actions.takeConfirmedPlan(permanent, permanentConfirmed: true))
  await actions.executeConfirmed(claimed)
  #expect(!FileManager.default.fileExists(atPath: path))
  #expect(actions.result?.items.map(\.outcome) == [.applied])
}

@Test("The central confirmation adapter replaces descendant checks with selected root checks")
@MainActor func confirmationRebindsSelectedRoot() async throws {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root + "/chosen/.ssh", withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: root) }
  try Data("fixture".utf8).write(to: URL(fileURLWithPath: root + "/chosen/.ssh/owned"))
  let path = root + "/chosen"
  let identity = try LightenKit.DescriptorFileSystem.identity(at: path)
  let entry = LightenKit.ScanEntry(parentID: nil, path: path, identity: identity, issues: [], readable: true)
  let original = LightenKit.ActionPlan(
    snapshotRunID: UUID(), kind: .trash,
    items: [
      LightenKit.PlanItem(id: entry.id, sourcePath: path, inventory: [entry], ancestors: [])
    ])
  let outcome = await LightenKit.PlanService(homeDirectory: root).finalizeUserSelection(plan: original)
  let plan = try #require(outcome.plan)
  #expect(plan.id == original.id && plan.items.first?.id == entry.id)
  #expect(plan.items.first?.inventory.count == 1 && plan.items.first?.userSelection == true)
  #expect(outcome.rejections.isEmpty)
}

@Test(
  "Base locations stay out of the removal confirmation in either method", arguments: [ActionKind.trash, .catalogDelete])
@MainActor func baseRootsRemainBlocked(kind: ActionKind) async throws {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let result = await PlanService(homeDirectory: root).makeAvailableUserSelectionPlan(
    selections: [UserSelection(path: root)], kind: kind)
  #expect(result.plan == nil)
  #expect(result.rejections.map(\.path) == [root])
  #expect(FileManager.default.fileExists(atPath: root))
}

@Test("A rejected root at final confirmation is named and never reported as silently successful")
@MainActor func finalRootRejectionRemainsVisible() async throws {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/owned"
  try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
  let plan = try #require(
    await PlanService(homeDirectory: root).makeAvailableUserSelectionPlan(
      selections: [UserSelection(path: path)]).plan)
  let actions = ActionStore(
    journal: JSONLActionJournal(path: root + "/journal.jsonl"),
    planService: PlanService(homeDirectory: root), applicationActivity: PreferencesClearActivity())
  actions.present(
    plan: plan,
    items: plan.items.map {
      ActionItemSummary(
        id: $0.id, label: "Owned fixture", path: $0.sourcePath,
        reason: "Explicit selection", logicalBytes: 7, allocatedBytes: nil)
    })
  let presentation = try #require(actions.pending)
  let claimed = try #require(actions.takeConfirmedPlan(presentation))
  try FileManager.default.removeItem(atPath: path)
  await actions.executeConfirmed(claimed)
  #expect(actions.resultRejections.map(\.path) == [path])
  #expect(actions.completedSummary?.contains("No items") == true)
  #expect(!FileManager.default.fileExists(atPath: root + "/journal.jsonl"))
}
