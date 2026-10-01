import Darwin
import Foundation
import Testing

@testable import LightenKit

private struct UninstallFixture {
  let home: String
  let app: String
  let helper: String
  let cache: String
  let bundleID: String

  init() throws {
    let temporary = try #require(realpath("/tmp", nil))
    defer { free(temporary) }
    let token = UUID().uuidString
    home = String(cString: temporary) + "/LightenQA-" + token
    bundleID = "qa.lighten." + token
    app = home + "/Applications/LightenQA-" + token + ".app"
    helper = app + "/Contents/Helpers/LightenQA-" + token
    cache = RelatedLocation.caches.path(domain: bundleID, homeDirectory: home)
    try FileManager.default.createDirectory(atPath: app + "/Contents/Helpers", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: home + "/Trash", withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: helper)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
    try Data("related data".utf8).write(to: URL(fileURLWithPath: cache + "/record"))
  }

  var service: RelatedDataService {
    RelatedDataService(
      homeDirectory: home, applicationRoots: [home + "/Applications"], writeVerifiedReceipts: false,
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) })
  }

  var nativeService: RelatedDataService {
    RelatedDataService(
      homeDirectory: home, applicationRoots: [home + "/Applications"], writeVerifiedReceipts: false)
  }

  func selected() async throws -> (InstalledApplication, RelatedDataCandidate) {
    let selected = try #require(service.application(at: app))
    let candidate = try #require((await service.discover(for: selected)).first { $0.path == cache })
    return (selected, candidate)
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: home) }
}

private struct UninstallNotRunning: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? { false }
}

private actor UninstallTrash: TrashMoving {
  let destination: String
  let refused: String?
  private var moved: [String: String] = [:]
  private var attempts: [String] = []

  init(destination: String, refused: String? = nil) {
    self.destination = destination
    self.refused = refused
  }

  func moveToTrash(path: String) async throws -> String {
    attempts.append(path)
    if path == refused { throw CocoaError(.fileWriteNoPermission) }
    let target = destination + "/" + (path as NSString).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: target)
    moved[path] = target
    return target
  }

  func target(for path: String) -> String? { moved[path] }
  func paths() -> [String] { attempts }
}

private actor UninstallAppliedJournal: ActionJournal {
  private let journal: JSONLActionJournal
  private let packageID: UUID
  private let failApplied: Bool
  private let afterApplied: (@Sendable (JournalRecord) throws -> Void)?

  init(
    journal: JSONLActionJournal, packageID: UUID, failApplied: Bool = false,
    afterApplied: (@Sendable (JournalRecord) throws -> Void)? = nil
  ) {
    self.journal = journal
    self.packageID = packageID
    self.failApplied = failApplied
    self.afterApplied = afterApplied
  }

  func acquireMutationLease() async throws -> JournalLease { try await journal.acquireMutationLease() }
  func releaseMutationLease(_ lease: JournalLease) async { await journal.releaseMutationLease(lease) }
  func read() async throws -> JournalReadout { try await journal.read() }
  func readSummary() async throws -> JournalReadout { try await journal.readSummary() }
  func loadPlan(id: UUID) async throws -> ActionPlan { try await journal.loadPlan(id: id) }

  func append(_ record: JournalRecord) async throws {
    let packageApplied = record.kind == .applied && record.itemID == packageID
    if packageApplied && failApplied { throw JournalFailure.systemCall("fixture append", EIO) }
    try await journal.append(record)
    if packageApplied { try afterApplied?(record) }
  }
}

