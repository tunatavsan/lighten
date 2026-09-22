import Foundation

public struct DuplicateService: Sendable {
  private let scan: ScanService
  private let comparator: DuplicateFileComparator
  private let planner: PlanService

  public init(
    scan: ScanService = ScanService(), comparator: DuplicateFileComparator = DuplicateFileComparator(),
    planner: PlanService = PlanService()
  ) {
    self.scan = scan
    self.comparator = comparator
    self.planner = planner
  }

  public func events(rootPath: String) -> AsyncThrowingStream<DuplicateEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached {
        do {
          var snapshot: ScanSnapshot?
          var scanned = 0
          for try await event in scan.events(rootPath: rootPath) {
            try Task.checkCancellation()
            switch event {
            case .progress(let count, _):
              scanned = count
              continuation.yield(.progress(scanned: count, compared: 0))
            case .completed(let value): snapshot = value
            }
          }
          guard let snapshot else { throw DuplicateFailure.unavailable }
          let report = try group(snapshot: snapshot) { compared in
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
      let fragments = try selections.map {
        try makePlanImmediate(
          report: report, groupID: $0.groupID, keeperID: $0.keeperID,
          targetIDs: $0.targetIDs)
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

  private func makePlanImmediate(
    report: DuplicateReport, groupID: UUID, keeperID: UUID, targetIDs: Set<UUID>
  ) throws -> ActionPlan {
    guard let group = report.groups.first(where: { $0.id == groupID }),
      let keeper = group.members.first(where: { $0.id == keeperID && $0.eligibility == .eligible }),
      !targetIDs.isEmpty, !targetIDs.contains(keeperID),
      targetIDs.allSatisfy({ group.canTarget($0, keeperID: keeperID) }),
      let volumeID = report.snapshot.volumeID,
      let keeperIdentity = keeper.entry.identity
    else { throw DuplicateFailure.invalidSelection }
    let keeperDigest = try comparator.digest(keeper.entry, volumeID: volumeID)
    let keeperAncestors = try DescriptorFileSystem.ancestorIdentities(of: keeper.entry.path)
    let generic = try planner.makePlan(snapshot: report.snapshot, selectedIDs: targetIDs)
    var items: [PlanItem] = []
    for item in generic.items {
      guard let target = item.inventory.first,
        let targetIdentity = target.identity,
        targetIdentity.kind == .regular,
        targetIdentity.device != keeperIdentity.device || targetIdentity.inode != keeperIdentity.inode
      else { throw DuplicateFailure.invalidSelection }
      let digest = try comparator.digest(target, volumeID: volumeID)
      guard digest == keeperDigest else { throw DuplicateFailure.changed }
      let comparison = try comparator.compare(
        keeper.entry, target, volumeID: volumeID,
        expectedFirstDigest: keeperDigest, expectedSecondDigest: digest)
      guard comparison == .equal else { throw DuplicateFailure.invalidSelection }
      let proof = DuplicateProof(
        groupID: groupID, keeper: keeper.entry, keeperAncestors: keeperAncestors,
        keeperVolumeID: volumeID, targetDigest: digest, keeperDigest: keeperDigest)
      items.append(
        PlanItem(
          id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
          inventory: item.inventory, ancestors: item.ancestors, duplicateProof: proof))
    }
    return ActionPlan(snapshotRunID: generic.snapshotRunID, kind: .trash, items: items)
  }

  private func group(
    snapshot: ScanSnapshot, progress: (Int) -> Void
  ) throws -> DuplicateReport {
    guard let volumeID = snapshot.volumeID else {
      return DuplicateReport(
        snapshot: snapshot, groups: [], skippedCount: snapshot.entries.count,
        partial: true, comparisonCount: 0)
    }
    var unique: [String: ScanEntry] = [:]
    var skipped = 0
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
      for entry in sameSize.sorted(by: { $0.path < $1.path }) {
        do {
          bySample[try comparator.sample(entry, volumeID: volumeID), default: []].append(entry)
        } catch is CancellationError { throw CancellationError() } catch { skipped += 1 }
        compared += 1
        progress(compared)
      }
      for candidates in bySample.values where candidates.count > 1 {
        var byDigest: [Data: [ScanEntry]] = [:]
        for entry in candidates {
          try Task.checkCancellation()
          do {
            byDigest[try comparator.digest(entry, volumeID: volumeID), default: []].append(entry)
          } catch is CancellationError { throw CancellationError() } catch { skipped += 1 }
          compared += 1
          progress(compared)
        }
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
      partial: skipped > 0 || snapshot.nodes.first?.partial == true,
      comparisonCount: comparisonCount)
  }
}
