import Foundation
import LightenKit
import OSLog
import Observation
import Synchronization

@MainActor @Observable
final class DuplicateStore: ToolSummaryProviding {
  typealias Events = @Sendable (String) -> AsyncThrowingStream<DuplicateEvent, Error>
  @ObservationIgnored private let userPlanner: PlanService
  @ObservationIgnored private let preferences: RemovalPreferences
  @ObservationIgnored private let usesInjectedPlanner: Bool
  @ObservationIgnored private let events: Events
  @ObservationIgnored private let planBuilder:
    @Sendable (DuplicateReport, [DuplicateGroupSelection]) async throws -> ActionPlan
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var scanGeneration = UUID()
  @ObservationIgnored private var preparationTask: Task<ActionPlan, Error>?
  @ObservationIgnored private let loadPicture: @Sendable () -> ResultPicture<DuplicatePicture>?
  @ObservationIgnored private let savePicture: @Sendable (ResultPicture<DuplicatePicture>) throws -> Void
  @ObservationIgnored private let pictureQueue = DispatchQueue(
    label: "com.tavsn.lighten.duplicate-pictures", qos: .utility)
  @ObservationIgnored private let pictureWriteGeneration = DuplicatePictureWriteGeneration()
  @ObservationIgnored private var pictureTask: Task<Void, Never>?
  @ObservationIgnored private var opened = false
  @ObservationIgnored private var openingRequestedAt: ContinuousClock.Instant?
  @ObservationIgnored private var pictureDrawn = false
  @ObservationIgnored private let openingLogger = Logger(subsystem: "com.tavsn.lighten", category: "duplicates-opening")
  @ObservationIgnored private var originalPicture: ResultPicture<DuplicatePicture>?
  @ObservationIgnored private var hiddenPicturePaths: [UUID: Set<String>] = [:]
  @ObservationIgnored private weak var lastActions: ActionStore?
  let tool = ToolStore()
  private(set) var picture: ResultPicture<DuplicatePicture>?
  private(set) var scannedAt: Date?
  @ObservationIgnored private var displayGroups: [UUID: DuplicateGroup] = [:]
  @ObservationIgnored private var removedMembers: [UUID: Set<UUID>] = [:]
  private(set) var displayRevision = 0

  init(
    planBuilder: (@Sendable (DuplicateReport, [DuplicateGroupSelection]) async throws -> ActionPlan)? = nil,
    userPlanner: PlanService = PlanService(), preferences: RemovalPreferences = .shared,
    pictures: ResultPictureStore = ResultPictureStore(),
    loadPicture: (@Sendable () -> ResultPicture<DuplicatePicture>?)? = nil,
    savePicture: (@Sendable (ResultPicture<DuplicatePicture>) throws -> Void)? = nil,
    events: @escaping Events = { DuplicateService().events(rootPath: $0) }
  ) {
    self.planBuilder = planBuilder ?? { try await DuplicateService().makePlan(report: $0, selections: $1) }
    self.userPlanner = userPlanner
    self.preferences = preferences
    self.usesInjectedPlanner = planBuilder != nil
    self.events = events
    self.loadPicture = loadPicture ?? { pictures.load(DuplicatePicture.self, named: "duplicates") }
    self.savePicture = savePicture ?? { try pictures.save($0, named: "duplicates") }
    pictureWriteGeneration.replace(with: scanGeneration)
  }

  var folderPath: String?
  var report: DuplicateReport?
  var scanned = 0
  var compared = 0
  var busy: Bool { tool.phase == .scanning }
  var preparing: Bool { tool.preparation.preparing }
  var phase: ToolPhase { preparing ? .preparing : tool.phase }
  var cancelled = false
  var message: String?
  var keepers: [UUID: UUID] = [:]
  var targets: Set<UUID> = []
  var presentedPlanID: UUID?
  var needsRescan = false

  var selectedLogicalBytes: Int64 {
    guard let report else { return 0 }
    return report.groups.reduce(0) { sum, group in
      let count = group.members.filter { targets.contains($0.id) }.count
      let (bytes, productOverflow) = group.logicalBytes.multipliedReportingOverflow(by: Int64(count))
      let (value, sumOverflow) = sum.addingReportingOverflow(bytes)
      return productOverflow || sumOverflow ? Int64.max : value
    }
  }

