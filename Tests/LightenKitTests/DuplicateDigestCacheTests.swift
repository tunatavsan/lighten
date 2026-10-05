import Foundation
import Testing

@testable import LightenKit

private func cacheIdentity(
  device: UInt64 = 1, inode: UInt64 = 2, bytes: Int64 = 3, modified: Int64 = 4,
  changed: Int64 = 5, flags: UInt32 = 0
) -> FileIdentity {
  FileIdentity(
    device: device, inode: inode, changeSeconds: changed, changeNanoseconds: 1,
    logicalBytes: bytes, allocatedBytes: 4096, linkCount: 1, flags: flags, kind: .regular,
    birthSeconds: 1, birthNanoseconds: 1, modificationSeconds: modified, modificationNanoseconds: 1)
}

@Test func duplicateDigestCacheKeysIdentityAndStageAndInvalidatesMetadataChanges() {
  let cache = DuplicateDigestCache()
  let original = cacheIdentity()
  let digest = Data([1, 2, 3])
  cache.insert(digest, for: original, stage: .full)
  #expect(cache.value(for: original, stage: .full) == digest)
  #expect(cache.value(for: original, stage: .sample) == nil)
  for changed in [
    cacheIdentity(device: 9), cacheIdentity(inode: 9), cacheIdentity(bytes: 9),
    cacheIdentity(modified: 9), cacheIdentity(flags: 1),
  ] {
    #expect(cache.value(for: changed, stage: .full) == nil)
  }
  #expect(cache.value(for: cacheIdentity(changed: 9), stage: .full) == digest)
}

@Test func duplicateDigestCacheIsBoundedAndCannotUseLegacyMissingMtime() {
  let cache = DuplicateDigestCache(capacity: 1)
  cache.insert(Data([1]), for: cacheIdentity(), stage: .full)
  cache.insert(Data([2]), for: cacheIdentity(inode: 3), stage: .full)
  #expect(cache.value(for: cacheIdentity(), stage: .full) == nil)
  #expect(cache.value(for: cacheIdentity(inode: 3), stage: .full) == Data([2]))
  let legacy = FileIdentity(
    device: 1, inode: 2, changeSeconds: 5, changeNanoseconds: 1,
    logicalBytes: 3, allocatedBytes: 4096, linkCount: 1, flags: 0, kind: .regular)
  cache.insert(Data([3]), for: legacy, stage: .sample)
  #expect(cache.value(for: legacy, stage: .sample) == nil)
}
