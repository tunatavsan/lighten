import Darwin
import Foundation
import LightenKit
import Testing

@Suite("Space hierarchy and area")
struct SpaceTests {
  @Test("Volume free and used distinguish valid, missing, and inconsistent readings")
  func volumeMeasure() {
    let known = VolumeMeasure(path: "/", totalBytes: 100, freeBytes: 30)
    #expect(known.usedBytes == 70)
    #expect(known.freeBytes == 30)
    #expect(VolumeMeasure(path: "/", totalBytes: 100, freeBytes: nil).usedBytes == nil)
    #expect(VolumeMeasure(path: "/", totalBytes: 100, freeBytes: 110).usedBytes == nil)
  }

  private func fixtureDirectory() throws -> URL {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
      throw SpaceFailure.missingRoot
    }
    defer { free(resolved) }
    let directory = URL(fileURLWithPath: String(cString: resolved))
      .appending(path: "lighten-space-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test("Treemap tile area follows bytes and exactly partitions the viewport")
  func proportionalArea() {
    let ids = (0..<25).map { _ in UUID() }
    let sizes: [Int64] = [1, 4, 9] + (1..<23).map { Int64($0 + 10) }
    let values = zip(ids, sizes).map { ($0.0, $0.1) }
    let layout = Treemap.layout(values: values, width: 900, height: 600)
    #expect(layout.tiles.count == 25)
    let byID = Dictionary(uniqueKeysWithValues: layout.tiles.map { ($0.id, $0) })
    let a = byID[ids[0]]!.area
    let b = byID[ids[1]]!.area
    let c = byID[ids[2]]!.area
    #expect(abs(b / a - 4) < 1e-9)
    #expect(abs(c / a - 9) < 1e-9)
    #expect(abs(layout.tiles.reduce(0) { $0 + $1.area } - 900 * 600) < 1e-6)
    for tile in layout.tiles {
      #expect(tile.x >= -1e-8 && tile.y >= -1e-8)
      #expect(tile.x + tile.width <= 900 + 1e-8)
      #expect(tile.y + tile.height <= 600 + 1e-8)
    }
    for i in layout.tiles.indices {
      for j in layout.tiles.indices where j > i {
        let first = layout.tiles[i]
        let second = layout.tiles[j]
        let overlapX = max(0, min(first.x + first.width, second.x + second.width) - max(first.x, second.x))
        let overlapY = max(0, min(first.y + first.height, second.y + second.height) - max(first.y, second.y))
        #expect(overlapX * overlapY < 1e-7)
      }
    }
    #expect(Treemap.layout(values: values, width: 900, height: 600).tiles == layout.tiles)
    #expect(Treemap.layout(values: [(UUID(), 0)], width: 900, height: 600).tiles.isEmpty)
  }

  @Test("Equal sizes keep the caller's stable path and ID order")
  func equalSizeOrder() {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let values: [(UUID, Int64)] = [(second, 10), (first, 10), (third, 0)]
    let tiles = Treemap.layout(values: values, width: 100, height: 60).tiles
    #expect(tiles.map(\.id) == [second, first])
    #expect(abs(tiles.reduce(0) { $0 + $1.area } - 6000) < 1e-9)
  }

  @Test("Extreme byte totals do not overflow or create negative rectangles")
  func extremeBytes() {
    let values: [(UUID, Int64)] = [
      (UUID(), Int64.max), (UUID(), Int64.max), (UUID(), 1),
    ]
    let tiles = Treemap.layout(values: values, width: 900, height: 600).tiles
    #expect(tiles.count == 3)
    #expect(
      tiles.allSatisfy {
        $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite
          && $0.width >= 0 && $0.height >= 0
      })
    #expect(Treemap.layout(values: values, width: 0, height: 600).tiles.isEmpty)
    #expect(Treemap.layout(values: values, width: .infinity, height: 600).tiles.isEmpty)
  }

  @Test("Equal-size siblings sort by path before treemap layout")
  func equalSizePathOrder() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(repeating: 1, count: 10).write(to: directory.appending(path: "zeta"))
    try Data(repeating: 2, count: 10).write(to: directory.appending(path: "alpha"))
    let snapshot = try await ScanService().scan(rootPath: directory.path)
    let index = try SpaceIndex(snapshot: snapshot)
    let children = index.sortedChildren(of: index.rootID, metric: .logical)
    #expect(children.map(\.name) == ["alpha", "zeta"])
    let tiles = Treemap.layout(
      values: children.map { ($0.id, $0.logical.knownLowerBound) },
      width: 100, height: 60
    ).tiles
    #expect(tiles.map(\.id) == children.map(\.id))
  }

  @Test("Other keeps all children and breadcrumb ties to the same snapshot")
  func hierarchy() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let nested = directory.appending(path: "nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    for index in 0..<30 {
      try Data(repeating: UInt8(index), count: index + 1)
        .write(to: directory.appending(path: "file-\(index)"))
    }
    try Data(repeating: 1, count: 5).write(to: nested.appending(path: "child"))
    let snapshot = try await ScanService().scan(rootPath: directory.path)
    let index = try SpaceIndex(snapshot: snapshot)
    let group = index.group(at: index.rootID, metric: .logical)
    #expect(group.items.count == 24)
    #expect(group.other.count == 7)
    #expect(group.items.count + group.other.count == index.children[index.rootID]?.count)
    #expect(
      group.otherBytes.completeTotal
        == group.other.reduce(0) {
          $0 + $1.logical.knownLowerBound
        })
    let nestedItem = try #require(
      index.sortedChildren(of: index.rootID, metric: .logical)
        .first(where: { $0.name == "nested" }))
    #expect(index.breadcrumb(to: nestedItem.id).map(\.id) == [index.rootID, nestedItem.id])
    #expect(index.runID == snapshot.runID)
    #expect(index.items[index.rootID]?.canSelect == false)
  }

  @Test("A zero file is known and a skipped link is unknown")
  func zeroVsUnknown() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    FileManager.default.createFile(atPath: directory.appending(path: "zero").path, contents: Data())
    try FileManager.default.createSymbolicLink(
      at: directory.appending(path: "link"), withDestinationURL: directory.appending(path: "zero"))
    let snapshot = try await ScanService().scan(rootPath: directory.path)
    let index = try SpaceIndex(snapshot: snapshot)
    let children = index.sortedChildren(of: index.rootID, metric: .logical)
    let zero = try #require(children.first { $0.name == "zero" })
    let link = try #require(children.first { $0.name == "link" })
    #expect(zero.logical.completeTotal == 0)
    #expect(link.logical.completeTotal == nil)
    #expect(!link.canSelect)
  }
}
