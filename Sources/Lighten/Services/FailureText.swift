import Darwin
import Foundation
import LightenKit

struct FailurePresentation: Equatable, Sendable {
  let reasons: [String]
  let nextStep: String
  let unknownCodes: [String]
  var primaryReason: String { reasons.first ?? "" }
  var additionalReasons: [String] { Array(reasons.dropFirst()) }
  var text: String { reasons.joined(separator: " ") + " " + nextStep }
}

/// Machine-readable failures are presented as a reason and one next step.
enum FailureText {
  static func describe(_ error: any Error, turkish: Bool? = nil) -> String {
    if let rejection = error as? PlanRejection { return SpaceText.rejection(rejection, turkish: turkish) }
    if let refusals = error as? PlanRejections {
      return refusals.rejections.map { SpaceText.rejection($0, turkish: turkish) }.joined(separator: "\n")
    }
    if case FileSystemFailure.systemCall(_, let number) = error {
      return posixFailure(number, turkish: turkish)
    }
    if case JournalFailure.systemCall(_, let number) = error {
      return posixFailure(number, turkish: turkish)
    }
    if case UndoFailure.renameFailed(let number) = error { return posixFailure(number, turkish: turkish) }
    if case ScanStartFailure.unavailable(let number) = error { return posixFailure(number, turkish: turkish) }
    if case DirectoryReadFailure.open(let number) = error { return posixFailure(number, turkish: turkish) }
    if case DirectoryReadFailure.read(let number) = error { return posixFailure(number, turkish: turkish) }
    let systemError = error as NSError
    if systemError.domain == NSPOSIXErrorDomain, let number = Int32(exactly: systemError.code) {
      let path = systemError.userInfo[NSFilePathErrorKey] as? String
      return posixFailure(number, turkish: turkish) + (path.map { " — " + $0 } ?? "")
    }
    if let underlying = systemError.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain, let number = Int32(exactly: underlying.code)
    {
      let path = systemError.userInfo[NSFilePathErrorKey] as? String
      return posixFailure(number, turkish: turkish) + (path.map { " — " + $0 } ?? "")
    }
    if case CatalogFailure.resourceFailure = error {
      return text(
        "Clean could not load its catalog. Reinstall Lighten.",
        "Temizlik kataloğu yüklenemedi. Lighten’ı yeniden kurun.", turkish: turkish)
    }
    return describe(String(describing: error), turkish: turkish)
  }

  static func describe(_ raw: String) -> String { describe(raw, turkish: nil) }

  static func describe(_ raw: String, turkish: Bool?) -> String {
    presentation(raw, turkish: turkish).text
  }