private func stopUninstallHelper(_ pid: Int32) async -> Bool {
  func exited() -> Bool {
    var status: Int32 = 0
    let observed = waitpid(pid, &status, WNOHANG)
    return observed == pid || (observed == -1 && errno == ECHILD)
  }
  if exited() { return true }
  _ = kill(pid, SIGTERM)
  for _ in 0..<100 {
    if exited() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  _ = kill(pid, SIGKILL)
  for _ in 0..<100 {
    if exited() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return exited()
}

@Suite("Uninstall package safety")
struct UninstallPackageSafetyTests {
  @Test(
    "Durably applied packages stay applied when owner context fails and independent items still finish",
    arguments: ["context", "info"])
  func appliedPackageContextFailure(_ change: String) async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let independent = fixture.home + "/independent.bin"
    let independentBytes = Data("independent owned file".utf8)
    try independentBytes.write(to: URL(fileURLWithPath: independent))
    let relatedBytes = try Data(contentsOf: URL(fileURLWithPath: fixture.cache + "/record"))
    let (app, candidate) = try await fixture.selected()
    let uninstall = try fixture.service.planUninstall(app: app, selectedRelated: [candidate])
    let package = try #require(uninstall.items.first { $0.sourcePath == fixture.app })
    let data = try #require(uninstall.items.first { $0.sourcePath == fixture.cache })
    let identity = try DescriptorFileSystem.identity(at: independent)
    let ownPlan = try PlanService(homeDirectory: fixture.home).makeSpacePlan(
      selections: [.init(path: independent, device: identity.device, inode: identity.inode)],
      scanRootPath: fixture.home, runID: uninstall.snapshotRunID)
    let own = try #require(ownPlan.items.first)
    let plan = ActionPlan(
      id: uninstall.id, snapshotRunID: uninstall.snapshotRunID, kind: .trash,
      createdAt: uninstall.createdAt, items: uninstall.items + [own])
    let durable = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
    let journal = UninstallAppliedJournal(
      journal: durable, packageID: package.id,
      afterApplied: { record in
        if change == "context" {
          // Simulate a fresh source namespace appearing after the durable move.
          try FileManager.default.createDirectory(atPath: fixture.app, withIntermediateDirectories: false)
        } else {
          let moved = try #require(record.returnedTrashPath)
          try Data("changed owner metadata".utf8).write(to: URL(fileURLWithPath: moved + "/Contents/Info.plist"))
        }
      })
    let trash = UninstallTrash(destination: fixture.home + "/Trash")
    let result = try await ActionExecutor(
      journal: journal, trash: trash, guardService: ActionGuard(homeDirectory: fixture.home),
      related: fixture.service, runningApplications: UninstallNotRunning(),
      applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items.first { $0.itemID == package.id }?.outcome == .applied)
    #expect(result.items.first { $0.itemID == data.id }?.outcome == .skipped)
    #expect(result.items.first { $0.itemID == data.id }?.detail == "changedItem")
    #expect(result.items.first { $0.itemID == own.id }?.outcome == .applied)
    #expect(await trash.paths() == [fixture.app, independent])
    #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.cache + "/record")) == relatedBytes)
    #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.home + "/Trash/independent.bin")) == independentBytes)
    #expect(!FileManager.default.fileExists(atPath: independent))
    let records = try await durable.readSummary().records
    #expect(records.filter { $0.kind == .intent }.count == 1)
    #expect(records.filter { $0.itemID == package.id }.map(\.kind) == [.applied])
    #expect(records.filter { $0.itemID == data.id }.map(\.kind) == [.skipped])
    let history = try await ActionHistory(journal: durable, homeDirectory: fixture.home).loadGroup(planID: plan.id)
    #expect(history.appliedCount == 2)
    #expect(history.items.first { $0.itemID == package.id }?.state == .inTrash)
    #expect(history.items.first { $0.itemID == package.id }?.applied == true)
    #expect(history.items.first { $0.itemID == data.id }?.state == .skipped)
    #expect(history.items.first { $0.itemID == data.id }?.detail == "changedItem")
    #expect(history.items.first { $0.itemID == own.id }?.state == .inTrash)
    let restored = try await ActionHistory(journal: durable, homeDirectory: fixture.home).undo(planID: plan.id)
    #expect(restored.items.first { $0.itemID == own.id }?.outcome == .restored)
    #expect(try Data(contentsOf: URL(fileURLWithPath: independent)) == independentBytes)
    #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.cache + "/record")) == relatedBytes)
  }

  @Test("An applied append failure stays uncertain and stops dependent and independent moves")
  func packageAppliedAppendFailure() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let (app, candidate) = try await fixture.selected()
    let uninstall = try fixture.service.planUninstall(app: app, selectedRelated: [candidate])
    let package = try #require(uninstall.items.first { $0.sourcePath == fixture.app })
    let data = try #require(uninstall.items.first { $0.sourcePath == fixture.cache })
    let independent = fixture.home + "/independent.bin"
    let independentBytes = Data("unattempted owned file".utf8)
    try independentBytes.write(to: URL(fileURLWithPath: independent))
    let identity = try DescriptorFileSystem.identity(at: independent)
    let ownPlan = try PlanService(homeDirectory: fixture.home).makeSpacePlan(
      selections: [.init(path: independent, device: identity.device, inode: identity.inode)],
      scanRootPath: fixture.home, runID: uninstall.snapshotRunID)
    let own = try #require(ownPlan.items.first)
    let plan = ActionPlan(
      id: uninstall.id, snapshotRunID: uninstall.snapshotRunID, kind: .trash,
      createdAt: uninstall.createdAt, items: uninstall.items + [own])
    let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.cache + "/record"))
    let durable = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
    let journal = UninstallAppliedJournal(journal: durable, packageID: package.id, failApplied: true)
    let trash = UninstallTrash(destination: fixture.home + "/Trash")
    let result = try await ActionExecutor(
      journal: journal, trash: trash, guardService: ActionGuard(homeDirectory: fixture.home),
      related: fixture.service, runningApplications: UninstallNotRunning(),
      applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items.first { $0.itemID == package.id }?.outcome == .uncertain)
    #expect(result.items.first { $0.itemID == package.id }?.detail == "applied journal failure")
    #expect(result.items.first { $0.itemID == package.id }?.mutationStage == .trashMoveObserved)
    #expect(result.items.first { $0.itemID == data.id }?.outcome == .notAttempted)
    #expect(result.items.first { $0.itemID == own.id }?.outcome == .notAttempted)
    #expect(await trash.paths() == [fixture.app])
    #expect(!FileManager.default.fileExists(atPath: fixture.app))
    #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.cache + "/record")) == bytes)
    #expect(try Data(contentsOf: URL(fileURLWithPath: independent)) == independentBytes)
    #expect(try await durable.readSummary().records.map(\.kind) == [.intent])
    let history = try await ActionHistory(journal: durable, homeDirectory: fixture.home).reconcile()
    #expect(history.items.first { $0.itemID == package.id }?.state == .uncertain)
    #expect(history.items.first { $0.itemID == package.id }?.applied == false)
  }

  @Test("A native helper executable blocks both planning and every dependent move")
  func nativeHelperBlocksUninstall() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let (app, candidate) = try await fixture.selected()
    let plan = try fixture.service.planUninstall(app: app, selectedRelated: [candidate])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: fixture.helper)
    process.arguments = ["30"]
    try process.run()
    let pid = process.processIdentifier
    do {
      var observation = ApplicationActivity(state: .unknown)
      for _ in 0..<100 {
        observation = await NativeApplicationActivitySource().activity(applicationPath: fixture.app)
        if observation.state == .active { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(observation.state == .active)
      #expect(observation.processNames.contains { $0.hasPrefix("LightenQA-") })
      #expect(throws: ProcessActivityFailure.self) {
        try fixture.nativeService.planUninstall(app: app, selectedRelated: [candidate])
      }
      let trash = UninstallTrash(destination: fixture.home + "/Trash")
      let result = try await ActionExecutor(
        journal: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"), trash: trash,
        guardService: ActionGuard(homeDirectory: fixture.home), related: fixture.service,
        runningApplications: UninstallNotRunning()
      ).execute(plan)
      #expect(result.items.allSatisfy { $0.outcome == .skipped })
      #expect(result.items.allSatisfy { $0.detail?.contains("processActive:LightenQA-") == true })
      #expect(await trash.paths().isEmpty)
      #expect(FileManager.default.fileExists(atPath: fixture.app))
      #expect(FileManager.default.fileExists(atPath: fixture.cache))
    } catch {
      #expect(await stopUninstallHelper(pid))
      throw error
    }
    #expect(await stopUninstallHelper(pid))
  }

  @Test("Unknown executable observation refuses package and dependent data")
  func unknownExecutableObservationStopsData() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let (app, candidate) = try await fixture.selected()
    let unknown = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.home + "/Applications"],
      writeVerifiedReceipts: false, packageActivity: { _ in ApplicationActivity(state: .unknown) })
    let refusal = #expect(throws: ProcessActivityFailure.self) {
      try unknown.planUninstall(app: app, selectedRelated: [candidate])
    }
    #expect(refusal?.description == "processActivityUnavailable")
    let plan = try fixture.service.planUninstall(app: app, selectedRelated: [candidate])
    let trash = UninstallTrash(destination: fixture.home + "/Trash")
    let result = try await ActionExecutor(
      journal: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"), trash: trash,
      guardService: ActionGuard(homeDirectory: fixture.home), related: fixture.service,
      runningApplications: UninstallNotRunning(), applicationActivity: FixtureUnknownApplicationActivity()
    ).execute(plan)
    #expect(result.items.allSatisfy { $0.outcome == .skipped })
    #expect(result.items.allSatisfy { $0.detail?.contains("processActivityUnavailable") == true })
    #expect(await trash.paths().isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.app))
    #expect(FileManager.default.fileExists(atPath: fixture.cache))
  }

  @Test("A final package change cannot move data even when data was ordered first")
  func latePackageChangeStopsData() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let (app, candidate) = try await fixture.selected()
    let plan = try fixture.service.planUninstall(app: app, selectedRelated: [candidate])
    #expect(plan.items.first?.installedRelatedProof != nil)
    let trash = UninstallTrash(destination: fixture.home + "/Trash")
    let result = try await ActionExecutor(
      journal: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"), trash: trash,
      guardService: ActionGuard(homeDirectory: fixture.home),
      beforeMutation: { item in
        if item.sourcePath == fixture.app {
          try Data("changed metadata".utf8).write(to: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist"))
        }
      }, related: fixture.service, runningApplications: UninstallNotRunning(),
      applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items.allSatisfy { $0.outcome == .skipped })
    #expect(await trash.paths().isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.app))
    #expect(FileManager.default.fileExists(atPath: fixture.cache))
  }

  @Test("A failed package move skips its related data")
  func failedPackageMoveStopsData() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let (app, candidate) = try await fixture.selected()
    let plan = try fixture.service.planUninstall(app: app, selectedRelated: [candidate])
    let trash = UninstallTrash(destination: fixture.home + "/Trash", refused: fixture.app)
    let result = try await ActionExecutor(
      journal: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"), trash: trash,
      guardService: ActionGuard(homeDirectory: fixture.home), related: fixture.service,
      runningApplications: UninstallNotRunning(), applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items.first { $0.itemID == plan.items.last?.id }?.outcome == .failed)
    #expect(result.items.first { $0.itemID == plan.items.first?.id }?.outcome == .skipped)
    #expect(await trash.paths() == [fixture.app])
    #expect(FileManager.default.fileExists(atPath: fixture.app))
    #expect(FileManager.default.fileExists(atPath: fixture.cache))
  }

  @Test(
    "Moved owner metadata and root identity remain exact during the final related-data window",
    arguments: ["info", "root"])
  func movedOwnerChangedBeforeData(_ changed: String) async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let (app, candidate) = try await fixture.selected()
    let plan = try fixture.service.planUninstall(app: app, selectedRelated: [candidate])
    let trash = UninstallTrash(destination: fixture.home + "/Trash")
    let result = try await ActionExecutor(
      journal: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"), trash: trash,
      guardService: ActionGuard(homeDirectory: fixture.home),
      beforeMutation: { item in
        if item.sourcePath == fixture.cache, let owner = await trash.target(for: fixture.app) {
          if changed == "info" {
            try Data("changed metadata".utf8).write(to: URL(fileURLWithPath: owner + "/Contents/Info.plist"))
          } else {
            try FileManager.default.moveItem(atPath: owner, toPath: owner + ".original")
            try FileManager.default.copyItem(atPath: owner + ".original", toPath: owner)
          }
        }
      }, related: fixture.service, runningApplications: UninstallNotRunning(),
      applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items.first { $0.itemID == plan.items.last?.id }?.outcome == .applied)
    #expect(result.items.first { $0.itemID == plan.items.first?.id }?.outcome == .skipped)
    #expect(await trash.paths() == [fixture.app])
    #expect(!FileManager.default.fileExists(atPath: fixture.app))
    #expect(FileManager.default.fileExists(atPath: fixture.cache))
  }

  @Test("Data-only selections still refuse a changed application before moving data")
  func dataOnlyRequiresMovablePackage() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let (app, candidate) = try await fixture.selected()
    let plan = try fixture.service.planInstalled(app: app, candidate: candidate)
    let trash = UninstallTrash(destination: fixture.home + "/Trash")
    let result = try await ActionExecutor(
      journal: JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl"), trash: trash,
      guardService: ActionGuard(homeDirectory: fixture.home),
      beforeMutation: { _ in
        try Data("changed metadata".utf8).write(to: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist"))
      }, related: fixture.service, runningApplications: UninstallNotRunning(),
      applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items.allSatisfy { $0.outcome == .skipped })
    #expect(await trash.paths().isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.app))
    #expect(FileManager.default.fileExists(atPath: fixture.cache))
  }

  @Test("Verified package-first removal retains one journal plan and grouped Undo")
  func packageFirstRemainsRecoverable() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let (app, candidate) = try await fixture.selected()
    let plan = try fixture.service.planUninstall(app: app, selectedRelated: [candidate])
    let trash = UninstallTrash(destination: fixture.home + "/Trash")
    let journal = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
    let result = try await ActionExecutor(
      journal: journal, trash: trash, guardService: ActionGuard(homeDirectory: fixture.home),
      related: fixture.service, runningApplications: UninstallNotRunning(),
      applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items.allSatisfy { $0.outcome == .applied })
    #expect(await trash.paths() == [fixture.app, fixture.cache])
    #expect(try await journal.readSummary().records.filter { $0.kind == .intent }.count == 1)
    let restored = try await ActionHistory(journal: journal, homeDirectory: fixture.home).undo(planID: plan.id)
    #expect(restored.restoredCount == 2)
    #expect(FileManager.default.fileExists(atPath: fixture.app))
    #expect(FileManager.default.fileExists(atPath: fixture.cache))
  }
}
