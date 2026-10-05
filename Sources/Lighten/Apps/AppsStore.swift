import Darwin
import Foundation
import LightenKit
import Observation
import os

@MainActor @Observable
final class AppsStore: ToolSummaryProviding {
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

  struct OpeningTiming {
    let requestedAt: ContinuousClock.Instant
    var firstRowDrawnAt: ContinuousClock.Instant?
    var visibleIconsDrawnAt: ContinuousClock.Instant?
    var visibleRowCount = 0
  }

  @ObservationIgnored private(set) var openingTiming: OpeningTiming?
  private(set) var openingRevision = 0
  private(set) var displayListingFinished = false
  @ObservationIgnored private let openingLogger = Logger(subsystem: "com.tavsn.lighten", category: "apps-opening")
  @ObservationIgnored private let relatedLogger = Logger(subsystem: "com.tavsn.lighten", category: "apps-related")
  @ObservationIgnored private(set) var pictureOpeningTiming: PictureOpeningTiming?
  @ObservationIgnored private let events: @Sendable () -> AsyncStream<ApplicationDiscovery.Event>
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var session: ApplicationScanSession?
  @ObservationIgnored private var selectedReviewTask: Task<Void, Never>?
  @ObservationIgnored private var selectedRunningTask: Task<Void, Never>?
  @ObservationIgnored private var selectedReviewToken = UUID()
  @ObservationIgnored private let selectedReview: SelectedReview?
  @ObservationIgnored private let relatedService: RelatedDataService
  @ObservationIgnored private let usesInjectedPlanner: Bool
  @ObservationIgnored private var relatedReviewedPaths: Set<String> = []
  @ObservationIgnored private var removedPaths: Set<String> = []
  @ObservationIgnored private var displayChanges: [UUID: ActionDisplayItem] = [:]
  @ObservationIgnored private var removedReports: [UUID: [ApplicationReport]] = [:]
  @ObservationIgnored private var removedData: [UUID: [String: [RelatedDataCandidate]]] = [:]
  @ObservationIgnored private var removedReviewTokens: [String: UUID] = [:]
  @ObservationIgnored private var removedRetainedData: [UUID: [String: RetainedAppData]] = [:]
  @ObservationIgnored private var removedOrphans: [UUID: [RelatedDataCandidate]] = [:]
  private(set) var displayRevision = 0
  private(set) var ownershipPendingPaths: Set<String> = []
  private(set) var selectedReviewPending = false
  private(set) var selectedEvidencePending = false
  private(set) var selectedShallowComplete = false
  private(set) var selectedMeasurementProgress: (completed: Int, total: Int)?
  private(set) var selectedDrawRevision = 0
  private(set) var selectedListDrawnAt: ContinuousClock.Instant?
  private(set) var selectedEnrichedListDrawnAt: ContinuousClock.Instant?
  private(set) var ownershipCollectionFinished = false
  private(set) var relatedDiscoveryStopped = false
  @ObservationIgnored private var selectedEvidenceFinished = false
  @ObservationIgnored private var selectedReviewPhaseRank = -1
  private var appSelections: [String: AppRemovalSelection] = [:]
  private var unfocusedSelection = AppRemovalSelection()
  private(set) var selectedAppPaths: Set<String> = []
  @ObservationIgnored private var selectionAnchor: String?
  private var currentSelection: AppRemovalSelection {
    get { selectedPath.flatMap { appSelections[$0] } ?? unfocusedSelection }
    set {
      if let selectedPath { appSelections[selectedPath] = newValue } else { unfocusedSelection = newValue }
    }
  }
  private var explicitlyDeselectedDataPaths: Set<String> {
    get { currentSelection.deselectedDataPaths }
    set { currentSelection.deselectedDataPaths = newValue }
  }
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
  @ObservationIgnored private let preparationTimeout: @Sendable () async throws -> Void
  private nonisolated struct PreparedRemoval: Sendable {
    let outcome: RelatedDataService.AvailableUninstallPlan
    let hasRunningApplications: Bool
  }
  private nonisolated enum PreparationFailure: Error { case timedOut }
  private actor PreparationRace {
    private var result: Result<PreparedRemoval, Error>?
    private var waiter: CheckedContinuation<PreparedRemoval, Error>?

    func value() async throws -> PreparedRemoval {
      if let result { return try result.get() }
      return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func finish(_ result: Result<PreparedRemoval, Error>) {
      guard self.result == nil else { return }
      self.result = result
      waiter?.resume(with: result)
      waiter = nil
    }
  }
  private enum PreparationStage { case selectedItems, runningApplications }
  private var preparationStage: PreparationStage?
  @ObservationIgnored private var reviewIntentRequested = false
  @ObservationIgnored private var preparationTask: Task<PreparedRemoval, Error>?
  let tool = ToolStore()
  @ObservationIgnored private var choiceRevision = UUID()
  private enum ReviewKind { case focused, basket, orphans }
  @ObservationIgnored private var reviewKind = ReviewKind.focused
  @ObservationIgnored private let preferences: RemovalPreferences
  @ObservationIgnored private let userPlanner: PlanService
  @ObservationIgnored private let running: any RunningApplicationSource
  @ObservationIgnored private let pictures: ResultPictureStore
  @ObservationIgnored private let loadPicture: @Sendable () -> ResultPicture<AppsPicture>?
  @ObservationIgnored private var restoredDisplayRows: [String: AppsPicture.Row] = [:]
  @ObservationIgnored private var opened = false
  var pictureRows: [AppsPicture.Row] = []
  var pictureObservedAt: Date?
  var reports: [ApplicationReport] = []
  private(set) var listedNames: [String: String] = [:]
  private(set) var omittedApplicationPaths: [String] = []
  private(set) var listedPublishedAt: ContinuousClock.Instant?
  @ObservationIgnored private var listedIdentities: [String: FileIdentity] = [:]
  @ObservationIgnored private var visiblePaths: [String] = []
  var measuringPaths: Set<String> = []
  var measuredCount = 0
  var inventoryComplete = false
  private(set) var externalVolumesUnchecked = false
  private(set) var coverageIssueDescriptions: [String] = []
  var hasCoverageIssue: Bool { !busy && backgroundFinishedAt != nil && !inventoryComplete }
  var scannedAt: Date?
  var busy = false {
    didSet {
      tool.phase = busy ? .scanning : (relatedDiscoveryStopped ? .partial : reports.isEmpty ? .idle : .ready)
    }
  }
  var phase: ToolPhase { preparing ? .preparing : tool.phase }
  var showsPreviousResult: Bool { pictureObservedAt != nil && needsRescan }
  var toolSummary: ToolSummary {
    let count = showsPreviousResult ? defaultPictureRows.count : defaultApplicationReports.count
    let sizes = showsPreviousResult ? defaultPictureRows.map(\.logical) : defaultApplicationReports.map(\.logical)
    return ToolSummary(
      count: count, logicalBytes: Self.total(sizes).knownLowerBound,
      observedAt: scannedAt ?? pictureObservedAt,
      partial: busy || relatedDiscoveryStopped || needsRescan || !displayListingFinished || hasCoverageIssue)
  }
  func refresh() { startScan() }
  var preparing: Bool {
    get { tool.preparation.preparing }
    set {
      if newValue { _ = tool.preparation.begin() } else { tool.preparation.invalidatePreparation() }
    }
  }
  var needsRescan = false
  var selectedPath: String?
  var packageSelected: Bool {
    get { currentSelection.packageSelected }
    set {
      currentSelection.packageSelected = newValue
      updateBasketMembership()
    }
  }
  var selectedDataPaths: Set<String> {
    get { currentSelection.dataPaths }
    set {
      currentSelection.automaticDataPaths.formIntersection(newValue)
      currentSelection.dataPaths = newValue
      currentSelection.manualData = currentSelection.manualData.filter { newValue.contains($0.key) }
      updateBasketMembership()
    }
  }
  @ObservationIgnored private weak var preparedActions: ActionStore?
  private var explicitlySelectedUnproven: [String: RelatedDataCandidate] {
    get { currentSelection.manualData }
    set { currentSelection.manualData = newValue }
  }

  private func updateBasketMembership() {
    guard let selectedPath else { return }
    if currentSelection.hasChoice {
      selectedAppPaths.insert(selectedPath)
    } else {
      selectedAppPaths.remove(selectedPath)
    }
  }
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
  struct RetainedAppData {
    let appPath: String
    var rejection: PlanRejection?
    var result: ItemActionResult?
    var wasSelected: Bool
  }
  private(set) var retainedAppData: [String: RetainedAppData] = [:]
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
    let mutationStage: ActionMutationStage?
  }
  private(set) var packageItemResults: [PackageItemResult] = []
  private(set) var ownershipRefusalEvidence: [RelatedOwnershipRefusalEvidence] {
    get { currentSelection.refusalEvidence }
    set { currentSelection.refusalEvidence = newValue }
  }
  @ObservationIgnored private var presentedPackages: [String: (physical: UUID, link: UUID?)] = [:]
  @ObservationIgnored private var presentedPackageItems: [PlanItem] = []
  @ObservationIgnored private var incompletePackagePaths: Set<String> = []
  @ObservationIgnored private var navigationGeneration = UUID()
  @ObservationIgnored private var observedResultID: UUID?
  @ObservationIgnored private let uninstallPlanBuilder: AvailableUninstallPlanBuilder
  @ObservationIgnored private let explicitUninstallPlanBuilder: ExplicitUninstallPlanBuilder
  @ObservationIgnored private let orphanPlanBuilder: @Sendable ([RelatedDataCandidate]) async throws -> ActionPlan
  typealias RemainingDataPlanBuilder =
    @Sendable ([RelatedDataCandidate]) async -> RelatedDataService.AvailableUninstallPlan
  @ObservationIgnored private let remainingDataPlanBuilder: RemainingDataPlanBuilder
  @ObservationIgnored private let basketPlanBuilder: BasketPlanBuilder?
  @ObservationIgnored private let droppedReport: @Sendable (String) async -> ApplicationReport?

