import Foundation

/// A filesystem timestamp retaining the precision used by identity checks.
public struct FileTimestamp: Sendable, Equatable {
  public let seconds: Int64
  public let nanoseconds: Int64

  public init(seconds: Int64, nanoseconds: Int64) {
    self.seconds = seconds
    self.nanoseconds = nanoseconds
  }

  public var date: Date {
    Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
  }
}

/// Discovery metadata, never authority to mutate a file. A planner obtains fresh proof.
public struct FileFact: Sendable, Equatable {
  public let path: String
  public let identity: FileIdentity
  public let modTime: Date?
  public let addedTime: Date?

  public init(path: String, identity: FileIdentity, modTime: Date?, addedTime: Date?) {
    self.path = path
    self.identity = identity
    self.modTime = modTime
    self.addedTime = addedTime
  }

  public var logicalBytes: Int64 { identity.logicalBytes }
  public var allocatedBytes: Int64 { identity.allocatedBytes }
}

/// Receives eligible regular files during the same metadata walk. Worker threads
/// can call `receive` concurrently; consumers must synchronize mutable state.
public struct FileSink: Sendable {
  public let minLogicalBytes: Int64
  public let olderThan: Date?
  public let receive: @Sendable (FileFact) -> Void

  public init(
    minLogicalBytes: Int64 = 0, olderThan: Date? = nil,
    receive: @escaping @Sendable (FileFact) -> Void
  ) {
    self.minLogicalBytes = max(0, minLogicalBytes)
    self.olderThan = olderThan
    self.receive = receive
  }

  func accepts(_ entry: RawEntry) -> Bool {
    guard let logical = entry.identityLogicalBytes, logical >= minLogicalBytes else { return false }
    if let olderThan {
      guard let modified = entry.modificationTime?.date, modified < olderThan else { return false }
    }
    return true
  }
}
