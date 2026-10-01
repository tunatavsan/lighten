import CryptoKit
import Darwin
import Foundation

/// Last completed scan tree per root, for an instant first screen on the next
/// visit. A cached tree is only a picture: plans never read it.
public struct ScanCache: Sendable {
  public let directory: String

  public let homeDirectory: String
  public let maximumBytes: Int
  public let maximumRoots: Int

  public init(
    directory: String = ScanCache.defaultDirectory, homeDirectory: String = NSHomeDirectory(),
    maximumBytes: Int = 300_000_000, maximumRoots: Int = 3
  ) {
    self.directory = directory
    self.homeDirectory = homeDirectory
    self.maximumBytes = maximumBytes
    self.maximumRoots = maximumRoots
  }

  public static var defaultDirectory: String {
    NSHomeDirectory() + "/Library/Application Support/Lighten/scan-cache"
  }

  static let magic: UInt32 = 0x4C_53_43_31  // "LSC1"

  func file(for root: String) -> String {
    let digest = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory + "/" + digest + ".bin"
  }

  public struct Entry: Sendable {
    public let tree: ScanTree
    public let savedAt: Date
    public let baseline: ScanReplayBaseline?
  }

  public enum Failure: Error, Equatable { case tooLarge, retainedHomeExceedsLimit }

  public func save(_ tree: ScanTree, baseline: ScanReplayBaseline? = nil) throws {
    guard tree.isFinished, !tree.wasCancelled else { return }
    // Arrays and strings are CoW: encoding owns a stable snapshot without
    // blocking readers for the duration of serialization.
    let snapshot = tree.storage.withLock { $0 }
    let payload = Self.encode(Self.compacted(snapshot), savedAt: Date())
    var writer = Writer()
    writer.u32(0x4C_53_43_33)
    writer.u64(baseline?.eventID ?? 0)
    writer.optionalString(baseline?.volumeUUID.uuidString)
    writer.optionalString(baseline?.storeUUID?.uuidString)
    let header = writer.data
    writer.data.append(contentsOf: SHA256.hash(data: header + payload))
    writer.data.append(payload)
    guard writer.data.count <= maximumBytes else { throw Failure.tooLarge }
    try prepareDirectory()
    try prune(reserving: writer.data.count, replacing: tree.rootPath)
    let name = URL(fileURLWithPath: file(for: tree.rootPath)).lastPathComponent
    try ResultPictureFile.write(directory: directory, name: name, data: writer.data, limit: maximumBytes)
    try prune(reserving: 0, replacing: nil)
  }

  public func load(root: String) -> (tree: ScanTree, savedAt: Date)? {
    loadEntry(root: root).map { ($0.tree, $0.savedAt) }
  }

  public func loadEntry(root: String) -> Entry? {
    let name = URL(fileURLWithPath: file(for: root)).lastPathComponent
    guard let data = try? ResultPictureFile.read(directory: directory, name: name, limit: maximumBytes) else {
      return nil
    }
    var reader = Reader(data: data)
    guard let format = reader.u32(), format == 0x4C_53_43_32 || format == 0x4C_53_43_33,
      let eventID = reader.u64(), let uuidText = reader.optionalString()
    else { return nil }
    var storeUUID: UUID?
    if format == 0x4C_53_43_33 {
      guard let storeText = reader.optionalString() else { return nil }
      storeUUID = storeText.flatMap(UUID.init(uuidString:))
    }
    guard
      reader.offset + 32 <= data.count
    else { return nil }
    let header = Data(data.prefix(reader.offset))
    let checksum = data[reader.offset..<(reader.offset + 32)]
    let payload = Data(data.dropFirst(reader.offset + 32))
    guard Data(SHA256.hash(data: header + payload)) == checksum,
      let decoded = Self.decode(payload), decoded.storage.rootPath == root,
      !decoded.storage.nodes.isEmpty, decoded.savedAt <= Date(),
      decoded.savedAt.timeIntervalSince1970.isFinite
    else { return nil }
    let baseline = uuidText.flatMap(UUID.init(uuidString:)).map {
      ScanReplayBaseline(eventID: eventID, volumeUUID: $0, storeUUID: storeUUID)
    }
    let tree = ScanTree(
      runID: UUID(), rootPath: root, root: decoded.storage.nodes[0], firmlinks: decoded.storage.firmlinks,
      startedAt: decoded.savedAt)
    tree.storage.withLock { storage in
      storage = decoded.storage
      storage.finished = true
      storage.cancelled = false
    }
    return Entry(tree: tree, savedAt: decoded.savedAt, baseline: baseline)
  }