  var toolSummary: ToolSummary {
    let content = picture?.content ?? report.map(DuplicatePicture.init)
    let bytes =
      content?.groups.reduce(Int64(0)) { total, group in
        let (amount, overflow) = group.logicalBytes.multipliedReportingOverflow(by: Int64(group.members.count))
        let (sum, sumOverflow) = total.addingReportingOverflow(amount)
        return overflow || sumOverflow ? Int64.max : sum
      } ?? 0
    return ToolSummary(
      count: content?.groups.count ?? 0, logicalBytes: bytes,
      observedAt: picture?.observedAt ?? scannedAt, partial: content?.partial == true || phase == .partial)
  }

  func refresh() {
    if let folderPath { startScan(folder: folderPath, actions: lastActions) }
  }

  func open() {
    guard !opened else { return }
    opened = true
    guard report == nil, tool.phase == .idle else { return }
    let generation = scanGeneration
    let requestedAt = ContinuousClock.now
    openingRequestedAt = requestedAt
    let queue = pictureQueue
    let load = loadPicture
    pictureTask = Task(priority: .utility) { @concurrent [weak self] in
      let cached: ResultPicture<DuplicatePicture>? = await withCheckedContinuation { continuation in
        queue.async { continuation.resume(returning: load()) }
      }
      guard !Task.isCancelled else { return }
      await self?.publishPicture(cached, generation: generation, requestedAt: requestedAt)
    }
  }

  private func publishPicture(
    _ cached: ResultPicture<DuplicatePicture>?, generation: UUID, requestedAt: ContinuousClock.Instant
  ) {
    guard scanGeneration == generation, report == nil, tool.phase == .idle else { return }
    picture = cached
    guard let cached else { return }
    folderPath = cached.content.rootPath
    scanned = cached.content.scannedCount
    compared = cached.content.comparisonCount
    let elapsed = Self.milliseconds(requestedAt.duration(to: .now))
    let count = cached.content.groups.count
    openingLogger.info(
      "Duplicate picture published milliseconds=\(elapsed, privacy: .public) groups=\(count, privacy: .public)")
  }

  func pictureDidDraw() {
    guard picture != nil, !pictureDrawn, let requestedAt = openingRequestedAt else { return }
    pictureDrawn = true
    let elapsed = Self.milliseconds(requestedAt.duration(to: .now))
    openingLogger.info("Duplicate picture drawn milliseconds=\(elapsed, privacy: .public)")
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1_000_000_000_000_000
  }

  func waitForPicture() async { await pictureTask?.value }
  func waitForScan() async { await scanTask?.value }
  func waitForPictureSaves() async {
    let queue = pictureQueue
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  }

  private func persistPicture() {
    let value: ResultPicture<DuplicatePicture>
    if let picture {
      value = picture
    } else {
      guard tool.phase == .ready, let report, let scannedAt else { return }
      value = ResultPicture(observedAt: scannedAt, content: DuplicatePicture(report))
    }
    let generation = scanGeneration
    let state = pictureWriteGeneration
    let save = savePicture
    pictureQueue.async {
      guard state.accepts(generation) else { return }
      try? save(value)
    }
  }

  func startScan(folder: String, actions: ActionStore? = nil) {
    lastActions = actions ?? lastActions
    clearPreparation(actions: actions)
    cancelScan()
    let generation = UUID()
    scanGeneration = generation
    pictureWriteGeneration.replace(with: generation)
    picture = nil
    originalPicture = nil
    hiddenPicturePaths = [:]
    scannedAt = nil
    folderPath = folder
    report = nil
    displayGroups = [:]
    removedMembers = [:]
    keepers = [:]
    targets = []
    needsRescan = false
    scanned = 0
    compared = 0
    message = nil
    cancelled = false
    tool.phase = .scanning
    scanTask = Task {
      do {
        for try await event in events(folder) {
          guard scanGeneration == generation else { return }
          switch event {
          case .progress(let scannedCount, let comparedCount):
            scanned = scannedCount
            compared = comparedCount
          case .completed(let value):
            guard !Task.isCancelled else { return }
            report = value
            scanned = value.snapshot.entries.count
            compared = value.comparisonCount
          }
        }
      } catch is CancellationError {
        if scanGeneration == generation {
          cancelled = true
          tool.phase = .partial
        }
      } catch {
        if scanGeneration == generation {
          message = FailureText.describe(error)
          tool.phase = .failed
        }
      }
      guard scanGeneration == generation, !Task.isCancelled else { return }
      if tool.phase == .scanning {
        tool.phase = report == nil ? .failed : .ready
        if report != nil {
          scannedAt = Date()
          persistPicture()
        }
      }
    }
  }

