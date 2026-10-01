import CoreServices
import Darwin
import Foundation

public enum ScanReplayResult: Sendable, Equatable {
  case refreshed(directories: Int)
  case requiresFullScan
}

extension ScanEngine {
  /// Refreshes only journal-affected directories. Existing subtrees keep their
  /// storage and indices; a newly discovered subtree is measured once.
  public func reconcile(
    tree: ScanTree, replay: FileEventReplay, baseline: ScanReplayBaseline,
    currentBaseline: ScanReplayBaseline?
  ) -> ScanReplayResult {
    let unsafeFlags = UInt32(
      kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
        | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        | kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink)
    guard replay.complete, replay.events.count <= 50_000,
      let storeUUID = baseline.storeUUID, currentBaseline?.storeUUID == storeUUID,
      currentBaseline?.volumeUUID == baseline.volumeUUID,
      (currentBaseline?.eventID ?? 0) >= baseline.eventID,
      replay.latestID >= baseline.eventID,
      replay.events.allSatisfy({ $0.id >= baseline.eventID && $0.flags & unsafeFlags == 0 }),
      tree.isFinished, !tree.wasCancelled
    else { return .requiresFullScan }
    var previousID = baseline.eventID
    for event in replay.events {
      guard event.id >= previousID else { return .requiresFullScan }
      previousID = event.id
    }
    var paths = Set<String>()
    for event in replay.events {
      var path = event.path
      if tree.rootPath == "/", path.hasPrefix("/System/Volumes/Data/") {
        let relative = String(path.dropFirst("/System/Volumes/Data/".count))
        let first = String(relative.split(separator: "/").first ?? "")
        if ScanEngine.firmlinkNames().contains(first) { path = "/" + relative }
      }
      guard path == tree.rootPath || path.hasPrefix(tree.rootPath == "/" ? "/" : tree.rootPath + "/") else {
        continue
      }
      let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
      if event.flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { paths.insert(path) }
      paths.insert(parent)
    }
    var affected = Set<ScanItemID>()
    for var path in paths {
      while path == tree.rootPath || path.hasPrefix(tree.rootPath == "/" ? "/" : tree.rootPath + "/") {
        if let id = tree.find(path: path) {
          affected.insert(id)
          break
        }
        let next = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if next == path { break }
        path = next
      }
    }
    // Parents discover renames and moves before their children are refreshed.
    let ordered = affected.sorted {
      (tree.path(of: $0)?.utf8.count ?? 0) < (tree.path(of: $1)?.utf8.count ?? 0)
    }
    var refreshed = 0
    for id in ordered {
      guard let item = tree.item(id), tree.find(path: item.path) == id else { continue }
      // Protected metadata-only regions have no inspectable descendants.
      if item.isProtected { return .requiresFullScan }
      if case .partial(let reason) = item.state, reason != .descendant { return .requiresFullScan }
      do {
        try refreshDirectory(id, tree: tree)
        refreshed += 1
      } catch { return .requiresFullScan }
    }
    return .refreshed(directories: refreshed)
  }

  private enum RefreshFailure: Error { case unavailable, hardLinks, changed }

