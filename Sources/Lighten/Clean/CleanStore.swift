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

  var canAct: Bool {
    !node.partial && !node.protected && entry.issues.isEmpty
      && activity == .clearObservedCurrentUID && entry.identity != nil
  }
}

enum CleanRowStatus: Sendable {
  case toolRunning, processUnknown, empty, clear, unavailable
}

@MainActor @Observable
final class CleanStore {
  @ObservationIgnored private let activity: any ProcessActivitySource
  @ObservationIgnored private let catalog: CleanCatalog?
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var scanGeneration = UUID()
  var candidates: [CleanCandidate] = []
  var relatedCandidates: [RelatedDataCandidate] = []
  var rowStatuses: [String: CleanRowStatus] = [:]
  var selected: Set<UUID> = []
  var mode: ActionKind = .trash
  var busy = false
  var scannedAt: Date?
  var presentedPlanID: UUID?
  var message: String?

  init(activity: any ProcessActivitySource = MacOSProcessActivitySource()) {
    self.activity = activity
    self.catalog = try? CleanCatalog()
  }

  var rows: [CatalogRow] { catalog?.rows ?? [] }

  func startScan() {
    guard !busy else { return }
    let generation = UUID()
    scanGeneration = generation
    scanTask = Task { await scan(generation: generation) }
  }

  func cancelScan() {
    guard busy, scanTask != nil else { return }
    scanGeneration = UUID()
    scanTask?.cancel()
    scanTask = nil
    busy = false
    candidates = []
    relatedCandidates = []
    rowStatuses = [:]
    selected = []
    scannedAt = nil
    presentedPlanID = nil
    message = String(localized: "Scan cancelled")
  }

  private func scan(generation: UUID) async {
    guard !busy else { return }
    busy = true
    defer {
      if scanGeneration == generation {
        busy = false
        scanTask = nil
      }
    }
    candidates = []
    relatedCandidates = []
    selected = []
    presentedPlanID = nil
    rowStatuses = [:]
    message = nil
    if catalog == nil {
      message = String(localized: "Clean catalog unavailable. Reinstall the app.")
    }
    if let catalog {
      for row in catalog.rows {
        if Task.isCancelled || scanGeneration != generation { return }
        let activityState = await activity.activity(for: row.id).state
        do {
          let snapshot = try await ScanService().scan(rootPath: catalog.root(for: row))
          if Task.isCancelled || scanGeneration != generation { return }
          let nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
          let direct = snapshot.entries.filter { $0.parentID == snapshot.entries.first?.id }
          for entry in direct {
            if let node = nodes[entry.id] {
              candidates.append(
                CleanCandidate(
                  id: entry.id, row: row,
                  snapshot: snapshot, entry: entry, node: node,
                  activity: activityState))
            }
          }
          rowStatuses[row.id] =
            activityState == .active
            ? .toolRunning : activityState == .unknown ? .processUnknown : direct.isEmpty ? .empty : .clear
        } catch {
          if Task.isCancelled || scanGeneration != generation { return }
          rowStatuses[row.id] = .unavailable
        }
      }
    }
    let related = await RelatedDataService.system.discover()
    if Task.isCancelled || scanGeneration != generation { return }
    relatedCandidates = related
    scannedAt = Date()
  }

  func prepareRelated(_ candidate: RelatedDataCandidate, actions: ActionStore) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let plan = try await Task.detached(priority: .utility) {
        try RelatedDataService.system.plan(candidate: candidate)
      }.value
      actions.present(
        plan: plan,
        items: [
          ActionItemSummary(
            id: plan.items[0].id,
            label: URL(fileURLWithPath: candidate.path).lastPathComponent,
            path: candidate.path,
            reason: String(
              localized:
                "Previously verified relationship; owner absent from searched app locations. Data may exist elsewhere."),
            logicalBytes: candidate.snapshot?.nodes.first(where: { $0.id == plan.items[0].id })?.logical.completeTotal,
            allocatedBytes: candidate.snapshot?.nodes.first(where: { $0.id == plan.items[0].id })?.allocated
              .completeTotal)
        ])
      presentedPlanID = plan.id
      message = nil
    } catch {
      message =
        String(localized: "Could not prepare related data for Trash. Scan again.")
        + " " + String(describing: error)
    }
  }

  func prepare(actions: ActionStore) async {
    guard let catalog, !busy, !selected.isEmpty else { return }
    let chosen = candidates.filter { selected.contains($0.id) }
    guard chosen.count == selected.count, chosen.allSatisfy(\.canAct),
      let first = chosen.first,
      chosen.allSatisfy({ $0.row.id == first.row.id && $0.snapshot.runID == first.snapshot.runID })
    else {
      message = String(localized: "Selection requires a complete, clear scan of one cache area")
      return
    }
    busy = true
    defer { busy = false }
    do {
      let selectedIDs = selected
      let kind = mode
      let plan = try await Task.detached(priority: .utility) {
        try catalog.plan(
          snapshot: first.snapshot, selectedIDs: selectedIDs,
          rowID: first.row.id, kind: kind)
      }.value
      let turkish = Bundle.main.preferredLocalizations.first?.hasPrefix("tr") == true
      actions.present(
        plan: plan,
        items: chosen.map { candidate in
          ActionItemSummary(
            id: candidate.id,
            label: URL(fileURLWithPath: candidate.entry.path).lastPathComponent,
            path: candidate.entry.path,
            reason: "\(candidate.row.reason(turkish: turkish)) \(candidate.row.cost(turkish: turkish))",
            logicalBytes: candidate.node.logical.completeTotal,
            allocatedBytes: candidate.node.allocated.completeTotal)
        })
      presentedPlanID = plan.id
      message = nil
    } catch {
      message =
        String(localized: "Could not prepare a safe plan. Scan again or inspect the item.")
        + " " + String(describing: error)
    }
  }
}
