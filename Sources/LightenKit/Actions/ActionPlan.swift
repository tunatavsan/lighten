import Foundation

public enum ActionKind: String, Codable, Sendable, Hashable {
  case trash, catalogDelete
}

/// Display-only bytes observed separately from the inventory used to authorize an action.
public struct ObservedPlanSize: Codable, Sendable, Equatable {
  public let logical: ByteAggregate?
  public let allocated: ByteAggregate?

  public init(logical: ByteAggregate?, allocated: ByteAggregate?) {
    self.logical = Self.validated(logical)
    self.allocated = Self.validated(allocated)
  }

  public static let unknown = ObservedPlanSize(logical: nil, allocated: nil)

  public var validated: ObservedPlanSize { Self(logical: logical, allocated: allocated) }

  private static func validated(_ value: ByteAggregate?) -> ByteAggregate? {
    guard let value, value.knownLowerBound >= 0,
      value.completeTotal.map({ $0 >= value.knownLowerBound }) ?? true
    else { return nil }
    return value
  }

  /// A missing member makes the sum a lower bound; overflow makes that metric unknown.
  public static func total(_ values: [ObservedPlanSize]) -> ObservedPlanSize {
    func sum(_ values: [ByteAggregate?]) -> ByteAggregate? {
      var total: Int64 = 0
      var complete = true
      var hasKnown = values.isEmpty
      for raw in values {
        guard let value = validated(raw) else {
          complete = false
          continue
        }
        hasKnown = true
        let (next, overflow) = total.addingReportingOverflow(value.completeTotal ?? value.knownLowerBound)
        guard !overflow else { return nil }
        total = next
        complete = complete && value.completeTotal != nil
      }
      return hasKnown ? ByteAggregate(knownLowerBound: total, completeTotal: complete ? total : nil) : nil
    }
    return Self(logical: sum(values.map(\.logical)), allocated: sum(values.map(\.allocated)))
  }

  /// Counts hard links once and never uses a directory's own inode size as its contents size.
  public static func inventory(_ entries: [ScanEntry]) -> ObservedPlanSize {
    guard !entries.isEmpty else { return .unknown }
    var seen = Set<[UInt64]>()
    var values: [ObservedPlanSize] = []
    for entry in entries {
      guard let identity = entry.identity else {
        values.append(.unknown)
        continue
      }
      guard identity.kind != .directory else { continue }
      if identity.linkCount > 1, !seen.insert([identity.device, identity.inode]).inserted { continue }
      values.append(
        Self(
          logical: ByteAggregate(knownLowerBound: identity.logicalBytes, completeTotal: identity.logicalBytes),
          allocated: ByteAggregate(knownLowerBound: identity.allocatedBytes, completeTotal: identity.allocatedBytes)))
    }
    return total(values)
  }
}

