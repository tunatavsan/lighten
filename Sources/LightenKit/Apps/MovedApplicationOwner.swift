import Darwin
import Foundation

/// Exists only after the executor verifies one package's applied Trash move.
/// It is never encoded or recovered as authority from a journal.
struct MovedApplicationOwner: Sendable {
  let planID: UUID
  let originalPackage: PlanItem
  let movedPackage: PlanItem
  let movedIdentity: FileIdentity

  init(planID: UUID, package: PlanItem, path: String, identity: FileIdentity) throws {
    guard package.policy == .wholeBundle, let original = package.inventory.first?.identity,
      original.matchesStableTrashIdentity(identity), Self.isAbsent(package.sourcePath)
    else { throw RelatedFailure.changedItem }
    self.planID = planID
    self.originalPackage = package
    self.movedIdentity = identity
    let entries = package.inventory.map { entry in
      ScanEntry(
        id: entry.id, parentID: entry.parentID,
        path: path + entry.path.dropFirst(package.sourcePath.count),
        identity: entry.id == package.id ? identity : entry.identity,
        observedAt: entry.observedAt, issues: entry.issues, readable: entry.readable)
    }
    self.movedPackage = PlanItem(
      id: package.id, sourcePath: path, volumeID: package.volumeID, inventory: entries,
      ancestors: try DescriptorFileSystem.ancestorIdentities(of: path), policy: .wholeBundle,
      applicationBundleID: package.applicationBundleID, nestedApplicationIDs: package.nestedApplicationIDs,
      snapshotRunID: package.snapshotRunID)
  }

  func mapped(_ item: PlanItem, planID: UUID) throws -> PlanItem {
    guard self.planID == planID, Self.isAbsent(originalPackage.sourcePath),
      let proof = item.installedRelatedProof,
      proof.appPath == originalPackage.sourcePath, proof.bundleID == originalPackage.applicationBundleID,
      proof.appIdentity == originalPackage.inventory.first?.identity,
      proof.infoIdentity
        == originalPackage.inventory.first(where: {
          $0.path == originalPackage.sourcePath + "/Contents/Info.plist"
        })?.identity,
      (try? DescriptorFileSystem.identity(at: movedPackage.sourcePath)) == movedIdentity,
      ApplicationIdentity.bundleIdentifier(ofApplicationAt: movedPackage.sourcePath) == proof.bundleID
    else { throw RelatedFailure.changedItem }
    let mapped = InstalledRelatedProof(
      bundleID: proof.bundleID, appPath: movedPackage.sourcePath, appIdentity: movedIdentity,
      infoIdentity: proof.infoIdentity, relatedPath: proof.relatedPath, relatedIdentity: proof.relatedIdentity,
      snapshotRunID: proof.snapshotRunID)
    return PlanItem(
      id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID, inventory: item.inventory,
      ancestors: item.ancestors, installedRelatedProof: mapped, policy: item.policy,
      nestedApplicationIDs: item.nestedApplicationIDs, snapshotRunID: item.snapshotRunID)
  }

  static func isAbsent(_ path: String) -> Bool {
    var details = stat()
    return lstat(path, &details) != 0 && errno == ENOENT
  }
}