  private static let codeAliases: [String: String] = [
    "catalog-overlap": "overlappingCategory",
    "catalog-scope": "unauthorizedPath",
    "overlapping-selection": "overlappingSelection",
    "retainedHomeExceedsLimit": "selectionCapacity",
    "hardLinks": "unsafeSelection",
    "resourceFailure": "invalidManifest",
    "active": "activeProcess",
    "missingInfoPlist": "invalidProof",
    "invalidInfoPlist": "invalidProof",
    "invalidBundleIdentifier": "invalidProof",
    "ambiguousMetadataLayout": "invalidProof",

    "registrationUnavailable": "registrationUnknown",
    "liveCensusUnavailable": "liveUsageUnknown",
    "ios-wrapper": "iosWrapper",
    "receipt-enumeration-unavailable": "invalidReceipt",
    "receipt-install-prefix-or-files-unproven": "invalidReceipt",
    "traversalLimitExceeded": "selectionCapacity",
    "unsupportedDirectory": "unavailable",
    "unsupportedEntry": "unsupportedItem",
    "unfollowedDirectoryLink": "unsupportedItem",
    "process-unavailable": "ownershipUnknown",
    "memory-limit": "selectionCapacity",
    "time-limit": "ownershipUnknown",
    "process-changed": "changedItem",
    "cache-copy-is-not-installed-owner": "cacheCopy",
    "explicitSelectionRequired": "explicitChoice",
    "invalid-scope": "unauthorizedPath",
    "application-link-pair": "applicationLink",
    "manual-selection-capacity": "selectionCapacity",
    "application-context-capacity": "selectionCapacity",
    "application-identifier-changed": "changedItem",
    "application-metadata-changed": "changedItem",
    "application-package-changed": "changedItem",
    "application-info-changed": "changedItem",
    "application-package-protected": "protectedItem",
    "application-package-unsupported": "unsupportedItem",
    "application-info-unsafe": "missingMetadata",
    "application-info-missing": "missingMetadata",
    "application-info-invalid": "missingMetadata",
    "application-identifier-invalid": "missingMetadata",
    "application-identifier-absent": "missingMetadata",
    "application-layout": "missingMetadata",
    "application-wrapper-layout": "missingMetadata",
    "application-native-path-invalid": "invalidPath",
    "empty-plan": "emptySelection",
    "invalid-plan": "invalidPlan",
    "catalog-unavailable": "invalidManifest",
    "cancelled": "cancelledScan",
    "CancellationError": "cancelledScan",
    "open": "systemCall",
    "read": "systemCall",
    "errno": "systemCall",
    "candidateAreaUnreadable": "unavailable",
    "recordUnsafe": "invalidReceipt",
    "recordUnavailable": "invalidReceipt",
    "protected": "protectedItem",
    "installed": "associatedData",
    "historicallyVerified": "removedOwner",
    "orphanVerified": "removedOwner",
    "nameOnly": "nameMatch",
    "sharedGroup": "sharedData",
    "sharedInstalledData": "sharedData",
    "literalIdentifierOwner": "literalOwner",
    "installedElsewhere": "ownerPresent",
    "foreignOwner": "foreignOwnership",
    "mediumMatch": "nameMatch",
    "ownershipUnavailable": "ownershipUnknown",
    "unknownMetadata": "ownershipUnknown",
    "observedLiteralOwner": "literalOwner",
    "sharedInstalledOwners": "sharedData",
    "infoAbsenceChanged": "changedItem",
    "bulkRoot": "bulkSelection",
    "scanRoot": "rootSelection",
    "insidePackage": "packageInterior",
    "containsProtectedItem": "protectedItem",
    "containsApplication": "nestedApplication",
    "mountPoint": "differentVolume",
    "cloudItem": "cloudNotDownloaded",
    "unreadableFolder": "unavailable",
    "specialFile": "unsupportedItem",
    "symbolicLinkRoot": "unsupportedItem",
    "missingMetadata": "invalidProof",
    "differentVolume": "volumeUnknown",
    "needsAdministrator": "administratorRequired",
    "userPermissionDenied": "folderAccessDenied",
    "processActive": "activeProcess",
    "activityUnavailable": "processActivityUnavailable",
    "applicationRunning": "activeProcess",
    "lightenItself": "selfRemoval",
    "tooManyItems": "selectionCapacity",
    "apple-system-cache": "appleCache",
    "minimum-age": "recentFiles",
    "age-unavailable": "ageUnknown",
    "leaseBusy": "alreadyRunning",
    "leaseRequired": "invalidPlan",
    "invalidEncoding": "corruptHistory",
    "invalidPicture": "changedItem",
    "tooLarge": "selectionCapacity",
    "unsafe": "unsafeSelection",
    "missingRoot": "unavailable",
    "unsupportedFramework": "unsupportedInstalledData",
    "invalidPackage": "unsupportedItem",
    "missingArtifact": "missingMetadata",
    "unsafeArtifact": "invalidReceipt",
    "artifactTooLarge": "selectionCapacity",
    "invalidMetadata": "missingMetadata",
    "invalidArchive": "unsupportedItem",
    "missingDataShape": "invalidReceipt",
    "invalidProfile": "invalidReceipt",
    "receipt-directory-ownership-unproven": "invalidReceipt",
    "receipt-unsafe": "invalidReceipt",
    "receipt-unavailable": "invalidReceipt",
    "record-write": "invalidReceipt",
    "live-process-census-incomplete": "liveUsageUnknown",
    "spotlight-unavailable": "ownershipUnknown",
    "ownership-census-unavailable": "ownershipUnknown",
  ]

