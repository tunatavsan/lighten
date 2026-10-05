import Foundation
import LightenKit
import OSLog
import Observation
import Synchronization

struct CleanCandidate: Identifiable, Sendable {
  let id: UUID
  let row: CatalogRow
  let snapshot: ScanSnapshot
  let entry: ScanEntry
  let node: ScanNode
  let activity: ProcessActivityState
  let allowed: Bool
  let exactLogicalBytes: Int64?
  let refusal: String?
  let requiresFullDiskAccess: Bool
  let processNames: [String]
  var displayLogicalBytes: Int64? = nil
  var displaySizeComplete: Bool? = nil

  var logicalBytes: Int64 { displayLogicalBytes ?? exactLogicalBytes ?? node.logical.knownLowerBound }
  var sizeComplete: Bool { displaySizeComplete ?? (exactLogicalBytes != nil || node.logical.completeTotal != nil) }

  var canAct: Bool {
    guard allowed, activity == .clearObservedCurrentUID, let identity = entry.identity,
      identity.kind != .other, identity.birthSeconds != nil, identity.birthNanoseconds != nil,
      identity.modificationSeconds != nil, identity.modificationNanoseconds != nil,
      identity.device == snapshot.volumeDevice, snapshot.volumeID != nil
    else { return false }
    return true
  }
}

/// Counts only observations published by completed discovery snapshots.
struct CleanScanDisplayProgress {
  private var paths: Set<String> = []
  private var measuredPaths: Set<String> = []
  private(set) var count = 0
  private(set) var bytes: Int64?
  private(set) var unreadablePaths: Set<String> = []

  mutating func include(_ snapshot: ScanSnapshot) {
    for entry in snapshot.entries {
      paths.insert(entry.path)
      if !entry.readable || entry.issues.contains(.unreadable) { unreadablePaths.insert(entry.path) }
      if let identity = entry.identity, identity.kind == .regular,
        measuredPaths.insert(entry.path).inserted
      {
        bytes = (bytes ?? 0) + max(0, identity.logicalBytes)
      }
    }
    count = paths.count
  }
}

enum CleanRowStatus: Sendable {
  case toolRunning, processUnknown, empty, clear, unavailable
}

@MainActor @Observable
final class CleanStore: ToolSummaryProviding {
  typealias Scanner = @Sendable (String, String) async throws -> ScanSnapshot
  typealias PlanBuilder = @Sendable (CleanCatalog, [CatalogSelection], ActionKind) async throws -> ActionPlan
  typealias AvailablePlanBuilder =
    @Sendable (CleanCatalog, [CatalogSelection], ActionKind) async throws -> CatalogPlanOutcome

  @ObservationIgnored private let userPlanner: PlanService
  @ObservationIgnored private let preferences: RemovalPreferences
  @ObservationIgnored private let usesInjectedPlanner: Bool
  @ObservationIgnored private let activity: any ProcessActivitySource
  @ObservationIgnored private let catalog: CleanCatalog?
  @ObservationIgnored private let catalogFailure: (any Error)?
  @ObservationIgnored let homeDirectory: String
  @ObservationIgnored private let scanner: Scanner?
  @ObservationIgnored private let discoverRelated: @Sendable () async -> [RelatedDataCandidate]
  @ObservationIgnored private let availablePlanBuilder: AvailablePlanBuilder
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var scanGeneration = UUID()
  @ObservationIgnored private var relatedTask: Task<Void, Never>?
  @ObservationIgnored private var relatedGeneration: UUID?
  @ObservationIgnored private var preparationTask: Task<ActionPlan, Error>?
  @ObservationIgnored private var availablePreparationTask: Task<CatalogPlanOutcome, Error>?
  @ObservationIgnored private var observedPlanID: UUID?
  @ObservationIgnored private var removedCandidates: [UUID: [CleanCandidate]] = [:]
  @ObservationIgnored private var removedRelated: [UUID: [RelatedDataCandidate]] = [:]
  @ObservationIgnored private var displayChanges: [UUID: ActionDisplayItem] = [:]
  @ObservationIgnored private let loadPicture: @Sendable () -> ResultPicture<CleanPicture>?
  @ObservationIgnored private let savePicture: @Sendable (ResultPicture<CleanPicture>) throws -> Void
  @ObservationIgnored private let pictureQueue = DispatchQueue(label: "com.tavsn.lighten.clean-pictures", qos: .utility)
  @ObservationIgnored private let pictureWriteGeneration = CleanPictureWriteGeneration()
  @ObservationIgnored private var pictureTask: Task<Void, Never>?
  @ObservationIgnored private var opened = false
  @ObservationIgnored private var openingRequestedAt: ContinuousClock.Instant?
  @ObservationIgnored private var pictureDrawn = false
  @ObservationIgnored private let openingLogger = Logger(subsystem: "com.tavsn.lighten", category: "clean-opening")
  @ObservationIgnored private var pictureBeforeDisplayChanges: ResultPicture<CleanPicture>?
  private(set) var displayRevision = 0
  let tool = ToolStore()
  var candidates: [CleanCandidate] = []
  var relatedCandidates: [RelatedDataCandidate] = []
  private(set) var discoveringRelated = false
  private(set) var scanProgress = CleanScanDisplayProgress()
  var rowStatuses: [String: CleanRowStatus] = [:]
  var selected: Set<UUID> = []
  var mode: ActionKind = .trash
  var scannedAt: Date?
  var presentedPlanID: UUID?
  var message: String?
  private(set) var picture: ResultPicture<CleanPicture>?

