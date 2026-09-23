import Darwin
import Foundation

/// The legacy snapshot traversal with descriptor-relative metadata: one open and
/// readdir per folder and one no-follow fstatat per entry, instead of reopening
/// every path from "/". Issues, order and identities match `ScanService` exactly,
/// so plans and proofs built from its snapshots are unchanged.
struct DescriptorScan {
  let homeDirectory: String

  func run(
    rootPath: String, immediateChild: String?, progress: (@Sendable (Int, String) -> Void)?
  ) throws -> ScanSnapshot {
    let rootIdentity = try DescriptorFileSystem.identity(at: rootPath)
    guard rootIdentity.kind == .directory else { throw ScanFailure.rootNotDirectory }
    let volumeID = try? DescriptorFileSystem.volumeID(at: rootPath)
    let automaton = ProtectionAutomaton(homeDirectory: homeDirectory)
    let rootInsidePackage = ScanService.isInsidePackage(rootPath)
    var entries: [ScanEntry] = []

    func issues(path: String, identity: FileIdentity, readable: Bool, protected: Bool) -> [ScanIssue] {
      var result: [ScanIssue] = []
      if volumeID == nil { result.append(.unknownVolume) }
      if !readable { result.append(.unreadable) }
      if protected { result.append(.protected) }
      if identity.device != rootIdentity.device { result.append(.mountBoundary) }
      if identity.kind == .symbolicLink { result.append(.symbolicLink) }
      if identity.kind == .other { result.append(.unknownMetadata) }
      if identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0 { result.append(.dataless) }
      let package =
        identity.kind == .directory
        ? ScanService.isPackage(path) : ScanService.isPackageName(path)
      if package || rootInsidePackage { result.append(.packageBoundary) }
      return result
    }

    func visit(
      path: String, identity: FileIdentity, readable: Bool, parentID: UUID?,
      state: ProtectionAutomaton.State, open: () -> Int32
    ) throws {
      try Task.checkCancellation()
      // The automaton matches the same rules case-folded, a superset of ProtectionPolicy.
      let protected = automaton.match(state) != nil
      let found = issues(path: path, identity: identity, readable: readable, protected: protected)
      let id = UUID()
      entries.append(
        ScanEntry(id: id, parentID: parentID, path: path, identity: identity, issues: found, readable: readable))
      progress?(entries.count, path)
      guard identity.kind == .directory, found.isEmpty else { return }
      let fd = open()
      var opened = stat()
      let names: [String]?
      if fd >= 0, fstat(fd, &opened) == 0, DescriptorFileSystem.identity(from: opened) == identity {
        names = try? ExactInventory.names(fd: fd)
      } else {
        names = nil
      }
      defer { if fd >= 0 { close(fd) } }
      guard let names else {
        entries[entries.count - 1] = ScanEntry(
          id: id, parentID: parentID, path: path, identity: identity, issues: [.unreadable], readable: false)
        return
      }
      let position = entries.count - 1
      if parentID == nil, let immediateChild {
        guard names.contains(immediateChild) else { throw ScanFailure.childUnavailable }
        entries[position] = ScanEntry(
          id: id, parentID: parentID, path: path, identity: identity, issues: [.notTraversed], readable: readable)
      }
      for name in names where parentID != nil || immediateChild == nil || name == immediateChild {
        let childPath = path == "/" ? "/" + name : path + "/" + name
        var details = stat()
        guard fstatat(fd, name, &details, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
          try Task.checkCancellation()
          entries.append(
            ScanEntry(
              parentID: id, path: childPath, identity: nil,
              issues: volumeID == nil ? [.unknownMetadata, .unknownVolume] : [.unknownMetadata], readable: false))
          progress?(entries.count, childPath)
          continue
        }
        let child = DescriptorFileSystem.identity(from: details)
        // An access check avoids opening a File Provider item just to display it.
        let childReadable =
          child.kind != .regular || child.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0
          || faccessat(fd, name, R_OK, AT_SYMLINK_NOFOLLOW_ANY) == 0
        try visit(
          path: childPath, identity: child, readable: childReadable, parentID: id,
          state: automaton.step(state, name),
          open: { openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) })
      }
    }

    try visit(
      path: rootPath, identity: rootIdentity, readable: true, parentID: nil,
      state: automaton.state(forPath: rootPath), open: { DirectoryReader.openDirectory(rootPath) })
    return ScanService.snapshot(
      rootPath: rootPath, rootDevice: rootIdentity.device, volumeID: volumeID, entries: entries)
  }
}