  private static func splitCopy(_ copy: String) -> (reason: String, step: String) {
    guard let boundary = copy.range(of: ". ", options: .backwards) else { return (copy, "") }
    return (String(copy[..<boundary.lowerBound]) + ".", String(copy[boundary.upperBound...]))
  }

  static func presentation(_ raw: String, turkish: Bool? = nil) -> FailurePresentation {
    let first =
      raw.split(whereSeparator: { $0 == ":" || $0 == "(" || $0 == ";" || $0 == "|" || $0.isWhitespace }).first.map(
        String.init) ?? raw
    var descriptions = [singleCodeDescription(first, turkish: turkish)]
    let components = raw.components(separatedBy: CharacterSet(charactersIn: ";|"))
    var unknown = descriptions[0].recognized ? [] : [first]
    for component in components.dropFirst() {
      let description = singleCodeDescription(component.trimmingCharacters(in: .whitespaces), turkish: turkish)
      if description.recognized && !descriptions.contains(where: { $0.text == description.text }) {
        descriptions.append(description)
      } else if !description.recognized {
        let code = component.trimmingCharacters(in: .whitespaces)
        if code.range(of: #"^[A-Za-z][A-Za-z0-9-]*(?:[:(]|$)"#, options: .regularExpression) != nil {
          unknown.append(code)
          if !descriptions.contains(where: { $0.text == description.text }) { descriptions.append(description) }
        }
      }
    }
    let copies = descriptions.map { splitCopy($0.text) }
    return FailurePresentation(
      reasons: copies.map(\.reason), nextStep: copies[0].step,
      unknownCodes: unknown)
  }

  static func presentation(_ rejection: PlanRejection, turkish: Bool? = nil) -> FailurePresentation {
    if let raw = rejection.ruleID {
      if raw.hasPrefix("errno:"), let number = Int32(raw.dropFirst("errno:".count)) {
        let copy = splitCopy(posixFailure(number, turkish: turkish))
        return FailurePresentation(reasons: [copy.reason], nextStep: copy.step, unknownCodes: [])
      }
      let machineCode =
        raw.split(whereSeparator: { $0 == ":" || $0 == "(" || $0 == ";" || $0 == "|" || $0.isWhitespace }).first.map(
          String.init) ?? raw
      if singleCodeDescription(machineCode, turkish: turkish).recognized {
        return presentation(raw, turkish: turkish)
      }
      if rejection.reason == .unavailable { return presentation(raw, turkish: turkish) }
    }
    let copy = splitCopy(SpaceText.baseRejection(rejection, turkish: turkish))
    return FailurePresentation(reasons: [copy.reason], nextStep: copy.step, unknownCodes: [])
  }

  static func candidate(_ candidate: RelatedDataCandidate, turkish: Bool? = nil) -> FailurePresentation {
    let evidence = candidate.refusalEvidence
    let primary =
      evidence.first.map { presentation($0.reason.rawValue, turkish: turkish) }
      ?? presentation(candidate.reason.rawValue, turkish: turkish)
    let others =
      evidence.dropFirst().map { presentation($0.reason.rawValue, turkish: turkish) }
      + (evidence.isEmpty ? [] : [presentation(candidate.reason.rawValue, turkish: turkish)])
    var reasons = primary.reasons
    for copy in others {
      for reason in copy.reasons where !reasons.contains(reason) { reasons.append(reason) }
    }
    let step = evidence.first.map { nextStep($0.nextStep, turkish: turkish) }
    return FailurePresentation(
      reasons: reasons, nextStep: step?.text ?? primary.nextStep,
      unknownCodes: primary.unknownCodes + others.flatMap(\.unknownCodes) + (step?.unknownCodes ?? []))
  }

