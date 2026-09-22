import Darwin
import Foundation
import LightenKit
import Testing

@testable import Lighten

@Suite("Space scan state")
struct SpaceStoreTests {
  private actor RecordingMover: TrashMoving {
    let destination: String
    private(set) var moves = 0

    init(destination: String) { self.destination = destination }

    func moveToTrash(path: String) async throws -> String {
      moves += 1
      try FileManager.default.moveItem(atPath: path, toPath: destination)
      return destination
    }
  }

  @MainActor @Test("Confirmed plan executes once after the sheet clears pending state")
  func confirmationSurvivesDismissal() async throws {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
      Issue.record("temporary fixture root unavailable")
      return
    }
    defer { free(resolved) }
    let container = String(cString: resolved) + "/lighten-confirm-" + UUID().uuidString
    let root = container + "/source"
    let source = root + "/inside.bin"
    let destination = container + "/returned.bin"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: container) }
    try Data(repeating: 7, count: 128).write(to: URL(fileURLWithPath: source))

    let snapshot = try await ScanService().scan(rootPath: root)
    let index = try SpaceIndex(snapshot: snapshot)
    let item = try #require(index.sortedChildren(of: index.rootID, metric: .logical).first)
    let plan = try await PlanService().makePlanAsync(snapshot: snapshot, selectedIDs: [item.id])
    let mover = RecordingMover(destination: destination)
    let store = ActionStore(
      journal: JSONLActionJournal(path: container + "/journal/actions-v1.jsonl"),
      trash: mover)
    store.add(item, snapshot: snapshot)
    store.present(
      plan: plan,
      items: [
        ActionItemSummary(
          id: item.id, label: item.name, path: item.path, reason: "test selection",
          logicalBytes: item.logical.completeTotal,
          allocatedBytes: item.allocated.completeTotal)
      ])
    let presentation = try #require(store.pending)
    let confirmed = try #require(store.takeConfirmedPlan(presentation))
    store.pending = nil  // SwiftUI's sheet dismissal clears its binding.
    #expect(store.takeConfirmedPlan(presentation) == nil)
    let altered = ActionPlan(
      id: confirmed.id, snapshotRunID: confirmed.snapshotRunID,
      kind: .trash, createdAt: confirmed.createdAt, items: [])
    await store.executeConfirmed(altered)
    #expect(await mover.moves == 0)
    await store.executeConfirmed(confirmed)
    #expect(await mover.moves == 1)
    #expect(store.result?.items.map(\.outcome) == [.applied])
    #expect(store.basket.isEmpty)
    #expect(FileManager.default.fileExists(atPath: destination))
    #expect(!FileManager.default.fileExists(atPath: source))
    await store.executeConfirmed(confirmed)
    #expect(await mover.moves == 1)
  }

  private struct SlowAttributes: FileAttributeSource {
    func volumeID(at path: String) async throws -> UUID? { UUID() }
    func inspect(at path: String) async throws -> FileAttributes {
      try await Task.sleep(for: .seconds(5))
      return FileAttributes(
        identity: FileIdentity(
          device: 1, inode: 1, changeSeconds: 1, changeNanoseconds: 0,
          logicalBytes: 0, allocatedBytes: 0, linkCount: 1, flags: 0, kind: .directory),
        readable: true)
    }
    func children(at path: String, expected: FileIdentity) async throws -> [String] { [] }
  }

  @MainActor @Test("A stale scan callback cannot cancel or overwrite a newer scan")
  func staleCallback() async throws {
    let store = SpaceStore(scanService: ScanService(attributes: SlowAttributes()))
    // A nonexistent root keeps the test free of user-file traversal.
    store.selectRoot(URL(fileURLWithPath: "/private/var/empty/lighten-\(UUID())"))
    store.startScan()
    let previous = try #require(store.currentScanRunID)
    store.startScan()
    #expect(previous != store.currentScanRunID)
    store.applyCancellation(root: store.selectedRoot.path, runID: previous)
    store.applyError("stale", root: store.selectedRoot.path, runID: previous)
    store.applyProgress(999, path: "stale", root: store.selectedRoot.path, runID: previous)
    try await Task.sleep(for: .milliseconds(30))
    #expect(store.phase == .scanning)
    #expect(store.progressCount == 0)
    store.cancel()
  }
}
