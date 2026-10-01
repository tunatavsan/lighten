import AppKit
import Darwin
import Foundation
import LightenKit

/// Produces read-only observations and fresh Trash-plan refusals. No plan is executed.
@MainActor
final class RealUseSurvey {
  private struct Target {
    let id: String
    let path: String
    let scope: String
    let owner: String?
    let logical: ByteAggregate?
    let allocated: ByteAggregate?
    let candidateClassification: String?
    let candidateReason: String?
    let provenanceKind: String?
    let evidenceKinds: [String]
    let automaticSelectionAllowed: Bool?
    let defaultSelected: Bool?
    var outcome = "pending"
  }

  private let home: String
  private let scope: String
  private let folderLimit: Int
  private let timeout: Double
  private let workers: Int
  private let environment: BenchEnvironment
  private let started = ContinuousClock.now
  private var targets: [String: Target] = [:]
  private var stage = "starting"
  private var discoverySeconds = 0.0
  private var folderScanSeconds = 0.0
  private var planSeconds = 0.0
  private var validationSeconds = 0.0
  private var appPlanTimes: [Double] = []
  private var completedApplications = 0
  private var observedApplications = 0
  private var folderPoolCount = 0
  private var folderPoolPaths: Set<String> = []
  private var completedFolderRoots = 0
  private var listingComplete = false
  private var ownershipComplete = false
  private var metadataIssueCount = 0
  private var liveDataCensus: ApplicationLiveDataCensusReport?
  private var registrationReport: ApplicationRegistrationReport?
  private var knownUniverseApplicationCount: Int?
  private var registrationReported = false
  private var unsafeAutomaticSelections: [String: [String: Any]] = [:]
  private var unattributedRejectionCount = 0
  private var unattributedErrorCount = 0
  private var foldersComplete = true
  private var foldersFinished = false
  private var discoveryComplete = false
  private var discoveryStarted: ContinuousClock.Instant?
  private var folderScanStarted: ContinuousClock.Instant?
  private var activePlanStarted: ContinuousClock.Instant?
  private var activeValidationStarted: ContinuousClock.Instant?
  private var finished = false
  private var session: ApplicationScanSession?

