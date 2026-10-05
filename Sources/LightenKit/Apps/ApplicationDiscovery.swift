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
  /// Cached observation of a physical iOS Wrapper layout.
  public var isIOSWrapper = false
  /// Native physical root observation for reconciling displayed action results.
  /// This value never grants permission to act on a package.
  public let displayRootIdentity: FileIdentity?

  public init(
    path: String, bundleID: String?, version: String?, signerTeamID: String?, logical: ByteAggregate,
    allocated: ByteAggregate, knownItemCount: Int, partial: Bool, related: [RelatedDataCandidate],
    manualUninstallerSuggested: Bool, linkTarget: String? = nil, isIOSWrapper: Bool = false,
    displayRootIdentity: FileIdentity? = nil
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
    self.displayRootIdentity = displayRootIdentity
  }

  public var id: String { path }
}

public struct ApplicationDiscovery: Sendable {
  typealias Measurement = (logical: ByteAggregate, allocated: ByteAggregate, count: Int, partial: Bool)
  private let related: RelatedDataService
  private let uptime: @Sendable () -> TimeInterval
  private let lightweightListing: ApplicationListing.Collector
  private let measurement: @Sendable (String, String) async -> Measurement

  public init(
    related: RelatedDataService = RelatedDataService(),
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.related = related
    self.uptime = uptime
    self.lightweightListing = { progress in
      ApplicationListing.observe(roots: related.lightweightListingRoots, progress: progress)
    }
    self.measurement = Self.measure
  }

  init(
    related: RelatedDataService,
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    lightweightListing: @escaping @Sendable () -> [ApplicationListEntry],
    measurement: @escaping @Sendable (String, String) async -> Measurement
  ) {
    self.related = related
    self.uptime = uptime
    self.lightweightListing = { _ in lightweightListing() }
    self.measurement = measurement
  }

  public enum Event: Sendable {
    case session(ApplicationScanSession)
    /// Finality is only for the bounded display collector, never inventory or ownership completeness.
    case listed([ApplicationListEntry], isFinalBatch: Bool = true)
    case inventory(BundleInventory, [ApplicationReport])
    case related(path: String, candidates: [RelatedDataCandidate], ownershipPending: Bool)
    case ownershipReady(BundleInventory)
    case measured([ApplicationReport])
    case orphans([RelatedDataCandidate])
    case completed(BundleInventory, [ApplicationReport])
  }

  public func scanSession() -> ApplicationScanSession {
    ApplicationScanSession(
      related: related, uptime: uptime, lightweightListing: lightweightListing, measurement: measurement)
  }

