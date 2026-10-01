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

/// Only the service can mint this context. Public inventories and review DTOs
/// are observations and are never accepted as ownership authority.
final class AuthenticApplicationContext: Sendable {
  let scope: ApplicationContextScope
  let inventory: BundleInventory
  let lineage: [ApplicationPathObservation]
  let registeredPaths: [String]
  let standardBundleID: String?
  private let signers = Mutex<[String: ApplicationSignatureCache.Observation]>([:])

  init(
    scope: ApplicationContextScope, inventory: BundleInventory, lineage: [ApplicationPathObservation],
    registeredPaths: [String], standardBundleID: String? = nil
  ) {
    self.scope = scope
    self.inventory = inventory
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
}

/// Native service values share concrete plan bindings. Injected services each
/// receive a separate registry; copying a service preserves its lineage.
final class ApplicationPlanContexts: Sendable {
  static let native = ApplicationPlanContexts()
  private struct Binding: Sendable {
    let plan: ActionPlan
    let context: AuthenticApplicationContext
  }
  private let bindings = Mutex<[Binding]>([])

  func bind(_ plan: ActionPlan, context: AuthenticApplicationContext) {
    bindings.withLock { entries in
      entries.removeAll { $0.plan.id == plan.id }
      entries.append(Binding(plan: plan, context: context))
      // A very large observation remains usable by its session, but a later
      // execution must freshly validate it instead of retaining unbounded state.
      if context.lineage.count > 100_000 { entries.removeAll { $0.plan.id == plan.id } }
      func retainedPaths() -> Int {
        var seen: Set<ObjectIdentifier> = []
        return entries.reduce(0) { total, entry in
          total + (seen.insert(ObjectIdentifier(entry.context)).inserted ? entry.context.lineage.count : 0)
        }
      }
      while entries.count > 64 || retainedPaths() > 250_000 { entries.removeFirst() }
    }
  }

  func context(for plan: ActionPlan, scope: ApplicationContextScope) -> AuthenticApplicationContext? {
    bindings.withLock { entries in
      entries.first { $0.plan == plan && $0.context.scope == scope }?.context
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
    let task = Task.detached(priority: .utility) { service.makeContext(base: listing) }
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
      context = await Task.detached(priority: .userInitiated) {
        service.makeStandardContext(app: app, listing: listing)
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
