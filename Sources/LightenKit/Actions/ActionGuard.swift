import Darwin
import Foundation

public enum GuardFailure: Error, Codable, Sendable, Equatable {
  case changedAncestor, changedItem, changedInventory, protectedItem, unsupportedItem
}

public struct ActionGuard: Sendable {
  public let homeDirectory: String

  public init(homeDirectory: String = NSHomeDirectory()) {
    self.homeDirectory = homeDirectory
  }

  func validate(_ item: PlanItem, planID: UUID, movedOwner: MovedApplicationOwner) throws {
    let mapped = try movedOwner.mapped(item, planID: planID)
    try validate(movedOwner.movedPackage)
    try validate(mapped)
  }

  func validate(
    _ item: PlanItem, plan: ActionPlan, preparedOwner: PreparedInstalledOwner,
    movedOwner: MovedApplicationOwner? = nil
  ) throws {
    try preparedOwner.validate(item, plan: plan, movedOwner: movedOwner)
    if let movedOwner { try validate(movedOwner.movedPackage) }
    let mapped = try movedOwner?.mapped(item, planID: plan.id) ?? item
    try validate(mapped, installedScopePrepared: true)
  }

  public func validate(_ item: PlanItem) throws {
    guard item.userSelection != true else { throw GuardFailure.unsupportedItem }
    try ApplicationExplicitSelections.refuseWithoutPlan(item)
    try validate(item, installedScopePrepared: false)
  }

  public func validate(_ item: PlanItem, plan: ActionPlan) throws {
    if item.userSelection == true {
      try UserSelectionBindings.validate(plan, homeDirectory: homeDirectory)
      guard plan.items.contains(item) else { throw GuardFailure.unsupportedItem }
      try UserSelectionSafety.validateRoot(item, homeDirectory: homeDirectory)
      return
    }
    try ApplicationExplicitSelections.validate(item, plan: plan)
    try validate(item, installedScopePrepared: false)
  }

  func validate(
    _ item: PlanItem, plan: ActionPlan, preparedLink: PreparedApplicationLink,
    movedOwner: MovedApplicationOwner? = nil
  ) throws {
    try preparedLink.validate(item, plan: plan, movedOwner: movedOwner)
    if let movedOwner { try validate(movedOwner.movedPackage) } else { try validate(preparedLink.package.item) }
    try validate(item, installedScopePrepared: false, applicationLinkPrepared: true)
  }

