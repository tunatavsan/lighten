import Darwin
import Foundation
import Synchronization

public struct ApplicationRelatedReview: Sendable {
  public let application: InstalledApplication
  public let candidates: [RelatedDataCandidate]
  public let signerTeamID: String?
  public let ownershipPending: Bool

  public init(
    application: InstalledApplication, candidates: [RelatedDataCandidate], signerTeamID: String? = nil,
    ownershipPending: Bool = true
  ) {
    self.application = application
    self.candidates = candidates
    self.signerTeamID = signerTeamID
    self.ownershipPending = ownershipPending
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

  func validate() throws {
    let current: FileIdentity?
    do { current = try DescriptorFileSystem.identity(at: path) } catch FileSystemFailure.systemCall(_, let code)
      where code == ENOENT || code == ENOTDIR
    { current = nil } catch { throw RelatedFailure.changedItem }
    guard current == identity else { throw RelatedFailure.changedItem }
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
    let info = RelatedDataService.infoPlistPath(ofBundleAt: physical)
    do {
      observations.append(ApplicationPathObservation(path: info, identity: try DescriptorFileSystem.identity(at: info)))
    } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
      throw ApplicationMetadataFailure.missingInfoPlist
    }
    return observations
  }

  func application(at path: String, registered: Bool, read: () throws -> InstalledApplication?) throws
    -> InstalledApplication?
  {
    let key = Key(path: path, registered: registered)
    let current = try identities(at: path)
    if let cached = entries.withLock({ $0[key] }),
      cached.identities.count == current.count,
      zip(cached.identities, current).allSatisfy({ pair in
        pair.0.path == pair.1.path && pair.0.identity == pair.1.identity
      })
    {
      return cached.application
    }
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

  init(
    scope: ApplicationContextScope, inventory: BundleInventory, lineage: [ApplicationPathObservation],
    registeredPaths: [String], standardBundleID: String? = nil,
    installedListing: BundleInventory? = nil, metadata: ApplicationContextMetadata? = nil
  ) {
    self.scope = scope
    self.inventory = inventory
    self.installedListing = installedListing ?? inventory
    self.metadata = metadata ?? ApplicationContextMetadata()
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
    if let observation = signers.withLock({ $0[path] }) { return observation }
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

  func bind(_ plan: ActionPlan, context: AuthenticApplicationContext) {
    bind(plan, contexts: Dictionary(plan.items.map { ($0.id, context) }, uniquingKeysWith: { first, _ in first }))
  }

  func bind(_ plan: ActionPlan, contexts: [UUID: AuthenticApplicationContext]) {
    bindings.withLock { entries in
      entries.removeAll { $0.plan.id == plan.id }
      let selected = contexts.filter { entry in plan.items.contains { $0.id == entry.key } }
      entries.append(Binding(plan: plan, contexts: selected))
      // A very large observation remains usable by its session, but a later
      // execution must freshly validate it instead of retaining unbounded state.
      if selected.values.contains(where: { $0.lineage.count > 100_000 }) {
        entries.removeAll { $0.plan.id == plan.id }
      }
      func retainedPaths() -> Int {
        var seen: Set<ObjectIdentifier> = []
        return entries.reduce(0) { total, entry in
          total
            + entry.contexts.values.reduce(0) { count, context in
              count + (seen.insert(ObjectIdentifier(context)).inserted ? context.lineage.count : 0)
            }
        }
      }
      while entries.count > 64 || retainedPaths() > 250_000 { entries.removeFirst() }
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
  private let metadata = ApplicationContextMetadata()
  private var ownership: Task<AuthenticApplicationContext, Never>?
  private var listing: Task<BundleInventory, Never>?
  private var worker: Task<Void, Never>?
  private var relatedCandidates: Task<[RelatedDataCandidate], Never>?
  private var enrichments: [Task<Void, Never>] = []
  private var continuation: AsyncStream<ApplicationDiscovery.Event>.Continuation?
  private let activity = ApplicationSessionActivity()
  private var cancelled = false
  private var streamed = false

  init(related: RelatedDataService, uptime: @escaping @Sendable () -> TimeInterval) {
    self.related = related
    self.uptime = uptime
  }

  public func events() -> AsyncStream<ApplicationDiscovery.Event> {
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
      await ApplicationDiscovery.run(session: self, related: service, uptime: clock) { event in
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

  func installedListing() async -> BundleInventory {
    if let listing { return await listing.value }
    let service = related
    let task = Task.detached(priority: .utility) { service.installedListing() }
    listing = task
    if cancelled { task.cancel() }
    return await task.value
  }

  func context(base: BundleInventory? = nil) async -> AuthenticApplicationContext {
    if let ownership { return await ownership.value }
    let listing: BundleInventory
    if let base { listing = base } else { listing = await installedListing() }
    if let ownership { return await ownership.value }
    let service = related
    let metadata = self.metadata
    let task = Task.detached(priority: .utility) { service.makeContext(base: listing, metadata: metadata) }
    ownership = task
    if cancelled { task.cancel() }
    return await task.value
  }

  /// Includes uncertain, protected and unmatched rows for an honest review
  /// denominator. These observations cannot authorize an action.
  public func observedRelatedCandidates() async -> [RelatedDataCandidate] {
    if let relatedCandidates { return await relatedCandidates.value }
    let context = await self.context()
    if let relatedCandidates { return await relatedCandidates.value }
    let service = related
    let task = Task.detached(priority: .utility) { await service.discover(context: context) }
    relatedCandidates = task
    if cancelled { task.cancel() }
    return await task.value
  }

  public func relatedReview(
    path: String, progress: (@Sendable (ApplicationRelatedReview) -> Void)? = nil
  ) async throws -> ApplicationRelatedReview? {
    try Task.checkCancellation()
    guard !cancelled else { throw CancellationError() }
    let service = related
    // Metadata only: neither package measurement nor owner collection precedes
    // the selected application's first standard-domain observation.
    guard let app = service.application(at: path) else { return nil }
    let activity = self.activity
    let review = await service.initialReview(for: app) { review in
      if activity.active.withLock({ $0 }), !Task.isCancelled { progress?(review) }
    }
    try Task.checkCancellation()
    guard !cancelled else { throw CancellationError() }
    let task = Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      let context = await self.context()
      guard !Task.isCancelled, await self.isActive else { return }
      let enriched = await service.review(for: app, context: context)
      guard !Task.isCancelled, await self.isActive else { return }
      progress?(enriched)
      await self.publish(
        .related(path: path, candidates: enriched.candidates, ownershipPending: enriched.ownershipPending))
    }
    enrichments.append(task)
    if enrichments.count > 32 { enrichments.removeFirst().cancel() }
    return review
  }

  public func makeAvailableUninstallPlan(
    app: InstalledApplication, selectedRelated: [RelatedDataCandidate], includePackage: Bool = true
  ) async -> RelatedDataService.AvailableUninstallPlan {
    guard !cancelled, !Task.isCancelled else {
      return .init(plan: nil, rejections: [PlanRejection(.unavailable, path: app.path, ruleID: "cancelled")])
    }
    let context: AuthenticApplicationContext?
    if selectedRelated.isEmpty {
      context = nil
    } else if related.isExactStandardSelection(app: app, candidates: selectedRelated) {
      let listing = await installedListing()
      let service = related
      let metadata = self.metadata
      context = await Task.detached(priority: .userInitiated) {
        service.makeStandardContext(app: app, listing: listing, metadata: metadata)
      }.value
    } else {
      context = await self.context()
    }
    guard !cancelled, !Task.isCancelled else {
      return .init(plan: nil, rejections: [PlanRejection(.unavailable, path: app.path, ruleID: "cancelled")])
    }
    return await related.makeAvailableUninstallPlan(
      app: app, selectedRelated: selectedRelated, includePackage: includePackage, context: context)
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
    let evidence = await Task.detached(priority: .userInitiated) {
      service.ownershipRefusalEvidence(for: plan)
    }.value
    return cancelled || Task.isCancelled ? [] : evidence
  }

  /// A leftover still needs current owner absence and, when present, a
  /// freshly validated receipt. Review observations do not grant authority.
  public func plan(candidate: RelatedDataCandidate) async -> RelatedDataService.AvailableUninstallPlan {
    guard !cancelled, !Task.isCancelled else {
      return .init(plan: nil, rejections: [PlanRejection(.unavailable, path: candidate.path, ruleID: "cancelled")])
    }
    let context = await self.context()
    guard !cancelled, !Task.isCancelled else {
      return .init(plan: nil, rejections: [PlanRejection(.unavailable, path: candidate.path, ruleID: "cancelled")])
    }
    return await related.availableOrphanPlan(candidate: candidate, context: context)
  }

  public func cancel() async {
    cancelled = true
    activity.active.withLock { $0 = false }
    worker?.cancel()
    ownership?.cancel()
    listing?.cancel()
    relatedCandidates?.cancel()
    for task in enrichments { task.cancel() }
    let pending = enrichments
    enrichments.removeAll()
    continuation?.finish()
    continuation = nil
    await worker?.value
    _ = await ownership?.value
    _ = await listing?.value
    _ = await relatedCandidates?.value
    for task in pending { await task.value }
  }

  private func finishStream() { continuation = nil }

  private var isActive: Bool { !cancelled }
  private func publish(_ event: ApplicationDiscovery.Event) {
    if !cancelled { continuation?.yield(event) }
  }
}