  /// The compatibility stream retains its session for selected review and
  /// planning. Dropping the stream cancels its owned workers.
  public func events(includeAllRelated: Bool = false) -> AsyncStream<Event> {
    let session = scanSession()
    return AsyncStream { continuation in
      let worker = Task {
        for await event in await session.events(includeAllRelated: includeAllRelated) { continuation.yield(event) }
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
    for await event in await session.events(includeAllRelated: true) {
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
    uptime: @escaping @Sendable () -> TimeInterval, includeAllRelated: Bool,
    emit: @escaping @Sendable (Event) -> Void
  ) async {
    let entries = await session.displayListing { entries in
      emit(.listed(entries, isFinalBatch: false))
    }
    guard !Task.isCancelled else { return }
    emit(.listed(entries))
    let listing = await session.installedListing()
    let metadata = metadataReports(listing)
    guard !Task.isCancelled else { return }
    emit(.inventory(listing, metadata))
    var inventory = listing
    var reports = metadata
    var candidates: [RelatedDataCandidate] = []
    await withTaskGroup(of: Result.self) { group in
      group.addTask {
        .sizes(
          await measureReports(
            metadata, session: session, homeDirectory: related.homeDirectory, uptime: uptime, emit: emit))
      }
      group.addTask {
        guard let context = try? await session.context(base: listing) else { return .related(listing, []) }
        guard !Task.isCancelled else { return .related(context.inventory, []) }
        emit(.ownershipReady(context.inventory))
        guard includeAllRelated else { return .related(context.inventory, []) }
        let candidates = await session.observedRelatedCandidates()
        guard !Task.isCancelled else { return .related(context.inventory, []) }
        for app in context.inventory.applications {
          emit(
            .related(
              path: app.path,
              candidates: associatedCandidates(
                candidates, bundleID: app.bundleID, path: app.path, physicalPath: app.linkTarget ?? app.path,
                homeDirectory: related.homeDirectory),
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
      reports += await measureReports(
        extra, session: session, homeDirectory: related.homeDirectory, uptime: uptime, emit: emit)
    }
    guard !Task.isCancelled else { return }
    reports = reports.map { report in
      var enriched = report
      enriched.related = associatedCandidates(
        candidates, bundleID: report.bundleID, path: report.path, physicalPath: report.linkTarget ?? report.path,
        homeDirectory: related.homeDirectory)
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

  private static func associatedCandidates(
    _ candidates: [RelatedDataCandidate], bundleID: String?, path: String, physicalPath: String,
    homeDirectory: String
  ) -> [RelatedDataCandidate] {
    guard let bundleID else { return [] }
    let cached =
      RelatedDataService.isCachedApplication(path, homeDirectory: homeDirectory)
      || RelatedDataService.isCachedApplication(physicalPath, homeDirectory: homeDirectory)
    return candidates.filter { candidate in
      guard candidate.bundleID == bundleID else { return false }
      return !cached
        || RelatedLocation.matching(path: candidate.path, homeDirectory: homeDirectory)?.0 == .groupContainers
    }
  }

  private static func metadataReports(_ inventory: BundleInventory) -> [ApplicationReport] {
    let known = inventory.applications.map { app in
      var report = ApplicationReport(
        path: app.path, bundleID: app.bundleID, version: app.version, signerTeamID: nil,
        logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        allocated: ByteAggregate(knownLowerBound: 0, completeTotal: nil), knownItemCount: 0, partial: true,
        related: [], manualUninstallerSuggested: false,
        displayRootIdentity: try? DescriptorFileSystem.identity(at: app.linkTarget ?? app.path))
      report.linkTarget = app.linkTarget
      report.isIOSWrapper = isIOSWrapper(at: app.linkTarget ?? app.path)
      return report
    }
    return known
      + inventory.unidentifiedPaths.map { path in
        let physical = inventory.applicationMetadata.first { $0.path == path }?.physicalPath ?? path
        var report = ApplicationReport(
          path: path, bundleID: nil, version: nil, signerTeamID: nil,
          logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
          allocated: ByteAggregate(knownLowerBound: 0, completeTotal: nil), knownItemCount: 0, partial: true,
          related: [], manualUninstallerSuggested: false,
          displayRootIdentity: try? DescriptorFileSystem.identity(at: physical))
        if physical != path { report.linkTarget = physical }
        report.isIOSWrapper = isIOSWrapper(at: physical)
        return report
      }
  }

  private static func measureReports(
    _ metadata: [ApplicationReport], session: ApplicationScanSession, homeDirectory: String,
    uptime: @Sendable () -> TimeInterval,
    emit: @Sendable (Event) -> Void
  ) async -> [ApplicationReport] {
    await session.enqueueMeasurements(metadata)
    return await withTaskGroup(of: ApplicationReport.self) { group in
      var reports: [ApplicationReport] = []
      func enqueue() async {
        guard !Task.isCancelled, let app = await session.nextMeasurement() else { return }
        group.addTask {
          let size = await session.measureApplication(path: app.linkTarget ?? app.path, homeDirectory: homeDirectory)
          var report = ApplicationReport(
            path: app.path, bundleID: app.bundleID, version: app.version, signerTeamID: nil,
            logical: size.logical, allocated: size.allocated, knownItemCount: size.count, partial: size.partial,
            related: [],
            manualUninstallerSuggested: (try? DescriptorFileSystem.identity(
              at: app.path + "/Contents/Library/SystemExtensions")) != nil
              || (try? DescriptorFileSystem.identity(at: app.path + "/Contents/Library/LaunchServices")) != nil,
            displayRootIdentity: app.displayRootIdentity)
          report.linkTarget = app.linkTarget
          report.isIOSWrapper = app.isIOSWrapper
          return report
        }
      }
      for _ in 0..<min(concurrentPackages, metadata.count) { await enqueue() }
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
        await enqueue()
      }
      if !Task.isCancelled && !unpublished.isEmpty { emit(.measured(unpublished)) }
      return reports
    }
  }

  /// Measures just one explicitly supplied bundle and its standard data locations.
  public func report(path: String) async -> ApplicationReport? {
    guard related.scopeExclusion(at: path) == nil else { return nil }
    guard let app = related.application(at: path) else {
      let observation = ApplicationMetadataObservation.read(at: path)
      guard let metadata = try? ApplicationPackagePlanning.metadata(at: observation.physicalPath),
        metadata.observation.bundleIdentifier == nil
      else { return nil }
      let size = await Self.measure(
        path: observation.physicalPath, homeDirectory: related.homeDirectory)
      var report = ApplicationReport(
        path: path, bundleID: nil, version: metadata.version, signerTeamID: nil,
        logical: size.logical, allocated: size.allocated, knownItemCount: size.count,
        partial: size.partial,
        related: [], manualUninstallerSuggested: false, displayRootIdentity: metadata.rootIdentity)
      if observation.physicalPath != path { report.linkTarget = observation.physicalPath }
      report.isIOSWrapper = Self.isIOSWrapper(at: observation.physicalPath)
      return report
    }
    let physical = app.linkTarget ?? path
    guard related.scopeExclusion(at: physical) == nil else { return nil }
    let displayRootIdentity = try? DescriptorFileSystem.identity(at: physical)
    async let observation = related.focusedObservation(for: app)
    let size = await Self.measure(path: physical, homeDirectory: related.homeDirectory)
    let data = await observation
    var report = ApplicationReport(
      path: path, bundleID: app.bundleID, version: app.version,
      signerTeamID: data.signerTeamID,
      logical: size.logical, allocated: size.allocated, knownItemCount: size.count, partial: size.partial,
      related: data.candidates, manualUninstallerSuggested: false, displayRootIdentity: displayRootIdentity)
    report.linkTarget = app.linkTarget
    report.isIOSWrapper = Self.isIOSWrapper(at: physical)
    return report
  }

  private static func isIOSWrapper(at path: String) -> Bool {
    (try? DescriptorFileSystem.identity(at: path + "/Wrapper"))?.kind == .directory
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
