import LightenKit

/// Size of a planned item from its exact inventory; hard links count once.
enum PlanItemSize {
  nonisolated static func measure(_ item: PlanItem) -> (logical: Int64, allocated: Int64) {
    var seen = Set<[UInt64]>()
    var logical: Int64 = 0
    var allocated: Int64 = 0
    for entry in item.inventory {
      guard let identity = entry.identity, identity.kind != .directory else { continue }
      if identity.linkCount > 1, !seen.insert([identity.device, identity.inode]).inserted { continue }
      logical &+= identity.logicalBytes
      allocated &+= identity.allocatedBytes
    }
    return (logical, allocated)
  }
}
