import Darwin
import Foundation
import Testing

@testable import Lighten
@testable import LightenKit

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

@Test("Protected refusals show a human safety reason and descendant path")
@MainActor func cleanProtectedRefusalContext() throws {
  let rule = try #require(NeverRule.all.first)
  let text = SpaceText.rejection(
    PlanRejection(.containsProtectedItem, path: "/fixture/protected-child", ruleID: rule.id))
  #expect(!text.contains(rule.id))
  #expect(text.contains("A safety rule protects an item inside this folder"))
  #expect(text.contains("/fixture/protected-child"))
}

@Test("Catalog resource failures show a reinstall step without internal diagnostics")
@MainActor func cleanCatalogFailureContext() {
  let text = FailureText.describe(CatalogFailure.resourceFailure(stage: "read catalog", code: 2))
  #expect(text.contains("could not load its catalog") && text.contains("Reinstall"))
  #expect(!text.contains("read catalog") && !text.contains("(2)"))
}

@Test("Process refusals hide internal diagnostics and translate the next step")
@MainActor func cleanProcessFailureNames() {
  let english = FailureText.describe("processActive:LightenQA, pip", turkish: false)
  let turkish = FailureText.describe("processActive:LightenQA, pip", turkish: true)
  #expect(!english.contains("processActive"))
  #expect(!turkish.contains("processActive"))
  #expect(english != turkish)
  #expect(english.contains("Quit") && !english.localizedCaseInsensitiveContains("scan"))
  #expect(turkish.localizedCaseInsensitiveContains("kapat") && !turkish.localizedCaseInsensitiveContains("tarayın"))
  let refusal = SpaceText.rejection(PlanRejection(.processActive, path: "/fixture/in-use", ruleID: "LightenQA, pip"))
  #expect(refusal.contains("/fixture/in-use") && refusal.contains("Quit"))
  #expect(!FailureText.describe("processActivityUnavailable", turkish: false).isEmpty)
  #expect(!FailureText.describe("processActivityUnavailable", turkish: true).isEmpty)
}

