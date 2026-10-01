import Darwin
import Foundation
import LightenKit
import Synchronization

enum Bench {
  static func scan(
    engine: String, root: String, timeout: Double, workers: Int, sinkMinimumBytes: Int64? = nil
  ) async -> [String: Any] {
    switch engine {
    case "old":
      guard sinkMinimumBytes == nil else { return ["error": "file sink requires the new engine"] }
      return await scanOld(root: root, timeout: timeout)
    case "new": return await scanNew(root: root, timeout: timeout, workers: workers, sinkMinimumBytes: sinkMinimumBytes)
    default: return ["error": "unknown engine \(engine)"]
    }
  }

  // MARK: Legacy ScanService

  static func scanOld(root: String, timeout: Double) async -> [String: Any] {
    let seen = Atomic<Int>(0)
    let before = ProcessSample.now()
    let consumer = Task { () -> ScanSnapshot? in
      do {
        for try await event in ScanService().events(rootPath: root) {
          switch event {
          case .progress(let count, _): seen.store(count, ordering: .relaxed)
          case .completed(let snapshot): return snapshot
          }
        }
      } catch {}
      return nil
    }
    let timer = cancellationTimer(timeout: timeout) { consumer.cancel() }
    let snapshot = await consumer.value
    timer.cancel()
    let after = ProcessSample.now()
    var result = common(engine: "old", root: root, before: before, after: after)
    guard let snapshot else {
      result["completed"] = false
      result["timedOutAfterSeconds"] = timeout
      result["entriesSeen"] = seen.load(ordering: .relaxed)
      return result
    }
    let rootNode = snapshot.nodes.first { $0.parentID == nil }
    result["completed"] = true
    // The legacy engine publishes nothing until its tree is complete.
    result["tFirstSeconds"] = result["tCompleteSeconds"]
    result["entries"] = snapshot.entries.count
    result["directories"] = snapshot.entries.filter { $0.identity?.kind == .directory }.count
    result["logicalKnown"] = rootNode?.logical.knownLowerBound ?? -1
    result["allocatedKnown"] = rootNode?.allocated.knownLowerBound ?? -1
    result["partial"] = rootNode?.partial ?? true
    result["skippedEntries"] = snapshot.entries.filter { !$0.issues.isEmpty }.count
    return result
  }

  static func scanNew(
    root: String, timeout: Double, workers: Int, sinkMinimumBytes: Int64? = nil
  ) async -> [String: Any] {
    let facts = Mutex(
      (count: 0, modTimeCount: 0, addedTimeCount: 0, earliestModTime: Date?.none, latestModTime: Date?.none))
    var configuration = ScanConfiguration(workers: workers > 0 ? workers : ScanConfiguration.defaultWorkers)
    if let sinkMinimumBytes {
      configuration.fileSink = FileSink(minLogicalBytes: sinkMinimumBytes) { fact in
        facts.withLock {
          $0.count += 1
          if let modified = fact.modTime {
            $0.modTimeCount += 1
            $0.earliestModTime = min($0.earliestModTime ?? modified, modified)
            $0.latestModTime = max($0.latestModTime ?? modified, modified)
          }
          if fact.addedTime != nil { $0.addedTimeCount += 1 }
        }
      }
    }
    let before = ProcessSample.now()
    let run: ScanRun
    do { run = try ScanEngine(configuration: configuration).start(root: root) } catch {
      return ["engine": "new", "root": root, "error": "\(error)"]
    }
    let timer = cancellationTimer(timeout: timeout) { run.cancel() }
    var firstScreen: UInt64?
    var publications = 0
    for await update in run.progress {
      publications += 1
      if firstScreen == nil, (run.tree.item(run.tree.rootID)?.childCount ?? 0) > 0 {
        firstScreen = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      }
      if update.finished { break }
    }
    await run.waitUntilFinished()
    timer.cancel()
    let after = ProcessSample.now()
    var result = common(engine: "new", root: root, before: before, after: after)
    let rootItem = run.tree.item(run.tree.rootID)
    result["workers"] = configuration.workers
    result["sinkEnabled"] = sinkMinimumBytes != nil
    if let sinkMinimumBytes {
      let observed = facts.withLock { $0 }
      result["sinkMinLogicalBytes"] = sinkMinimumBytes
      result["emittedFactCount"] = observed.count
      result["factsWithModTime"] = observed.modTimeCount
      result["factsWithAddedTime"] = observed.addedTimeCount
      result["earliestModTimeEpoch"] = observed.earliestModTime.map { $0.timeIntervalSince1970 } as Any? ?? NSNull()
      result["latestModTimeEpoch"] = observed.latestModTime.map { $0.timeIntervalSince1970 } as Any? ?? NSNull()
    }
    result["completed"] = !run.tree.wasCancelled
    result["tFirstSeconds"] = firstScreen.map { seconds(from: before.wall, to: $0) } ?? -1
    result["publications"] = publications
    result["nodes"] = run.tree.nodeCount
    result["itemsBelowRoot"] = rootItem?.itemCount ?? -1
    result["logicalKnown"] = rootItem?.logical.knownLowerBound ?? -1
    result["logicalExact"] = rootItem?.logical.completeTotal ?? -1
    result["allocatedKnown"] = rootItem?.allocated.knownLowerBound ?? -1
    result["partial"] = rootItem?.partial ?? true
    result["state"] = "\(rootItem?.state as Any)"
    for (key, value) in run.counters.snapshot { result["counter." + key] = value }
    if run.tree.wasCancelled { result["timedOutAfterSeconds"] = timeout }
    return result
  }