  private func refreshDirectory(_ id: ScanItemID, tree: ScanTree) throws {
    guard let item = tree.item(id) else { throw RefreshFailure.unavailable }
    var details = stat()
    guard lstat(item.path, &details) == 0, details.st_mode & S_IFMT == S_IFDIR,
      DescriptorFileSystem.deviceID(details.st_dev) == item.device, details.st_ino == item.inode
    else { throw RefreshFailure.changed }
    let oldChildren = tree.storage.withLock { storage in
      storage.nodes[Int(id.node)].childNodes.map { ($0, storage.nodes[Int($0)]) }
    }
    let oldByName = Dictionary(uniqueKeysWithValues: oldChildren.map { ($0.1.name, $0) })
    let temporary = ScanTree(
      runID: UUID(), rootPath: item.path,
      root: ScanTree.rootNode(name: item.path, device: item.device, inode: item.inode))
    let automaton = ProtectionAutomaton(homeDirectory: configuration.homeDirectory)
    let walker = ParallelWalker(
      tree: temporary, counters: ScanCounters(), automaton: automaton, boundaryDevice: item.device,
      homeDirectory: configuration.homeDirectory, firmlinks: nil, workers: 1, onFinish: {})
    let reader = DirectoryReader(counters: walker.counters)
    // A hidden small-file hardlink may have been counted in another directory.
    // Refuse the incremental path rather than silently changing deduplication.
    var throwHardLink = false
    let oldOpaque = oldChildren.filter { $0.1.ownReason != nil || $0.1.protectedRule != nil }
    let opaqueNames = Set(oldOpaque.map { $0.1.name })
    var opaqueEntries: [String: RawEntry] = [:]
    try reader.read(
      path: item.path, expected: (item.device, item.inode), isCancelled: { false },
      visit: {
        if $0.kind == .regular && $0.linkCount > 1 { throwHardLink = true }
        if opaqueNames.contains($0.name) { opaqueEntries[$0.name] = $0 }
      })
    if throwHardLink { throw RefreshFailure.hardLinks }
    for (_, old) in oldOpaque {
      guard let entry = opaqueEntries[old.name], entry.error == 0, entry.kind == .directory,
        entry.device == old.device, entry.inode == old.inode
      else { throw RefreshFailure.changed }
    }
    let job = WalkJob(
      owner: 0, path: item.path, device: item.device, inode: item.inode,
      mode: item.kind == .package ? .interior : .node,
      depth: 0, protection: automaton.state(forPath: item.path))
    var jobs = walker.process(job, reader: reader)
    var preserved: [Int32: Int32] = [:]
    if item.kind != .package {
      let children = temporary.storage.withLock { storage in
        storage.nodes[0].childNodes.map { ($0, storage.nodes[Int($0)]) }
      }
      // Classification uses only the parent's entry metadata. Protected and
      // cloud-only children are never opened to validate the cached boundary.
      for (index, child) in children {
        let old = oldByName[child.name]
        let wasOpaque = old.map { $0.1.ownReason != nil || $0.1.protectedRule != nil } ?? false
        guard child.ownReason != nil || child.protectedRule != nil || wasOpaque else { continue }
        guard let old, Self.sameBoundary(child, old.1) else {
          throw RefreshFailure.changed
        }
        preserved[index] = old.0
      }
      jobs = jobs.filter { job in
        let child = temporary.storage.withLock { $0.nodes[Int(job.owner)] }
        guard let old = oldByName[child.name], Self.sameBoundary(child, old.1)
        else { return true }
        preserved[job.owner] = old.0
        temporary.storage.withLock { storage in
          var copy = old.1
          copy.parent = 0
          copy.childNodes = []
          storage.nodes[Int(job.owner)] = copy
          storage.nodes[0].logical &+= copy.logical
          storage.nodes[0].allocated &+= copy.allocated
          storage.nodes[0].items &+= copy.items
        }
        return false
      }
    }
    while let next = jobs.popLast() {
      var linkedFile = false
      try reader.read(
        path: next.path, expected: (next.device, next.inode), isCancelled: { false },
        visit: { if $0.kind == .regular && $0.linkCount > 1 { linkedFile = true } })
      if linkedFile { throw RefreshFailure.hardLinks }
      jobs.append(contentsOf: walker.process(next, reader: reader))
    }
    let measured = temporary.storage.withLock { storage -> ScanTree.Storage in
      for index in storage.nodes.indices { storage.nodes[index].lifecycle = .done }
      return storage
    }
    guard
      measured.nodes.enumerated().allSatisfy({ index, node in
        node.ownReason == nil || preserved[Int32(index)] != nil
      })
    else { throw RefreshFailure.unavailable }
    tree.replaceDirectory(id.node, measured: measured, preserved: preserved)
  }

  private static func sameBoundary(_ fresh: ScanTree.Node, _ old: ScanTree.Node) -> Bool {
    fresh.name == old.name && fresh.device == old.device && fresh.inode == old.inode
      && fresh.kind == old.kind && fresh.ownReason == old.ownReason && fresh.protectedRule == old.protectedRule
  }
}
