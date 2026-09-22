import Darwin
import Foundation

public enum FileSystemFailure: Error, Sendable, Equatable {
  case invalidPath
  case systemCall(String, Int32)
  case changedDuringInspection
}

/// All intermediate components are opened as directories without following links.
/// A caller must still revalidate immediately before a path-based OS mutation.
public enum DescriptorFileSystem {
  /// A persistent volume UUID, separate from the mount-time st_dev value.
  /// Unsupported filesystems return nil and cannot be action targets.
  public static func volumeID(at path: String) throws -> UUID? {
    _ = try path == "/" ? [] : validatedComponents(path)
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.volattr = UInt32(ATTR_VOL_UUID) | ATTR_VOL_INFO
    var bytes = [UInt8](repeating: 0, count: 20)
    let result = bytes.withUnsafeMutableBytes { buffer in
      getattrlist(
        path, &attributes, buffer.baseAddress, buffer.count,
        UInt32(FSOPT_NOFOLLOW_ANY))
    }
    if result != 0 {
      if errno == ENOTSUP || errno == EOPNOTSUPP { return nil }
      throw FileSystemFailure.systemCall("getattrlist", errno)
    }
    let length =
      UInt32(bytes[0]) | UInt32(bytes[1]) << 8
      | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    guard length == 20, bytes[4..<20].contains(where: { $0 != 0 }) else { return nil }
    return UUID(
      uuid: (
        bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        bytes[16], bytes[17], bytes[18], bytes[19]
      ))
  }

  public static func identity(at path: String) throws -> FileIdentity {
    if path == "/" {
      let fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard fd >= 0 else { throw FileSystemFailure.systemCall("open", errno) }
      defer { close(fd) }
      var details = stat()
      guard fstat(fd, &details) == 0 else { throw FileSystemFailure.systemCall("fstat", errno) }
      return identity(from: details)
    }
    let (parentFD, name) = try openParent(of: path)
    defer { close(parentFD) }
    return try identity(name: name, relativeTo: parentFD)
  }

  public static func children(at path: String, expected: FileIdentity) throws -> [String] {
    let directoryFD: Int32
    if path == "/" {
      directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    } else {
      let (parentFD, name) = try openParent(of: path)
      directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      close(parentFD)
    }
    guard directoryFD >= 0 else { throw FileSystemFailure.systemCall("openat", errno) }
    var opened = stat()
    guard fstat(directoryFD, &opened) == 0 else {
      let error = errno
      close(directoryFD)
      throw FileSystemFailure.systemCall("fstat", error)
    }
    guard identity(from: opened) == expected else {
      close(directoryFD)
      throw FileSystemFailure.changedDuringInspection
    }
    guard let directory = fdopendir(directoryFD) else {
      let error = errno
      close(directoryFD)
      throw FileSystemFailure.systemCall("fdopendir", error)
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
      errno = 0
      guard let item = readdir(directory) else {
        if errno != 0 { throw FileSystemFailure.systemCall("readdir", errno) }
        break
      }
      let name = withUnsafePointer(to: &item.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name != "." && name != ".." { names.append(name) }
    }
    // An open directory can change while enumerated. The guard compares the
    // complete sorted inventory again before an OS move.
    return names.sorted()
  }

  public static func openParent(of path: String) throws -> (Int32, String) {
    let components = try validatedComponents(path)
    guard let name = components.last else { throw FileSystemFailure.invalidPath }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open", errno) }
    for component in components.dropLast() {
      let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      let error = errno
      close(fd)
      guard next >= 0 else { throw FileSystemFailure.systemCall("openat", error) }
      fd = next
    }
    return (fd, name)
  }

  public static func ancestorIdentities(of path: String) throws -> [PathIdentity] {
    let parts = try validatedComponents(path)
    var result: [PathIdentity] = []
    var prefix = ""
    for part in parts.dropLast() {
      prefix += "/" + part
      result.append(PathIdentity(path: prefix, identity: try identity(at: prefix)))
    }
    return result
  }

  static func identity(name: String, relativeTo directoryFD: Int32) throws -> FileIdentity {
    var details = stat()
    guard fstatat(directoryFD, name, &details, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
      throw FileSystemFailure.systemCall("fstatat", errno)
    }
    return identity(from: details)
  }

  static func identity(from details: stat) -> FileIdentity {
    let type = details.st_mode & mode_t(S_IFMT)
    let kind: EntryKind
    switch type {
    case mode_t(S_IFREG): kind = .regular
    case mode_t(S_IFDIR): kind = .directory
    case mode_t(S_IFLNK): kind = .symbolicLink
    default: kind = .other
    }
    return FileIdentity(
      device: UInt64(details.st_dev), inode: details.st_ino,
      changeSeconds: Int64(details.st_ctimespec.tv_sec),
      changeNanoseconds: Int64(details.st_ctimespec.tv_nsec),
      logicalBytes: details.st_size,
      allocatedBytes: Int64(details.st_blocks) * 512,
      linkCount: UInt64(details.st_nlink), flags: details.st_flags,
      kind: kind,
      birthSeconds: details.st_birthtimespec.tv_sec > 0
        ? Int64(details.st_birthtimespec.tv_sec) : nil,
      birthNanoseconds: details.st_birthtimespec.tv_sec > 0
        ? Int64(details.st_birthtimespec.tv_nsec) : nil,
      modificationSeconds: Int64(details.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(details.st_mtimespec.tv_nsec)
    )
  }

  static func validatedComponents(_ path: String) throws -> [String] {
    guard path.hasPrefix("/"), !path.contains("\0") else { throw FileSystemFailure.invalidPath }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
    guard !parts.isEmpty,
      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !path.hasSuffix("/")
    else { throw FileSystemFailure.invalidPath }
    return parts
  }
}

public struct PathIdentity: Codable, Sendable, Equatable {
  public let path: String
  public let identity: FileIdentity

  public init(path: String, identity: FileIdentity) {
    self.path = path
    self.identity = identity
  }
}
