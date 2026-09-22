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

  @MainActor @Test("Other maps only remaining items and back rejects its stale layout")
  func otherLayoutAndBack() async throws {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
      Issue.record("temporary fixture root unavailable")
      return
    }
    defer { free(resolved) }
    let root = String(cString: resolved) + "/lighten-other-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    for number in 1...31 {
      try Data(repeating: UInt8(number), count: number).write(
        to: URL(fileURLWithPath: root + "/item-\(number).bin"))
    }

    let snapshot = try await ScanService().scan(rootPath: root)
    let index = try SpaceIndex(snapshot: snapshot)
    let group = index.group(at: index.rootID, metric: .logical)
    #expect(group.items.count == 24)
    #expect(group.other.count == 7)
    let store = SpaceStore()
    store.selectedRoot = URL(fileURLWithPath: root)
    store.snapshot = snapshot
    store.index = index
    store.currentID = index.rootID
    store.updateLayout(width: 400, height: 300)
    let top = try await waitForLayout(store)
    #expect(Set(top.tiles.map(\.id)) == Set(group.items.map(\.id) + [SpaceView.otherID]))

    store.selectedID = group.items.first?.id
    store.showOther()
    #expect(store.selectedID == nil)
    #expect(store.layout == nil)
    store.updateLayout(width: 400, height: 300)
    let other = try await waitForLayout(store)
    #expect(Set(other.tiles.map(\.id)) == Set(group.other.map(\.id)))
    let first = try #require(group.other.first)
    let last = try #require(group.other.last)
    let firstArea = try #require(other.tiles.first(where: { $0.id == first.id })?.area)
    let lastArea = try #require(other.tiles.first(where: { $0.id == last.id })?.area)
    #expect(
      abs(firstArea / lastArea - Double(first.logical.knownLowerBound) / Double(last.logical.knownLowerBound))
        < 0.000001)

    store.back()
    #expect(!store.showingOther)
    #expect(store.layout == nil)
    store.showOther()
    store.updateLayout(width: 400, height: 300)
    store.back()
    store.updateLayout(width: 400, height: 300)
    let returned = try await waitForLayout(store)
    #expect(Set(returned.tiles.map(\.id)) == Set(top.tiles.map(\.id)))
    try await Task.sleep(for: .milliseconds(30))
    #expect(Set(store.layout?.tiles.map(\.id) ?? []) == Set(top.tiles.map(\.id)))
  }

  @MainActor private func waitForLayout(_ store: SpaceStore) async throws -> TreemapLayout {
    for _ in 0..<100 {
      if let layout = store.layout { return layout }
      try await Task.sleep(for: .milliseconds(10))
    }
    return try #require(store.layout)
  }
}
