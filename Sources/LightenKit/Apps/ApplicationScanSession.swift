import Darwin
import Foundation
import Synchronization

public struct ApplicationRelatedReview: Sendable {
  public enum Phase: Sendable, Equatable {
    case legacy
    case shallow
    case measuring(completed: Int, total: Int)
    case initialComplete
    case enriched
  }
  public let application: InstalledApplication
  public let candidates: [RelatedDataCandidate]
  public let signerTeamID: String?
  public let ownershipPending: Bool
  public let registrationReport: ApplicationRegistrationReport?
  /// Informational coverage only; it supplies no ownership or action authority.
  public let openFilesComplete: Bool?
  public let phase: Phase
  public let globalEvidencePending: Bool
  public let globalEvidenceUnavailable: Bool

  public init(
    application: InstalledApplication, candidates: [RelatedDataCandidate], signerTeamID: String? = nil,
    ownershipPending: Bool = true, registrationReport: ApplicationRegistrationReport? = nil,
    phase: Phase = .legacy, openFilesComplete: Bool? = nil,
    globalEvidencePending: Bool = false, globalEvidenceUnavailable: Bool = false
  ) {
    self.application = application
    self.candidates = candidates
    self.signerTeamID = signerTeamID
    self.ownershipPending = ownershipPending
    self.registrationReport = registrationReport
    self.phase = phase
    self.openFilesComplete = openFilesComplete
    self.globalEvidencePending = globalEvidencePending
    self.globalEvidenceUnavailable = globalEvidenceUnavailable
  }
}

struct ApplicationContextScope: Sendable, Equatable {
  let home: String
  let applicationRoots: [String]
  let ownershipRoots: [String]
}

struct ApplicationPathObservation: Sendable {
  let path: String
  let identity: FileIdentity?
  private let namespaceOwnerID: uid_t?
  private let nativeReferenceDirectories: ApplicationReferenceDirectories?

  init(
    path: String, identity: FileIdentity?, namespaceOwnerID: uid_t? = nil,
    nativeReferenceDirectories: ApplicationReferenceDirectories? = nil
  ) {
    self.path = path
    self.identity = identity
    self.namespaceOwnerID = namespaceOwnerID
    self.nativeReferenceDirectories = nativeReferenceDirectories
  }

  func validate() throws {
    try nativeReferenceDirectories?.validate()
    if let namespaceOwnerID {
      guard let identity, identity.kind == .directory, namespaceOwnerID == geteuid() else {
        throw RelatedFailure.changedItem
      }
      let (parent, name) = try DescriptorFileSystem.openParent(of: path)
      defer { close(parent) }
      let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
      guard fd >= 0 else { throw RelatedFailure.changedItem }
      defer { close(fd) }
      var details = stat()
      guard fstat(fd, &details) == 0, details.st_uid == namespaceOwnerID,
        identity.matchesStableTrashIdentity(DescriptorFileSystem.identity(from: details)),
        identity.matchesStableTrashIdentity(try DescriptorFileSystem.identity(name: name, relativeTo: parent)),
        fstat(fd, &details) == 0, details.st_uid == namespaceOwnerID,
        identity.matchesStableTrashIdentity(DescriptorFileSystem.identity(from: details)),
        identity.matchesStableTrashIdentity(try DescriptorFileSystem.identity(name: name, relativeTo: parent))
      else { throw RelatedFailure.changedItem }
      return
    }
    let current: FileIdentity?
    do { current = try DescriptorFileSystem.identity(at: path) } catch FileSystemFailure.systemCall(_, let code)
      where code == ENOENT || code == ENOTDIR
    { current = nil } catch { throw RelatedFailure.changedItem }
    guard current == identity else { throw RelatedFailure.changedItem }
  }

  /// Checks the original namespace through one fresh no-follow directory
  /// descriptor, then checks the named root again to detect replacements.
  static func validate(_ observations: [Self], root: String, expected: FileIdentity) throws {
    let (parentFD, name) = try DescriptorFileSystem.openParent(of: root)
    defer { close(parentFD) }
    guard try DescriptorFileSystem.identity(name: name, relativeTo: parentFD) == expected else {
      throw RelatedFailure.changedItem
    }
    let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("openat", errno) }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0 else { throw FileSystemFailure.systemCall("fstat", errno) }
    guard DescriptorFileSystem.identity(from: details) == expected else { throw RelatedFailure.changedItem }
    for observation in observations where observation.path != root {
      if observation.path.hasPrefix(root + "/") {
        let relative = String(observation.path.dropFirst(root.count + 1))
        let current: FileIdentity?
        do {
          current = try DescriptorFileSystem.identity(name: relative, relativeTo: fd)
        } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT || code == ENOTDIR {
          current = nil
        }
        guard current == observation.identity else { throw RelatedFailure.changedItem }
      } else {
        try observation.validate()
      }
    }
    guard fstat(fd, &details) == 0 else { throw FileSystemFailure.systemCall("fstat", errno) }
    guard DescriptorFileSystem.identity(from: details) == expected,
      try DescriptorFileSystem.identity(at: root) == expected
    else { throw RelatedFailure.changedItem }
  }
}

