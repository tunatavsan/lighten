import Foundation

/// A read-only catalog observation. Action planning replaces it with fresh proof.
public struct CatalogDiscovery: Sendable {
  public let row: CatalogRow
  public let snapshot: ScanSnapshot
  public let candidates: [CatalogDiscoveryCandidate]
}

public struct CatalogDiscoveryCandidate: Sendable {
  public let entry: ScanEntry
  public let node: ScanNode
  public let rejection: PlanRejection?
}

extension CleanCatalog {
  @concurrent public func discover(rowID: String) async throws -> CatalogDiscovery {
    guard let row = row(id: rowID) else { throw CatalogFailure.unauthorizedPath }
    let snapshot = try await ScanEngine(configuration: ScanConfiguration(homeDirectory: homeDirectory))
      .discoverySnapshot(rootPath: root(for: row))
    try Task.checkCancellation()
    return try discovery(snapshot: snapshot, rowID: rowID)
  }

  /// The same candidate producer also accepts an injected discovery observation.
  /// Current catalog eligibility is presentation guidance, never action authority.
  /// Age-limited rows retain their existing read-only content-mtime checks.
  public func discovery(snapshot: ScanSnapshot, rowID: String) throws -> CatalogDiscovery {
    guard snapshot.schema == 1, let row = row(id: rowID), snapshot.rootPath == root(for: row),
      let rootEntry = snapshot.entries.first, rootEntry.path == snapshot.rootPath, rootEntry.parentID == nil,
      Set(snapshot.entries.map(\.id)).count == snapshot.entries.count,
      Set(snapshot.entries.map(\.path)).count == snapshot.entries.count,
      Set(snapshot.nodes.map(\.id)).count == snapshot.nodes.count
    else { throw CatalogFailure.unauthorizedPath }
    let nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
    var candidates: [CatalogDiscoveryCandidate] = []
    for entry in snapshot.entries where entry.parentID == rootEntry.id {
      try Task.checkCancellation()
      guard (entry.path as NSString).deletingLastPathComponent == snapshot.rootPath,
        let node = nodes[entry.id], node.parentID == rootEntry.id
      else { throw CatalogFailure.unauthorizedPath }
      candidates.append(
        CatalogDiscoveryCandidate(
          entry: entry, node: node,
          rejection: candidateRejection(path: entry.path, row: row, kind: .trash)))
    }
    return CatalogDiscovery(row: row, snapshot: snapshot, candidates: candidates)
  }
}
