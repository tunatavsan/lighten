import Darwin
import Foundation

/// Traversal happens as part of irreversible removal, through pinned directory
/// descriptors. Symbolic links are unlinked themselves and never opened.
actor UserSelectionPermanentRemoval {
  private let item: PlanItem
  private let homeDirectory: String
  private let progress: @Sendable (Int, Int64) async throws -> Void
  private var parentFD: Int32 = -1
  private var rootName = ""
  private var parentIdentity: FileIdentity?
  private var rootIdentity: FileIdentity?
  private(set) var count = 0
  private(set) var bytes: Int64 = 0

  init(item: PlanItem, homeDirectory: String, progress: @escaping @Sendable (Int, Int64) async throws -> Void) {
    self.item = item
    self.homeDirectory = homeDirectory
    self.progress = progress
  }

  func remove() async throws {
    try UserSelectionSafety.validateRoot(item, homeDirectory: homeDirectory)
    let opened = try UserSelectionFileSystem.openParent(of: item.sourcePath)
    parentFD = opened.0
    rootName = opened.1
    defer {
      close(parentFD)
      parentFD = -1
    }
    var details = stat()
    guard fstat(parentFD, &details) == 0 else { throw FileSystemFailure.systemCall("fstat", errno) }
    parentIdentity = DescriptorFileSystem.identity(from: details)
    rootIdentity = item.inventory.first?.identity
    try await remove(name: rootName, from: parentFD, depth: 0)
  }

  private func validateRootLocation() throws {
    guard let rootIdentity, let parentIdentity,
      UserSelectionSafety.sameRoot(
        try DescriptorFileSystem.identity(name: rootName, relativeTo: parentFD), rootIdentity)
    else { throw GuardFailure.changedItem }
    let current = try UserSelectionFileSystem.openParent(of: item.sourcePath)
    defer { close(current.0) }
    var details = stat()
    guard current.1 == rootName, fstat(current.0, &details) == 0,
      UserSelectionSafety.sameRoot(DescriptorFileSystem.identity(from: details), parentIdentity)
    else { throw GuardFailure.changedAncestor }
  }

  private func remove(name: String, from directoryFD: Int32, depth: Int) async throws {
    guard depth <= 1024, !Task.isCancelled else { throw CancellationError() }
    try validateRootLocation()
    let expected = try DescriptorFileSystem.identity(name: name, relativeTo: directoryFD)
    if expected.kind == .directory {
      let childFD = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard childFD >= 0 else { throw FileSystemFailure.systemCall("openat", errno) }
      defer { close(childFD) }
      var details = stat()
      guard fstat(childFD, &details) == 0,
        UserSelectionSafety.sameRoot(DescriptorFileSystem.identity(from: details), expected)
      else { throw FileSystemFailure.changedDuringInspection }
      let enumerationFD = dup(childFD)
      guard enumerationFD >= 0 else { throw FileSystemFailure.systemCall("dup", errno) }
      guard let stream = fdopendir(enumerationFD) else {
        let error = errno
        close(enumerationFD)
        throw FileSystemFailure.systemCall("fdopendir", error)
      }
      defer { closedir(stream) }
      while true {
        errno = 0
        guard let entry = readdir(stream) else {
          if errno != 0 { throw FileSystemFailure.systemCall("readdir", errno) }
          break
        }
        let child = withUnsafePointer(to: &entry.pointee.d_name) {
          $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        if child == "." || child == ".." { continue }
        try await remove(name: child, from: childFD, depth: depth + 1)
      }
    }
    try validateRootLocation()
    guard
      UserSelectionSafety.sameRoot(
        try DescriptorFileSystem.identity(name: name, relativeTo: directoryFD), expected)
    else { throw GuardFailure.changedItem }
    guard unlinkat(directoryFD, name, expected.kind == .directory ? AT_REMOVEDIR : 0) == 0 else {
      throw FileSystemFailure.systemCall("unlinkat", errno)
    }
    count += 1
    if expected.kind != .directory {
      let (next, overflow) = bytes.addingReportingOverflow(max(0, expected.logicalBytes))
      bytes = overflow ? Int64.max : next
    }
    try await progress(count, bytes)
  }
}
