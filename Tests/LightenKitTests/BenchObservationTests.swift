import Darwin
import Foundation
import Testing

@testable import LightenKit

@Test("Read-only discovery neither creates nor updates verified receipts", arguments: [false, true])
func readOnlyDiscoveryPreservesReceiptStore(existingReceipt: Bool) async throws {
  let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
  defer { free(temporary) }
  let root = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
  defer { try? FileManager.default.removeItem(atPath: root) }
  let bundleID = "qa.lighten.observation"
  let appRoot = root + "/Applications"
  let appPath = appRoot + "/LightenQA.app"
  let cachePath = root + "/Library/Caches/" + bundleID
  let receiptPath = root + "/Library/Application Support/com.tavsn.lighten/related-receipts.json"
  try FileManager.default.createDirectory(atPath: appPath + "/Contents", withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: cachePath, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: root + "/Library/Preferences", withIntermediateDirectories: true)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: appPath + "/Contents/Info.plist"))
  try Data("cached bytes".utf8).write(to: URL(fileURLWithPath: cachePath + "/entry"))

  let writer = RelatedDataService(homeDirectory: root, applicationRoots: [appRoot])
  if existingReceipt {
    _ = await writer.discover()
    #expect(FileManager.default.fileExists(atPath: receiptPath))
  }
  let beforeData = try? Data(contentsOf: URL(fileURLWithPath: receiptPath))
  let beforeIdentity = try? DescriptorFileSystem.identity(at: receiptPath)
  let observer = RelatedDataService(
    homeDirectory: root, applicationRoots: [appRoot], writeVerifiedReceipts: false,
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let candidates = await observer.discover()
  let candidate = try #require(candidates.first { $0.path == cachePath })
  #expect(candidate.classification == .installed)
  #expect(candidate.observation?.logical.completeTotal == Int64("cached bytes".utf8.count))
  #expect(candidate.snapshot?.entries.count == 1)
  #expect(!candidates.contains { $0.id == "receipt-write" })
  #expect((try? Data(contentsOf: URL(fileURLWithPath: receiptPath))) == beforeData)
  #expect((try? DescriptorFileSystem.identity(at: receiptPath)) == beforeIdentity)
  if !existingReceipt {
    #expect(!FileManager.default.fileExists(atPath: root + "/Library/Application Support"))
  }

  let app = try #require(observer.inventory().applications.first { $0.path == appPath })
  let plan = try observer.planInstalled(app: app, candidate: candidate)
  #expect(plan.items.first?.installedRelatedProof?.bundleID == bundleID)
  try FileManager.default.removeItem(atPath: appPath)
  let absent = try #require((await observer.discover()).first { $0.path == cachePath })
  #expect(absent.classification == (existingReceipt ? .historicallyVerifiedAbsent : .orphanVerified))
  #expect(!absent.defaultSelected)
}

@Test("Read-only survey discovery retains name-only bytes and unknown-size refused observations")
func readOnlySurveyRetainsNameOnlyAndUnknownCandidates() async throws {
  let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
  defer { free(temporary) }
  let root = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
  defer { try? FileManager.default.removeItem(atPath: root) }
  let appRoot = root + "/Applications"
  let appPath = appRoot + "/LightenQA-observation.app"
  let bundleID = "qa.lighten.observation"
  let named = root + "/Library/Application Support/LightenQA-observation"
  let exact = root + "/Library/Caches/" + bundleID
  let unreadableArea = root + "/Library/Logs"
  try FileManager.default.createDirectory(atPath: appPath + "/Contents", withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: named, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: exact, withIntermediateDirectories: true)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: appPath + "/Contents/Info.plist"))
  try Data(repeating: 1, count: 37).write(to: URL(fileURLWithPath: named + "/data.bin"))
  try Data(repeating: 2, count: 13).write(to: URL(fileURLWithPath: exact + "/cache.bin"))
  // A regular file where an area directory should be is a deterministic unreadable-area observation.
  try Data("not a directory".utf8).write(to: URL(fileURLWithPath: unreadableArea))
  let service = RelatedDataService(
    homeDirectory: root, applicationRoots: [appRoot], writeVerifiedReceipts: false,
    installedElsewhere: { _ in false },
    packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  let session = ApplicationDiscovery(related: service).scanSession()
  var completedReports: [ApplicationReport] = []
  for await event in await session.events() {
    if case .completed(_, let reports) = event { completedReports = reports }
  }
  let raw = await session.observedRelatedCandidates()
  let nameOnly = try #require(raw.first { $0.path == named })
  let known = try #require(raw.first { $0.path == exact })
  let unknown = try #require(raw.first { $0.path == unreadableArea })
  #expect(nameOnly.classification == .unprovenNameOnly && nameOnly.reason == .nameOnly)
  #expect(nameOnly.observation?.logical.completeTotal == 37)
  #expect(nameOnly.observation?.allocated.completeTotal != nil)
  #expect(!nameOnly.canSelect && !nameOnly.defaultSelected)
  #expect(nameOnly.explicitManualChoiceAvailable && nameOnly.snapshot?.entries.count == 1)
  #expect(known.classification == .installed && known.observation?.logical.completeTotal == 13)
  #expect(unknown.reason == .candidateAreaUnreadable && unknown.classification == .uncertain)
  #expect(unknown.observation == nil && unknown.snapshot == nil)
  #expect(!unknown.canSelect && !unknown.explicitManualChoiceAvailable)
  #expect(raw.filter { [named, exact, unreadableArea].contains($0.path) }.count == 3)
  let report = try #require(completedReports.first { $0.path == appPath })
  #expect(report.related.contains { $0.path == named && $0.classification == .unprovenNameOnly })
  #expect(report.related.contains { $0.path == exact })
  let app = try #require(service.application(at: appPath))
  let automatic = await session.makeAvailableUninstallPlan(
    app: app, selectedRelated: [nameOnly], includePackage: false)
  #expect(automatic.plan == nil && !automatic.rejections.isEmpty)
  let explicit = await session.makeAvailableUninstallPlan(
    app: app, selectedRelated: [], includePackage: false, selectedUnprovenRelated: [nameOnly])
  let manualPlan = try #require(explicit.plan)
  let manual = try #require(manualPlan.items.first)
  #expect(explicit.rejections.isEmpty && manual.policy == .spaceTrash)
  #expect(manual.installedRelatedProof == nil && manual.relatedProof == nil && manual.orphanRelatedProof == nil)
  #expect(await session.validatePlan(manualPlan).isEmpty)
  let guardService = ActionGuard(homeDirectory: root)
  try guardService.validate(manual, plan: manualPlan)
  #expect(throws: (any Error).self) { try guardService.validate(manual) }
  let unbound = ActionPlan(snapshotRunID: manualPlan.snapshotRunID, kind: .trash, items: [manual])
  #expect(throws: (any Error).self) { try guardService.validate(manual, plan: unbound) }
  let permanent = ActionPlan(
    id: manualPlan.id, snapshotRunID: manualPlan.snapshotRunID, kind: .catalogDelete,
    createdAt: manualPlan.createdAt, items: manualPlan.items)
  #expect(throws: (any Error).self) { try guardService.validate(manual, plan: permanent) }
  try FileManager.default.moveItem(atPath: named, toPath: named + ".old")
  try FileManager.default.createDirectory(atPath: named, withIntermediateDirectories: true)
  #expect(!(await session.validatePlan(manualPlan)).isEmpty)
  #expect(!FileManager.default.fileExists(atPath: root + "/Library/Application Support/com.tavsn.lighten"))
  await session.cancel()
}