  init(
    activity: any ProcessActivitySource = MacOSProcessActivitySource(),
    homeDirectory: String = NSHomeDirectory(),
    pictures: ResultPictureStore = ResultPictureStore(),
    loadPicture: (@Sendable () -> ResultPicture<CleanPicture>?)? = nil,
    savePicture: (@Sendable (ResultPicture<CleanPicture>) throws -> Void)? = nil,
    catalogLoader: @Sendable (String) throws -> CleanCatalog = { try CleanCatalog(homeDirectory: $0) },
    scanner: Scanner? = nil,
    discoverRelated: @escaping @Sendable () async -> [RelatedDataCandidate] = {
      await RelatedDataService.system.discover()
    },
    planBuilder: PlanBuilder? = nil,
    availablePlanBuilder: AvailablePlanBuilder? = nil,
    preferences: RemovalPreferences = .shared, userPlanner: PlanService? = nil
  ) {
    self.loadPicture = loadPicture ?? { pictures.load(CleanPicture.self, named: "clean") }
    self.savePicture = savePicture ?? { try pictures.save($0, named: "clean") }
    self.preferences = preferences
    self.userPlanner = userPlanner ?? PlanService(homeDirectory: homeDirectory)
    usesInjectedPlanner = availablePlanBuilder != nil || planBuilder != nil
    self.activity = activity
    self.homeDirectory = homeDirectory
    do {
      self.catalog = try catalogLoader(homeDirectory)
      self.catalogFailure = nil
    } catch {
      self.catalog = nil
      self.catalogFailure = error
    }
    self.scanner = scanner
    self.discoverRelated = discoverRelated
    self.availablePlanBuilder =
      availablePlanBuilder ?? { catalog, selections, kind in
        if let planBuilder {
          return CatalogPlanOutcome(plan: try await planBuilder(catalog, selections, kind), rejections: [])
        }
        return await Task.detached(priority: .userInitiated) {
          catalog.planAvailable(selections: selections, kind: kind)
        }.value
      }
    pictureWriteGeneration.replace(with: scanGeneration)
  }