/// Parsed IDs are reusable only while every full root and Info identity is
/// unchanged. A changed Info file is parsed again before it can supply an ID.
final class ApplicationContextMetadata: Sendable {
  private struct Key: Hashable {
    let path: String
    let registered: Bool
  }
  private struct Observation: Sendable {
    let identities: [ApplicationPathObservation]
    let application: InstalledApplication?
  }
  private let entries = Mutex<[Key: Observation]>([:])
  let ownedData = ApplicationDataEvidenceCache()

  private func identities(at path: String) throws -> [ApplicationPathObservation] {
    let root = try DescriptorFileSystem.identity(at: path)
    var observations = [ApplicationPathObservation(path: path, identity: root)]
    let physical: String
    if root.kind == .symbolicLink {
      guard let resolved = realpath(path, nil) else { throw FileSystemFailure.systemCall("realpath", errno) }
      physical = String(cString: resolved)
      free(resolved)
      observations.append(
        ApplicationPathObservation(path: physical, identity: try DescriptorFileSystem.identity(at: physical)))
    } else {
      physical = path
    }
    let relative = try ApplicationPackagePlanning.infoRelativePath(at: physical)
    var paths = [physical + "/Contents", physical + "/Info.plist", physical + "/Wrapper", physical + "/" + relative]
    if relative.hasPrefix("Wrapper/") {
      paths.append(((physical + "/" + relative) as NSString).deletingLastPathComponent)
    }
    for candidate in Set(paths).sorted() {
      let identity: FileIdentity?
      do { identity = try DescriptorFileSystem.identity(at: candidate) } catch FileSystemFailure.systemCall(_, let code)
        where code == ENOENT || code == ENOTDIR
      { identity = nil }
      observations.append(ApplicationPathObservation(path: candidate, identity: identity))
    }
    return observations
  }

  private func unchanged(_ observations: [ApplicationPathObservation]) -> Bool {
    guard let root = observations.first(where: { $0.identity?.kind == .directory }),
      let expected = root.identity
    else { return false }
    do {
      try ApplicationPathObservation.validate(observations, root: root.path, expected: expected)
      return true
    } catch { return false }
  }

  func application(at path: String, registered: Bool, read: () throws -> InstalledApplication?) throws
    -> InstalledApplication?
  {
    let key = Key(path: path, registered: registered)
    if let cached = entries.withLock({ $0[key] }),
      unchanged(cached.identities)
    {
      return cached.application
    }
    let current = try identities(at: path)
    let application = try read()
    let finished = try identities(at: path)
    guard current.count == finished.count,
      zip(current, finished).allSatisfy({ pair in
        pair.0.path == pair.1.path && pair.0.identity == pair.1.identity
      })
    else { throw FileSystemFailure.changedDuringInspection }
    entries.withLock { $0[key] = Observation(identities: current, application: application) }
    return application
  }
}

/// Only the service can mint this context. Public inventories and review DTOs
/// are observations and are never accepted as ownership authority.
final class AuthenticApplicationContext: Sendable {
  let scope: ApplicationContextScope
  let inventory: BundleInventory
  let installedListing: BundleInventory
  let lineage: [ApplicationPathObservation]
  let registeredPaths: [String]
  let standardBundleID: String?
  let metadata: ApplicationContextMetadata
  private let infoAbsences: Mutex<[String: ApplicationMetadataObservation]>
  private let signers = Mutex<[String: ApplicationSignatureCache.Observation]>([:])
  private let dataEvidence = Mutex<[String: ApplicationOwnedDataEvidence]>([:])
  private struct DataClaims: Sendable {
    let claims: [String: [ApplicationOwnedDataEvidence]]
    let sources: [ApplicationPathObservation]
    let issues: [ApplicationAuxiliaryIssue]
    let packages: [String: [ApplicationPathObservation]]
    let independentSources: [ApplicationPathObservation]
  }
  private let dataClaims = Mutex<DataClaims?>(nil)
  private let dataSourceValidations = Mutex(0)
  var dataSourceValidationCount: Int { dataSourceValidations.withLock { $0 } }