  func cancelScan() {
    scanTask?.cancel()
    scanTask = nil
    scanGeneration = UUID()
    pictureWriteGeneration.replace(with: scanGeneration)
    if busy {
      cancelled = true
      tool.phase = .partial
      keepers = [:]
      targets = []
      clearPreparation(actions: lastActions)
    }
  }

  func deactivate(actions: ActionStore) {
    // Leaving the screen keeps a running scan going; only prepared plans expire.
    observeResult(actions: actions)
    let awaitingResult = actions.busy && actions.pending?.id != presentedPlanID
    clearPreparation(actions: actions, keepPresentedPlanID: awaitingResult || needsRescan)
  }

  func applyDisplayChange(_ change: ActionDisplayChange) {
    clearPreparation(actions: lastActions, keepPresentedPlanID: true)
    if picture != nil {
      applyPictureDisplayChange(change)
      return
    }
    guard let report else { return }
    if displayGroups.isEmpty { displayGroups = Dictionary(uniqueKeysWithValues: report.groups.map { ($0.id, $0) }) }
    for item in change.items {
      switch change.kind {
      case .applied:
        removedMembers[item.itemID] = Set(
          displayGroups.values.flatMap(\.members).filter {
            item.matches(path: $0.entry.path, identity: $0.entry.identity)
          }.map(\.id))
      case .restored: removedMembers.removeValue(forKey: item.itemID)
      }
    }
    let hidden = removedMembers.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
    let groups = displayGroups.values.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap {
      group -> DuplicateGroup? in
      let members = group.members.filter { !hidden.contains($0.id) }
      guard members.count > 1 else { return nil }
      return DuplicateGroup(id: group.id, logicalBytes: group.logicalBytes, members: members)
    }
    self.report = DuplicateReport(
      snapshot: report.snapshot, groups: groups, skippedCount: report.skippedCount,
      partial: report.partial, comparisonCount: report.comparisonCount)
    targets.subtract(hidden)
    displayRevision += 1
    if change.kind == .applied, !hidden.isEmpty { needsRescan = false }
    persistPicture()
  }

  private func applyPictureDisplayChange(_ change: ActionDisplayChange) {
    if originalPicture == nil { originalPicture = picture }
    guard let originalPicture else { return }
    for item in change.items {
      switch change.kind {
      case .applied:
        hiddenPicturePaths[item.itemID] = Set(
          originalPicture.content.groups.flatMap(\.members).filter {
            $0.path == item.path
          }.map(\.path))
      case .restored: hiddenPicturePaths.removeValue(forKey: item.itemID)
      }
    }
    let hidden = hiddenPicturePaths.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    let content = originalPicture.content
    picture = ResultPicture(
      observedAt: originalPicture.observedAt,
      content: DuplicatePicture(
        rootPath: content.rootPath,
        groups: content.groups.compactMap { group in
          let members = group.members.filter { !hidden.contains($0.path) }
          return members.count > 1 ? DuplicatePicture.Group(logicalBytes: group.logicalBytes, members: members) : nil
        }, scannedCount: content.scannedCount, comparisonCount: content.comparisonCount,
        skippedCount: content.skippedCount, partial: content.partial))
    displayRevision += 1
    persistPicture()
  }

  func observeResult(actions: ActionStore) {
    guard let presentedPlanID, actions.result?.planID == presentedPlanID,
      !needsRescan
    else { return }
    clearPreparation(actions: actions, keepPresentedPlanID: true)
    let applied = Set(actions.result?.items.filter { $0.outcome == .applied }.map(\.itemID) ?? [])
    targets.subtract(applied)
    keepers = [:]
    needsRescan = false
  }

  private func clearPreparation(
    actions: ActionStore? = nil, keepPresentedPlanID: Bool = false
  ) {
    tool.preparation.invalidatePreparation()
    preparationTask?.cancel()
    preparationTask = nil
    message = nil
    let pendingMatches = actions?.pending?.id == presentedPlanID && presentedPlanID != nil
    if pendingMatches {
      actions?.pending = nil
    }
    if !keepPresentedPlanID || pendingMatches { presentedPlanID = nil }
  }

  func chooseKeeper(_ id: UUID, for group: DuplicateGroup, actions: ActionStore) {
    guard picture == nil, tool.phase == .ready, !needsRescan, !actions.busy,
      let group = report?.groups.first(where: { $0.id == group.id }),
      group.members.contains(where: { $0.id == id })
    else { return }
    lastActions = actions
    clearPreparation(actions: actions)
    keepers[group.id] = id
    targets.subtract(group.members.map(\.id))
  }