@Test(
  "Native process diagnostics remain internal while both languages give one next step",
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
    #expect(!confirmation.contains(details) && confirmation.hasSuffix(path))
    let execution = FailureText.describe("processActivityUnavailable:" + details, turkish: turkish)
    #expect(execution.contains(turkish ? "denetlenemedi" : "could not be checked"))
    #expect(execution.contains(turkish ? "Etkinlik Monitörü" : "Activity Monitor"))
    #expect(!execution.contains(details))
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

@Test("File operation refusals preserve the cause and path while hiding internal errno")
@MainActor func fileOperationFailureContext() {
  let path = "/fixture/owned/blocked"
  let failure = NSError(
    domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
    userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
  for turkish in [false, true] {
    let text = FailureText.describe(failure, turkish: turkish)
    #expect(text.contains(path))
    #expect(!text.contains("(\(EACCES))"))
    #expect(text.contains(turkish ? "erişimi reddetti" : "denied access"))
    let refusal = SpaceText.rejection(
      PlanRejection(.unreadableFolder, path: path, ruleID: "errno:\(EACCES)"), turkish: turkish)
    #expect(refusal.contains(path) && !refusal.contains("(\(EACCES))"))
    #expect(!refusal.contains("errno"))
    #expect(!refusal.localizedCaseInsensitiveContains(turkish ? "tarayın" : "scan"))
  }
  let typed = FailureText.describe(FileSystemFailure.systemCall("open", EROFS), turkish: false)
  #expect(typed.contains("read-only") && !typed.contains("(\(EROFS))"))
  let serialized = FailureText.describe("systemCall(\"open \(path)\", \(EACCES))", turkish: false)
  #expect(!serialized.contains("systemCall") && !serialized.contains("(\(EACCES))"))
}

@Test("An unknown refusal is visibly unrecognized without exposing its internal code")
@MainActor func unknownFailureContextIsHonest() {
  let raw = "futureFailure(/fixture/unknown)"
  let english = FailureText.describe(raw, turkish: false)
  let turkish = FailureText.describe(raw, turkish: true)
  #expect(english.contains("could not determine why") && !english.contains(raw))
  #expect(turkish.contains("neden başarısız") && !turkish.contains(raw))
  #expect(!english.localizedCaseInsensitiveContains("permission"))
  #expect(!english.localizedCaseInsensitiveContains("missing"))
  let refusal = SpaceText.rejection(PlanRejection(.unavailable, path: "/fixture/actual", ruleID: raw), turkish: false)
  #expect(!refusal.contains(raw) && refusal.contains("/fixture/actual"))
  #expect(FailureText.presentation(raw, turkish: false).unknownCodes == ["futureFailure"])
}

@Test(
  "Compound refusals keep the first human reason and exactly one next step in both languages",
  arguments: [
    ["processActive", "changedItem"],
    ["sharedInstalledData", "literalIdentifierOwner", "liveCensusUnavailable"],
    ["registrationUnavailable", "nameOnly"],
    ["protectedItem", "invalidReceipt"],
    ["userPermissionDenied", "changedAncestor", "incompleteInventory"],
    ["changedItem", "processActive", "changedItem"],
  ])
@MainActor func compoundFailurePresentation(_ codes: [String]) {
  for turkish in [false, true] {
    let combined = FailureText.presentation(codes.joined(separator: ";"), turkish: turkish)
    let first = FailureText.presentation(codes[0], turkish: turkish)
    #expect(combined.primaryReason == first.primaryReason)
    #expect(combined.nextStep == first.nextStep)
    #expect(combined.reasons.count == Set(codes).count)
    #expect(combined.unknownCodes.isEmpty)
    #expect(
      FailureText.additionalReasonLabel(combined.additionalReasons.count, turkish: turkish)
        .contains(turkish ? "neden daha" : "more reasons"))
    for code in codes { #expect(!combined.text.contains(code)) }
    #expect(!combined.nextStep.isEmpty)
  }
}

@Test("Candidate reason and ownership next step are human copy while diagnostics stay internal")
@MainActor func candidateFailurePresentation() {
  let path = "/fixture/data"
  let candidate = RelatedDataCandidate(
    id: path, path: path, classification: .shared, reason: .sharedInstalledData,
    snapshot: nil, receipt: nil,
    refusalEvidence: [
      RelatedOwnershipRefusalEvidence(
        candidatePath: path, bundleID: "qa.other", reason: .observedLiteralOwner,
        ownerPaths: ["/fixture/Other.app"], nextStep: "review-observed-owner", detail: "receipt metadata raw"),
      RelatedOwnershipRefusalEvidence(
        candidatePath: path, bundleID: "qa.other", reason: .sharedInstalledOwners,
        ownerPaths: ["/fixture/Other.app"], nextStep: "review-other-installations", detail: "machine raw"),
    ])
  for turkish in [false, true] {
    let presentation = FailureText.candidate(candidate, turkish: turkish)
    #expect(
      presentation.primaryReason == FailureText.presentation("observedLiteralOwner", turkish: turkish).primaryReason)
    #expect(presentation.additionalReasons.count == 1)
    #expect(presentation.nextStep == FailureText.nextStep("review-observed-owner", turkish: turkish).text)
    #expect(presentation.unknownCodes.isEmpty)
    #expect(!presentation.text.contains("metadata") && !presentation.text.contains("receipt"))
    #expect(!presentation.text.contains("review-observed-owner"))
  }
}

@Test("New refusal codes require a human translation instead of silently passing the fallback")
@MainActor func emittedRefusalCodesHaveHumanCopy() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Sources/LightenKit")
  let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
  let regex = try NSRegularExpression(pattern: #"ruleID:\s*"([A-Za-z][A-Za-z0-9-]+)""#)
  let steps = try NSRegularExpression(pattern: #"nextStep:\s*"([A-Za-z][A-Za-z0-9-]+)""#)
  var codes = Set<String>()
  var nextSteps = Set<String>()
  for case let url as URL in enumerator where url.pathExtension == "swift" {
    let source = try String(contentsOf: url, encoding: .utf8)
    for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
      guard let range = Range(match.range(at: 1), in: source) else { continue }
      codes.insert(String(source[range]))
    }
    for match in steps.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
      guard let range = Range(match.range(at: 1), in: source) else { continue }
      nextSteps.insert(String(source[range]))
    }
  }
  #expect(!codes.isEmpty)
  for code in codes {
    for turkish in [false, true] {
      let copy = FailureText.presentation(code, turkish: turkish)
      #expect(copy.unknownCodes.isEmpty, "Add EN/TR reason and next step for emitted refusal: \(code)")
      #expect(!copy.primaryReason.isEmpty && !copy.nextStep.isEmpty)
    }
  }
  for step in nextSteps {
    for turkish in [false, true] {
      let copy = FailureText.nextStep(step, turkish: turkish)
      #expect(copy.unknownCodes.isEmpty, "Add EN/TR next step for emitted evidence: \(step)")
      #expect(!copy.text.isEmpty && !copy.text.contains(step))
    }
  }
  #expect(FailureText.nextStep("future-next-step", turkish: false).unknownCodes == ["future-next-step"])
  let future = FailureText.presentation("future-refusal;processActive", turkish: false)
  #expect(future.unknownCodes == ["future-refusal"])
  #expect(future.primaryReason.contains("could not determine why"))
  #expect(future.additionalReasons.count == 1)
  #expect(!future.text.contains("future-refusal"))
}