public struct PlanItem: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let sourcePath: String
  public let volumeID: UUID?
  public let inventory: [ScanEntry]
  public let ancestors: [PathIdentity]
  /// The observation that supplied this item; older plans use the plan-level run.
  public let snapshotRunID: UUID?
  public let catalogProof: CatalogProof?
  public let relatedProof: RelatedProof?
  public let installedRelatedProof: InstalledRelatedProof?
  public let orphanRelatedProof: OrphanRelatedProof?
  public let duplicateProof: DuplicateProof?
  /// Absent in records written before tree policies existed; absent means strict.
  public let policy: TreePolicy?
  /// Bundle identifier of a whole application moved to the Trash; it must not be running.
  public let applicationBundleID: String?
  /// An expected layout and Info identity, checked against a fresh native read.
  public let applicationPackageObservation: ApplicationPackageObservation?
  /// A symbolic-link leaf's expected physical item in this same plan. This ID
  /// cannot grant authority without a current private package/link binding.
  public let packageLinkTargetItemID: UUID?
  /// Application packages included by the inventory; none may be running.
  public let nestedApplicationIDs: [String]?

  /// Optional contents-size observation. Guard, execution and Undo must not consult it.
  public let observedSize: ObservedPlanSize?
  /// Absent in legacy plans, preserving the exact shape of their compact journal metadata.
  public let sizeMetadataVersion: Int?
  /// Recovery provenance only; execution requires a private confirmation binding.
  public let userSelection: Bool?
  public let userSelectionWarnings: [UserSelectionWarning]?

  public var displaySize: ObservedPlanSize {
    if userSelection == true {
      return observedSize?.validated
        ?? (inventory.first?.identity?.kind == .directory ? .unknown : ObservedPlanSize.inventory(inventory))
    }
    if let sizeMetadataVersion, sizeMetadataVersion != 1 { return .unknown }
    return containsOpaquePackages ? (observedSize?.validated ?? .unknown) : ObservedPlanSize.inventory(inventory)
  }

  /// A presentation observation only; neither this value nor inventory size grants action authority.
  public var containsOpaquePackages: Bool {
    guard policy != nil else { return false }
    return inventory.contains { entry in
      guard entry.identity?.kind == .directory else { return false }
      return (policy == .wholeBundle && entry.path == sourcePath) || Self.isPackageName(entry.path)
    }
  }

  /// Presentation must remain stable after the source moves or disappears.
  static func isPackageName(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent.lowercased()
    return ScanService.packageSuffixes.contains { name.hasSuffix($0) }
  }

  public init(
    id: UUID, sourcePath: String, volumeID: UUID? = nil,
    inventory: [ScanEntry], ancestors: [PathIdentity], catalogProof: CatalogProof? = nil,
    relatedProof: RelatedProof? = nil, installedRelatedProof: InstalledRelatedProof? = nil,
    duplicateProof: DuplicateProof? = nil, policy: TreePolicy? = nil, applicationBundleID: String? = nil,
    nestedApplicationIDs: [String]? = nil, snapshotRunID: UUID? = nil,
    orphanRelatedProof: OrphanRelatedProof? = nil, observedSize: ObservedPlanSize? = nil,
    sizeMetadataVersion: Int? = 1, applicationPackageObservation: ApplicationPackageObservation? = nil,
    packageLinkTargetItemID: UUID? = nil, userSelection: Bool? = nil,
    userSelectionWarnings: [UserSelectionWarning]? = nil
  ) {
    self.id = id
    self.sourcePath = sourcePath
    self.volumeID = volumeID
    self.inventory = inventory
    self.ancestors = ancestors
    self.snapshotRunID = snapshotRunID
    self.catalogProof = catalogProof
    self.relatedProof = relatedProof
    self.installedRelatedProof = installedRelatedProof
    self.orphanRelatedProof = orphanRelatedProof
    self.duplicateProof = duplicateProof
    self.policy = policy
    self.applicationBundleID = applicationBundleID
    self.applicationPackageObservation = applicationPackageObservation
    self.packageLinkTargetItemID = packageLinkTargetItemID
    self.nestedApplicationIDs = nestedApplicationIDs
    self.observedSize = observedSize?.validated
    self.sizeMetadataVersion = sizeMetadataVersion
    self.userSelection = userSelection
    self.userSelectionWarnings = userSelectionWarnings
  }
}

public struct ActionPlan: Codable, Sendable, Equatable {
  public let schema: Int
  public let id: UUID
  public let snapshotRunID: UUID
  public let kind: ActionKind
  public let createdAt: Date
  public let items: [PlanItem]

  public init(
    schema: Int = 1, id: UUID = UUID(), snapshotRunID: UUID,
    kind: ActionKind, createdAt: Date = Date(), items: [PlanItem]
  ) {
    self.schema = schema
    self.id = id
    self.snapshotRunID = snapshotRunID
    self.kind = kind
    self.createdAt = createdAt
    self.items = items
  }
}

public enum PlanFailure: Error, Sendable, Equatable {
  case incompatibleSnapshot
  case unknownSelection
  case unsafeSelection
  case changedSinceScan
  case emptySelection
}

