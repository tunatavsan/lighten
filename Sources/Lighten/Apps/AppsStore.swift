import Darwin
import Foundation
import LightenKit
import Observation

@MainActor @Observable
final class AppsStore {
  typealias AvailableUninstallPlanBuilder =
    @Sendable (ApplicationReport, [RelatedDataCandidate], Bool) async throws ->
    RelatedDataService.AvailableUninstallPlan
  typealias ExplicitUninstallPlanBuilder =
    @Sendable (ApplicationReport, [RelatedDataCandidate], Bool, [RelatedDataCandidate]) async throws ->
    RelatedDataService.AvailableUninstallPlan
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
  @ObservationIgnored private var session: ApplicationScanSession?
  @ObservationIgnored private var selectedReviewTask: Task<Void, Never>?
  @ObservationIgnored private var selectedReviewToken = UUID()
  @ObservationIgnored private let selectedReview: SelectedReview?
  @ObservationIgnored private let relatedService: RelatedDataService
  @ObservationIgnored private let usesInjectedPlanner: Bool
  @ObservationIgnored private var relatedReviewedPaths: Set<String> = []
  @ObservationIgnored private var removedPaths: Set<String> = []
  @ObservationIgnored private var displayChanges: [UUID: ActionDisplayItem] = [:]
  @ObservationIgnored private var removedReports: [UUID: [ApplicationReport]] = [:]
  @ObservationIgnored private var removedData: [UUID: [String: [RelatedDataCandidate]]] = [:]
  @ObservationIgnored private var removedOrphans: [UUID: [RelatedDataCandidate]] = [:]
  private(set) var displayRevision = 0
  private(set) var ownershipPendingPaths: Set<String> = []
  private(set) var selectedReviewPending = false
  private(set) var backgroundStartedAt: ContinuousClock.Instant?
  private(set) var inventoryPublishedAt: ContinuousClock.Instant?
  private(set) var backgroundFinishedAt: ContinuousClock.Instant?
  private(set) var backgroundCancelledAt: ContinuousClock.Instant?
  private(set) var selectedReviewRequestedAt: ContinuousClock.Instant?
  private(set) var selectedReviewPublishedAt: ContinuousClock.Instant?
  private(set) var selectedPackageReadyAt: ContinuousClock.Instant?
  private(set) var selectedReviewReadyAt: ContinuousClock.Instant?

  typealias SelectedReview =
    @Sendable (String, (@Sendable (ApplicationRelatedReview) -> Void)?) async throws -> ApplicationRelatedReview?
  @ObservationIgnored private var cancellationRequestedAt: ContinuousClock.Instant?
  private(set) var cancellationLayoutMilliseconds: Double?
  @ObservationIgnored private var preparationTask: Task<RelatedDataService.AvailableUninstallPlan, Error>?
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
  var selectedDataPaths: Set<String> = [] {
    didSet {
      explicitlySelectedUnproven = explicitlySelectedUnproven.filter { selectedDataPaths.contains($0.key) }
    }
  }
  @ObservationIgnored private weak var preparedActions: ActionStore?
  @ObservationIgnored private var explicitlySelectedUnproven: [String: RelatedDataCandidate] = [:]
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
  struct PackageItemResult: Identifiable {
    let id: UUID
    let sourcePath: String
    let isLink: Bool
    let outcome: ActionOutcome
    let detail: String?
  }
  private(set) var packageItemResults: [PackageItemResult] = []
  private(set) var ownershipRefusalEvidence: [RelatedOwnershipRefusalEvidence] = []
  @ObservationIgnored private var presentedPackages: [String: (physical: UUID, link: UUID?)] = [:]
  @ObservationIgnored private var presentedPackageItems: [PlanItem] = []
  @ObservationIgnored private var incompletePackagePaths: Set<String> = []
  @ObservationIgnored private var navigationGeneration = UUID()
  @ObservationIgnored private var observedResultID: UUID?
  @ObservationIgnored private let uninstallPlanBuilder: AvailableUninstallPlanBuilder
  @ObservationIgnored private let explicitUninstallPlanBuilder: ExplicitUninstallPlanBuilder
  @ObservationIgnored private let orphanPlanBuilder: @Sendable ([RelatedDataCandidate]) async throws -> ActionPlan
  @ObservationIgnored private let droppedReport: @Sendable (String) async -> ApplicationReport?

