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
  /// A best-effort size walk stopped at its time budget; metadata remains visible.
  public var sizeLimitReached = false

  public var id: String { path }
}

public struct ApplicationDiscovery: Sendable {
  private let related: RelatedDataService
  private let uptime: @Sendable () -> TimeInterval

  public init(
    related: RelatedDataService = RelatedDataService(),
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.related = related
    self.uptime = uptime
  }

  public enum Event: Sendable {
    case inventory(BundleInventory, [ApplicationReport])
    case measured([ApplicationReport])
    case completed(BundleInventory, [ApplicationReport])
  }

  /// Inventory metadata is published before any package-size walk. The stream
  /// owns its worker so cancellation stops both discovery and measurement.
  public func events() -> AsyncStream<Event> {
    AsyncStream { continuation in
      let worker = Task.detached(priority: .utility) {
        _ = await discover { event in continuation.yield(event) }
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in worker.cancel() }
    }
  }

  public func discover() async -> (BundleInventory, [ApplicationReport]) {
    await discover { _ in }
  }

  private func discover(_ emit: @Sendable (Event) -> Void) async -> (BundleInventory, [ApplicationReport]) {
    let inventory = related.inventory()
    let known = inventory.applications.map { (path: $0.path, bundleID: Optional($0.bundleID), version: $0.version) }
    let unknown = inventory.unidentifiedPaths.map {
      (path: $0, bundleID: Optional<String>.none, version: Optional<String>.none)
    }
    let metadata = (known + unknown).map { app in
      ApplicationReport(
        path: app.path, bundleID: app.bundleID, version: app.version,
        signerTeamID: nil,
        logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        allocated: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        knownItemCount: 0, partial: true, related: [],
        manualUninstallerSuggested: false)
    }
    emit(.inventory(inventory, metadata))
    if Task.isCancelled { return (inventory, []) }
    var reports: [ApplicationReport] = []
    var unpublished: [ApplicationReport] = []
    var lastPublished = uptime()
    let sizeStageStarted = uptime()
    for app in known + unknown {
      if Task.isCancelled { break }
      let appStarted = uptime()
      let globalLimitReached = appStarted - sizeStageStarted >= 20
      let size =
        globalLimitReached
        ? Self.limitedUnknownSize()
        : Self.measure(path: app.path, homeDirectory: related.homeDirectory) {
          let current = uptime()
          return current - appStarted >= 2 || current - sizeStageStarted >= 20
        }
      var report = ApplicationReport(
        path: app.path, bundleID: app.bundleID, version: app.version,
        signerTeamID: nil,
        logical: size.logical, allocated: size.allocated,
        knownItemCount: size.count, partial: size.partial,
        related: [],
        manualUninstallerSuggested: (try? DescriptorFileSystem.identity(
          at: app.path + "/Contents/Library/SystemExtensions")) != nil
          || (try? DescriptorFileSystem.identity(at: app.path + "/Contents/Library/LaunchServices")) != nil)
      report.sizeLimitReached = size.limited
      reports.append(report)
      unpublished.append(report)
      let now = uptime()
      if unpublished.count >= 8 || now - lastPublished >= 0.1 {
        emit(.measured(unpublished))
        unpublished.removeAll(keepingCapacity: true)
        lastPublished = now
      }
    }
    if !Task.isCancelled && !unpublished.isEmpty { emit(.measured(unpublished)) }
    if Task.isCancelled { return (inventory, reports) }
    let relatedCandidates = await related.discover()
    if Task.isCancelled { return (inventory, reports) }
    reports = reports.map { app in
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
      var enriched = ApplicationReport(
        path: app.path, bundleID: app.bundleID, version: app.version,
        signerTeamID: app.signerTeamID, logical: app.logical,
        allocated: app.allocated, knownItemCount: app.knownItemCount,
        partial: app.partial, related: candidates,
        manualUninstallerSuggested: app.manualUninstallerSuggested)
      enriched.sizeLimitReached = app.sizeLimitReached
      return enriched
    }
    reports.sort {
      if $0.logical.knownLowerBound != $1.logical.knownLowerBound {
        return $0.logical.knownLowerBound > $1.logical.knownLowerBound
      }
      return $0.path < $1.path
    }
    if !Task.isCancelled { emit(.completed(inventory, reports)) }
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

  private static func limitedUnknownSize() -> (
    logical: ByteAggregate, allocated: ByteAggregate, count: Int, partial: Bool, limited: Bool
  ) {
    (
      ByteAggregate(knownLowerBound: 0, completeTotal: nil),
      ByteAggregate(knownLowerBound: 0, completeTotal: nil), 0, true, true
    )
  }

  private static func measure(
    path: String, homeDirectory: String, overBudget: () -> Bool
  ) -> (
    logical: ByteAggregate, allocated: ByteAggregate, count: Int, partial: Bool, limited: Bool
  ) {
    guard let root = try? DescriptorFileSystem.identity(at: path), root.kind == .directory,
      let volume = try? DescriptorFileSystem.volumeID(at: path)
    else {
      return (
        ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        ByteAggregate(knownLowerBound: 0, completeTotal: nil), 0, true, overBudget()
      )
    }
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var count = 0
    var partial = false
    var limited = false
    var stack: [(String, FileIdentity)] = [(path, root)]
    while let (currentPath, identity) = stack.popLast() {
      if overBudget() {
        limited = true
        partial = true
        break
      }
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
          if overBudget() {
            limited = true
            partial = true
            break
          }
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
    if overBudget() {
      limited = true
      partial = true
    }
    if (try? DescriptorFileSystem.identity(at: path)) != root { partial = true }
    return (
      ByteAggregate(knownLowerBound: logical, completeTotal: partial ? nil : logical),
      ByteAggregate(knownLowerBound: allocated, completeTotal: partial ? nil : allocated),
      count, partial, limited
    )
  }

}