@Test("Every declared backend failure and related reason has human EN/TR copy")
@MainActor func declaredFailureCodesHaveHumanCopy() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Sources/LightenKit")
  let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
  let enums = try NSRegularExpression(pattern: #"enum\s+\w+\s*:\s*[^\{]*\bError[^\{]*\{([^}]+)"#)
  let related = try NSRegularExpression(pattern: #"enum\s+Related(?:Reason|OwnershipRefusalReason)\s*:[^\{]*\{([^}]+)"#)
  let members = try NSRegularExpression(
    pattern: #"(?m)^\s*(?:(?:public|private|internal|nonisolated|static)\s+)*(?:var|func|init)\b"#)
  let payload = try NSRegularExpression(pattern: #"\([^)]*\)"#)
  var codes = Set<String>()
  for case let url as URL in enumerator where url.pathExtension == "swift" {
    let source = try String(contentsOf: url, encoding: .utf8)
    for expression in [enums, related] {
      for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
        guard let range = Range(match.range(at: 1), in: source) else { continue }
        var body = String(source[range])
        if let member = members.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
          let stop = Range(member.range, in: body)
        {
          body = String(body[..<stop.lowerBound])
        }
        let lines = body.components(separatedBy: .newlines)
        var declaration = ""
        for line in lines {
          let value = line.trimmingCharacters(in: .whitespaces)
          if value.hasPrefix("case ") {
            declaration = String(value.dropFirst(5))
          } else if declaration.hasSuffix(",") {
            declaration += value
          } else {
            continue
          }
          if declaration.hasSuffix(",") { continue }
          let names = payload.stringByReplacingMatches(
            in: declaration, range: NSRange(declaration.startIndex..., in: declaration), withTemplate: "")
          for name in names.components(separatedBy: ",") {
            let code = name.trimmingCharacters(in: .whitespaces)
            if code.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil { codes.insert(code) }
          }
          declaration = ""
        }
      }
    }
  }
  #expect(codes.contains("registrationUnavailable") && codes.contains("liveCensusUnavailable"))
  for code in codes {
    let english = FailureText.presentation(code, turkish: false)
    let turkish = FailureText.presentation(code, turkish: true)
    #expect(
      english.unknownCodes.isEmpty && turkish.unknownCodes.isEmpty,
      "New backend failure needs explicit human reason and next step: \(code)")
    #expect(!english.nextStep.isEmpty && !turkish.nextStep.isEmpty)
    #expect(english != turkish)
  }
}
