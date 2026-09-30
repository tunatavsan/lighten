import Darwin
import Foundation
import LightenKit

/// Machine-readable failures are presented as a reason and a next step.
enum FailureText {
  static func describe(_ error: any Error) -> String {
    if case CatalogFailure.resourceFailure(let stage, let code) = error {
      return String(localized: "Clean could not load its catalog. Reinstall Lighten.")
        + " \(stage): \(String(cString: strerror(code))) (\(code))"
    }
    return describe(String(describing: error))
  }

  static func describe(_ raw: String) -> String { describe(raw, turkish: nil) }

  static func describe(_ raw: String, turkish: Bool?) -> String {
    if raw.hasPrefix("processActive:") {
      let names = String(raw.dropFirst("processActive:".count))
      return text(
        "A related process is running. Quit it, then scan again.",
        "İlgili bir süreç çalışıyor. Kapatıp yeniden tarayın.", turkish: turkish) + " " + names
    }
    let code = raw.split(separator: "(").first.map(String.init) ?? raw
    let copy: (String, String) =
      switch code {
      case "mountedImage":
        (
          "The disk image is attached. Eject it in Finder, then try again.",
          "Disk imajı bağlı. Finder’da çıkarıp yeniden deneyin."
        )
      case "imageStateUnavailable":
        (
          "The disk image’s attachment state could not be checked. Try again before moving it.",
          "Disk imajının bağlılık durumu denetlenemedi. Taşımadan önce yeniden deneyin."
        )
      case "processActivityUnavailable":
        (
          "Process activity could not be checked. Scan again before cleaning.",
          "Süreç etkinliği denetlenemedi. Temizlemeden önce yeniden tarayın."
        )
      case "catalogDeleteDenied":
        (
          "A related process is running or could not be checked. Quit the related tool, then scan again.",
          "İlgili bir süreç çalışıyor veya denetlenemedi. İlgili aracı kapatıp yeniden tarayın."
        )
      case "runningOrUnknown":
        (
          "The app is running or its state could not be checked. Quit the app, then scan again.",
          "Uygulama çalışıyor veya durumu denetlenemedi. Uygulamayı kapatıp yeniden tarayın."
        )
      case "selfRemoval":
        ("Lighten cannot remove itself. Choose another item.", "Lighten kendisini kaldıramaz. Başka bir öğe seçin.")
      case "changedItem", "changedAncestor", "changedInventory", "changed", "changedSinceScan",
        "changedDuringInspection":
        (
          "The item changed after it was checked. Scan again before cleaning.",
          "Öğe denetlendikten sonra değişti. Temizlemeden önce yeniden tarayın."
        )
      case "changedTrashItem":
        (
          "The item in Trash changed after removal. Inspect it in Finder before restoring it.",
          "Çöp’teki öğe kaldırıldıktan sonra değişti. Geri yüklemeden önce Finder’da inceleyin."
        )
      case "trashItemMissing":
        (
          "The item is no longer in Trash. Check its location in Finder.",
          "Öğe artık Çöp’te değil. Konumunu Finder’da kontrol edin."
        )
      case "protectedItem":
        (
          "A safety rule protects this item. Inspect it in Finder.",
          "Bir güvenlik kuralı bu öğeyi koruyor. Finder’da inceleyin."
        )
      case "unsupportedItem", "unsafeSelection":
        (
          "This item does not meet the safety requirements. Inspect it in Finder.",
          "Bu öğe güvenlik koşullarını karşılamıyor. Finder’da inceleyin."
        )
      case "incompleteInventory":
        (
          "The application inventory is incomplete. Scan Applications again before cleaning this data.",
          "Uygulama envanteri eksik. Bu veriyi temizlemeden önce Uygulamalar’ı yeniden tarayın."
        )
      case "ownerPresent", "ambiguousOwner":
        (
          "An installed app may own this data. Review the app in Applications.",
          "Kurulu bir uygulama bu verinin sahibi olabilir. Uygulamayı Uygulamalar’da inceleyin."
        )
      case "invalidReceipt", "invalidProof", "unauthorizedPath", "invalidPlan", "planAlreadyUsed",
        "incompatibleSnapshot", "unknownSelection", "emptySelection":
        (
          "The prepared action is no longer valid. Scan again before cleaning.",
          "Hazırlanan işlem artık geçerli değil. Temizlemeden önce yeniden tarayın."
        )
      case "corruptHistory":
        (
          "The action history could not be verified. Review History before another action.",
          "İşlem geçmişi doğrulanamadı. Yeni bir işlemden önce Geçmiş’i inceleyin."
        )
      case "alreadyRunning":
        ("Another action is running. Wait for it to finish.", "Başka bir işlem çalışıyor. Tamamlanmasını bekleyin.")
      case "nameOccupied":
        (
          "Another item now uses the original name. Rename that item in Finder before restoring.",
          "Başka bir öğe eski adı kullanıyor. Geri yüklemeden önce o öğeyi Finder’da yeniden adlandırın."
        )
      case "unsafeParent", "noAppliedRecord", "unknownItem":
        (
          "The original location could not be verified. Inspect the item in Trash with Finder.",
          "Eski konum doğrulanamadı. Çöp’teki öğeyi Finder’da inceleyin."
        )
      case "invalidSelection", "metadataUnknown", "metadataDifferent", "dataDifferent":
        (
          "The copies could not be verified as identical. Scan the copies again.",
          "Kopyaların aynı olduğu doğrulanamadı. Kopyaları yeniden tarayın."
        )
      case "notDirectory", "rootNotDirectory":
        (
          "The chosen item is not a folder. Choose a folder to scan.",
          "Seçilen öğe bir klasör değil. Taramak için bir klasör seçin."
        )
      case "unavailable", "childUnavailable", "invalidPath":
        (
          "The location is missing or unreadable. Inspect it in Finder.",
          "Konum yok veya okunamıyor. Finder’da inceleyin."
        )
      case "systemCall", "renameFailed":
        (
          "macOS refused the operation. Check the item’s permissions in Finder.",
          "macOS işlemi reddetti. Öğenin izinlerini Finder’da kontrol edin."
        )
      case "invalidManifest":
        (
          "The Clean catalog could not be verified. Reinstall Lighten.",
          "Clean kataloğu doğrulanamadı. Lighten’ı yeniden kurun."
        )
      case "unsupportedInstalledData":
        (
          "This app data is not eligible for this action. Review it in Applications.",
          "Bu uygulama verisi bu işlem için uygun değil. Uygulamalar’da inceleyin."
        )
      default:
        (
          "The action could not be completed. Inspect the item in Finder.",
          "İşlem tamamlanamadı. Öğeyi Finder’da inceleyin."
        )
      }
    return text(copy.0, copy.1, turkish: turkish)
  }

  static func text(_ english: String, _ translation: String, turkish: Bool?) -> String {
    if let turkish { return turkish ? translation : english }
    return String(localized: String.LocalizationValue(english))
  }
}
