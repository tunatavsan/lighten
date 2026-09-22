import Darwin
import Foundation

public struct ScanService: Sendable {
  public let homeDirectory: String
  private let attributes: any FileAttributeSource

  public init(
    homeDirectory: String = NSHomeDirectory(),
    attributes: any FileAttributeSource = DescriptorAttributeSource()
  ) {
    self.homeDirectory = homeDirectory
    self.attributes = attributes
  }

  public func scan(rootPath: String) async throws -> ScanSnapshot {
    let task = Task.detached { try await performScan(rootPath: rootPath, progress: nil) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func events(rootPath: String) -> AsyncThrowingStream<ScanEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached {
        do {
          let snapshot = try await performScan(rootPath: rootPath) { count, path in
            continuation.yield(.progress(scannedItems: count, path: path))
          }
          continuation.yield(.completed(snapshot))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private func performScan(
    rootPath: String, progress: (@Sendable (Int, String) -> Void)?
  ) async throws -> ScanSnapshot {
    let rootIdentity = try await attributes.inspect(at: rootPath).identity
    guard rootIdentity.kind == .directory else { throw ScanFailure.rootNotDirectory }
    let volumeID = try? await attributes.volumeID(at: rootPath)
    var entries: [ScanEntry] = []
    var indexByID: [UUID: Int] = [:]

    func visit(_ path: String, parentID: UUID?) async throws {
      try Task.checkCancellation()
      let observed: FileAttributes?
      do { observed = try await attributes.inspect(at: path) } catch { observed = nil }
      let identity = observed?.identity
      var issues: [ScanIssue] = []
      if identity == nil { issues.append(.unknownMetadata) }
      if volumeID == nil { issues.append(.unknownVolume) }
      if observed?.readable == false { issues.append(.unreadable) }
      if ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) != nil {
        issues.append(.protected)
      }
      if let identity {
        if identity.device != rootIdentity.device { issues.append(.mountBoundary) }
        if identity.kind == .symbolicLink { issues.append(.symbolicLink) }
        if identity.kind == .other { issues.append(.unknownMetadata) }
        if identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0 { issues.append(.dataless) }
        if Self.isPackage(path) || Self.isInsidePackage(path) { issues.append(.packageBoundary) }
      }
      let id = UUID()
      indexByID[id] = entries.count
      entries.append(
        ScanEntry(
          id: id, parentID: parentID, path: path, identity: identity,
          issues: issues, readable: observed?.readable == true
        ))
      progress?(entries.count, path)
      guard let identity, identity.kind == .directory, issues.isEmpty else { return }
      let names: [String]
      do { names = try await attributes.children(at: path, expected: identity) } catch {
        let position = indexByID[id]!
        entries[position] = ScanEntry(
          id: id, parentID: parentID, path: path, identity: identity,
          issues: [.unreadable], readable: false
        )
        return
      }
      for name in names {
        let childPath = path == "/" ? "/" + name : path + "/" + name
        try await visit(childPath, parentID: id)
      }
    }

    try await visit(rootPath, parentID: nil)
    var childrenByParent: [UUID: [UUID]] = [:]
    for entry in entries {
      if let parent = entry.parentID { childrenByParent[parent, default: []].append(entry.id) }
    }
    var nodesByID: [UUID: ScanNode] = [:]
    for entry in entries.reversed() {
      let childNodes = (childrenByParent[entry.id] ?? []).compactMap { nodesByID[$0] }
      let partial = !entry.issues.isEmpty || childNodes.contains(where: \.partial)
      let ownLogical = entry.identity?.logicalBytes ?? 0
      let ownAllocated = entry.identity?.allocatedBytes ?? 0
      let logical = ownLogical + childNodes.reduce(0) { $0 + $1.logical.knownLowerBound }
      let allocated = ownAllocated + childNodes.reduce(0) { $0 + $1.allocated.knownLowerBound }
      let count = 1 + childNodes.reduce(0) { $0 + $1.knownItemCount }
      nodesByID[entry.id] = ScanNode(
        id: entry.id, parentID: entry.parentID,
        logical: ByteAggregate(knownLowerBound: logical, completeTotal: partial ? nil : logical),
        allocated: ByteAggregate(knownLowerBound: allocated, completeTotal: partial ? nil : allocated),
        knownItemCount: count, completeItemCount: partial ? nil : count,
        partial: partial,
        protected: entry.issues.contains(.protected) || childNodes.contains(where: \.protected),
        skipped: !entry.issues.isEmpty
      )
    }
    return ScanSnapshot(
      rootPath: rootPath, volumeDevice: rootIdentity.device, volumeID: volumeID,
      entries: entries,
      nodes: entries.compactMap { nodesByID[$0.id] }
    )
  }

  static func isPackage(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent.lowercased()
    if [
      ".app", ".bundle", ".framework", ".photoslibrary", ".pkg", ".pvm", ".vmwarevm", ".sparsebundle", ".rtfd",
      ".playground", ".xcworkspace", ".xcodeproj", ".pages", ".numbers", ".key",
    ].contains(where: {
      name.hasSuffix($0)
    }) {
      return true
    }
    return ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage) == true
  }

  static func isInsidePackage(_ path: String) -> Bool {
    var parent = (path as NSString).deletingLastPathComponent
    while parent != "/" && !parent.isEmpty {
      if isPackage(parent) { return true }
      parent = (parent as NSString).deletingLastPathComponent
    }
    return false
  }
}

public enum ScanFailure: Error, Sendable {
  case rootNotDirectory
}