  var rows: [CatalogRow] { catalog?.rows ?? [] }
  var phase: ToolPhase { tool.preparation.preparing ? .preparing : tool.phase }
  var busy: Bool { phase == .scanning || tool.preparation.preparing }
  var partial: Bool { phase == .partial }
  var actionableCandidates: [CleanCandidate] { candidates.filter(\.canAct) }
  var toolSummary: ToolSummary {
    if let picture {
      return ToolSummary(
        count: picture.content.rows.count + picture.content.relatedRows.count,
        logicalBytes: picture.content.rows.reduce(0) { $0 + $1.logicalBytes }
          + picture.content.relatedRows.reduce(0) { $0 + ($1.logicalBytes ?? 0) },
        observedAt: picture.observedAt, partial: picture.content.partial)
    }
    return ToolSummary(
      count: actionableCandidates.count,
      logicalBytes: actionableCandidates.reduce(0) { $0 + $1.logicalBytes },
      observedAt: scannedAt, partial: partial)
  }
  var selectedLogicalBytes: Int64 {
    candidates.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.logicalBytes }
  }

  func open(refresh: Bool = true) {
    guard !opened else { return }
    opened = true
    guard tool.phase == .idle, scannedAt == nil else { return }
    let requestedAt = ContinuousClock.now
    if refresh { startScan() }
    let generation = scanGeneration
    openingRequestedAt = requestedAt
    let queue = pictureQueue
    let load = loadPicture
    pictureTask = Task(priority: .utility) { @concurrent [weak self] in
      let cached: ResultPicture<CleanPicture>? = await withCheckedContinuation { continuation in
        queue.async { continuation.resume(returning: load()) }
      }
      guard !Task.isCancelled else { return }
      await self?.publishPicture(cached, generation: generation, requestedAt: requestedAt)
    }
  }

  private func publishPicture(
    _ cached: ResultPicture<CleanPicture>?, generation: UUID, requestedAt: ContinuousClock.Instant
  ) {
    guard scanGeneration == generation, scannedAt == nil, candidates.isEmpty else { return }
    picture = cached
    pictureBeforeDisplayChanges = nil
    guard let cached else { return }
    let elapsed = Self.milliseconds(requestedAt.duration(to: .now))
    let count = cached.content.rows.count + cached.content.relatedRows.count
    openingLogger.info(
      "Clean picture published milliseconds=\(elapsed, privacy: .public) rows=\(count, privacy: .public)")
  }

  func pictureDidDraw() {
    guard picture != nil, !pictureDrawn, let requestedAt = openingRequestedAt else { return }
    pictureDrawn = true
    let elapsed = Self.milliseconds(requestedAt.duration(to: .now))
    openingLogger.info("Clean picture drawn milliseconds=\(elapsed, privacy: .public)")
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1_000_000_000_000_000
  }

  func waitForPicture() async { await pictureTask?.value }

  func waitForPictureSaves() async {
    let queue = pictureQueue
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  }

  private func persistPicture() {
    let snapshot: ResultPicture<CleanPicture>
    if let picture {
      snapshot = picture
    } else {
      guard tool.phase == .ready, let scannedAt else { return }
      snapshot = ResultPicture(
        observedAt: scannedAt,
        content: CleanPicture(
          rows: candidates.map {
            CleanPicture.Row(
              path: $0.entry.path, categoryID: $0.row.id,
              logicalBytes: $0.logicalBytes, sizeComplete: $0.sizeComplete, detail: $0.refusal)
          },
          relatedRows: relatedCandidates.map {
            CleanPicture.RelatedRow(
              path: $0.path, logicalBytes: $0.observation?.logical.knownLowerBound,
              detail: String(localized: "Previous result. Scan again before cleaning."))
          },
          partial: candidates.contains { !$0.sizeComplete } || rowStatuses.values.contains { $0 == .unavailable }))
    }
    let token = scanGeneration
    let state = pictureWriteGeneration
    let save = savePicture
    // Enqueue on the main actor so disk writes retain publication order.
    pictureQueue.async {
      guard state.accepts(token) else { return }
      try? save(snapshot)
    }
  }

  func refresh() { startScan() }

  func startScan(actions: ActionStore? = nil) {
    guard phase != .scanning else { return }
    expirePreparation(actions: actions)
    cancelRelatedDiscovery()
    let generation = UUID()
    scanGeneration = generation
    pictureWriteGeneration.replace(with: generation)
    pictureTask?.cancel()
    tool.phase = .scanning
    candidates = []
    relatedCandidates = []
    scanProgress = CleanScanDisplayProgress()
    selected = []
    scannedAt = nil
    rowStatuses = [:]
    message = nil
    scanTask = Task { await scan(generation: generation) }
  }

  func waitForScan() async { await scanTask?.value }

  func waitForRelatedDiscovery() async { await relatedTask?.value }

  func cancelScan(actions: ActionStore? = nil) {
    guard phase == .scanning else { return }
    scanGeneration = UUID()
    pictureWriteGeneration.replace(with: scanGeneration)
    pictureTask?.cancel()
    scanTask?.cancel()
    scanTask = nil
    cancelRelatedDiscovery()
    expirePreparation(actions: actions)
    tool.phase = .partial
    selected = []
    scannedAt = Date()
    message = String(localized: "Partial scan. Scan again before cleaning.")
  }

  private func scan(generation: UUID) async {
    guard let catalog else {
      if scanGeneration == generation {
        tool.phase = .failed
        message =
          catalogFailure.map { FailureText.describe($0) }
          ?? String(localized: "Clean catalog unavailable. Reinstall the app.")
        scanTask = nil
      }
      return
    }
    for row in catalog.rows {
      if Task.isCancelled || scanGeneration != generation { return }
      let childScoped = row.relativeRoot == "Library/Caches" || row.relativeRoot == "Library/Logs"
      let rowActivity =
        childScoped
        ? ProcessActivity(state: .clearObservedCurrentUID)
        : await activity.activity(for: row, rootPath: catalog.root(for: row))
      let activityState = rowActivity.state
      if Task.isCancelled || scanGeneration != generation { return }
      do {
        let discovered: CatalogDiscovery
        if let scanner {
          let snapshot = try await scanner(catalog.root(for: row), homeDirectory)
          discovered = try await Task.detached(priority: .utility) {
            try catalog.discovery(snapshot: snapshot, rowID: row.id)
          }.value
        } else {
          discovered = try await catalog.discover(rowID: row.id)
        }
        if Task.isCancelled || scanGeneration != generation { return }
        let snapshot = discovered.snapshot
        scanProgress.include(snapshot)
        for observed in discovered.candidates {
          let entry = observed.entry
          let node = observed.node
          let candidateActivity =
            childScoped
            ? await activity.activity(for: row, rootPath: catalog.activityRoot(for: row, candidatePath: entry.path))
            : rowActivity
          if Task.isCancelled || scanGeneration != generation { return }
          let rejection = observed.rejection
          var allowed = rejection == nil
          var exactLogical: Int64?
          var refusal = rejection.map(SpaceText.rejection)
          var requiresFullDiskAccess = false
          if allowed && candidateActivity.state == .clearObservedCurrentUID
            && (node.partial || node.protected || !entry.issues.isEmpty)
          {
            do {
              let plan = try await Task.detached(priority: .utility) {
                try catalog.plan(snapshot: snapshot, selectedIDs: [entry.id], rowID: row.id, kind: .trash)
              }.value
              if !plan.items.contains(where: { $0.containsOpaquePackages }) {
                exactLogical = plan.items.reduce(Int64(0)) { $0 + PlanItemSize.measure($1).0 }
              }
            } catch {
              allowed = false
              requiresFullDiskAccess =
                (error as? PlanRejections)?.rejections.contains { $0.reason == .unreadableFolder } == true
              refusal =
                (error as? PlanRejections).map {
                  $0.rejections.map(SpaceText.rejection).joined(separator: "\n")
                }
                ?? (error as? PlanRejection).map(SpaceText.rejection)
                ?? FailureText.describe(error)
            }
            if Task.isCancelled || scanGeneration != generation { return }
          }
          candidates.append(
            CleanCandidate(
              id: entry.id, row: row, snapshot: snapshot, entry: entry, node: node,
              activity: candidateActivity.state, allowed: allowed, exactLogicalBytes: exactLogical,
              refusal: refusal, requiresFullDiskAccess: requiresFullDiskAccess,
              processNames: candidateActivity.processNames))
        }
        rowStatuses[row.id] =
          activityState == .active
          ? .toolRunning
          : activityState == .unknown ? .processUnknown : discovered.candidates.isEmpty ? .empty : .clear
      } catch {
        if Task.isCancelled || scanGeneration != generation { return }
        rowStatuses[row.id] = .unavailable
      }
    }
    if Task.isCancelled || scanGeneration != generation { return }
    picture = nil
    pictureBeforeDisplayChanges = nil
    scannedAt = Date()
    tool.phase = .ready
    selected = Set(actionableCandidates.filter { $0.row.defaultSelected }.map(\.id))
    scanTask = nil
    persistPicture()
    startRelatedDiscovery(scan: generation)
  }

  private func startRelatedDiscovery(scan: UUID) {
    let token = UUID()
    relatedGeneration = token
    discoveringRelated = true
    let discover = discoverRelated
    relatedTask = Task(priority: .utility) { @concurrent [weak self] in
      let related = await discover()
      guard !Task.isCancelled else { return }
      await self?.finishRelatedDiscovery(related, scan: scan, token: token)
    }
  }

  private func finishRelatedDiscovery(_ related: [RelatedDataCandidate], scan: UUID, token: UUID) {
    guard scanGeneration == scan, relatedGeneration == token else { return }
    relatedCandidates = related.filter { $0.classification != .installed }
    discoveringRelated = false
    relatedGeneration = nil
    relatedTask = nil
    persistPicture()
  }

  private func cancelRelatedDiscovery() {
    relatedGeneration = nil
    relatedTask?.cancel()
    relatedTask = nil
    discoveringRelated = false
  }

  func toggleCategory(_ rowID: String, actions: ActionStore) {
    guard picture == nil, tool.phase == .ready, !actions.busy else { return }
    let ids = Set(candidates.filter { $0.row.id == rowID }.map(\.id))
    expirePreparation(actions: actions)
    if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
  }

  func selectAll(actions: ActionStore) {
    guard picture == nil, tool.phase == .ready, !actions.busy else { return }
    expirePreparation(actions: actions)
    let ids = Set(candidates.map(\.id))
    selected = selected == ids ? [] : ids
  }

  func deactivate(actions: ActionStore) {
    cancelRelatedDiscovery()
    observeResult(actions: actions)
    let executing = actions.busy && actions.pending?.id != presentedPlanID
    expirePreparation(actions: actions, keepPresentedPlanID: executing)
  }

  private func expirePreparation(actions: ActionStore? = nil, keepPresentedPlanID: Bool = false) {
    tool.preparation.invalidatePreparation()
    preparationTask?.cancel()
    preparationTask = nil
    availablePreparationTask?.cancel()
    availablePreparationTask = nil
    if let presentedPlanID, actions?.pending?.id == presentedPlanID { actions?.pending = nil }
    if !keepPresentedPlanID { presentedPlanID = nil }
    message = nil
  }

  func applyDisplayChange(_ change: ActionDisplayChange) {
    if picture != nil, pictureBeforeDisplayChanges == nil { pictureBeforeDisplayChanges = picture }
    for item in change.items {
      switch change.kind {
      case .applied:
        displayChanges[item.itemID] = item
        let removed = candidates.filter { candidate in
          item.matches(path: candidate.entry.path, identity: candidate.entry.identity)
            || candidate.entry.path.hasPrefix(item.path + "/")
              && candidate.snapshot.entries.contains { item.matches(path: $0.path, identity: $0.identity) }
        }
        removedCandidates[item.itemID] = removed
        candidates.removeAll { candidate in removed.contains { $0.id == candidate.id } }
        let related = relatedCandidates.filter { candidate in
          candidate.snapshot?.entries.contains { item.matches(path: $0.path, identity: $0.identity) } == true
            && (candidate.path == item.path || candidate.path.hasPrefix(item.path + "/"))
        }
        removedRelated[item.itemID] = related
        relatedCandidates.removeAll { candidate in related.contains { $0.path == candidate.path } }
        selected.subtract(removed.map(\.id))
      case .restored:
        displayChanges.removeValue(forKey: item.itemID)
        for candidate in removedCandidates.removeValue(forKey: item.itemID) ?? [] {
          if !candidates.contains(where: { $0.id == candidate.id || $0.entry.path == candidate.entry.path }) {
            candidates.append(candidate)
          }
        }
        for candidate in removedRelated.removeValue(forKey: item.itemID) ?? [] {
          if !relatedCandidates.contains(where: { $0.path == candidate.path }) { relatedCandidates.append(candidate) }
        }
      }
    }
    candidates = candidates.map { candidate in
      var updated = candidate
      var bytes = candidate.exactLogicalBytes ?? candidate.node.logical.knownLowerBound
      var complete = candidate.exactLogicalBytes != nil || candidate.node.logical.completeTotal != nil
      let removed = displayChanges.values.filter { item in
        item.path.hasPrefix(candidate.entry.path + "/")
          && candidate.snapshot.entries.contains { item.matches(path: $0.path, identity: $0.identity) }
      }
      for item in removed where !removed.contains(where: { item.path.hasPrefix($0.path + "/") }) {
        if let amount = item.size.logical {
          bytes = max(0, bytes - min(bytes, amount.knownLowerBound))
          complete = complete && amount.completeTotal != nil
        } else {
          complete = false
        }
      }
      updated.displayLogicalBytes = bytes
      updated.displaySizeComplete = complete
      return updated
    }
    projectPreviousPicture()
    displayRevision += 1
    persistPicture()
  }

  /// Completed actions update presentation by path without manufacturing fresh scan proof.
  private func projectPreviousPicture() {
    guard picture != nil, let original = pictureBeforeDisplayChanges else { return }
    let removed = Array(displayChanges.values)
    func wasRemoved(_ path: String) -> Bool {
      removed.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }
    let rows = original.content.rows.filter { !wasRemoved($0.path) }.map { row in
      let descendants = removed.filter { $0.path.hasPrefix(row.path + "/") }
      var bytes = row.logicalBytes
      var complete = row.sizeComplete
      for item in descendants where !descendants.contains(where: { item.path.hasPrefix($0.path + "/") }) {
        if let amount = item.size.logical {
          bytes = max(0, bytes - min(bytes, amount.knownLowerBound))
          complete = complete && amount.completeTotal != nil
        } else {
          complete = false
        }
      }
      return CleanPicture.Row(
        path: row.path, categoryID: row.categoryID, logicalBytes: bytes,
        sizeComplete: complete, detail: row.detail)
    }
    picture = ResultPicture(
      observedAt: original.observedAt,
      content: CleanPicture(
        rows: rows, relatedRows: original.content.relatedRows.filter { !wasRemoved($0.path) },
        partial: original.content.partial))
  }

  func observeResult(actions: ActionStore) {
    guard let planID = presentedPlanID, let result = actions.result,
      result.planID == planID, observedPlanID != planID
    else { return }
    observedPlanID = planID
    let moved = Set(result.items.filter { $0.outcome == .applied }.map(\.itemID))
    candidates.removeAll { moved.contains($0.id) }
    relatedCandidates.removeAll { candidate in
      candidate.snapshot?.entries.contains { moved.contains($0.id) && $0.path == candidate.path } == true
    }
    selected.subtract(moved)
    expirePreparation(actions: actions, keepPresentedPlanID: true)
    persistPicture()
  }

  func prepareRelated(_ candidate: RelatedDataCandidate, actions: ActionStore) async {
    guard picture == nil, tool.allowsPreparation, !actions.busy,
      let token = tool.preparation.begin()
    else { return }
    defer { tool.preparation.finish(token) }
    let outcome = await userPlanner.makeAvailableUserSelectionPlan(
      selections: [
        UserSelection(
          path: candidate.path,
          expectedIdentity: candidate.snapshot?.entries.first { $0.path == candidate.path }?.identity,
          observedSize: candidate.observation.map { ObservedPlanSize(logical: $0.logical, allocated: $0.allocated) },
          warnings: SelectionWarning.example(in: candidate.snapshot?.entries.map(\.path) ?? [candidate.path])
            .map { [UserSelectionWarning(examplePath: $0)] } ?? [],
          applicationPackagePaths: ActionStore.observedApplicationPackagePaths(
            in: candidate.snapshot?.entries.map(\.path) ?? [], under: candidate.path))
      ],
      kind: preferences.deletionDefault.kind)
    guard tool.preparation.accepts(token) else { return }
    guard let plan = outcome.plan else {
      message = outcome.rejections.map(SpaceText.rejection).joined(separator: "\n")
      return
    }
    let running = await actions.containsRunningApplications(plan)
    guard tool.preparation.accepts(token) else { return }
    actions.present(
      plan: plan,
      items: plan.items.map { item in
        let sizes = PlanItemSize.measure(item)
        return ActionItemSummary(
          id: item.id, label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
          path: item.sourcePath,
          reason: String(localized: "Previously verified owner absent here; it may exist elsewhere"),
          logicalBytes: sizes.0, allocatedBytes: sizes.1)
      }, hasRunningApplications: running)
    presentedPlanID = plan.id
    message = nil
  }

  func prepare(actions: ActionStore, kind: ActionKind = .trash) async {
    guard picture == nil, let catalog, tool.allowsPreparation, !actions.busy, !selected.isEmpty else { return }
    let chosen = candidates.filter { selected.contains($0.id) }
    guard chosen.count == selected.count else {
      message = String(localized: "Some selected items are unavailable. Scan again before cleaning.")
      return
    }
    if !usesInjectedPlanner {
      guard let token = tool.preparation.begin() else { return }
      defer { tool.preparation.finish(token) }
      let selectedIDs = selected
      let outcome = await userPlanner.makeAvailableUserSelectionPlan(
        selections: chosen.map { candidate in
          UserSelection(
            path: candidate.entry.path, expectedIdentity: candidate.entry.identity,
            observedSize: ObservedPlanSize(
              logical: ByteAggregate(
                knownLowerBound: candidate.logicalBytes,
                completeTotal: candidate.sizeComplete ? candidate.logicalBytes : nil),
              allocated: candidate.node.allocated),
            warnings: SelectionWarning.example(
              in: candidate.snapshot.entries.filter {
                $0.path == candidate.entry.path || $0.path.hasPrefix(candidate.entry.path + "/")
              }.map(\.path)
            ).map { [UserSelectionWarning(examplePath: $0)] } ?? [],
            applicationPackagePaths: ActionStore.observedApplicationPackagePaths(
              in: candidate.snapshot.entries.map(\.path), under: candidate.entry.path))
        }, kind: preferences.deletionDefault.kind)
      guard tool.preparation.accepts(token), selected == selectedIDs else { return }
      guard let plan = outcome.plan else {
        message = outcome.rejections.map(SpaceText.rejection).joined(separator: "\n")
        return
      }
      let running = await actions.containsRunningApplications(plan)
      guard tool.preparation.accepts(token), selected == selectedIDs else { return }
      actions.present(
        plan: plan,
        items: plan.items.map { item in
          ActionItemSummary(
            id: item.id, label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
            path: item.sourcePath, reason: String(localized: "Selected for removal"),
            logicalBytes: nil, allocatedBytes: nil, observedSize: item.observedSize)
        }, rejectedItems: outcome.rejections, hasRunningApplications: running)
      presentedPlanID = plan.id
      return
    }
    guard let token = tool.preparation.begin() else { return }
    let selectedIDs = selected
    defer {
      if tool.preparation.accepts(token) { availablePreparationTask = nil }
      tool.preparation.finish(token)
    }
    do {
      let groups = Dictionary(grouping: chosen, by: { $0.row.id })
      let selections = groups.values.compactMap { group -> CatalogSelection? in
        guard let first = group.first else { return nil }
        return CatalogSelection(snapshot: first.snapshot, selectedIDs: Set(group.map(\.id)), rowID: first.row.id)
      }
      let builder = availablePlanBuilder
      let task = Task(priority: .userInitiated) { @concurrent in try await builder(catalog, selections, kind) }
      availablePreparationTask = task
      let outcome = try await task.value
      guard tool.preparation.accepts(token), selected == selectedIDs, !task.isCancelled else { return }
      guard let plan = outcome.plan else {
        message = outcome.rejections.map(SpaceText.rejection).joined(separator: "\n")
        return
      }
      let turkish = Bundle.main.preferredLocalizations.first?.hasPrefix("tr") == true
      let summaries = plan.items.map { item in
        let candidate = chosen.first { $0.entry.path == item.sourcePath }
        let sizes = PlanItemSize.measure(item)
        return ActionItemSummary(
          id: item.id, label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
          path: item.sourcePath,
          reason: candidate.map { $0.row.reason(turkish: turkish) + " " + $0.row.cost(turkish: turkish) } ?? "",
          logicalBytes: sizes.0, allocatedBytes: sizes.1)
      }
      var permanentBuilder: (@MainActor @Sendable () async -> Void)?
      if kind == .trash && chosen.allSatisfy({ $0.row.methods.contains(.catalogDelete) }) {
        permanentBuilder = { @MainActor [weak self, weak actions] in
          guard let self, let actions, self.selected == selectedIDs, self.phase == .ready else { return }
          self.expirePreparation(keepPresentedPlanID: true)
          await self.prepare(actions: actions, kind: .catalogDelete)
        }
      }
      actions.present(
        plan: plan, items: summaries, permanentPlanBuilder: permanentBuilder, rejectedItems: outcome.rejections)
      guard actions.pending?.id == plan.id else { return }
      presentedPlanID = plan.id
      message = nil
    } catch {
      if tool.preparation.accepts(token) {
        if let refusals = error as? PlanRejections {
          message = refusals.rejections.map { SpaceText.rejection($0) }.joined(separator: "\n")
        } else {
          message = FailureText.describe(error)
        }
      }
    }
  }
}

/// Shared only with the serial disk queue; the UI's generation stays on the main actor.
private nonisolated final class CleanPictureWriteGeneration: Sendable {
  private let value = Mutex(UUID())
  func replace(with generation: UUID) { value.withLock { $0 = generation } }
  func accepts(_ generation: UUID) -> Bool { value.withLock { $0 == generation } }
}
