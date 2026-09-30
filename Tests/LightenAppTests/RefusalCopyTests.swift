import LightenKit
import Testing

@testable import Lighten

@Test(
  "Every plan refusal has English and Turkish reason and next step",
  arguments: [
    RejectionReason.bulkRoot, .scanRoot, .insidePackage, .protectedItem, .containsProtectedItem,
    .containsApplication, .mountPoint, .cloudItem, .unreadableFolder, .specialFile, .symbolicLinkRoot,
    .missingMetadata, .changedSinceScan, .differentVolume, .needsAdministrator, .userPermissionDenied,
    .applicationRunning, .lightenItself, .tooManyItems, .unavailable,
  ])
@MainActor func cleanRefusalTranslations(_ reason: RejectionReason) {
  let refusal = PlanRejection(reason, path: "/fixture/child")
  let english = SpaceText.rejection(refusal, turkish: false)
  let turkish = SpaceText.rejection(refusal, turkish: true)
  #expect(!english.isEmpty && !turkish.isEmpty)
  #expect(english != turkish)
  #expect(english.contains("/fixture/child") && turkish.contains("/fixture/child"))
  #expect(english.split(separator: ".").count >= 2)
  #expect(turkish.split(separator: ".").count >= 2)
  if reason == .userPermissionDenied {
    #expect(!english.localizedCaseInsensitiveContains("administrator"))
    #expect(!turkish.localizedCaseInsensitiveContains("yönetici"))
  }
}

@Test(
  "Failure codes have translated reasons and next steps",
  arguments: [
    "catalogDeleteDenied", "runningOrUnknown", "selfRemoval", "changedItem", "changedAncestor",
    "changedInventory", "changed", "changedSinceScan", "changedDuringInspection", "changedTrashItem",
    "trashItemMissing", "protectedItem", "unsupportedItem", "unsafeSelection", "incompleteInventory",
    "ownerPresent", "ambiguousOwner", "invalidReceipt", "invalidProof", "unauthorizedPath", "invalidPlan",
    "planAlreadyUsed", "incompatibleSnapshot", "unknownSelection", "emptySelection", "corruptHistory",
    "alreadyRunning", "nameOccupied", "unsafeParent", "noAppliedRecord", "unknownItem", "invalidSelection",
    "metadataUnknown", "metadataDifferent", "dataDifferent", "notDirectory", "rootNotDirectory",
    "unavailable", "childUnavailable", "invalidPath", "systemCall", "renameFailed", "invalidManifest",
    "unsupportedInstalledData",
  ])
@MainActor func cleanFailureTranslations(_ code: String) {
  let english = FailureText.describe(code, turkish: false)
  let turkish = FailureText.describe(code, turkish: true)
  #expect(!english.isEmpty && !turkish.isEmpty)
  #expect(english != turkish)
  #expect(!english.contains("(\(code))"))
  #expect(english.split(separator: ".").count >= 2)
  #expect(turkish.split(separator: ".").count >= 2)
}

@Test("Protected refusals preserve both safety rule reason and descendant path")
@MainActor func cleanProtectedRefusalContext() throws {
  let rule = try #require(NeverRule.all.first)
  let text = SpaceText.rejection(
    PlanRejection(.containsProtectedItem, path: "/fixture/protected-child", ruleID: rule.id))
  #expect(text.contains(rule.reason))
  #expect(text.contains("/fixture/protected-child"))
}

@Test("Catalog resource failures preserve the failing stage and errno")
@MainActor func cleanCatalogFailureContext() {
  let text = FailureText.describe(CatalogFailure.resourceFailure(stage: "read catalog", code: 2))
  #expect(text.contains("read catalog"))
  #expect(text.contains("(2)"))
}

@Test("Process refusals include process names and translate the next step")
@MainActor func cleanProcessFailureNames() {
  let english = FailureText.describe("processActive:LightenQA, pip", turkish: false)
  let turkish = FailureText.describe("processActive:LightenQA, pip", turkish: true)
  #expect(english.contains("LightenQA, pip"))
  #expect(turkish.contains("LightenQA, pip"))
  #expect(english != turkish)
  #expect(!FailureText.describe("processActivityUnavailable", turkish: false).isEmpty)
  #expect(!FailureText.describe("processActivityUnavailable", turkish: true).isEmpty)
}
