import Darwin
import Foundation
import LightenKit

/// Machine-readable failures are presented as a reason and a next step.
enum FailureText {
  static func describe(_ error: any Error, turkish: Bool? = nil) -> String {
    if let rejection = error as? PlanRejection { return SpaceText.rejection(rejection, turkish: turkish) }
    if let refusals = error as? PlanRejections {
      return refusals.rejections.map { SpaceText.rejection($0, turkish: turkish) }.joined(separator: "\n")
    }
    if case FileSystemFailure.systemCall(let operation, let number) = error {
      return posixFailure(number, turkish: turkish) + " " + operation
    }
    if case JournalFailure.systemCall(let operation, let number) = error {
      return posixFailure(number, turkish: turkish) + " " + operation
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
    if case CatalogFailure.resourceFailure(let stage, let code) = error {
      return text(
        "Clean could not load its catalog. Reinstall Lighten.",
        "Temizlik kataloğu yüklenemedi. Lighten’ı yeniden kurun.", turkish: turkish)
        + " \(stage): \(String(cString: strerror(code))) (\(code))"
    }
    return describe(String(describing: error), turkish: turkish)
  }

  static func describe(_ raw: String) -> String { describe(raw, turkish: nil) }

  static func describe(_ raw: String, turkish: Bool?) -> String {
    if raw == "processActivityUnavailable" || raw.hasPrefix("processActivityUnavailable:") {
      let details =
        raw.hasPrefix("processActivityUnavailable:")
        ? String(raw.dropFirst("processActivityUnavailable:".count)) : ""
      return text(
        "Process activity could not be checked. Check Activity Monitor.",
        "Süreç etkinliği denetlenemedi. Etkinlik Monitörü’nü kontrol edin.", turkish: turkish)
        + (details.isEmpty ? "" : " " + details)
    }
    if raw.hasPrefix("processActive:") {
      let names = String(raw.dropFirst("processActive:".count))
      return text(
        "A related process is running. Quit it before cleaning.",
        "İlgili bir süreç çalışıyor. Temizlemeden önce kapatın.", turkish: turkish) + " " + names
    }
    let code = raw.split(separator: "(").first.map(String.init) ?? raw
    if ["systemCall", "renameFailed", "unavailable", "open", "read"].contains(code),
      let start = raw.firstIndex(of: "("), raw.hasSuffix(")")
    {
      let arguments = raw[raw.index(after: start)..<raw.index(before: raw.endIndex)]
      let last = arguments.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) }
      if let last, let number = Int32(last) {
        return posixFailure(number, turkish: turkish) + " " + raw
      }
    }
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
    default:
      recognized = false
      copy = (
        "Lighten could not determine why this action failed. Inspect the item in Finder.",
        "Lighten bu işlemin neden başarısız olduğunu belirleyemedi. Öğeyi Finder’da inceleyin."
      )
    }
    let message = text(copy.0, copy.1, turkish: turkish)
    return recognized ? message : message + " " + raw
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
    return text(copy.0, copy.1, turkish: turkish) + " " + posixDetails(number)
  }

  static func text(_ english: String, _ translation: String, turkish: Bool?) -> String {
    if let turkish { return turkish ? translation : english }
    return String(localized: String.LocalizationValue(english))
  }
}