  static func run(options: Options, environment: BenchEnvironment) async -> Int32 {
    let home = options.string("home") ?? NSHomeDirectory()
    let scope = options.string("scope") ?? "all"
    let limit = options.string("folder-limit").map { Int($0) ?? 0 } ?? 30
    let timeout = options.string("timeout").map { Double($0) ?? 0 } ?? 900
    let workers = options.string("workers").map { Int($0) ?? 0 } ?? ScanConfiguration.defaultWorkers
    guard home.hasPrefix("/"), ["all", "space", "apps"].contains(scope), (1...1000).contains(limit),
      timeout.isFinite, timeout > 0, timeout <= 900, (1...32).contains(workers)
    else {
      FileHandle.standardError.write(Data("survey: invalid home, scope, folder-limit, timeout, or workers\n".utf8))
      return 64
    }
    let survey = RealUseSurvey(
      home: URL(fileURLWithPath: home).standardizedFileURL.path, scope: scope,
      folderLimit: limit, timeout: timeout, workers: workers, environment: environment)
    // The deadline emits the completed subset before exiting this read-only process.
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(timeout))
      guard !Task.isCancelled, !survey.finished else { return }
      survey.finish(timedOut: true)
      exit(2)
    }
    defer { watchdog.cancel() }
    await survey.observe()
    return survey.finish(timedOut: false)
  }

  private init(
    home: String, scope: String, folderLimit: Int, timeout: Double, workers: Int,
    environment: BenchEnvironment
  ) {
    self.home = home
    self.scope = scope
    self.folderLimit = folderLimit
    self.timeout = timeout
    self.workers = workers
    self.environment = environment
  }

  private func observe() async {
    line([
      "type": "start", "schema": 1, "command": "survey", "home": home, "scope": scope,
      "folderLimit": folderLimit, "allInstalledApplications": scope != "space", "timeoutSeconds": timeout,
      "configuredScanWorkers": workers,
      "receiptWrites": false, "planExecution": false, "environmentStart": environment.json,
    ])
    if scope != "space" {
      stage = "native-live-data-census"
      let census = await Self.observeLiveDataCensus()
      liveDataCensus = census
      var row = Self.censusDetails(census)
      row["type"] = "liveDataCensusObservation"
      row["dataSource"] = "standalone native current-user census; not action authority"
      line(row)
    }
    if scope != "apps" { await observeFolders() }
    if scope != "space" { await observeApplications() }
  }

  private func observeFolders() async {
    stage = "folder-discovery"
    let start = ContinuousClock.now
    folderScanStarted = start
    let roots = [
      home + "/Library/Application Support", home + "/Library/Caches", home + "/Library/Containers",
      home + "/Library/Developer", home + "/Downloads", home + "/Documents",
    ]
    var folders: [(SpaceItem, UUID, String)] = []
    let engine = ScanEngine(configuration: ScanConfiguration(workers: workers, homeDirectory: home))
    for root in roots {
      progress(path: root)
      var info = stat()
      if lstat(root, &info) != 0, errno == ENOENT {
        line(["type": "root", "path": root, "status": "absent", "errno": ENOENT])
        completedFolderRoots += 1
        continue
      }
      do {
        let run = try engine.start(root: root)
        await run.waitUntilFinished()
        let rootItem = run.tree.item(run.tree.rootID)
        line([
          "type": "root", "path": root, "status": "observed", "partial": rootItem?.partial ?? true,
          "bytes": bytes(rootItem?.logical, rootItem?.allocated), "cancelled": run.tree.wasCancelled,
        ])
        if run.tree.wasCancelled || rootItem?.partial != false { foldersComplete = false }
        var pending = [run.tree.rootID]
        while let parent = pending.popLast() {
          for item in run.tree.children(of: parent, metric: .logical)
          where item.kind == .directory || item.kind == .package {
            folders.append((item, run.runID, root))
            folderPoolPaths.insert(item.path)
            if item.canInspect { pending.append(item.id) }
          }
        }
      } catch {
        foldersComplete = false
        line(["type": "root", "path": root, "status": "unavailable", "error": String(describing: error)])
      }
      completedFolderRoots += 1
      folderPoolCount = folders.count
      folderScanSeconds = elapsed(start)
      progress(path: root, extra: ["folderPoolCount": folderPoolCount, "completedRoots": completedFolderRoots])
    }
    folderScanSeconds = elapsed(start)
    folderPoolCount = folders.count
    folderScanStarted = nil
    foldersFinished = true
    folders.sort {
      $0.0.logical.knownLowerBound != $1.0.logical.knownLowerBound
        ? $0.0.logical.knownLowerBound > $1.0.logical.knownLowerBound : $0.0.path < $1.0.path
    }
    let selected = Array(folders.prefix(folderLimit))
    for (item, _, root) in selected {
      register(
        path: item.path, scope: "space", owner: nil, logical: item.logical, allocated: item.allocated,
        extra: ["scanRoot": root, "itemState": String(describing: item.state), "kind": String(describing: item.kind)])
    }
    for (item, runID, _) in selected {
      stage = "folder-planning"
      progress(path: item.path)
      let start = ContinuousClock.now
      activePlanStarted = start
      let outcome = await PlanService(homeDirectory: home).makeAvailableUserSelectionPlan(
        selections: [
          UserSelection(
            path: item.path, expectedIdentity: try? KnownPathFileSystem.identity(at: item.path),
            observedSize: ObservedPlanSize(logical: item.logical, allocated: item.allocated))
        ], runID: runID)
      let planning = elapsed(start)
      planSeconds += planning
      activePlanStarted = nil
      stage = "folder-validation"
      let checkedAt = ContinuousClock.now
      activeValidationStarted = outcome.plan == nil ? nil : checkedAt
      let validation = await Self.validateUserSelection(outcome.plan, home: home)
      let checking = outcome.plan == nil ? nil : elapsed(checkedAt)
      validationSeconds += checking ?? 0
      activeValidationStarted = nil
      await result(
        path: item.path, scope: "space", owner: nil, rejections: outcome.rejections + validation,
        planned: outcome.plan?.items.contains { $0.sourcePath == item.path } == true,
        planning: planning, validation: checking)
    }
  }

  private func observeApplications() async {
    stage = "application-discovery"
    let start = ContinuousClock.now
    discoveryStarted = start
    let service = RelatedDataService(homeDirectory: home, writeVerifiedReceipts: false)
    let session = ApplicationDiscovery(related: service).scanSession()
    self.session = session
    var reports: [ApplicationReport] = []
    for await event in await session.events(includeAllRelated: true) {
      switch event {
      case .inventory(let inventory, let current), .completed(let inventory, let current):
        reports = current
        listingComplete = inventory.complete
        ownershipComplete = inventory.ownershipComplete
        registrationReport = inventory.registrationReport
        knownUniverseApplicationCount = inventory.applications.count
        if case .completed = event { reportRegistration() }
        registerScopeExclusions(inventory.scopeExclusions)
        observedApplications = Set(current.map(\.path)).count
        if case .completed = event { discoveryComplete = true }
        registerReports(current)
      case .ownershipReady(let inventory):
        listingComplete = inventory.complete
        ownershipComplete = inventory.ownershipComplete
        registrationReport = inventory.registrationReport
        knownUniverseApplicationCount = inventory.applications.count
        reportRegistration()
        registerScopeExclusions(inventory.scopeExclusions)
        for issue in inventory.ownershipIssues {
          line([
            "type": "ownershipIssue", "path": issue.path, "errno": issue.code,
            "systemScope": issue.systemScope,
          ])
        }
        metadataIssueCount = inventory.metadataIssues.count
        for issue in inventory.metadataIssues {
          line([
            "type": "applicationMetadataIssue", "path": issue.path, "reason": issue.reason,
          ])
        }
      case .measured(let current):
        reports = current
        registerReports(current)
      case .related(let path, let candidates, let ownershipPending):
        for candidate in candidates {
          registerRelated(
            candidate, scope: "installedRelated", owner: path,
            extra: ["ownershipPending": ownershipPending])
        }
      case .orphans(let candidates):
        for candidate in candidates { registerRelated(candidate, scope: "orphanRelated", owner: nil) }
      default: break
      }
      discoverySeconds = elapsed(start)
      progress(path: "application-discovery", extra: ["observedApplications": observedApplications])
    }
    let allData = await session.observedRelatedCandidates()
    discoverySeconds = elapsed(start)
    discoveryStarted = nil
    registerReports(reports)
    let installedPaths = Set(reports.flatMap { $0.related.map(\.path) })
    for candidate in allData where !installedPaths.contains(candidate.path) {
      let kind =
        candidate.classification == .orphanVerified || candidate.classification == .historicallyVerifiedAbsent
        ? "orphanRelated" : "unmatchedRelated"
      registerRelated(candidate, scope: kind, owner: nil)
    }
    for report in reports {
      stage = "application-planning"
      progress(path: report.path)
      let start = ContinuousClock.now
      activePlanStarted = start
      // Each root is explicitly selected for this read-only probe. Recommendation
      // evidence and automatic-selection accounting remain discovery observations.
      let selections =
        [
          UserSelection(
            path: report.path,
            expectedIdentity: report.linkTarget == nil
              ? report.displayRootIdentity : try? KnownPathFileSystem.identity(at: report.path),
            observedSize: ObservedPlanSize(logical: report.logical, allocated: report.allocated))
        ]
        + report.related.map(Self.userSelection)
      let outcome = await PlanService(homeDirectory: home).makeAvailableUserSelectionPlan(selections: selections)
      let planning = elapsed(start)
      planSeconds += planning
      appPlanTimes.append(planning)
      activePlanStarted = nil
      stage = "application-validation"
      let checkedAt = ContinuousClock.now
      activeValidationStarted = outcome.plan == nil ? nil : checkedAt
      let validation = await Self.validateUserSelection(outcome.plan, home: home)
      let checking = outcome.plan == nil ? nil : elapsed(checkedAt)
      validationSeconds += checking ?? 0
      activeValidationStarted = nil
      let rejections = outcome.rejections + validation
      let evidence: [RelatedOwnershipRefusalEvidence] = []
      let packageItems = outcome.plan?.items.filter { $0.sourcePath == report.path } ?? []
      let packageRoots = [report.path]
      let roots = packageRoots + report.related.map(\.path)
      let unassigned = rejections.filter { rejection in
        !roots.contains { Self.covers(root: $0, path: rejection.path) }
      }
      let packageRefusals = rejections.filter { rejection in
        packageRoots.contains { Self.covers(root: $0, path: rejection.path) }
      }
      for rejection in unassigned {
        let row = await refusal(rejection, evidence: evidence)
        unattributedRejectionCount += 1
        if row["classification"] as? String != "legitimate" { unattributedErrorCount += 1 }
        line([
          "type": "unattributedPlanRejection", "ownerApplicationPath": report.path,
          "includedInApplicationDenominator": false, "rejection": row,
          "owningRequestOutcome": "errorRefusal",
        ])
      }
      let packagePlanned = packageItems.count == 1
      let packageDetails = await applicationPlanDetails(
        report: report, items: packageItems, rejections: packageRefusals, evidence: evidence,
        validationPerformed: checking != nil)
      await result(
        path: report.path, scope: "application", owner: report.path, rejections: packageRefusals + unassigned,
        planned: packagePlanned, planning: planning, validation: checking, evidence: evidence,
        extra: packageDetails, forceError: !unassigned.isEmpty)
      for candidate in report.related {
        let refusals = rejections.filter {
          Self.covers(root: candidate.path, path: $0.path) || Self.covers(root: $0.path, path: candidate.path)
        }
        await result(
          path: candidate.path, scope: "installedRelated", owner: report.path,
          rejections: packageRefusals.isEmpty ? refusals : packageRefusals + refusals,
          planned: outcome.plan?.items.contains { Self.covers(root: $0.sourcePath, path: candidate.path) } == true,
          planning: planning, validation: checking,
          evidence: evidence,
          extra: Self.candidateDetails(candidate).merging([
            "selectedRootPath": outcome.plan?.items.first {
              Self.covers(root: $0.sourcePath, path: candidate.path)
            }?.sourcePath as Any? ?? NSNull()
          ]) { _, value in value })
      }
      completedApplications += 1
    }
    for candidate in allData where !installedPaths.contains(candidate.path) {
      let kind =
        candidate.classification == .orphanVerified || candidate.classification == .historicallyVerifiedAbsent
        ? "orphanRelated" : "unmatchedRelated"
      stage = "related-planning"
      progress(path: candidate.path)
      let start = ContinuousClock.now
      activePlanStarted = start
      let outcome = await PlanService(homeDirectory: home).makeAvailableUserSelectionPlan(
        selections: [Self.userSelection(candidate)])
      let planning = elapsed(start)
      planSeconds += planning
      activePlanStarted = nil
      stage = "related-validation"
      let checkedAt = ContinuousClock.now
      activeValidationStarted = outcome.plan == nil ? nil : checkedAt
      let validation = await Self.validateUserSelection(outcome.plan, home: home)
      let checking = outcome.plan == nil ? nil : elapsed(checkedAt)
      validationSeconds += checking ?? 0
      activeValidationStarted = nil
      await result(
        path: candidate.path, scope: kind, owner: nil,
        rejections: outcome.rejections + validation,
        planned: outcome.plan?.items.contains { $0.sourcePath == candidate.path } == true,
        planning: planning, validation: checking,
        extra: Self.candidateDetails(candidate))
    }
    await session.cancel()
    self.session = nil
  }

  private func registerReports(_ reports: [ApplicationReport]) {
    for report in reports {
      register(
        path: report.path, scope: "application", owner: report.path,
        logical: report.logical, allocated: report.allocated,
        extra: [
          "bundleID": report.bundleID as Any? ?? NSNull(), "linkTarget": report.linkTarget as Any? ?? NSNull(),
          "isIOSWrapper": report.isIOSWrapper,
        ])
      for candidate in report.related {
        registerRelated(candidate, scope: "installedRelated", owner: report.path)
      }
    }
    observedApplications = targets.values.filter { $0.scope == "application" }.count
  }

  private func registerScopeExclusions(_ exclusions: [ApplicationScopeExclusion]) {
    for exclusion in exclusions {
      let scope = "simulatorOutOfScope"
      let id = scope + "::" + exclusion.path
      register(
        path: exclusion.path, scope: scope, owner: nil, logical: nil, allocated: nil,
        extra: [
          "bundleID": exclusion.bundleID as Any? ?? NSNull(),
          "reason": exclusion.reason, "nextStep": exclusion.nextStep,
          "includedInApplicationDenominator": false,
          "byteObservation": "not supplied by discovery; unknown",
        ])
      targets[id]?.outcome = "outOfScope"
      line([
        "type": "result", "id": id, "scope": scope, "path": exclusion.path,
        "bundleID": exclusion.bundleID as Any? ?? NSNull(), "outcome": "outOfScope",
        "reason": exclusion.reason, "nextStep": exclusion.nextStep,
        "includedInApplicationDenominator": false, "planBuilt": false, "planExecution": false,
        "fullValidationPerformed": false, "rejections": [], "bytes": bytes(nil, nil),
      ])
    }
  }

  private func applicationPlanDetails(
    report: ApplicationReport, items: [PlanItem], rejections: [PlanRejection],
    evidence: [RelatedOwnershipRefusalEvidence], validationPerformed: Bool
  ) async -> [String: Any] {
    let selected = items.first { $0.sourcePath == report.path }
    var refusals: [[String: Any]] = []
    for rejection in rejections { refusals.append(await refusal(rejection, evidence: evidence)) }
    let row: [String: Any] = [
      "type": selected == nil ? "applicationPlanTarget" : "applicationPlanItem",
      "ownerApplicationPath": report.path, "itemID": selected?.id.uuidString as Any? ?? NSNull(),
      "sourcePath": report.path,
      "role": selected?.inventory.first?.identity?.kind == .symbolicLink ? "selectedLinkLeaf" : "selectedRoot",
      "pathSource": selected == nil ? "listedObservation" : "freshSelectedRoot",
      "includedInApplicationDenominator": false, "planBuilt": selected != nil,
      "outcome": Self.resultOutcome(planned: selected != nil, refusals: refusals), "rejections": refusals,
      "fullValidationPerformed": false, "rootValidationPerformed": validationPerformed,
      "validationScope": "selected-root-and-base-only", "planExecution": false,
      "userSelectionWarnings": selected?.userSelectionWarnings?.map { $0.examplePath } as Any? ?? [],
      "bytes": selected.map { bytes($0.displaySize.logical, $0.displaySize.allocated) } as Any? ?? bytes(nil, nil),
      "unexplainedMissingPlan": selected == nil && rejections.isEmpty,
    ]
    line(row)
    return [
      "selectedRootPath": report.path, "selectedRootItemID": selected?.id.uuidString as Any? ?? NSNull(),
      "observedLinkTarget": report.linkTarget as Any? ?? NSNull(),
      "linkTargetSelected": false, "selectedRootResults": [row],
    ]
  }

  private func registerRelated(
    _ candidate: RelatedDataCandidate, scope: String, owner: String?,
    extra: [String: Any] = [:]
  ) {
    let values = Self.observation(candidate)
    var details = extra
    details.merge(Self.candidateDetails(candidate)) { _, value in value }
    details["ownershipRefusalEvidence"] = candidate.refusalEvidence.map { Self.ownershipEvidence($0, fresh: false) }
    register(path: candidate.path, scope: scope, owner: owner, logical: values.0, allocated: values.1, extra: details)
  }

  private static func userSelection(_ candidate: RelatedDataCandidate) -> UserSelection {
    let observed = observation(candidate)
    return UserSelection(
      path: candidate.path,
      expectedIdentity: candidate.snapshot?.entries.first { $0.path == candidate.path }?.identity
        ?? (try? KnownPathFileSystem.identity(at: candidate.path)),
      observedSize: ObservedPlanSize(logical: observed.0, allocated: observed.1))
  }

  private static func candidateDetails(_ candidate: RelatedDataCandidate) -> [String: Any] {
    let kinds = candidate.evidenceKinds.isEmpty ? candidate.provenance.map { [$0.kind] } ?? [] : candidate.evidenceKinds
    return [
      "classification": candidate.classification.rawValue,
      "candidateReason": candidate.reason.rawValue,
      "candidateName": URL(fileURLWithPath: candidate.path).lastPathComponent,
      "canSelectObservation": candidate.canSelect,
      "explicitManualChoiceAvailableObservation": candidate.explicitManualChoiceAvailable,
      "defaultSelectedObservation": candidate.defaultSelected,
      "defaultSelected": candidate.defaultSelected,
      "automaticSelectionAllowed": candidate.automaticSelectionAllowed,
      "evidenceKinds": kinds.map(\.rawValue),
      "matchStrength": candidate.matchStrength.rawValue,
      "bundleID": candidate.bundleID as Any? ?? NSNull(),
      "provenanceKind": candidate.provenance?.kind.rawValue as Any? ?? NSNull(),
      "provenanceSourcePath": candidate.provenance?.sourcePath as Any? ?? NSNull(),
      "provenanceDetail": candidate.provenance?.detail as Any? ?? NSNull(),
      "ownershipClaim": candidate.classification == .installed,
    ]
  }

  private static func covers(root: String, path: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
  }

  @concurrent private static func observeLiveDataCensus() async -> ApplicationLiveDataCensusReport {
    ApplicationLiveDataCensus.observe()
  }

  private static func censusDetails(_ report: ApplicationLiveDataCensusReport) -> [String: Any] {
    [
      "complete": report.complete, "recordCount": report.recordCount,
      "processesInspected": report.processesInspected, "applicationProcesses": report.applicationProcesses,
      "descriptorsInspected": report.descriptorsInspected, "failureFlags": report.failureFlags,
      "incompleteReasons": report.incompleteReasons, "timedOut": report.timedOut,
      "elapsedMilliseconds": report.elapsedMilliseconds,
    ]
  }

  private func reportRegistration() {
    guard !registrationReported, let report = registrationReport else { return }
    registrationReported = true
    var row = Self.registrationDetails(report)
    row["type"] = "registeredUniverseObservation"
    row["inventoryApplicationCount"] = knownUniverseApplicationCount as Any? ?? NSNull()
    row["dataSource"] = "application discovery inventory; native verification follows discovery leads"
    line(row)
  }

  private static func registrationDetails(_ report: ApplicationRegistrationReport) -> [String: Any] {
    [
      "source": report.source, "leadCount": report.leadCount, "complete": report.complete,
      "gatheringCompleted": report.gatheringCompleted, "bootIndexingStatus": report.bootIndexingStatus,
      "externalVolumesUnchecked": report.externalVolumesUnchecked,
    ]
  }

  private func unsafeAutomaticSelection(path: String, extra: [String: Any]) -> Bool {
    let automatic = extra["automaticSelectionAllowed"] as? Bool == true
    let selected = extra["defaultSelected"] as? Bool == true
    let kinds = extra["evidenceKinds"] as? [String] ?? []
    let transient = [
      RelatedDataProvenanceKind.liveProcess.rawValue, RelatedDataProvenanceKind.vendorDirectory.rawValue,
    ]
    let soleTransient = !kinds.isEmpty && kinds.allSatisfy { transient.contains($0) }
    let allowedAreas = [
      "Application Support", "Caches", "Containers", "Group Containers", "Preferences", "Logs",
      "Saved Application State", "WebKit", "HTTPStorages", "Cookies",
    ].map { home + "/Library/" + $0 }
    let comparablePath =
      path.hasPrefix("/System/Volumes/Data/") && !home.hasPrefix("/System/Volumes/Data/")
      ? String(path.dropFirst("/System/Volumes/Data".count)) : path
    let liveOutsideLibrary =
      kinds.contains(RelatedDataProvenanceKind.liveProcess.rawValue)
      && !allowedAreas.contains { Self.covers(root: $0, path: comparablePath) }
    return (selected && !automatic) || ((automatic || selected) && (soleTransient || liveOutsideLibrary))
  }

  private static func observation(_ candidate: RelatedDataCandidate) -> (ByteAggregate?, ByteAggregate?) {
    if let observed = candidate.observation { return (observed.logical, observed.allocated) }
    let rootID = candidate.snapshot?.entries.first?.id
    let node = candidate.snapshot?.nodes.first { $0.id == rootID }
    return (node?.logical, node?.allocated)
  }

  @concurrent private static func validateUserSelection(_ plan: ActionPlan?, home: String) async -> [PlanRejection] {
    guard let plan else { return [] }
    var refusals: [PlanRejection] = []
    for item in plan.items {
      do { try ActionGuard(homeDirectory: home).validate(item, plan: plan) } catch let rejection as PlanRejection {
        refusals.append(rejection)
      } catch let rejections as PlanRejections {
        refusals += rejections.rejections
      } catch {
        refusals.append(.init(.unavailable, path: item.sourcePath, ruleID: String(describing: error)))
      }
    }
    return refusals
  }

  private func register(
    path: String, scope: String, owner: String?, logical: ByteAggregate?,
    allocated: ByteAggregate?, extra: [String: Any]
  ) {
    let id = scope + ":" + (owner ?? "") + ":" + path
    let previous = targets[id]
    if unsafeAutomaticSelection(path: path, extra: extra) {
      unsafeAutomaticSelections[id] = [
        "id": id, "path": path, "scope": scope, "ownerApplicationPath": owner as Any? ?? NSNull(),
        "evidenceKinds": extra["evidenceKinds"] as Any? ?? NSNull(),
        "automaticSelectionAllowed": extra["automaticSelectionAllowed"] as Any? ?? NSNull(),
        "defaultSelected": extra["defaultSelected"] as Any? ?? NSNull(),
      ]
    }
    targets[id] = Target(
      id: id, path: path, scope: scope, owner: owner,
      logical: logical, allocated: allocated,
      candidateClassification: extra["classification"] as? String,
      candidateReason: extra["candidateReason"] as? String,
      provenanceKind: extra["provenanceKind"] as? String,
      evidenceKinds: extra["evidenceKinds"] as? [String] ?? [],
      automaticSelectionAllowed: extra["automaticSelectionAllowed"] as? Bool,
      defaultSelected: extra["defaultSelected"] as? Bool,
      outcome: previous?.outcome ?? "pending")
    var row = extra
    row["type"] = previous == nil ? "observation" : "observationUpdate"
    row["id"] = id
    row["scope"] = scope
    row["path"] = path
    row["ownerApplicationPath"] = owner as Any? ?? NSNull()
    row["bytes"] = bytes(logical, allocated)
    line(row)
  }

  private func result(
    path: String, scope: String, owner: String?, rejections: [PlanRejection],
    planned: Bool, planning: Double?, validation: Double?,
    evidence: [RelatedOwnershipRefusalEvidence] = [], extra: [String: Any] = [:], forceError: Bool = false,
    unprovenNameOnly: Bool = false
  ) async {
    let id = scope + ":" + (owner ?? "") + ":" + path
    var refusalRows: [[String: Any]] = []
    for rejection in rejections { refusalRows.append(await refusal(rejection, evidence: evidence)) }
    let relevantEvidence = evidence.filter { $0.candidatePath == path }
    // Any concrete veto or unexpected plan stays in the normal refusal accounting.
    let nameOnlyObservation =
      unprovenNameOnly && !planned && rejections.isEmpty
      && relevantEvidence.isEmpty && !forceError
    let outcome =
      forceError
      ? "errorRefusal"
      : nameOnlyObservation ? "unprovenNameOnly" : Self.resultOutcome(planned: planned, refusals: refusalRows)
    for veto in relevantEvidence where veto.reason == .unknownMetadata {
      let unavailableRegistration =
        extra["candidateReason"] as? String == RelatedReason.registrationUnavailable.rawValue
        && registrationReport?.complete == false && veto.detail == RelatedReason.registrationUnavailable.rawValue
      line([
        "type": "ownershipVeto", "candidatePath": veto.candidatePath,
        "bundleID": veto.bundleID as Any? ?? NSNull(), "unknownOwnerPaths": veto.ownerPaths,
        "reason": veto.reason.rawValue, "detail": veto.detail as Any? ?? NSNull(),
        "nextStep": veto.nextStep, "freshPlanEvidence": true,
        "classification": unavailableRegistration ? "legitimate" : "ERROR",
        "legitimateCategory": unavailableRegistration ? "registrationUniverseUnavailable" as Any : NSNull(),
      ])
    }
    targets[id]?.outcome = outcome
    var row = extra
    row.merge([
      "type": "result", "id": id, "scope": scope, "path": path,
      "ownerApplicationPath": owner as Any? ?? NSNull(), "outcome": outcome,
      "planBuilt": planned, "planBuilderSeconds": planning as Any? ?? NSNull(),
      "extraValidationSeconds": validation as Any? ?? NSNull(), "rejections": refusalRows,
      "fullValidationPerformed": false, "rootValidationPerformed": validation != nil,
      "validationScope": "selected-root-and-base-only", "explicitDryUserSelection": true,
      "timingScope": scope == "installedRelated" ? "shared owner application plan" : "requested item plan",
      "bytes": bytes(targets[id]?.logical, targets[id]?.allocated),
      "unexplainedMissingPlan": !planned && rejections.isEmpty && !nameOnlyObservation,
      "userChoiceRequired": nameOnlyObservation,
      "surveySelectedUnprovenItems": planned && extra["classification"] as? String == "unprovenNameOnly",
      "ownershipClaim": nameOnlyObservation ? false : extra["ownershipClaim"] as Any? ?? NSNull(),
      "ownershipRefusalEvidence": relevantEvidence.map { Self.ownershipEvidence($0, fresh: true) },
      "hasUnattributedRejection": forceError,
    ]) { _, value in value }
    line(row)
  }

  private static func resultOutcome(planned: Bool, refusals: [[String: Any]]) -> String {
    if refusals.isEmpty && planned { return "actionable" }
    if !refusals.isEmpty && refusals.allSatisfy({ $0["classification"] as? String == "legitimate" }) {
      return "legitimateRefusal"
    }
    return "errorRefusal"
  }

  private static func ownershipEvidence(_ evidence: RelatedOwnershipRefusalEvidence, fresh: Bool) -> [String: Any] {
    [
      "candidatePath": evidence.candidatePath, "bundleID": evidence.bundleID as Any? ?? NSNull(),
      "reason": evidence.reason.rawValue, "ownerPaths": evidence.ownerPaths,
      "nextStep": evidence.nextStep, "detail": evidence.detail as Any? ?? NSNull(),
      "freshPlanEvidence": fresh,
    ]
  }

  private func refusal(
    _ rejection: PlanRejection, evidence: [RelatedOwnershipRefusalEvidence] = []
  ) async -> [String: Any] {
    let named = rejection.ruleID ?? ""
    let code = named.hasPrefix("errno:") ? Int32(named.dropFirst(6)) : nil
    var info = stat()
    let statResult = lstat(rejection.path, &info)
    let observedErrno = statResult == 0 ? nil : errno
    let owner = statResult == 0 ? UInt32(info.st_uid) : nil
    let locale = Locale(identifier: "en_US_POSIX")
    let neverRule = NeverRule.all.first {
      $0.id == named
        && PathPattern($0.pattern.lowercased(with: locale), homeDirectory: home.lowercased(with: locale))
          .matches(rejection.path.lowercased(with: locale))
    }
    var names: [String] = []
    var processEvidenceSource: String?
    var nativeExecutableState: String?
    var currentUserDescriptorState: String?
    if rejection.reason == .processActive {
      // A native executable observation includes helpers and other users' processes.
      // A bundle ID lookup cannot corroborate those process names.
      let executable = await NativeApplicationActivitySource().activity(applicationPath: rejection.path)
      nativeExecutableState = String(describing: executable.state)
      if executable.state == .active, !named.isEmpty,
        executable.processNames.joined(separator: ", ") == named
      {
        names = executable.processNames
        processEvidenceSource = "nativeExecutablePath"
      } else {
        let descriptors = await NativeSpaceActivitySource().activity(rootPath: rejection.path)
        currentUserDescriptorState = String(describing: descriptors.state)
        if descriptors.state == .active, !named.isEmpty,
          descriptors.processNames.joined(separator: ", ") == named
        {
          names = descriptors.processNames
          processEvidenceSource = "nativeCurrentUserDescriptors"
        }
      }
    } else if rejection.reason == .applicationRunning {
      names = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier?.caseInsensitiveCompare(named) == .orderedSame
      }.compactMap(\.localizedName)
      if !names.isEmpty { processEvidenceSource = "workspaceBundleIdentifier" }
    }
    let legit: Bool
    let matchingEvidence = evidence.filter { $0.candidatePath == rejection.path }
    let sharedOwners = matchingEvidence.first {
      $0.reason == .sharedInstalledOwners && Set($0.ownerPaths).count >= 2
    }
    let registrationUnavailable =
      named == RelatedReason.registrationUnavailable.rawValue && registrationReport?.complete == false
      && targets.values.contains {
        $0.path == rejection.path && $0.candidateReason == RelatedReason.registrationUnavailable.rawValue
      }
    switch rejection.reason {
    case .protectedItem, .containsProtectedItem: legit = neverRule != nil
    case .bulkRoot:
      let roots = ["/", "/System", "/Library", "/Users", "/Applications", home, home + "/Library"]
      let selected = try? KnownPathFileSystem.identity(at: rejection.path)
      legit = roots.contains { root in
        guard let selected, selected.kind == .directory,
          let base = try? KnownPathFileSystem.identity(at: root)
        else { return false }
        return selected.device == base.device && selected.inode == base.inode
      }
    case .lightenItself: legit = true
    case .processActive, .applicationRunning: legit = !names.isEmpty
    case .needsAdministrator: legit = owner.map { $0 != geteuid() } ?? false
    case .unreadableFolder, .userPermissionDenied:
      legit = code.map { $0 > 0 } ?? false
    case .unavailable:
      legit =
        registrationUnavailable
        || (named == "ambiguousOwner" && sharedOwners != nil
          && !matchingEvidence.contains { $0.reason == .unknownMetadata || $0.reason == .infoAbsenceChanged })
    default: legit = false
    }
    return [
      "path": rejection.path, "reason": rejection.reason.rawValue,
      "detail": rejection.ruleID as Any? ?? NSNull(),
      "ruleID": rejection.reason == .lightenItself
        ? LightenIdentity.bundleIdentifier as Any : neverRule?.id as Any? ?? NSNull(),
      "processNames": names, "errno": code as Any? ?? NSNull(),
      "processEvidenceSource": processEvidenceSource as Any? ?? NSNull(),
      "nativeExecutableState": nativeExecutableState as Any? ?? NSNull(),
      "currentUserDescriptorState": currentUserDescriptorState as Any? ?? NSNull(),
      "observedStatErrno": observedErrno as Any? ?? NSNull(), "ownerUID": owner as Any? ?? NSNull(),
      "classification": legit ? "legitimate" : "ERROR",
      "ownershipRefusalEvidence": matchingEvidence.map { Self.ownershipEvidence($0, fresh: true) },
      "legitimateCategory": legit && rejection.reason == .unavailable && sharedOwners != nil
        ? "sharedInstalledOwners" as Any
        : registrationUnavailable ? "registrationUniverseUnavailable" as Any : NSNull(),
      "appleSystemPath": rejection.path.hasPrefix("/System/"),
    ]
  }

  @discardableResult private func finish(timedOut: Bool) -> Int32 {
    guard !finished else { return 2 }
    finished = true
    let observed = Array(targets.values)
    let requested = observed.filter { $0.scope != "simulatorOutOfScope" }
    let exclusions = observed.filter { $0.scope == "simulatorOutOfScope" }
    let pending = requested.filter { $0.outcome == "pending" }.count
    let folderCoverage = scope == "apps" || (foldersFinished && foldersComplete)
    let applicationCoverage =
      scope == "space"
      || (discoveryComplete && discoveryStarted == nil && listingComplete && ownershipComplete)
    let coverage = folderCoverage && applicationCoverage
    let censusComplete = scope == "space" || liveDataCensus?.complete == true
    let completed = !timedOut && pending == 0 && coverage && censusComplete
    let errorRefusals = requested.filter { $0.outcome == "errorRefusal" }
    let accepted =
      completed && errorRefusals.isEmpty && unattributedErrorCount == 0 && unsafeAutomaticSelections.isEmpty
    var acceptanceFailures: [String] = []
    if timedOut { acceptanceFailures.append("survey-timed-out") }
    if pending > 0 { acceptanceFailures.append("requested-items-unfinished") }
    if !folderCoverage { acceptanceFailures.append("folder-coverage-incomplete") }
    if !applicationCoverage { acceptanceFailures.append("application-coverage-incomplete") }
    if !censusComplete { acceptanceFailures.append("native-live-data-census-incomplete-or-unmeasured") }
    if !errorRefusals.isEmpty { acceptanceFailures.append("observed-error-refusals") }
    if unattributedErrorCount > 0 { acceptanceFailures.append("unattributed-plan-errors") }
    if !unsafeAutomaticSelections.isEmpty { acceptanceFailures.append("unsafe-automatic-selection") }
    for target in requested.filter({ $0.outcome == "pending" }).sorted(by: { $0.id < $1.id }) {
      line([
        "type": "unfinished", "id": target.id, "path": target.path, "scope": target.scope,
        "ownerApplicationPath": target.owner as Any? ?? NSNull(), "outcome": "pending",
        "planBuilderSeconds": NSNull(), "extraValidationSeconds": NSNull(),
        "bytes": bytes(target.logical, target.allocated), "timedOut": timedOut,
        "automaticSelectionAllowed": target.automaticSelectionAllowed as Any? ?? NSNull(),
        "defaultSelected": target.defaultSelected as Any? ?? NSNull(), "evidenceKinds": target.evidenceKinds,
      ])
    }
    let after = BenchEnvironment.now()
    let paths = Array(Set(targets.values.map(\.path))).sorted()
    var ancestors: [String] = []
    var overlaps: [[String: String]] = []
    for path in paths {
      ancestors.removeAll { !path.hasPrefix($0 + "/") }
      for ancestor in ancestors { overlaps.append(["ancestor": ancestor, "descendant": path]) }
      ancestors.append(path)
    }
    var scopes: [String: [String: Any]] = [:]
    for name in [
      "space", "application", "installedRelated", "orphanRelated", "unmatchedRelated", "simulatorOutOfScope",
    ] {
      let rows = observed.filter { $0.scope == name }
      let included = name == "space" ? scope != "apps" : scope != "space"
      let covered = name == "space" ? folderCoverage : applicationCoverage
      var values = scopeSummary(
        rows, coverageComplete: included && !timedOut && covered && rows.allSatisfy { $0.outcome != "pending" })
      values["includedInSurvey"] = included
      values["includedInApplicationDenominator"] = name == "application"
      values["includedInRequestedDenominator"] = name != "simulatorOutOfScope"
      scopes[name] = values
    }
    let nameOnly = requested.filter { $0.outcome == "unprovenNameOnly" }
    let nameOnlyCandidates = requested.filter { $0.candidateClassification == "unprovenNameOnly" }
    let namedNameOnlyCandidates = nameOnlyCandidates.sorted { $0.id < $1.id }.map { target -> [String: Any] in
      [
        "id": target.id, "name": URL(fileURLWithPath: target.path).lastPathComponent,
        "path": target.path, "scope": target.scope,
        "ownerApplicationPath": target.owner as Any? ?? NSNull(), "outcome": target.outcome,
        "candidateReason": target.candidateReason as Any? ?? NSNull(),
        "provenanceKind": target.provenanceKind as Any? ?? NSNull(),
        "automaticSelectionAllowed": target.automaticSelectionAllowed as Any? ?? NSNull(),
        "defaultSelected": target.defaultSelected as Any? ?? NSNull(), "evidenceKinds": target.evidenceKinds,
        "bytes": bytes(target.logical, target.allocated),
        "includedInRequestedDenominator": true, "ownershipClaim": false,
      ]
    }
    line([
      "type": "summary", "schema": 1, "completed": completed,
      "accepted": accepted, "exitCode": accepted ? 0 : 2,
      "acceptanceFailures": acceptanceFailures,
      "errorRefusalCount": errorRefusals.count,
      "liveDataCensusMeasured": liveDataCensus != nil,
      "liveDataCensusIncludedInAcceptance": scope != "space",
      "liveDataCensus": liveDataCensus.map(Self.censusDetails) as Any? ?? NSNull(),
      "registeredUniverseMeasured": registrationReport != nil,
      "registeredUniverse": registrationReport.map(Self.registrationDetails) as Any? ?? NSNull(),
      "knownUniverseInventoryApplicationCount": knownUniverseApplicationCount as Any? ?? NSNull(),
      "unsafeAutomaticSelectionCount": unsafeAutomaticSelections.count,
      "unsafeAutomaticSelections": unsafeAutomaticSelections.keys.sorted().compactMap { unsafeAutomaticSelections[$0] },
      "automaticSelectionAccounting":
        "candidate request rows; retains any unsafe observation, including updates; checks sole live/vendor evidence, live evidence outside standard user Library areas, and default selection without automatic permission",
      "metadataIssueCount": metadataIssueCount,
      "timedOut": timedOut, "truncated": !completed, "coverageComplete": coverage, "stage": stage,
      "elapsedSeconds": elapsed(started),
      "folderScanSeconds": folderScanStarted.map(elapsed) ?? folderScanSeconds,
      "applicationDiscoverySeconds": discoveryStarted.map(elapsed) ?? discoverySeconds,
      "planningSeconds": planSeconds + (activePlanStarted.map(elapsed) ?? 0),
      "planningCompletedIntervalsSeconds": planSeconds,
      "planningInFlightSeconds": activePlanStarted.map(elapsed) as Any? ?? NSNull(),
      "extraValidationSeconds": validationSeconds + (activeValidationStarted.map(elapsed) ?? 0),
      "extraValidationCompletedIntervalsSeconds": validationSeconds,
      "extraValidationInFlightSeconds": activeValidationStarted.map(elapsed) as Any? ?? NSNull(),
      "observedApplications": observedApplications,
      "completedApplicationPlans": completedApplications, "planTimingSampleCount": appPlanTimes.count,
      "applicationPlanP50Seconds": appPlanTimes.isEmpty ? NSNull() : percentile(appPlanTimes, 0.50) as Any,
      "applicationPlanP95Seconds": appPlanTimes.isEmpty ? NSNull() : percentile(appPlanTimes, 0.95) as Any,
      "percentileMethod": "nearest-rank; completed plan-builder intervals only",
      "planTimingCoversAllObservedApplications": discoveryComplete && appPlanTimes.count == observedApplications,
      "applicationTimingOperation":
        "makeAvailableUserSelectionPlan; displayed app root plus explicitly selected observed related roots",
      "listingComplete": listingComplete, "ownershipComplete": ownershipComplete,
      "applicationDiscoveryComplete": discoveryComplete && discoveryStarted == nil,
      "folderScanComplete": foldersFinished && foldersComplete, "completedFolderRoots": completedFolderRoots,
      "folderPoolCount": folderPoolCount, "folderLimit": folderLimit,
      "folderRanking": "global known logical lower bound; partial observations included",
      "requestedCount": requested.count, "allObservedRowCount": targets.count,
      "simulatorOutOfScopeObservedCount": exclusions.count,
      "simulatorOutOfScopeCompletedCount": exclusions.filter { $0.outcome == "outOfScope" }.count,
      "simulatorOutOfScope": scopeSummary(exclusions, coverageComplete: applicationCoverage && !timedOut),
      "applicationDenominator": "Mac application request rows; simulator device apps reported separately",
      "unattributedPlanRejectionCount": unattributedRejectionCount,
      "unattributedPlanErrorCount": unattributedErrorCount,
      "uniqueObservedPathCount": paths.count, "uniqueFolderPoolPathCount": folderPoolPaths.count,
      "requested": scopeSummary(requested, coverageComplete: completed), "scopes": scopes,
      "unprovenNameOnlyCount": nameOnly.count,
      "unprovenNameOnly": scopeSummary(nameOnly, coverageComplete: applicationCoverage && !timedOut),
      "unprovenNameOnlyObservedCandidateCount": nameOnlyCandidates.count,
      "unprovenNameOnlyCandidates": namedNameOnlyCandidates,
      "unprovenNameOnlyAccounting":
        "raw candidate request rows remain in the requested denominator; named list includes pending or refused candidates; bytes can be unknown or overlap",
      "canonicalUnionLogicalBytes": NSNull(), "canonicalUnionMeasured": false, "overlaps": overlaps,
      "byteAccounting": "requested sums overlap; they are not uniquely reclaimable bytes",
      "overlapDetection": "exact lexical paths; link-target and hardlink union not measured",
      "orphanObservedCount": targets.values.filter { $0.scope == "orphanRelated" }.count,
      "unmatchedRelatedObservedCount": targets.values.filter { $0.scope == "unmatchedRelated" }.count,
      "uniqueObservedRelatedPathCount": Set(requested.filter { $0.scope.hasSuffix("Related") }.map(\.path)).count,
      "environmentStart": environment.json, "environmentEnd": after.json,
      "performanceMeasured": environment.quiet && after.quiet,
      "timings": "raw wall observations; no performance acceptance claim when load is busy",
    ])
    return accepted ? 0 : 2
  }

  private func scopeSummary(_ rows: [Target], coverageComplete: Bool) -> [String: Any] {
    let exact = exactSum(rows.map(\.logical))
    let outcomes = Dictionary(grouping: rows, by: \.outcome).mapValues { values -> [String: Any] in
      let outcomeExact = exactSum(values.map(\.logical))
      let percent: Any =
        if coverageComplete, let exact, exact > 0, let outcomeExact {
          100 * Double(outcomeExact) / Double(exact)
        } else { NSNull() }
      return [
        "count": values.count,
        "requestedLogicalSumKnownLowerBound": sum(values.compactMap { $0.logical?.knownLowerBound }),
        "requestedLogicalSumExact": outcomeExact as Any? ?? NSNull(),
        "requestedAllocatedSumKnownLowerBound": sum(values.compactMap { $0.allocated?.knownLowerBound }),
        "requestedAllocatedSumExact": exactSum(values.map(\.allocated)) as Any? ?? NSNull(),
        "logicalBytePercentOfCompleteExactDenominator": percent,
        "unknownLogicalByteCount": values.filter { $0.logical == nil }.count,
        "lowerBoundLogicalByteCount": values.filter { $0.logical != nil && $0.logical?.completeTotal == nil }.count,
        "unknownAllocatedByteCount": values.filter { $0.allocated == nil }.count,
        "lowerBoundAllocatedByteCount": values.filter { $0.allocated != nil && $0.allocated?.completeTotal == nil }
          .count,
      ]
    }
    return [
      "count": rows.count, "finishedCount": rows.filter { $0.outcome != "pending" }.count,
      "automaticSelectionAllowedCount": rows.filter { $0.automaticSelectionAllowed == true }.count,
      "defaultSelectedCount": rows.filter { $0.defaultSelected == true }.count,
      "pendingCount": rows.filter { $0.outcome == "pending" }.count,
      "requestedLogicalSumKnownLowerBound": sum(rows.compactMap { $0.logical?.knownLowerBound }),
      "requestedLogicalSumExact": exact as Any? ?? NSNull(),
      "requestedAllocatedSumKnownLowerBound": sum(rows.compactMap { $0.allocated?.knownLowerBound }),
      "requestedAllocatedSumExact": exactSum(rows.map(\.allocated)) as Any? ?? NSNull(),
      "unknownLogicalByteCount": rows.filter { $0.logical == nil }.count,
      "lowerBoundLogicalByteCount": rows.filter { $0.logical != nil && $0.logical?.completeTotal == nil }.count,
      "unknownAllocatedByteCount": rows.filter { $0.allocated == nil }.count,
      "lowerBoundAllocatedByteCount": rows.filter { $0.allocated != nil && $0.allocated?.completeTotal == nil }.count,
      "coverageComplete": coverageComplete, "outcomes": outcomes,
      "byteAccounting": "requested sums; overlapping paths are counted per request",
    ]
  }

  private func exactSum(_ values: [ByteAggregate?]) -> Int64? {
    var total: Int64 = 0
    for value in values {
      guard let exact = value?.completeTotal else { return nil }
      let (next, overflow) = total.addingReportingOverflow(exact)
      guard !overflow else { return nil }
      total = next
    }
    return total
  }

  private func bytes(_ logical: ByteAggregate?, _ allocated: ByteAggregate?) -> [String: Any] {
    [
      "knownLogicalLowerBound": logical?.knownLowerBound as Any? ?? NSNull(),
      "exactLogicalBytes": logical?.completeTotal as Any? ?? NSNull(),
      "knownAllocatedLowerBound": allocated?.knownLowerBound as Any? ?? NSNull(),
      "exactAllocatedBytes": allocated?.completeTotal as Any? ?? NSNull(),
      "logicalState": logical == nil ? "unknown" : logical?.completeTotal == nil ? "lowerBound" : "exact",
      "allocatedState": allocated == nil ? "unknown" : allocated?.completeTotal == nil ? "lowerBound" : "exact",
    ]
  }

  private func sum(_ values: [Int64]) -> Int64 {
    values.reduce(0) { total, value in
      let (sum, overflow) = total.addingReportingOverflow(max(0, value))
      return overflow ? Int64.max : sum
    }
  }

  private func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let parts = start.duration(to: .now).components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }

  private func progress(path: String, extra: [String: Any] = [:]) {
    var row = extra
    row["type"] = "progress"
    row["stage"] = stage
    row["path"] = path
    row["elapsedSeconds"] = elapsed(started)
    line(row, stderr: true)
  }

  private func line(_ row: [String: Any], stderr: Bool = false) {
    do {
      var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
      data.append(10)
      (stderr ? FileHandle.standardError : FileHandle.standardOutput).write(data)
    } catch {
      FileHandle.standardError.write(Data("survey: JSON output failed: \(error)\n".utf8))
      exit(1)
    }
  }
}
