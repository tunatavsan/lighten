import Darwin
import Foundation
import LightenKit
import Observation

@MainActor @Observable
final class AppsStore {
  struct PictureOpeningTiming: Sendable {
    let requestedAt: ContinuousClock.Instant
    let loadStartedAt: ContinuousClock.Instant
    let loadFinishedAt: ContinuousClock.Instant
    let publishedAt: ContinuousClock.Instant
  }

  @ObservationIgnored private(set) var pictureOpeningTiming: PictureOpeningTiming?
  @ObservationIgnored private let events: @Sendable () -> AsyncStream<ApplicationDiscovery.Event>
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var preparationTask: Task<ActionPlan, Error>?
  @ObservationIgnored private var preparationGeneration = UUID()
  @ObservationIgnored private let running: any RunningApplicationSource
  @ObservationIgnored private let pictures: ResultPictureStore
  @ObservationIgnored private var opened = false
  var pictureRows: [AppsPicture.Row] = []
  var pictureObservedAt: Date?
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
  var selectedDataPaths: Set<String> = []
  var selectedDataPath: String? {
    get { selectedDataPaths.sorted().first }
    set { selectedDataPaths = newValue.map { [$0] } ?? [] }
  }
  var runningIDs: Set<String> = []
  var runningUnknownIDs: Set<String> = []
  var runningCheckedIDs: Set<String> = []
  var message: String?
  var presentedPlanID: UUID?
  var orphanCandidates: [RelatedDataCandidate] = []
  var selectedOrphanPaths: Set<String> = []
  var dropping = false
  @ObservationIgnored private var dropGeneration = UUID()
  @ObservationIgnored private var reviewedDropPath: String?
  @ObservationIgnored private var presentedPaths: [UUID: String] = [:]
  @ObservationIgnored private var observedResultID: UUID?
  @ObservationIgnored private let uninstallPlanBuilder:
    @Sendable (ApplicationReport, [RelatedDataCandidate], Bool) async throws -> ActionPlan
  @ObservationIgnored private let orphanPlanBuilder: @Sendable ([RelatedDataCandidate]) async throws -> ActionPlan
  @ObservationIgnored private let droppedReport: @Sendable (String) async -> ApplicationReport?