  private func validate(
    _ item: PlanItem, installedScopePrepared: Bool, applicationLinkPrepared: Bool = false
  ) throws {
    let policy = item.policy
    if policy == .applicationLink {
      guard applicationLinkPrepared, item.inventory.count == 1,
        item.packageLinkTargetItemID != nil, item.applicationPackageObservation == nil,
        item.applicationBundleID == nil, (item.nestedApplicationIDs ?? []).isEmpty
      else { throw GuardFailure.unsupportedItem }
    } else {
      guard item.packageLinkTargetItemID == nil,
        item.applicationPackageObservation == nil || policy == .wholeBundle
      else { throw GuardFailure.unsupportedItem }
    }
    let relatedPolicy = policy == .relatedTrash || policy == .relatedContainer || policy == .relatedGroupContainer
    if relatedPolicy {
      guard item.catalogProof == nil, item.duplicateProof == nil,
        [item.relatedProof != nil, item.installedRelatedProof != nil, item.orphanRelatedProof != nil]
          .filter({ $0 }).count == 1
      else { throw GuardFailure.unsupportedItem }
      if !installedScopePrepared {
        let related = RelatedDataService(homeDirectory: homeDirectory, writeVerifiedReceipts: false)
        let run =
          item.snapshotRunID ?? item.installedRelatedProof?.snapshotRunID
          ?? item.relatedProof?.snapshotRunID ?? item.orphanRelatedProof?.snapshotRunID ?? UUID()
        let plan = ActionPlan(snapshotRunID: run, kind: .trash, items: [item])
        do { try related.validateScope(item, plan: plan) } catch { throw GuardFailure.unsupportedItem }
      } else {
        guard item.installedRelatedProof != nil else { throw GuardFailure.unsupportedItem }
      }
      if !installedScopePrepared {
        guard let (location, _) = RelatedLocation.matching(path: item.sourcePath, homeDirectory: homeDirectory),
          policy
            == (location == .containers
              ? .relatedContainer : location == .groupContainers ? .relatedGroupContainer : .relatedTrash)
        else { throw GuardFailure.unsupportedItem }
      }
    }
    // Catalog tree policies require a matching, bundled Trash authority.
    if policy == .catalogTrash || policy == .catalogBuildOutput {
      guard let proof = item.catalogProof, proof.method == .trash,
        item.relatedProof == nil, item.installedRelatedProof == nil, item.orphanRelatedProof == nil,
        item.duplicateProof == nil,
        let catalog = try? CleanCatalog(homeDirectory: homeDirectory),
        let row = try? catalog.validate(
          item, in: ActionPlan(snapshotRunID: proof.snapshotRunID, kind: .trash, items: [item])),
        policy == (row.class == "buildOutput" ? .catalogBuildOutput : .catalogTrash)
      else { throw GuardFailure.unsupportedItem }
    } else if policy != nil && !relatedPolicy {
      guard item.catalogProof == nil, item.relatedProof == nil, item.installedRelatedProof == nil,
        item.orphanRelatedProof == nil, item.duplicateProof == nil,
        !ExactInventory(homeDirectory: homeDirectory).isBulkRoot(item.sourcePath)
      else { throw GuardFailure.unsupportedItem }
    }
    if policy == .wholeBundle {
      guard item.inventory.first?.identity?.kind == .directory,
        ExactInventory.isApplicationName(item.sourcePath), !ScanService.isInsidePackage(item.sourcePath)
      else { throw GuardFailure.unsupportedItem }
      _ = try ApplicationPackagePlanning.validatePackage(item)
    }
    if policy == .catalogTrash || policy == .catalogBuildOutput || relatedPolicy
      || policy == .spaceTrash || policy == .wholeBundle
    {
      let identifiers: [String]
      do {
        identifiers = try ExactInventory.packageObservations(for: item, homeDirectory: homeDirectory).applicationIDs
      } catch let rejection {
        if rejection.reason == .containsProtectedItem || rejection.reason == .protectedItem {
          throw rejection
        }
        throw GuardFailure.changedInventory
      }
      guard
        !identifiers.contains(where: { $0.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame })
      else {
        let identifier = identifiers.first {
          $0.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame
        }
        throw PlanRejection(.lightenItself, path: item.sourcePath, ruleID: identifier)
      }
      guard identifiers.sorted() == (item.nestedApplicationIDs ?? []).sorted() else {
        throw GuardFailure.changedInventory
      }
    }
    // Strict items keep the original extension check; tree policies judge a
    // package root only when it really is a directory.
    let rootIsDirectory = item.inventory.first?.identity?.kind == .directory
    let rootIsPackage = ScanService.isPackage(item.sourcePath) && (policy == nil || rootIsDirectory)
    let rootIsApplication = rootIsDirectory && ExactInventory.isApplicationName(item.sourcePath)
    if policy == .wholeBundle || policy == .applicationLink {
      guard let expectedVolume = item.volumeID,
        (try? DescriptorFileSystem.volumeID(at: item.sourcePath)) == expectedVolume
      else { throw PlanRejection(.differentVolume, path: item.sourcePath) }
    }
    guard let root = item.inventory.first, root.id == item.id,
      root.path == item.sourcePath,
      root.identity?.kind == .regular || root.identity?.kind == .directory
        || (root.identity?.kind == .symbolicLink
          && (policy == .catalogTrash || policy == .catalogBuildOutput || policy == .applicationLink)),
      !PlanService.isBulkRoot(item.sourcePath, homeDirectory: homeDirectory),
      !rootIsPackage || policy != nil,
      policy != .wholeBundle || rootIsApplication,
      !ScanService.isInsidePackage(item.sourcePath),
      let volumeID = item.volumeID,
      (try? DescriptorFileSystem.volumeID(at: item.sourcePath)) == volumeID
    else { throw GuardFailure.unsupportedItem }
    let components: [String]
    do { components = try DescriptorFileSystem.validatedComponents(item.sourcePath) } catch {
      throw GuardFailure.changedAncestor
    }
    var prefix = ""
    let expectedAncestorPaths = components.dropLast().map { component in
      prefix += "/" + component
      return prefix
    }
    guard item.ancestors.map(\.path) == expectedAncestorPaths else {
      throw GuardFailure.changedAncestor
    }
    for ancestor in item.ancestors {
      let current: FileIdentity
      do { current = try DescriptorFileSystem.identity(at: ancestor.path) } catch { throw GuardFailure.changedAncestor }
      let rules = ProtectionPolicy.rules(for: ancestor.path, homeDirectory: homeDirectory)
      let permitted =
        (policy == .spaceTrash || policy == .wholeBundle || policy == .applicationLink)
        ? ProtectionPolicy.spaceTrashPermits(
          rules, path: ancestor.path, rootPath: item.sourcePath, homeDirectory: homeDirectory, ancestor: true)
        : rules.allSatisfy { policy == .relatedGroupContainer && $0.id == "group-containers" }
      guard current.sameStableDirectory(as: ancestor.identity), permitted
      else {
        if current.sameStableDirectory(as: ancestor.identity), !permitted,
          let rule = rules.first(where: { rule in
            (policy == .spaceTrash || policy == .wholeBundle || policy == .applicationLink)
              ? !ProtectionPolicy.spaceTrashPermits(
                [rule], path: ancestor.path, rootPath: item.sourcePath, homeDirectory: homeDirectory, ancestor: true)
              : !(policy == .relatedGroupContainer && rule.id == "group-containers")
          })
        {
          throw PlanRejection(.protectedItem, path: ancestor.path, ruleID: rule.id)
        }
        throw GuardFailure.changedAncestor
      }
    }
    let knownPaths = Set(item.inventory.map(\.path))
    let entriesByID = Dictionary(item.inventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let childrenByParent = Dictionary(
      grouping: item.inventory.dropFirst().compactMap { entry -> (UUID, String)? in
        guard let parentID = entry.parentID else { return nil }
        return (parentID, (entry.path as NSString).lastPathComponent)
      }, by: { $0.0 })
    guard item.inventory.first?.path == item.sourcePath,
      knownPaths.count == item.inventory.count,
      entriesByID.count == item.inventory.count
    else { throw GuardFailure.changedInventory }
    // Protection states follow the inventory's parent chain, one name at a time.
    let automaton = ProtectionAutomaton(homeDirectory: homeDirectory)
    var states: [UUID: ProtectionAutomaton.State] = [:]
    var opaqueRoots: [String] = []
    for entry in item.inventory {
      if opaqueRoots.contains(where: { entry.path.hasPrefix($0 + "/") }) { continue }
      let state: ProtectionAutomaton.State
      if let parentID = entry.parentID, entry.id != item.id, let parentState = states[parentID] {
        state = automaton.step(parentState, (entry.path as NSString).lastPathComponent)
      } else {
        state = automaton.state(forPath: entry.path)
      }
      states[entry.id] = state
      if let parentID = entry.parentID, entry.id != item.id {
        guard let parent = entriesByID[parentID],
          entry.path == parent.path + "/" + (entry.path as NSString).lastPathComponent
        else { throw GuardFailure.changedInventory }
      }
      guard let expected = entry.identity,
        entry.issues.isEmpty, entry.readable
      else {
        throw GuardFailure.unsupportedItem
      }
      let opaque = ExactInventory.isOpaquePackage(path: entry.path, identity: expected, policy: policy)
      guard opaque ? expected.hasOpaquePackageProof : expected.hasStableTrashProof else {
        throw GuardFailure.unsupportedItem
      }
      // Case-folded matching covers ProtectionPolicy's exact and alias checks.
      let rules = automaton.matches(state, path: entry.path, homeDirectory: homeDirectory)
      if !rules.isEmpty {
        let exempt =
          ((entry.id != item.id && entry.path.hasPrefix(item.sourcePath + "/"))
            || (entry.id == item.id
              && (policy == .relatedGroupContainer || policy == .spaceTrash || policy == .wholeBundle
                || policy == .applicationLink)))
          && policy.map {
            ExactInventory.permits(
              rules, policy: $0, path: entry.path, rootPath: item.sourcePath, homeDirectory: homeDirectory)
          } == true
        if !exempt {
          let rule = rules.first { rule in
            !(((entry.id != item.id && entry.path.hasPrefix(item.sourcePath + "/"))
              || (entry.id == item.id
                && (policy == .relatedGroupContainer || policy == .spaceTrash || policy == .wholeBundle
                  || policy == .applicationLink)))
              && policy.map {
                ExactInventory.permits(
                  [rule], policy: $0, path: entry.path, rootPath: item.sourcePath, homeDirectory: homeDirectory)
              } == true)
          }
          throw PlanRejection(
            entry.id == item.id ? .protectedItem : .containsProtectedItem, path: entry.path, ruleID: rule?.id)
        }
      }
      // Tree policies move symlinks as leaves (never followed) and packages as contents.
      let packageBoundary =
        policy == nil && (ScanService.isPackage(entry.path) || ScanService.isInsidePackage(entry.path))
      if packageBoundary
        || expected.device != root.identity?.device
        || (expected.kind == .symbolicLink
          && (policy == nil
            || (entry.id == item.id && policy != .catalogTrash && policy != .catalogBuildOutput
              && policy != .applicationLink)))
        || (expected.kind == .other
          && (entry.id == item.id || (policy != .spaceTrash && policy != .wholeBundle)
            || !Self.isMovableSpecialLeaf(entry.path)))
        || expected.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0
      {
        throw GuardFailure.unsupportedItem
      }
      let current: FileIdentity
      do { current = try DescriptorFileSystem.identity(at: entry.path) } catch { throw GuardFailure.changedItem }
      if opaque {
        guard (try? DescriptorFileSystem.volumeID(at: entry.path)) == volumeID
        else { throw GuardFailure.changedItem }
        do { try ExactInventory.validateOpaqueRoot(path: entry.path, expected: expected) } catch {
          if policy == .wholeBundle { throw error }
          throw GuardFailure.changedItem
        }
        opaqueRoots.append(entry.path)
      } else if current != expected {
        throw GuardFailure.changedItem
      }
      if expected.kind == .directory && !opaque {
        let names: [String]
        do { names = try DescriptorFileSystem.children(at: entry.path, expected: expected) } catch {
          throw GuardFailure.changedInventory
        }
        let planned = (childrenByParent[entry.id] ?? []).map(\.1).sorted()
        guard names == planned else { throw GuardFailure.changedInventory }
      }
    }
  }

  private static func isMovableSpecialLeaf(_ path: String) -> Bool {
    guard let (fd, name) = try? DescriptorFileSystem.openParent(of: path) else { return false }
    defer { close(fd) }
    var details = stat()
    guard fstatat(fd, name, &details, AT_SYMLINK_NOFOLLOW_ANY) == 0 else { return false }
    return details.st_mode & S_IFMT == S_IFSOCK || details.st_mode & S_IFMT == S_IFIFO
  }

  /// Refreshes only explicit Space trees. The old immutable root still binds the
  /// operation, while every new descendant receives all current safety checks.
  public func refreshedSpaceItem(_ item: PlanItem) throws -> PlanItem {
    try ApplicationExplicitSelections.refuseWithoutPlan(item)
    return try refreshedSpaceItem(item, plan: nil)
  }

  func refreshedSpaceItem(_ item: PlanItem, plan: ActionPlan?) throws -> PlanItem {
    if let plan { try ApplicationExplicitSelections.validate(item, plan: plan) }
    guard item.policy == .spaceTrash || item.policy == .wholeBundle,
      item.catalogProof == nil, item.relatedProof == nil, item.installedRelatedProof == nil,
      item.orphanRelatedProof == nil, item.duplicateProof == nil,
      item.inventory.first?.id == item.id, item.inventory.first?.path == item.sourcePath,
      Set(item.inventory.map(\.path)).count == item.inventory.count,
      Set(item.inventory.map(\.id)).count == item.inventory.count,
      let original = item.inventory.first?.identity,
      let current = try? DescriptorFileSystem.identity(at: item.sourcePath),
      original.matchesStableTrashIdentity(current)
    else { throw GuardFailure.changedItem }
    if item.policy == .wholeBundle { _ = try ApplicationPackagePlanning.validatePackage(item) }
    let result = try ExactInventory(homeDirectory: homeDirectory).collect(
      rootPath: item.sourcePath, expected: (original.device, original.inode), policy: item.policy)
    guard result.volumeID == item.volumeID,
      result.ancestors.count == item.ancestors.count,
      zip(result.ancestors, item.ancestors).allSatisfy({ current, old in
        current.path == old.path && current.identity.sameStableDirectory(as: old.identity)
      })
    else { throw GuardFailure.changedAncestor }
    let oldIDs = Dictionary(uniqueKeysWithValues: item.inventory.map { ($0.path, $0.id) })
    let ids = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.id, oldIDs[$0.path] ?? $0.id) })
    let entries = result.entries.map { entry in
      ScanEntry(
        id: ids[entry.id]!, parentID: entry.parentID.flatMap { ids[$0] }, path: entry.path,
        identity: entry.identity, observedAt: entry.observedAt, issues: entry.issues, readable: entry.readable)
    }
    let refreshed = PlanItem(
      id: item.id, sourcePath: item.sourcePath, volumeID: result.volumeID,
      inventory: entries, ancestors: item.ancestors, policy: result.policy,
      applicationBundleID: item.applicationBundleID, nestedApplicationIDs: result.nestedApplicationIDs,
      snapshotRunID: item.snapshotRunID, observedSize: item.observedSize,
      sizeMetadataVersion: item.sizeMetadataVersion,
      applicationPackageObservation: item.applicationPackageObservation,
      packageLinkTargetItemID: item.packageLinkTargetItemID)
    if let plan { try validate(refreshed, plan: plan) } else { try validate(refreshed) }
    return refreshed
  }

}

extension FileIdentity {
  /// Moving one sibling changes its parent's ctime and sometimes its size.
  /// Stable ancestry still requires the same volume, inode, directory kind,
  /// and file flags; selected roots and descendants use full equality.
  func sameStableDirectory(as other: FileIdentity) -> Bool {
    device == other.device && inode == other.inode && kind == .directory
      && other.kind == .directory && flags == other.flags
      && flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
  }
}
