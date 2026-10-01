import Darwin
import Foundation
import LightenKit
import Testing

@testable import Lighten

private enum GateFailure: Error { case injected }

private struct DuplicateFixtureApplicationActivity: ApplicationActivitySource {
  func activity(applicationPath: String) async -> ApplicationActivity {
    ApplicationActivity(state: .clearObservedProcesses)
  }
}

private struct LocalDuplicateMover: TrashMoving {
  let destination: String

  func moveToTrash(path: String) async throws -> String {
    let target = destination + "/" + URL(fileURLWithPath: path).lastPathComponent
    try FileManager.default.moveItem(atPath: path, toPath: target)
    return target
  }
}

private actor PlanGate {
  private var requests: [CheckedContinuation<ActionPlan, Error>] = []
  private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
  private var received = 0

  func next() async throws -> ActionPlan {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(continuation)
      received += 1
      let ready = waiting.filter { received >= $0.0 }
      waiting.removeAll { received >= $0.0 }
      for (_, waiter) in ready { waiter.resume() }
    }
  }

  func waitForRequest(_ count: Int) async {
    if received >= count { return }
    await withCheckedContinuation { waiting.append((count, $0)) }
  }

  func finish(_ result: Result<ActionPlan, Error>) {
    guard !requests.isEmpty else { return }
    requests.removeFirst().resume(with: result)
  }
}

@Test("Stale duplicate preparation cannot present a result or error")
@MainActor func staleDuplicatePreparationIsDiscarded() async throws {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw GateFailure.injected }
  defer { free(resolved) }
  let root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: root) }
  for name in ["a", "b"] {
    try Data("same".utf8).write(to: URL(fileURLWithPath: root + "/" + name))
  }
  var report: DuplicateReport?
  for try await event in DuplicateService().events(rootPath: root) {
    if case .completed(let value) = event { report = value }
  }
  let found = try #require(report)
  let group = try #require(found.groups.first)
  let keeper = try #require(group.members.first)
  let target = try #require(group.members.first { $0.id != keeper.id })
  let validPlan = try await DuplicateService().makePlan(
    report: found, groupID: group.id, keeperID: keeper.id, targetIDs: [target.id])
  let gate = PlanGate()
  let store = DuplicateStore(planBuilder: { _, _ in try await gate.next() })
  let trashDirectory = root + "/trash"
  try FileManager.default.createDirectory(atPath: trashDirectory, withIntermediateDirectories: true)
  let actions = ActionStore(
    journal: JSONLActionJournal(path: root + "/journal.jsonl"),
    trash: LocalDuplicateMover(destination: trashDirectory),
    applicationActivity: DuplicateFixtureApplicationActivity())
  store.report = found
  store.chooseKeeper(keeper.id, for: group, actions: actions)
  store.toggleTarget(target.id, in: group, actions: actions)

  let staleResult = Task { await store.prepare(actions: actions) }
  await gate.waitForRequest(1)
  store.toggleTarget(target.id, in: group, actions: actions)
  store.toggleTarget(target.id, in: group, actions: actions)
  await gate.finish(.success(validPlan))
  await staleResult.value
  #expect(actions.pending == nil)
  #expect(store.message == nil)
  #expect(!store.preparing)

  let staleError = Task { await store.prepare(actions: actions) }
  await gate.waitForRequest(2)
  store.deactivate(actions: actions)
  await gate.finish(.failure(GateFailure.injected))
  await staleError.value
  #expect(actions.pending == nil)
  #expect(store.message == nil)

  let latest = Task { await store.prepare(actions: actions) }
  await gate.waitForRequest(3)
  await gate.finish(.success(validPlan))
  await latest.value
  #expect(actions.pending?.plan == validPlan)
  #expect(store.presentedPlanID == validPlan.id)

  let presentation = try #require(actions.pending)
  let confirmed = try #require(actions.takeConfirmedPlan(presentation))
  store.deactivate(actions: actions)
  #expect(store.presentedPlanID == validPlan.id)
  await actions.executeConfirmed(confirmed)
  #expect(actions.result?.items.map(\.outcome) == [.applied])
  store.observeResult(actions: actions)
  #expect(!store.needsRescan)
  #expect(store.targets.isEmpty)
  #expect(store.keepers.isEmpty)
  #expect(store.presentedPlanID == validPlan.id)
  #expect(actions.pending == nil)
}
