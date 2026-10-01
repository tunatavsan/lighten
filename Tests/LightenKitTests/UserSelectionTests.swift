import CLightenPlatform
import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private struct UserSelectionFixture {
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
  func write(_ path: String, _ text: String = "fixture") throws {
    try directory((path as NSString).deletingLastPathComponent)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }
  func plan(_ path: String, kind: ActionKind = .trash, warnings: [UserSelectionWarning] = []) async throws -> ActionPlan
  {
    let outcome = await PlanService(homeDirectory: home).makeAvailableUserSelectionPlan(
      selections: [UserSelection(path: path, warnings: warnings)], kind: kind)
    #expect(outcome.rejections.isEmpty)
    return try #require(outcome.plan)
  }
  func cleanup() { try? FileManager.default.removeItem(atPath: home) }
}

private func nativeCaptureFailureActivity(selectedRoot: String, unrelatedRoot: String) async -> String {
  let source = NativeApplicationActivitySource()
  let selected = await source.activity(applicationPath: selectedRoot)
  let unrelated = await source.activity(applicationPath: unrelatedRoot)
  return "selected root activity: \(selected.state), processes: \(selected.processNames); "
    + "unrelated root activity: \(unrelated.state), processes: \(unrelated.processNames)"
}

private struct UserSelectionTrash: TrashMoving {
  let directory: String
  func moveToTrash(path: String) async throws -> String {
    let result = directory + "/" + (path as NSString).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: result)
    return result
  }
}

private enum UserSelectionInjectedFailure: Error { case movedWithoutResult }
private struct UserSelectionUnverifiedTrash: TrashMoving {
  let directory: String
  func moveToTrash(path: String) async throws -> String {
    try FileManager.default.moveItem(atPath: path, toPath: directory + "/" + (path as NSString).lastPathComponent)
    throw UserSelectionInjectedFailure.movedWithoutResult
  }
}

private final class UserSelectionProcessState: Sendable {
  let active = Mutex(true)
  let confirmations = Mutex<[Bool]>([])
}

private struct UserSelectionActivity: ApplicationActivitySource {
  let state: UserSelectionProcessState
  func activity(applicationPath: String) async -> ApplicationActivity {
    ApplicationActivity(
      state: state.active.withLock { $0 } ? .active : .clearObservedProcesses, processNames: ["Fixture helper"])
  }
}

private struct UserSelectionClosing: UserSelectionApplicationClosing {
  let state: UserSelectionProcessState
  func closeApplications(rootPath: String, forceAfterGraceful: Bool) async throws {
    state.confirmations.withLock { $0.append(forceAfterGraceful) }
    state.active.withLock { $0 = false }
  }
}

