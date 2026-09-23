import Foundation
import Synchronization

public enum NodeKind: UInt8, Sendable, Codable {
  case directory, package, file, symlink, other, smallFiles, systemVolume
}

/// Why a value is only a lower bound, or why an item was not traversed.
public enum PartialReason: UInt8, Sendable, Codable {
  case unreadable, mountBoundary, cloudNotMeasured, protectedNotTraversed, entryError, changedDuringScan,
    cancelled, descendant
}

/// Presentation state of one item. Values of a non-`complete` item are lower bounds.
public enum ItemState: Sendable, Equatable {
  case measuring
  case complete
  case partial(PartialReason)
  /// NeverRule area: summed from metadata only; no children, no drill, no action.
  case protectedMetadataOnly(ruleID: String)
}

public struct ScanItemID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let node: Int32
  /// -1: the node itself, -2: the small-files summary of `node`, ≥ 0: a file slot.
  public let slot: Int32

  public init(node: Int32, slot: Int32 = -1) {
    self.node = node
    self.slot = slot
  }

  public var isNode: Bool { slot == -1 }
  public var description: String { "\(node).\(slot)" }
}

/// Immutable row handed to the UI.
public struct SpaceItem: Sendable, Identifiable, Equatable {
  public let id: ScanItemID
  public let parentID: ScanItemID?
  public let name: String
  public let path: String
  public let kind: NodeKind
  public let logical: ByteAggregate
  public let allocated: ByteAggregate
  public let itemCount: Int64
  public let state: ItemState
  public let childCount: Int
  public let device: UInt64
  public let inode: UInt64
  /// Number of files folded into a small-files summary.
  public let summarizedFiles: Int64