  init(
    scope: ApplicationContextScope, inventory: BundleInventory, lineage: [ApplicationPathObservation],
    registeredPaths: [String], standardBundleID: String? = nil,
    installedListing: BundleInventory? = nil, metadata: ApplicationContextMetadata? = nil,
    dataEvidenceSource: AuthenticApplicationContext? = nil
  ) {
    self.scope = scope
    self.inventory = inventory
    self.installedListing = installedListing ?? inventory
    self.metadata = metadata ?? ApplicationContextMetadata()
    if let dataEvidenceSource {
      let observed = dataEvidenceSource.dataEvidence.withLock { $0 }
      dataEvidence.withLock { $0 = observed }
      dataClaims.withLock { $0 = dataEvidenceSource.dataClaims.withLock { $0 } }
    }
    self.infoAbsences = Mutex(
      Dictionary(
        inventory.applicationMetadata.compactMap { observation in
          if case .absentInfo = observation.state { return (observation.path, observation) }
          return nil
        }, uniquingKeysWith: { first, _ in first }))
    var first: [String: ApplicationPathObservation] = [:]
    for observation in lineage where first[observation.path] == nil { first[observation.path] = observation }
    self.lineage = first.values.sorted { $0.path < $1.path }
    self.registeredPaths = registeredPaths
    self.standardBundleID = standardBundleID
  }

  func signature(at path: String, cache: ApplicationSignatureCache) -> ApplicationSignatureCache.Observation? {
    if let observation = signers.withLock({ $0[path] }) {
      return (try? observation.identity.validate()) != nil ? observation : nil
    }
    guard let observation = cache.observation(at: path) else { return nil }
    return signers.withLock { entries in
      if let existing = entries[path] { return existing }
      entries[path] = observation
      return observation
    }
  }

  func validateSignatures() throws {
    let observations = signers.withLock { Array($0.values) }
    for observation in observations { try observation.identity.validate() }
  }

  func recordInfoAbsence(_ observation: ApplicationMetadataObservation) {
    guard case .absentInfo = observation.state else { return }
    infoAbsences.withLock { entries in
      if entries[observation.path] == nil { entries[observation.path] = observation }
    }
  }

  func observedInfoAbsences() -> [ApplicationMetadataObservation] {
    infoAbsences.withLock { $0.values.sorted { $0.path < $1.path } }
  }

  func recordDataEvidence(_ evidence: ApplicationOwnedDataEvidence) {
    let key = evidence.packagePath + "\n" + evidence.dataPath
    dataEvidence.withLock { entries in
      if entries[key] == nil { entries[key] = evidence }
    }
  }

  func observedDataEvidence(packagePath: String, dataPath: String) -> ApplicationOwnedDataEvidence? {
    dataEvidence.withLock { $0[packagePath + "\n" + dataPath] }
  }

  func observedDataClaims() -> [String: [ApplicationOwnedDataEvidence]]? {
    dataClaims.withLock { $0?.claims }
  }

  func recordDataClaims(
    _ claims: [String: [ApplicationOwnedDataEvidence]], sources: [ApplicationPathObservation],
    issues: [ApplicationAuxiliaryIssue]
  ) {
    let packagePaths = Set(inventory.applications.map { $0.linkTarget ?? $0.path })
    var packages: [String: [ApplicationPathObservation]] = [:]
    var independent: [ApplicationPathObservation] = []
    for source in sources {
      let parts = source.path.split(separator: "/")
      var prefix = ""
      var owner: String?
      for part in parts {
        prefix += "/" + part
        if packagePaths.contains(prefix) {
          owner = prefix
          break
        }
      }
      if let owner { packages[owner, default: []].append(source) } else { independent.append(source) }
    }
    dataClaims.withLock {
      if $0 == nil {
        $0 = DataClaims(
          claims: claims, sources: sources, issues: issues, packages: packages, independentSources: independent)
      }
    }
  }

  func observedDataIssues() -> [ApplicationAuxiliaryIssue] {
    dataClaims.withLock { $0?.issues ?? [] }
  }

