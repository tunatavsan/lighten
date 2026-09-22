import Darwin
import Foundation

public struct ApplicationReport: Identifiable, Sendable {
  public let path: String
  public let bundleID: String?
  public let version: String?
  public let signerTeamID: String?
  public let logical: ByteAggregate
  public let allocated: ByteAggregate
  public let knownItemCount: Int
  public let partial: Bool
  public let related: [RelatedDataCandidate]
  public let manualUninstallerSuggested: Bool

  public var id: String { path }
}

public struct ApplicationDiscovery: Sendable {
  private let related: RelatedDataService

  public init(related: RelatedDataService = RelatedDataService()) {
    self.related = related
  }

  public func discover() async -> (BundleInventory, [ApplicationReport]) {
    let inventory = related.inventory()
    let relatedCandidates = await related.discover()
    let known = inventory.applications.map { (path: $0.path, bundleID: Optional($0.bundleID), version: $0.version) }
    let unknown = inventory.unidentifiedPaths.map {
      (path: $0, bundleID: Optional<String>.none, version: Optional<String>.none)
    }
    var reports: [ApplicationReport] = []
    for app in known + unknown {
      if Task.isCancelled { break }
      let size = Self.measure(path: app.path, homeDirectory: related.homeDirectory)
      let candidates: [RelatedDataCandidate]
      if let id = app.bundleID {
        var matched = relatedCandidates.filter { candidate in
          candidate.path == related.homeDirectory + "/Library/Caches/" + id
            || candidate.path == related.homeDirectory + "/Library/Preferences/" + id + ".plist"
        }
        for path in [
          related.homeDirectory + "/Library/Caches/" + id,
          related.homeDirectory + "/Library/Preferences/" + id + ".plist",
          related.homeDirectory + "/Library/Logs/" + id,
          related.homeDirectory + "/Library/Application Support/" + id,
          related.homeDirectory + "/Library/Containers/" + id,
        ] where !matched.contains(where: { $0.path == path }) {
          if let candidate = Self.reportOnlyCandidate(path: path, homeDirectory: related.homeDirectory) {
            matched.append(candidate)
          }
        }
        candidates = matched
      } else {
        candidates = []
      }
      reports.append(
        ApplicationReport(
          path: app.path, bundleID: app.bundleID, version: app.version,
          signerTeamID: nil,
          logical: size.logical, allocated: size.allocated,
          knownItemCount: size.count, partial: size.partial,
          related: candidates,
          manualUninstallerSuggested: (try? DescriptorFileSystem.identity(
            at: app.path + "/Contents/Library/SystemExtensions")) != nil
            || (try? DescriptorFileSystem.identity(at: app.path + "/Contents/Library/LaunchServices")) != nil))
    }
    reports.sort {
      if $0.logical.knownLowerBound != $1.logical.knownLowerBound {
        return $0.logical.knownLowerBound > $1.logical.knownLowerBound
      }
      return $0.path < $1.path
    }
    return (inventory, reports)
  }

  private static func reportOnlyCandidate(path: String, homeDirectory: String) -> RelatedDataCandidate? {
    let identity: FileIdentity
    do {
      identity = try DescriptorFileSystem.identity(at: path)
    } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
      return nil
    } catch {
      return RelatedDataCandidate(
        id: path, path: path, classification: .uncertain,
        reason: .candidateAreaUnreadable, snapshot: nil, receipt: nil)
    }
    let protected = ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) != nil
    return RelatedDataCandidate(
      id: path, path: path,
      classification: protected ? .protected : .uncertain,
      reason: protected ? .protected : identity.kind == .symbolicLink ? .recordUnsafe : .nameOnly,
      snapshot: nil, receipt: nil)
  }

  private static func measure(path: String, homeDirectory: String) -> (
    logical: ByteAggregate, allocated: ByteAggregate, count: Int, partial: Bool
  ) {
    guard let root = try? DescriptorFileSystem.identity(at: path), root.kind == .directory,
      let volume = try? DescriptorFileSystem.volumeID(at: path)
    else {
      return (
        ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        ByteAggregate(knownLowerBound: 0, completeTotal: nil), 0, true
      )
    }
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var count = 0
    var partial = false
    var stack: [(String, FileIdentity)] = [(path, root)]
    while let (currentPath, identity) = stack.popLast() {
      if Task.isCancelled || count >= 100_000 {
        partial = true
        break
      }
      count += 1
      if currentPath != path && ProtectionPolicy.rule(for: currentPath, homeDirectory: homeDirectory) != nil {
        partial = true
        continue
      }
      guard identity.device == root.device,
        (try? DescriptorFileSystem.identity(at: currentPath)) == identity,
        identity.kind != .symbolicLink && identity.kind != .other,
        identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
        (try? DescriptorFileSystem.volumeID(at: currentPath)) == volume
      else {
        partial = true
        continue
      }
      let (newLogical, logicalOverflow) = logical.addingReportingOverflow(identity.logicalBytes)
      let (newAllocated, allocatedOverflow) = allocated.addingReportingOverflow(identity.allocatedBytes)
      if logicalOverflow || allocatedOverflow {
        partial = true
        break
      }
      logical = newLogical
      allocated = newAllocated
      if identity.kind == .directory {
        guard let names = try? DescriptorFileSystem.children(at: currentPath, expected: identity)
        else {
          partial = true
          continue
        }
        for name in names.reversed() {
          if Task.isCancelled || stack.count + count >= 100_000 {
            partial = true
            break
          }
          let childPath = currentPath + "/" + name
          guard let child = try? DescriptorFileSystem.identity(at: childPath) else {
            partial = true
            continue
          }
          stack.append((childPath, child))
        }
      }
    }
    if (try? DescriptorFileSystem.identity(at: path)) != root { partial = true }
    return (
      ByteAggregate(knownLowerBound: logical, completeTotal: partial ? nil : logical),
      ByteAggregate(knownLowerBound: allocated, completeTotal: partial ? nil : allocated),
      count, partial
    )
  }

}