  public func usageBytes() -> Int64 {
    cacheFiles().reduce(0) { $0 + $1.bytes }
  }

  public func clear() throws {
    for entry in cacheFiles() { try removeCacheFile(entry.path) }
  }

  private func cacheFiles() -> [(path: String, bytes: Int64, modified: Date)] {
    let fd = DirectoryReader.openDirectory(directory)
    guard fd >= 0 else { return [] }
    defer { close(fd) }
    guard let names = try? ExactInventory.names(fd: fd) else { return [] }
    return names.compactMap { name in
      let path = directory + "/" + name
      var info = stat()
      guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
      return (
        path, info.st_size,
        Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
      )
    }
  }

  private func prepareDirectory() throws {
    let components = try DescriptorFileSystem.validatedComponents(directory)
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw ResultPictureFailure.unsafe }
    defer { close(fd) }
    for component in components {
      var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      if next < 0 && errno == ENOENT {
        guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else {
          throw FileSystemFailure.systemCall("create scan cache directory", errno)
        }
        next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      }
      guard next >= 0 else { throw ResultPictureFailure.unsafe }
      close(fd)
      fd = next
    }
    var details = stat()
    guard fstat(fd, &details) == 0, details.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else {
      throw ResultPictureFailure.unsafe
    }
  }

  private func removeCacheFile(_ path: String) throws {
    let fd = DirectoryReader.openDirectory(directory)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open scan cache", errno) }
    defer { close(fd) }
    guard unlinkat(fd, URL(fileURLWithPath: path).lastPathComponent, 0) == 0 else {
      throw FileSystemFailure.systemCall("remove scan cache", errno)
    }
  }

  private static func isCurrentFormat(_ path: String) -> Bool {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var bytes = [UInt8](repeating: 0, count: 4)
    let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    return count == 4 && (bytes == [0x32, 0x43, 0x53, 0x4C] || bytes == [0x33, 0x43, 0x53, 0x4C])
  }

  private func prune(reserving bytes: Int, replacing root: String?) throws {
    let home = file(for: homeDirectory)
    let replacement = root.map(file(for:))
    var entries = cacheFiles().filter { $0.path != replacement }
    // Unsupported legacy files are disposable pictures, never scan evidence.
    for entry in entries {
      guard Self.isCurrentFormat(entry.path)
      else {
        try removeCacheFile(entry.path)
        continue
      }
    }
    entries = cacheFiles().filter { $0.path != replacement }
    var total = entries.reduce(Int64(bytes)) { $0 + $1.bytes }
    var count = entries.count + (bytes > 0 ? 1 : 0)
    for entry in entries.sorted(by: { $0.modified < $1.modified }) where entry.path != home {
      if total <= maximumBytes && count <= maximumRoots { break }
      try removeCacheFile(entry.path)
      total -= entry.bytes
      count -= 1
    }
    guard total <= maximumBytes && count <= maximumRoots else { throw Failure.retainedHomeExceedsLimit }
  }

  private static func compacted(_ snapshot: ScanTree.Storage) -> ScanTree.Storage {
    var result = snapshot
    var order: [Int32] = [0]
    var position = 0
    while position < order.count {
      order.append(contentsOf: snapshot.nodes[Int(order[position])].childNodes)
      position += 1
    }
    let mapping = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, Int32($0.offset)) })
    result.nodes = order.map { index in
      var node = snapshot.nodes[Int(index)]
      node.parent = node.parent < 0 ? -1 : mapping[node.parent]!
      node.childNodes = node.childNodes.map { mapping[$0]! }
      return node
    }
    return result
  }

  // MARK: Binary format (little-endian, versioned by magic)

  static func encode(_ storage: ScanTree.Storage, savedAt: Date) -> Data {
    var writer = Writer()
    writer.u32(magic)
    writer.f64(savedAt.timeIntervalSince1970)
    writer.string(storage.rootPath)
    writer.u32(UInt32(storage.firmlinks?.count ?? 0) | (storage.firmlinks == nil ? 0x8000_0000 : 0))
    for name in (storage.firmlinks ?? []).sorted() { writer.string(name) }
    writer.u32(UInt32(storage.nodes.count))
    for node in storage.nodes {
      writer.string(node.name)
      writer.optionalString(node.pathOverride)
      writer.i32(node.parent)
      writer.u8(node.kind.rawValue)
      writer.optionalString(node.protectedRule)
      writer.u8(node.ownReason?.rawValue ?? 255)
      writer.u8(node.partialDescendant ? 1 : 0)
      writer.u64(node.device)
      writer.u64(node.inode)
      writer.i64(node.logical)
      writer.i64(node.allocated)
      writer.i64(node.items)
      writer.u32(UInt32(node.childNodes.count))
      for child in node.childNodes { writer.i32(child) }
      writer.u32(UInt32(node.files.count))
      for file in node.files {
        writer.string(file.name)
        writer.i64(file.logical)
        writer.i64(file.allocated)
        writer.u8(file.kind.rawValue)
        writer.optionalString(file.protectedRule)
        writer.u64(file.inode)
        writer.u8(file.error ? 1 : 0)
      }
      writer.i64(node.smallCount)
      writer.i64(node.smallLogical)
      writer.i64(node.smallAllocated)
    }
    return writer.data
  }

  static func decode(_ data: Data) -> (storage: ScanTree.Storage, savedAt: Date)? {
    var reader = Reader(data: data)
    guard reader.u32() == magic, let seconds = reader.f64(), let rootPath = reader.string(),
      let firmlinkHeader = reader.u32()
    else { return nil }
    var storage = ScanTree.Storage()
    storage.rootPath = rootPath
    if firmlinkHeader & 0x8000_0000 == 0 {
      var names = Set<String>()
      for _ in 0..<firmlinkHeader {
        guard let name = reader.string() else { return nil }
        names.insert(name)
      }
      storage.firmlinks = names
    }
    guard let count = reader.u32(), count < 50_000_000 else { return nil }
    storage.nodes.reserveCapacity(Int(count))
    for _ in 0..<count {
      guard let name = reader.string(), let override = reader.optionalString(), let parent = reader.i32(),
        let kindRaw = reader.u8(), let kind = NodeKind(rawValue: kindRaw), let rule = reader.optionalString(),
        let reasonRaw = reader.u8(), let partialDescendant = reader.u8(), let device = reader.u64(),
        let inode = reader.u64(), let logical = reader.i64(), let allocated = reader.i64(), let items = reader.i64(),
        let childCount = reader.u32(),
        storage.nodes.isEmpty ? parent == -1 : (parent >= 0 && Int(parent) < storage.nodes.count)
      else { return nil }
      var node = ScanTree.Node(name: name, parent: parent, kind: kind, device: device, inode: inode)
      node.pathOverride = override
      node.protectedRule = rule
      node.ownReason = reasonRaw == 255 ? nil : PartialReason(rawValue: reasonRaw)
      node.partialDescendant = partialDescendant == 1
      node.lifecycle = .done
      node.logical = logical
      node.allocated = allocated
      node.items = items
      for _ in 0..<childCount {
        // Children always come after their parent, so the tree cannot contain a cycle.
        guard let child = reader.i32(), Int(child) > storage.nodes.count, Int(child) < Int(count) else { return nil }
        node.childNodes.append(child)
      }
      guard let fileCount = reader.u32(), fileCount <= UInt32(ScanTree.filesPerDirectory) else { return nil }
      for _ in 0..<fileCount {
        guard let fileName = reader.string(), let fileLogical = reader.i64(), let fileAllocated = reader.i64(),
          let fileKindRaw = reader.u8(), let fileKind = NodeKind(rawValue: fileKindRaw),
          let fileRule = reader.optionalString(), let fileInode = reader.u64(), let error = reader.u8()
        else { return nil }
        node.files.append(
          ScanTree.FileRecord(
            name: fileName, logical: fileLogical, allocated: fileAllocated, kind: fileKind, protectedRule: fileRule,
            inode: fileInode, error: error == 1))
      }
      guard let smallCount = reader.i64(), let smallLogical = reader.i64(), let smallAllocated = reader.i64() else {
        return nil
      }
      node.smallCount = smallCount
      node.smallLogical = smallLogical
      node.smallAllocated = smallAllocated
      storage.nodes.append(node)
    }
    guard reader.atEnd else { return nil }
    return (storage, Date(timeIntervalSince1970: seconds))
  }

  private struct Writer {
    var data = Data()
    mutating func raw<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u32(_ value: UInt32) { raw(value) }
    mutating func i32(_ value: Int32) { raw(value) }
    mutating func u64(_ value: UInt64) { raw(value) }
    mutating func i64(_ value: Int64) { raw(value) }
    mutating func f64(_ value: Double) { raw(value.bitPattern) }
    mutating func string(_ value: String) {
      let bytes = Array(value.utf8)
      u32(UInt32(bytes.count))
      data.append(contentsOf: bytes)
    }
    mutating func optionalString(_ value: String?) {
      if let value {
        u8(1)
        string(value)
      } else {
        u8(0)
      }
    }
  }

  private struct Reader {
    let data: Data
    var offset = 0
    var atEnd: Bool { offset == data.count }

    mutating func raw<T: FixedWidthInteger>(_ type: T.Type) -> T? {
      let size = MemoryLayout<T>.size
      guard offset + size <= data.count else { return nil }
      var value: T = 0
      withUnsafeMutableBytes(of: &value) { target in
        data.copyBytes(
          to: target.bindMemory(to: UInt8.self), from: (data.startIndex + offset)..<(data.startIndex + offset + size))
      }
      offset += size
      return T(littleEndian: value)
    }
    mutating func u8() -> UInt8? { raw(UInt8.self) }
    mutating func u32() -> UInt32? { raw(UInt32.self) }
    mutating func i32() -> Int32? { raw(Int32.self) }
    mutating func u64() -> UInt64? { raw(UInt64.self) }
    mutating func i64() -> Int64? { raw(Int64.self) }
    mutating func f64() -> Double? { raw(UInt64.self).map(Double.init(bitPattern:)) }
    mutating func string() -> String? {
      guard let length = u32(), length <= 1 << 20, offset + Int(length) <= data.count else { return nil }
      let start = data.startIndex + offset
      offset += Int(length)
      return String(decoding: data[start..<(start + Int(length))], as: UTF8.self)
    }
    mutating func optionalString() -> String?? {
      guard let flag = u8() else { return nil }
      if flag == 0 { return .some(nil) }
      guard let value = string() else { return nil }
      return .some(value)
    }
  }
}

extension ScanTree {
  /// The node whose path equals `path`, following visible names from the root.
  public func find(path target: String) -> ScanItemID? {
    storage.withLock { storage in
      var cursor: Int32 = 0
      while true {
        let current = Self.path(of: cursor, in: storage.nodes, rootPath: storage.rootPath, firmlinks: storage.firmlinks)
        if current == target { return ScanItemID(node: cursor) }
        guard
          let next = storage.nodes[Int(cursor)].childNodes.first(where: { child in
            let path = Self.path(of: child, in: storage.nodes, rootPath: storage.rootPath, firmlinks: storage.firmlinks)
            return target == path || target.hasPrefix(path + "/")
          })
        else { return nil }
        cursor = next
      }
    }
  }
}
