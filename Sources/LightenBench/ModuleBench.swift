import Darwin
import Foundation
import LightenKit

extension Bench {
  static func duplicates(root: String, timeout: Double, dryPlan: Bool = false) async -> [String: Any] {
    let before = ProcessSample.now()
    let consumer = Task { () throws -> DuplicateReport in
      for try await event in DuplicateService().events(rootPath: root) {
        if case .completed(let report) = event { return report }
      }
      throw DuplicateFailure.unavailable
    }
    let timer = cancellationTimer(timeout: timeout) { consumer.cancel() }
    defer { timer.cancel() }
    do {
      let report = try await consumer.value
      let scanFinished = ProcessSample.now()
      var result = common(engine: "duplicates", root: root, before: before, after: scanFinished)
      result["completed"] = true
      result["partial"] = report.partial
      result["groups"] = report.groups.count
      result["members"] = report.groups.reduce(0) { $0 + $1.members.count }
      result["skippedCount"] = report.skippedCount
      result["comparisonCount"] = report.comparisonCount
      var bytes: Int64 = 0
      var compatibleBytes: Int64 = 0
      var unknownMembers = 0
      var reportOnlyGroups = 0
      for group in report.groups {
        bytes += group.logicalBytes * Int64(max(0, group.members.count - 1))
        let compatible = Dictionary(grouping: group.members.compactMap(\.compatibilityID), by: { $0 })
        if !compatible.values.contains(where: { $0.count >= 2 }) { reportOnlyGroups += 1 }
        compatibleBytes += compatible.values.reduce(0) { $0 + group.logicalBytes * Int64(max(0, $1.count - 1)) }
        unknownMembers += group.members.filter { $0.eligibility == .metadataUnknown }.count
      }
      result["duplicateLogicalBytes"] = bytes
      result["metadataCompatibleLogicalBytes"] = compatibleBytes
      result["metadataUnknownMembers"] = unknownMembers
      result["reportOnlyGroupCount"] = reportOnlyGroups
      result["actionableCompatibleLogicalBytes"] = compatibleBytes
      result["groupRows"] = report.groups.map { group in
        [
          "logicalBytes": group.logicalBytes,
          "members": group.members.map { member -> [String: Any] in
            [
              "path": member.entry.path, "eligibility": member.eligibility.rawValue,
              "compatibilityID": member.compatibilityID?.uuidString as Any? ?? NSNull(),
              "warnings": member.metadataWarnings.map(\.rawValue),
            ]
          },
        ] as [String: Any]
      }
      result["actionPlanBuilt"] = false
      guard dryPlan else { return result }
      let planningStarted = ProcessSample.now()
      let service = DuplicateService()
      var dryPlanReportOnlyGroups = 0
      var plannedLogicalBytes: Int64 = 0
      var plannedTargets = 0
      var planFailures: [[String: Any]] = []
      var dryPlanGroups: [[String: Any]] = []
      for group in report.groups {
        let eligible = group.members.filter { $0.eligibility == .eligible && $0.compatibilityID != nil }
        let subsets = Dictionary(grouping: eligible, by: \.compatibilityID).values
          .filter { $0.count > 1 }
          .sorted { ($0.map { $0.entry.path }.min() ?? "") < ($1.map { $0.entry.path }.min() ?? "") }
        var groupTargets = 0
        var refusalReasons: [String] = []
        if subsets.isEmpty {
          refusalReasons = Array(Set(group.members.map { $0.eligibility.rawValue })).sorted()
        }
        for subset in subsets {
          let ordered = subset.sorted { $0.entry.path < $1.entry.path }
          let keeper = ordered[0]
          let targets = Array(ordered.dropFirst())
          do {
            let plan = try await service.makePlan(
              report: report, groupID: group.id, keeperID: keeper.id, targetIDs: Set(targets.map(\.id)))
            let identities = plan.items.compactMap { $0.inventory.first?.identity }
            guard identities.count == plan.items.count else { throw DuplicateFailure.unavailable }
            groupTargets += plan.items.count
            plannedTargets += plan.items.count
            plannedLogicalBytes += identities.reduce(Int64(0)) { $0 + $1.logicalBytes }
          } catch is CancellationError { throw CancellationError() } catch {
            let reason = String(describing: error)
            refusalReasons.append(reason)
            planFailures.append([
              "keeperPath": keeper.entry.path, "targetPaths": targets.map { $0.entry.path },
              "reason": reason,
            ])
          }
        }
        if groupTargets == 0 { dryPlanReportOnlyGroups += 1 }
        dryPlanGroups.append([
          "memberPaths": group.members.map { $0.entry.path },
          "attemptedSubsetCount": subsets.count, "plannedTargetCount": groupTargets,
          "reportOnly": groupTargets == 0, "refusalReasons": Array(Set(refusalReasons)).sorted(),
        ])
      }
      result["dryPlanReportOnlyGroupCount"] = dryPlanReportOnlyGroups
      result["dryPlanReportOnlyGroupRatio"] =
        report.groups.isEmpty ? 0.0 : Double(dryPlanReportOnlyGroups) / Double(report.groups.count)
      result["plannedLogicalBytes"] = plannedLogicalBytes
      result["plannedTargetCount"] = plannedTargets
      result["dryPlanFailures"] = planFailures
      result["dryPlanGroups"] = dryPlanGroups
      result["dryPlanSeconds"] = seconds(from: planningStarted.wall, to: ProcessSample.now().wall)
      result["dryPlanCompleted"] = true
      result["actionPlanBuilt"] = plannedTargets > 0
      return result
    } catch {
      var result = common(engine: "duplicates", root: root, before: before, after: ProcessSample.now())
      result["completed"] = false
      result["error"] = String(describing: error)
      return result
    }
  }

