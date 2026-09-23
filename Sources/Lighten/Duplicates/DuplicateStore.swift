import Foundation
import LightenKit
import Observation

@MainActor @Observable
final class DuplicateStore {
  @ObservationIgnored private let service = DuplicateService()
  @ObservationIgnored private let planBuilder:
    @Sendable (DuplicateReport, [DuplicateGroupSelection]) async throws -> ActionPlan
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var scanGeneration = UUID()
  @ObservationIgnored private var preparationTask: Task<ActionPlan, Error>?
  @ObservationIgnored private var preparationGeneration = UUID()

  init(
    planBuilder: @escaping @Sendable (DuplicateReport, [DuplicateGroupSelection]) async throws -> ActionPlan = {
      try await DuplicateService().makePlan(report: $0, selections: $1)
    }
  ) {
    self.planBuilder = planBuilder
  }

  var folderPath: String?
  var report: DuplicateReport?
  var scanned = 0
  var compared = 0
  var busy = false
  var preparing = false
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

  func startScan(folder: String, actions: ActionStore) {
    invalidatePreparation(actions: actions)
    cancelScan()
    let generation = UUID()
    scanGeneration = generation
    folderPath = folder
    report = nil
    keepers = [:]
    targets = []
    needsRescan = false
    scanned = 0
    compared = 0
    message = nil
    cancelled = false
    busy = true
    scanTask = Task {
      do {
        for try await event in service.events(rootPath: folder) {
          guard scanGeneration == generation else { return }
          switch event {
          case .progress(let scannedCount, let comparedCount):
            scanned = scannedCount
            compared = comparedCount
          case .completed(let value):
            report = value
            scanned = value.snapshot.entries.count
          }
        }
      } catch is CancellationError {
        if scanGeneration == generation { cancelled = true }
      } catch {
        if scanGeneration == generation { message = FailureText.describe(error) }
      }
      if scanGeneration == generation { busy = false }
    }
  }

  func cancelScan() {
    scanTask?.cancel()
    scanTask = nil
    scanGeneration = UUID()
    if busy { cancelled = true }
    busy = false
  }

  func deactivate(actions: ActionStore) {
    // Leaving the screen keeps a running scan going; only prepared plans expire.
    observeResult(actions: actions)
    let awaitingResult = actions.busy && actions.pending?.id != presentedPlanID
    invalidatePreparation(actions: actions, keepPresentedPlanID: awaitingResult || needsRescan)
  }

  func observeResult(actions: ActionStore) {
    guard let presentedPlanID, actions.result?.planID == presentedPlanID,
      !needsRescan
    else { return }
    invalidatePreparation(actions: actions, keepPresentedPlanID: true)
    targets = []
    keepers = [:]
    needsRescan = true
  }

  private func invalidatePreparation(
    actions: ActionStore? = nil, keepPresentedPlanID: Bool = false
  ) {
    preparationGeneration = UUID()
    preparationTask?.cancel()
    preparationTask = nil
    preparing = false
    message = nil
    let pendingMatches = actions?.pending?.id == presentedPlanID && presentedPlanID != nil
    if pendingMatches {
      actions?.pending = nil
    }
    if !keepPresentedPlanID || pendingMatches { presentedPlanID = nil }
  }

  func chooseKeeper(_ id: UUID, for group: DuplicateGroup, actions: ActionStore) {
    guard !needsRescan, !actions.busy,
      group.members.contains(where: { $0.id == id && $0.eligibility == .eligible })
    else { return }
    invalidatePreparation(actions: actions)
    keepers[group.id] = id
    targets.subtract(group.members.map(\.id))
  }

  func toggleTarget(_ id: UUID, in group: DuplicateGroup, actions: ActionStore) {
    guard !needsRescan, !actions.busy,
      let keeperID = keepers[group.id], group.canTarget(id, keeperID: keeperID)
    else { return }
    invalidatePreparation(actions: actions)
    if targets.contains(id) { targets.remove(id) } else { targets.insert(id) }
  }

  func prepare(actions: ActionStore) async {
    guard let report, !busy, !preparing, !actions.busy, !needsRescan, !targets.isEmpty
    else { return }
    let generation = UUID()
    preparationGeneration = generation
    preparing = true
    defer {
      if preparationGeneration == generation {
        preparing = false
        preparationTask = nil
      }
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
      guard preparationGeneration == generation,
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
      if preparationGeneration == generation {
        message = String(localized: "Files changed or could not be verified. Scan again.")
      }
    }
  }
}