  func toggleTarget(_ id: UUID, in group: DuplicateGroup, actions: ActionStore) {
    guard picture == nil, tool.phase == .ready, !needsRescan, !actions.busy,
      let group = report?.groups.first(where: { $0.id == group.id }),
      let keeperID = keepers[group.id], keeperID != id, group.members.contains(where: { $0.id == id })
    else { return }
    lastActions = actions
    clearPreparation(actions: actions)
    if targets.contains(id) { targets.remove(id) } else { targets.insert(id) }
  }

  func prepare(actions: ActionStore) async {
    lastActions = actions
    guard picture == nil, let report, tool.allowsPreparation, !actions.busy, !needsRescan, !targets.isEmpty
    else { return }
    if !usesInjectedPlanner {
      guard let generation = tool.preparation.begin() else { return }
      defer { tool.preparation.finish(generation) }
      let chosen = report.groups.flatMap(\.members).filter { targets.contains($0.id) }
      let selected = targets
      let outcome = await userPlanner.makeAvailableUserSelectionPlan(
        selections: chosen.map { member in
          UserSelection(
            path: member.entry.path, expectedIdentity: member.entry.identity,
            observedSize: member.entry.identity.map {
              ObservedPlanSize(
                logical: ByteAggregate(knownLowerBound: $0.logicalBytes, completeTotal: $0.logicalBytes),
                allocated: ByteAggregate(knownLowerBound: $0.allocatedBytes, completeTotal: $0.allocatedBytes))
            },
            applicationPackagePaths: ActionStore.observedApplicationPackagePaths(
              in: report.snapshot.entries.map(\.path), under: member.entry.path))
        }, kind: preferences.deletionDefault.kind, runID: report.snapshot.runID)
      guard tool.preparation.accepts(generation), targets == selected,
        self.report?.snapshot.runID == report.snapshot.runID
      else { return }
      guard let plan = outcome.plan else {
        message = outcome.rejections.map(SpaceText.rejection).joined(separator: "\n")
        return
      }
      let running = await actions.containsRunningApplications(plan)
      guard tool.preparation.accepts(generation), targets == selected,
        self.report?.snapshot.runID == report.snapshot.runID
      else { return }
      actions.present(
        plan: plan,
        items: plan.items.map { item in
          ActionItemSummary(
            id: item.id, label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
            path: item.sourcePath, reason: String(localized: "Selected copy"),
            logicalBytes: nil, allocatedBytes: nil, observedSize: item.observedSize)
        }, rejectedItems: outcome.rejections, hasRunningApplications: running)
      presentedPlanID = plan.id
      return
    }
    guard let generation = tool.preparation.begin() else { return }
    defer {
      if tool.preparation.accepts(generation) { preparationTask = nil }
      tool.preparation.finish(generation)
    }
    do {
      let selections = report.groups.compactMap { group -> DuplicateGroupSelection? in
        guard let keeperID = keepers[group.id] else { return nil }
        let memberIDs = Set(group.members.map(\.id))
        let chosen = targets.intersection(memberIDs)
        guard !chosen.isEmpty else { return nil }
        return DuplicateGroupSelection(groupID: group.id, keeperID: keeperID, targetIDs: chosen)
      }
      let task = Task { @concurrent in
        try await planBuilder(report, selections)
      }
      preparationTask = task
      let plan = try await task.value
      guard tool.preparation.accepts(generation),
        self.report?.snapshot.runID == report.snapshot.runID,
        !task.isCancelled
      else { return }
      let entries = Dictionary(uniqueKeysWithValues: report.snapshot.entries.map { ($0.id, $0) })
      let summaries = plan.items.map { item in
        ActionItemSummary(
          id: item.id, label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
          path: item.sourcePath, reason: String(localized: "Exact copy; verified keeper remains"),
          logicalBytes: entries[item.id]?.identity?.logicalBytes,
          allocatedBytes: entries[item.id]?.identity?.allocatedBytes)
      }
      actions.present(plan: plan, items: summaries)
      presentedPlanID = plan.id
      message = nil
    } catch {
      if tool.preparation.accepts(generation) {
        message = String(localized: "Files changed or could not be verified. Scan again.")
      }
    }
  }
}

/// Shared only with the serial disk queue; UI generation remains main-actor owned.
private nonisolated final class DuplicatePictureWriteGeneration: Sendable {
  private let value = Mutex(UUID())
  func replace(with generation: UUID) { value.withLock { $0 = generation } }
  func accepts(_ generation: UUID) -> Bool { value.withLock { $0 == generation } }
}