  static func nextStep(_ code: String, turkish: Bool? = nil) -> (text: String, unknownCodes: [String]) {
    let copy: (String, String)
    switch code {
    case "review-observed-owner":
      copy = ("Review the observed owner in Apps.", "Gözlenen sahibi Uygulamalar’da inceleyin.")
    case "inspect-owner-metadata":
      copy = ("Inspect the possible owner in Finder.", "Olası sahibi Finder’da inceleyin.")
    case "review-other-installations":
      copy = ("Review the other installations in Apps.", "Diğer kurulumları Uygulamalar’da inceleyin.")
    case "scan-again":
      copy = ("Scan again before cleaning.", "Temizlemeden önce yeniden tarayın.")
    default:
      return (presentation(code, turkish: turkish).nextStep, [code])
    }
    return (text(copy.0, copy.1, turkish: turkish), [])
  }

  static func retainedPrefix(_ status: String, turkish: Bool? = nil) -> String {
    let copy: (String, String)
    switch status {
    case "review":
      copy = ("The app was removed; this data needs review.", "Uygulama kaldırıldı; bu veri incelenmeli.")
    case "notMoved":
      copy = ("The app was removed; this data was not moved.", "Uygulama kaldırıldı; bu veri taşınmadı.")
    case "refused":
      copy = ("The app was removed; this data was refused.", "Uygulama kaldırıldı; bu veri reddedildi.")
    default:
      copy = ("The app was removed; this data was not selected.", "Uygulama kaldırıldı; bu veri seçilmedi.")
    }
    return text(copy.0, copy.1, turkish: turkish)
  }

  static func additionalReasonLabel(_ count: Int, turkish: Bool? = nil) -> String {
    String.localizedStringWithFormat(
      text("and %lld more reasons", "ve %lld neden daha", turkish: turkish), count)
  }