  func validateDataSources(excludingPackage: String? = nil) throws {
    dataSourceValidations.withLock { $0 += 1 }
    let observed = dataClaims.withLock { $0 }
    guard let observed else { return }
    for (package, nodes) in observed.packages where package != excludingPackage {
      guard let root = nodes.first(where: { $0.path == package })?.identity else {
        throw RelatedFailure.incompleteInventory
      }
      try ApplicationPathObservation.validate(nodes, root: package, expected: root)
    }
    for source in observed.independentSources {
      if let excludingPackage,
        source.path == excludingPackage || source.path.hasPrefix(excludingPackage + "/")
      {
        continue
      }
      try source.validate()
    }
  }
}

/// Native service values share concrete plan bindings. Injected services each
/// receive a separate registry; copying a service preserves its lineage.
final class ApplicationPlanContexts: Sendable {
  static let native = ApplicationPlanContexts()
  private struct Binding: Sendable {
    let plan: ActionPlan
    let contexts: [UUID: AuthenticApplicationContext]
  }
  private let bindings = Mutex<[Binding]>([])
  private let maximumAdditionalPaths: Int

  init(maximumAdditionalPaths: Int = 250_000) {
    self.maximumAdditionalPaths = maximumAdditionalPaths
  }

  func bind(_ plan: ActionPlan, context: AuthenticApplicationContext) throws {
    try bind(plan, contexts: Dictionary(plan.items.map { ($0.id, context) }, uniquingKeysWith: { first, _ in first }))
  }

  func bind(_ plan: ActionPlan, contexts: [UUID: AuthenticApplicationContext]) throws {
    try bindings.withLock { entries in
      entries.removeAll { $0.plan.id == plan.id }
      let selected = contexts.filter { entry in plan.items.contains { $0.id == entry.key } }
      entries.append(Binding(plan: plan, contexts: selected))
      // Plans from one scan share its full native observation. Charging that
      // same object once keeps a large scan usable without discarding its
      // original negative proof. Other retained contexts have a bounded budget.
      func additionalRetainedPaths() -> Int {
        var sizes: [ObjectIdentifier: Int] = [:]
        for entry in entries {
          for context in entry.contexts.values {
            sizes[ObjectIdentifier(context)] = context.lineage.count
          }
        }
        return sizes.values.reduce(0, +) - (sizes.values.max() ?? 0)
      }
      while entries.count > 64 || additionalRetainedPaths() > maximumAdditionalPaths {
        guard entries.count > 1 else {
          entries.removeAll { $0.plan.id == plan.id }
          throw PlanRejection(
            .unavailable, path: plan.items.first?.sourcePath ?? "",
            ruleID: "application-context-capacity: create a smaller plan")
        }
        entries.removeFirst()
      }
    }
  }

  func context(for plan: ActionPlan, scope: ApplicationContextScope, itemID: UUID? = nil)
    -> AuthenticApplicationContext?
  {
    bindings.withLock { entries in
      guard let binding = entries.first(where: { $0.plan == plan }) else { return nil }
      let context: AuthenticApplicationContext?
      if let itemID { context = binding.contexts[itemID] } else { context = binding.contexts.values.first }
      return context?.scope == scope ? context : nil
    }
  }
}

/// One discovery lifetime owns one private ownership walk. Selected standard
/// data and package-only plans remain independent of that background work.
private final class ApplicationSessionActivity: Sendable {
  let active = Mutex(true)
}

