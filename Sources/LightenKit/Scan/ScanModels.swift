import Foundation

public struct FileIdentity: Codable, Sendable, Equatable {
  public let device: UInt64
  public let inode: UInt64
  public let changeSeconds: Int64
  public let changeNanoseconds: Int64
  public let birthSeconds: Int64?
  public let birthNanoseconds: Int64?
  public let modificationSeconds: Int64?
  public let modificationNanoseconds: Int64?
  public let logicalBytes: Int64
  public let allocatedBytes: Int64
  public let linkCount: UInt64
  public let flags: UInt32
  public let kind: EntryKind

  public init(
    device: UInt64, inode: UInt64, changeSeconds: Int64, changeNanoseconds: Int64,
    logicalBytes: Int64, allocatedBytes: Int64, linkCount: UInt64, flags: UInt32,
    kind: EntryKind, birthSeconds: Int64? = nil, birthNanoseconds: Int64? = nil,
    modificationSeconds: Int64? = nil, modificationNanoseconds: Int64? = nil
  ) {
    self.device = device
    self.inode = inode
    self.changeSeconds = changeSeconds
    self.changeNanoseconds = changeNanoseconds
    self.birthSeconds = birthSeconds
    self.birthNanoseconds = birthNanoseconds
    self.modificationSeconds = modificationSeconds
    self.modificationNanoseconds = modificationNanoseconds
    self.logicalBytes = logicalBytes
    self.allocatedBytes = allocatedBytes
    self.linkCount = linkCount
    self.flags = flags
    self.kind = kind
  }

  /// ctime changes during filesystem moves and later metadata maintenance.
  /// Missing legacy proof never qualifies an item for automatic Trash recovery.
  var hasStableTrashProof: Bool {
    birthSeconds != nil && birthNanoseconds != nil
      && modificationSeconds != nil && modificationNanoseconds != nil
  }

  func matchesStableTrashIdentity(_ other: FileIdentity) -> Bool {
    guard let birthSeconds, let birthNanoseconds,
      let modificationSeconds, let modificationNanoseconds,
      let otherBirthSeconds = other.birthSeconds,
      let otherBirthNanoseconds = other.birthNanoseconds,
      let otherModificationSeconds = other.modificationSeconds,
      let otherModificationNanoseconds = other.modificationNanoseconds
    else { return false }
    return device == other.device && inode == other.inode && kind == other.kind
      && birthSeconds == otherBirthSeconds && birthNanoseconds == otherBirthNanoseconds
      && modificationSeconds == otherModificationSeconds
      && modificationNanoseconds == otherModificationNanoseconds
      && logicalBytes == other.logicalBytes && linkCount == other.linkCount
      && flags == other.flags
  }
}

public enum EntryKind: String, Codable, Sendable {
  case regular, directory, symbolicLink, other
}

public enum ScanIssue: String, Codable, Sendable {
  case unreadable, unknownMetadata, unknownVolume, protected, symbolicLink, mountBoundary, dataless, packageBoundary,
    notTraversed
}

public struct ScanEntry: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let parentID: UUID?
  public let path: String
  public let identity: FileIdentity?
  public let observedAt: Date
  public let issues: [ScanIssue]
  public let readable: Bool

  public init(
    id: UUID = UUID(), parentID: UUID?, path: String, identity: FileIdentity?,
    observedAt: Date = Date(), issues: [ScanIssue], readable: Bool
  ) {
    self.id = id
    self.parentID = parentID
    self.path = path
    self.identity = identity
    self.observedAt = observedAt
    self.issues = issues
    self.readable = readable
  }
}

public struct ByteAggregate: Codable, Sendable, Equatable {
  public let knownLowerBound: Int64
  public let completeTotal: Int64?

  public init(knownLowerBound: Int64, completeTotal: Int64?) {
    self.knownLowerBound = knownLowerBound
    self.completeTotal = completeTotal
  }
}

public struct ScanNode: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let parentID: UUID?
  public let logical: ByteAggregate
  public let allocated: ByteAggregate
  public let knownItemCount: Int
  public let completeItemCount: Int?
  public let partial: Bool
  public let protected: Bool
  public let skipped: Bool
}

public struct ScanSnapshot: Codable, Sendable, Equatable {
  public let schema: Int
  public let runID: UUID
  public let rootPath: String
  public let volumeDevice: UInt64
  public let volumeID: UUID?
  public let observedAt: Date
  public let entries: [ScanEntry]
  public let nodes: [ScanNode]

  public init(
    schema: Int = 1, runID: UUID = UUID(), rootPath: String, volumeDevice: UInt64,
    volumeID: UUID? = nil,
    observedAt: Date = Date(), entries: [ScanEntry], nodes: [ScanNode]
  ) {
    self.schema = schema
    self.runID = runID
    self.rootPath = rootPath
    self.volumeDevice = volumeDevice
    self.volumeID = volumeID
    self.observedAt = observedAt
    self.entries = entries
    self.nodes = nodes
  }
}

public enum ScanEvent: Sendable {
  case progress(scannedItems: Int, path: String)
  case completed(ScanSnapshot)
}
