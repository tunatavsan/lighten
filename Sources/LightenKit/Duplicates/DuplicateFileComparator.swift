import CryptoKit
import Darwin
import Foundation

public protocol DuplicateHashing: Sendable {
  func digest(fd: Int32, size: Int64) throws -> Data
}

public struct SHA256DuplicateHashing: DuplicateHashing {
  public init() {}

  public func digest(fd: Int32, size: Int64) throws -> Data {
    var hash = SHA256()
    var buffer = [UInt8](repeating: 0, count: DuplicateFileComparator.chunkSize)
    var offset: Int64 = 0
    while offset < size {
      try Task.checkCancellation()
      let amount = min(buffer.count, Int(size - offset))
      let readCount = buffer.withUnsafeMutableBytes {
        pread(fd, $0.baseAddress, amount, off_t(offset))
      }
      guard readCount == amount else { throw DuplicateFailure.changed }
      hash.update(data: Data(buffer[0..<amount]))
      offset += Int64(amount)
    }
    return Data(hash.finalize())
  }
}

public enum DuplicateComparison: Sendable, Equatable {
  case equal, dataDifferent, metadataDifferent, metadataUnknown
}

/// Descriptor-backed comparison. Every public entry point is synchronous and
/// is called by a detached task, never on the app's main actor.
public struct DuplicateFileComparator: Sendable {
  public static let chunkSize = 1_048_576
  private static let aclCap = 65_536
  private static let nameCap = 65_536
  private static let xattrCap = 1_048_576
  private static let xattrTotalCap = 4_194_304
  private static let forkCap = 67_108_864
  private let hasher: any DuplicateHashing

  public init(hasher: any DuplicateHashing = SHA256DuplicateHashing()) {
    self.hasher = hasher
  }

  public func digest(_ entry: ScanEntry, volumeID: UUID) throws -> Data {
    try Task.checkCancellation()
    let fd = try openVerified(entry, volumeID: volumeID)
    defer { close(fd) }
    guard let expected = entry.identity else { throw DuplicateFailure.unavailable }
    let value = try hasher.digest(fd: fd, size: expected.logicalBytes)
    try verify(fd, entry: entry, volumeID: volumeID)
    return value
  }

  public func sample(_ entry: ScanEntry, volumeID: UUID) throws -> Data {
    try Task.checkCancellation()
    let fd = try openVerified(entry, volumeID: volumeID)
    defer { close(fd) }
    guard let size = entry.identity?.logicalBytes else { throw DuplicateFailure.unavailable }
    let width = min(Int64(4096), size)
    let offsets = [Int64(0), max(0, size / 2 - width / 2), max(0, size - width)]
    var hash = SHA256()
    var buffer = [UInt8](repeating: 0, count: Int(width))
    let sampleCount = buffer.count
    for offset in offsets {
      try Task.checkCancellation()
      let readCount = buffer.withUnsafeMutableBytes {
        pread(fd, $0.baseAddress, sampleCount, off_t(offset))
      }
      guard readCount == sampleCount else { throw DuplicateFailure.changed }
      hash.update(data: Data(buffer))
    }
    try verify(fd, entry: entry, volumeID: volumeID)
    return Data(hash.finalize())
  }

  public func compare(
    _ first: ScanEntry, _ second: ScanEntry, volumeID: UUID,
    expectedFirstDigest: Data? = nil, expectedSecondDigest: Data? = nil
  ) throws -> DuplicateComparison {
    try Task.checkCancellation()
    guard let a = first.identity, let b = second.identity,
      a.logicalBytes == b.logicalBytes,
      !(a.device == b.device && a.inode == b.inode)
    else { return .dataDifferent }
    let firstFD = try openVerified(first, volumeID: volumeID)
    defer { close(firstFD) }
    let secondFD = try openVerified(second, volumeID: volumeID)
    defer { close(secondFD) }
    if let expectedFirstDigest {
      guard try hasher.digest(fd: firstFD, size: a.logicalBytes) == expectedFirstDigest
      else { throw DuplicateFailure.changed }
    }
    if let expectedSecondDigest {
      guard try hasher.digest(fd: secondFD, size: b.logicalBytes) == expectedSecondDigest
      else { throw DuplicateFailure.changed }
    }
    try Task.checkCancellation()
    guard try compareData(firstFD, secondFD, size: a.logicalBytes) else {
      try verify(firstFD, entry: first, volumeID: volumeID)
      try verify(secondFD, entry: second, volumeID: volumeID)
      return .dataDifferent
    }
    let metadata = try compareMetadata(firstFD, secondFD)
    // Re-list and re-read ACLs, attributes, and forks after comparison.
    let repeated = try compareMetadata(firstFD, secondFD)
    try Task.checkCancellation()
    try verify(firstFD, entry: first, volumeID: volumeID)
    try verify(secondFD, entry: second, volumeID: volumeID)
    if metadata == .metadataUnknown || repeated == .metadataUnknown { return .metadataUnknown }
    if metadata == .metadataDifferent || repeated == .metadataDifferent { return .metadataDifferent }
    return .equal
  }

