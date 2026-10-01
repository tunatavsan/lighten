import Foundation
import Synchronization

public struct DuplicateService: Sendable {
  private let scan: ScanService
  private let configuration: ScanConfiguration
  private let comparator: DuplicateFileComparator
  private let planner: PlanService

  public init(
    scan: ScanService = ScanService(), comparator: DuplicateFileComparator = DuplicateFileComparator(),
    planner: PlanService = PlanService(), configuration: ScanConfiguration? = nil
  ) {
    self.scan = scan
    self.configuration = configuration ?? ScanConfiguration(homeDirectory: scan.homeDirectory)
    self.comparator = comparator
    self.planner = planner
  }

  public func events(rootPath: String) -> AsyncThrowingStream<DuplicateEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached {
        do {
          let facts = Mutex<[FileFact]>([])
          var configuration = self.configuration
          configuration.fileSink = FileSink { fact in facts.withLock { $0.append(fact) } }
          let run = try ScanEngine(configuration: configuration).start(root: rootPath)
          var scanned = 0
          await withTaskCancellationHandler {
            for await update in run.progress {
              scanned = update.itemsSeen
              continuation.yield(.progress(scanned: scanned, compared: 0))
            }
            await run.waitUntilFinished()
          } onCancel: {
            run.cancel()
          }
          try Task.checkCancellation()
          guard !run.tree.wasCancelled else { throw CancellationError() }
          let snapshot = try observation(run: run, facts: facts.withLock { $0 })
          let unavailableMetadata = run.counters.snapshot["sinkMetadataUnavailable"] ?? 0
          let omittedFiles = run.counters.snapshot["sinkOmittedFiles"] ?? 0
          let report = try group(
            snapshot: snapshot, unavailableMetadata: unavailableMetadata, omittedFiles: omittedFiles
          ) { compared in
            continuation.yield(.progress(scanned: scanned, compared: compared))
          }
          try Task.checkCancellation()
          continuation.yield(.completed(report))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  public func makePlan(
    report: DuplicateReport, groupID: UUID, keeperID: UUID, targetIDs: Set<UUID>
  ) async throws -> ActionPlan {
    try await makePlan(
      report: report,
      selections: [
        DuplicateGroupSelection(
          groupID: groupID, keeperID: keeperID, targetIDs: targetIDs)
      ])
  }

  public func makePlan(
    report: DuplicateReport, selections: [DuplicateGroupSelection]
  ) async throws -> ActionPlan {
    let task = Task.detached {
      guard !selections.isEmpty, selections.allSatisfy({ !$0.targetIDs.isEmpty }),
        Set(selections.map(\.groupID)).count == selections.count
      else { throw DuplicateFailure.invalidSelection }
      var fragments: [ActionPlan] = []
      for selection in selections {
        try Task.checkCancellation()
        fragments.append(
          try await makePlanSelection(
            report: report, groupID: selection.groupID, keeperID: selection.keeperID,
            targetIDs: selection.targetIDs))
      }
      let items = fragments.flatMap(\.items)
      guard Set(items.map(\.sourcePath)).count == items.count else {
        throw DuplicateFailure.invalidSelection
      }
      return ActionPlan(snapshotRunID: report.snapshot.runID, kind: .trash, items: items)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func makePlanSelection(
    report: DuplicateReport, groupID: UUID, keeperID: UUID, targetIDs: Set<UUID>
  ) async throws -> ActionPlan {
    guard let group = report.groups.first(where: { $0.id == groupID }),
      let keeper = group.members.first(where: { $0.id == keeperID && $0.eligibility == .eligible }),
      !targetIDs.isEmpty, !targetIDs.contains(keeperID),
      targetIDs.allSatisfy({ group.canTarget($0, keeperID: keeperID) }),
      let volumeID = report.snapshot.volumeID,
      let keeperIdentity = keeper.entry.identity
    else { throw DuplicateFailure.invalidSelection }
    let (_, freshKeeper) = try await freshFile(
      keeper.entry, volumeID: volumeID, runID: report.snapshot.runID)
    let keeperDigest = try comparator.digest(freshKeeper, volumeID: volumeID)
    let keeperAncestors = try DescriptorFileSystem.ancestorIdentities(of: freshKeeper.path)
    var items: [PlanItem] = []
    for member in group.members.filter({ targetIDs.contains($0.id) }).sorted(by: { $0.entry.path < $1.entry.path }) {
      try Task.checkCancellation()
      let (snapshot, _) = try await freshFile(member.entry, volumeID: volumeID, runID: report.snapshot.runID)
      let generic = try planner.makePlan(snapshot: snapshot, selectedIDs: [member.id])
      guard let item = generic.items.first, generic.items.count == 1,
        let target = item.inventory.first,
        let targetIdentity = target.identity,
        targetIdentity.kind == .regular,
        targetIdentity.device != keeperIdentity.device || targetIdentity.inode != keeperIdentity.inode
      else { throw DuplicateFailure.invalidSelection }
      let digest = try comparator.digest(target, volumeID: volumeID)
      guard digest == keeperDigest else { throw DuplicateFailure.changed }
      let comparison = try comparator.compare(
        freshKeeper, target, volumeID: volumeID,
        expectedFirstDigest: keeperDigest, expectedSecondDigest: digest)
      guard comparison == .equal else { throw DuplicateFailure.invalidSelection }
      let proof = DuplicateProof(
        groupID: groupID, keeper: freshKeeper, keeperAncestors: keeperAncestors,
        keeperVolumeID: volumeID, targetDigest: digest, keeperDigest: keeperDigest)
      items.append(
        PlanItem(
          id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
          inventory: item.inventory, ancestors: item.ancestors, duplicateProof: proof))
    }
    return ActionPlan(snapshotRunID: report.snapshot.runID, kind: .trash, items: items)
  }

  /// Only selected files receive a fresh descriptor-relative inventory. Every
  /// identity field must still match the discovery observation.
  private func freshFile(
    _ reported: ScanEntry, volumeID: UUID, runID: UUID
  ) async throws -> (ScanSnapshot, ScanEntry) {
    let path = reported.path as NSString
    let fresh = try await scan.scanImmediateChild(
      parentPath: path.deletingLastPathComponent, name: path.lastPathComponent)
    guard fresh.volumeID == volumeID,
      let entry = fresh.entries.first(where: { $0.path == reported.path }),
      entry.identity == reported.identity, entry.identity?.kind == .regular,
      entry.issues.isEmpty, entry.readable,
      let node = fresh.nodes.first(where: { $0.id == entry.id }), !node.partial
    else { throw DuplicateFailure.changed }
    func id(_ value: UUID) -> UUID { value == entry.id ? reported.id : value }
    let entries = fresh.entries.map {
      ScanEntry(
        id: id($0.id), parentID: $0.parentID.map(id), path: $0.path, identity: $0.identity,
        observedAt: $0.observedAt, issues: $0.issues, readable: $0.readable)
    }
    let nodes = fresh.nodes.map {
      ScanNode(
        id: id($0.id), parentID: $0.parentID.map(id), logical: $0.logical, allocated: $0.allocated,
        knownItemCount: $0.knownItemCount, completeItemCount: $0.completeItemCount,
        partial: $0.partial, protected: $0.protected, skipped: $0.skipped)
    }
    let snapshot = ScanSnapshot(
      runID: runID, rootPath: fresh.rootPath, volumeDevice: fresh.volumeDevice, volumeID: fresh.volumeID,
      observedAt: fresh.observedAt, entries: entries, nodes: nodes)
    guard let selected = entries.first(where: { $0.id == reported.id }) else { throw DuplicateFailure.changed }
    return (snapshot, selected)
  }

  /// The root retains the engine's complete aggregate or lower bound; regular
  /// file facts describe candidates, never a directory inventory for actions.
  private func observation(run: ScanRun, facts: [FileFact]) throws -> ScanSnapshot {
    guard let root = run.tree.item(run.tree.rootID) else { throw DuplicateFailure.unavailable }
    let rootID = UUID()
    let observedAt = Date()
    let entries = facts.sorted(by: { $0.path < $1.path }).map {
      ScanEntry(
        parentID: rootID, path: $0.path, identity: $0.identity, observedAt: observedAt, issues: [], readable: true)
    }
    let rootNode = ScanNode(
      id: rootID, parentID: nil, logical: root.logical, allocated: root.allocated,
      knownItemCount: Int(clamping: root.itemCount) + 1,
      completeItemCount: root.partial ? nil : Int(clamping: root.itemCount) + 1,
      partial: root.partial, protected: root.isProtected, skipped: false)
    let nodes = entries.map { entry in
      let identity = entry.identity!
      return ScanNode(
        id: entry.id, parentID: rootID,
        logical: ByteAggregate(knownLowerBound: identity.logicalBytes, completeTotal: identity.logicalBytes),
        allocated: ByteAggregate(knownLowerBound: identity.allocatedBytes, completeTotal: identity.allocatedBytes),
        knownItemCount: 1, completeItemCount: 1, partial: false, protected: false, skipped: false)
    }
    return ScanSnapshot(
      runID: run.runID, rootPath: run.tree.rootPath, volumeDevice: root.device,
      volumeID: try? DescriptorFileSystem.volumeID(at: root.path), observedAt: observedAt,
      entries: [
        ScanEntry(id: rootID, parentID: nil, path: root.path, identity: nil, issues: [.notTraversed], readable: true)
      ] + entries,
      nodes: [rootNode] + nodes)
  }

  /// Reads several files at once; results keep input order and a failed read is nil.
  static func parallel(
    _ entries: [ScanEntry], width: Int = 6, _ work: @Sendable (ScanEntry) throws -> Data
  ) throws -> [Data?] {
    try Task.checkCancellation()
    let results = Mutex([Data?](repeating: nil, count: entries.count))
    let next = Atomic<Int>(0)
    DispatchQueue.concurrentPerform(iterations: min(width, entries.count)) { _ in
      while true {
        let index = next.add(1, ordering: .relaxed).oldValue
        guard index < entries.count else { return }
        let value = try? work(entries[index])
        results.withLock { $0[index] = value }
      }
    }
    try Task.checkCancellation()
    return results.withLock { $0 }
  }

  private func group(
    snapshot: ScanSnapshot, unavailableMetadata: Int = 0, omittedFiles: Int = 0, progress: (Int) -> Void
  ) throws -> DuplicateReport {
    guard let volumeID = snapshot.volumeID else {
      return DuplicateReport(
        snapshot: snapshot, groups: [], skippedCount: snapshot.entries.count + omittedFiles,
        partial: true, comparisonCount: 0)
    }
    var unique: [String: ScanEntry] = [:]
    var skipped = omittedFiles
    for entry in snapshot.entries {
      guard let identity = entry.identity, identity.kind == .regular,
        identity.logicalBytes >= 0, entry.readable, entry.issues.isEmpty,
        identity.hasStableTrashProof
      else {
        if entry.identity?.kind == .regular { skipped += 1 }
        continue
      }
      let physical = "\(identity.device):\(identity.inode)"
      if unique[physical] == nil { unique[physical] = entry }
    }
    let bySize = Dictionary(grouping: unique.values, by: { $0.identity!.logicalBytes })
    var groups: [DuplicateGroup] = []
    var compared = 0
    var comparisonCount = 0
    for (_, sameSize) in bySize.sorted(by: { $0.key > $1.key }) where sameSize.count > 1 {
      try Task.checkCancellation()
      var bySample: [Data: [ScanEntry]] = [:]
      let ordered = sameSize.sorted(by: { $0.path < $1.path })
      let samples = try Self.parallel(ordered) { try comparator.sample($0, volumeID: volumeID) }
      for (entry, sample) in zip(ordered, samples) {
        if let sample { bySample[sample, default: []].append(entry) } else { skipped += 1 }
        compared += 1
      }
      progress(compared)
      for candidates in bySample.values where candidates.count > 1 {
        var byDigest: [Data: [ScanEntry]] = [:]
        let digests = try Self.parallel(candidates) { try comparator.digest($0, volumeID: volumeID) }
        for (entry, digest) in zip(candidates, digests) {
          if let digest { byDigest[digest, default: []].append(entry) } else { skipped += 1 }
          compared += 1
        }
        progress(compared)
        for matches in byDigest.values where matches.count > 1 {
          var clusters: [[ScanEntry]] = []
          for entry in matches {
            try Task.checkCancellation()
            var inserted = false
            for index in clusters.indices {
              try Task.checkCancellation()
              do {
                comparisonCount += 1
                let result = try comparator.compare(clusters[index][0], entry, volumeID: volumeID)
                if result != .dataDifferent {
                  clusters[index].append(entry)
                  inserted = true
                  break
                }
              } catch is CancellationError { throw CancellationError() } catch { skipped += 1 }
            }
            if !inserted { clusters.append([entry]) }
            compared += 1
            progress(compared)
          }
          for cluster in clusters where cluster.count > 1 {
            var partitions: [[ScanEntry]] = []
            var unknownIDs: Set<UUID> = []
            for entry in cluster {
              try Task.checkCancellation()
              var inserted = false
              for index in partitions.indices {
                try Task.checkCancellation()
                do {
                  comparisonCount += 1
                  switch try comparator.compare(partitions[index][0], entry, volumeID: volumeID) {
                  case .equal:
                    partitions[index].append(entry)
                    inserted = true
                  case .metadataUnknown:
                    unknownIDs.insert(entry.id)
                    unknownIDs.insert(partitions[index][0].id)
                  case .metadataDifferent, .dataDifferent: break
                  }
                } catch is CancellationError { throw CancellationError() } catch { unknownIDs.insert(entry.id) }
                if inserted { break }
              }
              if !inserted { partitions.append([entry]) }
            }
            var memberByID: [UUID: DuplicateMember] = [:]
            for partition in partitions {
              let compatibilityID = partition.count > 1 ? UUID() : nil
              for entry in partition {
                memberByID[entry.id] = DuplicateMember(
                  entry: entry,
                  eligibility: compatibilityID != nil
                    ? .eligible
                    : unknownIDs.contains(entry.id) ? .metadataUnknown : .metadataDifferent,
                  compatibilityID: compatibilityID)
              }
            }
            groups.append(
              DuplicateGroup(
                logicalBytes: cluster[0].identity?.logicalBytes ?? 0,
                members: cluster.compactMap { memberByID[$0.id] }))
          }
        }
      }
    }
    groups.sort { $0.logicalBytes > $1.logicalBytes }
    try Task.checkCancellation()
    return DuplicateReport(
      snapshot: snapshot, groups: groups, skippedCount: skipped,
      partial: unavailableMetadata > 0 || skipped > 0 || snapshot.nodes.first?.partial == true,
      comparisonCount: comparisonCount)
  }
}
