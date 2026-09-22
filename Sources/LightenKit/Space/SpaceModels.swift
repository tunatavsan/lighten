import Foundation

public enum SpaceMetric: String, CaseIterable, Sendable {
  case logical, allocated
}

public struct SpaceItem: Sendable, Identifiable {
  public let id: UUID
  public let parentID: UUID?
  public let path: String
  public let kind: EntryKind?
  public let logical: ByteAggregate
  public let allocated: ByteAggregate
  public let issues: [ScanIssue]
  public let partial: Bool
  public let protected: Bool
  public let childCount: Int

  public var name: String { URL(fileURLWithPath: path).lastPathComponent }
  public var canInspect: Bool { kind == .directory && childCount > 0 }
  public var canSelect: Bool {
    parentID != nil && !partial && !protected && issues.isEmpty
      && (kind == .regular || kind == .directory)
  }
  public func bytes(_ metric: SpaceMetric) -> ByteAggregate {
    metric == .logical ? logical : allocated
  }
}

public struct SpaceGroup: Sendable {
  public let items: [SpaceItem]
  public let other: [SpaceItem]
  public let otherBytes: ByteAggregate
}

/// Immutable, indexed projection. Construct outside the UI actor for large scans.
public struct SpaceIndex: Sendable {
  public let runID: UUID
  public let rootID: UUID
  public let items: [UUID: SpaceItem]
  public let children: [UUID: [UUID]]
  private let logicalOrder: [UUID: [UUID]]
  private let allocatedOrder: [UUID: [UUID]]
  private let logicalGroups: [UUID: SpaceGroup]
  private let allocatedGroups: [UUID: SpaceGroup]

  public init(snapshot: ScanSnapshot) throws {
    guard let root = snapshot.entries.first(where: { $0.parentID == nil }) else {
      throw SpaceFailure.missingRoot
    }
    var childIDs: [UUID: [UUID]] = [:]
    for entry in snapshot.entries {
      if let parent = entry.parentID { childIDs[parent, default: []].append(entry.id) }
    }
    let nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
    var projected: [UUID: SpaceItem] = [:]
    projected.reserveCapacity(snapshot.entries.count)
    for entry in snapshot.entries {
      guard let node = nodes[entry.id] else { continue }
      projected[entry.id] = SpaceItem(
        id: entry.id, parentID: entry.parentID, path: entry.path,
        kind: entry.identity?.kind, logical: node.logical, allocated: node.allocated,
        issues: entry.issues, partial: node.partial, protected: node.protected,
        childCount: childIDs[entry.id]?.count ?? 0)
    }
    self.runID = snapshot.runID
    self.rootID = root.id
    self.items = projected
    self.children = childIDs
    func ordered(_ metric: SpaceMetric) -> [UUID: [UUID]] {
      childIDs.mapValues { ids in
        ids.sorted { leftID, rightID in
          guard let left = projected[leftID], let right = projected[rightID] else {
            return leftID.uuidString < rightID.uuidString
          }
          let leftBytes = left.bytes(metric).knownLowerBound
          let rightBytes = right.bytes(metric).knownLowerBound
          if leftBytes != rightBytes { return leftBytes > rightBytes }
          if left.path != right.path { return left.path < right.path }
          return leftID.uuidString < rightID.uuidString
        }
      }
    }
    let logicalOrder = ordered(.logical)
    let allocatedOrder = ordered(.allocated)
    self.logicalOrder = logicalOrder
    self.allocatedOrder = allocatedOrder
    func groups(_ order: [UUID: [UUID]], metric: SpaceMetric) -> [UUID: SpaceGroup] {
      order.mapValues { ids in
        let top = ids.prefix(24).compactMap { projected[$0] }
        let rest = ids.dropFirst(24).compactMap { projected[$0] }
        let sum = rest.reduce(Int64(0)) { partial, item in
          let (value, overflow) = partial.addingReportingOverflow(
            max(0, item.bytes(metric).knownLowerBound))
          return overflow ? Int64.max : value
        }
        let complete = rest.allSatisfy { $0.bytes(metric).completeTotal != nil }
        return SpaceGroup(
          items: top, other: rest,
          otherBytes: ByteAggregate(knownLowerBound: sum, completeTotal: complete ? sum : nil))
      }
    }
    self.logicalGroups = groups(logicalOrder, metric: .logical)
    self.allocatedGroups = groups(allocatedOrder, metric: .allocated)
  }

  public func sortedChildren(of id: UUID, metric: SpaceMetric) -> [SpaceItem] {
    let ids = metric == .logical ? logicalOrder[id] : allocatedOrder[id]
    return (ids ?? []).compactMap { items[$0] }
  }

  public func group(at id: UUID, metric: SpaceMetric, limit: Int = 24) -> SpaceGroup {
    if limit == 24 {
      return (metric == .logical ? logicalGroups[id] : allocatedGroups[id])
        ?? SpaceGroup(
          items: [], other: [], otherBytes: ByteAggregate(knownLowerBound: 0, completeTotal: 0))
    }
    let sorted = sortedChildren(of: id, metric: metric)
    let front = Array(sorted.prefix(max(0, limit)))
    let rest = Array(sorted.dropFirst(max(0, limit)))
    let sum = rest.reduce(Int64(0)) { partial, item in
      let (value, overflow) = partial.addingReportingOverflow(
        max(0, item.bytes(metric).knownLowerBound))
      return overflow ? Int64.max : value
    }
    let complete = rest.allSatisfy { $0.bytes(metric).completeTotal != nil }
    return SpaceGroup(
      items: front, other: rest,
      otherBytes: ByteAggregate(knownLowerBound: sum, completeTotal: complete ? sum : nil))
  }

  public func breadcrumb(to id: UUID) -> [SpaceItem] {
    var path: [SpaceItem] = []
    var cursor: UUID? = id
    while let current = cursor, let item = items[current] {
      path.append(item)
      cursor = item.parentID
    }
    return path.reversed()
  }
}

public enum SpaceFailure: Error, Sendable { case missingRoot }

public struct VolumeMeasure: Sendable {
  public let path: String
  public let totalBytes: Int64?
  public let freeBytes: Int64?
  public let usedBytes: Int64?

  public init(path: String, totalBytes: Int64?, freeBytes: Int64?) {
    self.path = path
    self.totalBytes = totalBytes
    self.freeBytes = freeBytes
    if let totalBytes, let freeBytes, totalBytes >= freeBytes {
      self.usedBytes = totalBytes - freeBytes
    } else {
      self.usedBytes = nil
    }
  }
}

public enum VolumeMeasurer {
  public static func measure(path: String) async -> VolumeMeasure {
    await Task.detached {
      let url = URL(fileURLWithPath: path)
      let values = try? url.resourceValues(forKeys: [
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
      ])
      return VolumeMeasure(
        path: path,
        totalBytes: values?.volumeTotalCapacity.map(Int64.init),
        freeBytes: values?.volumeAvailableCapacity.map(Int64.init))
    }.value
  }
}
