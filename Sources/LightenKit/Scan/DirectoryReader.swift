import CLightenPlatform
import Darwin
import Foundation
import Synchronization

/// Syscall and work counters shared by the walker's readers.
public final class ScanCounters: Sendable {
  let opens = Atomic<Int>(0)
  let bulkCalls = Atomic<Int>(0)
  let fallbackStats = Atomic<Int>(0)
  let directories = Atomic<Int>(0)
  let entries = Atomic<Int>(0)
  /// Eligible sink records with unavailable identity or required dates.
  let sinkMetadataUnavailable = Atomic<Int>(0)
  /// Unavailable records that could not be emitted, a subset of the above.
  let sinkOmittedFiles = Atomic<Int>(0)

  public init() {}

  public var snapshot: [String: Int] {
    [
      "opens": opens.load(ordering: .relaxed), "bulkCalls": bulkCalls.load(ordering: .relaxed),
      "fallbackStats": fallbackStats.load(ordering: .relaxed),
      "directories": directories.load(ordering: .relaxed), "entries": entries.load(ordering: .relaxed),
      "sinkMetadataUnavailable": sinkMetadataUnavailable.load(ordering: .relaxed),
      "sinkOmittedFiles": sinkOmittedFiles.load(ordering: .relaxed),
    ]
  }
}

/// One directory entry as observed by a single metadata call; never followed.
public struct RawEntry: Sendable {
  public var name: String
  public var kind: EntryKind
  public var device: UInt64
  public var inode: UInt64
  public var flags: UInt32
  public var linkCount: UInt32
  public var logical: Int64
  public var allocated: Int64
  /// Nonzero when the filesystem reported a per-entry attribute error.
  public var error: Int32
  public var birthTime: FileTimestamp? = nil
  public var modificationTime: FileTimestamp? = nil
  public var changeTime: FileTimestamp? = nil
  public var addedTime: FileTimestamp? = nil
  public var identityLogicalBytes: Int64? = nil

  /// Missing ctime cannot be represented by FileIdentity; never invent one.
  public var identity: FileIdentity? {
    guard error == 0, let changeTime else { return nil }
    guard kind != .regular || identityLogicalBytes != nil else { return nil }
    return FileIdentity(
      device: device, inode: inode, changeSeconds: changeTime.seconds,
      changeNanoseconds: changeTime.nanoseconds, logicalBytes: identityLogicalBytes ?? logical,
      allocatedBytes: allocated,
      linkCount: UInt64(linkCount), flags: flags, kind: kind,
      birthSeconds: birthTime?.seconds, birthNanoseconds: birthTime?.nanoseconds,
      modificationSeconds: modificationTime?.seconds, modificationNanoseconds: modificationTime?.nanoseconds)
  }
}

public enum DirectoryReadFailure: Error, Sendable, Equatable {
  case open(Int32)
  case changed
  case read(Int32)
  case cancelled
}

/// Reads one directory per call: a single no-follow open, bulk metadata reads,
/// and close before returning, so a worker holds at most one directory descriptor.
public final class DirectoryReader {
  private let buffer: UnsafeMutableRawPointer
  private let bufferSize: Int
  private let entries: UnsafeMutablePointer<LightenDirEntry>
  private let capacity: Int
  private let counters: ScanCounters
  private let includeFileMetadata: Bool

  /// 64 KB keeps one bulk call short even in very large folders, so cancellation
  /// and progress stay responsive.
  public init(counters: ScanCounters, bufferSize: Int = 64 * 1024, includeFileMetadata: Bool = false) {
    self.counters = counters
    self.includeFileMetadata = includeFileMetadata
    self.bufferSize = bufferSize
    self.buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    self.capacity = bufferSize / 32
    self.entries = .allocate(capacity: capacity)
  }

  deinit {
    buffer.deallocate()
    entries.deallocate()
  }