@Suite("Explicit user selections")
struct UserSelectionTests {
  @Test("Sensitive descendants and nested applications move intact without an inventory or Info requirement")
  func rootOnlyTrashAndUndo() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let source = fixture.home + "/Chosen"
    let photos = source + "/Pictures.photoslibrary/originals/photo"
    try fixture.write(photos)
    try fixture.write(source + "/Library/Keychains/credentials")
    try fixture.write(source + "/.ssh/key")
    try fixture.write(source + "/Nested.app/Contents/MacOS/tool")
    let plan = try await fixture.plan(source, warnings: [UserSelectionWarning(examplePath: photos)])
    #expect(plan.items[0].inventory.count == 1 && plan.items[0].ancestors.isEmpty)
    #expect(plan.items[0].applicationPackageObservation == nil)
    #expect(plan.items[0].userSelectionWarnings?.first?.examplePath == photos)
    let result = try await ActionExecutor(
      journal: fixture.journal, trash: UserSelectionTrash(directory: fixture.trash),
      guardService: ActionGuard(homeDirectory: fixture.home),
      beforeMutation: { _ in try fixture.write(source + "/added-after-confirmation") },
      applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items.first?.outcome == .applied)
    #expect(!FileManager.default.fileExists(atPath: source))
    let reopened = JSONLActionJournal(path: fixture.home + "/Journal/actions.jsonl")
    let history = ActionHistory(journal: reopened, homeDirectory: fixture.home)
    #expect(try await history.loadGroup(planID: plan.id).canUndo)
    #expect(try await history.undo(planID: plan.id).restoredCount == 1)
    #expect(try String(contentsOfFile: photos, encoding: .utf8) == "fixture")
    #expect(FileManager.default.fileExists(atPath: source + "/added-after-confirmation"))
  }

  @Test("A symbolic-link selection moves its own leaf and Undo preserves its target")
  func symbolicLinkLeaf() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let target = fixture.home + "/Target"
    let link = fixture.home + "/Link"
    try fixture.write(target)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    let plan = try await fixture.plan(link)
    let result = try await ActionExecutor(
      journal: fixture.journal, trash: UserSelectionTrash(directory: fixture.trash),
      guardService: ActionGuard(homeDirectory: fixture.home), applicationActivity: FixtureUnknownApplicationActivity()
    ).execute(plan)
    #expect(result.items[0].outcome == .applied)
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "fixture")
    #expect(
      try await ActionHistory(journal: fixture.journal, homeDirectory: fixture.home).undo(planID: plan.id).restoredCount
        == 1)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == target)
  }

  @Test("Base roots are refused for both removal methods", arguments: [ActionKind.trash, .catalogDelete])
  func baseRoots(kind: ActionKind) async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let roots = ["/", "/System", "/Library", "/Users", "/Applications", fixture.home, fixture.home + "/Library"]
    for path in roots {
      let outcome = await PlanService(homeDirectory: fixture.home).makeAvailableUserSelectionPlan(
        selections: [UserSelection(path: path)], kind: kind)
      #expect(outcome.plan == nil && outcome.rejections.first?.reason == .bulkRoot)
    }
  }

  @Test("Physical aliases of base directories stay protected while a symlink leaf remains selectable")
  func physicalBaseAliasAndLink() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let ownerHome = fixture.home + "/OwnerHome"
    try fixture.directory(ownerHome + "/Library")
    let alias = fixture.home + "/ParentAlias"
    try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.home)
    let service = PlanService(homeDirectory: ownerHome)
    for kind in [ActionKind.trash, .catalogDelete] {
      for path in [alias + "/OwnerHome", alias + "/OwnerHome/Library"] {
        let refused = await service.makeAvailableUserSelectionPlan(selections: [UserSelection(path: path)], kind: kind)
        #expect(refused.plan == nil && refused.rejections.first?.reason == .bulkRoot)
      }
    }
    let link = fixture.home + "/HomeLink"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: ownerHome)
    let allowed = await service.makeAvailableUserSelectionPlan(selections: [UserSelection(path: link)])
    #expect(allowed.rejections.isEmpty && allowed.plan?.items[0].inventory[0].identity?.kind == .symbolicLink)
  }

  @Test("Lighten itself remains protected for both methods without denying a link to it")
  func selfApplicationAndLink() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let app = fixture.home + "/LightenQA-self.app"
    try fixture.directory(app + "/Contents")
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": LightenIdentity.bundleIdentifier], format: .xml, options: 0
    ).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
    let service = PlanService(homeDirectory: fixture.home)
    for kind in [ActionKind.trash, .catalogDelete] {
      let result = await service.makeAvailableUserSelectionPlan(selections: [UserSelection(path: app)], kind: kind)
      #expect(result.plan == nil && result.rejections.first?.reason == .lightenItself)
    }
    let link = fixture.home + "/LightenQA-link.app"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: app)
    #expect(await service.makeAvailableUserSelectionPlan(selections: [UserSelection(path: link)]).plan != nil)
  }

  @Test("A serialized user-selection marker cannot grant private execution authority")
  func forgedMarkerHasNoAuthority() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let path = fixture.home + "/item"
    try fixture.write(path)
    let original = try await fixture.plan(path)
    let forged = ActionPlan(snapshotRunID: original.snapshotRunID, kind: .trash, items: original.items)
    await #expect(throws: ExecutionFailure.self) {
      try await ActionExecutor(
        journal: fixture.journal, trash: UserSelectionTrash(directory: fixture.trash),
        guardService: ActionGuard(homeDirectory: fixture.home)
      ).execute(forged)
    }
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(throws: GuardFailure.unsupportedItem) {
      try ActionGuard(homeDirectory: fixture.home).validate(original.items[0])
    }
  }

  @Test("Replacing a selected root in the final window refuses that root")
  func replacedRootRefused() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let path = fixture.home + "/item"
    try fixture.write(path)
    let plan = try await fixture.plan(path)
    let result = try await ActionExecutor(
      journal: fixture.journal, trash: UserSelectionTrash(directory: fixture.trash),
      guardService: ActionGuard(homeDirectory: fixture.home),
      beforeMutation: { _ in
        try FileManager.default.moveItem(atPath: path, toPath: path + "-original")
        try fixture.write(path, "replacement")
      }, applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items[0].outcome == .skipped)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "replacement")
  }

  @Test("Permanent removal requires its second confirmation and never follows a descendant symlink")
  func permanentConfirmationAndNoFollow() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let source = fixture.home + "/Chosen"
    let target = fixture.home + "/Outside"
    try fixture.write(target)
    try fixture.write(source + "/Nested.app/Contents/MacOS/tool")
    try fixture.write(source + "/Library/Keychains/key")
    try FileManager.default.createSymbolicLink(atPath: source + "/link", withDestinationPath: target)
    let plan = try await fixture.plan(source, kind: .catalogDelete)
    let executor = ActionExecutor(
      journal: fixture.journal, trash: UserSelectionTrash(directory: fixture.trash),
      guardService: ActionGuard(homeDirectory: fixture.home), applicationActivity: FixtureClearApplicationActivity())
    await #expect(throws: ExecutionFailure.self) { try await executor.execute(plan) }
    #expect(FileManager.default.fileExists(atPath: source))
    #expect(try await fixture.journal.readSummary().records.isEmpty)
    let result = try await executor.execute(
      plan, confirmation: IrreversibleConfirmation(planID: plan.id, method: .catalogDelete))
    #expect(result.items[0].outcome == .applied && result.items[0].deletedCount > 1)
    #expect(!FileManager.default.fileExists(atPath: source))
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "fixture")
    #expect(
      try await ActionHistory(journal: fixture.journal, homeDirectory: fixture.home).loadGroup(planID: plan.id).canUndo
        == false)
  }

  @Test("Helpers close only after the explicit close-and-remove flag")
  func confirmedApplicationClosing() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let source = fixture.home + "/Chosen"
    try fixture.write(source + "/Nested.app/Contents/MacOS/helper")
    let state = UserSelectionProcessState()
    let executor = ActionExecutor(
      journal: fixture.journal, trash: UserSelectionTrash(directory: fixture.trash),
      guardService: ActionGuard(homeDirectory: fixture.home),
      applicationActivity: UserSelectionActivity(state: state),
      applicationClosing: UserSelectionClosing(state: state))
    let first = try await fixture.plan(source)
    #expect(try await executor.execute(first).items[0].outcome == .skipped)
    #expect(state.confirmations.withLock { $0.isEmpty })
    let second = try await fixture.plan(source)
    #expect(try await executor.execute(second, closeRunningApplications: true).items[0].outcome == .applied)
    #expect(state.confirmations.withLock { $0 } == [true])
  }

  @Test("Confirmation conversion preserves UI correlation while removing prior heavy authority")
  func finalizedIdentityAndMethod() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let source = fixture.home + "/item"
    try fixture.write(source)
    let original = try await fixture.plan(source)
    let result = await PlanService(homeDirectory: fixture.home).finalizeUserSelection(
      plan: original, kind: .catalogDelete)
    let final = try #require(result.plan)
    #expect(final.id == original.id && final.items[0].id == original.items[0].id)
    #expect(final.kind == .catalogDelete && final.items[0].inventory.count == 1)
    try ActionGuard(homeDirectory: fixture.home).validate(final.items[0], plan: final)
    #expect(throws: ExecutionFailure.self) {
      try ActionGuard(homeDirectory: fixture.home).validate(original.items[0], plan: original)
    }
  }

  @Test("Changed or relocated Trash items remain visible and cannot be silently restored")
  func changedTrashHonesty() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let source = fixture.home + "/item"
    try fixture.write(source)
    let plan = try await fixture.plan(source)
    _ = try await ActionExecutor(
      journal: fixture.journal, trash: UserSelectionTrash(directory: fixture.trash),
      guardService: ActionGuard(homeDirectory: fixture.home), applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    try fixture.write(fixture.trash + "/item", "changed bytes")
    let history = ActionHistory(journal: fixture.journal, homeDirectory: fixture.home)
    let group = try await history.loadGroup(planID: plan.id)
    #expect(!group.canUndo && group.items[0].state == .uncertain)
    await #expect(throws: UndoFailure.changedTrashItem) {
      try await history.undo(planID: plan.id, itemID: plan.items[0].id)
    }
    #expect(!FileManager.default.fileExists(atPath: source))
  }

  @Test("Native closing includes nested helper executables and rejects changed PID or vnode bindings")
  func nativeHelperClosing() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let app = fixture.home + "/LightenQA-running.app"
    let paths = [app + "/Contents/MacOS/main", app + "/Contents/Helpers/LightenQA-helper.app/Contents/MacOS/helper"]
    var processes: [Process] = []
    defer {
      for process in processes {
        if process.isRunning {
          _ = kill(process.processIdentifier, SIGKILL)
        }
      }
    }
    for path in paths {
      try fixture.directory((path as NSString).deletingLastPathComponent)
      try FileManager.default.copyItem(atPath: "/bin/bash", toPath: path)
      // System shell signatures can be restricted to their original location.
      // Re-sign only our disposable copy before using it as a native executable fixture.
      let signer = Process()
      signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
      signer.arguments = ["--force", "--sign", "-", path]
      signer.environment = ["LC_ALL": "C", "LANG": "C"]
      try signer.run()
      defer {
        if signer.isRunning { _ = kill(signer.processIdentifier, SIGKILL) }
      }
      let signingDeadline = ContinuousClock.now + .seconds(3)
      while signer.isRunning && ContinuousClock.now < signingDeadline {
        try await Task.sleep(for: .milliseconds(25))
      }
      if signer.isRunning { _ = kill(signer.processIdentifier, SIGKILL) }
      try #require(!signer.isRunning, "Disposable executable signing timed out")
      try #require(signer.terminationStatus == 0, "Disposable executable signing failed")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: path)
      // A stopped sleep can still exit on TERM. Ignore TERM explicitly before
      // publishing readiness so only the confirmed force step can close these fixtures.
      process.arguments = ["-c", "trap '' TERM; : > \"$LIGHTEN_QA_READY_PATH\"; while :; do /bin/sleep 1; done"]
      process.environment = ["LC_ALL": "C", "LANG": "C", "LIGHTEN_QA_READY_PATH": path + ".ready"]
      try process.run()
      processes.append(process)
    }
    let readyDeadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < readyDeadline
      && !paths.allSatisfy({ FileManager.default.fileExists(atPath: $0 + ".ready") })
    {
      try await Task.sleep(for: .milliseconds(25))
    }
    let statuses = processes.map { $0.isRunning ? "running" : "exit \($0.terminationStatus)" }.joined(separator: ", ")
    try #require(
      paths.allSatisfy { FileManager.default.fileExists(atPath: $0 + ".ready") },
      "Fixture readiness failed: \(statuses)")
    try #require(processes.allSatisfy { $0.isRunning })
    var pointer: UnsafeMutablePointer<LightenApplicationProcess>?
    var count: UInt32 = 0
    let status = app.withCString { lighten_copy_application_processes($0, &pointer, &count) }
    defer { lighten_free_application_processes(pointer) }
    var diagnostic = ""
    if status != 0 {
      let unrelated = fixture.home + "/LightenQA-unrelated-observation"
      try fixture.directory(unrelated)
      diagnostic =
        "capture status: \(status), count: \(count); "
        + (await nativeCaptureFailureActivity(selectedRoot: app, unrelatedRoot: unrelated))
    }
    #expect(status == 0, "\(diagnostic)")
    let records = Array(UnsafeBufferPointer(start: pointer, count: Int(count)))
    #expect(Set(records.map(\.pid)) == Set(processes.map(\.processIdentifier)))
    var changedStart = try #require(records.first)
    changedStart.start_microseconds += 1
    #expect(lighten_signal_application_process(&changedStart, SIGTERM) == -1)
    var changedVnode = try #require(records.first)
    changedVnode.executable_inode += 1
    #expect(lighten_signal_application_process(&changedVnode, SIGTERM) == -1)
    #expect(processes.allSatisfy { $0.isRunning })
    await #expect(throws: ProcessActivityFailure.self) {
      try await NativeUserSelectionApplicationClosing().closeApplications(rootPath: app, forceAfterGraceful: false)
    }
    #expect(processes.allSatisfy { $0.isRunning })
    try await NativeUserSelectionApplicationClosing().closeApplications(rootPath: app, forceAfterGraceful: true)
    let exitedDeadline = ContinuousClock.now + .seconds(3)
    while processes.contains(where: { $0.isRunning }) && ContinuousClock.now < exitedDeadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(processes.allSatisfy { !$0.isRunning })
  }

  @Test("Unlinked executable mappings remain scoped and incomplete observations never authorize signals")
  func nativeUnlinkedExecutableActivity() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let app = fixture.home + "/LightenQA-unlinked.app"
    let path = app + "/Contents/MacOS/helper"
    let unrelated = fixture.home + "/LightenQA-unrelated"
    try fixture.directory((path as NSString).deletingLastPathComponent)
    try fixture.directory(unrelated)
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path)
    let signer = Process()
    signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signer.arguments = ["--force", "--sign", "-", path]
    signer.environment = ["LC_ALL": "C", "LANG": "C"]
    try signer.run()
    defer { if signer.isRunning { _ = kill(signer.processIdentifier, SIGKILL) } }
    let signingDeadline = ContinuousClock.now + .seconds(3)
    while signer.isRunning && ContinuousClock.now < signingDeadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    if signer.isRunning { _ = kill(signer.processIdentifier, SIGKILL) }
    try #require(!signer.isRunning && signer.terminationStatus == 0)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["30"]
    process.environment = ["LC_ALL": "C", "LANG": "C"]
    try process.run()
    defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
    var pointer: UnsafeMutablePointer<LightenApplicationProcess>?
    var count: UInt32 = 0
    let captured = app.withCString { lighten_copy_application_processes($0, &pointer, &count) }
    defer { lighten_free_application_processes(pointer) }
    var diagnostic = ""
    if captured != 0 || count != 1 {
      diagnostic =
        "capture status: \(captured), count: \(count); "
        + (await nativeCaptureFailureActivity(selectedRoot: app, unrelatedRoot: unrelated))
    }
    try #require(captured == 0 && count == 1, "\(diagnostic)")
    var original = try #require(pointer?.pointee)
    try #require(original.pid == process.processIdentifier)
    // Removing this exact owned leaf reproduces an updater's detached image.
    try FileManager.default.removeItem(atPath: path)
    #expect(!FileManager.default.fileExists(atPath: path))
    var incompletePointer: UnsafeMutablePointer<LightenApplicationProcess>?
    var incompleteCount: UInt32 = 0
    let incomplete = app.withCString {
      lighten_copy_application_processes($0, &incompletePointer, &incompleteCount)
    }
    defer { lighten_free_application_processes(incompletePointer) }
    #expect(incomplete == -1)
    #expect(incompletePointer == nil && incompleteCount == 0)
    #expect(app.withCString { lighten_application_mapping_activity(process.processIdentifier, $0, 4096) } == 1)
    #expect(unrelated.withCString { lighten_application_mapping_activity(process.processIdentifier, $0, 4096) } == 0)
    #expect(unrelated.withCString { lighten_application_mapping_activity(process.processIdentifier, $0, 1) } == -1)
    #expect(unrelated.withCString { lighten_application_mapping_activity(process.processIdentifier, $0, 0) } == -1)
    #expect(unrelated.withCString { lighten_application_mapping_activity(process.processIdentifier, $0, 4097) } == -1)
    #expect(unrelated.withCString { lighten_application_mapping_activity(0, $0, 4096) } == -1)
    #expect(lighten_application_mapping_activity(process.processIdentifier, "relative", 4096) == -1)
    let source = NativeApplicationActivitySource()
    #expect(await source.activity(applicationPath: app).state == .active)
    #expect(await source.activity(applicationPath: unrelated).state == .clearObservedProcesses)
    #expect(lighten_signal_application_process(&original, SIGTERM) == -1)
    #expect(process.isRunning)
    await #expect(throws: ProcessActivityFailure.self) {
      try await NativeUserSelectionApplicationClosing().closeApplications(rootPath: app, forceAfterGraceful: true)
    }
    #expect(process.isRunning)
  }

  @Test("A throwing Trash call after moving remains uncertain and cannot claim success")
  func unverifiedMoveRemainsUncertain() async throws {
    let fixture = try UserSelectionFixture()
    defer { fixture.cleanup() }
    let source = fixture.home + "/item"
    try fixture.write(source)
    let plan = try await fixture.plan(source)
    let result = try await ActionExecutor(
      journal: fixture.journal, trash: UserSelectionUnverifiedTrash(directory: fixture.trash),
      guardService: ActionGuard(homeDirectory: fixture.home), applicationActivity: FixtureClearApplicationActivity()
    ).execute(plan)
    #expect(result.items[0].outcome == .uncertain && result.items[0].mutationStage == .trashCallUnverified)
    #expect(!(try await fixture.journal.readSummary().records).contains { $0.kind == .applied })
    #expect(
      try await ActionHistory(journal: fixture.journal, homeDirectory: fixture.home).loadGroup(planID: plan.id).state
        == .uncertain)
  }
}