  public var partial: Bool {
    if case .complete = state { return false }
    if case .protectedMetadataOnly = state { return logical.completeTotal == nil }
    return true
  }
  public var isProtected: Bool {
    if case .protectedMetadataOnly = state { return true }
    return false
  }
  public var canInspect: Bool { kind == .directory && childCount > 0 && !isProtected }
  /// Whether the item may enter the basket. Planning re-derives every fact from
  /// a fresh exact inventory and can still refuse with a reason.
  public var canSelect: Bool {
    guard parentID != nil, !isProtected else { return false }
    switch kind {
    case .directory, .package, .file: break
    case .symlink, .other, .smallFiles, .systemVolume: return false
    }
    if case .partial(let reason) = state {
      switch reason {
      case .unreadable, .mountBoundary, .cloudNotMeasured, .protectedNotTraversed, .changedDuringScan:
        return false
      case .entryError, .cancelled, .descendant: break
      }
    }
    return true
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

/// Compact, lock-protected scan tree. Nodes are directories, packages and
/// non-traversed folders; each directory keeps its largest files and a summary.
public final class ScanTree: Sendable {
  public static let filesPerDirectory = 32

  struct FileRecord {
    var name: String
    var logical: Int64
    var allocated: Int64
    var kind: NodeKind
    var protectedRule: String?
    var inode: UInt64
    var error: Bool
  }

  enum Lifecycle: UInt8 { case pending, reading, done }

  struct Node {
    var name: String
    var pathOverride: String?
    var parent: Int32
    var kind: NodeKind
    var lifecycle: Lifecycle = .pending
    var protectedRule: String?
    var ownReason: PartialReason?
    var partialDescendant = false
    var pending: Int32 = 0
    var device: UInt64
    var inode: UInt64
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var items: Int64 = 0
    var childNodes: [Int32] = []
    var files: [FileRecord] = []
    var smallCount: Int64 = 0
    var smallLogical: Int64 = 0
    var smallAllocated: Int64 = 0
  }

  struct Storage {
    var rootPath = "/"
    /// Set only when the root is "/": top-level names reachable through a firmlink.
    var firmlinks: Set<String>?
    var nodes: [Node] = []
    var version: UInt64 = 0
    var finished = false
    var cancelled = false
  }

  public let runID: UUID
  public let rootPath: String
  public let startedAt: Date
  let storage = Mutex(Storage())

  init(runID: UUID, rootPath: String, root: Node, firmlinks: Set<String>? = nil, startedAt: Date = Date()) {
    self.runID = runID
    self.rootPath = rootPath
    self.startedAt = startedAt
    storage.withLock {
      $0.rootPath = rootPath
      $0.firmlinks = firmlinks
      $0.nodes = [root]
    }
  }

  public var rootID: ScanItemID { ScanItemID(node: 0) }
  public var version: UInt64 { storage.withLock { $0.version } }
  public var isFinished: Bool { storage.withLock { $0.finished } }
  public var wasCancelled: Bool { storage.withLock { $0.cancelled } }
  public var nodeCount: Int { storage.withLock { $0.nodes.count } }

  // MARK: Reads (O(children) per call)

  public func item(_ id: ScanItemID) -> SpaceItem? {
    storage.withLock { storage in Self.item(id, in: storage) }
  }

  public func children(of id: ScanItemID, metric: SpaceMetric) -> [SpaceItem] {
    storage.withLock { storage in Self.sortedChildren(id, metric: metric, in: storage) }
  }

  public func group(at id: ScanItemID, metric: SpaceMetric, limit: Int = 24) -> SpaceGroup {
    let sorted = children(of: id, metric: metric)
    let front = Array(sorted.prefix(max(0, limit)))
    let rest = Array(sorted.dropFirst(max(0, limit)))
    var sum: Int64 = 0
    for item in rest {
      let (value, overflow) = sum.addingReportingOverflow(max(0, item.bytes(metric).knownLowerBound))
      sum = overflow ? Int64.max : value
    }
    let complete = rest.allSatisfy { $0.bytes(metric).completeTotal != nil }
    return SpaceGroup(
      items: front, other: rest, otherBytes: ByteAggregate(knownLowerBound: sum, completeTotal: complete ? sum : nil))
  }

  public func breadcrumb(to id: ScanItemID) -> [SpaceItem] {
    storage.withLock { storage in
      var result: [SpaceItem] = []
      var cursor: ScanItemID? = id
      while let current = cursor, let item = Self.item(current, in: storage) {
        result.append(item)
        cursor = item.parentID
      }
      return result.reversed()
    }
  }

  /// Whether `node` lies inside the subtree of `ancestor` (inclusive).
  public func isDescendant(_ node: Int32, of ancestor: Int32) -> Bool {
    storage.withLock { storage in Self.isDescendant(node, of: ancestor, in: storage.nodes) }
  }

  static func isDescendant(_ node: Int32, of ancestor: Int32, in nodes: [Node]) -> Bool {
    var cursor = node
    while cursor >= 0 && Int(cursor) < nodes.count {
      if cursor == ancestor { return true }
      cursor = nodes[Int(cursor)].parent
    }
    return false
  }

  static func path(of index: Int32, in nodes: [Node], rootPath: String, firmlinks: Set<String>?) -> String {
    var parts: [String] = []
    var cursor = index
    while cursor > 0 {
      let node = nodes[Int(cursor)]
      if let override = node.pathOverride {
        parts.append(String(override.dropFirst()))
        return "/" + parts.reversed().joined(separator: "/")
      }
      if node.parent == 0, let firmlinks {
        parts.append(firmlinks.contains(node.name) ? node.name : "System/Volumes/Data/" + node.name)
        return "/" + parts.reversed().joined(separator: "/")
      }
      parts.append(node.name)
      cursor = node.parent
    }
    guard !parts.isEmpty else { return rootPath }
    let suffix = parts.reversed().joined(separator: "/")
    return rootPath == "/" ? "/" + suffix : rootPath + "/" + suffix
  }

  public func path(of id: ScanItemID) -> String? { item(id)?.path }

  private static func item(_ id: ScanItemID, in storage: Storage) -> SpaceItem? {
    guard id.node >= 0, Int(id.node) < storage.nodes.count else { return nil }
    let nodes = storage.nodes
    let node = nodes[Int(id.node)]
    let nodePath = path(of: id.node, in: nodes, rootPath: storage.rootPath, firmlinks: storage.firmlinks)
    switch id.slot {
    case -1:
      let done = node.lifecycle == .done
      let partial = node.ownReason != nil || node.partialDescendant
      let state: ItemState
      if let rule = node.protectedRule {
        state = .protectedMetadataOnly(ruleID: rule)
      } else if let reason = node.ownReason {
        state = .partial(reason)
      } else if !done {
        state = storage.cancelled ? .partial(.cancelled) : .measuring
      } else if node.partialDescendant {
        state = .partial(.descendant)
      } else {
        state = .complete
      }
      let exact = done && !partial
      return SpaceItem(
        id: id, parentID: id.node == 0 ? nil : ScanItemID(node: node.parent),
        name: id.node == 0 ? displayName(nodePath) : node.name, path: nodePath, kind: node.kind,
        logical: ByteAggregate(knownLowerBound: node.logical, completeTotal: exact ? node.logical : nil),
        allocated: ByteAggregate(knownLowerBound: node.allocated, completeTotal: exact ? node.allocated : nil),
        itemCount: node.items, state: state,
        childCount: node.protectedRule == nil
          ? node.childNodes.count + node.files.count + (node.smallCount > 0 ? 1 : 0) : 0,
        device: node.device, inode: node.inode, summarizedFiles: 0)
    case -2:
      guard node.smallCount > 0 else { return nil }
      return SpaceItem(
        id: id, parentID: ScanItemID(node: id.node),
        name: "", path: nodePath, kind: .smallFiles,
        logical: ByteAggregate(knownLowerBound: node.smallLogical, completeTotal: node.smallLogical),
        allocated: ByteAggregate(knownLowerBound: node.smallAllocated, completeTotal: node.smallAllocated),
        itemCount: node.smallCount, state: .complete, childCount: 0, device: node.device, inode: 0,
        summarizedFiles: node.smallCount)
    default:
      guard id.slot >= 0, Int(id.slot) < node.files.count else { return nil }
      let file = node.files[Int(id.slot)]
      let state: ItemState =
        file.protectedRule.map { .protectedMetadataOnly(ruleID: $0) }
        ?? (file.error ? .partial(.entryError) : .complete)
      return SpaceItem(
        id: id, parentID: ScanItemID(node: id.node), name: file.name,
        path: nodePath == "/" ? "/" + file.name : nodePath + "/" + file.name, kind: file.kind,
        logical: ByteAggregate(knownLowerBound: file.logical, completeTotal: file.error ? nil : file.logical),
        allocated: ByteAggregate(knownLowerBound: file.allocated, completeTotal: file.error ? nil : file.allocated),
        itemCount: 1, state: state, childCount: 0, device: node.device, inode: file.inode, summarizedFiles: 0)
    }
  }

  private static func sortedChildren(_ id: ScanItemID, metric: SpaceMetric, in storage: Storage) -> [SpaceItem] {
    guard id.isNode, id.node >= 0, Int(id.node) < storage.nodes.count else { return [] }
    let node = storage.nodes[Int(id.node)]
    guard node.protectedRule == nil else { return [] }
    var result: [SpaceItem] = []
    result.reserveCapacity(node.childNodes.count + node.files.count + 1)
    for child in node.childNodes {
      if let item = item(ScanItemID(node: child), in: storage) { result.append(item) }
    }
    for slot in node.files.indices {
      if let item = item(ScanItemID(node: id.node, slot: Int32(slot)), in: storage) { result.append(item) }
    }
    if let summary = item(ScanItemID(node: id.node, slot: -2), in: storage) { result.append(summary) }
    result.sort { left, right in
      let leftBytes = left.bytes(metric).knownLowerBound
      let rightBytes = right.bytes(metric).knownLowerBound
      if leftBytes != rightBytes { return leftBytes > rightBytes }
      if left.kind == .smallFiles || right.kind == .smallFiles { return right.kind == .smallFiles }
      if left.name != right.name { return left.name < right.name }
      return left.id.slot < right.id.slot
    }
    return result
  }

  private static func displayName(_ path: String) -> String {
    path == "/" ? "/" : (path as NSString).lastPathComponent
  }
}