  private func openVerified(_ entry: ScanEntry, volumeID: UUID) throws -> Int32 {
    guard let expected = entry.identity, expected.kind == .regular,
      expected.hasStableTrashProof, expected.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
      entry.readable, entry.issues.isEmpty,
      ProtectionPolicy.rule(for: entry.path, homeDirectory: NSHomeDirectory()) == nil,
      !ScanService.isPackage(entry.path), !ScanService.isInsidePackage(entry.path),
      (try? DescriptorFileSystem.volumeID(at: entry.path)) == volumeID
    else { throw DuplicateFailure.unavailable }
    let (parent, name) = try DescriptorFileSystem.openParent(of: entry.path)
    defer { close(parent) }
    let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw DuplicateFailure.unavailable }
    do { try verify(fd, entry: entry, volumeID: volumeID) } catch {
      close(fd)
      throw error
    }
    return fd
  }

  private func verify(_ fd: Int32, entry: ScanEntry, volumeID: UUID) throws {
    var info = stat()
    guard fstat(fd, &info) == 0,
      let expected = entry.identity,
      DescriptorFileSystem.identity(from: info) == expected,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      info.st_flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
      (try? DescriptorFileSystem.volumeID(at: entry.path)) == volumeID,
      (try? DescriptorFileSystem.identity(at: entry.path)) == expected
    else { throw DuplicateFailure.changed }
  }

  private func compareData(_ a: Int32, _ b: Int32, size: Int64) throws -> Bool {
    try Task.checkCancellation()
    var left = [UInt8](repeating: 0, count: Self.chunkSize)
    var right = [UInt8](repeating: 0, count: Self.chunkSize)
    var offset: Int64 = 0
    while offset < size {
      try Task.checkCancellation()
      let amount = min(Self.chunkSize, Int(size - offset))
      let aCount = left.withUnsafeMutableBytes { pread(a, $0.baseAddress, amount, off_t(offset)) }
      let bCount = right.withUnsafeMutableBytes { pread(b, $0.baseAddress, amount, off_t(offset)) }
      guard aCount == amount, bCount == amount else { throw DuplicateFailure.changed }
      if !left[0..<amount].elementsEqual(right[0..<amount]) { return false }
      offset += Int64(amount)
    }
    return true
  }

  private func compareMetadata(_ a: Int32, _ b: Int32) throws -> DuplicateComparison {
    try Task.checkCancellation()
    var left = stat()
    var right = stat()
    guard fstat(a, &left) == 0, fstat(b, &right) == 0 else { return .metadataUnknown }
    guard left.st_uid == geteuid(), right.st_uid == geteuid() else { return .metadataUnknown }
    guard left.st_uid == right.st_uid, left.st_gid == right.st_gid,
      left.st_mode == right.st_mode, left.st_flags == right.st_flags
    else { return .metadataDifferent }
    let firstACL = try aclBytes(a)
    let secondACL = try aclBytes(b)
    guard let firstACL, let secondACL else { return .metadataUnknown }
    guard firstACL == secondACL else { return .metadataDifferent }
    try Task.checkCancellation()
    guard let firstNames = try xattrNames(a), let secondNames = try xattrNames(b)
    else { return .metadataUnknown }
    guard firstNames == secondNames else { return .metadataDifferent }
    var totalA = 0
    var totalB = 0
    for name in firstNames where name != Array("com.apple.ResourceFork".utf8) {
      try Task.checkCancellation()
      guard let first = try xattrValue(a, name: name, total: &totalA),
        let second = try xattrValue(b, name: name, total: &totalB)
      else { return .metadataUnknown }
      guard first == second else { return .metadataDifferent }
    }
    return try compareFork(a, b)
  }

  private func aclBytes(_ fd: Int32) throws -> Data? {
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
      return errno == ENOENT ? Data() : nil
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    let size = acl_size(acl)
    guard size >= 0, size <= Self.aclCap else { return nil }
    var result = Data(count: Int(size))
    let copied = result.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, acl, size) }
    guard copied == size else { return nil }
    return result
  }

  private func xattrNames(_ fd: Int32) throws -> [[UInt8]]? {
    let size = flistxattr(fd, nil, 0, XATTR_SHOWCOMPRESSION)
    guard size >= 0, size <= Self.nameCap else { return nil }
    if size == 0 { return [] }
    var bytes = [CChar](repeating: 0, count: size)
    let readCount = bytes.withUnsafeMutableBufferPointer {
      flistxattr(fd, $0.baseAddress, $0.count, XATTR_SHOWCOMPRESSION)
    }
    guard readCount == size, bytes.last == 0 else { return nil }
    var names: [[UInt8]] = []
    var current: [UInt8] = []
    for byte in bytes {
      if byte == 0 {
        guard !current.isEmpty, String(bytes: current, encoding: .utf8) != nil else { return nil }
        names.append(current)
        current = []
      } else {
        current.append(UInt8(bitPattern: byte))
      }
    }
    names.sort { $0.lexicographicallyPrecedes($1) }
    guard Set(names).count == names.count else { return nil }
    return names
  }

  private func xattrValue(_ fd: Int32, name: [UInt8], total: inout Int) throws -> Data? {
    let cName = name.map { CChar(bitPattern: $0) } + [0]
    return cName.withUnsafeBufferPointer { pointer in
      guard let namePointer = pointer.baseAddress else { return nil }
      let size = fgetxattr(fd, namePointer, nil, 0, 0, 0)
      guard size >= 0, size <= Self.xattrCap, total <= Self.xattrTotalCap - size else { return nil }
      var value = Data(count: size)
      let readCount = value.withUnsafeMutableBytes {
        fgetxattr(fd, namePointer, $0.baseAddress, $0.count, 0, 0)
      }
      guard readCount == size else { return nil }
      total += size
      return value
    }
  }

  private func compareFork(_ a: Int32, _ b: Int32) throws -> DuplicateComparison {
    try Task.checkCancellation()
    let name = "com.apple.ResourceFork"
    let aSize = fgetxattr(a, name, nil, 0, 0, 0)
    let aError = errno
    let bSize = fgetxattr(b, name, nil, 0, 0, 0)
    let bError = errno
    if aSize < 0 || bSize < 0 {
      if aSize < 0 && bSize < 0 && aError == ENOATTR && bError == ENOATTR { return .equal }
      if (aSize < 0 && aError == ENOATTR && bSize >= 0)
        || (bSize < 0 && bError == ENOATTR && aSize >= 0)
      {
        return .metadataDifferent
      }
      return .metadataUnknown
    }
    guard aSize == bSize else { return .metadataDifferent }
    guard aSize <= Self.forkCap else { return .metadataUnknown }
    var left = [UInt8](repeating: 0, count: Self.chunkSize)
    var right = [UInt8](repeating: 0, count: Self.chunkSize)
    var offset = 0
    while offset < aSize {
      try Task.checkCancellation()
      let amount = min(Self.chunkSize, aSize - offset)
      let aCount = left.withUnsafeMutableBytes {
        fgetxattr(a, name, $0.baseAddress, amount, UInt32(offset), 0)
      }
      let bCount = right.withUnsafeMutableBytes {
        fgetxattr(b, name, $0.baseAddress, amount, UInt32(offset), 0)
      }
      guard aCount == amount, bCount == amount else { return .metadataUnknown }
      if !left[0..<amount].elementsEqual(right[0..<amount]) { return .metadataDifferent }
      offset += amount
    }
    guard fgetxattr(a, name, nil, 0, 0, 0) == aSize,
      fgetxattr(b, name, nil, 0, 0, 0) == bSize
    else { return .metadataUnknown }
    return .equal
  }
}
