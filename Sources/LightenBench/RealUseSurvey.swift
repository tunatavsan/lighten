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
    var applications: [InstalledApplication] = []
    for await event in await session.events() {
      switch event {
      case .inventory(let inventory, let current), .completed(let inventory, let current):
        reports = current
        applications = inventory.applications
        listingComplete = inventory.complete
        ownershipComplete = inventory.ownershipComplete
        observedApplications = Set(current.map(\.path)).count
        if case .completed = event { discoveryComplete = true }
        registerReports(current)
      case .ownershipReady(let inventory):
        applications = inventory.applications
        listingComplete = inventory.complete
        ownershipComplete = inventory.ownershipComplete
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
      guard let app = applications.first(where: { $0.path == report.path }) else {
        await result(
          path: report.path, scope: "application", owner: report.path,
          rejections: [.init(.missingMetadata, path: report.path, ruleID: "unidentified-application")],
          planned: false, planning: nil, validation: nil)
        for candidate in report.related {
          await result(
            path: candidate.path, scope: "installedRelated", owner: report.path,
            rejections: [.init(.missingMetadata, path: report.path, ruleID: "unidentified-application")],
            planned: false, planning: nil, validation: nil)
        }
        continue
      }
      let start = ContinuousClock.now
      activePlanStarted = start
      let outcome = await session.makeAvailableUninstallPlan(
        app: app, selectedRelated: report.related, includePackage: true)
      let planning = elapsed(start)
      planSeconds += planning
      appPlanTimes.append(planning)
      activePlanStarted = nil
      stage = "application-validation"
      let checkedAt = ContinuousClock.now
      activeValidationStarted = outcome.plan == nil ? nil : checkedAt
      let validation: [PlanRejection] = if let plan = outcome.plan { await session.validatePlan(plan) } else { [] }
      let checking = outcome.plan == nil ? nil : elapsed(checkedAt)
      validationSeconds += checking ?? 0
      activeValidationStarted = nil
      let rejections = outcome.rejections + validation
      let roots = [report.path] + report.related.map(\.path)
      let unassigned = rejections.filter { rejection in
        !roots.contains { Self.covers(root: $0, path: rejection.path) }
      }
      let packageRefusals = rejections.filter { Self.covers(root: report.path, path: $0.path) } + unassigned
      await result(
        path: report.path, scope: "application", owner: report.path, rejections: packageRefusals,
        planned: outcome.plan?.items.contains { $0.sourcePath == report.path } == true,
        planning: planning, validation: checking)
      for candidate in report.related {
        let refusals = rejections.filter { Self.covers(root: candidate.path, path: $0.path) }
        await result(
          path: candidate.path, scope: "installedRelated", owner: report.path,
          rejections: packageRefusals.isEmpty ? refusals : packageRefusals + refusals,
          planned: outcome.plan?.items.contains { $0.sourcePath == candidate.path } == true,
          planning: planning, validation: checking)
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
      let outcome = await session.plan(candidate: candidate)
      let planning = elapsed(start)
      planSeconds += planning
      activePlanStarted = nil
      stage = "related-validation"
      let checkedAt = ContinuousClock.now
      activeValidationStarted = outcome.plan == nil ? nil : checkedAt
      let validation: [PlanRejection] = if let plan = outcome.plan { await session.validatePlan(plan) } else { [] }
      let checking = outcome.plan == nil ? nil : elapsed(checkedAt)
      validationSeconds += checking ?? 0
      activeValidationStarted = nil
      await result(
        path: candidate.path, scope: kind, owner: nil,
        rejections: outcome.rejections + validation,
        planned: outcome.plan?.items.contains { $0.sourcePath == candidate.path } == true,
        planning: planning, validation: checking)
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

  private func registerRelated(
    _ candidate: RelatedDataCandidate, scope: String, owner: String?,
    extra: [String: Any] = [:]
  ) {
    let values = Self.observation(candidate)
    var details = extra
    details["classification"] = candidate.classification.rawValue
    details["candidateReason"] = candidate.reason.rawValue
    details["canSelectObservation"] = candidate.canSelect
    details["matchStrength"] = candidate.matchStrength.rawValue
    details["bundleID"] = candidate.bundleID as Any? ?? NSNull()
    register(path: candidate.path, scope: scope, owner: owner, logical: values.0, allocated: values.1, extra: details)
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
      logical: logical, allocated: allocated, outcome: previous?.outcome ?? "pending")
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
    planned: Bool, planning: Double?, validation: Double?
  ) async {
    let id = scope + ":" + (owner ?? "") + ":" + path
    var refusalRows: [[String: Any]] = []
    for rejection in rejections { refusalRows.append(await refusal(rejection)) }
    let outcome: String
    if rejections.isEmpty && planned {
      outcome = "actionable"
    } else if !refusalRows.isEmpty && refusalRows.allSatisfy({ $0["classification"] as? String == "legitimate" }) {
      outcome = "legitimateRefusal"
    } else {
      outcome = "errorRefusal"
    }
    targets[id]?.outcome = outcome
    line([
      "type": "result", "id": id, "scope": scope, "path": path,
      "ownerApplicationPath": owner as Any? ?? NSNull(), "outcome": outcome,
      "planBuilt": planned, "planBuilderSeconds": planning as Any? ?? NSNull(),
      "extraValidationSeconds": validation as Any? ?? NSNull(), "rejections": refusalRows,
      "fullValidationPerformed": validation != nil,
      "timingScope": scope == "installedRelated" ? "shared owner application plan" : "requested item plan",
      "bytes": bytes(targets[id]?.logical, targets[id]?.allocated),
      "unexplainedMissingPlan": !planned && rejections.isEmpty,
    ])
  }

  private func refusal(_ rejection: PlanRejection) async -> [String: Any] {
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
    switch rejection.reason {
    case .protectedItem, .containsProtectedItem: legit = neverRule != nil
    case .lightenItself: legit = true
    case .processActive, .applicationRunning: legit = !names.isEmpty
    case .needsAdministrator: legit = owner.map { $0 != geteuid() } ?? false
    case .unreadableFolder, .userPermissionDenied:
      legit = code.map { $0 > 0 } ?? false
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
      "appleSystemPath": rejection.path.hasPrefix("/System/"),
    ]
  }

  private func finish(timedOut: Bool) {
    guard !finished else { return }
    finished = true
    let requested = Array(targets.values)
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
    for name in ["space", "application", "installedRelated", "orphanRelated", "unmatchedRelated"] {
      let rows = requested.filter { $0.scope == name }
      let included = name == "space" ? scope != "apps" : scope != "space"
      let covered = name == "space" ? folderCoverage : applicationCoverage
      var values = scopeSummary(
        rows, coverageComplete: included && !timedOut && covered && rows.allSatisfy { $0.outcome != "pending" })
      values["includedInSurvey"] = included
      scopes[name] = values
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
      "uniqueObservedPathCount": paths.count, "uniqueFolderPoolPathCount": folderPoolPaths.count,
      "requested": scopeSummary(requested, coverageComplete: completed), "scopes": scopes,
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