  init(
    pictures: ResultPictureStore = ResultPictureStore(),
    uninstallPlanBuilder: (@Sendable (ApplicationReport, [RelatedDataCandidate], Bool) async throws -> ActionPlan)? =
      nil,
    availableUninstallPlanBuilder: AvailableUninstallPlanBuilder? = nil,
    explicitUninstallPlanBuilder: ExplicitUninstallPlanBuilder? = nil,
    relatedService: RelatedDataService = .system,
    selectedReview: SelectedReview? = nil,
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
    self.selectedReview = selectedReview
    self.relatedService = relatedService
    self.usesInjectedPlanner =
      availableUninstallPlanBuilder != nil || explicitUninstallPlanBuilder != nil
      || uninstallPlanBuilder != nil || planBuilder != nil
    self.pictures = pictures
    self.running = running
    self.events = events
    self.orphanPlanBuilder = orphanPlanBuilder
    self.droppedReport = droppedReport
    let standardBuilder: AvailableUninstallPlanBuilder =
      availableUninstallPlanBuilder ?? { report, candidates, includePackage in
        if let uninstallPlanBuilder {
          return RelatedDataService.AvailableUninstallPlan(
            plan: try await uninstallPlanBuilder(report, candidates, includePackage), rejections: [])
        }
        if let planBuilder {
          let plans = try await candidates.asyncPlans(report: report, builder: planBuilder)
          if plans.count == 1 && !includePackage {
            return RelatedDataService.AvailableUninstallPlan(plan: plans[0], rejections: [])
          }
          var items = plans.flatMap(\.items)
          if includePackage {
            switch await appPlanBuilder(report.path) {
            case .success(let plan): items += plan.items
            case .failure(let refused): throw refused
            }
          }
          return RelatedDataService.AvailableUninstallPlan(
            plan: ActionPlan(snapshotRunID: plans.first?.snapshotRunID ?? UUID(), kind: .trash, items: items),
            rejections: [])
        }
        let service = relatedService
        return await service.makeAvailableUninstallPlan(
          path: report.path, expectedBundleID: report.bundleID,
          selectedRelated: candidates, includePackage: includePackage)
      }
    self.uninstallPlanBuilder = standardBuilder
    self.explicitUninstallPlanBuilder =
      explicitUninstallPlanBuilder ?? { report, candidates, includePackage, manual in
        if manual.isEmpty { return try await standardBuilder(report, candidates, includePackage) }
        return await relatedService.makeAvailableUninstallPlan(
          path: report.path, expectedBundleID: report.bundleID, selectedRelated: candidates,
          includePackage: includePackage, selectedUnprovenRelated: manual)
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
    cancelSelectedReview()
    let previousSession = session
    session = nil
    if let previousSession { Task { await previousSession.cancel() } }
    relatedReviewedPaths = []
    removedPaths = []
    incompletePackagePaths = []
    ownershipRefusalEvidence = []
    navigationGeneration = UUID()
    ownershipPendingPaths = []
    backgroundStartedAt = .now
    inventoryPublishedAt = nil
    backgroundFinishedAt = nil
    backgroundCancelledAt = nil
    let id = UUID()
    generation = id
    cancellationRequestedAt = nil
    cancellationLayoutMilliseconds = nil
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
    explicitlySelectedUnproven = [:]
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
          case .session(let session):
            self.session = session
          case .inventory(_, let metadata):
            self.reports = metadata.filter { !self.displayRemoved($0) }
            self.measuringPaths = Set(metadata.map(\.path))
            self.inventoryPublishedAt = .now
            self.pictureRows = []
            self.pictureObservedAt = nil
          case .related(let path, let candidates, let ownershipPending):
            self.publishRelated(path: path, candidates: candidates, ownershipPending: ownershipPending)
          case .ownershipReady(let inventory):
            self.inventoryComplete = inventory.complete
          case .measured(let batch):
            for report in batch {
              if let index = self.reports.firstIndex(where: { $0.path == report.path }) {
                self.reports[index] = self.mergingMeasurement(report, with: self.reports[index])
                self.measuringPaths.remove(report.path)
                self.measuredCount += 1
              }
            }
          case .orphans(let candidates):
            self.orphanCandidates = candidates.filter { !self.displayRemoved($0) }
          case .completed(let inventory, let reports):
            self.reports = reports.filter { !self.displayRemoved($0) }.map { report in
              self.reports.first(where: { $0.path == report.path }).map {
                self.mergingMeasurement(report, with: $0)
              } ?? report
            }
            self.backgroundFinishedAt = .now
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
      guard finishedInventory != nil, !Task.isCancelled else {
        await MainActor.run {
          guard self.generation == id, !Task.isCancelled else { return }
          self.cancelSelectedReview()
          self.backgroundCancelledAt = .now
          let endedSession = self.session
          self.session = nil
          if let endedSession { Task { await endedSession.cancel() } }
          self.busy = false
          self.needsRescan = true
          self.measuringPaths = []
          self.scanTask = nil
          self.message = String(localized: "Scan stopped before review was complete. Scan again.")
        }
        return
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
    cancellationRequestedAt = .now
    cancellationLayoutMilliseconds = nil
    backgroundCancelledAt = .now
    cancelSelectedReview()
    let cancelledSession = session
    session = nil
    if let cancelledSession { Task { await cancelledSession.cancel() } }
    generation = UUID()
    scanTask?.cancel()
    scanTask = nil
    busy = false
    measuringPaths = []
    needsRescan = true
    invalidatePreparation()
    packageSelected = false
    selectedDataPaths = []
    explicitlySelectedUnproven = [:]
    message = String(localized: "Scan cancelled")
  }

  /// Called when the view has laid out the idle state after cancellation.
  func scanDidLayout() {
    guard !busy, let requested = cancellationRequestedAt else { return }
    let elapsed = requested.duration(to: .now).components
    cancellationLayoutMilliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    cancellationRequestedAt = nil
  }

  func select(_ path: String) {
    guard !needsRescan, pictureRows.isEmpty, !dropping else { return }
    navigationGeneration = UUID()
    ownershipRefusalEvidence = []
    selectedPath = path
    packageSelected = false
    selectedDataPaths = []
    explicitlySelectedUnproven = [:]
    message = nil
    requestSelectedReview(path)
  }

  func select(_ path: String, actions: ActionStore) {
    invalidatePreparation(actions: actions)
    select(path)
  }

  func waitForSelectedReview() async { await selectedReviewTask?.value }

  private func cancelSelectedReview() {
    selectedReviewToken = UUID()
    selectedReviewTask?.cancel()
    selectedReviewTask = nil
    selectedReviewPending = false
  }

  private func requestSelectedReview(_ path: String) {
    cancelSelectedReview()
    // An absent identifier permits package review only; no fabricated owner joins.
    guard selectedReport?.bundleID != nil else { return }
    let activeSession = session
    let review = selectedReview
    // Legacy injected streams already carry fully reviewed reports.
    guard activeSession != nil || review != nil else { return }
    let token = UUID()
    selectedReviewToken = token
    let scanGeneration = generation
    selectedReviewRequestedAt = .now
    selectedPackageReadyAt = nil
    selectedReviewPublishedAt = nil
    selectedReviewReadyAt = nil
    selectedReviewPending = true
    let running = self.running
    let bundleID = selectedReport?.bundleID
    if let bundleID {
      runningCheckedIDs.remove(bundleID)
      runningIDs.remove(bundleID)
      runningUnknownIDs.remove(bundleID)
    }
    selectedReviewTask = Task(priority: .userInitiated) { @concurrent in
      if let bundleID {
        let status = await running.isRunning(bundleID: bundleID)
        await MainActor.run {
          guard self.acceptsReview(path: path, token: token, generation: scanGeneration) else { return }
          self.runningCheckedIDs.insert(bundleID)
          if status == false { self.selectedPackageReadyAt = .now }
          if status == true { self.runningIDs.insert(bundleID) }
          if status == nil { self.runningUnknownIDs.insert(bundleID) }
        }
      }
      guard !Task.isCancelled else { return }
      let progress: @Sendable (ApplicationRelatedReview) -> Void = { update in
        Task { @MainActor in
          guard self.acceptsReview(path: path, token: token, generation: scanGeneration) else { return }
          self.publishReview(update, path: path)
        }
      }
      do {
        let result: ApplicationRelatedReview?
        if let review {
          result = try await review(path, progress)
        } else if let activeSession {
          result = try await activeSession.relatedReview(path: path, progress: progress)
        } else {
          result = nil
        }
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard self.acceptsReview(path: path, token: token, generation: scanGeneration) else { return }
          if let result { self.publishReview(result, path: path, ready: true) }
          self.selectedReviewPending = false
          self.selectedReviewTask = nil
        }
      } catch {
        await MainActor.run {
          guard self.acceptsReview(path: path, token: token, generation: scanGeneration) else { return }
          self.selectedReviewPending = false
          self.selectedReviewTask = nil
          self.message = FailureText.describe(error)
        }
      }
    }
  }

  private func acceptsReview(path: String, token: UUID, generation: UUID) -> Bool {
    self.generation == generation && selectedReviewToken == token && selectedPath == path
      && !needsRescan && pictureRows.isEmpty
  }

  private func publishReview(_ review: ApplicationRelatedReview, path: String, ready: Bool = false) {
    guard let old = reports.first(where: { $0.path == path }),
      review.application.path == path || review.application.path == old.linkTarget,
      old.bundleID == review.application.bundleID
    else {
      message = String(localized: "The application changed. Refresh Apps before reviewing it.")
      return
    }
    publishRelated(
      path: path, candidates: review.candidates, ownershipPending: review.ownershipPending)
    if let index = reports.firstIndex(where: { $0.path == path }) {
      let current = reports[index]
      var updated = ApplicationReport(
        path: current.path, bundleID: current.bundleID, version: current.version,
        signerTeamID: review.signerTeamID ?? current.signerTeamID,
        logical: current.logical, allocated: current.allocated, knownItemCount: current.knownItemCount,
        partial: current.partial, related: current.related,
        manualUninstallerSuggested: current.manualUninstallerSuggested, linkTarget: current.linkTarget,
        displayRootIdentity: current.displayRootIdentity)
      updated.isIOSWrapper = current.isIOSWrapper
      reports[index] = updated
    }
    selectedReviewPublishedAt = selectedReviewPublishedAt ?? .now
    if ready { selectedReviewReadyAt = selectedReviewReadyAt ?? .now }
  }

  private func publishRelated(path: String, candidates: [RelatedDataCandidate], ownershipPending: Bool) {
    guard let index = reports.firstIndex(where: { $0.path == path }), !displayRemoved(reports[index]) else { return }
    let incoming = candidates.filter { !displayRemoved($0) }
    let incomingPaths = Set(incoming.map(\.path))
    reports[index].related =
      ownershipPending
      ? incoming + reports[index].related.filter { !incomingPaths.contains($0.path) && !displayRemoved($0) }
      : incoming
    if selectedPath == path {
      let invalidated = explicitlySelectedUnproven.keys.filter { selected in
        guard let original = explicitlySelectedUnproven[selected],
          let fresh = reports[index].related.first(where: { $0.path == selected })
        else { return true }
        return !Self.sameUnprovenObservation(original, fresh)
      }
      for selected in invalidated {
        selectedDataPaths.remove(selected)
        explicitlySelectedUnproven.removeValue(forKey: selected)
      }
      if !invalidated.isEmpty {
        invalidatePreparation(actions: preparedActions)
        message = String(localized: "An item you selected by name changed. Review it and select it again.")
      }
    }
    relatedReviewedPaths.insert(path)
    if ownershipPending { ownershipPendingPaths.insert(path) } else { ownershipPendingPaths.remove(path) }
  }

  private func mergingMeasurement(_ report: ApplicationReport, with current: ApplicationReport) -> ApplicationReport {
    var merged = ApplicationReport(
      path: report.path, bundleID: report.bundleID, version: report.version,
      signerTeamID: current.signerTeamID ?? report.signerTeamID,
      logical: report.logical, allocated: report.allocated, knownItemCount: report.knownItemCount,
      partial: report.partial,
      related: (relatedReviewedPaths.contains(report.path) ? current.related : report.related)
        .filter { !displayRemoved($0) },
      manualUninstallerSuggested: report.manualUninstallerSuggested, linkTarget: report.linkTarget,
      displayRootIdentity: report.displayRootIdentity)
    merged.isIOSWrapper = report.isIOSWrapper
    return merged
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
        report.related.filter {
          $0.classification != .unprovenNameOnly && $0.provenance?.kind != .configuredDirectory
            && $0.defaultSelected && canSelect($0, app: report)
        }.map(\.path))
    }
  }

  /// Why the whole app cannot be moved to the Trash, or nil when it can be selected.
  func packageUnavailableReason(_ report: ApplicationReport) -> String? {
    if needsRescan { return String(localized: "Scan again to review data") }

    if incompletePackagePaths.contains(report.path) {
      return String(
        localized: "This application removal is incomplete. Refresh Apps to review what remains.")
    }
    if let bundleID = report.bundleID {
      if bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame {
        return String(localized: "Lighten does not remove itself.")
      }
      if runningIDs.contains(bundleID) {
        return String(localized: "The app is running. Quit it first.")
      }
      if runningUnknownIDs.contains(bundleID) || !runningCheckedIDs.contains(bundleID) {
        return String(localized: "Whether the app is running is unknown.")
      }
    }
    // Identifierless selections still require the planner's fresh native executable check.
    let parent = (report.path as NSString).deletingLastPathComponent
    var metadata = stat()
    let foreignOwner = Darwin.lstat(report.path, &metadata) == 0 && metadata.st_uid != geteuid()
    if foreignOwner || Darwin.access(parent, W_OK) != 0 || Darwin.access(report.path, W_OK) != 0 {
      return String(localized: "Administrator permission is needed. Use Show in Finder to remove it there.")
    }
    return nil
  }

  func otherInstallationPaths(candidate: RelatedDataCandidate, app: ApplicationReport) -> [String] {
    let evidence =
      candidate.refusalEvidence
      + ownershipRefusalEvidence.filter { $0.candidatePath == candidate.path }
    return Array(
      Set(
        evidence.filter {
          $0.reason == .sharedInstalledOwners && Set($0.ownerPaths).count >= 2
        }.flatMap(\.ownerPaths))
    ).filter { $0 != (app.linkTarget ?? app.path) }.sorted()
  }

  /// Owner paths are navigation leads. Refresh the destination before offering selections.
  func openOtherInstallation(
    _ path: String, candidate: RelatedDataCandidate, app: ApplicationReport, actions: ActionStore
  ) async {
    guard !needsRescan, pictureRows.isEmpty, !dropping, !preparing, !actions.busy,
      otherInstallationPaths(candidate: candidate, app: app).contains(path)
    else { return }
    invalidatePreparation(actions: actions)
    let token = UUID()
    navigationGeneration = token
    let previousSelection = selectedPath
    guard let report = await droppedReport(path), report.path == path,
      navigationGeneration == token, selectedPath == previousSelection,
      !needsRescan, pictureRows.isEmpty, !actions.busy
    else { return }
    if let index = reports.firstIndex(where: { $0.path == path }) {
      reports[index] = report
    } else {
      reports.append(report)
    }
    incompletePackagePaths.remove(path)
    reviewedDropPath = path
    select(path, actions: actions)
  }

  func toggleData(_ path: String, actions: ActionStore) {
    guard !needsRescan else { return }
    invalidatePreparation(actions: actions)
    guard let app = selectedReport, let candidate = app.related.first(where: { $0.path == path }),
      canSelect(candidate, app: app)
    else { return }
    if selectedDataPaths.contains(path) {
      selectedDataPaths.remove(path)
      explicitlySelectedUnproven.removeValue(forKey: path)
    } else {
      selectedDataPaths.insert(path)
      if candidate.classification == .unprovenNameOnly { explicitlySelectedUnproven[path] = candidate }
    }
  }

  /// Leaving the screen keeps a running scan going; only prepared plans expire.
  func deactivate(actions: ActionStore) {
    dropGeneration = UUID()
    navigationGeneration = UUID()
    dropping = false
    invalidatePreparation(actions: actions, keepPresentedPlanID: actions.busy)
  }

  private func displayRemoved(path: String, identity: FileIdentity?) -> Bool {
    let observations = displayChanges.values.filter { $0.path == path }
    if !observations.isEmpty { return observations.contains { $0.matches(path: path, identity: identity) } }
    return removedPaths.contains(path)
  }

  private func displayRemoved(_ report: ApplicationReport) -> Bool {
    displayRemoved(path: report.linkTarget ?? report.path, identity: report.displayRootIdentity)
  }

  private func displayRemoved(_ candidate: RelatedDataCandidate) -> Bool {
    displayRemoved(
      path: candidate.path, identity: candidate.snapshot?.entries.first { $0.path == candidate.path }?.identity)
  }

  func applyDisplayChange(_ change: ActionDisplayChange) {
    for item in change.items {
      switch change.kind {
      case .applied:
        displayChanges[item.itemID] = item
        let matched = reports.filter { report in
          item.matches(path: report.linkTarget ?? report.path, identity: report.displayRootIdentity)
        }
        removedReports[item.itemID] = matched
        reports.removeAll { report in matched.contains { $0.path == report.path } }
        var data: [String: [RelatedDataCandidate]] = [:]
        for index in reports.indices {
          let matched = reports[index].related.filter { candidate in
            candidate.snapshot?.entries.contains { item.matches(path: $0.path, identity: $0.identity) } == true
              && (candidate.path == item.path || candidate.path.hasPrefix(item.path + "/"))
          }
          data[reports[index].path] = matched
          reports[index].related.removeAll { candidate in matched.contains { $0.path == candidate.path } }
        }
        removedData[item.itemID] = data
        let orphans = orphanCandidates.filter { candidate in
          candidate.snapshot?.entries.contains { item.matches(path: $0.path, identity: $0.identity) } == true
            && (candidate.path == item.path || candidate.path.hasPrefix(item.path + "/"))
        }
        removedOrphans[item.itemID] = orphans
        orphanCandidates.removeAll { candidate in orphans.contains { $0.path == candidate.path } }
        removedPaths.formUnion(matched.map(\.path))
        removedPaths.formUnion(data.values.flatMap { $0 }.map(\.path))
        selectedDataPaths.subtract(data.values.flatMap { $0 }.map(\.path))
        selectedOrphanPaths.subtract(orphans.map(\.path))
        if let selectedPath, matched.contains(where: { $0.path == selectedPath }) {
          self.selectedPath = nil
          packageSelected = false
        }
      case .restored:
        displayChanges.removeValue(forKey: item.itemID)
        for report in removedReports.removeValue(forKey: item.itemID) ?? [] {
          removedPaths.remove(report.path)
          if !reports.contains(where: { $0.path == report.path }) { reports.append(report) }
        }
        for (path, candidates) in removedData.removeValue(forKey: item.itemID) ?? [:] {
          guard let index = reports.firstIndex(where: { $0.path == path }) else { continue }
          for candidate in candidates {
            removedPaths.remove(candidate.path)
            if !reports[index].related.contains(where: { $0.path == candidate.path }) {
              reports[index].related.append(candidate)
            }
          }
        }
        for candidate in removedOrphans.removeValue(forKey: item.itemID) ?? [] {
          if !orphanCandidates.contains(where: { $0.path == candidate.path }) { orphanCandidates.append(candidate) }
        }
      }
    }
    displayRevision += 1
  }

  func observeResult(actions: ActionStore) {
    guard let presentedPlanID, let result = actions.result, result.planID == presentedPlanID,
      observedResultID != result.planID
    else { return }
    observedResultID = result.planID
    invalidatePreparation(actions: actions, keepPresentedPlanID: true)
    let moved = Set(
      result.items.filter { $0.outcome == .applied }.compactMap { presentedPaths[$0.itemID] })
    let results = Dictionary(uniqueKeysWithValues: result.items.map { ($0.itemID, $0) })
    packageItemResults = presentedPackageItems.compactMap { item in
      guard let outcome = results[item.id] else { return nil }
      return PackageItemResult(
        id: item.id, sourcePath: item.sourcePath,
        isLink: item.policy == .applicationLink, outcome: outcome.outcome, detail: outcome.detail)
    }
    var removedApplications: Set<String> = []
    for (path, pair) in presentedPackages {
      let physicalMoved = results[pair.physical]?.outcome == .applied
      let linkMoved = pair.link.map { results[$0]?.outcome == .applied } ?? true
      if physicalMoved && linkMoved {
        removedApplications.insert(path)
      } else if physicalMoved || (pair.link.map { results[$0]?.outcome == .applied } ?? false) {
        incompletePackagePaths.insert(path)
        if selectedPath == path { packageSelected = false }
      }
    }
    let removedRows = moved.subtracting(presentedPackages.keys).union(removedApplications)
    removedPaths.formUnion(moved.subtracting(incompletePackagePaths).union(removedApplications))
    let retainedData = reports.filter { removedRows.contains($0.path) }.flatMap { report in
      report.related.filter { !moved.contains($0.path) }
    }
    orphanCandidates += retainedData.filter { candidate in
      !orphanCandidates.contains { $0.path == candidate.path }
    }
    reports = reports.filter { !removedRows.contains($0.path) }.map { report in
      var refreshed = report
      refreshed.related.removeAll { moved.contains($0.path) }
      return refreshed
    }
    orphanCandidates.removeAll { moved.contains($0.path) }
    selectedDataPaths.subtract(moved)
    selectedOrphanPaths.subtract(moved)
    if !removedApplications.isEmpty { packageSelected = false }
    if let selectedPath, removedRows.contains(selectedPath) { self.selectedPath = nil }
    message = nil
  }

  func canSelect(_ candidate: RelatedDataCandidate, app: ApplicationReport) -> Bool {
    let manual =
      candidate.classification == .unprovenNameOnly
      && candidate.reason == .nameOnly && candidate.explicitManualChoiceAvailable
      && candidate.snapshot?.entries.first(where: { $0.path == candidate.path })?.identity != nil
      && candidate.refusalEvidence.isEmpty
    guard !incompletePackagePaths.contains(app.path),
      (candidate.canSelect && candidate.classification == .installed) || manual,
      !ownershipRefusalEvidence.contains(where: { $0.candidatePath == candidate.path }),
      inventoryComplete || relatedReviewedPaths.contains(app.path) || reviewedDropPath == app.path,
      !needsRescan, pictureRows.isEmpty,
      let id = app.bundleID,
      id.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame,
      runningCheckedIDs.contains(id), !runningIDs.contains(id), !runningUnknownIDs.contains(id)
    else { return false }
    return true
  }

  nonisolated static func provenanceLabel(_ kind: RelatedDataProvenanceKind) -> String {
    switch kind {
    case .bundleIdentifier: String(localized: "Evidence: bundle identifier")
    case .teamIdentifier: String(localized: "Evidence: signing team identifier")
    case .electron: String(localized: "Evidence: Electron package settings and data structure")
    case .mozilla: String(localized: "Evidence: Mozilla package settings and profile structure")
    case .installerReceipt: String(localized: "Evidence: installer receipt")
    case .launchService: String(localized: "Evidence: launch service points into this app")
    case .configuredDirectory: String(localized: "Evidence: directory named in this app’s settings")
    case .vendorDirectory: String(localized: "Evidence: this app’s exclusive vendor directory")
    case .liveProcess: String(localized: "Evidence: this app’s open files or working directory")
    case .explicitUserChoice: String(localized: "Your explicit choice · ownership remains unproven")
    }
  }

  private nonisolated static func sameUnprovenObservation(
    _ original: RelatedDataCandidate, _ current: RelatedDataCandidate
  ) -> Bool {
    guard current.classification == .unprovenNameOnly, current.reason == .nameOnly,
      current.explicitManualChoiceAvailable, current.refusalEvidence.isEmpty,
      let oldRoot = original.snapshot?.entries.first(where: { $0.path == original.path })?.identity,
      let newRoot = current.snapshot?.entries.first(where: { $0.path == current.path })?.identity
    else { return false }
    return original.path == current.path && oldRoot == newRoot
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
        RelatedDataService.AvailableUninstallPlan(plan: try await builder(candidates), rejections: [])
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
    explicitlySelectedUnproven = [:]
    packageSelected = false
    if let bundleID = report.bundleID {
      let status = await running.isRunning(bundleID: bundleID)
      guard dropGeneration == id else { return }
      runningCheckedIDs.insert(bundleID)
      runningIDs.remove(bundleID)
      runningUnknownIDs.remove(bundleID)
      if status == true { runningIDs.insert(bundleID) }
      if status == nil { runningUnknownIDs.insert(bundleID) }
    }
    guard let reason = packageUnavailableReason(report) else {
      packageSelected = true
      selectedDataPaths = Set(
        report.related.filter {
          $0.classification != .unprovenNameOnly && $0.provenance?.kind != .configuredDirectory
            && $0.defaultSelected && canSelect($0, app: report)
        }.map(\.path))
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
    guard !preparing, !needsRescan, !actions.busy, pictureRows.isEmpty, let report = selectedReport,
      packageSelected || !selectedDataPaths.isEmpty
    else {
      message = String(localized: "Select the app or eligible related data")
      return
    }
    let candidates = report.related.filter {
      selectedDataPaths.contains($0.path) && $0.classification != .unprovenNameOnly
    }
    let manual = explicitlySelectedUnproven.values.filter { original in
      selectedDataPaths.contains(original.path)
        && report.related.contains { Self.sameUnprovenObservation(original, $0) }
    }.sorted { $0.path < $1.path }
    let missing = selectedDataPaths.subtracting(candidates.map(\.path) + manual.map(\.path)).sorted().map {
      PlanRejection(.unavailable, path: $0, ruleID: "explicitSelectionRequired")
    }
    if packageSelected, let reason = packageUnavailableReason(report) {
      message = reason
      return
    }
    let includePackage = packageSelected
    let dataPaths = selectedDataPaths
    let fallbackBuilder = explicitUninstallPlanBuilder
    let activeSession = usesInjectedPlanner ? nil : session
    let builder: AvailableUninstallPlanBuilder = { report, candidates, includePackage in
      guard let activeSession else {
        return try await fallbackBuilder(report, candidates, includePackage, manual)
      }
      return await activeSession.makeAvailableUninstallPlan(
        path: report.path, expectedBundleID: report.bundleID,
        selectedRelated: candidates, includePackage: includePackage, selectedUnprovenRelated: manual)
    }
    await prepare(
      actions: actions,
      stillSelected: {
        self.selectedPath == report.path && self.selectedDataPaths == dataPaths
          && self.packageSelected == includePackage
          && manual.allSatisfy { original in
            self.explicitlySelectedUnproven[original.path].map {
              Self.sameUnprovenObservation(original, $0)
            } == true
          }
      },
      builder: {
        if candidates.isEmpty && manual.isEmpty && !includePackage {
          return RelatedDataService.AvailableUninstallPlan(plan: nil, rejections: missing)
        }
        let outcome = try await builder(report, candidates, includePackage)
        if includePackage, let plan = outcome.plan {
          let packages = plan.items.filter { $0.policy == .wholeBundle }
          let links = plan.items.filter { $0.policy == .applicationLink }
          guard packages.count == 1, let package = packages.first,
            package.applicationBundleID == report.bundleID,
            report.bundleID != nil
              || package.applicationPackageObservation?.bundleIdentifier == nil
                && package.applicationPackageObservation != nil,
            (links.isEmpty && report.linkTarget == nil && package.sourcePath == report.path)
              || (links.count == 1 && links[0].sourcePath == report.path
                && links[0].packageLinkTargetItemID == package.id)
          else {
            throw PlanRejections(rejections: [PlanRejection(.changedSinceScan, path: report.path)])
          }
        }
        return RelatedDataService.AvailableUninstallPlan(
          plan: outcome.plan, rejections: missing + outcome.rejections,
          refusalEvidence: outcome.refusalEvidence)
      })
  }

  private func prepare(
    actions: ActionStore, stillSelected: @escaping @MainActor () -> Bool,
    builder: @escaping @Sendable () async throws -> RelatedDataService.AvailableUninstallPlan
  ) async {
    let id = UUID()
    preparationGeneration = id
    preparing = true
    preparedActions = actions
    defer {
      if preparationGeneration == id {
        preparing = false
        preparationTask = nil
      }
    }
    do {
      let task = Task(priority: .userInitiated) { @concurrent in try await builder() }
      preparationTask = task
      let outcome = try await task.value
      guard preparationGeneration == id, stillSelected(), !task.isCancelled, !actions.busy else {
        return
      }
      ownershipRefusalEvidence = outcome.refusalEvidence
      guard let plan = outcome.plan else {
        message =
          outcome.rejections.isEmpty
          ? String(localized: "Select the app or eligible related data")
          : outcome.rejections.map(Self.refusalText).joined(separator: "\n")
        return
      }
      for item in plan.items where item.policy == .wholeBundle {
        guard item.applicationBundleID != nil || item.applicationPackageObservation != nil else {
          throw PlanFailure.unsafeSelection
        }
        for bundle in [item.applicationBundleID].compactMap({ $0 })
          + (item.nestedApplicationIDs ?? [])
        {
          let status = await running.isRunning(bundleID: bundle)
          if status == false { continue }
          guard preparationGeneration == id, stillSelected() else { return }
          message = Self.refusalText(
            PlanRejection(
              status == true ? .processActive : .activityUnavailable,
              path: item.sourcePath, ruleID: status == true ? bundle : nil))
          return
        }
      }
      guard preparationGeneration == id, stillSelected(), !actions.busy else { return }
      let summaries = plan.items.map { item in
        let size = PlanItemSize.measure(item)
        let selectedByName = explicitlySelectedUnproven[item.sourcePath] != nil
        return ActionItemSummary(
          id: item.id, label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
          path: item.sourcePath,
          reason: item.policy == .wholeBundle
            ? String(localized: "Whole application package")
            : item.policy == .applicationLink
              ? String(
                localized: "Listed application link; the physical application is a separate item.")
              : selectedByName
                ? String(
                  localized:
                    "You selected this item by name. Its ownership is unproven; it may contain personal data. Move it to Trash only if you recognize it. Undo is available in History."
                )
                : String(
                  localized:
                    "Selected app data. Preferences and support files may contain personal settings or documents."
                ),
          logicalBytes: size.logical, allocatedBytes: size.allocated)
      }
      actions.present(plan: plan, items: summaries, rejectedItems: outcome.rejections)
      guard actions.pending?.id == plan.id else { return }
      presentedPaths = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.sourcePath) })
      presentedPackageItems = plan.items.filter {
        $0.policy == .wholeBundle || $0.policy == .applicationLink
      }
      presentedPackages = [:]
      for package in presentedPackageItems where package.policy == .wholeBundle {
        let leaf = presentedPackageItems.first {
          $0.packageLinkTargetItemID == package.id && $0.policy == .applicationLink
        }
        let listedPath = leaf?.sourcePath ?? package.sourcePath
        presentedPackages[listedPath] = (package.id, leaf?.id)
      }
      packageItemResults = []
      presentedPlanID = plan.id
      observedResultID = nil
      message = nil
    } catch let refused as PlanRejections {
      if preparationGeneration == id { message = refused.rejections.map(Self.refusalText).joined(separator: "\n") }
    } catch let refused as PlanRejection {
      if preparationGeneration == id { message = Self.refusalText(refused) }
    } catch {
      if preparationGeneration == id {
        message = FailureText.describe(error)
      }
    }
  }

  private static func refusalText(_ rejection: PlanRejection) -> String {
    guard let code = rejection.ruleID else { return SpaceText.rejection(rejection) }
    switch code {
    case "ios-wrapper":
      return String(localized: "This iPhone or iPad application cannot be removed here. Use Show in Finder.")
        + " — " + rejection.path
    case "incompleteInventory", "invalidReceipt", "ownerPresent", "changedItem", "runningOrUnknown",
      "ambiguousOwner", "unsupportedInstalledData":
      return FailureText.describe(code) + " — " + rejection.path
    default: return SpaceText.rejection(rejection)
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
