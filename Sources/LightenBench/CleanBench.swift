import AppKit
import CLightenPlatform
import Darwin
import Foundation
import LightenKit

private struct BenchProcessActivity: ProcessActivitySource {
  func activity(for rowID: String) async -> ProcessActivity { ProcessActivity(state: .unknown) }

  func activity(for row: CatalogRow, rootPath: String) async -> ProcessActivity {
    let native = await Task.detached(priority: .utility) {
      var name = [CChar](repeating: 0, count: 256)
      let state = rootPath.withCString { root in
        name.withUnsafeMutableBufferPointer { lighten_process_activity(root, $0.baseAddress, $0.count) }
      }
      return (state, String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }.value
    if native.0 == 1 {
      return ProcessActivity(state: .active, processNames: native.1.isEmpty ? [] : [native.1])
    }
    guard native.0 == 0 else { return ProcessActivity(state: .unknown) }
    if row.relativeRoot == "Library/Caches" {
      let bundleID = (rootPath as NSString).lastPathComponent
      let names = await runningNames(bundleIDs: [bundleID])
      if !names.isEmpty { return ProcessActivity(state: .active, processNames: names) }
    }
    return ProcessActivity(state: .clearObservedCurrentUID)
  }
}

private func runningNames(bundleIDs: [String]) async -> [String] {
  await MainActor.run {
    NSWorkspace.shared.runningApplications.compactMap { app -> String? in
      guard let id = app.bundleIdentifier,
        bundleIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame })
      else { return nil }
      return app.localizedName ?? id
    }.sorted()
  }
}

private struct ObservedBytes {
  var logical: Int64 = 0
  var allocated: Int64 = 0
  var complete = false
  var source = "unavailable"
  var measurementError: String?

  init() {}

  init(entries: [ScanEntry], complete: Bool, source: String) {
    var hardLinks = Set<[UInt64]>()
    for entry in entries {
      guard let identity = entry.identity, identity.kind != .directory else { continue }
      if identity.linkCount > 1, !hardLinks.insert([identity.device, identity.inode]).inserted { continue }
      logical += max(0, identity.logicalBytes)
      allocated += max(0, identity.allocatedBytes)
    }
    self.complete = complete
    self.source = source
  }

  init(node: ScanNode) {
    logical = node.logical.knownLowerBound
    allocated = node.allocated.knownLowerBound
    complete = !node.partial && node.logical.completeTotal != nil && node.allocated.completeTotal != nil
    source = "scanEngineDiscovery"
  }

  var json: [String: Any] {
    var result: [String: Any] = [
      "logicalKnownBytes": logical, "allocatedKnownBytes": allocated,
      "bytesComplete": complete, "unknownBytes": !complete, "byteSource": source,
    ]
    if let measurementError { result["byteMeasurementError"] = measurementError }
    return result
  }
}

