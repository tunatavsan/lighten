import Foundation
import Synchronization

/// Discovery acceleration only. Plans and the executor always read the bytes again.
final class DuplicateDigestCache: Sendable {
  static let shared = DuplicateDigestCache()

  enum Stage: Hashable, Sendable { case sample, full }
  private struct Key: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let seconds: Int64
    let nanoseconds: Int64
    let stage: Stage
  }
  private struct Value: Sendable {
    let identity: FileIdentity
    let digest: Data
  }
  private let capacity: Int
  private let entries = Mutex<[Key: Value]>([:])

  init(capacity: Int = 32_768) { self.capacity = max(1, capacity) }

  func value(for identity: FileIdentity, stage: Stage) -> Data? {
    guard let key = key(identity, stage: stage) else { return nil }
    return entries.withLock { entries in
      guard let value = entries[key], value.identity == identity else { return nil }
      return value.digest
    }
  }

  func insert(_ digest: Data, for identity: FileIdentity, stage: Stage) {
    guard let key = key(identity, stage: stage) else { return }
    entries.withLock { entries in
      if entries.count >= capacity, entries[key] == nil { entries.removeAll(keepingCapacity: true) }
      entries[key] = Value(identity: identity, digest: digest)
    }
  }

  private func key(_ identity: FileIdentity, stage: Stage) -> Key? {
    guard let seconds = identity.modificationSeconds, let nanoseconds = identity.modificationNanoseconds else {
      return nil
    }
    return Key(
      device: identity.device, inode: identity.inode, size: identity.logicalBytes,
      seconds: seconds, nanoseconds: nanoseconds, stage: stage)
  }
}
