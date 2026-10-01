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

  public init(
    path: String, bundleID: String?, version: String?, signerTeamID: String?, logical: ByteAggregate,
    allocated: ByteAggregate, knownItemCount: Int, partial: Bool, related: [RelatedDataCandidate],
    manualUninstallerSuggested: Bool, linkTarget: String? = nil, isIOSWrapper: Bool = false
  ) {
    self.path = path
    self.bundleID = bundleID
    self.version = version
    self.signerTeamID = signerTeamID
    self.logical = logical
    self.allocated = allocated
    self.knownItemCount = knownItemCount
    self.partial = partial
    self.related = related
    self.manualUninstallerSuggested = manualUninstallerSuggested
    self.linkTarget = linkTarget
    self.isIOSWrapper = isIOSWrapper
  }

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
    case session(ApplicationScanSession)
    case inventory(BundleInventory, [ApplicationReport])
    case related(path: String, candidates: [RelatedDataCandidate], ownershipPending: Bool)
    case ownershipReady(BundleInventory)
    case measured([ApplicationReport])
    case orphans([RelatedDataCandidate])
    case completed(BundleInventory, [ApplicationReport])
  }

  public func scanSession() -> ApplicationScanSession {
    ApplicationScanSession(related: related, uptime: uptime)
  }

  /// The compatibility stream retains its session for selected review and
  /// planning. Dropping the stream cancels its owned workers.
  public func events() -> AsyncStream<Event> {
    let session = scanSession()
    return AsyncStream { continuation in
      let worker = Task {
        for await event in await session.events() { continuation.yield(event) }
        continuation.finish()
      }
      continuation.onTermination = { @Sendable termination in
        if case .cancelled = termination {
          worker.cancel()
          Task { await session.cancel() }
        }
      }
    }
  }

  public func discover() async -> (BundleInventory, [ApplicationReport]) {
    let session = scanSession()
    var inventory = BundleInventory(applications: [], unidentifiedPaths: [], complete: false, observedAt: Date())
    var reports: [ApplicationReport] = []
    for await event in await session.events() {
      switch event {
      case .inventory(let listing, let metadata):
        inventory = listing
        reports = metadata
      case .ownershipReady(let listing): inventory = listing
      case .completed(let listing, let final):
        inventory = listing
        reports = final
      default: break
      }
    }
    return (inventory, reports)
  }

  private enum Result: Sendable {
    case sizes([ApplicationReport])
    case related(BundleInventory, [RelatedDataCandidate])
  }

  static func run(
    session: ApplicationScanSession, related: RelatedDataService,
    uptime: @escaping @Sendable () -> TimeInterval, emit: @escaping @Sendable (Event) -> Void
  ) async {
    let listing = await session.installedListing()
    let metadata = metadataReports(listing)
    guard !Task.isCancelled else { return }
    emit(.inventory(listing, metadata))
    var inventory = listing
    var reports = metadata
    var candidates: [RelatedDataCandidate] = []
    await withTaskGroup(of: Result.self) { group in
      group.addTask {
        .sizes(await measureReports(metadata, homeDirectory: related.homeDirectory, uptime: uptime, emit: emit))
      }
      group.addTask {
        let context = await session.context(base: listing)
        guard !Task.isCancelled else { return .related(context.inventory, []) }
        emit(.ownershipReady(context.inventory))
        let candidates = await session.observedRelatedCandidates()
        guard !Task.isCancelled else { return .related(context.inventory, []) }
        for app in context.inventory.applications {
          emit(
            .related(
              path: app.path, candidates: candidates.filter { $0.bundleID == app.bundleID },
              ownershipPending: !context.inventory.ownershipComplete))
        }
        emit(
          .orphans(
            candidates.filter {
              $0.classification == .orphanVerified || $0.classification == .historicallyVerifiedAbsent
            }))
        return .related(context.inventory, candidates)
      }
      for await result in group {
        switch result {
        case .sizes(let measured): reports = measured
        case .related(let current, let data):
          inventory = current
          candidates = data
        }
      }
    }
    guard !Task.isCancelled else { return }
    // Registered application rows can arrive after the cheap initial listing.
    let extra = metadataReports(inventory).filter { row in !reports.contains { $0.path == row.path } }
    if !extra.isEmpty {
      reports += await measureReports(extra, homeDirectory: related.homeDirectory, uptime: uptime, emit: emit)
    }
    guard !Task.isCancelled else { return }
    reports = reports.map { report in
      var enriched = report
      enriched.related = report.bundleID.map { id in candidates.filter { $0.bundleID == id } } ?? []
      return enriched
    }
    reports.sort {
      if $0.logical.knownLowerBound != $1.logical.knownLowerBound {
        return $0.logical.knownLowerBound > $1.logical.knownLowerBound
      }
      return $0.path < $1.path
    }
    emit(.completed(inventory, reports))
  }

  private static func metadataReports(_ inventory: BundleInventory) -> [ApplicationReport] {
    let known = inventory.applications.map { app in
      var report = ApplicationReport(
        path: app.path, bundleID: app.bundleID, version: app.version, signerTeamID: nil,
        logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        allocated: ByteAggregate(knownLowerBound: 0, completeTotal: nil), knownItemCount: 0, partial: true,
        related: [], manualUninstallerSuggested: false)
      report.linkTarget = app.linkTarget
      report.isIOSWrapper = isIOSWrapper(at: app.linkTarget ?? app.path)
      return report
    }
    return known
      + inventory.unidentifiedPaths.map { path in
        var report = ApplicationReport(
          path: path, bundleID: nil, version: nil, signerTeamID: nil,
          logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
          allocated: ByteAggregate(knownLowerBound: 0, completeTotal: nil), knownItemCount: 0, partial: true,
          related: [], manualUninstallerSuggested: false)
        report.isIOSWrapper = isIOSWrapper(at: path)
        return report
      }
  }

  private static func measureReports(
    _ metadata: [ApplicationReport], homeDirectory: String, uptime: @Sendable () -> TimeInterval,
    emit: @Sendable (Event) -> Void
  ) async -> [ApplicationReport] {
    await withTaskGroup(of: ApplicationReport.self) { group in
      var reports: [ApplicationReport] = []
      var next = 0
      func enqueue() {
        guard next < metadata.count, !Task.isCancelled else { return }
        let app = metadata[next]
        next += 1
        group.addTask {
          let size = await measure(path: app.linkTarget ?? app.path, homeDirectory: homeDirectory)
          var report = ApplicationReport(
            path: app.path, bundleID: app.bundleID, version: app.version, signerTeamID: nil,
            logical: size.logical, allocated: size.allocated, knownItemCount: size.count, partial: size.partial,
            related: [],
            manualUninstallerSuggested: (try? DescriptorFileSystem.identity(
              at: app.path + "/Contents/Library/SystemExtensions")) != nil
              || (try? DescriptorFileSystem.identity(at: app.path + "/Contents/Library/LaunchServices")) != nil)
          report.linkTarget = app.linkTarget
          report.isIOSWrapper = app.isIOSWrapper
          return report
        }
      }
      for _ in 0..<min(concurrentPackages, metadata.count) { enqueue() }
      var unpublished: [ApplicationReport] = []
      var lastPublished = uptime()
      while let report = await group.next() {
        reports.append(report)
        unpublished.append(report)
        let now = uptime()
        if !Task.isCancelled, unpublished.count >= 8 || now - lastPublished >= 0.1 {
          emit(.measured(unpublished))
          unpublished.removeAll(keepingCapacity: true)
          lastPublished = now
        }
        enqueue()
      }
      if !Task.isCancelled && !unpublished.isEmpty { emit(.measured(unpublished)) }
      return reports
    }
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
