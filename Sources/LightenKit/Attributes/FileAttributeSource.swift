import Darwin
import Foundation

public struct FileAttributes: Sendable {
  public let identity: FileIdentity
  public let readable: Bool

  public init(identity: FileIdentity, readable: Bool) {
    self.identity = identity
    self.readable = readable
  }
}

/// Metadata-only seam for the asynchronous scanner. Values contain no open
/// handles, URLResourceValues, or file contents.
public protocol FileAttributeSource: Sendable {
  func volumeID(at path: String) async throws -> UUID?
  func inspect(at path: String) async throws -> FileAttributes
  func children(at path: String, expected: FileIdentity) async throws -> [String]
}

public struct DescriptorAttributeSource: FileAttributeSource {
  public init() {}

  public func volumeID(at path: String) async throws -> UUID? {
    try DescriptorFileSystem.volumeID(at: path)
  }

  public func inspect(at path: String) async throws -> FileAttributes {
    let identity = try DescriptorFileSystem.identity(at: path)
    guard identity.kind == .regular,
      identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
    else { return FileAttributes(identity: identity, readable: true) }
    let (parentFD, name) = try DescriptorFileSystem.openParent(of: path)
    defer { close(parentFD) }
    // An access check avoids opening a File Provider item just to display it.
    let readable = faccessat(parentFD, name, R_OK, AT_SYMLINK_NOFOLLOW_ANY) == 0
    return FileAttributes(identity: identity, readable: readable)
  }

  public func children(at path: String, expected: FileIdentity) async throws -> [String] {
    try DescriptorFileSystem.children(at: path, expected: expected)
  }
}