public struct PlanService: Sendable {
  public let homeDirectory: String
  private let runningApplications: any RunningApplicationSource
  private let spaceActivity: any SpaceActivitySource
  private let mountedImages: any MountedImageSource
  private let applicationActivity: any ApplicationActivitySource

  public init(
    homeDirectory: String = NSHomeDirectory(),
    runningApplications: any RunningApplicationSource = NativeRunningApplicationSource(),
    spaceActivity: any SpaceActivitySource = NativeSpaceActivitySource(),
    mountedImages: any MountedImageSource = NativeMountedImageSource(),
    applicationActivity: any ApplicationActivitySource = NativeApplicationActivitySource()
  ) {
    self.homeDirectory = homeDirectory
    self.runningApplications = runningApplications
    self.spaceActivity = spaceActivity
    self.mountedImages = mountedImages
    self.applicationActivity = applicationActivity
  }

  /// Planning walks the complete snapshot and performs descriptor checks.
  /// UI callers can use this entry point to keep that work off the main actor.
  public func makePlanAsync(
    snapshot: ScanSnapshot, selectedIDs: Set<UUID>, kind: ActionKind = .trash
  ) async throws -> ActionPlan {
    try await Task.detached {
      try makePlan(snapshot: snapshot, selectedIDs: selectedIDs, kind: kind)
    }.value
  }

  public func makePlan(
    snapshot: ScanSnapshot, selectedIDs: Set<UUID>, kind: ActionKind = .trash
  ) throws -> ActionPlan {
    guard snapshot.schema == 1 else { throw PlanFailure.incompatibleSnapshot }
    guard !selectedIDs.isEmpty else { throw PlanFailure.emptySelection }
    let entriesByID = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
    let nodesByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
    guard selectedIDs.allSatisfy({ entriesByID[$0] != nil }) else {
      throw PlanFailure.unknownSelection
    }
    let roots = selectedIDs.filter { id in
      var cursor = entriesByID[id]?.parentID
      while let current = cursor {
        if selectedIDs.contains(current) { return false }
        cursor = entriesByID[current]?.parentID
      }
      return true
    }.sorted { entriesByID[$0]!.path < entriesByID[$1]!.path }

    var items: [PlanItem] = []
    for id in roots {
      guard let root = entriesByID[id], let rootIdentity = root.identity,
        let node = nodesByID[id], !node.partial, !node.protected,
        rootIdentity.device == snapshot.volumeDevice,
        let volumeID = snapshot.volumeID,
        rootIdentity.kind == .regular || rootIdentity.kind == .directory,
        root.path != snapshot.rootPath,
        !Self.isBulkRoot(root.path, homeDirectory: homeDirectory),
        !ScanService.isPackage(root.path), !ScanService.isInsidePackage(root.path)
      else { throw PlanFailure.unsafeSelection }
      let inventory = snapshot.entries.filter {
        $0.id == id || isDescendant($0, of: id, entriesByID: entriesByID)
      }
      guard
        inventory.allSatisfy({ entry in
          guard let identity = entry.identity else { return false }
          return entry.issues.isEmpty && entry.readable && identity.hasStableTrashProof
            && identity.device == snapshot.volumeDevice
        })
      else { throw PlanFailure.unsafeSelection }
      let ancestors = try DescriptorFileSystem.ancestorIdentities(of: root.path)
      // The snapshot is an observation, not a grant. Planning itself rejects
      // an already changed source or ancestor.
      guard try DescriptorFileSystem.identity(at: root.path) == rootIdentity else {
        throw PlanFailure.changedSinceScan
      }
      guard try DescriptorFileSystem.volumeID(at: root.path) == volumeID else {
        throw PlanFailure.changedSinceScan
      }
      items.append(
        PlanItem(
          id: id, sourcePath: root.path, volumeID: volumeID,
          inventory: inventory, ancestors: ancestors))
    }
    return ActionPlan(snapshotRunID: snapshot.runID, kind: kind, items: items)
  }

