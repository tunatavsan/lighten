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
  public let reportOnlyReason: DuplicateReportOnlyReason?

  public init(
    id: UUID = UUID(), logicalBytes: Int64, members: [DuplicateMember],
    reportOnlyReason: DuplicateReportOnlyReason? = nil
  ) {
    self.id = id
    self.logicalBytes = logicalBytes
    self.members = members
    self.reportOnlyReason = reportOnlyReason
  }

  public func canTarget(_ targetID: UUID, keeperID: UUID) -> Bool {
    guard reportOnlyReason == nil, targetID != keeperID,
      members.allSatisfy({ $0.eligibility == .eligible && $0.compatibilityID != nil }),
      Set(members.compactMap(\.compatibilityID)).count == 1,
      let keeper = members.first(where: { $0.id == keeperID }),
      let target = members.first(where: { $0.id == targetID }),
      keeper.eligibility == .eligible, target.eligibility == .eligible,
      let compatibilityID = keeper.compatibilityID
    else { return false }
    return target.compatibilityID == compatibilityID
  }
}

public enum DuplicateReportOnlyReason: String, Codable, Sendable {
  case protectiveMetadataDifferent, metadataUnknown, protectedArea
}

/// Deliberate omissions are scope information, not failed verification.
public struct DuplicateScanExclusion: Sendable, Equatable {
  public enum Reason: String, Sendable {
    case invalidPath, outsideScanRoot, hiddenDirectory, sourceControl, buildOutput
    case dependencyDirectory, derivedData, libraryCache, package, homeLibrary
    case cloudOnly, protectedArea, mountBoundary, hardLinkAlias, configuration
  }
  public let path: String
  public let reason: Reason
  public let isDirectory: Bool

  public init(path: String, reason: Reason, isDirectory: Bool) {
    self.path = path
    self.reason = reason
    self.isDirectory = isDirectory
  }
}

public struct DuplicateReport: Sendable {
  public let snapshot: ScanSnapshot
  public let groups: [DuplicateGroup]
  public let skippedCount: Int
  public let partial: Bool
  public let comparisonCount: Int
  public let refusals: [DuplicateObservationRefusal]
  public let exclusions: [DuplicateScanExclusion]
  public let excludedRoot: DuplicateScanExclusion?
  public var excludedDirectoryCount: Int { exclusions.filter(\.isDirectory).count }
  public var cloudOnlyCount: Int { exclusions.filter { $0.reason == .cloudOnly }.count }
  public var hardLinkAliasCount: Int { exclusions.filter { $0.reason == .hardLinkAlias }.count }
  public var additionalHardLinkCount: Int {
    var links: [String: UInt64] = [:]
    for entry in snapshot.entries {
      guard let identity = entry.identity, identity.kind == .regular else { continue }
      links["\(identity.device):\(identity.inode)"] = identity.linkCount
    }
    return links.values.reduce(0) { count, links in
      let (sum, overflow) = count.addingReportingOverflow(Int(clamping: links > 0 ? links - 1 : 0))
      return overflow ? Int.max : sum
    }
  }
  public var unreadableCount: Int { refusals.filter { $0.reason.isVerificationFailure }.count }

  public init(
    snapshot: ScanSnapshot, groups: [DuplicateGroup], skippedCount: Int,
    partial: Bool, comparisonCount: Int, refusals: [DuplicateObservationRefusal] = [],
    exclusions: [DuplicateScanExclusion] = [], excludedRoot: DuplicateScanExclusion? = nil
  ) {
    self.snapshot = snapshot
    self.groups = groups
    self.skippedCount = skippedCount
    self.partial = partial
    self.comparisonCount = comparisonCount
    self.refusals = refusals
    self.exclusions = exclusions
    self.excludedRoot = excludedRoot
  }
}

/// A pictured path that could not join a freshly observed duplicate group.
public struct DuplicateObservationRefusal: Sendable, Equatable {
  public enum Reason: String, Sendable {
    case unavailable, outOfScope, notRegular, unreadable, changed, noLongerDuplicate
    case metadataUnknown, metadataDifferent, protectedArea

    public var isVerificationFailure: Bool {
      switch self {
      case .unavailable, .unreadable, .changed, .metadataUnknown: true
      case .outOfScope, .notRegular, .noLongerDuplicate, .metadataDifferent, .protectedArea: false
      }
    }
  }
  public let path: String
  public let reason: Reason

  public init(path: String, reason: Reason) {
    self.path = path
    self.reason = reason
  }
}

/// One failed group names its cause while other groups form one confirmation.
public struct DuplicatePlanRefusal: Error, Sendable, Equatable {
  public enum Reason: String, Sendable {
    case changed, unavailable, unreadable, outOfScope, metadataUnknown, metadataDifferent, dataDifferent, protectedArea
  }
  public let groupID: UUID
  public let path: String
  public let reason: Reason

  public init(groupID: UUID, path: String, reason: Reason) {
    self.groupID = groupID
    self.path = path
    self.reason = reason
  }

  public var planRejection: PlanRejection {
    let rejection: RejectionReason =
      switch reason {
      case .changed, .dataDifferent: .changedSinceScan
      case .unavailable: .unavailable
      case .unreadable: .unreadableFolder
      case .outOfScope: .insidePackage
      case .metadataUnknown: .missingMetadata
      case .metadataDifferent, .protectedArea: .protectedItem
      }
    return PlanRejection(rejection, path: path)
  }
}

public struct DuplicatePlanResult: Sendable {
  public let plan: ActionPlan?
  public let refusals: [DuplicatePlanRefusal]
  public init(plan: ActionPlan?, refusals: [DuplicatePlanRefusal] = []) {
    self.plan = plan
    self.refusals = refusals
  }
}

public enum DuplicateEvent: Sendable {
  case progress(scanned: Int, compared: Int)
  /// Known bytes from metadata already delivered to the discovery sink.
  case measuredBytes(Int64)
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
  case unreadable, outOfScope, protectedArea
}
