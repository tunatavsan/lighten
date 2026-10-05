import Darwin
import Foundation
import Synchronization

public struct DuplicateService: Sendable {
  private let scan: ScanService
  private let configuration: ScanConfiguration
  private let comparator: DuplicateFileComparator
  private let planner: PlanService
  private let scope: DuplicateScanScope

  public init(
    scan: ScanService? = nil, comparator: DuplicateFileComparator = DuplicateFileComparator(),
    planner: PlanService = PlanService(), configuration: ScanConfiguration? = nil,
    scope: DuplicateScanScope? = nil
  ) {
    self.scope =
      scope
      ?? DuplicateScanScope(homeDirectory: configuration?.homeDirectory ?? scan?.homeDirectory ?? NSHomeDirectory())
    self.scan = scan ?? ScanService(homeDirectory: self.scope.homeDirectory)
    self.configuration = configuration ?? ScanConfiguration(homeDirectory: self.scope.homeDirectory)
    self.comparator = comparator
    self.planner = planner
  }

  /// Previous results contribute paths only. Each file is observed again without
  /// walking the selected root, and hashes and compatibility are freshly proved.
  public func observePicture(_ picture: DuplicatePicture) async throws -> DuplicateReport {
    let task = Task.detached {
      var entries: [ScanEntry] = []
      var nodes: [ScanNode] = []
      var refusals: [DuplicateObservationRefusal] = []
      var exclusions: [DuplicateScanExclusion] = []
      var volumeID: UUID?
      var device: UInt64 = 0
      let paths = Set(picture.groups.flatMap { $0.members.map(\.path) }).sorted()
      for path in paths {
        try Task.checkCancellation()
        if let reason = scope.exclusionReason(for: path, isDirectory: false, scanRoot: picture.rootPath) {
          exclusions.append(
            DuplicateScanExclusion(
              path: path,
              reason: DuplicateScanExclusion.Reason(rawValue: reason.rawValue) ?? .configuration, isDirectory: false))
          continue
        }
        do {
          let name = path as NSString
          let fresh = try await scan.scanImmediateChild(
            parentPath: name.deletingLastPathComponent, name: name.lastPathComponent, metadataOnly: true)
          guard let entry = fresh.entries.first(where: { $0.path == path }), let identity = entry.identity else {
            refusals.append(DuplicateObservationRefusal(path: path, reason: .unavailable))
            continue
          }
          guard identity.kind == .regular else {
            refusals.append(DuplicateObservationRefusal(path: path, reason: .notRegular))
            continue
          }
          guard entry.readable, entry.issues.isEmpty, identity.hasStableTrashProof,
            let node = fresh.nodes.first(where: { $0.id == entry.id }), !node.partial,
            let freshVolume = fresh.volumeID
          else {
            refusals.append(DuplicateObservationRefusal(path: path, reason: .unreadable))
            continue
          }
          guard scope.includesFile(path: path, logicalBytes: identity.logicalBytes, scanRoot: picture.rootPath) else {
            refusals.append(DuplicateObservationRefusal(path: path, reason: .outOfScope))
            continue
          }
          guard volumeID == nil || volumeID == freshVolume else {
            refusals.append(DuplicateObservationRefusal(path: path, reason: .unavailable))
            continue
          }
          volumeID = freshVolume
          device = fresh.volumeDevice
          entries.append(entry)
          nodes.append(node)
        } catch is CancellationError { throw CancellationError() } catch {
          refusals.append(DuplicateObservationRefusal(path: path, reason: .unavailable))
        }
      }
      let snapshot = ScanSnapshot(
        rootPath: picture.rootPath, volumeDevice: device, volumeID: volumeID,
        entries: entries, nodes: nodes)
      let report = try group(snapshot: snapshot, fresh: true, progress: { _ in })
      let groupedPaths = Set(report.groups.flatMap { $0.members.map { $0.entry.path } })
      let failedPaths = Set(report.refusals.map(\.path))
      refusals += report.refusals
      for entry in entries where !groupedPaths.contains(entry.path) && !failedPaths.contains(entry.path) {
        refusals.append(DuplicateObservationRefusal(path: entry.path, reason: .noLongerDuplicate))
      }
      try Task.checkCancellation()
      return DuplicateReport(
        snapshot: snapshot, groups: report.groups,
        skippedCount: refusals.count,
        partial: refusals.contains(where: { $0.reason.isVerificationFailure }) || report.partial,
        comparisonCount: report.comparisonCount, refusals: refusals, exclusions: exclusions)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func events(rootPath: String) -> AsyncThrowingStream<DuplicateEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached {
        do {
          let facts = Mutex<[FileFact]>([])
          let measuredBytes = Mutex((bytes: Int64(0), physical: Set<String>()))
          let omissions = Mutex<[ScanDiscoveryOmission]>([])
          if let reason = scope.exclusionReason(for: rootPath, isDirectory: true, scanRoot: rootPath),
            let mapped = DuplicateScanExclusion.Reason(rawValue: reason.rawValue)
          {
            let excluded = DuplicateScanExclusion(path: rootPath, reason: mapped, isDirectory: true)
            continuation.yield(
              .completed(
                DuplicateReport(
                  snapshot: ScanSnapshot(rootPath: rootPath, volumeDevice: 0, entries: [], nodes: []),
                  groups: [], skippedCount: 0, partial: false, comparisonCount: 0,
                  exclusions: [excluded], excludedRoot: excluded)))
            continuation.finish()
            return
          }
          if let identity = try? DescriptorFileSystem.identity(at: rootPath),
            identity.flags & UInt32(SF_DATALESS) != 0
          {
            let excluded = DuplicateScanExclusion(path: rootPath, reason: .cloudOnly, isDirectory: true)
            continuation.yield(
              .completed(
                DuplicateReport(
                  snapshot: ScanSnapshot(rootPath: rootPath, volumeDevice: identity.device, entries: [], nodes: []),
                  groups: [], skippedCount: 0, partial: false, comparisonCount: 0,
                  exclusions: [excluded], excludedRoot: excluded)))
            continuation.finish()
            return
          }
          var configuration = self.configuration
          configuration.discoveryPolicy = ScanDiscoveryPolicy(
            neutralExclusions: true, allowsLocalICloudFiles: true,
            onOmission: { omission in omissions.withLock { $0.append(omission) } })
          configuration.fileSink = FileSink(minLogicalBytes: scope.minimumBytes) { fact in
            guard scope.includesFile(path: fact.path, logicalBytes: fact.identity.logicalBytes, scanRoot: rootPath)
            else {
              return
            }
            facts.withLock { $0.append(fact) }
            measuredBytes.withLock { measured in
              guard measured.physical.insert("\(fact.identity.device):\(fact.identity.inode)").inserted else { return }
              let (sum, overflow) = measured.bytes.addingReportingOverflow(fact.identity.logicalBytes)
              measured.bytes = overflow ? Int64.max : sum
            }
          }
          let existingFilter = configuration.directoryFilter
          configuration.directoryFilter = { path in
            existingFilter?(path) != false
              && scope.traversesDirectory(path: path, scanRoot: rootPath)
          }
          let run = try ScanEngine(configuration: configuration).start(root: rootPath)
          var scanned = 0
          await withTaskCancellationHandler {
            for await update in run.progress {
              scanned = update.itemsSeen
              continuation.yield(.progress(scanned: scanned, compared: 0))
              continuation.yield(.measuredBytes(measuredBytes.withLock { $0.bytes }))
            }
            await run.waitUntilFinished()
          } onCancel: {
            run.cancel()
          }
          try Task.checkCancellation()
          guard !run.tree.wasCancelled else { throw CancellationError() }
          let snapshot = try observation(run: run, facts: facts.withLock { $0 })
          continuation.yield(.measuredBytes(measuredBytes.withLock { $0.bytes }))
          let unavailableMetadata = run.counters.snapshot["sinkMetadataUnavailable"] ?? 0
          let omittedFiles = run.counters.snapshot["sinkOmittedFiles"] ?? 0
          let grouped = try group(
            snapshot: snapshot, unavailableMetadata: unavailableMetadata, omittedFiles: omittedFiles
          ) { compared in
            continuation.yield(.progress(scanned: scanned, compared: compared))
          }
          var exclusions: [DuplicateScanExclusion] = []
          var refusals = grouped.refusals
          for omitted in omissions.withLock({ $0 }).sorted(by: { $0.path < $1.path }) {
            let exclusionReason: DuplicateScanExclusion.Reason?
            switch omitted.reason {
            case .filtered:
              let reason = scope.exclusionReason(
                for: omitted.path, isDirectory: omitted.isDirectory, scanRoot: rootPath)
              exclusionReason =
                reason.flatMap { DuplicateScanExclusion.Reason(rawValue: $0.rawValue) } ?? .configuration
            case .package: exclusionReason = .package
            case .cloudOnly: exclusionReason = .cloudOnly
            case .protectedArea: exclusionReason = .protectedArea
            case .mountBoundary: exclusionReason = .mountBoundary
            case .hardLinkAlias: exclusionReason = .hardLinkAlias
            case .unreadable, .changed, .metadataUnavailable:
              exclusionReason = nil
              let reason: DuplicateObservationRefusal.Reason =
                switch omitted.reason {
                case .changed: .changed
                case .metadataUnavailable: .metadataUnknown
                default: .unreadable
                }
              let refusal = DuplicateObservationRefusal(path: omitted.path, reason: reason)
              if !refusals.contains(refusal) { refusals.append(refusal) }
            }
            if let exclusionReason {
              let excluded = DuplicateScanExclusion(
                path: omitted.path, reason: exclusionReason, isDirectory: omitted.isDirectory)
              if !exclusions.contains(excluded) { exclusions.append(excluded) }
            }
          }
          let report = DuplicateReport(
            snapshot: snapshot, groups: grouped.groups, skippedCount: grouped.skippedCount,
            partial: grouped.partial || refusals.contains(where: { $0.reason.isVerificationFailure }),
            comparisonCount: grouped.comparisonCount, refusals: refusals, exclusions: exclusions,
            excludedRoot: exclusions.first(where: { $0.path == rootPath }))
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

  /// Unlike the strict API, one changed group cannot discard other fresh proofs.
  /// Refused groups remain named and no partially verified group contributes items.
  public func makeAvailablePlan(
    report: DuplicateReport, selections: [DuplicateGroupSelection]
  ) async throws -> DuplicatePlanResult {
    let task = Task.detached {
      try validateSelections(report: report, selections: selections)
      var items: [PlanItem] = []
      var refusals: [DuplicatePlanRefusal] = []
      for selection in selections {
        try Task.checkCancellation()
        do {
          let fragment = try await makePlanSelection(
            report: report, groupID: selection.groupID, keeperID: selection.keeperID,
            targetIDs: selection.targetIDs)
          items += fragment.items
        } catch is CancellationError { throw CancellationError() } catch let refusal as DuplicatePlanRefusal {
          refusals.append(refusal)
        } catch {
          let path =
            report.groups.first(where: { $0.id == selection.groupID })?.members.first(where: {
              $0.id == selection.keeperID
            })?.entry.path ?? report.snapshot.rootPath
          refusals.append(DuplicatePlanRefusal(groupID: selection.groupID, path: path, reason: .unavailable))
        }
      }
      guard Set(items.map(\.sourcePath)).count == items.count else { throw DuplicateFailure.invalidSelection }
      return DuplicatePlanResult(
        plan: items.isEmpty ? nil : ActionPlan(snapshotRunID: report.snapshot.runID, kind: .trash, items: items),
        refusals: refusals)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func validateSelections(report: DuplicateReport, selections: [DuplicateGroupSelection]) throws {
    guard !selections.isEmpty else { throw DuplicateFailure.invalidSelection }
    var members: Set<UUID> = []
    var paths: Set<String> = []
    var subsets: [UUID: Set<UUID>] = [:]
    for selection in selections {
      guard let group = report.groups.first(where: { $0.id == selection.groupID }),
        let keeper = group.members.first(where: { $0.id == selection.keeperID }),
        keeper.eligibility == .eligible, let compatibilityID = keeper.compatibilityID,
        !selection.targetIDs.isEmpty, !selection.targetIDs.contains(keeper.id),
        selection.targetIDs.allSatisfy({ group.canTarget($0, keeperID: keeper.id) }),
        subsets[group.id, default: []].insert(compatibilityID).inserted
      else { throw DuplicateFailure.invalidSelection }
      for member in group.members where member.id == keeper.id || selection.targetIDs.contains(member.id) {
        guard members.insert(member.id).inserted, paths.insert(member.entry.path).inserted else {
          throw DuplicateFailure.invalidSelection
        }
      }
    }
  }

  public func makePlan(
    report: DuplicateReport, selections: [DuplicateGroupSelection]
  ) async throws -> ActionPlan {
    let task = Task.detached {
      try validateSelections(report: report, selections: selections)
      var fragments: [ActionPlan] = []
      for selection in selections {
        try Task.checkCancellation()
        do {
          fragments.append(
            try await makePlanSelection(
              report: report, groupID: selection.groupID, keeperID: selection.keeperID,
              targetIDs: selection.targetIDs))
        } catch let refusal as DuplicatePlanRefusal {
          let failure: DuplicateFailure =
            switch refusal.reason {
            case .changed: .changed
            case .unavailable: .unavailable
            case .unreadable: .unreadable
            case .outOfScope: .outOfScope
            case .metadataUnknown: .metadataUnknown
            case .metadataDifferent: .metadataDifferent
            case .dataDifferent: .dataDifferent
            case .protectedArea: .protectedArea
            }
          throw failure
        }
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
    var currentPath = keeper.entry.path
    do {
      let (_, freshKeeper) = try await freshFile(
        keeper.entry, volumeID: volumeID, runID: report.snapshot.runID)
      let keeperDigest = try comparator.digest(freshKeeper, volumeID: volumeID)
      let keeperAncestors = try DescriptorFileSystem.ancestorIdentities(of: freshKeeper.path)
      var items: [PlanItem] = []
      for member in group.members.filter({ targetIDs.contains($0.id) }).sorted(by: { $0.entry.path < $1.entry.path }) {
        try Task.checkCancellation()
        currentPath = member.entry.path
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
        switch comparison {
        case .equal: break
        case .dataDifferent: throw DuplicateFailure.dataDifferent
        case .metadataDifferent: throw DuplicateFailure.metadataDifferent
        case .metadataUnknown: throw DuplicateFailure.metadataUnknown
        }
        let proof = DuplicateProof(
          groupID: groupID, keeper: freshKeeper, keeperAncestors: keeperAncestors,
          keeperVolumeID: volumeID, targetDigest: digest, keeperDigest: keeperDigest)
        items.append(
          PlanItem(
            id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
            inventory: item.inventory, ancestors: item.ancestors, duplicateProof: proof))
      }
      return ActionPlan(snapshotRunID: report.snapshot.runID, kind: .trash, items: items)
    } catch is CancellationError { throw CancellationError() } catch {
      let reason: DuplicatePlanRefusal.Reason =
        switch error {
        case DuplicateFailure.changed, PlanFailure.changedSinceScan: .changed
        case DuplicateFailure.metadataUnknown: .metadataUnknown
        case DuplicateFailure.metadataDifferent: .metadataDifferent
        case DuplicateFailure.dataDifferent: .dataDifferent
        case DuplicateFailure.unreadable: .unreadable
        case DuplicateFailure.outOfScope: .outOfScope
        case DuplicateFailure.protectedArea: .protectedArea
        default: .unavailable
        }
      throw DuplicatePlanRefusal(groupID: groupID, path: currentPath, reason: reason)
    }
  }

  /// Only selected files receive a fresh descriptor-relative inventory. Every
  /// identity field must still match the discovery observation.
  private func freshFile(
    _ reported: ScanEntry, volumeID: UUID, runID: UUID
  ) async throws -> (ScanSnapshot, ScanEntry) {
    guard scope.exclusionReason(for: reported.path, isDirectory: false, scanRoot: reported.path) == nil,
      !PackageNames.containsPackage(in: reported.path, isDirectory: false)
    else { throw DuplicateFailure.outOfScope }
    guard ProtectionPolicy.rule(for: reported.path, homeDirectory: scope.homeDirectory) == nil else {
      throw DuplicateFailure.protectedArea
    }
    let path = reported.path as NSString
    let fresh = try await scan.scanImmediateChild(
      parentPath: path.deletingLastPathComponent, name: path.lastPathComponent)
    if let entry = fresh.entries.first(where: { $0.path == reported.path }),
      !entry.readable || entry.issues.contains(.unreadable)
    {
      throw DuplicateFailure.unreadable
    }
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
    snapshot: ScanSnapshot, unavailableMetadata: Int = 0, omittedFiles: Int = 0,
    fresh: Bool = false, progress: (Int) -> Void
  ) throws -> DuplicateReport {
    guard let volumeID = snapshot.volumeID else {
      return DuplicateReport(
        snapshot: snapshot, groups: [], skippedCount: snapshot.entries.count + omittedFiles,
        partial: !snapshot.entries.isEmpty || omittedFiles > 0, comparisonCount: 0)
    }
    var unique: [String: ScanEntry] = [:]
    var skipped = omittedFiles
    var refusals: [DuplicateObservationRefusal] = []
    for entry in snapshot.entries {
      guard let identity = entry.identity, identity.kind == .regular,
        scope.includesFile(path: entry.path, logicalBytes: identity.logicalBytes, scanRoot: snapshot.rootPath),
        entry.readable, entry.issues.isEmpty, identity.hasStableTrashProof
      else {
        if entry.identity?.kind == .regular { skipped += 1 }
        continue
      }
      let physical = "\(identity.device):\(identity.inode)"
      if unique[physical] == nil { unique[physical] = entry }
    }
    struct Pair: Hashable {
      let first: UUID
      let second: UUID
    }
    let bySize = Dictionary(grouping: unique.values, by: { $0.identity!.logicalBytes })
    var groups: [DuplicateGroup] = []
    var compared = 0
    var comparisonCount = 0
    func compare(_ first: ScanEntry, _ second: ScanEntry) throws
      -> (comparison: DuplicateComparison, warnings: [DuplicateMetadataWarning])
    {
      try fresh
        ? comparator.compareWithMetadataWarnings(first, second, volumeID: volumeID)
        : comparator.discoveryCompare(first, second, volumeID: volumeID)
    }
    func failed(_ entry: ScanEntry) {
      skipped += 1
      refusals.append(DuplicateObservationRefusal(path: entry.path, reason: .unavailable))
    }
    for (_, sameSize) in bySize.sorted(by: { $0.key > $1.key }) where sameSize.count > 1 {
      try Task.checkCancellation()
      var bySample: [Data: [ScanEntry]] = [:]
      let ordered = sameSize.sorted(by: { $0.path < $1.path })
      let samples = try Self.parallel(ordered) {
        try fresh ? comparator.sample($0, volumeID: volumeID) : comparator.discoverySample($0, volumeID: volumeID)
      }
      for (entry, sample) in zip(ordered, samples) {
        if let sample { bySample[sample, default: []].append(entry) } else { failed(entry) }
        compared += 1
      }
      progress(compared)
      for candidates in bySample.values where candidates.count > 1 {
        var byDigest: [Data: [ScanEntry]] = [:]
        let digests = try Self.parallel(candidates) {
          try fresh ? comparator.digest($0, volumeID: volumeID) : comparator.discoveryDigest($0, volumeID: volumeID)
        }
        for (entry, digest) in zip(candidates, digests) {
          if let digest { byDigest[digest, default: []].append(entry) } else { failed(entry) }
          compared += 1
        }
        progress(compared)
        for matches in byDigest.values where matches.count > 1 {
          var clusters: [[ScanEntry]] = []
          var comparisons: [Pair: (comparison: DuplicateComparison, warnings: [DuplicateMetadataWarning])] = [:]
          for entry in matches.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            var inserted = false
            var unavailable = false
            for index in clusters.indices {
              do {
                comparisonCount += 1
                let representative = clusters[index][0]
                let result = try compare(representative, entry)
                comparisons[Pair(first: representative.id, second: entry.id)] = result
                if result.comparison != .dataDifferent {
                  clusters[index].append(entry)
                  inserted = true
                  break
                }
              } catch is CancellationError { throw CancellationError() } catch {
                failed(entry)
                unavailable = true
                break
              }
            }
            if !inserted && !unavailable { clusters.append([entry]) }
            compared += 1
            progress(compared)
          }
          for cluster in clusters where cluster.count > 1 {
            var partitions: [[ScanEntry]] = []
            var warnings: [UUID: Set<DuplicateMetadataWarning>] = [:]
            var unknownIDs: Set<UUID> = []
            for entry in cluster {
              try Task.checkCancellation()
              var inserted = false
              for index in partitions.indices {
                let representative = partitions[index][0]
                let pair = Pair(first: representative.id, second: entry.id)
                do {
                  let result: (comparison: DuplicateComparison, warnings: [DuplicateMetadataWarning])
                  if let cached = comparisons[pair] {
                    result = cached
                  } else {
                    comparisonCount += 1
                    result = try compare(representative, entry)
                    comparisons[pair] = result
                  }
                  switch result.comparison {
                  case .equal:
                    partitions[index].append(entry)
                    warnings[representative.id, default: []].formUnion(result.warnings)
                    inserted = true
                  case .metadataUnknown:
                    unknownIDs.insert(entry.id)
                    unknownIDs.insert(representative.id)
                  case .metadataDifferent, .dataDifferent: break
                  }
                } catch is CancellationError { throw CancellationError() } catch { unknownIDs.insert(entry.id) }
                if inserted { break }
              }
              if !inserted { partitions.append([entry]) }
            }
            let reportOnlyReason: DuplicateReportOnlyReason? =
              cluster.contains(where: { scope.isLocalICloudPath($0.path) })
              ? .protectedArea
              : !unknownIDs.isEmpty
                ? .metadataUnknown
                : partitions.count > 1 ? .protectiveMetadataDifferent : nil
            let compatibilityID = reportOnlyReason == nil ? UUID() : nil
            let differences = warnings.values.reduce(into: Set<DuplicateMetadataWarning>()) { $0.formUnion($1) }
              .sorted { $0.rawValue < $1.rawValue }
            let members = cluster.map { entry in
              DuplicateMember(
                entry: entry,
                eligibility: reportOnlyReason == nil
                  ? .eligible : reportOnlyReason == .metadataUnknown ? .metadataUnknown : .metadataDifferent,
                compatibilityID: compatibilityID, metadataWarnings: differences)
            }
            if let reportOnlyReason {
              let refusalReason: DuplicateObservationRefusal.Reason =
                switch reportOnlyReason {
                case .protectiveMetadataDifferent: .metadataDifferent
                case .metadataUnknown: .metadataUnknown
                case .protectedArea: .protectedArea
                }
              refusals += cluster.map { DuplicateObservationRefusal(path: $0.path, reason: refusalReason) }
            }
            groups.append(
              DuplicateGroup(
                logicalBytes: cluster[0].identity!.logicalBytes,
                members: members, reportOnlyReason: reportOnlyReason))
          }
        }
      }
    }
    groups.sort {
      $0.logicalBytes != $1.logicalBytes
        ? $0.logicalBytes > $1.logicalBytes
        : ($0.members.first?.entry.path ?? "") < ($1.members.first?.entry.path ?? "")
    }
    try Task.checkCancellation()
    return DuplicateReport(
      snapshot: snapshot, groups: groups, skippedCount: skipped,
      partial: unavailableMetadata > 0 || skipped > 0 || refusals.contains(where: { $0.reason.isVerificationFailure })
        || snapshot.nodes.contains(where: \.partial),
      comparisonCount: comparisonCount, refusals: refusals)
  }
}