  /// Cache creation is setup; the measured opening starts at the actual load.
  static func cachedSpace(root: String, layout: Bool, timeout: Double, workers: Int) async -> [String: Any] {
    let before = ProcessSample.now()
    var result: [String: Any] = ["root": root, "completed": false]
    var fixture: OwnedFixture?
    do {
      let owned = try OwnedFixture()
      fixture = owned
      result["fixtureDirectory"] = owned.directory
      let configuration = ScanConfiguration(workers: workers > 0 ? workers : ScanConfiguration.defaultWorkers)
      let run = try ScanEngine(configuration: configuration).start(root: root)
      let timer = cancellationTimer(timeout: timeout) { run.cancel() }
      await run.waitUntilFinished()
      timer.cancel()
      guard !run.tree.wasCancelled else { throw CancellationError() }
      let seeded = ProcessSample.now()
      result["seedScanSeconds"] = seconds(from: before.wall, to: seeded.wall)
      let cache = ScanCache(directory: owned.directory + "/scan-cache")
      try cache.save(run.tree)
      let saved = ProcessSample.now()
      result["cacheSaveSeconds"] = seconds(from: seeded.wall, to: saved.wall)
      guard let loaded = cache.load(root: run.tree.rootPath) else {
        throw FileSystemFailureDescription("cache did not decode the completed tree")
      }
      let opened = ProcessSample.now()
      result["cacheLoadSeconds"] = seconds(from: saved.wall, to: opened.wall)
      result["nodes"] = loaded.tree.nodeCount
      let rootItem = loaded.tree.item(loaded.tree.rootID)
      result["logicalKnownBytes"] = rootItem?.logical.knownLowerBound ?? 0
      result["allocatedKnownBytes"] = rootItem?.allocated.knownLowerBound ?? 0
      result["logicalExactBytes"] = rootItem?.logical.completeTotal as Any? ?? NSNull()
      result["allocatedExactBytes"] = rootItem?.allocated.completeTotal as Any? ?? NSNull()
      result["partial"] = rootItem?.partial ?? true
      if layout {
        let group = loaded.tree.group(at: loaded.tree.rootID, metric: .logical)
        let values = group.items.map { ($0.id, $0.logical.knownLowerBound) }
        let treemap = Treemap.layout(values: values, width: 1200, height: 800)
        let ready = ProcessSample.now()
        result["layoutSeconds"] = seconds(from: opened.wall, to: ready.wall)
        result["spaceOpenSeconds"] = seconds(from: saved.wall, to: ready.wall)
        result["visibleItems"] = group.items.count
        result["tiles"] = treemap.tiles.count
        result["layoutAvailable"] = true
      }
      let files = try FileManager.default.contentsOfDirectory(atPath: cache.directory)
      result["cacheBytes"] = try files.reduce(Int64(0)) { sum, name in
        sum + (try DescriptorFileSystem.identity(at: cache.directory + "/" + name)).logicalBytes
      }
      result["completed"] = true
    } catch {
      result["error"] = String(describing: error)
    }
    if let fixture {
      do {
        try fixture.remove()
        result["fixtureRemoved"] = true
      } catch {
        result["fixtureRemoved"] = false
        result["cleanupError"] = String(describing: error)
        result["completed"] = false
      }
    }
    result["totalSeconds"] = seconds(from: before.wall, to: ProcessSample.now().wall)
    return result
  }

  static func cancellationTimer(
    timeout: Double, cancel: @escaping @Sendable () -> Void
  ) -> Task<Void, Never> {
    let duration = timeout.isFinite ? max(0.01, timeout) : 600
    return Task {
      do { try await Task.sleep(for: .seconds(duration)) } catch { return }
      cancel()
    }
  }
}