  private static func singleCodeDescription(_ raw: String, turkish: Bool?) -> (text: String, recognized: Bool) {
    let first =
      raw.split(whereSeparator: { $0 == ":" || $0 == "(" || $0 == ";" || $0 == "|" || $0.isWhitespace }).first.map(
        String.init) ?? raw
    var code = first
    var seen = Set<String>()
    while let alias = codeAliases[code], seen.insert(code).inserted { code = alias }
    let copy: (String, String)
    var recognized = true
    switch code {
    case "mountedImage":
      copy = (
        "The disk image is attached. Eject it in Finder.",
        "Disk imajı bağlı. Finder’da çıkarın."
      )
    case "imageStateUnavailable":
      copy = (
        "The disk image’s attachment state could not be checked. Inspect it in Disk Utility.",
        "Disk imajının bağlılık durumu denetlenemedi. Disk İzlencesi’nde inceleyin."
      )
    case "processActivityUnavailable":
      copy = (
        "Process activity could not be checked. Check Activity Monitor.",
        "Süreç etkinliği denetlenemedi. Etkinlik Monitörü’nü kontrol edin."
      )
    case "appRunningStateUnavailable":
      copy = (
        "This app’s running state could not be verified. Quit it and try again.",
        "Bu uygulamanın çalışıp çalışmadığı doğrulanamadı. Uygulamayı kapatıp tekrar deneyin."
      )
    case "catalogDeleteDenied":
      copy = (
        "Lighten could not confirm that the related tool is idle. Check the tool in Activity Monitor.",
        "Lighten ilgili aracın boşta olduğunu doğrulayamadı. Aracı Etkinlik Monitörü’nde kontrol edin."
      )
    case "runningOrUnknown":
      copy = (
        "Lighten could not confirm that the app is closed. Check the app in Activity Monitor.",
        "Lighten uygulamanın kapalı olduğunu doğrulayamadı. Uygulamayı Etkinlik Monitörü’nde kontrol edin."
      )
    case "selfRemoval":
      copy = (
        "Lighten cannot remove itself. Choose another item.", "Lighten kendisini kaldıramaz. Başka bir öğe seçin."
      )
    case "changedItem", "changedAncestor", "changedInventory", "changed", "changedSinceScan",
      "changedDuringInspection":
      copy = (
        "The item changed after it was checked. Scan again before cleaning.",
        "Öğe denetlendikten sonra değişti. Temizlemeden önce yeniden tarayın."
      )
    case "changedTrashItem":
      copy = (
        "The item in Trash changed after removal. Inspect it in Finder before restoring it.",
        "Çöp’teki öğe kaldırıldıktan sonra değişti. Geri yüklemeden önce Finder’da inceleyin."
      )
    case "trashItemMissing":
      copy = (
        "The item is no longer in Trash. Check its location in Finder.",
        "Öğe artık Çöp’te değil. Konumunu Finder’da kontrol edin."
      )
    case "protectedItem":
      copy = (
        "A safety rule protects this item. Inspect it in Finder.",
        "Bir güvenlik kuralı bu öğeyi koruyor. Finder’da inceleyin."
      )
    case "unsupportedItem", "unsafeSelection":
      copy = (
        "This item does not meet the safety requirements. Inspect it in Finder.",
        "Bu öğe güvenlik koşullarını karşılamıyor. Finder’da inceleyin."
      )
    case "incompleteInventory":
      copy = (
        "Lighten could not check every possible app owner of this data. Inspect it in Finder.",
        "Lighten bu verinin olası tüm uygulama sahiplerini denetleyemedi. Finder’da inceleyin."
      )
    case "ownerPresent", "ambiguousOwner":
      copy = (
        "An app may still use this data. Review the app in Apps.",
        "Bir uygulama bu veriyi hâlâ kullanıyor olabilir. Uygulamayı Uygulamalar’da inceleyin."
      )
    case "invalidReceipt":
      copy = (
        "Lighten could not confirm which app created this data. Inspect it in Finder.",
        "Lighten bu veriyi hangi uygulamanın oluşturduğunu doğrulayamadı. Finder’da inceleyin."
      )
    case "invalidProof", "missingMetadata":
      copy = (
        "Lighten could not confirm this item’s current details. Inspect it in Finder.",
        "Lighten bu öğenin güncel bilgilerini doğrulayamadı. Finder’da inceleyin."
      )
    case "unauthorizedPath":
      copy = (
        "This item is outside the locations this action can change. Choose an item from the listed folder.",
        "Bu öğe, bu işlemin değiştirebileceği konumların dışında. Listelenen klasörden bir öğe seçin."
      )
    case "incompatibleSnapshot", "unknownSelection":
      copy = (
        "The scan no longer matches this selection. Scan this folder again.",
        "Tarama artık bu seçimle eşleşmiyor. Bu klasörü yeniden tarayın."
      )
    case "emptySelection":
      copy = ("No eligible item is selected. Select an eligible item.", "Uygun bir öğe seçilmedi. Uygun bir öğe seçin.")
    case "invalidPlan", "planAlreadyUsed":
      copy = (
        "This review no longer matches the requested action. Review your selection again.",
        "Bu inceleme artık istenen işlemle eşleşmiyor. Seçiminizi yeniden inceleyin."
      )
    case "corruptHistory":
      copy = (
        "Lighten could not read a reliable action record. Inspect the item in Finder.",
        "Lighten güvenilir bir işlem kaydı okuyamadı. Öğeyi Finder’da inceleyin."
      )
    case "alreadyRunning":
      copy = (
        "Another action is running. Wait for it to finish.", "Başka bir işlem çalışıyor. Tamamlanmasını bekleyin."
      )
    case "nameOccupied":
      copy = (
        "Another item now uses the original name. Rename that item in Finder before restoring.",
        "Başka bir öğe eski adı kullanıyor. Geri yüklemeden önce o öğeyi Finder’da yeniden adlandırın."
      )
    case "unsafeParent", "noAppliedRecord", "unknownItem":
      copy = (
        "The original location could not be verified. Inspect the item in Trash with Finder.",
        "Eski konum doğrulanamadı. Çöp’teki öğeyi Finder’da inceleyin."
      )
    case "metadataDifferent", "dataDifferent":
      copy = (
        "These files no longer match. Scan the copies again.",
        "Bu dosyalar artık eşleşmiyor. Kopyaları yeniden tarayın."
      )
    case "invalidSelection", "metadataUnknown":
      copy = (
        "Lighten could not confirm that these files are identical. Inspect the files in Finder.",
        "Lighten bu dosyaların aynı olduğunu doğrulayamadı. Dosyaları Finder’da inceleyin."
      )
    case "notDirectory", "rootNotDirectory":
      copy = (
        "The chosen item is not a folder. Choose a folder to scan.",
        "Seçilen öğe bir klasör değil. Taramak için bir klasör seçin."
      )
    case "unavailable", "childUnavailable", "invalidPath":
      copy = (
        "The location is missing or unreadable. Inspect it in Finder.",
        "Konum yok veya okunamıyor. Finder’da inceleyin."
      )
    case "systemCall", "renameFailed":
      copy = (
        "macOS refused the operation. Inspect the item in Finder.",
        "macOS işlemi reddetti. Öğeyi Finder’da inceleyin."
      )
    case "invalidManifest":
      copy = (
        "The Clean catalog could not be verified. Reinstall Lighten.",
        "Clean kataloğu doğrulanamadı. Lighten’ı yeniden kurun."
      )
    case "unsupportedInstalledData":
      copy = (
        "This app data is not eligible for this action. Review it in Applications.",
        "Bu uygulama verisi bu işlem için uygun değil. Uygulamalar’da inceleyin."
      )
    case "skipped", "notAttempted":
      copy = (
        "This item was skipped before removal. Review this item before trying again.",
        "Bu öğe kaldırılmadan önce atlandı. Yeniden denemeden önce bu öğeyi inceleyin."
      )
    case "registrationUnknown":
      copy = (
        "Other app installations could not be fully checked, so shared ownership is unverified. Inspect the possible owners in Finder.",
        "Diğer uygulama kurulumları tam denetlenemediği için ortak sahiplik doğrulanamadı. Olası sahipleri Finder’da inceleyin."
      )
    case "liveUsageUnknown":
      copy = (
        "Open files could not be fully checked, so another app may be using this data. Close related apps and review again.",
        "Açık dosyalar tam denetlenemediği için başka bir uygulama bu veriyi kullanıyor olabilir. İlgili uygulamaları kapatıp yeniden inceleyin."
      )
    case "iosWrapper":
      copy = (
        "This iPhone or iPad application cannot be removed here. Use Show in Finder.",
        "Bu iPhone veya iPad uygulaması buradan kaldırılamaz. Finder’da Göster'i kullanın."
      )
    case "cacheCopy":
      copy = (
        "This app is a cache copy, so it cannot establish which installed app owns the data. Review the installed app in Apps.",
        "Bu uygulama bir önbellek kopyası; verinin hangi kurulu uygulamaya ait olduğunu kanıtlayamaz. Kurulu uygulamayı Uygulamalar’da inceleyin."
      )
    case "explicitChoice":
      copy = (
        "This item was not explicitly selected in the current review. Review it and select it yourself.",
        "Bu öğe güncel incelemede açıkça seçilmedi. İnceleyip kendiniz seçin."
      )
    case "applicationLink":
      copy = (
        "The app’s shortcut and physical package no longer match this review. Review the app again.",
        "Uygulamanın bağlantısı ve asıl paketi artık bu incelemeyle eşleşmiyor. Uygulamayı yeniden inceleyin."
      )
    case "selectionCapacity":
      copy = (
        "This selection is too large to verify at once. Review fewer items together.",
        "Bu seçim tek seferde doğrulanamayacak kadar büyük. Daha az öğeyi birlikte inceleyin."
      )
    case "cancelledScan":
      copy = (
        "The review was cancelled before verification finished. Scan again before cleaning.",
        "İnceleme doğrulama tamamlanmadan iptal edildi. Temizlemeden önce yeniden tarayın."
      )
    case "associatedData":
      copy = (
        "This folder is associated with the app. Review it separately before moving it to Trash.",
        "Bu klasör uygulamayla ilişkilidir. Çöp’e taşımadan önce ayrıca inceleyin."
      )
    case "removedOwner":
      copy = (
        "The app is no longer installed. Review the remaining data before moving it to Trash.",
        "Uygulama artık kurulu değil. Çöp’e taşımadan önce kalan veriyi inceleyin."
      )
    case "nameMatch":
      copy = (
        "Only the name resembles the app; ownership is unproven. Select it only if you recognize it.",
        "Yalnızca adı uygulamayı andırıyor; sahiplik kanıtlanmadı. Yalnızca tanıyorsanız seçin."
      )
    case "sharedData":
      copy = (
        "Another app may still use this data. Review the other installations in Apps.",
        "Başka bir uygulama bu veriyi hâlâ kullanıyor olabilir. Diğer kurulumları Uygulamalar’da inceleyin."
      )
    case "literalOwner":
      copy = (
        "Another observed app declares this data’s exact identifier. Review that app in Apps.",
        "Gözlenen başka bir uygulama bu verinin tam kimliğini bildiriyor. O uygulamayı Uygulamalar’da inceleyin."
      )
    case "administratorRequired":
      copy = (
        "Moving this item requires administrator permission. Use Show in Finder to remove it there.",
        "Bu öğeyi taşımak için yönetici yetkisi gerekiyor. Oradan kaldırmak için Finder’da Göster’i kullanın."
      )
    case "foreignOwnership":
      copy = (
        "This item belongs to another account. Check its owner and permissions in Finder.",
        "Bu öğe başka bir hesaba ait. Sahibini ve izinlerini Finder’da kontrol edin."
      )
    case "ownershipUnknown":
      copy = (
        "The application ownership check could not be completed. Inspect the possible owners in Finder.",
        "Uygulama sahipliği denetimi tamamlanamadı. Olası sahipleri Finder’da inceleyin."
      )
    case "bulkSelection":
      copy = (
        "A whole standard folder cannot be moved. Select items inside it.",
        "Standart bir klasörün tamamı taşınamaz. İçindeki öğeleri seçin."
      )
    case "rootSelection":
      copy = (
        "The scanned folder itself cannot be removed. Choose items inside it.",
        "Taranan klasörün kendisi kaldırılamaz. İçindeki öğeleri seçin."
      )
    case "packageInterior":
      copy = (
        "This item is inside an app or package. Select the whole app or package instead.",
        "Bu öğe bir uygulama veya paketin içinde. Uygulamanın veya paketin tamamını seçin."
      )
    case "nestedApplication":
      copy = (
        "This folder contains an app. Select the app itself.",
        "Bu klasörde bir uygulama var. Uygulamanın kendisini seçin."
      )
    case "cloudNotDownloaded":
      copy = (
        "This item includes cloud files that are not downloaded. Download them in Finder first.",
        "Bu öğede indirilmemiş bulut dosyaları var. Önce Finder’da indirin."
      )
    case "volumeUnknown":
      copy = (
        "The item’s volume could not be verified. Inspect its location in Finder.",
        "Öğenin diski doğrulanamadı. Konumunu Finder’da inceleyin."
      )
    case "folderAccessDenied":
      copy = (
        "Your account cannot move this item from its folder. Check the folder’s permissions in Finder.",
        "Hesabınız bu öğeyi klasöründen taşıyamıyor. Klasörün izinlerini Finder’da kontrol edin."
      )
    case "activeProcess":
      copy = (
        "A related process is running. Quit it before cleaning.",
        "İlgili bir süreç çalışıyor. Temizlemeden önce kapatın."
      )
    case "overlappingCategory":
      copy = (
        "Another cleanup category handles this item. Review it in that category.",
        "Bu öğeyi başka bir temizlik kategorisi ele alıyor. O kategoride inceleyin."
      )
    case "overlappingSelection":
      copy = (
        "The selection includes a folder and an item inside it. Select either the folder or its contents.",
        "Seçim bir klasörü ve içindeki bir öğeyi kapsıyor. Klasörü veya içeriğini seçin."
      )
    case "appleCache":
      copy = (
        "Apple system cache. Inspect it in Finder.",
        "Apple sistem önbelleği. Finder’da inceleyin."
      )
    case "recentFiles":
      copy = (
        "This item includes recently modified files. Keep it until the category’s minimum age is reached.",
        "Bu öğe yakın zamanda değiştirilmiş dosyalar içeriyor. Kategorinin asgari yaşına ulaşılana kadar saklayın."
      )
    case "ageUnknown":
      copy = (
        "The age of this item could not be verified. Inspect its dates in Finder.",
        "Bu öğenin yaşı doğrulanamadı. Tarihlerini Finder’da inceleyin."
      )
    default:
      recognized = false
      copy = (
        "Lighten could not determine why this action failed. Inspect the item in Finder.",
        "Lighten bu işlemin neden başarısız olduğunu belirleyemedi. Öğeyi Finder’da inceleyin."
      )
    }
    let message = text(copy.0, copy.1, turkish: turkish)
    return (message, recognized)
  }

