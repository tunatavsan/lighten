import Foundation
import LightenKit
import Observation

@MainActor @Observable
final class AppsStore {
  @ObservationIgnored private let events: @Sendable () -> AsyncStream<ApplicationDiscovery.Event>
  @ObservationIgnored private let planBuilder:
    @Sendable (ApplicationReport, RelatedDataCandidate) async throws -> ActionPlan
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var preparationTask: Task<ActionPlan, Error>?
  @ObservationIgnored private var preparationGeneration = UUID()
  @ObservationIgnored private let running: any RunningApplicationSource
  var reports: [ApplicationReport] = []
  var measuringPaths: Set<String> = []
  var measuredCount = 0
  var inventoryComplete = false
  var scannedAt: Date?
  var busy = false
  var preparing = false
  var needsRescan = false
  var selectedPath: String?
  var packageSelected = false
  var selectedDataPath: String?
  var runningIDs: Set<String> = []
  var runningUnknownIDs: Set<String> = []
  var runningCheckedIDs: Set<String> = []
  var message: String?
  var presentedPlanID: UUID?

  init(
    running: any RunningApplicationSource = MacOSRunningApplicationSource(),
    events: @escaping @Sendable () -> AsyncStream<ApplicationDiscovery.Event> = {
      ApplicationDiscovery().events()
    },
    planBuilder: @escaping @Sendable (ApplicationReport, RelatedDataCandidate) async throws -> ActionPlan = {
      report, candidate in
      guard let bundleID = report.bundleID,
        let app = RelatedDataService().inventory().applications.first(where: {
          $0.path == report.path && $0.bundleID == bundleID
        })
      else { throw RelatedFailure.ambiguousOwner }
      return try RelatedDataService().planInstalled(app: app, candidate: candidate)
    }
  ) {
    self.running = running
    self.events = events
    self.planBuilder = planBuilder
  }

  var selectedReport: ApplicationReport? { reports.first { $0.path == selectedPath } }

  func startScan(actions: ActionStore) {
    guard !busy else { return }
    invalidatePreparation(actions: actions)
    let id = UUID()
    generation = id
    busy = true
    reports = []
    measuringPaths = []
    measuredCount = 0
    inventoryComplete = false
    selectedPath = nil
    packageSelected = false
    selectedDataPath = nil
    runningIDs = []
    runningUnknownIDs = []
    runningCheckedIDs = []
    scannedAt = nil
    message = nil
    needsRescan = false
    let events = self.events
    scanTask = Task { @concurrent in
      var finishedInventory: BundleInventory?
      for await event in events() {
        if Task.isCancelled { return }
        await MainActor.run {
          guard self.generation == id else { return }
          switch event {
          case .inventory(_, let metadata):
            self.reports = metadata
            self.measuringPaths = Set(metadata.map(\.path))
          case .measured(let batch):
            for report in batch {
              if let index = self.reports.firstIndex(where: { $0.path == report.path }) {
                self.reports[index] = report
                self.measuringPaths.remove(report.path)
                self.measuredCount += 1
              }
            }
          case .completed(let inventory, let reports):
            self.reports = reports
            self.measuringPaths = []
            self.measuredCount = reports.count
            self.inventoryComplete = inventory.complete
            self.scannedAt = Date()
            finishedInventory = inventory
          }
        }
      }
      guard let inventory = finishedInventory, !Task.isCancelled else {
        await MainActor.run {
          guard self.generation == id, !Task.isCancelled else { return }
          self.busy = false
          self.needsRescan = true
          self.measuringPaths = []
          self.scanTask = nil
          self.message = String(localized: "Scan stopped before review was complete. Scan again.")
        }
        return
      }
      for app in inventory.applications {
        if Task.isCancelled { break }
        let status = await running.isRunning(bundleID: app.bundleID)
        await MainActor.run {
          guard self.generation == id else { return }
          if status == true { self.runningIDs.insert(app.bundleID) }
          if status == nil { self.runningUnknownIDs.insert(app.bundleID) }
          self.runningCheckedIDs.insert(app.bundleID)
        }
      }
      await MainActor.run {
        guard self.generation == id else { return }
        self.busy = false
        self.scanTask = nil
      }
    }
  }

