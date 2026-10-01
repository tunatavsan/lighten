import Darwin
import Foundation
import Synchronization

extension ScanEngine {
  /// A compact discovery view: the root and its immediate children. Directory
  /// totals come from the parallel tree, not a second recursive traversal.
  /// This view is for presentation; planning still obtains fresh exact proof.
  @concurrent public func discoverySnapshot(rootPath: String) async throws -> ScanSnapshot {
    try Task.checkCancellation()
    let direct = Mutex<[RawEntry]>([])
    let run = try start(
      root: rootPath,
      directEntries: { entry in
        direct.withLock { $0.append(entry) }
      })
    await withTaskCancellationHandler {
      await run.waitUntilFinished()
    } onCancel: {
      run.cancel()
    }
    try Task.checkCancellation()
    return Self.discoverySnapshot(
      run: run, direct: direct.withLock { $0 }, homeDirectory: configuration.homeDirectory)
  }

  private static func discoverySnapshot(
    run: ScanRun, direct: [RawEntry], homeDirectory: String
  ) -> ScanSnapshot {
    let root = run.tree.rootPath
    let physicalRoot = root == "/" ? "/System/Volumes/Data" : root
    let rootItem = run.tree.item(run.tree.rootID)!
    let rootIdentity = try? DescriptorFileSystem.identity(at: physicalRoot)
    let volumeID = try? DescriptorFileSystem.volumeID(at: physicalRoot)
    let rootID = UUID()
    var entries: [ScanEntry] = []
    var nodes: [ScanNode] = []
    let directoryItems = Dictionary(
      uniqueKeysWithValues: run.tree.children(of: run.tree.rootID, metric: .logical)
        .filter { $0.id.isNode && $0.kind != .systemVolume }.map { ($0.name, $0) })
    let rootIssues = discoveryIssues(
      path: root, identity: rootIdentity, item: rootItem, volumeID: volumeID,
      device: rootItem.device, homeDirectory: homeDirectory)
    entries.append(
      ScanEntry(
        id: rootID, parentID: nil, path: root, identity: rootIdentity,
        observedAt: run.tree.startedAt, issues: rootIssues, readable: !rootIssues.contains(.unreadable)))
    nodes.append(discoveryNode(id: rootID, parentID: nil, item: rootItem, issues: rootIssues))

    for raw in direct.sorted(by: { $0.name < $1.name }) {
      let item = directoryItems[raw.name]
      let path = item?.path ?? (root == "/" ? "/" + raw.name : root + "/" + raw.name)
      // Directory identities are read only for direct children. Regular records
      // retain the metadata from the bulk walk, including files beyond 32 slots.
      let identity = raw.kind == .directory ? try? DescriptorFileSystem.identity(at: path) : raw.identity
      var issues = discoveryIssues(
        path: path, identity: identity, item: item, volumeID: volumeID,
        device: rootItem.device, homeDirectory: homeDirectory)
      if raw.error != 0 || identity?.device != raw.device || identity?.inode != raw.inode {
        if !issues.contains(.unknownMetadata) { issues.append(.unknownMetadata) }
      }
      let id = UUID()
      entries.append(
        ScanEntry(
          id: id, parentID: rootID, path: path, identity: identity,
          observedAt: run.tree.startedAt, issues: issues,
          readable: raw.error == 0 && identity != nil && !issues.contains(.unreadable)))
      if let item {
        nodes.append(discoveryNode(id: id, parentID: rootID, item: item, issues: issues))
      } else {
        let partial = !issues.isEmpty
        nodes.append(
          ScanNode(
            id: id, parentID: rootID,
            logical: ByteAggregate(knownLowerBound: raw.logical, completeTotal: partial ? nil : raw.logical),
            allocated: ByteAggregate(knownLowerBound: raw.allocated, completeTotal: partial ? nil : raw.allocated),
            knownItemCount: 1, completeItemCount: partial ? nil : 1, partial: partial,
            protected: issues.contains(.protected), skipped: partial))
      }
    }
    return ScanSnapshot(
      runID: run.runID, rootPath: root, volumeDevice: rootItem.device, volumeID: volumeID,
      observedAt: run.tree.startedAt, entries: entries, nodes: nodes)
  }

  private static func discoveryNode(
    id: UUID, parentID: UUID?, item: SpaceItem, issues: [ScanIssue]
  ) -> ScanNode {
    let partial = item.partial || !issues.isEmpty
    return ScanNode(
      id: id, parentID: parentID,
      logical: ByteAggregate(
        knownLowerBound: item.logical.knownLowerBound,
        completeTotal: partial ? nil : item.logical.completeTotal),
      allocated: ByteAggregate(
        knownLowerBound: item.allocated.knownLowerBound,
        completeTotal: partial ? nil : item.allocated.completeTotal),
      knownItemCount: Int(clamping: item.itemCount) + 1,
      completeItemCount: partial ? nil : Int(clamping: item.itemCount) + 1,
      partial: partial, protected: item.isProtected || issues.contains(.protected), skipped: !issues.isEmpty)
  }

  private static func discoveryIssues(
    path: String, identity: FileIdentity?, item: SpaceItem?, volumeID: UUID?, device: UInt64,
    homeDirectory: String
  ) -> [ScanIssue] {
    var issues: [ScanIssue] = []
    if volumeID == nil { issues.append(.unknownVolume) }
    guard let identity else { return issues + [.unknownMetadata] }
    if identity.device != device { issues.append(.mountBoundary) }
    if identity.kind == .symbolicLink { issues.append(.symbolicLink) }
    if identity.kind == .other { issues.append(.unknownMetadata) }
    if identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0 { issues.append(.dataless) }
    if item?.isProtected == true || ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) != nil {
      issues.append(.protected)
    }
    if path.split(separator: "/").contains(where: { PackageNames.isPackage(String($0)) }) {
      issues.append(.packageBoundary)
    }
    if case .partial(let reason) = item?.state {
      switch reason {
      case .unreadable: issues.append(.unreadable)
      case .mountBoundary: if !issues.contains(.mountBoundary) { issues.append(.mountBoundary) }
      case .cloudNotMeasured: if !issues.contains(.dataless) { issues.append(.dataless) }
      case .protectedNotTraversed: if !issues.contains(.protected) { issues.append(.protected) }
      case .changedDuringScan, .entryError: issues.append(.unknownMetadata)
      case .cancelled, .descendant: issues.append(.notTraversed)
      }
    }
    return issues
  }
}