  static func executionIsUnverified(_ item: ItemActionResult) -> Bool {
    guard item.outcome != .applied else { return false }
    switch item.mutationStage {
    case .notStarted, .sourceRetained: return false
    case .trashCallUnverified, .trashMoveObserved, .permanentMutation: return true
    case nil: return item.outcome == .uncertain || item.outcome == .failed
    }
  }

  static func executionPresentation(_ item: ItemActionResult, turkish: Bool? = nil) -> FailurePresentation {
    if !executionIsUnverified(item), let detail = item.detail { return presentation(detail, turkish: turkish) }
    let copy = splitCopy(execution(item, turkish: turkish))
    return FailurePresentation(reasons: [copy.reason], nextStep: copy.step, unknownCodes: [])
  }

  static func execution(_ item: ItemActionResult, turkish: Bool? = nil) -> String {
    if !executionIsUnverified(item) {
      return item.detail.map { describe($0, turkish: turkish) }
        ?? text("This item was not removed.", "Bu öğe kaldırılmadı.", turkish: turkish)
    }
    switch item.mutationStage {
    case .trashCallUnverified, .trashMoveObserved:
      return text(
        "Removal could not be verified. The item may be in Trash; check History or Finder.",
        "Kaldırma doğrulanamadı. Öğe Çöp’te olabilir; Geçmiş’ten veya Finder’dan kontrol edin.", turkish: turkish)
    case .permanentMutation:
      return text(
        "A permanent change occurred, but completion could not be verified. Check History; this change cannot be undone.",
        "Kalıcı bir değişiklik oldu, ancak tamamlandığı doğrulanamadı. Geçmiş’i kontrol edin; bu değişiklik geri alınamaz.",
        turkish: turkish)
    case nil:
      return text(
        "Removal could not be verified. Check the item in History and Finder.",
        "Kaldırma doğrulanamadı. Öğeyi Geçmiş’ten ve Finder’dan kontrol edin.", turkish: turkish)
    case .notStarted, .sourceRetained:
      return text("This item was not removed.", "Bu öğe kaldırılmadı.", turkish: turkish)
    }
  }

