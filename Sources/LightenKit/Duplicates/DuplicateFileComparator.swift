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
  private let discoveryCache: DuplicateDigestCache?

  public init(hasher: any DuplicateHashing = SHA256DuplicateHashing()) {
    self.hasher = hasher
    self.discoveryCache = hasher is SHA256DuplicateHashing ? .shared : nil
  }

  init(hasher: any DuplicateHashing, discoveryCache: DuplicateDigestCache) {
    self.hasher = hasher
    self.discoveryCache = discoveryCache
  }

  func discoverySample(_ entry: ScanEntry, volumeID: UUID) throws -> Data {
    try discoveryValue(entry, volumeID: volumeID, stage: .sample)
  }

  func discoveryDigest(_ entry: ScanEntry, volumeID: UUID) throws -> Data {
    try discoveryValue(entry, volumeID: volumeID, stage: .full)
  }

  private func discoveryValue(
    _ entry: ScanEntry, volumeID: UUID, stage: DuplicateDigestCache.Stage
  ) throws -> Data {
    try Task.checkCancellation()
    guard let identity = entry.identity else { throw DuplicateFailure.unavailable }
    let fd = try openVerified(entry, volumeID: volumeID, discovery: true)
    defer { close(fd) }
    if let cached = discoveryCache?.value(for: identity, stage: stage) {
      try verify(fd, entry: entry, volumeID: volumeID, discovery: true)
      return cached
    }
    let value =
      try stage == .sample
      ? sample(fd: fd, size: identity.logicalBytes) : hasher.digest(fd: fd, size: identity.logicalBytes)
    try verify(fd, entry: entry, volumeID: volumeID, discovery: true)
    discoveryCache?.insert(value, for: identity, stage: stage)
    return value
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
    let value = try sample(fd: fd, size: size)
    try verify(fd, entry: entry, volumeID: volumeID)
    return value
  }

  private func sample(fd: Int32, size: Int64) throws -> Data {
    let width = min(Int64(65_536), size)
    let offsets = size <= width ? [Int64(0)] : [Int64(0), size - width]
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
    return Data(hash.finalize())
  }

  public func compare(
    _ first: ScanEntry, _ second: ScanEntry, volumeID: UUID,
    expectedFirstDigest: Data? = nil, expectedSecondDigest: Data? = nil
  ) throws -> DuplicateComparison {
    try compareWithMetadataWarnings(
      first, second, volumeID: volumeID,
      expectedFirstDigest: expectedFirstDigest, expectedSecondDigest: expectedSecondDigest
    ).comparison
  }

  func compareWithMetadataWarnings(
    _ first: ScanEntry, _ second: ScanEntry, volumeID: UUID,
    expectedFirstDigest: Data? = nil, expectedSecondDigest: Data? = nil
  ) throws -> (comparison: DuplicateComparison, warnings: [DuplicateMetadataWarning]) {
    try compareFiles(
      first, second, volumeID: volumeID, expectedFirstDigest: expectedFirstDigest,
      expectedSecondDigest: expectedSecondDigest, discovery: false)
  }

  func discoveryCompare(_ first: ScanEntry, _ second: ScanEntry, volumeID: UUID) throws
    -> (comparison: DuplicateComparison, warnings: [DuplicateMetadataWarning])
  {
    try compareFiles(first, second, volumeID: volumeID, discovery: true)
  }

  private func compareFiles(
    _ first: ScanEntry, _ second: ScanEntry, volumeID: UUID,
    expectedFirstDigest: Data? = nil, expectedSecondDigest: Data? = nil, discovery: Bool
  ) throws -> (comparison: DuplicateComparison, warnings: [DuplicateMetadataWarning]) {
    try Task.checkCancellation()
    guard let a = first.identity, let b = second.identity,
      a.logicalBytes == b.logicalBytes,
      !(a.device == b.device && a.inode == b.inode)
    else { return (.dataDifferent, []) }
    let firstFD = try openVerified(first, volumeID: volumeID, discovery: discovery)
    defer { close(firstFD) }
    let secondFD = try openVerified(second, volumeID: volumeID, discovery: discovery)
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
      try verify(firstFD, entry: first, volumeID: volumeID, discovery: discovery)
      try verify(secondFD, entry: second, volumeID: volumeID, discovery: discovery)
      return (.dataDifferent, [])
    }
    let metadata = try compareMetadata(firstFD, secondFD)
    // Re-list and re-read ACLs, attributes, and forks after comparison.
    let repeated = try compareMetadata(firstFD, secondFD)
    try Task.checkCancellation()
    try verify(firstFD, entry: first, volumeID: volumeID, discovery: discovery)
    try verify(secondFD, entry: second, volumeID: volumeID, discovery: discovery)
    if metadata.comparison == .metadataUnknown || repeated.comparison == .metadataUnknown {
      return (.metadataUnknown, [])
    }
    if metadata.comparison == .metadataDifferent || repeated.comparison == .metadataDifferent {
      return (.metadataDifferent, [])
    }
    return (.equal, Array(Set(metadata.warnings + repeated.warnings)).sorted { $0.rawValue < $1.rawValue })
  }

  private func openVerified(_ entry: ScanEntry, volumeID: UUID, discovery: Bool = false) throws -> Int32 {
    guard let expected = entry.identity, expected.kind == .regular,
      expected.hasStableTrashProof, expected.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
      entry.readable, entry.issues.isEmpty,
      ProtectionPolicy.rule(for: entry.path, homeDirectory: NSHomeDirectory()) == nil
        || (discovery
          && ProtectionPolicy.rule(for: entry.path, homeDirectory: NSHomeDirectory())?.id == "mobile-documents"),
      !PackageNames.isPackage(atPath: entry.path),
      !PackageNames.containsPackage(in: entry.path, isDirectory: false),
      discovery || (try? DescriptorFileSystem.volumeID(at: entry.path)) == volumeID
    else { throw DuplicateFailure.unavailable }
    let (parent, name) = try DescriptorFileSystem.openParent(of: entry.path)
    defer { close(parent) }
    let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw DuplicateFailure.unavailable }
    do { try verify(fd, entry: entry, volumeID: volumeID, discovery: discovery) } catch {
      close(fd)
      throw error
    }
    return fd
  }

  private func verify(_ fd: Int32, entry: ScanEntry, volumeID: UUID, discovery: Bool = false) throws {
    var info = stat()
    guard fstat(fd, &info) == 0,
      let expected = entry.identity,
      DescriptorFileSystem.identity(from: info) == expected,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      info.st_flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
      discovery || (try? DescriptorFileSystem.volumeID(at: entry.path)) == volumeID,
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

  private func compareMetadata(_ a: Int32, _ b: Int32) throws
    -> (comparison: DuplicateComparison, warnings: [DuplicateMetadataWarning])
  {
    try Task.checkCancellation()
    var left = stat()
    var right = stat()
    guard fstat(a, &left) == 0, fstat(b, &right) == 0 else { return (.metadataUnknown, []) }
    guard left.st_uid == geteuid(), right.st_uid == geteuid() else { return (.metadataUnknown, []) }
    let protectionFlags = UInt32(UF_IMMUTABLE | UF_APPEND) | ~UInt32(UF_SETTABLE)
    guard left.st_uid == right.st_uid, left.st_gid == right.st_gid,
      left.st_mode & ~mode_t(0o777) == right.st_mode & ~mode_t(0o777),
      left.st_flags & protectionFlags == right.st_flags & protectionFlags
    else { return (.metadataDifferent, []) }
    var warnings: Set<DuplicateMetadataWarning> = []
    if left.st_mode != right.st_mode { warnings.insert(.permissions) }
    if left.st_flags & UInt32(UF_COMPRESSED) != right.st_flags & UInt32(UF_COMPRESSED) { warnings.insert(.compression) }
    if left.st_flags & ~UInt32(UF_COMPRESSED) != right.st_flags & ~UInt32(UF_COMPRESSED) {
      warnings.insert(.fileInformation)
    }
    if left.st_mtimespec.tv_sec != right.st_mtimespec.tv_sec || left.st_mtimespec.tv_nsec != right.st_mtimespec.tv_nsec
      || left.st_birthtimespec.tv_sec != right.st_birthtimespec.tv_sec
      || left.st_birthtimespec.tv_nsec != right.st_birthtimespec.tv_nsec
    {
      warnings.insert(.fileInformation)
    }
    let firstACL = try aclBytes(a)
    let secondACL = try aclBytes(b)
    guard let firstACL, let secondACL else { return (.metadataUnknown, []) }
    guard firstACL.deny == secondACL.deny else { return (.metadataDifferent, []) }
    if firstACL.all != secondACL.all { warnings.insert(.fileInformation) }
    try Task.checkCancellation()
    guard let firstNames = try xattrNames(a), let secondNames = try xattrNames(b)
    else { return (.metadataUnknown, []) }
    let strictFirst = firstNames.filter { informationalWarning(for: $0) == nil }
    let strictSecond = secondNames.filter { informationalWarning(for: $0) == nil }
    guard strictFirst == strictSecond else { return (.metadataDifferent, []) }
    var totalA = 0
    var totalB = 0
    for name in strictFirst where name != Array("com.apple.ResourceFork".utf8) {
      try Task.checkCancellation()
      guard let first = try xattrValue(a, name: name, total: &totalA),
        let second = try xattrValue(b, name: name, total: &totalB)
      else { return (.metadataUnknown, []) }
      guard first == second else { return (.metadataDifferent, []) }
    }
    for bytes in Set(firstNames + secondNames) {
      guard let warning = informationalWarning(for: bytes) else { continue }
      let hasFirst = firstNames.contains(bytes)
      let hasSecond = secondNames.contains(bytes)
      if hasFirst != hasSecond {
        warnings.insert(warning)
      } else if hasFirst {
        guard let first = try xattrValue(a, name: bytes, total: &totalA),
          let second = try xattrValue(b, name: bytes, total: &totalB)
        else { return (.metadataUnknown, []) }
        if first != second { warnings.insert(warning) }
      }
    }
    return (try compareFork(a, b), warnings.sorted { $0.rawValue < $1.rawValue })
  }

  private func informationalWarning(for bytes: [UInt8]) -> DuplicateMetadataWarning? {
    let name = String(decoding: bytes, as: UTF8.self)
    switch name {
    case "com.apple.quarantine": return .quarantine
    case "com.apple.metadata:kMDItemWhereFroms": return .downloadSource
    case "com.apple.metadata:_kMDItemUserTags": return .finderTags
    case "com.apple.decmpfs": return .compression
    case "com.apple.lastuseddate#PS", "com.apple.FinderInfo", "com.apple.macl", "com.apple.provenance":
      return .fileInformation
    default: return name.hasPrefix("com.apple.metadata:") ? .fileInformation : nil
    }
  }

  private func aclBytes(_ fd: Int32) throws -> (all: Data, deny: Data)? {
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
      return errno == ENOENT ? (Data(), Data()) : nil
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_valid(acl) == 0, let all = serializedACL(acl) else { return nil }
    var denyACL: acl_t? = acl_init(0)
    guard denyACL != nil else { return nil }
    defer { acl_free(UnsafeMutableRawPointer(denyACL!)) }
    var entry: acl_entry_t?
    var index: Int32 = 0
    var denies = 0
    while acl_get_entry(acl, index, &entry) == 0 {
      try Task.checkCancellation()
      guard let entry else { return nil }
      var tag = ACL_UNDEFINED_TAG
      guard acl_get_tag_type(entry, &tag) == 0 else { return nil }
      switch tag {
      case ACL_EXTENDED_DENY:
        var copied: acl_entry_t?
        guard acl_create_entry(&denyACL, &copied) == 0, let copied,
          acl_copy_entry(copied, entry) == 0
        else { return nil }
        denies += 1
      case ACL_EXTENDED_ALLOW: break
      default: return nil
      }
      index += 1
    }
    guard errno == EINVAL else { return nil }
    guard denies > 0 else { return (all, Data()) }
    guard let denyACL, let deny = serializedACL(denyACL) else { return nil }
    return (all, deny)
  }

  private func serializedACL(_ acl: acl_t) -> Data? {
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