  /// `expected` guards against a directory replaced after its parent listed it.
  public func read(
    path: String, expected: (device: UInt64, inode: UInt64)?, includeFileMetadata: Bool? = nil,
    isCancelled: () -> Bool, visit: (RawEntry) -> Void
  ) throws(DirectoryReadFailure) {
    let metadata = includeFileMetadata ?? self.includeFileMetadata
    let fd = Self.openDirectory(path)
    counters.opens.add(1, ordering: .relaxed)
    guard fd >= 0 else { throw .open(errno) }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0 else { throw .open(errno) }
    if let expected, UInt64(details.st_dev) != expected.device || details.st_ino != expected.inode {
      throw .changed
    }
    counters.directories.add(1, ordering: .relaxed)
    var batches = 0
    while true {
      if isCancelled() { throw .cancelled }
      let count =
        metadata
        ? lighten_bulk_read_metadata(fd, buffer, bufferSize, entries, Int32(capacity))
        : lighten_bulk_read(fd, buffer, bufferSize, entries, Int32(capacity))
      counters.bulkCalls.add(1, ordering: .relaxed)
      if count == 0 { return }
      if count < 0 {
        let code = errno
        // Fall back only before any batch was delivered, so no entry is visited twice.
        if batches == 0 && (code == ENOTSUP || code == EINVAL) {
          try readWithStat(fd: fd, isCancelled: isCancelled, visit: visit)
          return
        }
        throw .read(code)
      }
      batches += 1
      counters.entries.add(Int(count), ordering: .relaxed)
      for index in 0..<Int(count) {
        if isCancelled() { throw .cancelled }
        let raw = entries[index]
        let name = String(
          decoding: UnsafeRawBufferPointer(
            start: buffer.advanced(by: Int(raw.name_offset)), count: Int(raw.name_length)),
          as: UTF8.self)
        if name == "." || name == ".." { continue }
        // Missing flags could hide a dataless folder; a file without sizes or a
        // link count cannot be summed or deduplicated. Either is an entry error.
        let common = UInt32(LIGHTEN_HAS_KIND | LIGHTEN_HAS_FILE_ID | LIGHTEN_HAS_DEVICE | LIGHTEN_HAS_FLAGS)
        let sized = UInt32(LIGHTEN_HAS_LOGICAL | LIGHTEN_HAS_ALLOCATED | LIGHTEN_HAS_LINK_COUNT)
        let isDirectory = Int(raw.kind) == Int(LIGHTEN_OBJ_DIRECTORY)
        let complete =
          raw.returned & common == common && (isDirectory || raw.returned & sized == sized)
        visit(
          RawEntry(
            name: name, kind: Self.kind(raw.kind), device: UInt64(raw.device), inode: raw.file_id,
            flags: raw.flags, linkCount: raw.link_count, logical: raw.logical, allocated: raw.allocated,
            error: raw.error != 0 ? raw.error : complete ? 0 : EIO,
            birthTime: Self.timestamp(
              raw, bit: LIGHTEN_HAS_BIRTH_TIME, seconds: raw.birth_seconds,
              nanoseconds: raw.birth_nanoseconds, positive: true),
            modificationTime: Self.timestamp(
              raw, bit: LIGHTEN_HAS_MOD_TIME, seconds: raw.mod_seconds,
              nanoseconds: raw.mod_nanoseconds),
            changeTime: Self.timestamp(
              raw, bit: LIGHTEN_HAS_CHANGE_TIME, seconds: raw.change_seconds,
              nanoseconds: raw.change_nanoseconds),
            addedTime: Self.timestamp(
              raw, bit: LIGHTEN_HAS_ADDED_TIME, seconds: raw.added_seconds,
              nanoseconds: raw.added_nanoseconds, positive: true),
            identityLogicalBytes: raw.returned & UInt32(LIGHTEN_HAS_DATA_LOGICAL) != 0 ? raw.data_logical : nil))
      }
    }
  }

  /// Filesystems without bulk attributes: readdir plus one fstatat per entry.
  private func readWithStat(
    fd: Int32, isCancelled: () -> Bool, visit: (RawEntry) -> Void
  ) throws(DirectoryReadFailure) {
    let copy = dup(fd)
    guard copy >= 0, let directory = fdopendir(copy) else {
      let code = errno
      if copy >= 0 { close(copy) }
      throw .read(code)
    }
    defer { closedir(directory) }
    rewinddir(directory)
    while true {
      if isCancelled() { throw .cancelled }
      errno = 0
      guard let item = readdir(directory) else {
        if errno != 0 { throw .read(errno) }
        return
      }
      let name = withUnsafePointer(to: &item.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      var details = stat()
      counters.fallbackStats.add(1, ordering: .relaxed)
      counters.entries.add(1, ordering: .relaxed)
      guard fstatat(fd, name, &details, AT_SYMLINK_NOFOLLOW) == 0 else {
        visit(
          RawEntry(
            name: name, kind: .other, device: 0, inode: 0, flags: 0, linkCount: 0, logical: 0,
            allocated: 0, error: errno))
        continue
      }
      let identity = DescriptorFileSystem.identity(from: details)
      visit(
        RawEntry(
          name: name, kind: identity.kind, device: identity.device, inode: identity.inode,
          flags: identity.flags, linkCount: UInt32(clamping: identity.linkCount),
          logical: identity.kind == .directory ? 0 : identity.logicalBytes,
          allocated: identity.allocatedBytes, error: 0,
          birthTime: identity.birthSeconds.flatMap { seconds in
            identity.birthNanoseconds.map { FileTimestamp(seconds: seconds, nanoseconds: $0) }
          },
          modificationTime: FileTimestamp(
            seconds: Int64(details.st_mtimespec.tv_sec),
            nanoseconds: Int64(details.st_mtimespec.tv_nsec)),
          changeTime: FileTimestamp(seconds: identity.changeSeconds, nanoseconds: identity.changeNanoseconds),
          identityLogicalBytes: identity.logicalBytes))
    }
  }

  static func openDirectory(_ path: String) -> Int32 {
    let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
    if path.utf8.count < Int(PATH_MAX) - 1 { return open(path, flags) }
    // Very deep paths: descend component by component, still without following links.
    guard let components = try? DescriptorFileSystem.validatedComponents(path) else {
      errno = ENAMETOOLONG
      return -1
    }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    for component in components {
      guard fd >= 0 else { return -1 }
      let next = openat(fd, component, flags)
      let code = errno
      close(fd)
      errno = code
      fd = next
    }
    return fd
  }

  private static func timestamp(
    _ entry: LightenDirEntry, bit: Int, seconds: Int64, nanoseconds: Int64, positive: Bool = false
  ) -> FileTimestamp? {
    guard entry.returned & UInt32(bit) != 0, (0..<1_000_000_000).contains(nanoseconds),
      !positive || seconds > 0
    else { return nil }
    return FileTimestamp(seconds: seconds, nanoseconds: nanoseconds)
  }

  private static func kind(_ value: UInt32) -> EntryKind {
    switch Int(value) {
    case Int(LIGHTEN_OBJ_REGULAR): .regular
    case Int(LIGHTEN_OBJ_DIRECTORY): .directory
    case Int(LIGHTEN_OBJ_SYMLINK): .symbolicLink
    default: .other
    }
  }
}
