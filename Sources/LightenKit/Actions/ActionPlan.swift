import Foundation

public enum ActionKind: String, Codable, Sendable {
  case trash, catalogDelete
}

public struct PlanItem: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let sourcePath: String
  public let volumeID: UUID?
  public let inventory: [ScanEntry]
  public let ancestors: [PathIdentity]

  public init(
    id: UUID, sourcePath: String, volumeID: UUID? = nil,
    inventory: [ScanEntry], ancestors: [PathIdentity]
  ) {
    self.id = id
    self.sourcePath = sourcePath
    self.volumeID = volumeID
    self.inventory = inventory
    self.ancestors = ancestors
  }
}

public struct ActionPlan: Codable, Sendable, Equatable {
  public let schema: Int
  public let id: UUID
  public let snapshotRunID: UUID
  public let kind: ActionKind
  public let createdAt: Date
  public let items: [PlanItem]

  public init(
    schema: Int = 1, id: UUID = UUID(), snapshotRunID: UUID,
    kind: ActionKind, createdAt: Date = Date(), items: [PlanItem]
  ) {
    self.schema = schema
    self.id = id
    self.snapshotRunID = snapshotRunID
    self.kind = kind
    self.createdAt = createdAt
    self.items = items
  }
}

public enum PlanFailure: Error, Sendable, Equatable {
  case incompatibleSnapshot
  case unknownSelection
  case unsafeSelection
  case changedSinceScan
  case emptySelection
}

public struct PlanService: Sendable {
  public let homeDirectory: String

  public init(homeDirectory: String = NSHomeDirectory()) {
    self.homeDirectory = homeDirectory
  }

  /// Planning walks the complete snapshot and performs descriptor checks.
  /// UI callers can use this entry point to keep that work off the main actor.
  public func makePlanAsync(
    snapshot: ScanSnapshot, selectedIDs: Set<UUID>, kind: ActionKind = .trash
  ) async throws -> ActionPlan {
    try await Task.detached {
      try makePlan(snapshot: snapshot, selectedIDs: selectedIDs, kind: kind)
    }.value
  }

  public func makePlan(
    snapshot: ScanSnapshot, selectedIDs: Set<UUID>, kind: ActionKind = .trash
  ) throws -> ActionPlan {
    guard snapshot.schema == 1 else { throw PlanFailure.incompatibleSnapshot }
    guard !selectedIDs.isEmpty else { throw PlanFailure.emptySelection }
    let entriesByID = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
    let nodesByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
    guard selectedIDs.allSatisfy({ entriesByID[$0] != nil }) else {
      throw PlanFailure.unknownSelection
    }
    let roots = selectedIDs.filter { id in
      var cursor = entriesByID[id]?.parentID
      while let current = cursor {
        if selectedIDs.contains(current) { return false }
        cursor = entriesByID[current]?.parentID
      }
      return true
    }.sorted { entriesByID[$0]!.path < entriesByID[$1]!.path }

    var items: [PlanItem] = []
    for id in roots {
      guard let root = entriesByID[id], let rootIdentity = root.identity,
        let node = nodesByID[id], !node.partial, !node.protected,
        rootIdentity.device == snapshot.volumeDevice,
        let volumeID = snapshot.volumeID,
        rootIdentity.kind == .regular || rootIdentity.kind == .directory,
        root.path != snapshot.rootPath,
        !Self.isBulkRoot(root.path, homeDirectory: homeDirectory),
        !ScanService.isPackage(root.path), !ScanService.isInsidePackage(root.path)
      else { throw PlanFailure.unsafeSelection }
      let inventory = snapshot.entries.filter {
        $0.id == id || isDescendant($0, of: id, entriesByID: entriesByID)
      }
      guard
        inventory.allSatisfy({ entry in
          guard let identity = entry.identity else { return false }
          return entry.issues.isEmpty && entry.readable && identity.hasStableTrashProof
            && identity.device == snapshot.volumeDevice
        })
      else { throw PlanFailure.unsafeSelection }
      let ancestors = try DescriptorFileSystem.ancestorIdentities(of: root.path)
      // The snapshot is an observation, not a grant. Planning itself rejects
      // an already changed source or ancestor.
      guard try DescriptorFileSystem.identity(at: root.path) == rootIdentity else {
        throw PlanFailure.changedSinceScan
      }
      guard try DescriptorFileSystem.volumeID(at: root.path) == volumeID else {
        throw PlanFailure.changedSinceScan
      }
      items.append(
        PlanItem(
          id: id, sourcePath: root.path, volumeID: volumeID,
          inventory: inventory, ancestors: ancestors))
    }
    return ActionPlan(snapshotRunID: snapshot.runID, kind: kind, items: items)
  }

  private func isDescendant(
    _ entry: ScanEntry, of ancestor: UUID, entriesByID: [UUID: ScanEntry]
  ) -> Bool {
    var cursor = entry.parentID
    while let current = cursor {
      if current == ancestor { return true }
      cursor = entriesByID[current]?.parentID
    }
    return false
  }

  static func isBulkRoot(_ path: String, homeDirectory: String) -> Bool {
    let blocked = [
      "/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private", "/private/var", homeDirectory,
    ]
    let locale = Locale(identifier: "en_US_POSIX")
    let folded = path.lowercased(with: locale)
    return blocked.contains { $0.lowercased(with: locale) == folded }
  }
}
