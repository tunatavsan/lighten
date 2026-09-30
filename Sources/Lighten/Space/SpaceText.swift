import Foundation
import LightenKit

/// Every refusal and every incomplete size says why, in the person's language.
enum SpaceText {
  static func name(_ item: SpaceItem) -> String {
    switch item.kind {
    case .smallFiles: "\(item.summarizedFiles) \(String(localized: "smaller files"))"
    default: item.name
    }
  }

  static func symbol(_ item: SpaceItem) -> String {
    switch item.kind {
    case .directory: "folder"
    case .package: "shippingbox"
    case .file: "doc"
    case .symlink: "link"
    case .other: "questionmark.square"
    case .smallFiles: "doc.on.doc"
    case .systemVolume: "internaldrive"
    }
  }

  /// Why the value is incomplete or special; nil for an exact, ordinary item.
  static func state(_ item: SpaceItem) -> String? {
    switch item.state {
    case .complete: return nil
    case .measuring: return String(localized: "Measuring. The size shown is a known minimum.")
    case .protectedMetadataOnly(let ruleID):
      let reason = NeverRule.all.first { $0.id == ruleID }?.reason ?? ""
      return
        "\(String(localized: "Protected by Lighten's safety rules. Measured from metadata only; it cannot be removed here.")) \(reason)"
    case .partial(let reason):
      switch reason {
      case .unreadable:
        return String(
          localized:
            "Lighten cannot read this folder. Full Disk Access in Settings or the folder's permissions decide this.")
      case .mountBoundary: return String(localized: "Another volume is mounted here and is not included.")
      case .cloudNotMeasured: return String(localized: "Cloud files are not downloaded or measured.")
      case .protectedNotTraversed: return String(localized: "Private keys and keychains are never opened.")
      case .entryError: return String(localized: "Some items could not be read, so the size is a minimum.")
      case .changedDuringScan: return String(localized: "This folder changed during the scan. Scan again.")
      case .cancelled: return String(localized: "The scan was cancelled, so the size is a minimum.")
      case .descendant:
        return String(localized: "Contains areas that could not be measured, so the size is a minimum.")
      }
    }
  }

  /// Why an item cannot enter the basket, or nil when it can.
  static func unselectable(_ item: SpaceItem) -> String? {
    if item.canSelect { return nil }
    if item.parentID == nil {
      return String(localized: "The scanned folder itself cannot be removed. Open it and choose items inside.")
    }
    switch item.kind {
    case .symlink: return String(localized: "A symbolic link moves only together with its folder.")
    case .smallFiles: return String(localized: "Small files are summarized. Select their folder instead.")
    case .systemVolume: return String(localized: "The macOS system volume is sealed and read-only.")
    case .other: return String(localized: "Special files such as sockets and devices are not removed.")
    default: return state(item)
    }
  }

  static func rejection(_ rejection: PlanRejection) -> String { Self.rejection(rejection, turkish: nil) }