  static func common(engine: String, root: String, before: ProcessSample, after: ProcessSample) -> [String: Any] {
    [
      "engine": engine, "root": root,
      "tCompleteSeconds": seconds(from: before.wall, to: after.wall),
      "cpuUserSeconds": Double(after.userMicros - before.userMicros) / 1_000_000,
      "cpuSystemSeconds": Double(after.systemMicros - before.systemMicros) / 1_000_000,
      "unixSyscalls": after.unixSyscalls - before.unixSyscalls,
      "machSyscalls": after.machSyscalls - before.machSyscalls,
      "peakRSSBytes": ProcessSample.peakResidentBytes,
      "peakFootprintBytes": ProcessSample.peakFootprintBytes,
    ]
  }

  // MARK: Apps screen path

  /// Runs the Apps screen's discovery end to end, then times one package alone.
  static func apps(focus: String) async -> [String: Any] {
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    var inventoryAt: UInt64?
    var reports: [ApplicationReport] = []
    var complete = false
    for await event in ApplicationDiscovery(related: RelatedDataService(writeVerifiedReceipts: false)).events() {
      switch event {
      case .inventory: inventoryAt = inventoryAt ?? clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      case .measured, .orphans: break
      case .completed(let inventory, let final):
        reports = final
        complete = inventory.complete
      }
    }
    let finished = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let unknown = reports.filter { $0.logical.completeTotal == nil }
    let focusStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let size = await ApplicationDiscovery.measure(path: focus, homeDirectory: NSHomeDirectory())
    let focusEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    return [
      "engine": "apps", "apps": reports.count, "inventoryComplete": complete,
      "listVisibleSeconds": inventoryAt.map { seconds(from: start, to: $0) } ?? -1,
      "allMeasuredSeconds": seconds(from: start, to: finished),
      "unknownCount": unknown.count, "unknownPaths": unknown.map(\.path),
      "focus": focus, "focusLogical": size.logical.completeTotal ?? -1,
      "focusAllocated": size.allocated.completeTotal ?? -1, "focusItems": size.count,
      "focusSeconds": seconds(from: focusStart, to: focusEnd),
    ]
  }

  // MARK: Cancellation latency

  static func cancellation(engine: String, root: String, trials: Int, workers: Int) async -> [String: Any] {
    var latencies: [Double] = []
    var finishedBeforeCancel = 0
    for trial in 0..<trials {
      // Deterministic spread of cancel points between 100 ms and 1.5 s.
      let delay = 0.1 + Double((trial * 7) % trials) / Double(max(trials - 1, 1)) * 1.4
      let (latency, finished) = await cancelOnce(engine: engine, root: root, delay: delay, workers: workers)
      if finished { finishedBeforeCancel += 1 } else { latencies.append(latency) }
    }
    return [
      "engine": engine, "root": root, "trials": trials,
      "finishedBeforeCancel": finishedBeforeCancel,
      "latencyP50Ms": percentile(latencies, 0.5) * 1000,
      "latencyP95Ms": percentile(latencies, 0.95) * 1000,
      "latencyMaxMs": (latencies.max() ?? .nan) * 1000,
    ]
  }

  static func cancelOnce(engine: String, root: String, delay: Double, workers: Int) async -> (Double, Bool) {
    let done = Atomic<Bool>(false)
    let task: Task<Void, Never>
    switch engine {
    case "old":
      task = Task {
        _ = try? await ScanService().scan(rootPath: root)
        done.store(true, ordering: .sequentiallyConsistent)
      }
    default:
      let configuration = ScanConfiguration(workers: workers > 0 ? workers : ScanConfiguration.defaultWorkers)
      guard let run = try? ScanEngine(configuration: configuration).start(root: root) else { return (.nan, true) }
      try? await Task.sleep(for: .seconds(delay))
      if run.tree.isFinished { return (0, true) }
      let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      run.cancel()
      await run.waitUntilFinished()
      return (seconds(from: start, to: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)), false)
    }
    try? await Task.sleep(for: .seconds(delay))
    if done.load(ordering: .sequentiallyConsistent) { return (0, true) }
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    task.cancel()
    await task.value
    return (seconds(from: start, to: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)), false)
  }
}
