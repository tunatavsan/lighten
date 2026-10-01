import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private struct SelectionScopeFixture {
  let home: String
  let trash: String
  let journal: JSONLActionJournal

  init() throws {
    let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(temporary) }
    home = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
    trash = home + "/Trash"
    journal = JSONLActionJournal(path: home + "/Journal/actions.jsonl")
    try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
  }

  func directory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }

  func write(_ path: String) throws {
    try directory((path as NSString).deletingLastPathComponent)
    try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
  }

  func plan(_ selections: [UserSelection], kind: ActionKind = .trash) async throws -> ActionPlan {
    let available = await PlanService(homeDirectory: home).makeAvailableUserSelectionPlan(
      selections: selections, kind: kind)
    #expect(available.rejections.isEmpty)
    return try #require(available.plan)
  }

  func executor(_ probe: SelectionScopeProbe) -> ActionExecutor {
    ActionExecutor(
      journal: journal, trash: SelectionScopeTrash(directory: trash),
      guardService: ActionGuard(homeDirectory: home),
      userSelectionApplicationActivity: probe, applicationClosing: probe)
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: home) }
}

private struct SelectionScopeTrash: TrashMoving {
  let directory: String
  func moveToTrash(path: String) async throws -> String {
    let result = directory + "/" + (path as NSString).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: result)
    return result
  }
}

private final class SelectionScopeProbe: ApplicationActivitySource, UserSelectionApplicationClosing, Sendable {
  let observations = Mutex<[String]>([])
  let closures = Mutex<[String]>([])
  let state: Mutex<ApplicationActivityState>
  let administrator: Bool

  init(_ state: ApplicationActivityState = .unknown, administrator: Bool = false) {
    self.state = Mutex(state)
    self.administrator = administrator
  }

  func activity(applicationPath: String) async -> ApplicationActivity {
    observations.withLock { $0.append(applicationPath) }
    return ApplicationActivity(
      state: state.withLock { $0 }, processNames: ["Fixture helper"], scope: .currentUser,
      requiresAdministrator: administrator)
  }

  func closeApplications(rootPath: String, forceAfterGraceful: Bool) async throws {
    #expect(forceAfterGraceful)
    closures.withLock { $0.append(rootPath) }
    state.withLock { $0 = .clearObservedProcesses }
  }
}

@Suite("Explicit selection application process scope")
struct UserSelectionScopeTests {
  @Test("Ordinary selected files and folders never query or close processes", arguments: [false, true])
  func ordinarySelectionHasNoProcessVeto(close: Bool) async throws {
    let fixture = try SelectionScopeFixture()
    defer { fixture.cleanup() }
    let file = fixture.home + "/ChosenFile"
    let folder = fixture.home + "/ChosenFolder"
    try fixture.write(file)
    try fixture.write(folder + "/Nested.app/Contents/MacOS/helper")
    let probe = SelectionScopeProbe()
    let plan = try await fixture.plan([UserSelection(path: file), UserSelection(path: folder)])
    let result = try await fixture.executor(probe).execute(plan, closeRunningApplications: close)
    #expect(result.items.allSatisfy { $0.outcome == .applied })
    #expect(probe.observations.withLock { $0.isEmpty })
    #expect(probe.closures.withLock { $0.isEmpty })
  }

  @Test("An unknown application observation skips only that item with a named reason")
  func unknownApplicationIsItemOnly() async throws {
    let fixture = try SelectionScopeFixture()
    defer { fixture.cleanup() }
    let app = fixture.home + "/A.app"
    let file = fixture.home + "/Z-file"
    try fixture.directory(app)
    try fixture.write(file)
    let probe = SelectionScopeProbe()
    let plan = try await fixture.plan([UserSelection(path: app), UserSelection(path: file)])
    let result = try await fixture.executor(probe).execute(plan, closeRunningApplications: true)
    let appID = try #require(plan.items.first { $0.sourcePath == app }?.id)
    let fileID = try #require(plan.items.first { $0.sourcePath == file }?.id)
    #expect(result.items.first { $0.itemID == appID }?.outcome == .skipped)
    #expect(result.items.first { $0.itemID == appID }?.detail == "appRunningStateUnavailable:" + app)
    #expect(result.items.first { $0.itemID == fileID }?.outcome == .applied)
    #expect(probe.observations.withLock { $0 } == [app])
    #expect(probe.closures.withLock { $0.isEmpty })
    #expect(FileManager.default.fileExists(atPath: app))
  }

  @Test("A known nested package scopes observation and confirmed closing to that package")
  func knownNestedApplication() async throws {
    let fixture = try SelectionScopeFixture()
    defer { fixture.cleanup() }
    let folder = fixture.home + "/Chosen"
    let app = folder + "/Nested.app"
    try fixture.write(app + "/Contents/MacOS/helper")
    let probe = SelectionScopeProbe(.active)
    let selection = UserSelection(path: folder, applicationPackagePaths: [app])
    let first = try await fixture.plan([selection])
    let executor = fixture.executor(probe)
    #expect(try await executor.execute(first).items[0].outcome == .skipped)
    #expect(probe.closures.withLock { $0.isEmpty })
    let second = try await fixture.plan([selection])
    #expect(try await executor.execute(second, closeRunningApplications: true).items[0].outcome == .applied)
    #expect(probe.closures.withLock { $0 } == [app])
    #expect(probe.observations.withLock { $0.allSatisfy { $0 == app } })
  }