  init(
    pictures: ResultPictureStore = ResultPictureStore(),
    loadPicture: (@Sendable () -> ResultPicture<AppsPicture>?)? = nil,
    uninstallPlanBuilder: (@Sendable (ApplicationReport, [RelatedDataCandidate], Bool) async throws -> ActionPlan)? =
      nil,
    availableUninstallPlanBuilder: AvailableUninstallPlanBuilder? = nil,
    explicitUninstallPlanBuilder: ExplicitUninstallPlanBuilder? = nil,
    relatedService: RelatedDataService = .system,
    selectedReview: SelectedReview? = nil,
    basketPlanBuilder: BasketPlanBuilder? = nil,
    preparationTimeout: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .seconds(5))
    },
    orphanPlanBuilder: (@Sendable ([RelatedDataCandidate]) async throws -> ActionPlan)? = nil,
    remainingDataPlanBuilder: RemainingDataPlanBuilder? = nil,
    droppedReport: @escaping @Sendable (String) async -> ApplicationReport? = {
      await ApplicationDiscovery(related: .system).report(path: $0)
    },
    preferences: RemovalPreferences = .shared, userPlanner: PlanService = PlanService(),
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
    self.basketPlanBuilder = basketPlanBuilder
    self.preparationTimeout = preparationTimeout
    self.selectedReview = selectedReview
    self.relatedService = relatedService
    self.usesInjectedPlanner =
      availableUninstallPlanBuilder != nil || explicitUninstallPlanBuilder != nil
      || uninstallPlanBuilder != nil || planBuilder != nil
      || remainingDataPlanBuilder != nil || orphanPlanBuilder != nil
    self.pictures = pictures
    self.loadPicture = loadPicture ?? { pictures.load(AppsPicture.self, named: "apps") }
    self.preferences = preferences
    self.userPlanner = userPlanner
    self.running = running
    self.events = events
    self.orphanPlanBuilder =
      orphanPlanBuilder ?? { candidates in
        let plans = try candidates.map { try RelatedDataService.system.plan(candidate: $0) }
        guard let first = plans.first else { throw PlanFailure.emptySelection }
        return ActionPlan(snapshotRunID: first.snapshotRunID, kind: .trash, items: plans.flatMap(\.items))
      }
    self.remainingDataPlanBuilder =
      remainingDataPlanBuilder ?? { candidates in
        await relatedService.makeAvailableRemainingDataPlan(selected: candidates)
      }
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

  func displayName(_ report: ApplicationReport) -> String {
    listedNames[report.path] ?? URL(fileURLWithPath: report.path).deletingPathExtension().lastPathComponent
  }

  /// Receives one complete snapshot from the scroll viewport's drawing pass.
  func viewportDidDraw(_ snapshot: ApplicationViewportSnapshot, revision: Int) {
    guard revision == openingRevision, var timing = openingTiming, !snapshot.visibleRows.isEmpty else { return }
    timing.visibleRowCount = snapshot.visibleRows.count
    if timing.firstRowDrawnAt == nil {
      timing.firstRowDrawnAt = .now
      let elapsed = Self.milliseconds(timing.requestedAt.duration(to: .now))
      openingLogger.info("Apps opening first-row milliseconds=\(elapsed, privacy: .public)")
    }
    if displayListingFinished, timing.visibleIconsDrawnAt == nil, snapshot.iconsReady {
      timing.visibleIconsDrawnAt = .now
      let elapsed = Self.milliseconds(timing.requestedAt.duration(to: .now))
      let visible = snapshot.visibleRows.count
      let listed = snapshot.listedRowCount
      openingLogger.info(
        "Apps opening visible-icons milliseconds=\(elapsed, privacy: .public) visible-rows=\(visible, privacy: .public) listed-rows=\(listed, privacy: .public)"
      )
    }
    openingTiming = timing
  }

  func viewportVisibilityChanged(_ paths: Set<String>) {
    visiblePaths = paths.sorted()
    let visible = visiblePaths
    Task { await ApplicationIconCache.shared.prioritize(paths: visible) }
    guard let session else { return }
    Task { await session.prioritizeVisibleApplications(paths: visible) }
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
  }

  func rowVisibilityChanged(_ path: String, visible: Bool) {
    visiblePaths.removeAll { $0 == path }
    if visible { visiblePaths.append(path) }
    guard let session else { return }
    let paths = visiblePaths
    Task { await session.prioritizeVisibleApplications(paths: paths) }
  }

  var selectedReport: ApplicationReport? { reports.first { $0.path == selectedPath } }

  /// Display restoration and fresh discovery run independently. Neither grants action authority.
  func open(actions: ActionStore) {
    openingRevision += 1
    openingTiming = OpeningTiming(requestedAt: .now)
    guard !opened else { return }
    opened = true
    let requestedAt = ContinuousClock.now
    if scannedAt == nil, !busy { startScan(actions: actions) }
    let openingGeneration = generation
    let loadPicture = self.loadPicture
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let loadStartedAt = ContinuousClock.now
      let picture = loadPicture()
      let loadFinishedAt = ContinuousClock.now
      Task(priority: .userInitiated) { @MainActor [weak self] in
        guard let self, self.generation == openingGeneration else { return }
        if self.reports.isEmpty, self.busy, self.listedPublishedAt == nil, self.inventoryPublishedAt == nil, let picture
        {
          self.pictureRows = picture.content.rows
          self.restoredDisplayRows = Dictionary(
            picture.content.rows.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
          self.pictureObservedAt = picture.observedAt
          self.needsRescan = true
          self.pictureOpeningTiming = PictureOpeningTiming(
            requestedAt: requestedAt, loadStartedAt: loadStartedAt, loadFinishedAt: loadFinishedAt, publishedAt: .now)
        }
      }
    }
  }

  func startScan(actions: ActionStore? = nil) {
    guard !busy else { return }
    cancelPreparation(actions: actions)
    reviewedDropPath = nil
    cancelSelectedReview()
    let previousSession = session
    session = nil
    if let previousSession { Task { await previousSession.cancel() } }
    appSelections = [:]
    selectedAppPaths = []
    selectionAnchor = nil
    relatedReviewedPaths = []
    removedPaths = []
    incompletePackagePaths = []
    ownershipRefusalEvidence = []
    navigationGeneration = UUID()
    ownershipPendingPaths = []
    ownershipCollectionFinished = false
    relatedDiscoveryStopped = false
    removedReviewTokens = [:]
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
    listedNames = [:]
    omittedApplicationPaths = []
    listedIdentities = [:]
    listedPublishedAt = nil
    displayListingFinished = false
    visiblePaths = []
    orphanCandidates = []
    retainedAppData = [:]
    selectedOrphanPaths = []
    measuringPaths = []
    measuredCount = 0
    inventoryComplete = false
    coverageIssueDescriptions = []
    externalVolumesUnchecked = false
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
            let visible = self.visiblePaths
            Task { await session.prioritizeVisibleApplications(paths: visible) }
          case .listed(let entries, let isFinalBatch):
            self.publishOmittedPaths(entries.map(\.path))
            let cached = self.restoredDisplayRows
            self.listedNames = Dictionary(entries.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
            self.listedIdentities = Dictionary(
              entries.compactMap { entry in
                entry.displayRootIdentity.map { (entry.path, $0) }
              }, uniquingKeysWith: { first, _ in first })
            self.reports = entries.filter { self.listLocation($0.path) != .excluded }.map { entry in
              let previous = cached[entry.path]
              return ApplicationReport(
                path: entry.path, bundleID: entry.bundleID, version: entry.version,
                signerTeamID: nil,
                logical: previous?.logical ?? ByteAggregate(knownLowerBound: 0, completeTotal: nil),
                allocated: previous?.allocated ?? ByteAggregate(knownLowerBound: 0, completeTotal: nil),
                knownItemCount: previous?.knownItemCount ?? 0, partial: true, related: [],
                manualUninstallerSuggested: false, displayRootIdentity: entry.displayRootIdentity)
            }.filter { !self.displayRemoved($0) }
            if !entries.isEmpty, self.listedPublishedAt == nil { self.listedPublishedAt = .now }
            self.displayListingFinished = isFinalBatch
            if isFinalBatch {
              self.openingRevision += 1
            }
            self.measuringPaths = Set(self.reports.map(\.path))
            self.pictureRows = []
            self.needsRescan = false
          case .inventory(let inventory, let metadata):
            self.publishOmittedPaths(metadata.map(\.path))
            self.externalVolumesUnchecked = inventory.registrationReport?.externalVolumesUnchecked ?? false
            self.reports = metadata.filter { self.listLocation($0.path) != .excluded && !self.displayRemoved($0) }.map {
              report in
              guard let current = self.reports.first(where: { $0.path == report.path }) else { return report }
              return self.mergingMeasurement(report, with: current)
            }
            self.measuringPaths = Set(self.reports.map(\.path))
            self.inventoryPublishedAt = .now
            self.pictureRows = []
            self.pictureObservedAt = nil
          case .related(let path, let candidates, let ownershipPending):
            self.publishRelated(path: path, candidates: candidates, ownershipPending: ownershipPending)
          case .ownershipReady(let inventory):
            self.ownershipCollectionFinished = true
            self.inventoryComplete = inventory.complete
            self.publishCoverage(inventory)
            self.externalVolumesUnchecked =
              inventory.registrationReport?.externalVolumesUnchecked ?? self.externalVolumesUnchecked
          case .measured(let batch):
            for report in batch {
              if let index = self.reports.firstIndex(where: { $0.path == report.path }) {
                self.reports[index] = self.mergingMeasurement(report, with: self.reports[index])
                self.measuringPaths.remove(report.path)
                self.measuredCount += 1
              }
            }
          case .orphans(let candidates):
            self.publishOrphans(candidates)
          case .completed(let inventory, let reports):
            self.publishOmittedPaths(reports.map(\.path))
            for report in reports where self.removedReport(path: report.path) != nil {
              self.retainLateRelatedData(path: report.path, candidates: report.related)
            }
            self.reports = reports.filter { self.listLocation($0.path) != .excluded && !self.displayRemoved($0) }.map {
              report in
              self.reports.first(where: { $0.path == report.path }).map {
                self.mergingMeasurement(report, with: $0)
              } ?? report
            }
            self.backgroundFinishedAt = .now
            self.measuringPaths = []
            self.measuredCount = reports.count
            self.inventoryComplete = inventory.complete
            self.publishCoverage(inventory)
            self.externalVolumesUnchecked =
              inventory.registrationReport?.externalVolumesUnchecked ?? self.externalVolumesUnchecked
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
          self.measuringPaths = []
          self.scanTask = nil
          self.finishStoppedDiscovery()
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
    finishStoppedDiscovery()
  }

  private func finishStoppedDiscovery() {
    relatedDiscoveryStopped = true
    tool.phase = .partial
    needsRescan = !pictureRows.isEmpty || (reports.isEmpty && orphanCandidates.isEmpty)
    cancelPreparation()
    if needsRescan {
      selectedAppPaths = []
      appSelections = [:]
      packageSelected = false
      selectedDataPaths = []
      explicitlySelectedUnproven = [:]
    }
    message = String(
      localized: "Related discovery stopped. Review the app and files already listed, or scan again to find more.")
  }

  /// Called when the view has laid out the idle state after cancellation.
  func scanDidLayout() {
    guard !busy, let requested = cancellationRequestedAt else { return }
    let elapsed = requested.duration(to: .now).components
    cancellationLayoutMilliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    cancellationRequestedAt = nil
  }

  private func selection(for report: ApplicationReport, defaultPackage: Bool) -> AppRemovalSelection {
    let identity = listedIdentities[report.path] ?? report.displayRootIdentity
    if var saved = appSelections[report.path] {
      let changedBundle = saved.bundleID != nil && report.bundleID != nil && saved.bundleID != report.bundleID
      if changedBundle {
        appSelections.removeValue(forKey: report.path)
      } else if let old = saved.rootIdentity, let identity,
        old.device != identity.device || old.inode != identity.inode || old.kind != identity.kind
          || old.birthSeconds != identity.birthSeconds || old.birthNanoseconds != identity.birthNanoseconds
      {
        appSelections.removeValue(forKey: report.path)
      } else {
        if saved.rootIdentity == nil { saved.rootIdentity = identity }
        if saved.bundleID == nil { saved.bundleID = report.bundleID }
        refreshAutomaticSelection(&saved, report: report, addingNew: false)
        return saved
      }
    }
    var choice = AppRemovalSelection(rootIdentity: identity, bundleID: report.bundleID)
    choice.packageSelected = defaultPackage && packageUnavailableReason(report) == nil
    refreshAutomaticSelection(&choice, report: report)
    return choice
  }

  private func refreshAutomaticSelection(
    _ choice: inout AppRemovalSelection, report: ApplicationReport, addingNew: Bool = true
  ) {
    let manual = choice.dataPaths.subtracting(choice.automaticDataPaths)
    let eligible = Set(
      report.related.filter {
        automaticSelectionAllowed(
          $0, appPath: report.path, appBundleID: report.bundleID, refusalEvidence: choice.refusalEvidence)
          && !choice.deselectedDataPaths.contains($0.path)
      }.map(\.path))
    choice.automaticDataPaths =
      addingNew && choice.packageSelected
      ? eligible.subtracting(manual) : choice.automaticDataPaths.intersection(eligible)
    choice.dataPaths = manual.union(choice.automaticDataPaths)
  }

  func isAutomaticallySelected(_ candidate: RelatedDataCandidate, app: ApplicationReport) -> Bool {
    appSelections[app.path]?.automaticDataPaths.contains(candidate.path) == true
  }

  private func resetSelection(_ path: String) {
    appSelections.removeValue(forKey: path)
  }

  private func focusApp(_ path: String, defaultPackage: Bool) {
    selectedReviewRequestedAt = .now
    selectedDrawRevision += 1
    selectedListDrawnAt = nil
    selectedEnrichedListDrawnAt = nil
    selectedShallowComplete = false
    selectedEvidenceFinished = false
    selectedReviewPhaseRank = -1
    selectedMeasurementProgress = nil
    navigationGeneration = UUID()
    if let report = reports.first(where: { $0.path == path }) {
      appSelections[path] = selection(for: report, defaultPackage: defaultPackage)
    }
    selectedPath = path
    message = nil
    requestSelectedReview(path)
  }

  func select(_ path: String, selectPackage: Bool = false) {
    guard !needsRescan, pictureRows.isEmpty, !dropping else { return }
    focusApp(path, defaultPackage: selectPackage)
    if !selectPackage { packageSelected = false }
    selectedAppPaths = currentSelection.hasChoice ? [path] : []
    selectionAnchor = path
  }

  func select(_ path: String, actions: ActionStore, selectPackage: Bool = true) {
    let continueReview = preparing || reviewIntentRequested
    cancelPreparation(actions: actions, preserveReviewIntent: continueReview)
    select(path, selectPackage: selectPackage)
    logPackageAvailability(actions: actions)
    if continueReview { continueReviewIntent(actions: actions) }
  }

  private func logPackageAvailability(actions: ActionStore) {
    if packageSelected, canReviewSelectedData(actions: actions), let requested = selectedReviewRequestedAt {
      let ms = Self.milliseconds(requested.duration(to: .now))
      relatedLogger.info("package-review-available ms=\(ms, privacy: .public)")
    }
  }

  func waitForSelectedReview() async { await selectedReviewTask?.value }
  func waitForScan() async { await scanTask?.value }

  var listScopeHomeDirectory: String { userPlanner.homeDirectory }

  private func publishOmittedPaths(_ paths: [String]) {
    omittedApplicationPaths = Array(Set(omittedApplicationPaths + paths.filter { listLocation($0) == .excluded }))
      .sorted()
  }

  private func listLocation(_ path: String) -> AppListScope {
    AppListScope.location(of: path, homeDirectory: userPlanner.homeDirectory)
  }

  var defaultApplicationReports: [ApplicationReport] { reports.filter { listLocation($0.path) == .installed } }
  var otherLocationReports: [ApplicationReport] { reports.filter { listLocation($0.path) == .other } }
  var defaultPictureRows: [AppsPicture.Row] { pictureRows.filter { listLocation($0.path) == .installed } }
  var otherPictureRows: [AppsPicture.Row] { pictureRows.filter { listLocation($0.path) == .other } }
  var defaultMeasuredCount: Int { defaultApplicationReports.filter { !measuringPaths.contains($0.path) }.count }

  func signerDescription(for app: ApplicationReport) -> String {
    if let signer = app.signerTeamID { return signer }
    if selectedPath == app.path && (selectedEvidencePending || selectedReviewPending) {
      return String(localized: "Checking app signature…")
    }
    return String(localized: "Unavailable")
  }

  func selectApp(
    _ path: String, intent: AppSelectionIntent = .single, orderedPaths: [String] = [], actions: ActionStore
  ) {
    guard !needsRescan, pictureRows.isEmpty, !dropping, !actions.busy,
      let report = reports.first(where: { $0.path == path })
    else { return }
    let continueReview = preparing || reviewIntentRequested
    cancelPreparation(actions: actions, preserveReviewIntent: continueReview)
    let previous = selectedAppPaths
    let anchor = selectionAnchor
    focusApp(path, defaultPackage: true)
    if let reason = packageUnavailableReason(report) {
      selectedAppPaths = intent == .single ? [] : previous.subtracting([path])
      message = reason
    } else {
      switch intent {
      case .single:
        if !currentSelection.hasChoice { packageSelected = true }
        selectedAppPaths = [path]
      case .toggle:
        if previous.contains(path) {
          selectedAppPaths = previous.subtracting([path])
          resetSelection(path)
        } else {
          if !currentSelection.hasChoice { packageSelected = true }
          selectedAppPaths = previous.union([path])
        }
      case .range:
        let range: [String]
        if let anchor, let start = orderedPaths.firstIndex(of: anchor), let end = orderedPaths.firstIndex(of: path) {
          range = Array(orderedPaths[min(start, end)...max(start, end)])
        } else {
          range = [path]
        }
        var additions: Set<String> = []
        for path in range {
          guard let app = reports.first(where: { $0.path == path }), packageUnavailableReason(app) == nil else {
            continue
          }
          var choice = selection(for: app, defaultPackage: true)
          if !choice.hasChoice { choice.packageSelected = true }
          appSelections[path] = choice
          additions.insert(path)
        }
        selectedAppPaths = previous.union(additions)
      }
    }
    if intent != .range { selectionAnchor = path }
    logPackageAvailability(actions: actions)
    if continueReview { continueReviewIntent(actions: actions) }
  }

  func removeAppFromBasket(_ path: String, actions: ActionStore) {
    let continueReview = preparing || reviewIntentRequested
    cancelPreparation(actions: actions, preserveReviewIntent: continueReview)
    selectedAppPaths.remove(path)
    resetSelection(path)
    if continueReview { continueReviewIntent(actions: actions) }
  }

  func clearBasket(actions: ActionStore) {
    cancelPreparation(actions: actions)
    for path in selectedAppPaths { resetSelection(path) }
    selectedAppPaths = []
  }

  func canReviewBasket(actions: ActionStore) -> Bool {
    !preparing && !needsRescan && !actions.busy && pictureRows.isEmpty
      && selectedAppPaths.contains { appSelections[$0]?.hasChoice == true }
  }

  var basketApplications: [ApplicationReport] { reports.filter { selectedAppPaths.contains($0.path) } }
  var basketDataCount: Int { Set(selectedAppPaths.flatMap { appSelections[$0]?.dataPaths ?? [] }).count }
  var basketLogical: ByteAggregate {
    var sizes: [String: ByteAggregate] = [:]
    for report in basketApplications {
      guard let choice = appSelections[report.path] else { continue }
      if choice.packageSelected { sizes[report.path] = report.logical }
      for candidate in report.related where choice.dataPaths.contains(candidate.path) {
        sizes[candidate.path] =
          Self.userSelection(candidate).observedSize?.logical
          ?? candidate.observation?.logical ?? ByteAggregate(knownLowerBound: 0, completeTotal: nil)
      }
    }
    let roots = sizes.keys.filter { path in !sizes.keys.contains { path.hasPrefix($0 + "/") } }
    return Self.total(roots.compactMap { sizes[$0] })
  }

  private nonisolated static func total(_ values: [ByteAggregate]) -> ByteAggregate {
    var lower: Int64 = 0
    var complete: Int64? = 0
    for value in values {
      let added = lower.addingReportingOverflow(max(0, value.knownLowerBound))
      lower = added.overflow ? Int64.max : added.partialValue
      if let previous = complete, let total = value.completeTotal, !added.overflow {
        let sum = previous.addingReportingOverflow(max(0, total))
        complete = sum.overflow ? nil : sum.partialValue
      } else {
        complete = nil
      }
    }
    return ByteAggregate(knownLowerBound: lower, completeTotal: complete)
  }

  typealias BasketPlanBuilder =
    @Sendable ([UserSelection], ActionKind) async -> RelatedDataService.AvailableUninstallPlan

  func prepareBasket(actions: ActionStore) async {
    guard canReviewBasket(actions: actions) else { return }
    reviewKind = .basket
    let paths = selectedAppPaths
    for path in paths {
      guard let report = reports.first(where: { $0.path == path }), var choice = appSelections[path] else { continue }
      refreshAutomaticSelection(&choice, report: report, addingNew: false)
      appSelections[path] = choice
    }
    let choices = appSelections.filter { paths.contains($0.key) }
    var chosen: [UserSelection] = []
    var rejections: [PlanRejection] = []
    var manualPaths: Set<String> = []
    for path in paths.sorted() {
      guard let report = reports.first(where: { $0.path == path }), let choice = choices[path] else {
        rejections.append(PlanRejection(.unavailable, path: path))
        continue
      }
      if choice.packageSelected {
        if let reason = packageUnavailableReason(report) {
          message = reason
          return
        }
        chosen.append(
          UserSelection(
            path: path,
            expectedIdentity: listedIdentities[path] ?? (report.linkTarget == nil ? report.displayRootIdentity : nil),
            observedSize: ObservedPlanSize(logical: report.logical, allocated: report.allocated),
            applicationPackagePaths: [path]))
      }
      let candidates = report.related.filter { choice.dataPaths.contains($0.path) }
      for candidate in candidates {
        if candidate.classification == .unprovenNameOnly {
          guard let original = choice.manualData[candidate.path], Self.sameUnprovenObservation(original, candidate)
          else {
            rejections.append(PlanRejection(.unavailable, path: candidate.path, ruleID: "explicitSelectionRequired"))
            continue
          }
          manualPaths.insert(candidate.path)
        }
        chosen.append(Self.userSelection(candidate))
      }
      rejections += choice.dataPaths.subtracting(candidates.map(\.path)).sorted().map {
        PlanRejection(.unavailable, path: $0)
      }
    }
    let selections = chosen
    let missing = rejections
    let planner = userPlanner
    let builder = basketPlanBuilder
    let kind = preferences.deletionDefault.kind
    await prepare(
      actions: actions,
      stillSelected: {
        self.selectedAppPaths == paths
          && choices.allSatisfy { path, old in
            guard let current = self.appSelections[path] else { return false }
            return old.packageSelected == current.packageSelected && old.dataPaths == current.dataPaths
              && old.manualData.allSatisfy { key, original in
                current.manualData[key].map { Self.sameUnprovenObservation(original, $0) } == true
              }
          }
      }, selectedByNamePaths: manualPaths,
      refusalTargets: Dictionary(uniqueKeysWithValues: choices.map { ($0.key, $0.value.dataPaths) }),
      builder: {
        let outcome: RelatedDataService.AvailableUninstallPlan
        if let builder {
          outcome = await builder(selections, kind)
        } else {
          let fresh = await planner.makeAvailableUserSelectionPlan(selections: selections, kind: kind)
          outcome = .init(plan: fresh.plan, rejections: fresh.rejections)
        }
        return .init(
          plan: outcome.plan, rejections: missing + outcome.rejections, refusalEvidence: outcome.refusalEvidence)
      })
  }

  private func cancelSelectedReview() {
    let previous = selectedReviewToken
    if let session { Task { await session.cancelSelectedReview(requestID: previous) } }
    selectedReviewToken = UUID()
    selectedReviewTask?.cancel()
    selectedReviewTask = nil
    selectedRunningTask?.cancel()
    selectedRunningTask = nil
    selectedReviewPending = false
    selectedEvidencePending = false
  }

  private func requestSelectedReview(_ path: String) {
    cancelSelectedReview()
    guard !relatedDiscoveryStopped else { return }
    // An absent identifier permits package review only; no fabricated owner joins.
    guard selectedReport?.bundleID != nil else { return }
    let activeSession = session
    let review = selectedReview
    // Legacy injected streams already carry fully reviewed reports.
    guard activeSession != nil || review != nil else { return }
    let token = UUID()
    selectedReviewToken = token
    let scanGeneration = generation
    selectedPackageReadyAt = nil
    selectedReviewPublishedAt = nil
    selectedReviewReadyAt = nil
    selectedReviewPending = true
    selectedEvidencePending = activeSession != nil
    let running = self.running
    let bundleID = selectedReport?.bundleID
    if let bundleID {
      runningCheckedIDs.remove(bundleID)
      runningIDs.remove(bundleID)
      runningUnknownIDs.remove(bundleID)
    }
    selectedRunningTask = Task(priority: .userInitiated) { @concurrent in
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
    }
    selectedReviewTask = Task(priority: .userInitiated) { @concurrent in
      guard !Task.isCancelled else { return }
      let progress: @Sendable (ApplicationRelatedReview) -> Void = { update in
        Task { @MainActor in
          if self.acceptsRemovedReview(path: path, token: token, generation: scanGeneration) {
            self.publishRemovedReview(update, path: path)
            return
          }
          guard self.acceptsReview(path: path, token: token, generation: scanGeneration) else { return }
          self.publishReview(update, path: path)
        }
      }
      do {
        let result: ApplicationRelatedReview?
        if let review {
          result = try await review(path, progress)
        } else if let activeSession {
          result = try await activeSession.relatedReview(path: path, requestID: token, progress: progress)
        } else {
          result = nil
        }
        await MainActor.run {
          if self.acceptsRemovedReview(path: path, token: token, generation: scanGeneration) {
            if let result { self.publishRemovedReview(result, path: path) }
            return
          }
          guard !Task.isCancelled, self.acceptsReview(path: path, token: token, generation: scanGeneration) else {
            return
          }
          if let result {
            self.publishReview(result, path: path, ready: true)
          } else {
            self.selectedEvidencePending = false
          }
          self.selectedReviewPending = false
          self.selectedReviewTask = nil
        }
      } catch {
        await MainActor.run {
          guard self.acceptsReview(path: path, token: token, generation: scanGeneration) else { return }
          self.selectedReviewPending = false
          self.selectedReviewTask = nil
          self.message = FailureText.describe(error)
          self.selectedEvidencePending = false
        }
      }
    }
  }

  private func acceptsReview(path: String, token: UUID, generation: UUID) -> Bool {
    self.generation == generation && selectedReviewToken == token && selectedPath == path
      && !needsRescan && pictureRows.isEmpty
  }

  private func removedReport(path: String) -> ApplicationReport? {
    guard removedPaths.contains(path) else { return nil }
    return removedReports.values.flatMap { $0 }.first { $0.path == path }
  }

  private func acceptsRemovedReview(path: String, token: UUID, generation: UUID) -> Bool {
    self.generation == generation && removedReviewTokens[path] == token && removedReport(path: path) != nil
  }

  private func publishRemovedReview(_ review: ApplicationRelatedReview, path: String) {
    guard let old = removedReport(path: path),
      review.application.path == path || review.application.path == old.linkTarget,
      old.bundleID == review.application.bundleID
    else { return }
    retainLateRelatedData(path: path, candidates: review.candidates)
  }

  private func retainLateRelatedData(path: String, candidates: [RelatedDataCandidate]) {
    guard removedReport(path: path) != nil else { return }
    let incoming = candidates.filter { !displayRemoved($0) }
    for candidate in incoming {
      if let index = orphanCandidates.firstIndex(where: { $0.path == candidate.path }) {
        orphanCandidates[index] = candidate
      } else {
        orphanCandidates.append(candidate)
      }
      if retainedAppData[candidate.path] == nil {
        retainedAppData[candidate.path] = RetainedAppData(appPath: path, wasSelected: false)
        selectedOrphanPaths.remove(candidate.path)
      }
    }
    for itemID in Array(removedReports.keys) {
      guard var archived = removedReports[itemID], let index = archived.firstIndex(where: { $0.path == path }) else {
        continue
      }
      let paths = Set(incoming.map(\.path))
      archived[index].related = archived[index].related.filter { !paths.contains($0.path) } + incoming
      removedReports[itemID] = archived
    }
    displayRevision += 1
  }

  private func publishReview(_ review: ApplicationRelatedReview, path: String, ready: Bool = false) {
    guard let old = reports.first(where: { $0.path == path }),
      review.application.path == path || review.application.path == old.linkTarget,
      old.bundleID == review.application.bundleID
    else {
      message = String(localized: "The application changed. Refresh Apps before reviewing it.")
      return
    }
    let rank: Int?
    switch review.phase {
    case .legacy: rank = nil
    case .shallow: rank = 0
    case .measuring(let completed, _): rank = completed + 1
    case .initialComplete: rank = Int.max - 1
    case .enriched: rank = Int.max
    }
    if let rank {
      guard rank >= selectedReviewPhaseRank else { return }
      selectedReviewPhaseRank = rank
    }
    externalVolumesUnchecked = review.registrationReport?.externalVolumesUnchecked ?? externalVolumesUnchecked
    switch review.phase {
    case .legacy: break
    case .shallow:
      selectedShallowComplete = true
    case .measuring(let completed, let total):
      selectedShallowComplete = true
      selectedMeasurementProgress = (completed, total)
    case .initialComplete:
      selectedShallowComplete = true
      selectedMeasurementProgress = nil
    case .enriched:
      selectedEvidencePending = false
      selectedEvidenceFinished = true
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
    selectedDrawRevision += 1
    if ready { selectedReviewReadyAt = selectedReviewReadyAt ?? .now }
  }

  func selectedListDidDraw(_ snapshot: RelatedListViewportSnapshot, revision: Int) {
    guard !needsRescan, pictureRows.isEmpty, revision == selectedDrawRevision, selectedShallowComplete,
      snapshot.isComplete,
      let report = selectedReport, let started = selectedReviewRequestedAt,
      snapshot.candidatePaths == Set(report.related.map(\.path))
    else { return }
    let now = ContinuousClock.now
    if selectedListDrawnAt == nil {
      selectedListDrawnAt = now
      let duration = started.duration(to: now)
      let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
      let phase = selectedEvidenceFinished ? "enriched" : "shallow"
      relatedLogger.info(
        "selected-list ms=\(ms, privacy: .public) visible-rows=\(snapshot.visibleCount, privacy: .public) candidates=\(snapshot.candidatePaths.count, privacy: .public) phase=\(phase, privacy: .public)"
      )
    }
    if selectedEvidenceFinished, selectedEnrichedListDrawnAt == nil {
      selectedEnrichedListDrawnAt = now
      let duration = started.duration(to: now)
      let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
      relatedLogger.info(
        "selected-enriched-list ms=\(ms, privacy: .public) visible-rows=\(snapshot.visibleCount, privacy: .public) candidates=\(snapshot.candidatePaths.count, privacy: .public)"
      )
    }
  }

  private func publishRelated(path: String, candidates: [RelatedDataCandidate], ownershipPending: Bool) {
    guard let index = reports.firstIndex(where: { $0.path == path }), !displayRemoved(reports[index]) else {
      retainLateRelatedData(path: path, candidates: candidates)
      return
    }
    let incoming = candidates.filter { !displayRemoved($0) }
    let incomingPaths = Set(incoming.map(\.path))
    reports[index].related =
      ownershipPending
      ? incoming + reports[index].related.filter { !incomingPaths.contains($0.path) && !displayRemoved($0) }
      : incoming
    if ownershipPending { ownershipPendingPaths.insert(path) } else { ownershipPendingPaths.remove(path) }
    if selectedPath == path { selectedDrawRevision += 1 }
    if var choice = appSelections[path] {
      let invalidated = choice.manualData.keys.filter { selected in
        guard let original = choice.manualData[selected],
          let fresh = reports[index].related.first(where: { $0.path == selected })
        else { return true }
        return fresh.classification == .unprovenNameOnly
          ? !Self.sameUnprovenObservation(original, fresh) : !Self.sameDisplayedRoot(original, fresh)
      }
      for selected in invalidated {
        choice.dataPaths.remove(selected)
        choice.manualData.removeValue(forKey: selected)
      }
      for selected in Array(choice.manualData.keys) {
        if let fresh = reports[index].related.first(where: { $0.path == selected }) {
          if fresh.classification == .unprovenNameOnly {
            choice.manualData[selected] = fresh
          }
        }
      }
      let hasPresentedReview = presentedPlanID != nil && preparedActions?.pending?.id == presentedPlanID
      if selectedAppPaths.contains(path), !preparing, !hasPresentedReview {
        refreshAutomaticSelection(&choice, report: reports[index])
      }
      appSelections[path] = choice
      let affectsCurrentReview: Bool
      switch reviewKind {
      case .basket: affectsCurrentReview = selectedAppPaths.contains(path)
      case .focused: affectsCurrentReview = selectedPath == path
      case .orphans: affectsCurrentReview = false
      }
      if !invalidated.isEmpty, affectsCurrentReview {
        cancelPreparation(actions: preparedActions)
        message =
          String(localized: "An item you selected by name changed. Review it and select it again.")
          + " " + invalidated.sorted().joined(separator: ", ")
      }
    }
    relatedReviewedPaths.insert(path)
  }

  private func publishCoverage(_ inventory: BundleInventory) {
    guard !inventory.complete else {
      coverageIssueDescriptions = []
      return
    }
    var descriptions = inventory.unidentifiedPaths.map {
      String(localized: "Application could not be identified") + ": " + $0
    }
    descriptions += inventory.metadataIssues.map {
      String(localized: "Application metadata could not be read") + ": " + $0.path + " — " + $0.reason
    }
    descriptions += inventory.ownershipIssues.filter { !$0.systemScope }.map {
      String(localized: "Application ownership could not be checked") + ": " + $0.path + " — "
        + (String(cString: strerror($0.code)))
    }
    if let registration = inventory.registrationReport, !registration.complete {
      descriptions.append(String(localized: "Application registration lookup did not finish."))
    }
    if descriptions.isEmpty {
      descriptions.append(String(localized: "Some application associations could not be verified."))
    }
    coverageIssueDescriptions = Array(Set(descriptions)).sorted()
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
    let continueReview = preparing || reviewIntentRequested
    cancelPreparation(actions: actions, preserveReviewIntent: continueReview)
    guard let report = selectedReport, packageUnavailableReason(report) == nil else {
      packageSelected = false
      return
    }
    defer { if continueReview { continueReviewIntent(actions: actions) } }
    packageSelected.toggle()
    var choice = currentSelection
    refreshAutomaticSelection(&choice, report: report)
    currentSelection = choice
    updateBasketMembership()
  }

  func automaticSelectionAllowed(_ candidate: RelatedDataCandidate) -> Bool {
    automaticSelectionAllowed(
      candidate, appPath: selectedReport?.path, appBundleID: selectedReport?.bundleID,
      refusalEvidence: ownershipRefusalEvidence)
  }

  private func automaticSelectionAllowed(
    _ candidate: RelatedDataCandidate, appPath: String?, appBundleID: String?,
    refusalEvidence: [RelatedOwnershipRefusalEvidence]
  ) -> Bool {
    appBundleID != nil && appPath.map { !ownershipPendingPaths.contains($0) } == true
      && preferences.automaticallySelectRelatedData && candidate.automaticSelectionAllowed
      && candidate.defaultSelected
      && candidate.classification != .unprovenNameOnly && candidate.provenance?.kind != .configuredDirectory
      && candidate.refusalEvidence.isEmpty
      && !refusalEvidence.contains { $0.candidatePath == candidate.path }
  }

  /// Manual removal can be reviewed while evidence and sizes continue loading.
  func packageUnavailableReason(_ report: ApplicationReport) -> String? {
    if report.bundleID?.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame {
      return String(localized: "Lighten does not remove itself.")
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
    cancelPreparation(actions: actions)
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
    focusApp(path, defaultPackage: false)
    logPackageAvailability(actions: actions)
  }

  func toggleData(_ path: String, actions: ActionStore) {
    guard !needsRescan else { return }
    let continueReview = preparing || reviewIntentRequested
    cancelPreparation(actions: actions, preserveReviewIntent: continueReview)
    guard let app = selectedReport, let candidate = app.related.first(where: { $0.path == path }),
      canSelect(candidate, app: app)
    else { return }
    defer { if continueReview { continueReviewIntent(actions: actions) } }
    if selectedDataPaths.contains(path) {
      selectedDataPaths.remove(path)
      explicitlyDeselectedDataPaths.insert(path)
      explicitlySelectedUnproven.removeValue(forKey: path)
    } else {
      explicitlyDeselectedDataPaths.remove(path)
      currentSelection.automaticDataPaths.remove(path)
      selectedDataPaths.insert(path)
      if candidate.classification == .unprovenNameOnly { explicitlySelectedUnproven[path] = candidate }
    }
  }

  /// Leaving the screen keeps a running scan going; only prepared plans expire.
  func deactivate(actions: ActionStore) {
    selectedDrawRevision += 1
    dropGeneration = UUID()
    navigationGeneration = UUID()
    dropping = false
    cancelPreparation(actions: actions, keepPresentedPlanID: actions.busy)
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
      path: candidate.path,
      identity: candidate.displayRootIdentity
        ?? candidate.snapshot?.entries.first { $0.path == candidate.path }?.identity)
  }

  private func displayItem(_ item: ActionDisplayItem, matches candidate: RelatedDataCandidate) -> Bool {
    if candidate.path == item.path {
      let root =
        candidate.displayRootIdentity ?? candidate.snapshot?.entries.first { $0.path == candidate.path }?.identity
      return item.matches(path: candidate.path, identity: root)
    }
    return candidate.path.hasPrefix(item.path + "/")
      && candidate.snapshot?.entries.contains { item.matches(path: $0.path, identity: $0.identity) } == true
  }

  func publishOrphans(_ candidates: [RelatedDataCandidate]) {
    let retained = orphanCandidates.filter { retainedAppData[$0.path] != nil && !displayRemoved($0) }
    let retainedPaths = Set(retained.map(\.path))
    orphanCandidates = candidates.filter { !displayRemoved($0) && !retainedPaths.contains($0.path) } + retained
  }

  private func retainRelatedData(from reports: [ApplicationReport], moved: Set<String>) {
    for report in reports {
      for candidate in report.related where !moved.contains(candidate.path) {
        if !orphanCandidates.contains(where: { $0.path == candidate.path }) { orphanCandidates.append(candidate) }
        if retainedAppData[candidate.path] == nil {
          retainedAppData[candidate.path] = RetainedAppData(
            appPath: report.path, wasSelected: appSelections[report.path]?.dataPaths.contains(candidate.path) == true)
        }
      }
    }
  }

  func applyDisplayChange(_ change: ActionDisplayChange) {
    let moved = Set(change.items.map(\.path))
    for item in change.items {
      switch change.kind {
      case .applied:
        displayChanges[item.itemID] = item
        let physicalMatches = reports.filter { report in
          item.matches(path: report.linkTarget ?? report.path, identity: report.displayRootIdentity)
        }
        let explicitMatches = reports.filter { report in
          presentedPlanID == item.planID && presentedPackages[report.path]?.physical == item.itemID
            && report.path == item.path
        }
        let matched =
          physicalMatches.filter { $0.linkTarget == nil || moved.contains($0.path) }
          + explicitMatches.filter { row in !physicalMatches.contains { $0.path == row.path } }
        for report in physicalMatches where !matched.contains(where: { $0.path == report.path }) {
          incompletePackagePaths.insert(report.path)
        }
        retainRelatedData(from: matched, moved: moved)
        removedReports[item.itemID] = matched
        for report in matched where selectedPath == report.path {
          removedReviewTokens[report.path] = selectedReviewToken
        }
        reports.removeAll { report in matched.contains { $0.path == report.path } }
        var data: [String: [RelatedDataCandidate]] = [:]
        for index in reports.indices {
          let matched = reports[index].related.filter { candidate in
            displayItem(item, matches: candidate)
          }
          data[reports[index].path] = matched
          reports[index].related.removeAll { candidate in matched.contains { $0.path == candidate.path } }
        }
        removedData[item.itemID] = data
        let orphans = orphanCandidates.filter { candidate in
          displayItem(item, matches: candidate)
        }
        removedOrphans[item.itemID] = orphans
        removedRetainedData[item.itemID] = Dictionary(
          uniqueKeysWithValues: orphans.compactMap { candidate in
            retainedAppData[candidate.path].map { (candidate.path, $0) }
          })
        orphanCandidates.removeAll { candidate in orphans.contains { $0.path == candidate.path } }
        removedPaths.formUnion(matched.map(\.path))
        removedPaths.formUnion(data.values.flatMap { $0 }.map(\.path))
        for (path, candidates) in data {
          appSelections[path]?.dataPaths.subtract(candidates.map(\.path))
        }
        selectedOrphanPaths.subtract(orphans.map(\.path))
        if let selectedPath, matched.contains(where: { $0.path == selectedPath }) {
          self.selectedPath = nil
          packageSelected = false
        }
      case .restored:
        displayChanges.removeValue(forKey: item.itemID)
        for var report in removedReports.removeValue(forKey: item.itemID) ?? [] {
          removedPaths.remove(report.path)
          removedReviewTokens.removeValue(forKey: report.path)
          report.related.removeAll { displayRemoved($0) }
          incompletePackagePaths.remove(report.path)
          let retained = Set(report.related.map(\.path).filter { retainedAppData[$0]?.appPath == report.path })
          orphanCandidates.removeAll { retained.contains($0.path) }
          for path in retained { retainedAppData.removeValue(forKey: path) }
          selectedOrphanPaths.subtract(retained)
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
        let retained = removedRetainedData.removeValue(forKey: item.itemID) ?? [:]
        for candidate in removedOrphans.removeValue(forKey: item.itemID) ?? [] {
          removedPaths.remove(candidate.path)
          if let owner = retained[candidate.path], let index = reports.firstIndex(where: { $0.path == owner.appPath }) {
            if !reports[index].related.contains(where: { $0.path == candidate.path }) {
              reports[index].related.append(candidate)
            }
          } else {
            if !orphanCandidates.contains(where: { $0.path == candidate.path }) { orphanCandidates.append(candidate) }
            if let owner = retained[candidate.path] { retainedAppData[candidate.path] = owner }
          }
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
    cancelPreparation(actions: actions, keepPresentedPlanID: true)
    let moved = Set(
      result.items.filter { $0.outcome == .applied }.compactMap { presentedPaths[$0.itemID] })
    let results = Dictionary(uniqueKeysWithValues: result.items.map { ($0.itemID, $0) })
    packageItemResults = presentedPackageItems.compactMap { item in
      guard let outcome = results[item.id] else { return nil }
      return PackageItemResult(
        id: item.id, sourcePath: item.sourcePath,
        isLink: item.policy == .applicationLink, outcome: outcome.outcome, detail: outcome.detail,
        mutationStage: outcome.mutationStage)
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
    for report in reports where removedApplications.contains(report.path) {
      guard let itemID = presentedPackages[report.path]?.physical else { continue }
      if removedReports[itemID]?.contains(where: { $0.path == report.path }) != true {
        removedReports[itemID, default: []].append(report)
      }
      if selectedPath == report.path { removedReviewTokens[report.path] = selectedReviewToken }
    }
    let removedRows = moved.subtracting(presentedPackages.keys).union(removedApplications)
    removedPaths.formUnion(moved.subtracting(incompletePackagePaths).union(removedApplications))
    retainRelatedData(from: reports.filter { removedRows.contains($0.path) }, moved: moved)
    for path in retainedAppData.keys {
      guard var retained = retainedAppData[path] else { continue }
      if let rejection = actions.resultRejections.first(where: { $0.path == path }) { retained.rejection = rejection }
      if let result = presentedPaths.first(where: { $0.value == path }).flatMap({ results[$0.key] }) {
        retained.result = result
      }
      retainedAppData[path] = retained
    }
    reports = reports.filter { !removedRows.contains($0.path) }.map { report in
      var refreshed = report
      refreshed.related.removeAll { moved.contains($0.path) }
      return refreshed
    }
    orphanCandidates.removeAll { moved.contains($0.path) }
    for path in moved { retainedAppData.removeValue(forKey: path) }
    for path in Array(appSelections.keys) {
      guard var choice = appSelections[path] else { continue }
      choice.dataPaths.subtract(moved)
      choice.automaticDataPaths.subtract(moved)
      choice.manualData = choice.manualData.filter { !moved.contains($0.key) }
      if removedApplications.contains(path) { choice.packageSelected = false }
      appSelections[path] = choice
    }
    selectedAppPaths.subtract(removedApplications)
    selectedAppPaths = selectedAppPaths.filter { appSelections[$0]?.hasChoice == true }
    selectedOrphanPaths.subtract(moved)
    if let selectedPath, removedRows.contains(selectedPath) { self.selectedPath = nil }
    message = nil
  }

  func canSelect(_ candidate: RelatedDataCandidate, app: ApplicationReport) -> Bool {
    !needsRescan && pictureRows.isEmpty && !dropping
      && app.related.contains { $0.path == candidate.path }
  }

  nonisolated static func provenanceLabel(_ kind: RelatedDataProvenanceKind) -> String {
    switch kind {
    case .bundleIdentifier: String(localized: "Evidence: bundle identifier")
    case .teamIdentifier: String(localized: "Evidence: signing team identifier")
    case .electron: String(localized: "Evidence: Electron package settings and data structure")
    case .mozilla: String(localized: "Evidence: Mozilla package settings and profile structure")
    case .installerReceipt: String(localized: "Evidence: app installation record")
    case .launchService: String(localized: "Evidence: launch service points into this app")
    case .configuredDirectory: String(localized: "Evidence: directory named in this app’s settings")
    case .vendorDirectory: String(localized: "Evidence: app vendor data folder")
    case .liveProcess: String(localized: "Evidence: this app’s open files or working directory")
    case .executableName:
      String(localized: "Only the name resembles the app; ownership is unproven. Select it only if you recognize it.")
    case .explicitUserChoice: String(localized: "Your explicit choice · ownership remains unproven")
    }
  }

  private nonisolated static func sameUnprovenObservation(
    _ original: RelatedDataCandidate, _ current: RelatedDataCandidate
  ) -> Bool {
    guard current.classification == .unprovenNameOnly, current.reason == .nameOnly,
      current.explicitManualChoiceAvailable, current.refusalEvidence.isEmpty,
      let oldRoot = original.snapshot?.entries.first(where: { $0.path == original.path })?.identity
        ?? original.displayRootIdentity,
      let newRoot = current.snapshot?.entries.first(where: { $0.path == current.path })?.identity
        ?? current.displayRootIdentity
    else { return false }
    return original.path == current.path && oldRoot == newRoot
  }

  private nonisolated static func sameDisplayedRoot(_ original: RelatedDataCandidate, _ current: RelatedDataCandidate)
    -> Bool
  {
    guard original.path == current.path,
      let old = original.snapshot?.entries.first(where: { $0.path == original.path })?.identity
        ?? original.displayRootIdentity,
      let fresh = current.snapshot?.entries.first(where: { $0.path == current.path })?.identity
        ?? current.displayRootIdentity
    else { return false }
    return old == fresh
  }

  func retainedReason(_ candidate: RelatedDataCandidate, turkish: Bool? = nil) -> FailurePresentation? {
    guard let retained = retainedAppData[candidate.path] else { return nil }
    let prefix: String
    let cause: FailurePresentation
    if let result = retained.result {
      prefix =
        FailureText.executionIsUnverified(result)
        ? FailureText.retainedPrefix("review", turkish: turkish)
        : FailureText.retainedPrefix("notMoved", turkish: turkish)
      if FailureText.executionIsUnverified(result) {
        let copy = FailureText.executionPresentation(result, turkish: turkish)
        return FailurePresentation(
          reasons: [prefix] + copy.reasons, nextStep: copy.nextStep, unknownCodes: copy.unknownCodes)
      }
      cause =
        result.detail.map { FailureText.presentation($0, turkish: turkish) }
        ?? FailureText.presentation(result.outcome == .skipped ? "skipped" : "notAttempted", turkish: turkish)
    } else if let rejection = retained.rejection {
      prefix = FailureText.retainedPrefix("refused", turkish: turkish)
      cause = FailureText.presentation(rejection, turkish: turkish)
    } else {
      prefix = FailureText.retainedPrefix("notSelected", turkish: turkish)
      cause = FailureText.candidate(candidate, turkish: turkish)
    }
    return FailurePresentation(
      reasons: [prefix] + cause.reasons, nextStep: cause.nextStep, unknownCodes: cause.unknownCodes)
  }

  func canSelectOrphan(_ candidate: RelatedDataCandidate) -> Bool {
    !needsRescan && !dropping && pictureRows.isEmpty
      && orphanCandidates.contains { $0.path == candidate.path }
  }

  func toggleOrphan(_ path: String, actions: ActionStore) {
    guard !needsRescan, !dropping, pictureRows.isEmpty,
      orphanCandidates.contains(where: { $0.path == path && canSelectOrphan($0) })
    else { return }
    let continueReview = preparing || reviewIntentRequested
    cancelPreparation(actions: actions, preserveReviewIntent: continueReview)
    if selectedOrphanPaths.contains(path) { selectedOrphanPaths.remove(path) } else { selectedOrphanPaths.insert(path) }
    if continueReview { continueReviewIntent(actions: actions, orphans: true) }
  }

  func prepareOrphans(actions: ActionStore) async {
    guard !preparing, !needsRescan, !actions.busy, pictureRows.isEmpty else { return }
    reviewKind = .orphans
    let candidates = orphanCandidates.filter {
      selectedOrphanPaths.contains($0.path) && canSelectOrphan($0)
    }
    guard !candidates.isEmpty else { return }
    let paths = selectedOrphanPaths
    if !usesInjectedPlanner {
      let planner = userPlanner
      let kind = preferences.deletionDefault.kind
      await prepare(
        actions: actions, stillSelected: { self.selectedOrphanPaths == paths },
        builder: {
          let outcome = await planner.makeAvailableUserSelectionPlan(
            selections: candidates.map(Self.userSelection), kind: kind)
          return .init(plan: outcome.plan, rejections: outcome.rejections)
        })
      return
    }
    let builder = orphanPlanBuilder
    let remainingBuilder = remainingDataPlanBuilder
    let hasRetained = candidates.contains { retainedAppData[$0.path] != nil }
    await prepare(
      actions: actions, stillSelected: { self.selectedOrphanPaths == paths },
      builder: {
        if hasRetained { return await remainingBuilder(candidates) }
        return RelatedDataService.AvailableUninstallPlan(plan: try await builder(candidates), rejections: [])
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
    cancelPreparation(actions: actions)
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
    selectedAppPaths = []
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
      var choice = currentSelection
      refreshAutomaticSelection(&choice, report: report)
      currentSelection = choice
      await prepareSelectedData(actions: actions)
      return
    }
    message = reason
  }

  private func cancelPreparation(
    actions: ActionStore? = nil, keepPresentedPlanID: Bool = false, preserveReviewIntent: Bool = false
  ) {
    let actions = actions ?? preparedActions
    actions?.clearKeptItems()
    choiceRevision = UUID()
    preparationTask?.cancel()
    preparationTask = nil
    tool.preparation.invalidatePreparation()
    preparationStage = nil
    if !preserveReviewIntent { reviewIntentRequested = false }
    let pendingMatches = actions?.pending?.id == presentedPlanID && presentedPlanID != nil
    if pendingMatches { actions?.pending = nil }
    if !keepPresentedPlanID || pendingMatches { presentedPlanID = nil }
  }

  private func continueReviewIntent(actions: ActionStore, orphans: Bool = false) {
    reviewIntentRequested = true
    let id = choiceRevision
    if orphans { reviewKind = .orphans }
    let hasChoice: Bool
    switch reviewKind {
    case .orphans: hasChoice = !selectedOrphanPaths.isEmpty
    case .basket: hasChoice = selectedAppPaths.contains { appSelections[$0]?.hasChoice == true }
    case .focused: hasChoice = packageSelected || !selectedDataPaths.isEmpty
    }
    guard hasChoice else {
      message = String(localized: "Selection changed. Select an item to continue the removal review.")
      return
    }
    Task { @MainActor [weak self, weak actions] in
      guard let self, let actions, self.choiceRevision == id, self.reviewIntentRequested else { return }
      if self.reviewKind == .orphans {
        await self.prepareOrphans(actions: actions)
      } else if self.reviewKind == .basket {
        await self.prepareBasket(actions: actions)
      } else {
        await self.prepareSelectedData(actions: actions)
      }
    }
  }

  func reviewExplanation(actions: ActionStore) -> String {
    if actions.busy { return String(localized: "Waiting for the current action to finish.") }
    if preparing {
      return preparationStage == .runningApplications
        ? String(localized: "Checking whether selected apps are running…")
        : String(localized: "Checking selected items before opening the removal review…")
    }
    if needsRescan { return String(localized: "Scan again to review data") }
    if relatedDiscoveryStopped {
      return String(
        localized: "Related discovery stopped. Review the app and files already listed, or scan again to find more.")
    }
    return selectedReviewPending
      ? String(localized: "Checking this app’s data. You can review the app itself now.")
      : String(localized: "Select the app, its data, or both")
  }

  func canReviewSelectedData(actions: ActionStore) -> Bool {
    !preparing && !needsRescan && !actions.busy && pictureRows.isEmpty
      && selectedReport != nil && (packageSelected || !selectedDataPaths.isEmpty)
  }

  func prepareSelectedData(actions: ActionStore) async {
    guard canReviewSelectedData(actions: actions), let report = selectedReport
    else {
      message = String(localized: "Select the app or eligible related data")
      return
    }
    reviewKind = .focused
    var choice = currentSelection
    refreshAutomaticSelection(&choice, report: report, addingNew: false)
    currentSelection = choice
    if packageSelected, let reason = packageUnavailableReason(report) {
      message = reason
      return
    }
    if !usesInjectedPlanner {
      let paths = selectedDataPaths
      let includePackage = packageSelected
      let planner = userPlanner
      let kind = preferences.deletionDefault.kind
      var selections = report.related.filter { paths.contains($0.path) }.map(Self.userSelection)
      if includePackage {
        selections.append(
          UserSelection(
            path: report.path,
            expectedIdentity: listedIdentities[report.path]
              ?? (report.linkTarget == nil ? report.displayRootIdentity : nil),
            observedSize: ObservedPlanSize(logical: report.logical, allocated: report.allocated),
            applicationPackagePaths: [report.path]))
      }
      let chosen = selections
      let missing = paths.subtracting(report.related.map(\.path)).sorted().map {
        PlanRejection(.unavailable, path: $0)
      }
      await prepare(
        actions: actions,
        stillSelected: {
          self.selectedPath == report.path && self.selectedDataPaths == paths && self.packageSelected == includePackage
        },
        builder: {
          let outcome = await planner.makeAvailableUserSelectionPlan(selections: chosen, kind: kind)
          return .init(plan: outcome.plan, rejections: missing + outcome.rejections)
        })
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
    selectedByNamePaths: Set<String>? = nil,
    refusalTargets: [String: Set<String>]? = nil,
    builder: @escaping @Sendable () async throws -> RelatedDataService.AvailableUninstallPlan
  ) async {
    actions.clearKeptItems()
    guard let id = tool.preparation.begin() else { return }
    let manualPaths = selectedByNamePaths ?? Set(explicitlySelectedUnproven.keys)
    var automaticProof: [String: String] = [:]
    for report in reports {
      guard let choice = appSelections[report.path] else { continue }
      for candidate in report.related where choice.automaticDataPaths.contains(candidate.path) {
        let kinds =
          candidate.evidenceKinds.isEmpty ? candidate.provenance.map { [$0.kind] } ?? [] : candidate.evidenceKinds
        automaticProof[candidate.path] = kinds.map(Self.provenanceLabel).joined(separator: " · ")
      }
    }
    reviewIntentRequested = true
    preparationStage = .selectedItems
    message = nil
    preparedActions = actions
    let requestedAt = ContinuousClock.now
    relatedLogger.info("review-preparation requested")
    defer {
      if tool.preparation.accepts(id) {
        tool.preparation.finish(id)
        preparationTask = nil
        preparationStage = nil
        reviewIntentRequested = false
      }
    }
    do {
      let timeout = preparationTimeout
      let task = Task(priority: .userInitiated) { @concurrent in
        let race = PreparationRace()
        // Unstructured tasks allow the review to return even when an observation ignores cancellation.
        // A single terminal result prevents late observation and deadline callbacks from presenting twice.
        let observation = Task(priority: .userInitiated) { @concurrent in
          do {
            let outcome = try await builder()
            try Task.checkCancellation()
            var running = false
            if let plan = outcome.plan {
              await MainActor.run {
                guard self.tool.preparation.accepts(id) else { return }
                self.preparationStage = .runningApplications
              }
              running = await actions.containsRunningApplications(plan)
            }
            try Task.checkCancellation()
            await race.finish(.success(PreparedRemoval(outcome: outcome, hasRunningApplications: running)))
          } catch { await race.finish(.failure(error)) }
        }
        let deadline = Task { @concurrent in
          do {
            try await timeout()
            try Task.checkCancellation()
            await race.finish(.failure(PreparationFailure.timedOut))
          } catch {
            if !Task.isCancelled { await race.finish(.failure(error)) }
          }
        }
        defer {
          observation.cancel()
          deadline.cancel()
        }
        return try await withTaskCancellationHandler {
          try await race.value()
        } onCancel: {
          Task { await race.finish(.failure(CancellationError())) }
        }
      }
      preparationTask = task
      let prepared = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      let outcome = prepared.outcome
      guard tool.preparation.accepts(id), stillSelected(), !task.isCancelled, !Task.isCancelled, !actions.busy else {
        return
      }
      if let refusalTargets {
        for (path, dataPaths) in refusalTargets {
          appSelections[path]?.refusalEvidence = outcome.refusalEvidence.filter { dataPaths.contains($0.candidatePath) }
        }
      } else {
        ownershipRefusalEvidence = outcome.refusalEvidence
      }
      guard let plan = outcome.plan else {
        if outcome.rejections.isEmpty {
          message = String(localized: "Select the app or eligible related data")
        } else {
          showKeptItems(outcome.rejections, actions: actions)
        }
        return
      }
      guard tool.preparation.accepts(id), stillSelected(), !Task.isCancelled, !actions.busy else { return }
      let summaries = plan.items.map { item in
        let size = PlanItemSize.measure(item)
        let selectedByName = manualPaths.contains(item.sourcePath)
        let dataReason = String(
          localized: "Selected app data. Preferences and support files may contain personal settings or documents.")
        let automaticReason = automaticProof[item.sourcePath].map { $0 + " · " + dataReason }
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
                : automaticReason ?? dataReason,
          logicalBytes: size.logical, allocatedBytes: size.allocated)
      }
      guard tool.preparation.accepts(id), stillSelected(), !Task.isCancelled, !actions.busy else { return }
      actions.present(
        plan: plan, items: summaries, rejectedItems: outcome.rejections,
        hasRunningApplications: prepared.hasRunningApplications)
      guard actions.pending?.id == plan.id else { return }
      presentedPaths = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.sourcePath) })
      presentedPackageItems = plan.items.filter {
        $0.policy == .wholeBundle || $0.policy == .applicationLink
          || ($0.userSelection == true && $0.sourcePath.lowercased().hasSuffix(".app"))
      }
      presentedPackages = [:]
      for package in presentedPackageItems where package.policy == .wholeBundle || package.userSelection == true {
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
      let ms = Self.milliseconds(requestedAt.duration(to: .now))
      relatedLogger.info("review-preparation ms=\(ms, privacy: .public) outcome=presented")
    } catch PreparationFailure.timedOut {
      if tool.preparation.accepts(id), stillSelected(), !Task.isCancelled, !actions.busy {
        message =
          preparationStage == .runningApplications
          ? String(localized: "Checking running apps took too long. Your selection is unchanged. Try reviewing again.")
          : String(
            localized: "Checking selected items took too long. Your selection is unchanged. Try reviewing again.")
        let ms = Self.milliseconds(requestedAt.duration(to: .now))
        relatedLogger.info("review-preparation ms=\(ms, privacy: .public) outcome=timed-out")
      }
    } catch let refused as PlanRejections {
      if tool.preparation.accepts(id), stillSelected(), !Task.isCancelled, !actions.busy {
        showKeptItems(refused.rejections, actions: actions)
      }
    } catch let refused as PlanRejection {
      if tool.preparation.accepts(id), stillSelected(), !Task.isCancelled, !actions.busy {
        showKeptItems([refused], actions: actions)
      }
    } catch {
      if tool.preparation.accepts(id), stillSelected(), !Task.isCancelled, !actions.busy {
        message = FailureText.describe(error)
      }
    }
  }

  private func showKeptItems(_ rejections: [PlanRejection], actions: ActionStore) {
    actions.publishKeptItems(rejections)
    packageItemResults = []
    message = nil
  }

  private nonisolated static func userSelection(_ candidate: RelatedDataCandidate) -> UserSelection {
    let root = candidate.snapshot?.entries.first { $0.path == candidate.path }
    let size = candidate.snapshot?.nodes.first { $0.id == root?.id }.map {
      ObservedPlanSize(logical: $0.logical, allocated: $0.allocated)
    }
    let example =
      candidate.provenance?.kind == .configuredDirectory
      ? candidate.path
      : SelectionWarning.example(in: candidate.snapshot?.entries.map(\.path) ?? [candidate.path])
    return UserSelection(
      path: candidate.path, expectedIdentity: root?.identity ?? candidate.displayRootIdentity, observedSize: size,
      warnings: example.map { [UserSelectionWarning(examplePath: $0)] } ?? [],
      applicationPackagePaths: ActionStore.observedApplicationPackagePaths(
        in: candidate.snapshot?.entries.map(\.path) ?? [], under: candidate.path))
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
