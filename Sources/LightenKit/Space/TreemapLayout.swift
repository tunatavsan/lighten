import Foundation

public struct TreemapTile: Sendable, Identifiable, Equatable {
  public let id: ScanItemID
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public var area: Double { width * height }
}

public struct TreemapLayout: Sendable {
  public let tiles: [TreemapTile]
  public let width: Double
  public let height: Double
}

/// Squarified treemap without per-tile padding or minimum-area distortion.
/// Input order breaks equal-byte ties; callers supply stable path/ID order.
public enum Treemap {
  public static func layout(
    values: [(ScanItemID, Int64)], width: Double, height: Double
  ) -> TreemapLayout {
    guard width.isFinite, height.isFinite, width > 0, height > 0 else {
      return TreemapLayout(tiles: [], width: width, height: height)
    }
    let sorted = values.enumerated().filter { $0.element.1 > 0 }.sorted {
      if $0.element.1 != $1.element.1 { return $0.element.1 > $1.element.1 }
      return $0.offset < $1.offset
    }
    guard !sorted.isEmpty else {
      return TreemapLayout(tiles: [], width: width, height: height)
    }
    let total = sorted.reduce(0.0) { $0 + Double($1.element.1) }
    let scale = width * height / total
    let entries = sorted.map { (id: $0.element.0, area: Double($0.element.1) * scale) }
    var remaining = Rect(x: 0, y: 0, width: width, height: height)
    var row: [(id: ScanItemID, area: Double)] = []
    var tiles: [TreemapTile] = []
    for entry in entries {
      let candidate = row + [entry]
      let shortSide = min(remaining.width, remaining.height)
      if row.isEmpty || worst(candidate, shortSide: shortSide) <= worst(row, shortSide: shortSide) {
        row = candidate
      } else {
        append(row, to: &tiles, in: &remaining, final: false)
        row = [entry]
      }
    }
    append(row, to: &tiles, in: &remaining, final: true)
    return TreemapLayout(tiles: tiles, width: width, height: height)
  }

  private struct Rect {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
  }

  private static func worst(_ row: [(id: ScanItemID, area: Double)], shortSide: Double) -> Double {
    guard !row.isEmpty, shortSide > 0 else { return .infinity }
    let sum = row.reduce(0) { $0 + $1.area }
    let largest = row.map(\.area).max()!
    let smallest = row.map(\.area).min()!
    return max(
      shortSide * shortSide * largest / (sum * sum),
      sum * sum / (shortSide * shortSide * smallest))
  }

  private static func append(
    _ row: [(id: ScanItemID, area: Double)], to tiles: inout [TreemapTile],
    in remaining: inout Rect, final: Bool
  ) {
    guard !row.isEmpty else { return }
    guard remaining.width > 0, remaining.height > 0 else {
      // A ratio smaller than the viewport's floating-point precision has no
      // drawable area. Keep its identity without enlarging or overlapping it.
      for entry in row {
        tiles.append(TreemapTile(id: entry.id, x: remaining.x, y: remaining.y, width: 0, height: 0))
      }
      return
    }
    let rowArea = row.reduce(0) { $0 + $1.area }
    if remaining.width >= remaining.height {
      let stripWidth = final ? remaining.width : min(remaining.width, rowArea / remaining.height)
      var y = remaining.y
      for (index, entry) in row.enumerated() {
        let tileHeight =
          index == row.count - 1
          ? remaining.y + remaining.height - y : entry.area / stripWidth
        tiles.append(
          TreemapTile(
            id: entry.id, x: remaining.x, y: y,
            width: stripWidth, height: max(0, tileHeight)))
        y += tileHeight
      }
      remaining.x += stripWidth
      remaining.width -= stripWidth
    } else {
      let stripHeight = final ? remaining.height : min(remaining.height, rowArea / remaining.width)
      var x = remaining.x
      for (index, entry) in row.enumerated() {
        let tileWidth =
          index == row.count - 1
          ? remaining.x + remaining.width - x : entry.area / stripHeight
        tiles.append(
          TreemapTile(
            id: entry.id, x: x, y: remaining.y,
            width: max(0, tileWidth), height: stripHeight))
        x += tileWidth
      }
      remaining.y += stripHeight
      remaining.height -= stripHeight
    }
  }
}
