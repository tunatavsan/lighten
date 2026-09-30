import Darwin
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
  @ObservationIgnored private let appPlanBuilder: @Sendable (String) async -> Result<ActionPlan, PlanRejections>
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
      ApplicationDiscovery(related: .system).events()
    },
    planBuilder:
      @escaping @Sendable (ApplicationReport, RelatedDataCandidate) async throws -> ActionPlan = {
        report, candidate in
        guard let bundleID = report.bundleID,
          let app = RelatedDataService.system.inventory().applications.first(where: {
            $0.path == report.path && $0.bundleID == bundleID
          })
        else { throw RelatedFailure.ambiguousOwner }
        return try RelatedDataService.system.planInstalled(app: app, candidate: candidate)
      },
    appPlanBuilder: @escaping @Sendable (String) async -> Result<ActionPlan, PlanRejections> = {
      path in
      await Task.detached { () -> Result<ActionPlan, PlanRejections> in
        do throws(PlanRejections) {
          guard let identity = try? DescriptorFileSystem.identity(at: path) else {
            throw PlanRejections(rejections: [PlanRejection(.unavailable, path: path)])
          }
          return .success(
            try PlanService().makeSpacePlan(
              selections: [
                PlanService.Selection(path: path, device: identity.device, inode: identity.inode)
              ],
              scanRootPath: "", runID: UUID()))
        } catch {
          return .failure(error)
        }
      }.value
    }
  ) {
    self.running = running
    self.appPlanBuilder = appPlanBuilder
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
          case .orphans: break
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
    guard let report = selectedReport, packageUnavailableReason(report) == nil else {
      packageSelected = false
      return
    }
    packageSelected.toggle()
  }

  /// Why the whole app cannot be moved to the Trash, or nil when it can be selected.
  func packageUnavailableReason(_ report: ApplicationReport) -> String? {
    if busy { return String(localized: "Review is available after the scan") }
    if needsRescan { return String(localized: "Scan again to review data") }
    if let target = report.linkTarget {
      return
        "\(String(localized: "This is a link to an app stored elsewhere. It is shown for identification only.")) \(target)"
    }
    guard let bundleID = report.bundleID else {
      return String(localized: "App identity unavailable")
    }
    if bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame {
      return String(localized: "Lighten does not remove itself.")
    }
    if runningIDs.contains(bundleID) {
      return String(localized: "The app is running. Quit it first.")
    }
    if runningUnknownIDs.contains(bundleID) || !runningCheckedIDs.contains(bundleID) {
      return String(localized: "Whether the app is running is unknown.")
    }
    let parent = (report.path as NSString).deletingLastPathComponent
    if Darwin.access(parent, W_OK) != 0 || Darwin.access(report.path, W_OK) != 0 {
      return String(
        localized: "Administrator permission is needed. Use Show in Finder to remove it there.")
    }
    return nil
  }

  func toggleData(_ path: String, actions: ActionStore) {
    guard !busy, !needsRescan else { return }
    invalidatePreparation(actions: actions)
    selectedDataPath = selectedDataPath == path ? nil : path
  }

  /// Leaving the screen keeps a running scan going; only prepared plans expire.
  func deactivate(actions: ActionStore) {
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
    guard !busy, !preparing, !needsRescan, !actions.busy, let report = selectedReport,
      packageSelected || selectedDataPath != nil
    else {
      message = String(localized: "Select one eligible data item")
      return
    }
    var candidate: RelatedDataCandidate?
    if let dataPath = selectedDataPath {
      guard let bundleID = report.bundleID,
        let found = report.related.first(where: { $0.path == dataPath }),
        found.classification == .installed, found.snapshot != nil,
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
      candidate = found
    }
    if packageSelected, let reason = packageUnavailableReason(report) {
      message = reason
      return
    }
    let includePackage = packageSelected
    let dataPath = selectedDataPath
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
      let planBuilder = self.planBuilder
      let appPlanBuilder = self.appPlanBuilder
      let chosen = candidate
      let task = Task { @concurrent () throws -> ActionPlan in
        // Data first: its proof requires the owner app to still be installed.
        var plans: [ActionPlan] = []
        if let chosen { plans.append(try await planBuilder(report, chosen)) }
        if includePackage {
          switch await appPlanBuilder(report.path) {
          case .success(let appPlan): plans.append(appPlan)
          case .failure(let refused): throw refused
          }
        }
        if plans.count == 1 { return plans[0] }
        return ActionPlan(
          snapshotRunID: plans[0].snapshotRunID, kind: .trash, items: plans.flatMap(\.items))
      }
      preparationTask = task
      let plan = try await task.value
      guard preparationGeneration == id, selectedPath == report.path,
        selectedDataPath == dataPath, packageSelected == includePackage, !task.isCancelled,
        !actions.busy
      else { return }
      if includePackage {
        guard let appItem = plan.items.first(where: { $0.policy == .wholeBundle }),
          let bundleID = appItem.applicationBundleID, bundleID == report.bundleID
        else {
          message = SpaceText.rejection(PlanRejection(.changedSinceScan, path: report.path))
          return
        }
        for id in [bundleID] + (appItem.nestedApplicationIDs ?? [])
        where await running.isRunning(bundleID: id) != false {
          message = String(localized: "The app is running. Quit it first.")
          return
        }
      }
      let summaries = plan.items.map { item -> ActionItemSummary in
        let isPackage = item.policy == .wholeBundle
        let node = candidate?.snapshot?.nodes.first { $0.id == item.id }
        let logical = PlanItemSize.measure(item).logical
        return ActionItemSummary(
          id: item.id,
          label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
          path: item.sourcePath,
          reason: isPackage
            ? String(localized: "Whole application package")
            : String(
              localized:
                "Selected app data. Preferences and support files may contain personal settings or documents."
            ),
          logicalBytes: isPackage ? logical : node?.logical.completeTotal ?? logical,
          allocatedBytes: node?.allocated.completeTotal)
      }
      actions.present(plan: plan, items: summaries)
      presentedPlanID = plan.id
      message = nil
    } catch let refused as PlanRejections {
      if preparationGeneration == id {
        message = refused.rejections.map(SpaceText.rejection).joined(separator: "\n")
      }
    } catch {
      if preparationGeneration == id {
        message =
          String(localized: "Could not prepare app data. Scan again.") + " "
          + FailureText.describe(error)
      }
    }
  }
}
