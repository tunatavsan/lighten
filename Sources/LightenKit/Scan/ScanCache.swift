import CryptoKit
import Foundation

/// Last completed scan tree per root, for an instant first screen on the next
/// visit. A cached tree is only a picture: plans never read it.
public struct ScanCache: Sendable {
  public let directory: String

  public init(directory: String = ScanCache.defaultDirectory) {
    self.directory = directory
  }

  public static var defaultDirectory: String {
    NSHomeDirectory() + "/Library/Application Support/Lighten/scan-cache"
  }

  static let magic: UInt32 = 0x4C_53_43_31  // "LSC1"

  func file(for root: String) -> String {
    let digest = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory + "/" + digest + ".bin"
  }

  public func save(_ tree: ScanTree) throws {
    guard tree.isFinished, !tree.wasCancelled else { return }
    let data = tree.storage.withLock { storage in Self.encode(storage, savedAt: Date()) }
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: URL(fileURLWithPath: file(for: tree.rootPath)), options: [.atomic])
  }

  /// A finished tree and the time its scan completed, or nil when absent or unreadable.
  public func load(root: String) -> (tree: ScanTree, savedAt: Date)? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: file(for: root)), options: [.mappedIfSafe]),
      let decoded = Self.decode(data), decoded.storage.rootPath == root, !decoded.storage.nodes.isEmpty
    else { return nil }
    let tree = ScanTree(
      runID: UUID(), rootPath: root, root: decoded.storage.nodes[0], firmlinks: decoded.storage.firmlinks,
      startedAt: decoded.savedAt)
    tree.storage.withLock { storage in
      storage = decoded.storage
      storage.finished = true
      storage.cancelled = false
    }
    return (tree, decoded.savedAt)
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
        let childCount = reader.u32(), Int(parent) < Int(count)
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
        guard let child = reader.i32(), child > 0, Int(child) < Int(count) else { return nil }
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