  static func rejection(_ rejection: PlanRejection, turkish: Bool?) -> String {
    let catalogCopy: (String, String)? =
      switch rejection.ruleID {
      case "apple-system-cache":
        ("Apple system cache. Inspect it in Finder.", "Apple sistem önbelleği. Finder’da inceleyin.")
      case "minimum-age":
        (
          "This item includes recently modified files. Keep it until the category’s minimum age is reached.",
          "Bu öğe yakın zamanda değiştirilmiş dosyalar içeriyor. Kategorinin asgari yaşına ulaşılana kadar saklayın."
        )
      case "age-unavailable":
        (
          "The age of this item could not be verified. Inspect it in Finder, then scan again.",
          "Bu öğenin yaşı doğrulanamadı. Finder’da inceleyip yeniden tarayın."
        )
      default: nil
      }
    if let catalogCopy {
      return FailureText.text(catalogCopy.0, catalogCopy.1, turkish: turkish) + " — " + rejection.path
    }
    let copy: (String, String) =
      switch rejection.reason {
      case .bulkRoot:
        (
          "A whole standard folder cannot be moved. Choose items inside it.",
          "Standart bir klasörün tamamı taşınamaz. İçindeki öğeleri seçin."
        )
      case .scanRoot:
        (
          "The scanned folder itself cannot be removed. Choose items inside it.",
          "Taranan klasörün kendisi kaldırılamaz. İçindeki öğeleri seçin."
        )
      case .insidePackage:
        (
          "This item is inside an app or package. Select the whole app or package instead.",
          "Bu öğe bir uygulama veya paketin içinde. Uygulamanın veya paketin tamamını seçin."
        )
      case .protectedItem:
        (
          "A safety rule protects this item. Inspect it in Finder.",
          "Bir güvenlik kuralı bu öğeyi koruyor. Finder’da inceleyin."
        )
      case .containsProtectedItem:
        (
          "A safety rule protects an item inside this folder. Inspect that item in Finder.",
          "Bir güvenlik kuralı bu klasördeki bir öğeyi koruyor. O öğeyi Finder’da inceleyin."
        )
      case .containsApplication:
        (
          "This folder contains an app. Select the app itself or choose other items.",
          "Bu klasörde bir uygulama var. Uygulamanın kendisini veya başka öğeleri seçin."
        )
      case .mountPoint:
        (
          "Another volume is mounted inside this folder. Choose items on the same volume.",
          "Bu klasörün içinde başka bir disk bağlı. Aynı diskteki öğeleri seçin."
        )
      case .cloudItem:
        (
          "This item includes cloud files that are not downloaded. Download them in Finder first.",
          "Bu öğede indirilmemiş bulut dosyaları var. Önce Finder’da indirin."
        )
      case .unreadableFolder:
        (
          "Lighten cannot read this folder. Check Full Disk Access and folder permissions.",
          "Lighten bu klasörü okuyamıyor. Tam Disk Erişimi’ni ve klasör izinlerini kontrol edin."
        )
      case .specialFile:
        (
          "This folder contains a special file such as a socket or device. Choose ordinary files or folders.",
          "Bu klasörde soket veya aygıt gibi özel bir dosya var. Normal dosya veya klasörleri seçin."
        )
      case .symbolicLinkRoot:
        (
          "This symbolic link cannot be moved by this action. Select its containing folder.",
          "Bu sembolik bağlantı bu işlemle taşınamaz. İçinde bulunduğu klasörü seçin."
        )
      case .missingMetadata:
        (
          "File metadata is incomplete, so undo cannot be guaranteed. Scan again before cleaning.",
          "Dosya metaverisi eksik; geri alma garantilenemiyor. Temizlemeden önce yeniden tarayın."
        )
      case .changedSinceScan:
        (
          "The item changed after the scan. Scan again before cleaning.",
          "Öğe taramadan sonra değişti. Temizlemeden önce yeniden tarayın."
        )
      case .differentVolume:
        (
          "The item’s volume could not be verified. Inspect its location in Finder.",
          "Öğenin diski doğrulanamadı. Konumunu Finder’da inceleyin."
        )
      case .needsAdministrator:
        (
          "This item belongs to another account or requires elevated access. Inspect its permissions in Finder.",
          "Bu öğe başka bir hesaba ait veya yükseltilmiş erişim gerektiriyor. İzinlerini Finder’da inceleyin."
        )
      case .userPermissionDenied:
        (
          "Your account cannot move this item from its folder. Check the folder’s permissions in Finder.",
          "Hesabınız bu öğeyi klasöründen taşıyamıyor. Klasörün izinlerini Finder’da kontrol edin."
        )
      case .applicationRunning:
        ("The app is running. Quit it before cleaning.", "Uygulama çalışıyor. Temizlemeden önce kapatın.")
      case .lightenItself:
        ("Lighten cannot remove itself. Choose another item.", "Lighten kendisini kaldıramaz. Başka bir öğe seçin.")
      case .tooManyItems:
        (
          "This folder contains too many items to verify at once. Choose a smaller subfolder.",
          "Bu klasörde bir kerede doğrulanamayacak kadar çok öğe var. Daha küçük bir alt klasör seçin."
        )
      case .unavailable:
        (
          "This item is no longer available. Inspect its location in Finder.",
          "Bu öğe artık mevcut değil. Konumunu Finder’da inceleyin."
        )
      }
    let text = FailureText.text(copy.0, copy.1, turkish: turkish)
    let rule = rejection.ruleID.flatMap { id in NeverRule.all.first { $0.id == id }?.reason }
    return "\(text)\(rule.map { " \($0)" } ?? "") — \(rejection.path)"
  }
}
