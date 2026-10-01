import Foundation
import LightenKit
import Testing

@testable import Lighten

private actor SelectionScopeUIProbe: ApplicationActivitySource, UserSelectionApplicationClosing {
  private var states: [String: ApplicationActivity]
  private(set) var queries: [String] = []
  private(set) var closed: [String] = []

  init(states: [String: ApplicationActivity] = [:]) { self.states = states }

  func activity(applicationPath: String) async -> ApplicationActivity {
    queries.append(applicationPath)
    return states[applicationPath] ?? ApplicationActivity(state: .unknown, scope: .currentUser)
  }

  func closeApplications(rootPath: String, forceAfterGraceful: Bool) async throws {
    closed.append(rootPath)
    states[rootPath] = ApplicationActivity(state: .clearObservedProcesses, scope: .currentUser)
  }
}

private struct SelectionScopeUITrash: TrashMoving {
  let directory: String

  func moveToTrash(path: String) async throws -> String {
    let target = directory + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: target)
    return target
  }
}

private struct SelectionScopeUIFixture {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  var home: String { root + "/home" }
  var trash: String { root + "/Trash" }

  init() throws {
    for path in [home, trash] {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }

  @MainActor func actions(current: SelectionScopeUIProbe, allUsers: SelectionScopeUIProbe) -> ActionStore {
    ActionStore(
      journal: JSONLActionJournal(path: root + "/journal/actions.jsonl"),
      trash: SelectionScopeUITrash(directory: trash), planService: PlanService(homeDirectory: home),
      applicationActivity: allUsers, userSelectionApplicationActivity: current, applicationClosing: current)
  }

  @MainActor func select(_ path: String, in actions: ActionStore, packages: [String] = []) throws {
    let identity = try DescriptorFileSystem.identity(at: path)
    actions.basket[path] = BasketEntry(
      path: path, label: URL(fileURLWithPath: path).lastPathComponent,
      device: identity.device, inode: identity.inode,
      logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil), identity: identity,
      applicationPackagePaths: packages)
  }
}

@Suite("Explicit selection process scope")
struct UserSelectionScopeUITests {
  @MainActor
  @Test("Space file and ordinary folder selections never query or close processes", arguments: [false, true])
  func ordinarySelection(folder: Bool) async throws {
    let fixture = try SelectionScopeUIFixture()
    defer { fixture.remove() }
    let path = fixture.home + "/Chosen"
    if folder {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
      try Data("fixture".utf8).write(to: URL(fileURLWithPath: path + "/tool"))
    } else {
      try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
    }
    let current = SelectionScopeUIProbe()
    let allUsers = SelectionScopeUIProbe()
    let actions = fixture.actions(current: current, allUsers: allUsers)
    try fixture.select(path, in: actions)
    await actions.prepare(scanRoot: fixture.home, runID: nil)
    let presentation = try #require(actions.pending)
    #expect(!presentation.hasRunningApplications)
    #expect(await current.queries.isEmpty)
    #expect(await allUsers.queries.isEmpty)
    let confirmed = try #require(actions.takeConfirmedPlan(presentation, closeRunningApplications: true))
    await actions.executeConfirmed(confirmed)
    #expect(actions.result?.items.map(\.outcome) == [.applied])
    #expect(await current.queries.isEmpty)
    #expect(await current.closed.isEmpty)
    #expect(await allUsers.queries.isEmpty)
  }

  @MainActor @Test("Space carries already observed nested app paths without querying the parent folder")
  func knownNestedApplication() async throws {
    let fixture = try SelectionScopeUIFixture()
    defer { fixture.remove() }
    let folder = fixture.home + "/Chosen"
    let app = folder + "/Nested.app"
    try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
    let run = try ScanEngine().start(root: fixture.home)
    await run.waitUntilFinished()
    let item = try #require(run.tree.children(of: run.tree.rootID, metric: .logical).first { $0.path == folder })
    let current = SelectionScopeUIProbe(states: [app: ApplicationActivity(state: .active, scope: .currentUser)])
    let allUsers = SelectionScopeUIProbe()
    let actions = fixture.actions(current: current, allUsers: allUsers)
    actions.add(item, tree: run.tree)
    await actions.prepare(scanRoot: fixture.home, runID: run.runID)
    let presentation = try #require(actions.pending)
    #expect(presentation.hasRunningApplications)
    #expect(await current.queries == [app])
    #expect(await allUsers.queries.isEmpty)
    await actions.requestPermanent(presentation)
    let permanent = try #require(actions.pending)
    let planned = try #require(permanent.plan.items.first)
    #expect(PlanService(homeDirectory: fixture.home).applicationPackagePaths(for: planned, in: permanent.plan) == [app])
    #expect(await current.closed.isEmpty)
  }