  func cancelScan() {
    guard busy else { return }
    generation = UUID()
    scanTask?.cancel()
    scanTask = nil
    busy = false
    measuringPaths = []
    needsRescan = true
    packageSelected = false
    selectedDataPath = nil
    message = String(localized: "Scan cancelled")
  }

  func select(_ path: String) {
    guard !needsRescan else { return }
    selectedPath = path
    packageSelected = false
    selectedDataPath = nil
    message = nil
  }

  func select(_ path: String, actions: ActionStore) {
    invalidatePreparation(actions: actions)
    select(path)
  }

  func togglePackage(actions: ActionStore) {
    invalidatePreparation(actions: actions)
    packageSelected = false
  }

  func toggleData(_ path: String, actions: ActionStore) {
    guard !busy, !needsRescan else { return }
    invalidatePreparation(actions: actions)
    selectedDataPath = selectedDataPath == path ? nil : path
  }

  func deactivate(actions: ActionStore) {
    cancelScan()
    invalidatePreparation(actions: actions, keepPresentedPlanID: actions.busy)
  }

  func observeResult(actions: ActionStore) {
    guard let presentedPlanID, actions.result?.planID == presentedPlanID,
      !needsRescan
    else { return }
    invalidatePreparation(actions: actions, keepPresentedPlanID: true)
    packageSelected = false
    selectedDataPath = nil
    needsRescan = true
    message = String(localized: "Action finished. Scan again before another choice.")
  }

  private func invalidatePreparation(
    actions: ActionStore? = nil, keepPresentedPlanID: Bool = false
  ) {
    preparationGeneration = UUID()
    preparationTask?.cancel()
    preparationTask = nil
    preparing = false
    let pendingMatches = actions?.pending?.id == presentedPlanID && presentedPlanID != nil
    if pendingMatches { actions?.pending = nil }
    if !keepPresentedPlanID || pendingMatches { presentedPlanID = nil }
  }

  func prepareSelectedData(actions: ActionStore) async {
    guard !busy, !preparing, !needsRescan, !actions.busy, !packageSelected,
      let report = selectedReport, let bundleID = report.bundleID,
      let dataPath = selectedDataPath,
      let candidate = report.related.first(where: { $0.path == dataPath }),
      candidate.classification == .installed, candidate.snapshot != nil,
      inventoryComplete, runningCheckedIDs.contains(bundleID),
      !runningIDs.contains(bundleID), !runningUnknownIDs.contains(bundleID),
      reports.filter({
        $0.bundleID?.lowercased(with: Locale(identifier: "en_US_POSIX"))
          == bundleID.lowercased(with: Locale(identifier: "en_US_POSIX"))
      }).count == 1
    else {
      message = String(localized: "Select one eligible data item")
      return
    }
    let id = UUID()
    preparationGeneration = id
    preparing = true
    defer {
      if preparationGeneration == id {
        preparing = false
        preparationTask = nil
      }
    }
    do {
      let task = Task { @concurrent in
        try await planBuilder(report, candidate)
      }
      preparationTask = task
      let plan = try await task.value
      guard preparationGeneration == id, selectedPath == report.path,
        selectedDataPath == dataPath, !packageSelected, !task.isCancelled,
        !actions.busy
      else { return }
      let node = candidate.snapshot?.nodes.first { $0.id == plan.items[0].id }
      actions.present(
        plan: plan,
        items: [
          ActionItemSummary(
            id: plan.items[0].id,
            label: URL(fileURLWithPath: dataPath).lastPathComponent,
            path: dataPath,
            reason: String(
              localized: "Selected app data. Preferences and support files may contain personal settings or documents."),
            logicalBytes: node?.logical.completeTotal,
            allocatedBytes: node?.allocated.completeTotal)
        ])
      presentedPlanID = plan.id
      message = nil
    } catch {
      if preparationGeneration == id {
        message = String(localized: "Could not prepare app data. Scan again.") + " " + String(describing: error)
      }
    }
  }
}
