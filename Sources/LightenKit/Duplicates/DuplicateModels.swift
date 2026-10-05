import Foundation

public enum DuplicateEligibility: String, Codable, Sendable {
  case eligible, metadataDifferent, metadataUnknown
}

/// Informational differences do not prevent preserving a byte-identical copy.
public enum DuplicateMetadataWarning: String, Codable, Sendable, Hashable, CaseIterable {
  case quarantine, downloadSource, finderTags, permissions, compression, fileInformation
}

public struct DuplicateMember: Codable, Sendable, Identifiable {
  public let entry: ScanEntry
  public let eligibility: DuplicateEligibility
  public let compatibilityID: UUID?
  public let metadataWarnings: [DuplicateMetadataWarning]
  public var id: UUID { entry.id }

  public init(
    entry: ScanEntry, eligibility: DuplicateEligibility, compatibilityID: UUID? = nil,
    metadataWarnings: [DuplicateMetadataWarning] = []
  ) {
    self.entry = entry
    self.eligibility = eligibility
    self.compatibilityID = compatibilityID
    self.metadataWarnings = metadataWarnings
  }

  private enum CodingKeys: String, CodingKey { case entry, eligibility, compatibilityID, metadataWarnings }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    entry = try values.decode(ScanEntry.self, forKey: .entry)
    eligibility = try values.decode(DuplicateEligibility.self, forKey: .eligibility)
    compatibilityID = try values.decodeIfPresent(UUID.self, forKey: .compatibilityID)
    metadataWarnings = try values.decodeIfPresent([DuplicateMetadataWarning].self, forKey: .metadataWarnings) ?? []
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
      keeper.eligibility == .eligible, target.eligibility == .eligible,
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
  public let refusals: [DuplicateObservationRefusal]

  public init(
    snapshot: ScanSnapshot, groups: [DuplicateGroup], skippedCount: Int,
    partial: Bool, comparisonCount: Int, refusals: [DuplicateObservationRefusal] = []
  ) {
    self.snapshot = snapshot
    self.groups = groups
    self.skippedCount = skippedCount
    self.partial = partial
    self.comparisonCount = comparisonCount
    self.refusals = refusals
  }
}

/// A pictured path that could not join a freshly observed duplicate group.
public struct DuplicateObservationRefusal: Sendable, Equatable {
  public enum Reason: String, Sendable {
    case unavailable, outOfScope, notRegular, unreadable, changed, noLongerDuplicate
  }
  public let path: String
  public let reason: Reason

  public init(path: String, reason: Reason) {
    self.path = path
    self.reason = reason
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
