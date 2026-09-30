import Darwin
import Foundation
import LightenKit

extension Bench {
  static func duplicates(root: String, timeout: Double) async -> [String: Any] {
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
      var result = common(engine: "duplicates", root: root, before: before, after: ProcessSample.now())
      result["completed"] = true
      result["partial"] = report.partial
      result["groups"] = report.groups.count
      result["members"] = report.groups.reduce(0) { $0 + $1.members.count }
      result["skippedCount"] = report.skippedCount
      result["comparisonCount"] = report.comparisonCount
      var bytes: Int64 = 0
      var compatibleBytes: Int64 = 0
      var unknownMembers = 0
      for group in report.groups {
        bytes += group.logicalBytes * Int64(max(0, group.members.count - 1))
        let compatible = Dictionary(grouping: group.members.compactMap(\.compatibilityID), by: { $0 })
        compatibleBytes += compatible.values.reduce(0) { $0 + group.logicalBytes * Int64(max(0, $1.count - 1)) }
        unknownMembers += group.members.filter { $0.eligibility == .metadataUnknown }.count
      }
      result["duplicateLogicalBytes"] = bytes
      result["metadataCompatibleLogicalBytes"] = compatibleBytes
      result["metadataUnknownMembers"] = unknownMembers
      result["actionPlanBuilt"] = false
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