public actor ApplicationScanSession {
  public nonisolated let id = UUID()
  private let related: RelatedDataService
  private let uptime: @Sendable () -> TimeInterval
  private let lightweightListing: ApplicationListing.Collector
  private let measurement: @Sendable (String, String) async -> ApplicationDiscovery.Measurement
  private var metadata = ApplicationContextMetadata()
  private var contextRevision = UUID()
  private var completedContext: AuthenticApplicationContext?
  private var dataEvidence: Task<Void, Never>?
  private var dataEvidenceUnavailable = false
  private let evidenceTimeout: @Sendable () async -> Void
  private var ownership: Task<AuthenticApplicationContext, any Error>?
  private var listing: Task<BundleInventory, Never>?
  private var displayListingTask: Task<[ApplicationListEntry], Never>?
  private var worker: Task<Void, Never>?
  private var relatedCandidates: Task<[RelatedDataCandidate], Never>?
  private var enrichments: [Task<Void, Never>] = []
  private var initialReviews: [Task<ApplicationRelatedReview, Never>] = []
  private var selectedReviewID: UUID?
  private var selectedInitial: Task<ApplicationRelatedReview, Never>?
  private var selectedEnrichment: Task<Void, Never>?
  private var continuation: AsyncStream<ApplicationDiscovery.Event>.Continuation?
  private let activity = ApplicationSessionActivity()
  private var cancelled = false
  private var streamed = false
  private var pendingMeasurements: [ApplicationReport] = []
  private var visibleApplicationPaths: [String] = []

  init(
    related: RelatedDataService, uptime: @escaping @Sendable () -> TimeInterval,
    lightweightListing: ApplicationListing.Collector? = nil,
    measurement: @escaping @Sendable (String, String) async -> ApplicationDiscovery.Measurement = ApplicationDiscovery
      .measure,
    evidenceTimeout: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(30)) }
  ) {
    self.related = related
    self.uptime = uptime
    self.lightweightListing =
      lightweightListing ?? { progress in
        ApplicationListing.observe(roots: related.lightweightListingRoots, progress: progress)
      }
    self.measurement = measurement
    self.evidenceTimeout = evidenceTimeout
  }

  public func events(includeAllRelated: Bool = false) -> AsyncStream<ApplicationDiscovery.Event> {
    guard !streamed, !cancelled else { return AsyncStream { $0.finish() } }
    streamed = true
    let pair = AsyncStream<ApplicationDiscovery.Event>.makeStream()
    continuation = pair.continuation
    pair.continuation.yield(.session(self))
    let service = related
    let clock = uptime
    worker = Task.detached(priority: .utility) { [weak self] in
      guard let self else {
        pair.continuation.finish()
        return
      }
      await ApplicationDiscovery.run(
        session: self, related: service, uptime: clock, includeAllRelated: includeAllRelated
      ) { event in
        pair.continuation.yield(event)
      }
      await self.finishStream()
      pair.continuation.finish()
    }
    pair.continuation.onTermination = { @Sendable termination in
      if case .cancelled = termination { Task { await self.cancel() } }
    }
    return pair.stream
  }

  func displayListing(
    progress: @escaping @Sendable ([ApplicationListEntry]) -> Void = { _ in }
  ) async -> [ApplicationListEntry] {
    if let displayListingTask { return await displayListingTask.value }
    let listing = lightweightListing
    let task = Task.detached(priority: .userInitiated) { listing(progress) }
    displayListingTask = task
    if cancelled { task.cancel() }
    return await task.value
  }

  /// Visible rows are taken first whenever a package measurement slot becomes free.
  public func prioritizeVisibleApplications(paths: [String]) {
    visibleApplicationPaths = paths
  }

  func enqueueMeasurements(_ reports: [ApplicationReport]) {
    guard !cancelled else { return }
    pendingMeasurements.append(contentsOf: reports)
  }

  func nextMeasurement() -> ApplicationReport? {
    guard !cancelled, !pendingMeasurements.isEmpty else { return nil }
    if let path = visibleApplicationPaths.first(where: { path in pendingMeasurements.contains { $0.path == path } }),
      let index = pendingMeasurements.firstIndex(where: { $0.path == path })
    {
      return pendingMeasurements.remove(at: index)
    }
    return pendingMeasurements.removeFirst()
  }

  func measureApplication(path: String, homeDirectory: String) async -> ApplicationDiscovery.Measurement {
    await measurement(path, homeDirectory)
  }

  func installedListing() async -> BundleInventory {
    let revision = contextRevision
    if let listing {
      let result = await listing.value
      guard revision == contextRevision else { return await installedListing() }
      return result
    }
    let service = related
    let task = Task.detached(priority: .utility) { service.installedListing() }
    listing = task
    if cancelled { task.cancel() }
    let result = await task.value
    guard revision == contextRevision else { return await installedListing() }
    return result
  }

  func context(base: BundleInventory? = nil) async throws -> AuthenticApplicationContext {
    try Task.checkCancellation()
    guard !cancelled else { throw CancellationError() }
    let revision = contextRevision
    if let ownership {
      let context = try await ownership.value
      guard revision == contextRevision else { return try await self.context() }
      completedContext = context
      prepareDataEvidence(context: context)
      return context
    }
    let listing: BundleInventory
    if let base { listing = base } else { listing = await installedListing() }
    if let ownership {
      let context = try await ownership.value
      guard revision == contextRevision else { return try await self.context() }
      completedContext = context
      prepareDataEvidence(context: context)
      return context
    }
    let service = related
    let metadata = self.metadata
    let task = Task.detached(priority: .utility) {
      try await service.ownershipContext(base: listing, metadata: metadata)
    }
    ownership = task
    if cancelled { task.cancel() }
    let context = try await task.value
    guard revision == contextRevision else { return try await self.context() }
    completedContext = context
    prepareDataEvidence(context: context)
    return context
  }

  private func prepareDataEvidence(context: AuthenticApplicationContext) {
    guard dataEvidence == nil, !cancelled else { return }
    let service = related
    dataEvidence = Task.detached(priority: .utility) { await service.prepareDataEvidence(context: context) }
  }

  private func waitForDataEvidence() async -> Bool {
    guard !dataEvidenceUnavailable else { return false }
    guard let evidence = dataEvidence else { return false }
    let revision = contextRevision
    let context = completedContext
    let timeout = evidenceTimeout
    let completion = AsyncStream<Bool>.makeStream()
    let observed = Task {
      await evidence.value
      guard !Task.isCancelled else { return }
      completion.continuation.yield(true)
      completion.continuation.finish()
    }
    let deadline = Task {
      await timeout()
      guard !Task.isCancelled else { return }
      completion.continuation.yield(false)
      completion.continuation.finish()
    }
    defer {
      observed.cancel()
      deadline.cancel()
    }
    var iterator = completion.stream.makeAsyncIterator()
    let completed = await iterator.next() == true
    guard !Task.isCancelled, revision == contextRevision else { return false }
    let finished = completed && context?.observedDataClaims() != nil
    if !finished {
      dataEvidenceUnavailable = true
      evidence.cancel()
    }
    return finished
  }

  private func scopedContext(app: InstalledApplication) async -> AuthenticApplicationContext {
    let listing = await installedListing()
    let metadata = self.metadata
    let source = completedContext
    let service = related
    return await Task.detached(priority: .userInitiated) {
      service.makeStandardContext(app: app, listing: listing, metadata: metadata, dataEvidenceSource: source)
    }.value
  }

  /// New requests get a fresh observation lifetime after removal or restoration.
  /// In-flight size observations can still publish retained rows for their original request.
  public func invalidateCachedObservations() {
    contextRevision = UUID()
    ownership?.cancel()
    listing?.cancel()
    relatedCandidates?.cancel()
    dataEvidence?.cancel()
    ownership = nil
    listing = nil
    relatedCandidates = nil
    dataEvidence = nil
    dataEvidenceUnavailable = false
    completedContext = nil
    metadata = ApplicationContextMetadata()
  }

  /// Includes uncertain, protected and unmatched rows for an honest review
  /// denominator. These observations cannot authorize an action.
  public func observedRelatedCandidates() async -> [RelatedDataCandidate] {
    if let relatedCandidates { return await relatedCandidates.value }
    guard let context = try? await self.context() else { return [] }
    if let relatedCandidates { return await relatedCandidates.value }
    let service = related
    let task = Task.detached(priority: .utility) { await service.discover(context: context) }
    relatedCandidates = task
    if cancelled { task.cancel() }
    return await task.value
  }

  public func relatedReview(
    path: String, requestID: UUID = UUID(), progress: (@Sendable (ApplicationRelatedReview) -> Void)? = nil
  ) async throws -> ApplicationRelatedReview? {
    try Task.checkCancellation()
    guard !cancelled else { throw CancellationError() }
    selectedInitial?.cancel()
    selectedEnrichment?.cancel()
    selectedReviewID = requestID
    let service = related
    // Metadata only: neither package measurement nor owner collection precedes
    // the selected application's first standard-domain observation.
    guard let app = service.application(at: path) else { return nil }
    let activity = self.activity
    let shallowReady = AsyncStream<Void>.makeStream()
    let initial = Task.detached(priority: .userInitiated) { [weak self] in
      let activeSession = self
      defer { shallowReady.continuation.finish() }
      return await service.initialReview(
        for: app,
        listing: {
          if let activeSession { return await activeSession.installedListing() }
          return service.installedListing()
        }
      ) { review in
        if activity.active.withLock({ $0 }), !Task.isCancelled { progress?(review) }
        if review.phase == .shallow {
          shallowReady.continuation.yield(())
          shallowReady.continuation.finish()
        }
      }
    }
    initialReviews.append(initial)
    selectedInitial = initial
    if initialReviews.count > 32 { initialReviews.removeFirst().cancel() }
    let task = Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      var ready = shallowReady.stream.makeAsyncIterator()
      guard await ready.next() != nil, !Task.isCancelled else { return }
      let revision = await self.contextRevision
      let scopedContext = await self.scopedContext(app: app)
      guard !Task.isCancelled, await self.isActive else { return }
      let scoped = await service.review(
        for: app, context: scopedContext, scopedOnly: true, globalEvidencePending: true)
      _ = await initial.value
      guard !Task.isCancelled, await self.isActive else { return }
      progress?(scoped)
      guard let context = try? await self.context() else {
        guard !Task.isCancelled, await self.isActive else { return }
        progress?(
          ApplicationRelatedReview(
            application: app, candidates: scoped.candidates, signerTeamID: scoped.signerTeamID,
            ownershipPending: true, phase: .enriched, openFilesComplete: scoped.openFilesComplete,
            globalEvidenceUnavailable: true))
        return
      }
      let finished = await self.waitForDataEvidence()
      guard !Task.isCancelled, await self.isActive else { return }
      guard await self.contextRevision == revision else { return }
      let enriched = await service.review(
        for: app, context: context, scopedOnly: true, globalEvidenceUnavailable: !finished)
      // Computing evidence is independent of sizing. Publish it last so an
      // older measurement wave cannot replace newer ownership evidence.
      _ = await initial.value
      guard !Task.isCancelled, await self.isActive else { return }
      progress?(enriched)
      await self.publish(
        .related(path: path, candidates: enriched.candidates, ownershipPending: enriched.ownershipPending))
    }
    enrichments.append(task)
    selectedEnrichment = task
    if enrichments.count > 32 { enrichments.removeFirst().cancel() }
    let review = await withTaskCancellationHandler {
      await initial.value
    } onCancel: {
      initial.cancel()
      task.cancel()
    }
    try Task.checkCancellation()
    guard !cancelled else { throw CancellationError() }
    return review
  }

  public func cancelSelectedReview(requestID: UUID) {
    guard selectedReviewID == requestID else { return }
    selectedInitial?.cancel()
    selectedEnrichment?.cancel()
    selectedReviewID = nil
  }

  /// A native drop/navigation report uses this session's cheap listing and
  /// one background ownership context. The existing full report API remains
  /// available to callers that explicitly await all ownership evidence.
  public func initialReport(path: String) async throws -> ApplicationReport? {
    try Task.checkCancellation()
    guard !cancelled, related.scopeExclusion(at: path) == nil else { return nil }
    guard let app = related.application(at: path) else {
      return await ApplicationDiscovery(related: related).report(path: path)
    }
    let physical = app.linkTarget ?? path
    guard related.scopeExclusion(at: physical) == nil else { return nil }
    let updates = AsyncStream<ApplicationRelatedReview>.makeStream()
    let work = Task { [weak self] in
      defer { updates.continuation.finish() }
      guard let self else { return }
      _ = try? await self.relatedReview(path: path) { updates.continuation.yield($0) }
    }
    enrichments.append(work)
    if enrichments.count > 32 { enrichments.removeFirst().cancel() }
    var iterator = updates.stream.makeAsyncIterator()
    var observed: ApplicationRelatedReview?
    while let update = await iterator.next() {
      if update.phase != .shallow {
        observed = update
        break
      }
    }
    guard let observed, !cancelled else { return nil }
    let unknown = ByteAggregate(knownLowerBound: 0, completeTotal: nil)
    var report = ApplicationReport(
      path: path, bundleID: app.bundleID, version: app.version, signerTeamID: observed.signerTeamID,
      logical: unknown, allocated: unknown, knownItemCount: 1, partial: true,
      related: observed.candidates, manualUninstallerSuggested: false, linkTarget: app.linkTarget,
      displayRootIdentity: try? DescriptorFileSystem.identity(at: physical))
    report.isIOSWrapper = (try? DescriptorFileSystem.identity(at: physical + "/Wrapper"))?.kind == .directory
    return report
  }

  public func makeAvailableUninstallPlan(
    app: InstalledApplication, selectedRelated: [RelatedDataCandidate], includePackage: Bool = true,
    selectedUnprovenRelated: [RelatedDataCandidate] = []
  ) async -> RelatedDataService.AvailableUninstallPlan {
    await makeAvailableUninstallPlan(
      path: app.path, expectedBundleID: app.bundleID, selectedRelated: selectedRelated,
      includePackage: includePackage, selectedUnprovenRelated: selectedUnprovenRelated)
  }

  public func makeAvailableUninstallPlan(
    path: String, expectedBundleID: String?, selectedRelated: [RelatedDataCandidate],
    includePackage: Bool = true, selectedUnprovenRelated: [RelatedDataCandidate] = []
  ) async -> RelatedDataService.AvailableUninstallPlan {
    guard !cancelled, !Task.isCancelled else {
      return .init(
        plan: nil, rejections: [PlanRejection(.unavailable, path: path, ruleID: "cancelled")])
    }
    let context: AuthenticApplicationContext?
    if (selectedRelated.isEmpty && selectedUnprovenRelated.isEmpty) || expectedBundleID == nil {
      context = nil
    } else if let observed = related.application(at: path),
      let app = related.application(at: observed.linkTarget ?? observed.path),
      related.isExactStandardSelection(app: app, candidates: selectedRelated)
    {
      let listing = await installedListing()
      let evidenceSource: AuthenticApplicationContext?
      if let ownership { evidenceSource = try? await ownership.value } else { evidenceSource = nil }
      let service = related
      let metadata = self.metadata
      context = await Task.detached(priority: .userInitiated) {
        service.makeStandardContext(
          app: app, listing: listing, metadata: metadata, dataEvidenceSource: evidenceSource)
      }.value
    } else {
      do { context = try await self.context() } catch {
        return .init(plan: nil, rejections: [PlanRejection(.unavailable, path: path, ruleID: "cancelled")])
      }
    }
    guard !cancelled, !Task.isCancelled else {
      return .init(
        plan: nil, rejections: [PlanRejection(.unavailable, path: path, ruleID: "cancelled")])
    }
    return await related.makeAvailableUninstallPlan(
      path: path, expectedBundleID: expectedBundleID, selectedRelated: selectedRelated,
      includePackage: includePackage, selectedUnprovenRelated: selectedUnprovenRelated, context: context)
  }

  /// Fresh read-only refusals for one concrete plan. Private ownership
  /// preparation and Guard envelopes never escape the service.
  public func validatePlan(_ plan: ActionPlan) async -> [PlanRejection] {
    guard !cancelled, !Task.isCancelled else {
      return plan.items.map { PlanRejection(.unavailable, path: $0.sourcePath, ruleID: "cancelled") }
    }
    return await related.validatePlan(plan)
  }

  public func ownershipRefusalEvidence(for plan: ActionPlan) async -> [RelatedOwnershipRefusalEvidence] {
    guard !cancelled, !Task.isCancelled else { return [] }
    let service = related
    let evidence = await service.asyncOwnershipRefusalEvidence(for: plan)
    return cancelled || Task.isCancelled ? [] : evidence
  }

  /// A leftover still needs current owner absence and, when present, a
  /// freshly validated receipt. Review observations do not grant authority.
  public func plan(candidate: RelatedDataCandidate) async -> RelatedDataService.AvailableUninstallPlan {
    guard !cancelled, !Task.isCancelled else {
      return .init(plan: nil, rejections: [PlanRejection(.unavailable, path: candidate.path, ruleID: "cancelled")])
    }
    let context: AuthenticApplicationContext
    do { context = try await self.context() } catch {
      return .init(plan: nil, rejections: [PlanRejection(.unavailable, path: candidate.path, ruleID: "cancelled")])
    }
    guard !cancelled, !Task.isCancelled else {
      return .init(plan: nil, rejections: [PlanRejection(.unavailable, path: candidate.path, ruleID: "cancelled")])
    }
    return await related.availableOrphanPlan(candidate: candidate, context: context)
  }

  public func cancel() async {
    cancelled = true
    pendingMeasurements.removeAll()
    activity.active.withLock { $0 = false }
    worker?.cancel()
    ownership?.cancel()
    dataEvidence?.cancel()
    listing?.cancel()
    displayListingTask?.cancel()
    relatedCandidates?.cancel()
    for task in initialReviews { task.cancel() }
    initialReviews.removeAll()
    for task in enrichments { task.cancel() }
    let pending = enrichments
    enrichments.removeAll()
    continuation?.finish()
    continuation = nil
    await worker?.value
    _ = try? await ownership?.value
    _ = await listing?.value
    _ = await displayListingTask?.value
    _ = await relatedCandidates?.value
    for task in pending { await task.value }
  }

  private func finishStream() { continuation = nil }

  private var isActive: Bool { !cancelled }
  private func publish(_ event: ApplicationDiscovery.Event) {
    if !cancelled { continuation?.yield(event) }
  }
}
