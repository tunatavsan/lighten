import CryptoKit
import Darwin
import Foundation
import Testing

@testable import LightenKit

private func observedSizeItem(
  path: String = "/private/tmp/LightenQA-observed.app", kind: EntryKind = .directory,
  bytes: Int64 = 0, observation: ObservedPlanSize? = nil
) -> PlanItem {
  let entry = ScanEntry(
    parentID: nil, path: path,
    identity: FileIdentity(
      device: 1, inode: 2, changeSeconds: 3, changeNanoseconds: 0,
      logicalBytes: bytes, allocatedBytes: bytes, linkCount: 1, flags: 0, kind: kind),
    issues: [], readable: true)
  return PlanItem(
    id: entry.id, sourcePath: path, inventory: [entry], ancestors: [],
    policy: kind == .directory ? .wholeBundle : nil, observedSize: observation)
}

@Suite("Observed plan sizes")
struct ObservedPlanSizeTests {
  @Test("Old opaque plans decode with unknown contents size")
  func oldOpaquePlan() throws {
    let item = observedSizeItem(bytes: 4096)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
    object.removeValue(forKey: "observedSize")
    object.removeValue(forKey: "sizeMetadataVersion")
    let decoded = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.observedSize == nil)
    #expect(decoded.sizeMetadataVersion == nil)
    #expect(decoded.displaySize == .unknown)
    #expect(JournalItemSummary(decoded).displaySize == .unknown)
  }

  @Test("Legacy plan files load through their original journal reference without metadata migration")
  func legacyJournalReference() async throws {
    let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(resolved) }
    let root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
    let plansPath = root + "/plans"
    try FileManager.default.createDirectory(
      atPath: plansPath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let item = observedSizeItem()
    let original = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [item])
    var planObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    var items = try #require(planObject["items"] as? [[String: Any]])
    items[0].removeValue(forKey: "observedSize")
    items[0].removeValue(forKey: "sizeMetadataVersion")
    planObject["items"] = items
    let planData = try JSONSerialization.data(withJSONObject: planObject)
    let legacy = try JSONDecoder().decode(ActionPlan.self, from: planData)
    var summaryObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(JournalPlanSummary(original))) as? [String: Any])
    var summaries = try #require(summaryObject["items"] as? [[String: Any]])
    summaries[0].removeValue(forKey: "observedSize")
    summaries[0].removeValue(forKey: "containsOpaquePackages")
    summaryObject["items"] = summaries
    let summary = try JSONDecoder().decode(
      JournalPlanSummary.self, from: JSONSerialization.data(withJSONObject: summaryObject))
    #expect(JournalPlanSummary(legacy) == summary)
    let planPath = plansPath + "/" + original.id.uuidString + ".json"
    try planData.write(to: URL(fileURLWithPath: planPath))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: planPath)
    let reference = JournalPlanReference(
      sha256: SHA256.hash(data: planData).map { String(format: "%02x", $0) }.joined(), summary: summary)
    let journal = JSONLActionJournal(path: root + "/actions.jsonl")
    try await journal.withMutationLease {
      try await journal.append(JournalRecord(kind: .intent, planID: original.id).externalized(reference))
    }
    let loaded = try await journal.loadPlan(id: original.id)
    #expect(loaded == legacy)
    #expect(loaded.items.first?.displaySize == .unknown)
    #expect((try await journal.readSummary()).issues.isEmpty)
    #expect(try Data(contentsOf: URL(fileURLWithPath: planPath)) == planData)
  }

  @Test("Old directory summaries cannot claim a complete size without opacity metadata")
  func oldDirectorySummary() throws {
    let item = observedSizeItem(path: "/private/tmp/LightenQA-folder")
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(JournalItemSummary(item))) as? [String: Any])
    object.removeValue(forKey: "observedSize")
    object.removeValue(forKey: "containsOpaquePackages")
    let decoded = try JSONDecoder().decode(
      JournalItemSummary.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.logicalBytes == 0)
    #expect(decoded.displaySize == .unknown)
  }

  @Test("Inventoried empty regular files keep an exact zero, including old summaries")
  func exactZero() throws {
    let item = observedSizeItem(path: "/private/tmp/LightenQA-empty", kind: .regular)
    #expect(item.displaySize.logical == ByteAggregate(knownLowerBound: 0, completeTotal: 0))
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(JournalItemSummary(item))) as? [String: Any])
    object.removeValue(forKey: "observedSize")
    object.removeValue(forKey: "containsOpaquePackages")
    let summary = try JSONDecoder().decode(
      JournalItemSummary.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(summary.displaySize == item.displaySize)
  }

  @Test("Opaque package observations survive the plan and compact summary round trips")
  func positiveOpaqueRoundTrip() throws {
    let size = ObservedPlanSize(
      logical: ByteAggregate(knownLowerBound: 12_000_000_000, completeTotal: 12_000_000_000),
      allocated: ByteAggregate(knownLowerBound: 9_000_000_000, completeTotal: nil))
    let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(resolved) }
    let root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
    let path = root + "/Fixture.app"
    try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "qa.lighten.observed", "CFBundlePackageType": "APPL"],
      format: .xml, options: 0)
    try info.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
    try Data("package payload".utf8).write(to: URL(fileURLWithPath: path + "/Contents/data"))
    let entry = ScanEntry(
      parentID: nil, path: path, identity: try DescriptorFileSystem.identity(at: path), issues: [], readable: true)
    let item = PlanItem(
      id: entry.id, sourcePath: path, inventory: [entry], ancestors: [], policy: .wholeBundle, observedSize: size)
    let plan = ActionPlan(snapshotRunID: UUID(), kind: .trash, items: [item])
    let before = JournalPlanSummary(plan)
    let encodedPlan = try JSONEncoder().encode(plan)
    try FileManager.default.moveItem(atPath: path, toPath: root + "/Fixture-in-Trash.app")
    let decodedPlan = try JSONDecoder().decode(ActionPlan.self, from: encodedPlan)
    let decoded = try #require(decodedPlan.items.first)
    let summary = try #require(before.items.first)
    #expect(decoded.displaySize == size)
    #expect(summary.displaySize == size)
    #expect(summary.logicalBytes == 0)
    #expect(summary.rootIdentity == item.inventory.first?.identity)
    #expect(JournalPlanSummary(decodedPlan) == before)
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test("Unknown members produce lower bounds and overflowing metrics stay unknown")
  func mixedTotalsAndOverflow() {
    let exact = ObservedPlanSize(
      logical: ByteAggregate(knownLowerBound: 42, completeTotal: 42),
      allocated: ByteAggregate(knownLowerBound: 10, completeTotal: nil))
    #expect(
      ObservedPlanSize.total([exact, .unknown]).logical == ByteAggregate(knownLowerBound: 42, completeTotal: nil))
    #expect(ObservedPlanSize.total([.unknown]).logical == nil)
    let huge = ObservedPlanSize(
      logical: ByteAggregate(knownLowerBound: Int64.max, completeTotal: Int64.max), allocated: nil)
    #expect(ObservedPlanSize.total([huge, exact]).logical == nil)
    #expect(ObservedPlanSize.total([huge, exact]).allocated == ByteAggregate(knownLowerBound: 10, completeTotal: nil))
    #expect(
      ObservedPlanSize(logical: ByteAggregate(knownLowerBound: -1, completeTotal: nil), allocated: nil) == .unknown)
  }

  @Test("Invalid decoded observations are unknown while observed empty packages stay exact zero")
  func invalidDecodedObservation() throws {
    let data = Data(#"{"logical":{"knownLowerBound":10,"completeTotal":-1}}"#.utf8)
    let size = try JSONDecoder().decode(ObservedPlanSize.self, from: data)
    #expect(observedSizeItem(observation: size).displaySize == .unknown)
    let zero = ObservedPlanSize(logical: ByteAggregate(knownLowerBound: 0, completeTotal: 0), allocated: nil)
    #expect(observedSizeItem(observation: zero).displaySize.logical?.completeTotal == 0)
    let item = observedSizeItem(observation: zero)
    let unsupported = PlanItem(
      id: item.id, sourcePath: item.sourcePath, inventory: item.inventory, ancestors: [],
      policy: .wholeBundle, observedSize: zero, sizeMetadataVersion: 2)
    #expect(unsupported.displaySize == .unknown)
  }

  @Test("Inventory overflow cannot wrap into a false size and hard links count once")
  func inventoryOverflowAndHardLinks() {
    let first = observedSizeItem(path: "/private/tmp/LightenQA-large", kind: .regular, bytes: Int64.max)
    let second = observedSizeItem(path: "/private/tmp/LightenQA-second", kind: .regular, bytes: 1)
    #expect(ObservedPlanSize.inventory(first.inventory + second.inventory) == .unknown)
    let identity = FileIdentity(
      device: 1, inode: 8, changeSeconds: 0, changeNanoseconds: 0,
      logicalBytes: 9, allocatedBytes: 10, linkCount: 2, flags: 0, kind: .regular)
    let entries = ["first", "second"].map {
      ScanEntry(parentID: nil, path: "/private/tmp/LightenQA-" + $0, identity: identity, issues: [], readable: true)
    }
    #expect(ObservedPlanSize.inventory(entries).logical?.completeTotal == 9)
  }

  @Test("Observational bytes neither authorize changed files nor prevent valid execution and Undo")
  func authorityIndependence() async throws {
    let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(resolved) }
    let root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
    let path = root + "/data"
    let trash = root + "/Trash"
    try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let original = Data("contents".utf8)
    try original.write(to: URL(fileURLWithPath: path))
    let scan = try await ScanService().scan(rootPath: root)
    let entry = try #require(scan.entries.first { $0.path == path })
    let plan = try PlanService().makePlan(snapshot: scan, selectedIDs: [entry.id])
    let item = try #require(plan.items.first)
    let forged = PlanItem(
      id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
      inventory: item.inventory, ancestors: item.ancestors,
      observedSize: ObservedPlanSize(
        logical: ByteAggregate(knownLowerBound: Int64.max, completeTotal: Int64.max), allocated: nil))
    try ActionGuard().validate(forged)
    let observedPlan = ActionPlan(snapshotRunID: plan.snapshotRunID, kind: .trash, items: [forged])
    let journal = JSONLActionJournal(path: root + "/Journal/actions.jsonl")
    let result = try await ActionExecutor(journal: journal, trash: ObservedSizeFixtureTrash(directory: trash)).execute(
      observedPlan)
    #expect(result.items.first?.outcome == .applied)
    try await ActionHistory(journal: journal).undo(planID: observedPlan.id)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
    try Data("changed content".utf8).write(to: URL(fileURLWithPath: path))
    #expect(throws: GuardFailure.changedItem) { try ActionGuard().validate(forged) }
  }
}

private struct ObservedSizeFixtureTrash: TrashMoving {
  let directory: String
  func moveToTrash(path: String) async throws -> String {
    let destination = directory + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: destination)
    return destination
  }
}
