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
    survey.finish(timedOut: false)
    return 0
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
    for (item, runID, root) in selected {
      stage = "folder-planning"
      progress(path: item.path)
      let start = ContinuousClock.now
      activePlanStarted = start
      let outcome = await PlanService(homeDirectory: home).makeAvailableSpacePlan(
        selections: [.init(path: item.path, device: item.device, inode: item.inode)],
        scanRootPath: root, runID: runID)
      let planning = elapsed(start)
      planSeconds += planning
      activePlanStarted = nil
      stage = "folder-validation"
      let checkedAt = ContinuousClock.now
      activeValidationStarted = outcome.plan == nil ? nil : checkedAt
      let validation = await Self.validateSpace(outcome.plan, home: home)
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
    for await event in await session.events() {
      switch event {
      case .inventory(let inventory, let current), .completed(let inventory, let current):
        reports = current
        listingComplete = inventory.complete
        ownershipComplete = inventory.ownershipComplete
        registerScopeExclusions(inventory.scopeExclusions)
        observedApplications = Set(current.map(\.path)).count
        if case .completed = event { discoveryComplete = true }
        registerReports(current)
      case .ownershipReady(let inventory):
        listingComplete = inventory.complete
        ownershipComplete = inventory.ownershipComplete
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
      // Name-only candidates are observations, never automatic uninstall selections.
      let automaticRelated = report.related.filter { $0.classification != .unprovenNameOnly }
      let outcome = await session.makeAvailableUninstallPlan(
        path: report.path, expectedBundleID: report.bundleID, selectedRelated: automaticRelated, includePackage: true)
      let planning = elapsed(start)
      planSeconds += planning
      appPlanTimes.append(planning)
      activePlanStarted = nil
      stage = "application-validation"
      let checkedAt = ContinuousClock.now
      activeValidationStarted = outcome.plan == nil ? nil : checkedAt
      let validation: [PlanRejection] = if let plan = outcome.plan { await session.validatePlan(plan) } else { [] }
      let validationEvidence =
        if let plan = outcome.plan, !validation.isEmpty {
          await session.ownershipRefusalEvidence(for: plan)
        } else { [RelatedOwnershipRefusalEvidence]() }
      let checking = outcome.plan == nil ? nil : elapsed(checkedAt)
      validationSeconds += checking ?? 0
      activeValidationStarted = nil
      let rejections = outcome.rejections + validation
      let evidence = outcome.refusalEvidence + validationEvidence
      let packageItems = outcome.plan?.items.filter { $0.policy == .wholeBundle || $0.policy == .applicationLink } ?? []
      let packageRoots = Array(
        Set([report.path] + [report.linkTarget].compactMap { $0 } + packageItems.map(\.sourcePath)))
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
      let physicalItems = packageItems.filter { $0.policy == .wholeBundle }
      let linkItems = packageItems.filter { $0.policy == .applicationLink }
      let requiresLink = report.linkTarget != nil || !linkItems.isEmpty
      let packagePlanned =
        physicalItems.count == 1
        && (!requiresLink
          || linkItems.contains { link in
            link.sourcePath == report.path && link.packageLinkTargetItemID == physicalItems.first?.id
          })
      let packageDetails = await applicationPlanDetails(
        report: report, items: packageItems, rejections: packageRefusals, evidence: evidence,
        validationPerformed: checking != nil)
      await result(
        path: report.path, scope: "application", owner: report.path, rejections: packageRefusals + unassigned,
        planned: packagePlanned, planning: planning, validation: checking, evidence: evidence,
        extra: packageDetails, forceError: !unassigned.isEmpty)
      for candidate in report.related {
        let refusals = rejections.filter { Self.covers(root: candidate.path, path: $0.path) }
        await result(
          path: candidate.path, scope: "installedRelated", owner: report.path,
          rejections: packageRefusals.isEmpty ? refusals : packageRefusals + refusals,
          planned: outcome.plan?.items.contains { $0.sourcePath == candidate.path } == true,
          planning: planning, validation: checking,
          evidence: evidence + candidate.refusalEvidence, extra: Self.candidateDetails(candidate),
          unprovenNameOnly: Self.isUnprovenNameOnly(candidate))
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
      let outcome: RelatedDataService.AvailableUninstallPlan
      if Self.isUnprovenNameOnly(candidate) {
        outcome = .init(plan: nil, rejections: [])
      } else {
        outcome = await session.plan(candidate: candidate)
      }
      let planning = elapsed(start)
      planSeconds += planning
      activePlanStarted = nil
      stage = "related-validation"
      let checkedAt = ContinuousClock.now
      activeValidationStarted = outcome.plan == nil ? nil : checkedAt
      let validation: [PlanRejection] = if let plan = outcome.plan { await session.validatePlan(plan) } else { [] }
      let validationEvidence =
        if let plan = outcome.plan, !validation.isEmpty {
          await session.ownershipRefusalEvidence(for: plan)
        } else { [RelatedOwnershipRefusalEvidence]() }
      let checking = outcome.plan == nil ? nil : elapsed(checkedAt)
      validationSeconds += checking ?? 0
      activeValidationStarted = nil
      await result(
        path: candidate.path, scope: kind, owner: nil,
        rejections: outcome.rejections + validation,
        planned: outcome.plan?.items.contains { $0.sourcePath == candidate.path } == true,
        planning: planning, validation: checking,
        evidence: outcome.refusalEvidence + validationEvidence + candidate.refusalEvidence,
        extra: Self.candidateDetails(candidate), unprovenNameOnly: Self.isUnprovenNameOnly(candidate))
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
    var rows: [[String: Any]] = []
    for item in items {
      let relevant = rejections.filter { Self.covers(root: item.sourcePath, path: $0.path) }
      var refusals: [[String: Any]] = []
      for rejection in relevant { refusals.append(await refusal(rejection, evidence: evidence)) }
      let dependencies =
        item.policy == .applicationLink
        ? rejections.filter { rejection in
          items.contains { $0.policy == .wholeBundle && Self.covers(root: $0.sourcePath, path: rejection.path) }
        } : []
      var dependencyRows: [[String: Any]] = []
      for rejection in dependencies { dependencyRows.append(await refusal(rejection, evidence: evidence)) }
      let outcome = Self.resultOutcome(planned: true, refusals: refusals + dependencyRows)
      let row: [String: Any] = [
        "type": "applicationPlanItem", "ownerApplicationPath": report.path,
        "itemID": item.id.uuidString, "sourcePath": item.sourcePath,
        "role": item.policy == .applicationLink ? "linkLeaf" : "physicalPackage",
        "packageLinkTargetItemID": item.packageLinkTargetItemID?.uuidString as Any? ?? NSNull(),
        "applicationBundleID": item.applicationBundleID as Any? ?? NSNull(),
        "pathSource": "freshPlan", "includedInApplicationDenominator": false,
        "planBuilt": true, "outcome": outcome, "rejections": refusals,
        "dependencyRejections": dependencyRows,
        "fullValidationPerformed": validationPerformed,
        "planExecution": false, "bytes": bytes(item.displaySize.logical, item.displaySize.allocated),
      ]
      rows.append(row)
      line(row)
    }
    let physical = items.first { $0.policy == .wholeBundle }
    let leaf = items.first { $0.policy == .applicationLink && $0.sourcePath == report.path }
    let expectedPhysical = report.linkTarget ?? report.path
    let missingTargets: [(String, String)] =
      (physical == nil ? [(expectedPhysical, "physicalPackage")] : [])
      + (report.linkTarget != nil && leaf == nil ? [(report.path, "linkLeaf")] : [])
    for (path, role) in missingTargets {
      let relevant = rejections.filter { Self.covers(root: path, path: $0.path) }
      var refusals: [[String: Any]] = []
      for rejection in relevant { refusals.append(await refusal(rejection, evidence: evidence)) }
      let dependencies =
        role == "linkLeaf" ? rejections.filter { Self.covers(root: expectedPhysical, path: $0.path) } : []
      var dependencyRows: [[String: Any]] = []
      for rejection in dependencies { dependencyRows.append(await refusal(rejection, evidence: evidence)) }
      let row: [String: Any] = [
        "type": "applicationPlanTarget", "ownerApplicationPath": report.path,
        "itemID": NSNull(), "sourcePath": path, "role": role,
        "packageLinkTargetItemID": NSNull(), "pathSource": "listedObservation",
        "includedInApplicationDenominator": false, "planBuilt": false,
        "outcome": Self.resultOutcome(planned: false, refusals: refusals + dependencyRows), "rejections": refusals,
        "dependencyRejections": dependencyRows,
        "fullValidationPerformed": false, "planExecution": false, "bytes": bytes(nil, nil),
        "unexplainedMissingPlan": relevant.isEmpty && dependencies.isEmpty,
      ]
      rows.append(row)
      line(row)
    }
    return [
      "physicalPackagePath": physical?.sourcePath as Any? ?? NSNull(),
      "physicalPackageItemID": physical?.id.uuidString as Any? ?? NSNull(),
      "listedLinkPath": report.linkTarget != nil || leaf != nil ? report.path as Any : NSNull(),
      "listedLinkItemID": leaf?.id.uuidString as Any? ?? NSNull(),
      "observedLinkTarget": report.linkTarget as Any? ?? NSNull(),
      "packageAndLinkResults": rows,
      "packageSuccessRequiresLink": report.linkTarget != nil || leaf != nil,
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

  private static func isUnprovenNameOnly(_ candidate: RelatedDataCandidate) -> Bool {
    candidate.classification == .unprovenNameOnly && candidate.reason == .nameOnly
      && candidate.refusalEvidence.isEmpty
  }

  private static func candidateDetails(_ candidate: RelatedDataCandidate) -> [String: Any] {
    [
      "classification": candidate.classification.rawValue,
      "candidateReason": candidate.reason.rawValue,
      "candidateName": URL(fileURLWithPath: candidate.path).lastPathComponent,
      "canSelectObservation": candidate.canSelect,
      "explicitManualChoiceAvailableObservation": candidate.explicitManualChoiceAvailable,
      "defaultSelectedObservation": candidate.defaultSelected,
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

  private static func observation(_ candidate: RelatedDataCandidate) -> (ByteAggregate?, ByteAggregate?) {
    if let observed = candidate.observation { return (observed.logical, observed.allocated) }
    let rootID = candidate.snapshot?.entries.first?.id
    let node = candidate.snapshot?.nodes.first { $0.id == rootID }
    return (node?.logical, node?.allocated)
  }

  @concurrent private static func validateSpace(_ plan: ActionPlan?, home: String) async -> [PlanRejection] {
    guard let plan else { return [] }
    var refusals: [PlanRejection] = []
    for item in plan.items {
      do { try ActionGuard(homeDirectory: home).validate(item) } catch let rejection as PlanRejection {
        refusals.append(rejection)
      } catch let rejections as PlanRejections {
        refusals += rejections.rejections
      } catch {
        refusals.append(.init(.unavailable, path: item.sourcePath, ruleID: String(describing: error)))
      }
      let observation = await NativeSpaceActivitySource().activity(rootPath: item.sourcePath)
      if observation.state == .active {
        refusals.append(
          .init(.processActive, path: item.sourcePath, ruleID: observation.processNames.joined(separator: ", ")))
      } else if observation.state == .unknown {
        refusals.append(
          .init(
            .activityUnavailable, path: item.sourcePath,
            ruleID: observation.processNames.isEmpty ? nil : observation.processNames.joined(separator: ", ")))
      }
      if item.containsOpaquePackages {
        let activity = await NativeApplicationActivitySource().activity(applicationPath: item.sourcePath)
        if activity.state == .active {
          refusals.append(
            .init(.processActive, path: item.sourcePath, ruleID: activity.processNames.joined(separator: ", ")))
        } else if activity.state == .unknown {
          refusals.append(
            .init(
              .activityUnavailable, path: item.sourcePath,
              ruleID: activity.processNames.isEmpty ? nil : activity.processNames.joined(separator: ", ")))
        }
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
    targets[id] = Target(
      id: id, path: path, scope: scope, owner: owner,
      logical: logical, allocated: allocated,
      candidateClassification: extra["classification"] as? String,
      candidateReason: extra["candidateReason"] as? String,
      provenanceKind: extra["provenanceKind"] as? String,
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
      line([
        "type": "ownershipVeto", "candidatePath": veto.candidatePath,
        "bundleID": veto.bundleID as Any? ?? NSNull(), "unknownOwnerPaths": veto.ownerPaths,
        "reason": veto.reason.rawValue, "detail": veto.detail as Any? ?? NSNull(),
        "nextStep": veto.nextStep, "freshPlanEvidence": true, "classification": "ERROR",
      ])
    }
    targets[id]?.outcome = outcome
    var row = extra
    row.merge([
      "type": "result", "id": id, "scope": scope, "path": path,
      "ownerApplicationPath": owner as Any? ?? NSNull(), "outcome": outcome,
      "planBuilt": planned, "planBuilderSeconds": planning as Any? ?? NSNull(),
      "extraValidationSeconds": validation as Any? ?? NSNull(), "rejections": refusalRows,
      "fullValidationPerformed": validation != nil,
      "timingScope": scope == "installedRelated" ? "shared owner application plan" : "requested item plan",
      "bytes": bytes(targets[id]?.logical, targets[id]?.allocated),
      "unexplainedMissingPlan": !planned && rejections.isEmpty && !nameOnlyObservation,
      "userChoiceRequired": nameOnlyObservation,
      "surveySelectedUnprovenItems": false,
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
    switch rejection.reason {
    case .protectedItem, .containsProtectedItem: legit = neverRule != nil
    case .lightenItself: legit = true
    case .processActive, .applicationRunning: legit = !names.isEmpty
    case .needsAdministrator: legit = owner.map { $0 != geteuid() } ?? false
    case .unreadableFolder, .userPermissionDenied:
      legit = code.map { $0 > 0 } ?? false
    case .unavailable:
      legit =
        named == "ambiguousOwner" && sharedOwners != nil
        && !matchingEvidence.contains { $0.reason == .unknownMetadata || $0.reason == .infoAbsenceChanged }
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
        ? "sharedInstalledOwners" as Any : NSNull(),
      "appleSystemPath": rejection.path.hasPrefix("/System/"),
    ]
  }

  private func finish(timedOut: Bool) {
    guard !finished else { return }
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
    let completed = !timedOut && pending == 0 && coverage
    for target in requested.filter({ $0.outcome == "pending" }).sorted(by: { $0.id < $1.id }) {
      line([
        "type": "unfinished", "id": target.id, "path": target.path, "scope": target.scope,
        "ownerApplicationPath": target.owner as Any? ?? NSNull(), "outcome": "pending",
        "planBuilderSeconds": NSNull(), "extraValidationSeconds": NSNull(),
        "bytes": bytes(target.logical, target.allocated), "timedOut": timedOut,
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
        "bytes": bytes(target.logical, target.allocated),
        "includedInRequestedDenominator": true, "ownershipClaim": false,
      ]
    }
    line([
      "type": "summary", "schema": 1, "completed": completed,
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
      "applicationTimingOperation": "makeAvailableUninstallPlan; package plus all observed related candidates",
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
