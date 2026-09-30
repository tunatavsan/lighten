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
      let names: [String]
      do {
        let identity = try DescriptorFileSystem.identity(at: root)
        names = try DescriptorFileSystem.children(at: root, expected: identity).sorted()
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
        category["status"] = "absent"
        category["candidateCount"] = 0
        categories.append(category)
        continue
      } catch {
        category["status"] = "unavailable"
        category["candidateCount"] = NSNull()
        category["error"] = String(describing: error)
        category["unknownBytes"] = true
        unavailableRoots += 1
        categories.append(category)
        continue
      }
      for name in names {
        let path = root + "/" + name
        // These subtrees belong to their specific row and must not count twice.
        if row.relativeRoot == "Library/Caches",
          catalog.rows.contains(where: {
            $0.id != row.id && (catalog.root(for: $0) == path || catalog.root(for: $0).hasPrefix(path + "/"))
          })
        {
          rowExcluded += 1
          continue
        }
        var bytes = ObservedBytes()
        var stage = "scan"
        do {
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
          bytes = ObservedBytes(
            entries: snapshot.entries.filter { $0.path == path || $0.path.hasPrefix(path + "/") },
            complete: !node.partial, source: "scanSnapshot")
          stage = "catalog"
          guard catalog.allowsCandidate(path: path, row: row, kind: .trash) else {
            throw FileSystemFailureDescription(catalogRefusal(catalog: catalog, row: row, path: path))
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
          if !bytes.complete {
            bytes = await measureRejected(path: path, home: home, fallback: bytes, timeout: timeout)
          }
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

  private static func catalogRefusal(catalog: CleanCatalog, row: CatalogRow, path: String) -> String {
    if !row.methods.contains(.trash) { return "catalog row is report-only" }
    if let rule = ProtectionPolicy.rule(for: path, homeDirectory: catalog.homeDirectory) {
      return "protected by " + rule.id
    }
    if row.relativeRoot == "Library/Caches", (path as NSString).lastPathComponent.lowercased().hasPrefix("com.apple.") {
      return "Apple cache is outside the generic application-cache authority"
    }
    if row.minAgeDays > 0 {
      return "minimum age of \(row.minAgeDays) days is not satisfied or modification time is unavailable"
    }
    return "candidate is outside the catalog row's immediate-child Trash authority"
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

  private static func measureRejected(
    path: String, home: String, fallback: ObservedBytes, timeout: Double
  ) async -> ObservedBytes {
    var unavailable = fallback
    let run: ScanRun
    do {
      let identity = try DescriptorFileSystem.identity(at: path)
      guard identity.kind == .directory else { return fallback }
      run = try ScanEngine(configuration: ScanConfiguration(homeDirectory: home)).start(root: path)
    } catch {
      unavailable.measurementError = String(describing: error)
      return unavailable
    }
    let timer = cancellationTimer(timeout: timeout) { run.cancel() }
    await run.waitUntilFinished()
    timer.cancel()
    guard let item = run.tree.item(run.tree.rootID) else {
      unavailable.measurementError = "scan tree root unavailable"
      return unavailable
    }
    var bytes = ObservedBytes()
    bytes.logical = item.logical.knownLowerBound
    bytes.allocated = item.allocated.knownLowerBound
    bytes.complete = !run.tree.wasCancelled && item.logical.completeTotal != nil && item.allocated.completeTotal != nil
    bytes.source = "scanTree"
    if !bytes.complete { bytes.measurementError = String(describing: item.state) }
    return bytes
  }
}