extension Bench {
  /// The dry observation builds fresh plans and validates them, without an executor or journal.
  static func clean(home: String, rowID: String?, timeout: Double) async -> [String: Any] {
    let before = ProcessSample.now()
    let catalog: CleanCatalog
    do { catalog = try CleanCatalog(homeDirectory: home) } catch {
      return ["home": home, "completed": false, "error": String(describing: error)]
    }
    if let rowID, catalog.row(id: rowID) == nil {
      return ["home": home, "completed": false, "error": "unknown catalog row: " + rowID]
    }
    var categories: [[String: Any]] = []
    var rejected: [[String: Any]] = []
    var acceptedPaths: [String] = []
    var actionableLogical: Int64 = 0
    var actionableAllocated: Int64 = 0
    var rejectedLogical: Int64 = 0
    var rejectedAllocated: Int64 = 0
    var unknownByteItems = 0
    var unavailableRoots = 0
    var discoverySeconds = 0.0
    var proofSeconds = 0.0
    let scanner = ScanService(homeDirectory: home)
    let guardService = ActionGuard(homeDirectory: home)
    let activity = BenchProcessActivity()
    for row in catalog.rows where rowID == nil || row.id == rowID {
      let root = catalog.root(for: row)
      let rowStart = ProcessSample.now()
      var category: [String: Any] = [
        "id": row.id, "title": row.titleEN, "root": root,
        "actionableCount": 0, "rejectedCount": 0, "excludedDedicatedCount": 0, "unknownByteItems": 0,
        "actionableLogicalBytes": 0, "actionableAllocatedBytes": 0,
        "rejectedLogicalKnownBytes": 0, "rejectedAllocatedKnownBytes": 0,
      ]
      var rowAccepted = 0
      var rowRejected = 0
      var rowExcluded = 0
      var rowUnknown = 0
      var rowLogical: Int64 = 0
      var rowAllocated: Int64 = 0
      var rowRejectedLogical: Int64 = 0
      var rowRejectedAllocated: Int64 = 0
      let discovery: CatalogDiscovery
      let discoveryStart = ProcessSample.now()
      do {
        let consumer = Task { try await catalog.discover(rowID: row.id) }
        let timer = cancellationTimer(timeout: timeout) { consumer.cancel() }
        do { discovery = try await consumer.value } catch {
          timer.cancel()
          throw error
        }
        timer.cancel()
      } catch ScanStartFailure.unavailable(let code) where code == ENOENT {
        let elapsed = seconds(from: discoveryStart.wall, to: ProcessSample.now().wall)
        discoverySeconds += elapsed
        category["tDiscoverySeconds"] = elapsed
        category["tProofSeconds"] = 0.0
        category["status"] = "absent"
        category["candidateCount"] = 0
        categories.append(category)
        continue
      } catch {
        let elapsed = seconds(from: discoveryStart.wall, to: ProcessSample.now().wall)
        discoverySeconds += elapsed
        category["tDiscoverySeconds"] = elapsed
        category["tProofSeconds"] = 0.0
        category["status"] = "unavailable"
        category["candidateCount"] = NSNull()
        category["error"] = String(describing: error)
        category["unknownBytes"] = true
        unavailableRoots += 1
        categories.append(category)
        continue
      }
      let elapsedDiscovery = seconds(from: discoveryStart.wall, to: ProcessSample.now().wall)
      discoverySeconds += elapsedDiscovery
      category["tDiscoverySeconds"] = elapsedDiscovery
      let proofStart = ProcessSample.now()
      for candidate in discovery.candidates {
        let path = candidate.entry.path
        // Dedicated catalog subtrees are reported by their own row once.
        if candidate.rejection?.ruleID == "catalog-overlap" {
          rowExcluded += 1
          continue
        }
        var bytes = ObservedBytes(node: candidate.node)
        var stage = "catalog"
        do {
          if let rejection = candidate.rejection { throw rejection }
          stage = "selectedProof"
          let name = (path as NSString).lastPathComponent
          let consumer = Task { try await scanner.scanImmediateChild(parentPath: root, name: name) }
          let timer = cancellationTimer(timeout: timeout) { consumer.cancel() }
          let snapshot: ScanSnapshot
          do { snapshot = try await consumer.value } catch {
            timer.cancel()
            throw error
          }
          timer.cancel()
          guard let entry = snapshot.entries.first(where: { $0.path == path }),
            let node = snapshot.nodes.first(where: { $0.id == entry.id })
          else { throw FileSystemFailureDescription("candidate disappeared during observation") }
          let freshBytes = ObservedBytes(
            entries: snapshot.entries.filter { $0.path == path || $0.path.hasPrefix(path + "/") },
            complete: !node.partial, source: "scanSnapshot")
          if freshBytes.complete {
            bytes = freshBytes
          } else {
            // A partial proof read cannot erase the discovery's known bytes.
            bytes.logical = max(bytes.logical, freshBytes.logical)
            bytes.allocated = max(bytes.allocated, freshBytes.allocated)
            bytes.complete = false
            bytes.source = "scanEngineDiscovery+partialSelectedSnapshot"
          }
          stage = "plan"
          let plan = try await Task.detached(priority: .utility) {
            try catalog.plan(
              selections: [CatalogSelection(snapshot: snapshot, selectedIDs: [entry.id], rowID: row.id)], kind: .trash)
          }.value
          bytes = ObservedBytes(entries: plan.items.flatMap(\.inventory), complete: true, source: "exactPlanInventory")
          stage = "guard"
          for item in plan.items { try guardService.validate(item) }
          stage = "processActivity"
          let observation = await activity.activity(
            for: row, rootPath: catalog.activityRoot(for: row, candidatePath: path))
          switch observation.state {
          case .clearObservedCurrentUID: break
          case .active: throw ProcessActivityFailure.active(processNames: observation.processNames)
          case .unknown: throw ProcessActivityFailure.unavailable
          }
          stage = "nestedApplication"
          let bundleIDs = plan.items.flatMap { $0.nestedApplicationIDs ?? [] }
          if bundleIDs.contains(where: { $0.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame })
          {
            throw FileSystemFailureDescription("contains Lighten itself")
          }
          let names = await runningNames(bundleIDs: bundleIDs)
          if !names.isEmpty { throw ProcessActivityFailure.active(processNames: names) }
          rowAccepted += 1
          rowLogical += bytes.logical
          rowAllocated += bytes.allocated
          acceptedPaths.append(path)
        } catch {
          var refusal = bytes.json
          refusal["path"] = path
          refusal["rowID"] = row.id
          refusal["stage"] = stage
          refusal["reasons"] = rejectionDetails(error, path: path)
          rejected.append(refusal)
          rowRejected += 1
          rowRejectedLogical += bytes.logical
          rowRejectedAllocated += bytes.allocated
          if !bytes.complete { rowUnknown += 1 }
        }
      }
      let elapsedProof = seconds(from: proofStart.wall, to: ProcessSample.now().wall)
      proofSeconds += elapsedProof
      category["tProofSeconds"] = elapsedProof
      actionableLogical += rowLogical
      actionableAllocated += rowAllocated
      rejectedLogical += rowRejectedLogical
      rejectedAllocated += rowRejectedAllocated
      unknownByteItems += rowUnknown
      category["status"] = "observed"
      category["candidateCount"] = rowAccepted + rowRejected
      category["actionableCount"] = rowAccepted
      category["rejectedCount"] = rowRejected
      category["excludedDedicatedCount"] = rowExcluded
      category["unknownByteItems"] = rowUnknown
      category["actionableLogicalBytes"] = rowLogical
      category["actionableAllocatedBytes"] = rowAllocated
      category["rejectedLogicalKnownBytes"] = rowRejectedLogical
      category["rejectedAllocatedKnownBytes"] = rowRejectedAllocated
      category["observationSeconds"] = seconds(from: rowStart.wall, to: ProcessSample.now().wall)
      categories.append(category)
    }
    var result = common(engine: "clean", root: home, before: before, after: ProcessSample.now())
    result["completed"] = unavailableRoots == 0
    result["dryRun"] = true
    result["tDiscoverySeconds"] = discoverySeconds
    result["tProofSeconds"] = proofSeconds
    result["discoveryEngine"] = "ScanEngine"
    result["discoveryIncludesAgeMetadata"] = true
    result["executedItems"] = 0
    result["actionableLogicalBytes"] = actionableLogical
    result["actionableAllocatedBytes"] = actionableAllocated
    result["actionableCount"] = acceptedPaths.count
    result["actionablePaths"] = acceptedPaths
    result["rejectedLogicalKnownBytes"] = rejectedLogical
    result["rejectedAllocatedKnownBytes"] = rejectedAllocated
    result["rejectedCount"] = rejected.count
    result["rejected"] = rejected
    result["unknownByteItems"] = unknownByteItems
    result["unavailableRoots"] = unavailableRoots
    result["unknownBytes"] = unknownByteItems > 0 || unavailableRoots > 0
    result["categories"] = categories
    result["byteAccounting"] = "non-directory metadata; hard links counted once per candidate"
    return result
  }

  private static func rejectionDetails(_ error: Error, path: String) -> [[String: Any]] {
    func detail(_ rejection: PlanRejection) -> [String: Any] {
      var result: [String: Any] = ["reason": rejection.reason.rawValue, "path": rejection.path]
      if let rule = rejection.ruleID { result["ruleID"] = rule }
      return result
    }
    if let rejection = error as? PlanRejection { return [detail(rejection)] }
    if let rejections = error as? PlanRejections { return rejections.rejections.map(detail) }
    return [["reason": String(describing: error), "path": path]]
  }

}
