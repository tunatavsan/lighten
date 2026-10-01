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
  /// Display-only metadata; absent in older records.
  public let observedSize: ObservedPlanSize?
  public let containsOpaquePackages: Bool?
  public let userSelection: Bool?

  public var displaySize: ObservedPlanSize {
    if let observedSize { return observedSize.validated }
    if containsOpaquePackages == true || (containsOpaquePackages == nil && rootIdentity?.kind == .directory)
      || (rootIdentity?.kind == .directory && PlanItem.isPackageName(sourcePath))
    {
      return .unknown
    }
    return ObservedPlanSize(
      logical: ByteAggregate(knownLowerBound: logicalBytes, completeTotal: logicalBytes),
      allocated: ByteAggregate(knownLowerBound: allocatedBytes, completeTotal: allocatedBytes))
  }

  init(_ item: PlanItem) {
    id = item.id
    sourcePath = item.sourcePath
    volumeID = item.volumeID
    rootIdentity = item.inventory.first?.identity
    inventoryCount = item.inventory.count
    let inventorySize = ObservedPlanSize.inventory(item.inventory)
    // Legacy numeric fields retain inventory totals; -1 represents a metric that overflowed.
    logicalBytes = inventorySize.logical?.completeTotal ?? -1
    allocatedBytes = inventorySize.allocated?.completeTotal ?? -1
    // Rebuilding an old reference must retain exactly its original optional-field shape.
    observedSize = item.sizeMetadataVersion == nil ? nil : item.displaySize
    containsOpaquePackages = item.sizeMetadataVersion == nil ? nil : item.containsOpaquePackages
    userSelection = item.userSelection
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
