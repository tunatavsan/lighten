import Foundation

public enum DuplicateEligibility: String, Codable, Sendable {
  case eligible, metadataDifferent, metadataUnknown
}

public struct DuplicateMember: Codable, Sendable, Identifiable {
  public let entry: ScanEntry
  public let eligibility: DuplicateEligibility
  public let compatibilityID: UUID?
  public var id: UUID { entry.id }

  public init(entry: ScanEntry, eligibility: DuplicateEligibility, compatibilityID: UUID? = nil) {
    self.entry = entry
    self.eligibility = eligibility
    self.compatibilityID = compatibilityID
  }
}

public struct DuplicateGroup: Codable, Sendable, Identifiable {
  public let id: UUID
  public let logicalBytes: Int64
  public let members: [DuplicateMember]

  public init(
    id: UUID = UUID(), logicalBytes: Int64, members: [DuplicateMember]
  ) {
    self.id = id
    self.logicalBytes = logicalBytes
    self.members = members
  }

  public func canTarget(_ targetID: UUID, keeperID: UUID) -> Bool {
    guard targetID != keeperID,
      let keeper = members.first(where: { $0.id == keeperID }),
      let target = members.first(where: { $0.id == targetID }),
      let compatibilityID = keeper.compatibilityID
    else { return false }
    return target.compatibilityID == compatibilityID
  }
}

public struct DuplicateReport: Sendable {
  public let snapshot: ScanSnapshot
  public let groups: [DuplicateGroup]
  public let skippedCount: Int
  public let partial: Bool
  public let comparisonCount: Int

  public init(
    snapshot: ScanSnapshot, groups: [DuplicateGroup], skippedCount: Int,
    partial: Bool, comparisonCount: Int
  ) {
    self.snapshot = snapshot
    self.groups = groups
    self.skippedCount = skippedCount
    self.partial = partial
    self.comparisonCount = comparisonCount
  }
}

public enum DuplicateEvent: Sendable {
  case progress(scanned: Int, compared: Int)
  case completed(DuplicateReport)
}

public struct DuplicateGroupSelection: Sendable {
  public let groupID: UUID
  public let keeperID: UUID
  public let targetIDs: Set<UUID>

  public init(groupID: UUID, keeperID: UUID, targetIDs: Set<UUID>) {
    self.groupID = groupID
    self.keeperID = keeperID
    self.targetIDs = targetIDs
  }
}

/// A receipt of the exact-copy observation. The executor treats every field as
/// untrusted input and reopens both files to prove the relationship again.
public struct DuplicateProof: Codable, Sendable, Equatable {
  public let groupID: UUID
  public let keeper: ScanEntry
  public let keeperAncestors: [PathIdentity]
  public let keeperVolumeID: UUID
  public let targetDigest: Data
  public let keeperDigest: Data

  public init(
    groupID: UUID, keeper: ScanEntry, keeperAncestors: [PathIdentity],
    keeperVolumeID: UUID, targetDigest: Data, keeperDigest: Data
  ) {
    self.groupID = groupID
    self.keeper = keeper
    self.keeperAncestors = keeperAncestors
    self.keeperVolumeID = keeperVolumeID
    self.targetDigest = targetDigest
    self.keeperDigest = keeperDigest
  }
}

public enum DuplicateFailure: Error, Sendable {
  case invalidSelection, changed, unavailable, metadataUnknown, metadataDifferent, dataDifferent
}
