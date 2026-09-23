import Foundation

extension ScanTree {
  struct ChildSpec {
    var name: String
    var device: UInt64
    var inode: UInt64
    var kind: NodeKind
    var reason: PartialReason?
    var protectedRule: String?
    var traverse: Bool
  }

  static func rootNode(name: String, kind: NodeKind = .directory, device: UInt64, inode: UInt64) -> Node {
    var node = Node(name: name, parent: -1, kind: kind, device: device, inode: inode)
    node.pending = 1
    return node
  }

  /// Applies one directory listing. Returns the node index of each child, in order.
  func applyNode(
    _ job: WalkJob, children: [ChildSpec], files: [FileRecord], small: (Int64, Int64, Int64),
    logical: Int64, allocated: Int64, items: Int64, entryErrors: Bool
  ) -> [Int32] {
    storage.withLock { storage in
      let owner = job.owner
      var created: [Int32] = []
      created.reserveCapacity(children.count)
      var traversed: Int32 = 0
      var anyPartialChild = false
      for spec in children {
        let index = Int32(storage.nodes.count)
        var node = Node(
          name: spec.name, parent: owner, kind: spec.kind, device: spec.device, inode: spec.inode)
        node.protectedRule = spec.protectedRule
        node.ownReason = spec.reason
        if spec.traverse {
          node.pending = 1
          traversed += 1
        } else {
          node.lifecycle = .done
          anyPartialChild = anyPartialChild || spec.reason != nil
        }
        storage.nodes.append(node)
        created.append(index)
      }
      storage.nodes[Int(owner)].childNodes += created
      storage.nodes[Int(owner)].files = files
      storage.nodes[Int(owner)].smallCount = small.0
      storage.nodes[Int(owner)].smallLogical = small.1
      storage.nodes[Int(owner)].smallAllocated = small.2
      Self.add(logical: logical, allocated: allocated, items: items, from: owner, in: &storage.nodes)
      if entryErrors {
        if storage.nodes[Int(owner)].ownReason == nil { storage.nodes[Int(owner)].ownReason = .entryError }
        Self.markPartialAncestors(of: owner, in: &storage.nodes)
      }
      if anyPartialChild {
        storage.nodes[Int(owner)].partialDescendant = true
        Self.markPartialAncestors(of: owner, in: &storage.nodes)
      }
      storage.nodes[Int(owner)].pending += traversed
      Self.jobDone(owner, in: &storage.nodes)
      storage.version &+= 1
      return created
    }
  }

  func applyInterior(
    _ job: WalkJob, logical: Int64, allocated: Int64, items: Int64, newJobs: Int, entryErrors: Bool
  ) {
    storage.withLock { storage in
      let owner = job.owner
      Self.add(logical: logical, allocated: allocated, items: items, from: owner, in: &storage.nodes)
      if entryErrors {
        if storage.nodes[Int(owner)].ownReason == nil { storage.nodes[Int(owner)].ownReason = .entryError }
        Self.markPartialAncestors(of: owner, in: &storage.nodes)
      }
      storage.nodes[Int(owner)].pending += Int32(newJobs)
      Self.jobDone(owner, in: &storage.nodes)
      storage.version &+= 1
    }
  }

  func fail(_ job: WalkJob, reason: PartialReason) {
    storage.withLock { storage in
      // A cancelled job leaves its owner measuring; the run is marked cancelled.
      guard reason != .cancelled else { return }
      let owner = job.owner
      if storage.nodes[Int(owner)].ownReason == nil { storage.nodes[Int(owner)].ownReason = reason }
      Self.markPartialAncestors(of: owner, in: &storage.nodes)
      Self.jobDone(owner, in: &storage.nodes)
      storage.version &+= 1
    }
  }

  func finish(cancelled: Bool) {
    storage.withLock { storage in
      storage.finished = true
      storage.cancelled = cancelled
      storage.version &+= 1
    }
  }

  /// Adds a synthetic, already measured child (the sealed system volume).
  func addMeasuredChild(name: String, pathOverride: String?, kind: NodeKind, logical: Int64) {
    storage.withLock { storage in
      var node = Node(name: name, parent: 0, kind: kind, device: 0, inode: 0)
      node.pathOverride = pathOverride
      node.lifecycle = .done
      node.logical = logical
      node.allocated = logical
      storage.nodes.append(node)
      storage.nodes[0].childNodes.append(Int32(storage.nodes.count - 1))
      Self.add(logical: logical, allocated: logical, items: 0, from: 0, in: &storage.nodes)
      storage.version &+= 1
    }
  }

  private static func add(logical: Int64, allocated: Int64, items: Int64, from index: Int32, in nodes: inout [Node]) {
    guard logical != 0 || allocated != 0 || items != 0 else { return }
    var cursor = index
    while cursor >= 0 {
      nodes[Int(cursor)].logical &+= logical
      nodes[Int(cursor)].allocated &+= allocated
      nodes[Int(cursor)].items &+= items
      cursor = nodes[Int(cursor)].parent
    }
  }

  private static func markPartialAncestors(of index: Int32, in nodes: inout [Node]) {
    var cursor = nodes[Int(index)].parent
    while cursor >= 0 {
      if nodes[Int(cursor)].partialDescendant { return }
      nodes[Int(cursor)].partialDescendant = true
      cursor = nodes[Int(cursor)].parent
    }
  }

  private static func jobDone(_ index: Int32, in nodes: inout [Node]) {
    var cursor = index
    while cursor >= 0 {
      nodes[Int(cursor)].pending -= 1
      guard nodes[Int(cursor)].pending == 0 else { return }
      nodes[Int(cursor)].lifecycle = .done
      cursor = nodes[Int(cursor)].parent
    }
  }
}
