import Foundation
import LightenKit
import Observation

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

  var logicalBytes: Int64 { exactLogicalBytes ?? node.logical.knownLowerBound }
  var sizeComplete: Bool { exactLogicalBytes != nil || node.logical.completeTotal != nil }

  var canAct: Bool {
    guard allowed, activity == .clearObservedCurrentUID, let identity = entry.identity,
      identity.kind != .other, identity.birthSeconds != nil, identity.birthNanoseconds != nil,
      identity.modificationSeconds != nil, identity.modificationNanoseconds != nil,
      identity.device == snapshot.volumeDevice, snapshot.volumeID != nil
    else { return false }
    return true
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

  @ObservationIgnored private let activity: any ProcessActivitySource
  @ObservationIgnored private let catalog: CleanCatalog?
  @ObservationIgnored private let catalogFailure: (any Error)?
  @ObservationIgnored let homeDirectory: String
  @ObservationIgnored private let scanner: Scanner
  @ObservationIgnored private let discoverRelated: @Sendable () async -> [RelatedDataCandidate]
  @ObservationIgnored private let availablePlanBuilder: AvailablePlanBuilder
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var scanGeneration = UUID()
  @ObservationIgnored private var relatedTask: Task<Void, Never>?
  @ObservationIgnored private var relatedGeneration: UUID?
  @ObservationIgnored private var preparationTask: Task<ActionPlan, Error>?
  @ObservationIgnored private var availablePreparationTask: Task<CatalogPlanOutcome, Error>?
  @ObservationIgnored private var observedPlanID: UUID?
  let tool = ToolStore()
  var candidates: [CleanCandidate] = []
  var relatedCandidates: [RelatedDataCandidate] = []
  private(set) var discoveringRelated = false
  var rowStatuses: [String: CleanRowStatus] = [:]
  var selected: Set<UUID> = []
  var mode: ActionKind = .trash
  var scannedAt: Date?
  var presentedPlanID: UUID?
  var message: String?

  init(
    activity: any ProcessActivitySource = MacOSProcessActivitySource(),
    homeDirectory: String = NSHomeDirectory(),
    catalogLoader: @Sendable (String) throws -> CleanCatalog = { try CleanCatalog(homeDirectory: $0) },
    scanner: @escaping Scanner = { path, home in try await ScanService(homeDirectory: home).scan(rootPath: path) },
    discoverRelated: @escaping @Sendable () async -> [RelatedDataCandidate] = {
      await RelatedDataService.system.discover()
    },
    planBuilder: PlanBuilder? = nil,
    availablePlanBuilder: AvailablePlanBuilder? = nil
  ) {
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
  }

  var rows: [CatalogRow] { catalog?.rows ?? [] }
  var phase: ToolPhase { tool.preparation.preparing ? .preparing : tool.phase }
  var busy: Bool { phase == .scanning || tool.preparation.preparing }
  var partial: Bool { phase == .partial }
  var actionableCandidates: [CleanCandidate] { candidates.filter(\.canAct) }
  var toolSummary: ToolSummary {
    ToolSummary(
      count: actionableCandidates.count,
      logicalBytes: actionableCandidates.reduce(0) { $0 + $1.logicalBytes },
      observedAt: scannedAt, partial: partial)
  }
  var selectedLogicalBytes: Int64 {
    candidates.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.logicalBytes }
  }

  func refresh() { startScan() }

  func startScan(actions: ActionStore? = nil) {
    guard phase != .scanning else { return }
    expirePreparation(actions: actions)
    cancelRelatedDiscovery()
    let generation = UUID()
    scanGeneration = generation
    tool.phase = .scanning
    candidates = []
    relatedCandidates = []
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
        let snapshot = try await scanner(catalog.root(for: row), homeDirectory)
        if Task.isCancelled || scanGeneration != generation { return }
        let nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        let direct = snapshot.entries.filter { $0.parentID == snapshot.entries.first?.id }
        for entry in direct {
          if let node = nodes[entry.id] {
            let candidateActivity =
              childScoped
              ? await activity.activity(for: row, rootPath: catalog.activityRoot(for: row, candidatePath: entry.path))
              : rowActivity
            if Task.isCancelled || scanGeneration != generation { return }
            let rejection = await Task.detached(priority: .utility) {
              catalog.candidateRejection(path: entry.path, row: row, kind: .trash)
            }.value
            if Task.isCancelled || scanGeneration != generation { return }
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
                exactLogical = plan.items.reduce(Int64(0)) { $0 + PlanItemSize.measure($1).0 }
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
        }
        rowStatuses[row.id] =
          activityState == .active
          ? .toolRunning
          : activityState == .unknown ? .processUnknown : direct.isEmpty ? .empty : .clear
      } catch {
        if Task.isCancelled || scanGeneration != generation { return }
        rowStatuses[row.id] = .unavailable
      }
    }
    if Task.isCancelled || scanGeneration != generation { return }
    scannedAt = Date()
    tool.phase = .ready
    selected = Set(actionableCandidates.filter { $0.row.defaultSelected }.map(\.id))
    scanTask = nil
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
  }

  private func cancelRelatedDiscovery() {
    relatedGeneration = nil
    relatedTask?.cancel()
    relatedTask = nil
    discoveringRelated = false
  }

  func toggleCategory(_ rowID: String, actions: ActionStore) {
    guard tool.phase == .ready, !actions.busy else { return }
    let ids = Set(actionableCandidates.filter { $0.row.id == rowID }.map(\.id))
    expirePreparation(actions: actions)
    if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
  }

  func selectAll(actions: ActionStore) {
    guard tool.phase == .ready, !actions.busy else { return }
    expirePreparation(actions: actions)
    let ids = Set(actionableCandidates.map(\.id))
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
    selected = []
    expirePreparation(actions: actions, keepPresentedPlanID: true)
  }

  func prepareRelated(_ candidate: RelatedDataCandidate, actions: ActionStore) async {
    guard tool.allowsPreparation, !actions.busy,
      candidate.classification == .historicallyVerifiedAbsent,
      let token = tool.preparation.begin()
    else { return }
    defer { tool.preparation.finish(token) }
    do {
      let task = Task { @concurrent in try RelatedDataService.system.plan(candidate: candidate) }
      preparationTask = task
      let plan = try await task.value
      guard tool.preparation.accepts(token), !task.isCancelled else { return }
      actions.present(
        plan: plan,
        items: plan.items.map { item in
          let sizes = PlanItemSize.measure(item)
          return ActionItemSummary(
            id: item.id, label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
            path: item.sourcePath,
            reason: String(localized: "Previously verified owner absent here; it may exist elsewhere"),
            logicalBytes: sizes.0, allocatedBytes: sizes.1)
        })
      presentedPlanID = plan.id
      message = nil
    } catch {
      if tool.preparation.accepts(token) { message = FailureText.describe(error) }
    }
  }

  func prepare(actions: ActionStore, kind: ActionKind = .trash) async {
    guard let catalog, tool.allowsPreparation, !actions.busy, !selected.isEmpty else { return }
    let chosen = candidates.filter { selected.contains($0.id) }
    guard chosen.count == selected.count, chosen.allSatisfy({ $0.canAct && $0.row.methods.contains(kind) }) else {
      message = String(localized: "Some selected items are unavailable. Scan again before cleaning.")
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