  /// A Space selection observed by a scan tree. The tree is only a pointer:
  /// every fact in the plan comes from a fresh exact inventory.
  public struct Selection: Sendable, Equatable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    /// Display-only contents measured by the selected scan; never inventory evidence.
    public let observedSize: ObservedPlanSize?

    public init(path: String, device: UInt64, inode: UInt64, observedSize: ObservedPlanSize? = nil) {
      self.path = path
      self.device = device
      self.inode = inode
      self.observedSize = observedSize?.validated
    }
  }

  public struct AvailableSpacePlan: Sendable {
    public let plan: ActionPlan?
    public let rejections: [PlanRejection]

    public init(plan: ActionPlan?, rejections: [PlanRejection]) {
      self.plan = plan
      self.rejections = rejections
    }
  }

  /// Preserves the original all-or-nothing throwing API for existing callers.
  public func makeSpacePlan(
    selections: [Selection], scanRootPath: String, runID: UUID,
    isCancelled: @Sendable () -> Bool = { false }
  ) throws(PlanRejections) -> ActionPlan {
    let result = collectSpacePlan(
      selections: selections, scanRootPath: scanRootPath, runID: runID, isCancelled: isCancelled)
    guard result.rejections.isEmpty, let plan = result.plan else {
      throw PlanRejections(rejections: result.rejections)
    }
    return plan
  }

  /// Each refused selection stays visible while the other selections form one
  /// executable plan. Process and image observations never grant file authority.
  public func makeAvailableSpacePlan(
    selections: [Selection], scanRootPath: String, runID: UUID,
    isCancelled: @Sendable () -> Bool = { false }
  ) async -> AvailableSpacePlan {
    let collected = collectSpacePlan(
      selections: selections, scanRootPath: scanRootPath, runID: runID, isCancelled: isCancelled)
    guard let plan = collected.plan else { return collected }
    var items: [PlanItem] = []
    var rejections = collected.rejections
    for item in plan.items {
      let identifiers =
        [item.applicationBundleID].compactMap { $0 } + (item.nestedApplicationIDs ?? [])
        + ProtectionPolicy.relatedApplicationIDs(for: item.inventory, homeDirectory: homeDirectory)
      var refusal: PlanRejection?
      for id in Set(identifiers) where await runningApplications.isRunning(bundleID: id) != false {
        refusal = PlanRejection(.applicationRunning, path: item.sourcePath, ruleID: id)
        break
      }
      if refusal == nil,
        item.inventory.contains(where: { entry in
          entry.identity.map { ExactInventory.isOpaquePackage(path: entry.path, identity: $0, policy: item.policy) }
            == true
        })
      {
        // Executable paths under the selected root include every opaque package
        // and its helpers. Observe once per selection, rather than per package.
        let observation = await applicationActivity.activity(applicationPath: item.sourcePath)
        switch observation.state {
        case .clearObservedProcesses: break
        case .active:
          refusal = PlanRejection(
            .processActive, path: item.sourcePath, ruleID: observation.processNames.joined(separator: ", "))
        case .unknown:
          refusal = PlanRejection(
            .activityUnavailable, path: item.sourcePath,
            ruleID: observation.processNames.isEmpty ? nil : observation.processNames.joined(separator: ", "))
        }
      }
      if refusal == nil {
        let observation = await spaceActivity.activity(rootPath: item.sourcePath)
        switch observation.state {
        case .clearObservedCurrentUID: break
        case .active:
          refusal = PlanRejection(
            .processActive, path: item.sourcePath, ruleID: observation.processNames.joined(separator: ", "))
        case .unknown: refusal = PlanRejection(.activityUnavailable, path: item.sourcePath)
        }
      }
      if refusal == nil {
        do throws(PlanRejection) {
          let observations = try ExactInventory.packageObservations(for: item, homeDirectory: homeDirectory)
          guard observations.applicationIDs.sorted() == (item.nestedApplicationIDs ?? []).sorted() else {
            throw PlanRejection(.changedSinceScan, path: item.sourcePath)
          }
          for path in Set(
            ProtectionPolicy.sparseImageRoots(in: item.inventory, homeDirectory: homeDirectory)
              + observations.imagePaths)
          {
            switch await mountedImages.state(imagePath: path) {
            case .detached: break
            case .attached: refusal = PlanRejection(.mountedImage, path: path)
            case .unknown: refusal = PlanRejection(.imageStateUnavailable, path: path)
            }
            if refusal != nil { break }
          }
        } catch let rejection { refusal = rejection }
      }
      if let refusal { rejections.append(refusal) } else { items.append(item) }
    }
    return AvailableSpacePlan(
      plan: items.isEmpty ? nil : ActionPlan(id: plan.id, snapshotRunID: runID, kind: .trash, items: items),
      rejections: rejections)
  }

  private func collectSpacePlan(
    selections: [Selection], scanRootPath: String, runID: UUID,
    isCancelled: @Sendable () -> Bool
  ) -> AvailableSpacePlan {
    guard !selections.isEmpty else { return AvailableSpacePlan(plan: nil, rejections: []) }
    let sorted = selections.sorted { $0.path < $1.path }
    var roots: [Selection] = []
    for selection in sorted
    where !roots.contains(where: { $0.path == selection.path || selection.path.hasPrefix($0.path + "/") }) {
      roots.append(selection)
    }
    let inventory = ExactInventory(homeDirectory: homeDirectory)
    var items: [PlanItem] = []
    var rejections: [PlanRejection] = []
    for root in roots {
      if root.path == scanRootPath {
        rejections.append(PlanRejection(.scanRoot, path: root.path))
        continue
      }
      do throws(PlanRejection) {
        let result = try inventory.collect(
          rootPath: root.path, expected: (root.device, root.inode), isCancelled: isCancelled)
        var bundleID: String?
        var packageObservation: ApplicationPackageObservation?
        if result.policy == .wholeBundle {
          do {
            let metadata = try ApplicationPackagePlanning.metadata(at: root.path)
            bundleID = metadata.observation.bundleIdentifier
            packageObservation = metadata.observation
          } catch { throw ApplicationPackagePlanning.refusal(error, path: root.path) }
          let identifiers = [bundleID].compactMap { $0 } + result.nestedApplicationIDs
          if identifiers.contains(where: {
            $0.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame
          }) {
            throw PlanRejection(.lightenItself, path: root.path)
          }
        }
        items.append(
          PlanItem(
            id: result.entries[0].id, sourcePath: root.path, volumeID: result.volumeID, inventory: result.entries,
            ancestors: result.ancestors, policy: result.policy, applicationBundleID: bundleID,
            nestedApplicationIDs: result.nestedApplicationIDs,
            observedSize: root.observedSize, applicationPackageObservation: packageObservation))
      } catch {
        rejections.append(error)
      }
    }
    return AvailableSpacePlan(
      plan: items.isEmpty ? nil : ActionPlan(snapshotRunID: runID, kind: .trash, items: items),
      rejections: rejections)
  }

  private func isDescendant(
    _ entry: ScanEntry, of ancestor: UUID, entriesByID: [UUID: ScanEntry]
  ) -> Bool {
    var cursor = entry.parentID
    while let current = cursor {
      if current == ancestor { return true }
      cursor = entriesByID[current]?.parentID
    }
    return false
  }

  static func isBulkRoot(_ path: String, homeDirectory: String) -> Bool {
    let blocked = [
      "/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private", "/private/var", homeDirectory,
    ]
    let locale = Locale(identifier: "en_US_POSIX")
    let folded = path.lowercased(with: locale)
    return blocked.contains { $0.lowercased(with: locale) == folded }
  }
}
