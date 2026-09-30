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
  public var related: [RelatedDataCandidate]
  public let manualUninstallerSuggested: Bool
  /// Resolved location when the listed path is a symbolic link to an app.
  public var linkTarget: String?
  /// Cached bundle-layout metadata; unsupported wrappers are display-only.
  public var isIOSWrapper = false

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
    case orphans([RelatedDataCandidate])
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
    let known = inventory.applications.map {
      (
        path: $0.path, bundleID: Optional($0.bundleID), version: $0.version, link: $0.linkTarget,
        isIOSWrapper: Self.isIOSWrapper(at: $0.linkTarget ?? $0.path)
      )
    }
    let unknown = inventory.unidentifiedPaths.map {
      (
        path: $0, bundleID: Optional<String>.none, version: Optional<String>.none, link: Optional<String>.none,
        isIOSWrapper: Self.isIOSWrapper(at: $0)
      )
    }
    let metadata = (known + unknown).map { app in
      var report = ApplicationReport(
        path: app.path, bundleID: app.bundleID, version: app.version,
        signerTeamID: nil,
        logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        allocated: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        knownItemCount: 0, partial: true, related: [],
        manualUninstallerSuggested: false)
      report.linkTarget = app.link
      report.isIOSWrapper = app.isIOSWrapper
      return report
    }
    emit(.inventory(inventory, metadata))
    if Task.isCancelled { return (inventory, []) }
    var reports: [ApplicationReport] = []
    // Every package is measured completely by the parallel engine; a few
    // packages at a time keep the total thread count bounded.
    let apps = known + unknown
    let homeDirectory = related.homeDirectory
    await withTaskGroup(of: ApplicationReport.self) { group in
      var next = 0
      func enqueue() {
        guard next < apps.count, !Task.isCancelled else { return }
        let app = apps[next]
        next += 1
        group.addTask {
          // A linked app is measured at its resolved location, read-only.
          let size = await Self.measure(path: app.link ?? app.path, homeDirectory: homeDirectory)
          var report = ApplicationReport(
            path: app.path, bundleID: app.bundleID, version: app.version,
            signerTeamID: nil,
            logical: size.logical, allocated: size.allocated,
            knownItemCount: size.count, partial: size.partial,
            related: [],
            manualUninstallerSuggested: (try? DescriptorFileSystem.identity(
              at: app.path + "/Contents/Library/SystemExtensions")) != nil
              || (try? DescriptorFileSystem.identity(at: app.path + "/Contents/Library/LaunchServices")) != nil)
          report.linkTarget = app.link
          report.isIOSWrapper = app.isIOSWrapper
          return report
        }
      }
      for _ in 0..<min(Self.concurrentPackages, apps.count) { enqueue() }
      var unpublished: [ApplicationReport] = []
      var lastPublished = uptime()
      while let report = await group.next() {
        reports.append(report)
        unpublished.append(report)
        let now = uptime()
        if unpublished.count >= 8 || now - lastPublished >= 0.1 {
          emit(.measured(unpublished))
          unpublished.removeAll(keepingCapacity: true)
          lastPublished = now
        }
        enqueue()
      }
      if !Task.isCancelled && !unpublished.isEmpty { emit(.measured(unpublished)) }
    }
    if Task.isCancelled { return (inventory, reports) }
    let relatedCandidates = await related.discover()
    if Task.isCancelled { return (inventory, reports) }
    emit(
      .orphans(
        relatedCandidates.filter {
          $0.classification == .orphanVerified || $0.classification == .historicallyVerifiedAbsent
        }))
    reports = reports.map { app in
      let candidates: [RelatedDataCandidate]
      if let id = app.bundleID {
        let matched = relatedCandidates.filter { $0.bundleID == id }
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
      enriched.linkTarget = app.linkTarget
      enriched.isIOSWrapper = app.isIOSWrapper
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

  /// Measures just one explicitly supplied bundle and its standard data locations.
  public func report(path: String) async -> ApplicationReport? {
    guard let app = related.application(at: path) else {
      guard Self.isIOSWrapper(at: path) else { return nil }
      let size = await Self.measure(path: path, homeDirectory: related.homeDirectory)
      var report = ApplicationReport(
        path: path, bundleID: nil, version: nil, signerTeamID: nil,
        logical: size.logical, allocated: size.allocated, knownItemCount: size.count, partial: size.partial,
        related: [], manualUninstallerSuggested: false)
      report.isIOSWrapper = true
      return report
    }
    let isIOSWrapper = Self.isIOSWrapper(at: app.linkTarget ?? path)
    async let observation = related.focusedObservation(for: app)
    let size = await Self.measure(path: app.linkTarget ?? path, homeDirectory: related.homeDirectory)
    let data = await observation
    var report = ApplicationReport(
      path: path, bundleID: app.bundleID, version: app.version,
      signerTeamID: data.signerTeamID,
      logical: size.logical, allocated: size.allocated, knownItemCount: size.count, partial: size.partial,
      related: data.candidates, manualUninstallerSuggested: false)
    report.linkTarget = app.linkTarget
    report.isIOSWrapper = isIOSWrapper
    return report
  }

  private static func isIOSWrapper(at path: String) -> Bool {
    RelatedDataService.infoPlistPath(ofBundleAt: path) != path + "/Contents/Info.plist"
  }

  public func discoverOrphans() async -> [RelatedDataCandidate] {
    await related.discover().filter {
      $0.classification == .orphanVerified || $0.classification == .historicallyVerifiedAbsent
    }
  }

  static let concurrentPackages = 4

  /// Complete package size from the parallel engine. Protected interiors are
  /// summed from metadata; unreadable parts leave a lower bound.
  public static func measure(path: String, homeDirectory: String) async -> (
    logical: ByteAggregate, allocated: ByteAggregate, count: Int, partial: Bool
  ) {
    if let identity = try? DescriptorFileSystem.identity(at: path), identity.kind == .regular {
      return (
        ByteAggregate(knownLowerBound: identity.logicalBytes, completeTotal: identity.logicalBytes),
        ByteAggregate(knownLowerBound: identity.allocatedBytes, completeTotal: identity.allocatedBytes), 1, false
      )
    }
    let configuration = ScanConfiguration(workers: 4, homeDirectory: homeDirectory)
    guard let run = try? ScanEngine(configuration: configuration).start(root: path) else {
      return (
        ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        ByteAggregate(knownLowerBound: 0, completeTotal: nil), 0, true
      )
    }
    await withTaskCancellationHandler {
      await run.waitUntilFinished()
    } onCancel: {
      run.cancel()
    }
    guard let root = run.tree.item(run.tree.rootID) else {
      return (
        ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        ByteAggregate(knownLowerBound: 0, completeTotal: nil), 0, true
      )
    }
    return (root.logical, root.allocated, Int(root.itemCount), root.logical.completeTotal == nil)
  }
}
