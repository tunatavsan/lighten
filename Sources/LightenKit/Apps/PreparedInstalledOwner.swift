import Foundation

/// A short-lived validation result for one exact item in one execution. It is
/// not encoded, recovered from a journal, or usable by a later execution.
struct PreparedInstalledOwner: Sendable {
  let planID: UUID
  let item: PlanItem
  let signatures: [ApplicationSignatureIdentity]

  func validate(_ selected: PlanItem, plan: ActionPlan, movedOwner: MovedApplicationOwner?) throws {
    guard plan.id == planID, selected == item, plan.kind == .trash,
      let originalProof = item.installedRelatedProof,
      RelatedDataService.currentUserOwns(item.sourcePath),
      (try? DescriptorFileSystem.identity(at: item.sourcePath)) == originalProof.relatedIdentity
    else { throw RelatedFailure.changedItem }
    let current = try movedOwner?.mapped(item, planID: plan.id) ?? item
    guard let proof = current.installedRelatedProof else { throw RelatedFailure.changedItem }
    let metadata: ApplicationPackageMetadata
    do { metadata = try ApplicationPackagePlanning.metadata(at: proof.appPath) } catch {
      throw RelatedFailure.changedItem
    }
    guard
      (try? DescriptorFileSystem.identity(at: proof.appPath)) == proof.appIdentity,
      metadata.observation.infoIdentity == proof.infoIdentity,
      metadata.observation.bundleIdentifier == proof.bundleID
    else { throw RelatedFailure.changedItem }
    for signature in signatures {
      if let movedOwner {
        try signature.validate(
          mappedFrom: originalProof.appPath, to: movedOwner.movedPackage.sourcePath,
          movedRoot: movedOwner.movedIdentity)
      } else {
        try signature.validate()
      }
    }
  }
}

struct InstalledOwnerPreparation: Sendable {
  var owners: [UUID: PreparedInstalledOwner] = [:]
  var failures: [UUID: String] = [:]
}
