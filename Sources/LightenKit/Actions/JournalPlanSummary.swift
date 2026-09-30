import Foundation

/// Compact history metadata. The complete inventory remains in its durable plan file.
public struct JournalItemSummary: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let sourcePath: String
  public let volumeID: UUID?
  public let rootIdentity: FileIdentity?
  public let inventoryCount: Int
  public let logicalBytes: Int64
  public let allocatedBytes: Int64

  init(_ item: PlanItem) {
    id = item.id
    sourcePath = item.sourcePath
    volumeID = item.volumeID
    rootIdentity = item.inventory.first?.identity
    inventoryCount = item.inventory.count
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var seen = Set<[UInt64]>()
    for entry in item.inventory {
      guard let identity = entry.identity, identity.kind != .directory else { continue }
      if identity.linkCount > 1, !seen.insert([identity.device, identity.inode]).inserted { continue }
      logical &+= identity.logicalBytes
      allocated &+= identity.allocatedBytes
    }
    logicalBytes = logical
    allocatedBytes = allocated
  }
}

public struct JournalPlanSummary: Codable, Sendable, Equatable, Identifiable {
  public let schema: Int
  public let id: UUID
  public let kind: ActionKind
  public let createdAt: Date
  public let items: [JournalItemSummary]

  init(_ plan: ActionPlan) {
    schema = plan.schema
    id = plan.id
    kind = plan.kind
    createdAt = plan.createdAt
    items = plan.items.map(JournalItemSummary.init)
  }
}

public struct JournalPlanReference: Codable, Sendable, Equatable {
  public let sha256: String
  public let summary: JournalPlanSummary
}
