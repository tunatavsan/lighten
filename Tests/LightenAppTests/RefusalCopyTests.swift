import Darwin
import Foundation
import LightenKit
import Testing

@testable import Lighten

@Test(
  "Every plan refusal has English and Turkish reason and next step",
  arguments: [
    RejectionReason.bulkRoot, .scanRoot, .insidePackage, .protectedItem, .containsProtectedItem,
    .containsApplication, .mountPoint, .cloudItem, .unreadableFolder, .specialFile, .symbolicLinkRoot,
    .missingMetadata, .changedSinceScan, .differentVolume, .needsAdministrator, .userPermissionDenied,
    .processActive, .activityUnavailable, .mountedImage, .imageStateUnavailable,
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
  if reason == .missingMetadata {
    #expect(!english.localizedCaseInsensitiveContains("metadata"))
    #expect(!english.localizedCaseInsensitiveContains("undo"))
    #expect(!english.localizedCaseInsensitiveContains("scan again"))
    #expect(!turkish.localizedCaseInsensitiveContains("metaveri"))
    #expect(!turkish.localizedCaseInsensitiveContains("yeniden tarayın"))
  }
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
  if ["incompleteInventory", "invalidReceipt", "invalidProof", "metadataUnknown"].contains(code) {
    #expect(!english.localizedCaseInsensitiveContains("scan"))
    #expect(!turkish.localizedCaseInsensitiveContains("tarayın"))
  }
}

@Test("Protected refusals preserve both safety rule reason and descendant path")
@MainActor func cleanProtectedRefusalContext() throws {
  let rule = try #require(NeverRule.all.first)
  let text = SpaceText.rejection(
    PlanRejection(.containsProtectedItem, path: "/fixture/protected-child", ruleID: rule.id))
  #expect(text.contains(rule.id))
  #expect(text.contains(rule.reason))
  #expect(text.contains("/fixture/protected-child"))
}

@Test("Catalog resource failures preserve the failing stage and errno")
@MainActor func cleanCatalogFailureContext() {
  let text = FailureText.describe(CatalogFailure.resourceFailure(stage: "read catalog", code: 2))
  #expect(text.contains("read catalog"))
  #expect(text.contains("(2)"))
  #expect(text.contains(String(cString: strerror(ENOENT))))
}

@Test("Process refusals include process names and translate the next step")
@MainActor func cleanProcessFailureNames() {
  let english = FailureText.describe("processActive:LightenQA, pip", turkish: false)
  let turkish = FailureText.describe("processActive:LightenQA, pip", turkish: true)
  #expect(english.contains("LightenQA, pip"))
  #expect(turkish.contains("LightenQA, pip"))
  #expect(english != turkish)
  #expect(english.contains("Quit") && !english.localizedCaseInsensitiveContains("scan"))
  #expect(turkish.localizedCaseInsensitiveContains("kapat") && !turkish.localizedCaseInsensitiveContains("tarayın"))
  let refusal = SpaceText.rejection(PlanRejection(.processActive, path: "/fixture/in-use", ruleID: "LightenQA, pip"))
  #expect(refusal.contains("LightenQA, pip") && refusal.contains("/fixture/in-use"))
  #expect(!FailureText.describe("processActivityUnavailable", turkish: false).isEmpty)
  #expect(!FailureText.describe("processActivityUnavailable", turkish: true).isEmpty)
}

@Test(
  "Unknown native process diagnostics survive confirmation and execution failure copy",
  arguments: [
    "WindowServer (pid 123, uid 88): executable path unavailable; errno:1",
    "Fixture Helper (pid 456, uid 501): process identity unavailable; errno:13",
    "Fixture Helper (pid 456, uid 501): process identity changed during observation",
  ])
@MainActor func unknownNativeProcessFailureContext(details: String) throws {
  let path = "/fixture/Applications/Owned.app"
  let observation = ApplicationActivity(state: .unknown, processNames: [details])
  let rejection = PlanRejection(.activityUnavailable, path: path, ruleID: observation.processNames[0])
  let presentation = ActionPresentation(
    plan: ActionPlan(snapshotRunID: UUID(), kind: .trash, items: []), items: [], rejectedItems: [rejection])
  let refusal = try #require(presentation.rejectedItems.first)
  #expect(observation.state == .unknown && refusal.reason == .activityUnavailable)
  #expect(presentation.plan.items.isEmpty && refusal.ruleID == details)
  for turkish in [false, true] {
    let confirmation = FailureText.describe(refusal, turkish: turkish)
    #expect(confirmation.contains(turkish ? "kontrol edilemedi" : "could not be checked"))
    #expect(confirmation.contains(turkish ? "Etkinlik Monitörü" : "Activity Monitor"))
    #expect(confirmation.contains(details) && confirmation.hasSuffix(path))
    let execution = FailureText.describe("processActivityUnavailable:" + details, turkish: turkish)
    #expect(execution.contains(turkish ? "denetlenemedi" : "could not be checked"))
    #expect(execution.contains(turkish ? "Etkinlik Monitörü" : "Activity Monitor"))
    #expect(execution.contains(details))
    #expect(!execution.contains(turkish ? "neden başarısız" : "could not determine why"))
    for copy in [confirmation, execution] {
      #expect(!copy.localizedCaseInsensitiveContains(turkish ? "tarayın" : "scan"))
      #expect(!copy.localizedCaseInsensitiveContains(turkish ? "kapatın" : "quit"))
      #expect(!copy.localizedCaseInsensitiveContains("processActivityUnavailable"))
    }
  }
}

@Test("An empty process diagnostic stays unknown without inventing a name or errno")
@MainActor func emptyNativeProcessFailureContext() {
  for turkish in [false, true] {
    let bare = FailureText.describe("processActivityUnavailable", turkish: turkish)
    #expect(FailureText.describe("processActivityUnavailable:", turkish: turkish) == bare)
    let refusal = SpaceText.rejection(
      PlanRejection(.activityUnavailable, path: "/fixture/unknown"), turkish: turkish)
    #expect(refusal.hasSuffix("/fixture/unknown"))
    #expect(!refusal.contains("errno:") && !bare.contains("errno:"))
    #expect(!refusal.contains("pid ") && !bare.contains("pid "))
  }
}

@Test(
  "Catalog refusals explain their specific reason and next step in both languages",
  arguments: ["apple-system-cache", "minimum-age", "age-unavailable"])
@MainActor func cleanCatalogRefusalTranslations(ruleID: String) {
  let refusal = PlanRejection(.unavailable, path: "/fixture/catalog-child", ruleID: ruleID)
  let english = SpaceText.rejection(refusal, turkish: false)
  let turkish = SpaceText.rejection(refusal, turkish: true)
  #expect(english != turkish)
  #expect(english.contains(refusal.path) && turkish.contains(refusal.path))
  #expect(english.split(separator: ".").count >= 2)
  #expect(turkish.split(separator: ".").count >= 2)
  switch ruleID {
  case "apple-system-cache":
    #expect(english.contains("Apple system cache") && turkish.contains("Apple sistem önbelleği"))
  case "minimum-age":
    #expect(english.contains("recently modified") && turkish.contains("yakın zamanda değiştirilmiş"))
  default:
    #expect(english.contains("could not be verified") && turkish.contains("doğrulanamadı"))
  }
}

@Test("File operation refusals preserve actual errno, OS reason and path without guessing another cause")
@MainActor func fileOperationFailureContext() {
  let path = "/fixture/owned/blocked"
  let failure = NSError(
    domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
    userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
  for turkish in [false, true] {
    let text = FailureText.describe(failure, turkish: turkish)
    #expect(text.contains(path))
    #expect(text.contains("(\(EACCES))"))
    #expect(text.contains(String(cString: strerror(EACCES))))
    let refusal = SpaceText.rejection(
      PlanRejection(.unreadableFolder, path: path, ruleID: "errno:\(EACCES)"), turkish: turkish)
    #expect(refusal.contains(path) && refusal.contains("(\(EACCES))"))
    #expect(refusal.contains(String(cString: strerror(EACCES))))
    #expect(!refusal.localizedCaseInsensitiveContains(turkish ? "tarayın" : "scan"))
  }
  let typed = FailureText.describe(FileSystemFailure.systemCall("open", EROFS), turkish: false)
  #expect(typed.contains("read-only") && typed.contains("(\(EROFS))") && typed.contains("open"))
  let serialized = FailureText.describe("systemCall(\"open \(path)\", \(EACCES))", turkish: false)
  #expect(serialized.contains(path) && serialized.contains(String(cString: strerror(EACCES))))
}

@Test("An unknown refusal retains its supplied details without inventing missing files or permissions")
@MainActor func unknownFailureContextIsHonest() {
  let raw = "futureFailure(/fixture/unknown)"
  let english = FailureText.describe(raw, turkish: false)
  let turkish = FailureText.describe(raw, turkish: true)
  #expect(english.contains("could not determine why") && english.contains(raw))
  #expect(turkish.contains("neden başarısız") && turkish.contains(raw))
  #expect(!english.localizedCaseInsensitiveContains("permission"))
  #expect(!english.localizedCaseInsensitiveContains("missing"))
  let refusal = SpaceText.rejection(PlanRejection(.unavailable, path: "/fixture/actual", ruleID: raw), turkish: false)
  #expect(refusal.contains(raw) && refusal.contains("/fixture/actual"))
}