  @Test("A symlink selected as an application leaf never queries its target")
  func selectedApplicationLinkHasNoProcessScope() async throws {
    let fixture = try SelectionScopeFixture()
    defer { fixture.cleanup() }
    let target = fixture.home + "/Target.app"
    let link = fixture.home + "/Link.app"
    try fixture.directory(target)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    let probe = SelectionScopeProbe()
    let plan = try await fixture.plan([UserSelection(path: link, applicationPackagePaths: [target])])
    #expect(
      try await fixture.executor(probe).execute(plan, closeRunningApplications: true).items[0].outcome == .applied)
    #expect(probe.observations.withLock { $0.isEmpty })
    #expect(probe.closures.withLock { $0.isEmpty })
    #expect(FileManager.default.fileExists(atPath: target))
  }

  @Test("Hints outside the root or behind descendant symlinks never query their targets")
  func invalidHintsHaveNoProcessScope() async throws {
    let fixture = try SelectionScopeFixture()
    defer { fixture.cleanup() }
    let folder = fixture.home + "/Chosen"
    let outside = fixture.home + "/Outside"
    let app = outside + "/Target.app"
    try fixture.directory(folder)
    try fixture.directory(app)
    try FileManager.default.createSymbolicLink(atPath: folder + "/alias", withDestinationPath: outside)
    try FileManager.default.createSymbolicLink(atPath: folder + "/Link.app", withDestinationPath: app)
    let plan = try await fixture.plan([
      UserSelection(path: folder, applicationPackagePaths: [app, folder + "/alias/Target.app", folder + "/Link.app"])
    ])
    let probe = SelectionScopeProbe()
    #expect(
      try await fixture.executor(probe).execute(plan, closeRunningApplications: true).items[0].outcome == .applied)
    #expect(probe.observations.withLock { $0.isEmpty })
    #expect(probe.closures.withLock { $0.isEmpty })
    #expect(FileManager.default.fileExists(atPath: app))
  }

  @Test("An observed foreign process gives an administrator reason before any closing")
  func foreignApplicationRequiresAdministrator() async throws {
    let fixture = try SelectionScopeFixture()
    defer { fixture.cleanup() }
    let app = fixture.home + "/Chosen.app"
    try fixture.directory(app)
    let probe = SelectionScopeProbe(.active, administrator: true)
    let plan = try await fixture.plan([UserSelection(path: app)])
    let result = try await fixture.executor(probe).execute(plan, closeRunningApplications: true)
    #expect(result.items[0].outcome == .skipped)
    #expect(result.items[0].detail?.contains("needsAdministrator") == true)
    #expect(probe.closures.withLock { $0.isEmpty })
    #expect(FileManager.default.fileExists(atPath: app))
  }

  @Test("Final confirmation preserves privately bound known package hints")
  func finalizationPreservesKnownPackages() async throws {
    let fixture = try SelectionScopeFixture()
    defer { fixture.cleanup() }
    let folder = fixture.home + "/Chosen"
    let app = folder + "/Nested.app"
    try fixture.directory(app)
    let plan = try await fixture.plan([UserSelection(path: folder, applicationPackagePaths: [app])])
    let service = PlanService(homeDirectory: fixture.home)
    let final = try #require(await service.finalizeUserSelection(plan: plan, kind: .catalogDelete).plan)
    #expect(final.id == plan.id && final.items[0].id == plan.items[0].id)
    #expect(service.applicationPackagePaths(for: final.items[0], in: final) == [app])
    #expect(final.items[0].inventory.count == 1)
    let encoded = try JSONEncoder().encode(final)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("Nested.app"))
  }

  @Test("A stale hinted package replaced by a symlink never becomes a target scope")
  func changedHintIsNotFollowed() async throws {
    let fixture = try SelectionScopeFixture()
    defer { fixture.cleanup() }
    let folder = fixture.home + "/Chosen"
    let app = folder + "/Nested.app"
    let target = fixture.home + "/Outside.app"
    try fixture.directory(app)
    try fixture.directory(target)
    let plan = try await fixture.plan([UserSelection(path: folder, applicationPackagePaths: [app])])
    try FileManager.default.removeItem(atPath: app)
    try FileManager.default.createSymbolicLink(atPath: app, withDestinationPath: target)
    let probe = SelectionScopeProbe()
    #expect(
      try await fixture.executor(probe).execute(plan, closeRunningApplications: true).items[0].outcome == .applied)
    #expect(probe.observations.withLock { $0.isEmpty })
    #expect(probe.closures.withLock { $0.isEmpty })
    #expect(FileManager.default.fileExists(atPath: target))
  }
}