  static func posixDetails(_ number: Int32) -> String {
    "\(String(cString: strerror(number))) (\(number))"
  }

  static func posixFailure(_ number: Int32, turkish: Bool? = nil) -> String {
    let copy: (String, String) =
      switch number {
      case EACCES, EPERM:
        (
          "macOS denied access to this item. Check its access permissions in Finder.",
          "macOS bu öğeye erişimi reddetti. Erişim izinlerini Finder’da kontrol edin."
        )
      case ENOENT:
        (
          "The item or its containing folder could not be found. Check its location in Finder.",
          "Öğe veya onu içeren klasör bulunamadı. Konumunu Finder’da kontrol edin."
        )
      case EROFS:
        (
          "This disk is read-only. Choose an item on a writable disk.",
          "Bu disk salt okunur. Yazılabilir bir diskteki öğeyi seçin."
        )
      case ENOSPC:
        (
          "The disk has no space for this operation. Review disk space in System Settings.",
          "Diskte bu işlem için yer yok. Disk alanını Sistem Ayarları’nda inceleyin."
        )
      default:
        (
          "macOS reported a file operation error. Inspect the item in Finder.",
          "macOS bir dosya işlemi hatası bildirdi. Öğeyi Finder’da inceleyin."
        )
      }
    return text(copy.0, copy.1, turkish: turkish)
  }

  static func text(_ english: String, _ translation: String, turkish: Bool?) -> String {
    if let turkish { return turkish ? translation : english }
    return String(localized: String.LocalizationValue(english))
  }
}
