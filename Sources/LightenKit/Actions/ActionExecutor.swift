import Darwin
import Foundation

public protocol TrashMoving: Sendable {
  /// Returns the actual URL path chosen by the OS, including any collision rename.
  func moveToTrash(path: String) async throws -> String
}

public enum ActionOutcome: String, Codable, Sendable {
  case applied, skipped, failed, uncertain, notAttempted
}

public struct ItemActionResult: Codable, Sendable {
  public let itemID: UUID
  public let outcome: ActionOutcome
  public let detail: String?
  public let addedFileCount: Int?
  public let logicalByteDelta: Int64?
  public let deletedCount: Int
  public let deletedLogicalBytes: Int64

  public init(
    itemID: UUID, outcome: ActionOutcome, detail: String? = nil,
    deletedCount: Int = 0, deletedLogicalBytes: Int64 = 0,
    addedFileCount: Int? = nil, logicalByteDelta: Int64? = nil
  ) {
    self.addedFileCount = addedFileCount
    self.logicalByteDelta = logicalByteDelta
    self.itemID = itemID
    self.outcome = outcome
    self.detail = detail
    self.deletedCount = deletedCount
    self.deletedLogicalBytes = deletedLogicalBytes
  }
}

public struct ActionResult: Codable, Sendable {
  public let planID: UUID
  public let items: [ItemActionResult]
}

public enum ExecutionFailure: Error, Sendable {
  case catalogDeleteDenied, invalidPlan, corruptHistory, alreadyRunning, planAlreadyUsed, selfRemoval
}

public struct IrreversibleConfirmation: Sendable, Equatable {
  public let planID: UUID
  public let method: ActionKind

  public init(planID: UUID, method: ActionKind) {
    self.planID = planID
    self.method = method
  }
}