  init(
    pictures: ResultPictureStore = ResultPictureStore(),
    uninstallPlanBuilder: (@Sendable (ApplicationReport, [RelatedDataCandidate], Bool) async throws -> ActionPlan)? =
      nil,
    orphanPlanBuilder: @escaping @Sendable ([RelatedDataCandidate]) async throws -> ActionPlan = { candidates in
      let service = RelatedDataService.system
      let plans = try candidates.map { try service.plan(candidate: $0) }
      guard let first = plans.first else { throw PlanFailure.emptySelection }
      return ActionPlan(snapshotRunID: first.snapshotRunID, kind: .trash, items: plans.flatMap(\.items))
    },
    droppedReport: @escaping @Sendable (String) async -> ApplicationReport? = {
      await ApplicationDiscovery(related: .system).report(path: $0)
    },
    running: any RunningApplicationSource = MacOSRunningApplicationSource(),
    events: @escaping @Sendable () -> AsyncStream<ApplicationDiscovery.Event> = {
      ApplicationDiscovery(related: .system).events()
    },
    planBuilder: (@Sendable (ApplicationReport, RelatedDataCandidate) async throws -> ActionPlan)? = nil,
    appPlanBuilder: @escaping @Sendable (String) async -> Result<ActionPlan, PlanRejections> = { path in
      await Task.detached(priority: .userInitiated) { () -> Result<ActionPlan, PlanRejections> in
        do throws(PlanRejections) {
          guard let identity = try? DescriptorFileSystem.identity(at: path) else {
            throw PlanRejections(rejections: [PlanRejection(.unavailable, path: path)])
          }
          return .success(
            try PlanService().makeSpacePlan(
              selections: [PlanService.Selection(path: path, device: identity.device, inode: identity.inode)],
              scanRootPath: "", runID: UUID()))
        } catch {
          return .failure(error)
        }
      }.value
    }
  ) {
    self.pictures = pictures
    self.running = running
    self.events = events
    self.orphanPlanBuilder = orphanPlanBuilder
    self.droppedReport = droppedReport
    self.uninstallPlanBuilder =
      uninstallPlanBuilder ?? { report, candidates, includePackage in
        if let planBuilder {
          let plans = try await candidates.asyncPlans(report: report, builder: planBuilder)
          if plans.count == 1 && !includePackage { return plans[0] }
          var items = plans.flatMap(\.items)
          if includePackage {
            switch await appPlanBuilder(report.path) {
            case .success(let plan): items += plan.items
            case .failure(let refused): throw refused
            }
          }
          return ActionPlan(snapshotRunID: plans.first?.snapshotRunID ?? UUID(), kind: .trash, items: items)
        }
        return try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .userInitiated).async {
            do {
              let service = RelatedDataService.system
              guard let id = report.bundleID,
                let app = service.application(at: report.path), app.bundleID == id
              else { throw RelatedFailure.ambiguousOwner }
              if includePackage {
                continuation.resume(returning: try service.planUninstall(app: app, selectedRelated: candidates))
                return
              }
              let plans = try candidates.map { try service.planInstalled(app: app, candidate: $0) }
              guard let first = plans.first else { throw PlanFailure.emptySelection }
              continuation.resume(
                returning: ActionPlan(snapshotRunID: first.snapshotRunID, kind: .trash, items: plans.flatMap(\.items)))
            } catch { continuation.resume(throwing: error) }
          }
        }
      }
  }

  var selectedReport: ApplicationReport? { reports.first { $0.path == selectedPath } }

  /// Restore display fields first, then obtain independent fresh scan authority.
  func open(actions: ActionStore) {
    guard !opened else { return }
    opened = true
    let requestedAt = ContinuousClock.now
    let openingGeneration = generation
    let pictures = self.pictures
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let loadStartedAt = ContinuousClock.now
      let picture = pictures.load(AppsPicture.self, named: "apps")
      let loadFinishedAt = ContinuousClock.now
      Task(priority: .userInitiated) { @MainActor [weak self] in
        guard let self, self.generation == openingGeneration else { return }
        if self.reports.isEmpty, !self.busy, let picture {
          self.pictureRows = picture.content.rows
          self.pictureObservedAt = picture.observedAt
          self.needsRescan = true
          self.pictureOpeningTiming = PictureOpeningTiming(
            requestedAt: requestedAt, loadStartedAt: loadStartedAt, loadFinishedAt: loadFinishedAt, publishedAt: .now)
        }
        if self.scannedAt == nil, !self.busy { self.startScan(actions: actions) }
      }
    }
  }

  func startScan(actions: ActionStore) {
    guard !busy else { return }
    invalidatePreparation(actions: actions)
    reviewedDropPath = nil
    let id = UUID()
    generation = id
    busy = true
    reports = []
    orphanCandidates = []
    selectedOrphanPaths = []
    measuringPaths = []
    measuredCount = 0
    inventoryComplete = false
    selectedPath = nil
    packageSelected = false
    selectedDataPaths = []
    runningIDs = []
    runningUnknownIDs = []
    runningCheckedIDs = []
    scannedAt = nil
    message = nil
    needsRescan = false
    let events = self.events
    scanTask = Task(priority: .userInitiated) { @concurrent in
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
          case .orphans(let candidates):
            self.orphanCandidates = candidates
          case .completed(let inventory, let reports):
            self.reports = reports
            self.measuringPaths = []
            self.measuredCount = reports.count
            self.inventoryComplete = inventory.complete
            self.scannedAt = Date()
            self.pictureRows = []
            self.pictureObservedAt = nil
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
      let picture = await MainActor.run {
        ResultPicture(
          observedAt: self.scannedAt ?? Date(),
          content: AppsPicture(
            reports: self.reports, inventoryComplete: self.inventoryComplete))
      }
      guard !Task.isCancelled else { return }
      try? self.pictures.save(picture, named: "apps")
      await MainActor.run {
        guard self.generation == id, !Task.isCancelled else { return }
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
    selectedDataPaths = []
    message = String(localized: "Scan cancelled")
  }

  func select(_ path: String) {
    guard !needsRescan, pictureRows.isEmpty, !dropping else { return }
    selectedPath = path
    packageSelected = false
    selectedDataPaths = []
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
    if packageSelected {
      selectedDataPaths.formUnion(
        report.related.filter { $0.defaultSelected && canSelect($0, app: report) }.map(\.path))
    }
  }

  /// Why the whole app cannot be moved to the Trash, or nil when it can be selected.
  func packageUnavailableReason(_ report: ApplicationReport) -> String? {
    if busy { return String(localized: "Review is available after the scan") }
    if needsRescan { return String(localized: "Scan again to review data") }
    if let target = report.linkTarget {
      return
        "\(String(localized: "This is a link to an app stored elsewhere. It is shown for identification only.")) \(target)"
    }
    guard let bundleID = report.bundleID else { return String(localized: "App identity unavailable") }
    if bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame {
      return String(localized: "Lighten does not remove itself.")
    }
    if runningIDs.contains(bundleID) { return String(localized: "The app is running. Quit it first.") }
    if runningUnknownIDs.contains(bundleID) || !runningCheckedIDs.contains(bundleID) {
      return String(localized: "Whether the app is running is unknown.")
    }
    let parent = (report.path as NSString).deletingLastPathComponent
    var metadata = stat()
    let foreignOwner = Darwin.lstat(report.path, &metadata) == 0 && metadata.st_uid != geteuid()
    if foreignOwner || Darwin.access(parent, W_OK) != 0 || Darwin.access(report.path, W_OK) != 0 {
      return String(localized: "Administrator permission is needed. Use Show in Finder to remove it there.")
    }
    return nil
  }

  func toggleData(_ path: String, actions: ActionStore) {
    guard !busy, !needsRescan else { return }
    invalidatePreparation(actions: actions)
    guard let app = selectedReport, let candidate = app.related.first(where: { $0.path == path }),
      canSelect(candidate, app: app)
    else { return }
    if selectedDataPaths.contains(path) { selectedDataPaths.remove(path) } else { selectedDataPaths.insert(path) }
  }

  /// Leaving the screen keeps a running scan going; only prepared plans expire.
  func deactivate(actions: ActionStore) {
    dropGeneration = UUID()
    dropping = false
    invalidatePreparation(actions: actions, keepPresentedPlanID: actions.busy)
  }

  func observeResult(actions: ActionStore) {
    guard let presentedPlanID, let result = actions.result, result.planID == presentedPlanID,
      observedResultID != result.planID
    else { return }
    observedResultID = result.planID
    invalidatePreparation(actions: actions, keepPresentedPlanID: true)
    let moved = Set(result.items.filter { $0.outcome == .applied }.compactMap { presentedPaths[$0.itemID] })
    let retainedData = reports.filter { moved.contains($0.path) }.flatMap { report in
      report.related.filter { !moved.contains($0.path) }
    }
    orphanCandidates += retainedData.filter { candidate in !orphanCandidates.contains { $0.path == candidate.path } }
    reports = reports.filter { !moved.contains($0.path) }.map { report in
      var refreshed = report
      refreshed.related.removeAll { moved.contains($0.path) }
      return refreshed
    }
    orphanCandidates.removeAll { moved.contains($0.path) }
    selectedDataPaths = []
    selectedOrphanPaths = []
    packageSelected = false
    if let selectedPath, moved.contains(selectedPath) { self.selectedPath = nil }
    message = nil
  }

  func canSelect(_ candidate: RelatedDataCandidate, app: ApplicationReport) -> Bool {
    guard candidate.canSelect, candidate.classification == .installed,
      inventoryComplete || reviewedDropPath == app.path, !busy, !needsRescan, pictureRows.isEmpty,
      let id = app.bundleID,
      reports.filter({ $0.bundleID?.caseInsensitiveCompare(id) == .orderedSame }).count == 1,
      id.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame,
      runningCheckedIDs.contains(id), !runningIDs.contains(id), !runningUnknownIDs.contains(id)
    else { return false }
    return true
  }

  func toggleOrphan(_ path: String, actions: ActionStore) {
    guard !busy, !needsRescan, !dropping, pictureRows.isEmpty,
      orphanCandidates.contains(where: { $0.path == path && $0.canSelect && $0.classification != .installed })
    else { return }
    invalidatePreparation(actions: actions)
    if selectedOrphanPaths.contains(path) { selectedOrphanPaths.remove(path) } else { selectedOrphanPaths.insert(path) }
  }

  func prepareOrphans(actions: ActionStore) async {
    guard !busy, !preparing, !needsRescan, !actions.busy, pictureRows.isEmpty else { return }
    let candidates = orphanCandidates.filter {
      selectedOrphanPaths.contains($0.path) && $0.canSelect && $0.classification != .installed
    }
    guard !candidates.isEmpty else { return }
    let paths = selectedOrphanPaths
    let builder = orphanPlanBuilder
    await prepare(
      actions: actions, stillSelected: { self.selectedOrphanPaths == paths },
      builder: {
        try await builder(candidates)
      })
  }

  func acceptDrop(_ urls: [URL], actions: ActionStore) async {
    guard urls.count == 1, let url = urls.first, url.isFileURL,
      url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    else {
      message = String(localized: "Drop one application (.app) to review removal.")
      return
    }
    guard !preparing, !dropping, !actions.busy else {
      message = String(localized: "Wait for the current review or scan to finish.")
      return
    }
    if busy { cancelScan() }
    invalidatePreparation(actions: actions)
    let id = UUID()
    dropGeneration = id
    dropping = true
    defer { if dropGeneration == id { dropping = false } }
    let discovered = await droppedReport(url.path)
    guard dropGeneration == id else { return }
    guard let report = discovered else {
      message = String(localized: "This application could not be identified safely.")
      return
    }
    if let index = reports.firstIndex(where: { $0.path == report.path }) {
      reports[index] = report
    } else {
      reports.append(report)
    }
    pictureRows = []
    pictureObservedAt = nil
    needsRescan = false
    selectedPath = report.path
    reviewedDropPath = report.path
    selectedDataPaths = []
    packageSelected = false
    guard let bundleID = report.bundleID else { return }
    let status = await running.isRunning(bundleID: bundleID)
    guard dropGeneration == id else { return }
    runningCheckedIDs.insert(bundleID)
    runningIDs.remove(bundleID)
    runningUnknownIDs.remove(bundleID)
    if status == true { runningIDs.insert(bundleID) }
    if status == nil { runningUnknownIDs.insert(bundleID) }
    guard let reason = packageUnavailableReason(report) else {
      packageSelected = true
      selectedDataPaths = Set(report.related.filter { $0.defaultSelected }.map(\.path))
      await prepareSelectedData(actions: actions)
      return
    }
    message = reason
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
    guard !busy, !preparing, !needsRescan, !actions.busy, pictureRows.isEmpty, let report = selectedReport,
      packageSelected || !selectedDataPaths.isEmpty
    else {
      message = String(localized: "Select the app or eligible related data")
      return
    }
    let candidates = report.related.filter { selectedDataPaths.contains($0.path) }
    guard candidates.count == selectedDataPaths.count,
      candidates.allSatisfy({ canSelect($0, app: report) })
    else {
      message = String(localized: "Some selected data is unavailable. Review the reasons before continuing.")
      return
    }
    if packageSelected, let reason = packageUnavailableReason(report) {
      message = reason
      return
    }
    let includePackage = packageSelected
    let dataPaths = selectedDataPaths
    let builder = uninstallPlanBuilder
    await prepare(
      actions: actions,
      stillSelected: {
        self.selectedPath == report.path && self.selectedDataPaths == dataPaths
          && self.packageSelected == includePackage
      },
      builder: {
        let plan = try await builder(report, candidates, includePackage)
        if includePackage {
          guard let package = plan.items.first(where: { $0.sourcePath == report.path && $0.policy == .wholeBundle }),
            package.applicationBundleID == report.bundleID
          else { throw PlanRejections(rejections: [PlanRejection(.changedSinceScan, path: report.path)]) }
        }
        return plan
      })
  }

  private func prepare(
    actions: ActionStore, stillSelected: @escaping @MainActor () -> Bool,
    builder: @escaping @Sendable () async throws -> ActionPlan
  ) async {
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
      let task = Task(priority: .userInitiated) { @concurrent () throws -> ActionPlan in try await builder() }
      preparationTask = task
      let plan = try await task.value
      guard preparationGeneration == id, stillSelected(), !task.isCancelled, !actions.busy else { return }
      for item in plan.items where item.policy == .wholeBundle {
        guard let bundleID = item.applicationBundleID else { throw PlanFailure.unsafeSelection }
        for bundle in [bundleID] + (item.nestedApplicationIDs ?? [])
        where await running.isRunning(bundleID: bundle) != false {
          guard preparationGeneration == id, stillSelected() else { return }
          message = String(localized: "The app is running. Quit it first.")
          return
        }
      }
      guard preparationGeneration == id, stillSelected(), !actions.busy else { return }
      let summaries = plan.items.map { item in
        let size = PlanItemSize.measure(item)
        return ActionItemSummary(
          id: item.id, label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
          path: item.sourcePath,
          reason: item.policy == .wholeBundle
            ? String(localized: "Whole application package")
            : String(
              localized: "Selected app data. Preferences and support files may contain personal settings or documents."),
          logicalBytes: size.logical, allocatedBytes: size.allocated)
      }
      actions.present(plan: plan, items: summaries)
      guard actions.pending?.id == plan.id else { return }
      presentedPaths = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.sourcePath) })
      presentedPlanID = plan.id
      observedResultID = nil
      message = nil
    } catch let refused as PlanRejections {
      if preparationGeneration == id { message = refused.rejections.map(SpaceText.rejection).joined(separator: "\n") }
    } catch {
      if preparationGeneration == id {
        message = String(localized: "Could not prepare app data. Scan again.") + " " + FailureText.describe(error)
      }
    }
  }
}

extension Array where Element == RelatedDataCandidate {
  fileprivate nonisolated func asyncPlans(
    report: ApplicationReport,
    builder: @Sendable (ApplicationReport, RelatedDataCandidate) async throws -> ActionPlan
  ) async throws -> [ActionPlan] {
    var plans: [ActionPlan] = []
    for candidate in self { plans.append(try await builder(report, candidate)) }
    return plans
  }
}
