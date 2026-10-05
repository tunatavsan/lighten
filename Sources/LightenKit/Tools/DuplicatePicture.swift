import Foundation

/// Previous duplicate groups for presentation only; no scan or action evidence is retained.
public struct DuplicatePicture: Codable, Sendable, Equatable {
  public struct Member: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let eligibility: DuplicateEligibility
    public var id: String { path }

    public init(path: String, eligibility: DuplicateEligibility) {
      self.path = path
      self.eligibility = eligibility
    }
  }

  public struct Group: Codable, Sendable, Equatable, Identifiable {
    public let logicalBytes: Int64
    public let members: [Member]
    public var id: String { members.map(\.path).joined(separator: "\u{0}") }

    public init(logicalBytes: Int64, members: [Member]) {
      self.logicalBytes = logicalBytes
      self.members = members
    }
  }

  public let rootPath: String
  public let groups: [Group]
  public let scannedCount: Int
  public let comparisonCount: Int
  public let skippedCount: Int
  public let partial: Bool

  public init(
    rootPath: String, groups: [Group], scannedCount: Int, comparisonCount: Int,
    skippedCount: Int, partial: Bool
  ) {
    self.rootPath = rootPath
    self.groups = groups
    self.scannedCount = scannedCount
    self.comparisonCount = comparisonCount
    self.skippedCount = skippedCount
    self.partial = partial
  }

  public init(_ report: DuplicateReport) {
    self.init(
      rootPath: report.snapshot.rootPath,
      groups: report.groups.map { group in
        Group(
          logicalBytes: group.logicalBytes,
          members: group.members.map { Member(path: $0.entry.path, eligibility: $0.eligibility) })
      }, scannedCount: report.snapshot.entries.count, comparisonCount: report.comparisonCount,
      skippedCount: report.skippedCount, partial: report.partial)
  }
}