public actor ActionExecutor {
  private let journal: any ActionJournal
  private let trash: any TrashMoving
  private let guardService: ActionGuard
  private let beforeMutation: (@Sendable (PlanItem) async throws -> Void)?
  private let activity: any ProcessActivitySource
  private let catalog: CleanCatalog?
  private let related: RelatedDataService
  private let runningApplications: any RunningApplicationSource
  private let spaceActivity: any SpaceActivitySource
  private let mountedImages: any MountedImageSource
  private let applicationActivity: any ApplicationActivitySource
  private let duplicates: DuplicateFileComparator
  private var busy = false

  public init(
    journal: any ActionJournal, trash: any TrashMoving,
    guardService: ActionGuard = ActionGuard(),
    beforeMutation: (@Sendable (PlanItem) async throws -> Void)? = nil,
    activity: any ProcessActivitySource = UnknownProcessActivitySource(),
    catalog: CleanCatalog? = try? CleanCatalog(),
    related: RelatedDataService = RelatedDataService(),
    runningApplications: any RunningApplicationSource = NativeRunningApplicationSource(),
    duplicates: DuplicateFileComparator = DuplicateFileComparator(),
    spaceActivity: any SpaceActivitySource = NativeSpaceActivitySource(),
    mountedImages: any MountedImageSource = NativeMountedImageSource(),
    applicationActivity: any ApplicationActivitySource = NativeApplicationActivitySource()
  ) {
    self.journal = journal
    self.trash = trash
    self.guardService = guardService
    self.beforeMutation = beforeMutation
    self.activity = activity
    self.catalog = catalog
    self.related = related
    self.runningApplications = runningApplications
    self.duplicates = duplicates
    self.spaceActivity = spaceActivity
    self.mountedImages = mountedImages
    self.applicationActivity = applicationActivity
  }

  public func execute(
    _ plan: ActionPlan, confirmation: IrreversibleConfirmation? = nil
  ) async throws -> ActionResult {
    guard !busy else { throw ExecutionFailure.alreadyRunning }
    busy = true
    defer { busy = false }
    // Signature and entitlement reads happen before the journal is leased.
    // Inside the lease only these exact selected-owner identities can be used.
    let related = self.related
    let preparedOwners = await Task.detached(priority: .utility) {
      related.prepareInstalledOwners(plan: plan)
    }.value
    return try await journal.withMutationLease {
      try await self.executeLeased(plan, confirmation: confirmation, preparedOwners: preparedOwners)
    }
  }

  private func executeLeased(
    _ plan: ActionPlan, confirmation: IrreversibleConfirmation?, preparedOwners: InstalledOwnerPreparation
  ) async throws -> ActionResult {
    guard plan.schema == 1, !plan.items.isEmpty,
      Set(plan.items.map(\.id)).count == plan.items.count,
      plan.items.allSatisfy({ !$0.inventory.isEmpty }),
      !plan.items.enumerated().contains(where: { index, item in
        plan.items.dropFirst(index + 1).contains { other in
          other.sourcePath == item.sourcePath
            || other.sourcePath.hasPrefix(item.sourcePath + "/")
            || item.sourcePath.hasPrefix(other.sourcePath + "/")
        }
      })
    else { throw ExecutionFailure.invalidPlan }
    guard
      plan.items.allSatisfy({ item in
        [
          item.catalogProof != nil, item.relatedProof != nil,
          item.installedRelatedProof != nil, item.orphanRelatedProof != nil, item.duplicateProof != nil,
        ]
        .filter { $0 }.count <= 1
      })
    else { throw ExecutionFailure.invalidPlan }
    try validateDuplicatePlan(plan)
    guard plan.kind == .trash || plan.items.allSatisfy({ $0.policy == nil }) else {
      throw ExecutionFailure.invalidPlan
    }
    if plan.kind == .catalogDelete {
      guard confirmation == IrreversibleConfirmation(planID: plan.id, method: .catalogDelete),
        let catalog
      else { throw ExecutionFailure.catalogDeleteDenied }
      for item in plan.items { _ = try catalog.validate(item, in: plan) }
    }
    for item in plan.items where item.catalogProof != nil {
      guard let catalog else { throw CatalogFailure.unavailable }
      _ = try catalog.validate(item, in: plan)
    }
    for item in plan.items where item.relatedProof != nil {
      try related.validate(item, plan: plan)
    }
    for item in plan.items where item.orphanRelatedProof != nil {
      try related.validateOrphan(item, plan: plan)
    }
    let existing = try await journal.readSummary()
    guard existing.issues.isEmpty else { throw ExecutionFailure.corruptHistory }
    guard
      !existing.records.contains(where: {
        $0.kind == .intent && $0.planID == plan.id
      })
    else { throw ExecutionFailure.planAlreadyUsed }
    var preparationFailures = preparedOwners.failures
    var ownerFailures: [String: String] = [:]
    var ownerPackages: [String: PlanItem] = [:]
    let installedItems = plan.items.filter { $0.installedRelatedProof != nil }
    for item in installedItems {
      guard let proof = item.installedRelatedProof,
        ownerPackages[proof.appPath] == nil, ownerFailures[proof.appPath] == nil
      else { continue }
      do {
        let package: PlanItem
        if let included = plan.items.first(where: { $0.sourcePath == proof.appPath }) {
          package = included
        } else {
          let app = InstalledApplication(bundleID: proof.bundleID, path: proof.appPath, version: nil)
          guard let dependency = try related.packagePlan(app: app).items.first else {
            throw RelatedFailure.changedItem
          }
          package = dependency
        }
        guard RelatedDataService.currentUserOwns(package.sourcePath),
          package.policy == .wholeBundle, package.applicationBundleID == proof.bundleID,
          installedItems.filter({ $0.installedRelatedProof?.appPath == proof.appPath }).allSatisfy({ data in
            guard let binding = data.installedRelatedProof else { return false }
            return binding.bundleID == package.applicationBundleID
              && binding.appIdentity == package.inventory.first?.identity
              && binding.infoIdentity
                == (try? DescriptorFileSystem.identity(at: package.sourcePath + "/Contents/Info.plist"))
          })
        else { throw RelatedFailure.changedItem }
        try guardService.validate(package)
        try await validateApplication(package)
        try await validateSpaceActivity(package)
        ownerPackages[proof.appPath] = package
      } catch {
        ownerFailures[proof.appPath] = String(describing: error)
      }
    }
    var preparedItems: [PlanItem] = []
    var deltas: [UUID: (Int, Int64)] = [:]
    for item in plan.items {
      do {
        if let owner = item.installedRelatedProof?.appPath ?? ownerPackages[item.sourcePath]?.sourcePath,
          let detail = ownerFailures[owner]
        {
          throw SpaceValidationFailure(detail: detail)
        }
        if let detail = ownerFailures[item.sourcePath] { throw SpaceValidationFailure(detail: detail) }
        if item.installedRelatedProof != nil {
          if let failure = preparedOwners.failures[item.id] { throw SpaceValidationFailure(detail: failure) }
          guard let prepared = preparedOwners.owners[item.id] else { throw RelatedFailure.changedItem }
          try guardService.validate(item, plan: plan, preparedOwner: prepared)
        }
        if item.policy == .spaceTrash || item.policy == .wholeBundle {
          let refreshed = try guardService.refreshedSpaceItem(item)
          try await validateApplication(refreshed)
          try await validateSpaceActivity(refreshed)
          preparedItems.append(refreshed)
          let oldPaths = Set(item.inventory.filter { $0.identity?.kind != .directory }.map(\.path))
          let added = refreshed.inventory.filter {
            $0.identity?.kind != .directory && !oldPaths.contains($0.path)
          }.count
          deltas[item.id] = (added, Self.logicalBytes(refreshed) - Self.logicalBytes(item))
        } else {
          preparedItems.append(item)
        }
      } catch {
        preparationFailures[item.id] = String(describing: error)
        preparedItems.append(item)
      }
    }
    let executionPlan = ActionPlan(
      schema: plan.schema, id: plan.id, snapshotRunID: plan.snapshotRunID,
      kind: plan.kind, createdAt: plan.createdAt,
      items: preparedItems.filter { ownerPackages[$0.sourcePath] != nil }
        + preparedItems.filter { ownerPackages[$0.sourcePath] == nil })
    // The complete immutable inventory is durable before any OS mutation.
    try await journal.append(JournalRecord(kind: .intent, planID: plan.id, plan: executionPlan))

    var results: [ItemActionResult] = []
    var movedOwners: [String: MovedApplicationOwner] = [:]
    for item in executionPlan.items {
      do {
        if let detail = preparationFailures[item.id] { throw SpaceValidationFailure(detail: detail) }
        if item.catalogProof != nil { try await validateCatalogActivity(item, in: plan) }
        if let proof = item.relatedProof {
          guard await runningApplications.isRunning(bundleID: proof.bundleID) == false
          else { throw RelatedFailure.runningOrUnknown }
          try related.validate(item, plan: plan)
        }
        if let proof = item.installedRelatedProof {
          if let detail = ownerFailures[proof.appPath] { throw SpaceValidationFailure(detail: detail) }
          try await validateInstalledData(
            item, plan: executionPlan, packages: ownerPackages, moved: movedOwners, preparedOwners: preparedOwners)
        }
        if let proof = item.orphanRelatedProof {
          guard await runningApplications.isRunning(bundleID: proof.bundleID) == false
          else { throw RelatedFailure.runningOrUnknown }
          try related.validateOrphan(item, plan: plan)
        }
        if let proof = item.duplicateProof {
          try validateDuplicate(item, proof: proof)
        }
        try await validateApplication(item)
        try await validateSpaceActivity(item)
        if let proof = item.installedRelatedProof {
          guard let prepared = preparedOwners.owners[item.id] else { throw RelatedFailure.changedItem }
          try guardService.validate(item, plan: plan, preparedOwner: prepared, movedOwner: movedOwners[proof.appPath])
        } else {
          try guardService.validate(item)
        }
        try await beforeMutation?(item)
        // The hook models the final window. Never move on its prior validation.
        if item.catalogProof != nil { try await validateCatalogActivity(item, in: plan) }
        if let proof = item.relatedProof {
          guard await runningApplications.isRunning(bundleID: proof.bundleID) == false
          else { throw RelatedFailure.runningOrUnknown }
          try related.validate(item, plan: plan)
        }
        if let proof = item.installedRelatedProof {
          if let detail = ownerFailures[proof.appPath] { throw SpaceValidationFailure(detail: detail) }
          try await validateInstalledData(
            item, plan: executionPlan, packages: ownerPackages, moved: movedOwners, preparedOwners: preparedOwners)
        }
        if let proof = item.orphanRelatedProof {
          guard await runningApplications.isRunning(bundleID: proof.bundleID) == false
          else { throw RelatedFailure.runningOrUnknown }
          try related.validateOrphan(item, plan: plan)
        }
        if let proof = item.duplicateProof {
          try validateDuplicate(item, proof: proof)
        }
        try await validateApplication(item)
        try await validateSpaceActivity(item)
        if let proof = item.installedRelatedProof {
          guard let prepared = preparedOwners.owners[item.id] else { throw RelatedFailure.changedItem }
          try guardService.validate(item, plan: plan, preparedOwner: prepared, movedOwner: movedOwners[proof.appPath])
        } else {
          try guardService.validate(item)
        }
      } catch {
        let detail = String(describing: error)
        if ownerPackages[item.sourcePath] != nil { ownerFailures[item.sourcePath] = detail }
        do {
          try await journal.append(
            JournalRecord(
              kind: .skipped, planID: plan.id, itemID: item.id, detail: detail
            ))
          results.append(ItemActionResult(itemID: item.id, outcome: .skipped, detail: detail))
          continue
        } catch {
          results.append(ItemActionResult(itemID: item.id, outcome: .uncertain, detail: "journal failure"))
          break
        }
      }
      if plan.kind == .catalogDelete {
        let outcome = await deleteCatalogItem(item, planID: plan.id)
        results.append(outcome)
        if outcome.outcome == .uncertain { break }
        continue
      }
      let returnedPath: String
      do {
        returnedPath = try await trash.moveToTrash(path: item.sourcePath)
      } catch {
        let detail = String(describing: error)
        if ownerPackages[item.sourcePath] != nil { ownerFailures[item.sourcePath] = detail }
        // A throwing path-based OS call does not prove that the source stayed put.
        guard let original = item.inventory.first?.identity,
          (try? DescriptorFileSystem.identity(at: item.sourcePath)) == original
        else {
          results.append(
            ItemActionResult(
              itemID: item.id, outcome: .uncertain,
              detail: "Trash call failed and source identity is unverified"))
          break
        }
        do {
          try await journal.append(
            JournalRecord(
              kind: .failed, planID: plan.id, itemID: item.id, detail: detail
            ))
          results.append(ItemActionResult(itemID: item.id, outcome: .failed, detail: detail))
        } catch {
          results.append(ItemActionResult(itemID: item.id, outcome: .uncertain, detail: "journal failure"))
          break
        }
        continue
      }
      // A move without a verified identity and durable applied record is uncertain.
      do {
        let moved = try KnownPathFileSystem.identity(at: returnedPath)
        guard let original = item.inventory.first?.identity,
          let volumeID = item.volumeID,
          (try? DescriptorFileSystem.volumeID(at: returnedPath)) == volumeID,
          moved.matchesStableTrashIdentity(original)
        else {
          results.append(
            ItemActionResult(
              itemID: item.id, outcome: .uncertain, detail: "moved identity mismatch"
            ))
          break
        }
        do {
          try await journal.append(
            JournalRecord(
              kind: .applied, planID: plan.id, itemID: item.id,
              returnedTrashPath: returnedPath, movedIdentity: moved
            ))
        } catch {
          results.append(ItemActionResult(itemID: item.id, outcome: .uncertain, detail: "applied journal failure"))
          break
        }
        if ownerPackages[item.sourcePath] != nil {
          do {
            movedOwners[item.sourcePath] = try MovedApplicationOwner(
              planID: plan.id, package: item, path: returnedPath, identity: moved)
          } catch {
            // The applied record already describes the verified package move.
            // Dependent data needs this additional fresh owner context.
            ownerFailures[item.sourcePath] = String(describing: error)
          }
        }
        results.append(
          ItemActionResult(
            itemID: item.id, outcome: .applied,
            addedFileCount: deltas[item.id]?.0, logicalByteDelta: deltas[item.id]?.1))
      } catch {
        results.append(
          ItemActionResult(
            itemID: item.id, outcome: .uncertain,
            detail: "moved result could not be verified"))
        break
      }
    }
    let completed = Set(results.map(\.itemID))
    for item in plan.items where !completed.contains(item.id) {
      results.append(
        ItemActionResult(
          itemID: item.id, outcome: .notAttempted,
          detail: "stopped after an uncertain result"))
    }
    return ActionResult(planID: plan.id, items: results)
  }

  /// A whole application leaves only while it is not running and still carries
  /// the identity recorded in the plan. Lighten never removes itself.
  private func validateCatalogActivity(_ item: PlanItem, in plan: ActionPlan) async throws {
    guard let catalog else { throw CatalogFailure.unavailable }
    let row = try catalog.validate(item, in: plan)
    let observation = await activity.activity(
      for: row, rootPath: catalog.activityRoot(for: row, candidatePath: item.sourcePath))
    switch observation.state {
    case .clearObservedCurrentUID: return
    case .active: throw ProcessActivityFailure.active(processNames: observation.processNames)
    case .unknown: throw ProcessActivityFailure.unavailable
    }
  }

  private func validateApplication(_ item: PlanItem) async throws {
    if item.inventory.contains(where: { entry in
      entry.identity.map { ExactInventory.isOpaquePackage(path: entry.path, identity: $0, policy: item.policy) }
        == true
    }) {
      // Each validation gets a fresh census covering all package executables.
      let observation = await applicationActivity.activity(applicationPath: item.sourcePath)
      switch observation.state {
      case .clearObservedProcesses: break
      case .active: throw ProcessActivityFailure.active(processNames: observation.processNames)
      case .unknown:
        guard !observation.processNames.isEmpty else { throw ProcessActivityFailure.unavailable }
        throw SpaceValidationFailure(
          detail: "processActivityUnavailable:" + observation.processNames.joined(separator: ", "))
      }
    }
    if item.policy == .spaceTrash || item.policy == .catalogTrash || item.policy == .catalogBuildOutput
      || item.policy == .relatedTrash || item.policy == .relatedContainer || item.policy == .relatedGroupContainer
    {
      for id in item.nestedApplicationIDs ?? [] {
        if id.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame {
          throw ExecutionFailure.selfRemoval
        }
        guard await runningApplications.isRunning(bundleID: id) == false else {
          throw RelatedFailure.runningOrUnknown
        }
      }
      return
    }
    guard item.policy == .wholeBundle else { return }
    let currentIdentifier = ApplicationIdentity.bundleIdentifier(ofApplicationAt: item.sourcePath)
    if let expected = item.applicationBundleID,
      currentIdentifier != expected
    {
      throw RelatedFailure.changedItem
    }
    let everyID = [currentIdentifier].compactMap { $0 } + (item.nestedApplicationIDs ?? [])
    if everyID.contains(where: { $0.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame }) {
      throw ExecutionFailure.selfRemoval
    }
    for id in everyID where await runningApplications.isRunning(bundleID: id) != false {
      throw RelatedFailure.runningOrUnknown
    }
  }

  private func validateInstalledData(
    _ item: PlanItem, plan: ActionPlan, packages: [String: PlanItem], moved: [String: MovedApplicationOwner],
    preparedOwners: InstalledOwnerPreparation
  ) async throws {
    guard let proof = item.installedRelatedProof, let package = packages[proof.appPath],
      let prepared = preparedOwners.owners[item.id]
    else {
      throw RelatedFailure.changedItem
    }
    guard await runningApplications.isRunning(bundleID: proof.bundleID) == false else {
      throw RelatedFailure.runningOrUnknown
    }
    if let owner = moved[proof.appPath] {
      try await validateApplication(owner.movedPackage)
      try guardService.validate(item, plan: plan, preparedOwner: prepared, movedOwner: owner)
    } else {
      // Related-data-only selections still require a fresh, movable package.
      try guardService.validate(package)
      guard RelatedDataService.currentUserOwns(package.sourcePath) else { throw RelatedFailure.changedItem }
      try await validateApplication(package)
      try await validateSpaceActivity(package)
      try guardService.validate(item, plan: plan, preparedOwner: prepared)
    }
  }

  private func validateSpaceActivity(_ item: PlanItem) async throws {
    guard item.policy == .spaceTrash || item.policy == .wholeBundle else { return }
    for id in ProtectionPolicy.relatedApplicationIDs(
      for: item.inventory, homeDirectory: guardService.homeDirectory)
    where await runningApplications.isRunning(bundleID: id) != false {
      throw RelatedFailure.runningOrUnknown
    }
    let observed = await spaceActivity.activity(rootPath: item.sourcePath)
    switch observed.state {
    case .clearObservedCurrentUID: break
    case .active: throw ProcessActivityFailure.active(processNames: observed.processNames)
    case .unknown: throw ProcessActivityFailure.unavailable
    }
    let observations = try ExactInventory.packageObservations(for: item, homeDirectory: guardService.homeDirectory)
    for path in Set(
      ProtectionPolicy.sparseImageRoots(in: item.inventory, homeDirectory: guardService.homeDirectory)
        + observations.imagePaths)
    {
      switch await mountedImages.state(imagePath: path) {
      case .detached: break
      case .attached: throw SpaceValidationFailure(detail: "mountedImage")
      case .unknown: throw SpaceValidationFailure(detail: "imageStateUnavailable")
      }
    }
  }

  private static func logicalBytes(_ item: PlanItem) -> Int64 {
    var total: Int64 = 0
    for entry in item.inventory where entry.identity?.kind != .directory {
      let (next, overflow) = total.addingReportingOverflow(max(0, entry.identity?.logicalBytes ?? 0))
      total = overflow ? Int64.max : next
    }
    return total
  }

  private func validateDuplicatePlan(_ plan: ActionPlan) throws {
    let hasDuplicate = plan.items.contains { $0.duplicateProof != nil }
    if hasDuplicate {
      guard plan.kind == .trash,
        plan.items.allSatisfy({
          $0.duplicateProof != nil && $0.catalogProof == nil && $0.relatedProof == nil
            && $0.installedRelatedProof == nil && $0.orphanRelatedProof == nil
            && $0.inventory.count == 1 && $0.inventory.first?.identity?.kind == .regular
        })
      else { throw ExecutionFailure.invalidPlan }
    }
    let targetPaths = Set(plan.items.map(\.sourcePath))
    let physicalTargets = Set(
      plan.items.compactMap { item -> String? in
        guard let identity = item.inventory.first?.identity else { return nil }
        return "\(identity.device):\(identity.inode)"
      })
    for item in plan.items {
      guard let proof = item.duplicateProof else { continue }
      guard plan.kind == .trash, item.catalogProof == nil, item.relatedProof == nil,
        item.inventory.count == 1, item.inventory[0].id == item.id,
        item.inventory[0].path == item.sourcePath,
        item.inventory[0].identity?.kind == .regular,
        let target = item.inventory[0].identity,
        let keeper = proof.keeper.identity,
        keeper.kind == .regular, proof.keeper.path != item.sourcePath,
        proof.keeperVolumeID == item.volumeID,
        proof.targetDigest.count == 32, proof.keeperDigest.count == 32,
        proof.targetDigest == proof.keeperDigest,
        keeper.device == target.device, keeper.logicalBytes == target.logicalBytes,
        keeper.device != target.device || keeper.inode != target.inode,
        !targetPaths.contains(proof.keeper.path),
        !physicalTargets.contains("\(keeper.device):\(keeper.inode)")
      else { throw ExecutionFailure.invalidPlan }
    }
  }

  private func validateDuplicate(_ item: PlanItem, proof: DuplicateProof) throws {
    let keeperItem = PlanItem(
      id: proof.keeper.id, sourcePath: proof.keeper.path, volumeID: proof.keeperVolumeID,
      inventory: [proof.keeper], ancestors: proof.keeperAncestors)
    try guardService.validate(keeperItem)
    guard let target = item.inventory.first, let volumeID = item.volumeID,
      try duplicates.compare(
        proof.keeper, target, volumeID: volumeID,
        expectedFirstDigest: proof.keeperDigest,
        expectedSecondDigest: proof.targetDigest) == .equal
    else { throw DuplicateFailure.changed }
  }

  private func deleteCatalogItem(_ item: PlanItem, planID: UUID) async -> ItemActionResult {
    var count = 0
    var bytes: Int64 = 0
    // Children precede their parent. Each leaf is pinned through its parent FD
    // and checked again immediately before unlinkat; no path-based recursive delete.
    let leaves = item.inventory.sorted {
      let left = $0.path.split(separator: "/").count
      let right = $1.path.split(separator: "/").count
      return left == right ? $0.path > $1.path : left > right
    }
    let byPath = Dictionary(uniqueKeysWithValues: item.inventory.map { ($0.path, $0) })
    var remainingChildren: [String: Set<String>] = [:]
    var directoryAncestors: [String: [String]] = [:]
    for entry in item.inventory {
      if entry.path != item.sourcePath {
        remainingChildren[(entry.path as NSString).deletingLastPathComponent, default: []]
          .insert((entry.path as NSString).lastPathComponent)
      }
      var path =
        entry.identity?.kind == .directory
        ? entry.path : (entry.path as NSString).deletingLastPathComponent
      var directories: [String] = []
      while path == item.sourcePath || path.hasPrefix(item.sourcePath + "/") {
        if byPath[path]?.identity?.kind == .directory { directories.append(path) }
        if path == item.sourcePath { break }
        path = (path as NSString).deletingLastPathComponent
      }
      directoryAncestors[entry.path] = directories.reversed()
    }
    for entry in leaves {
      do {
        guard let expected = entry.identity,
          ProtectionPolicy.rule(for: entry.path, homeDirectory: guardService.homeDirectory) == nil,
          !ScanService.isPackage(entry.path), !ScanService.isInsidePackage(entry.path)
        else { throw CatalogFailure.invalidProof }
        // Re-resolve the original ancestor chain after each journal await.
        // Within the selected subtree, only our already removed descendants
        // may be absent; a newly added child stops the operation as partial.
        for ancestor in item.ancestors {
          guard let observed = try? DescriptorFileSystem.identity(at: ancestor.path),
            Self.stableDeleteDirectory(observed, ancestor.identity),
            ProtectionPolicy.rule(
              for: ancestor.path,
              homeDirectory: guardService.homeDirectory) == nil
          else { throw GuardFailure.changedAncestor }
        }
        // The immutable path index removes full-inventory filtering. Every
        // affected directory is still enumerated after each journal await;
        // observed ctime is never used to excuse an unknown child.
        for directoryPath in directoryAncestors[entry.path] ?? [] {
          guard let expectedDirectory = byPath[directoryPath]?.identity,
            let observed = try? DescriptorFileSystem.identity(at: directoryPath),
            Self.stableDeleteDirectory(observed, expectedDirectory),
            (try? DescriptorFileSystem.volumeID(at: directoryPath)) == item.volumeID
          else { throw GuardFailure.changedInventory }
          let observedNames = try DescriptorFileSystem.children(at: directoryPath, expected: observed)
          let expectedNames = remainingChildren[directoryPath] ?? []
          guard observedNames.count == expectedNames.count && observedNames.allSatisfy(expectedNames.contains)
          else { throw GuardFailure.changedInventory }
        }
        let (parentFD, name) = try DescriptorFileSystem.openParent(of: entry.path)
        defer { close(parentFD) }
        var pinnedParent = stat()
        guard fstat(parentFD, &pinnedParent) == 0,
          (try? DescriptorFileSystem.volumeID(at: (entry.path as NSString).deletingLastPathComponent)) == item.volumeID,
          let expectedParent =
            (byPath[(entry.path as NSString).deletingLastPathComponent]?.identity
              ?? item.ancestors.last?.identity),
          Self.stableDeleteDirectory(
            DescriptorFileSystem.identity(from: pinnedParent),
            expectedParent)
        else { throw GuardFailure.changedAncestor }
        // A deleted sibling can change its directory's ctime. All other identity
        // fields and the descendant inventory were checked before the first unlink.
        let current = try DescriptorFileSystem.identity(name: name, relativeTo: parentFD)
        guard
          expected.kind == .directory
            ? Self.stableDeleteDirectory(current, expected) : current == expected
        else { throw GuardFailure.changedItem }
        if expected.kind == .directory {
          guard try DescriptorFileSystem.children(at: entry.path, expected: current).isEmpty
          else { throw GuardFailure.changedInventory }
        }
        let flags: Int32 = expected.kind == .directory ? AT_REMOVEDIR : 0
        guard unlinkat(parentFD, name, flags) == 0 else {
          throw FileSystemFailure.systemCall("unlinkat", errno)
        }
        remainingChildren[(entry.path as NSString).deletingLastPathComponent]?.remove(name)
        remainingChildren.removeValue(forKey: entry.path)
        count += 1
        let value = max(0, expected.logicalBytes)
        let (next, overflow) = bytes.addingReportingOverflow(value)
        bytes = overflow ? Int64.max : next
        try await journal.append(
          JournalRecord(
            kind: .deleteProgress, planID: planID, itemID: item.id,
            deletedCount: count, deletedLogicalBytes: bytes))
      } catch {
        let detail = String(describing: error)
        do {
          try await journal.append(
            JournalRecord(
              kind: .failed, planID: planID, itemID: item.id, detail: detail,
              deletedCount: count, deletedLogicalBytes: bytes))
          return ItemActionResult(
            itemID: item.id, outcome: .failed, detail: detail,
            deletedCount: count, deletedLogicalBytes: bytes)
        } catch {
          return ItemActionResult(
            itemID: item.id, outcome: .uncertain,
            detail: "journal failure after irreversible deletion",
            deletedCount: count, deletedLogicalBytes: bytes)
        }
      }
    }
    do {
      try await journal.append(
        JournalRecord(
          kind: .applied, planID: planID, itemID: item.id,
          detail: "irreversible; undo unavailable", deletedCount: count,
          deletedLogicalBytes: bytes))
      return ItemActionResult(
        itemID: item.id, outcome: .applied,
        detail: "irreversible; undo unavailable", deletedCount: count,
        deletedLogicalBytes: bytes)
    } catch {
      return ItemActionResult(
        itemID: item.id, outcome: .uncertain,
        detail: "journal failure after irreversible deletion",
        deletedCount: count, deletedLogicalBytes: bytes)
    }
  }

  private static func stableDeleteDirectory(
    _ current: FileIdentity,
    _ expected: FileIdentity
  ) -> Bool {
    current.device == expected.device && current.inode == expected.inode
      && current.kind == .directory && expected.kind == .directory
      && current.birthSeconds != nil && current.birthSeconds == expected.birthSeconds
      && current.birthNanoseconds == expected.birthNanoseconds
      && current.flags == expected.flags
      && current.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
  }
}

/// lstat of a known absolute Trash result does not require opening ~/.Trash.
/// It is only an observation; renameatx_np separately enforces no-follow.
public enum KnownPathFileSystem {
  public static func identity(at path: String) throws -> FileIdentity {
    _ = try DescriptorFileSystem.validatedComponents(path)
    var details = stat()
    guard lstat(path, &details) == 0 else {
      throw FileSystemFailure.systemCall("lstat", errno)
    }
    return DescriptorFileSystem.identity(from: details)
  }
}

private struct SpaceValidationFailure: Error, CustomStringConvertible {
  let detail: String
  var description: String { detail }
}