  @MainActor @Test("An active selected app uses current-user observation and closes only that package")
  func currentUserApplication() async throws {
    let fixture = try SelectionScopeUIFixture()
    defer { fixture.remove() }
    let app = fixture.home + "/Chosen.app"
    try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
    let current = SelectionScopeUIProbe(states: [app: ApplicationActivity(state: .active, scope: .currentUser)])
    let allUsers = SelectionScopeUIProbe()
    let actions = fixture.actions(current: current, allUsers: allUsers)
    try fixture.select(app, in: actions)
    await actions.prepare(scanRoot: fixture.home, runID: nil)
    let presentation = try #require(actions.pending)
    #expect(presentation.hasRunningApplications)
    let confirmed = try #require(actions.takeConfirmedPlan(presentation, closeRunningApplications: true))
    await actions.executeConfirmed(confirmed)
    #expect(actions.result?.items.map(\.outcome) == [.applied])
    #expect(await current.closed == [app])
    #expect(await current.queries.allSatisfy { $0 == app })
    #expect(await allUsers.queries.isEmpty)
  }

  @MainActor @Test("Unknown app activity retains only that app while another selected file proceeds")
  func unknownAppDoesNotVetoOtherSelections() async throws {
    let fixture = try SelectionScopeUIFixture()
    defer { fixture.remove() }
    let app = fixture.home + "/Chosen.app"
    let file = fixture.home + "/Chosen.txt"
    try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
    try Data("fixture".utf8).write(to: URL(fileURLWithPath: file))
    let current = SelectionScopeUIProbe()
    let allUsers = SelectionScopeUIProbe()
    let actions = fixture.actions(current: current, allUsers: allUsers)
    try fixture.select(app, in: actions)
    try fixture.select(file, in: actions)
    await actions.prepare(scanRoot: fixture.home, runID: nil)
    let presentation = try #require(actions.pending)
    let appItem = try #require(presentation.plan.items.first { $0.sourcePath == app })
    let fileItem = try #require(presentation.plan.items.first { $0.sourcePath == file })
    let confirmed = try #require(actions.takeConfirmedPlan(presentation, closeRunningApplications: true))
    await actions.executeConfirmed(confirmed)
    #expect(actions.result?.items.first { $0.itemID == appItem.id }?.detail == "appRunningStateUnavailable:" + app)
    #expect(actions.result?.items.first { $0.itemID == fileItem.id }?.outcome == .applied)
    #expect(actions.resultFailures.first { $0.path == app }?.presentation?.unknownCodes.isEmpty == true)
    #expect(actions.basket[app] != nil && actions.basket[file] == nil)
    #expect(FileManager.default.fileExists(atPath: app))
    #expect(await current.closed.isEmpty)
    #expect(await current.queries.allSatisfy { $0 == app })
    #expect(await allUsers.queries.isEmpty)
  }

  @MainActor @Test("An observed foreign app process requires an administrator before offering or attempting close")
  func foreignApplicationRequiresAdministrator() async throws {
    let fixture = try SelectionScopeUIFixture()
    defer { fixture.remove() }
    let app = fixture.home + "/Chosen.app"
    try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
    let current = SelectionScopeUIProbe(states: [
      app: ApplicationActivity(state: .active, scope: .currentUser, requiresAdministrator: true)
    ])
    let allUsers = SelectionScopeUIProbe()
    let actions = fixture.actions(current: current, allUsers: allUsers)
    try fixture.select(app, in: actions)
    await actions.prepare(scanRoot: fixture.home, runID: nil)
    let presentation = try #require(actions.pending)
    #expect(!presentation.hasRunningApplications)
    let confirmed = try #require(actions.takeConfirmedPlan(presentation, closeRunningApplications: true))
    await actions.executeConfirmed(confirmed)
    let failure = try #require(actions.resultFailures.first)
    let copy = try #require(failure.presentation)
    #expect(copy.primaryReason.contains("administrator"))
    #expect(copy.nextStep.contains("Finder"))
    #expect(await current.closed.isEmpty)
    #expect(await allUsers.queries.isEmpty)
    #expect(FileManager.default.fileExists(atPath: app))
  }

  @MainActor @Test("Unknown app activity has a named translated reason and one next action", arguments: [false, true])
  func unknownActivityCopy(turkish: Bool) {
    let copy = FailureText.presentation("appRunningStateUnavailable:/fixture/Chosen.app", turkish: turkish)
    #expect(
      copy.reasons == [
        turkish
          ? "Bu uygulamanın çalışıp çalışmadığı doğrulanamadı."
          : "This app’s running state could not be verified."
      ])
    #expect(copy.nextStep == (turkish ? "Uygulamayı kapatıp tekrar deneyin." : "Quit it and try again."))
    #expect(copy.unknownCodes.isEmpty)
    #expect(!copy.text.contains("/fixture") && !copy.text.contains("appRunningStateUnavailable"))
  }
}
