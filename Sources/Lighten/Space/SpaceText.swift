import Foundation
import LightenKit

/// Every refusal and every incomplete size says why, in the person's language.
enum SpaceText {
  static func trashMissing(turkish: Bool? = nil) -> String {
    FailureText.text(
      "This item is no longer at its recorded Trash location. Check Trash in Finder.",
      "Bu öğe artık kayıtlı Çöp konumunda değil. Finder’da Çöp’ü kontrol edin.", turkish: turkish)
  }

  static func warning(_ warning: ProtectiveWarning, paths: [String] = [], turkish: Bool? = nil) -> String {
    let copy: (String, String) =
      switch warning {
      case .valuableData:
        (
          "This item may contain a virtual machine, backup, or build archive; check what you need before moving it to Trash.",
          "Bu öğe bir sanal makine, yedek veya derleme arşivi içerebilir; Çöp’e taşımadan önce ihtiyacınız olanları kontrol edin."
        )
      case .secrets:
        (
          "This item contains names associated with keys or secrets; check before moving it to Trash.",
          "Bu öğede anahtar veya gizli bilgilerle ilişkili dosya adları var; Çöp’e taşımadan önce kontrol edin."
        )
      case .personalLibrary:
        (
          "This library may contain your projects, recordings or edits, and another copy is not known. Check what you need before moving it to Trash.",
          "Bu kütüphane projelerinizi, kayıtlarınızı veya düzenlemelerinizi içerebilir; başka bir kopyası bilinmiyor. Çöp’e taşımadan önce ihtiyacınız olanları kontrol edin."
        )
      case .copyUnknown:
        (
          "This item contains mostly personal files and another copy is not known; check before moving it to Trash.",
          "Bu öğe çoğunlukla kişisel dosyalar içeriyor ve başka bir kopyası bilinmiyor; Çöp’e taşımadan önce kontrol edin."
        )
      }
    let explanation = FailureText.text(copy.0, copy.1, turkish: turkish)
    guard !paths.isEmpty else { return explanation }
    return explanation + "\n" + paths.prefix(3).joined(separator: "\n")
  }

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
    case .measuring: return String(localized: "Measuring. The size shown is at least the space found so far.")
    case .protectedMetadataOnly:
      return String(
        localized:
          "This item was not opened during measurement. You can choose it yourself after reviewing its contents.")
    case .partial(let reason):
      switch reason {
      case .unreadable:
        return String(
          localized:
            "Lighten cannot read this folder. Check access to this folder in Finder.")
      case .mountBoundary:
        return String(
          localized: "Another volume is mounted here and is not included. Choose items on the current volume.")
      case .cloudNotMeasured:
        return String(localized: "Cloud files are not downloaded or measured. Download them in Finder first.")
      case .protectedNotTraversed:
        return String(localized: "Lighten never opens private keys or keychains. Inspect their location in Finder.")
      case .entryError:
        return String(
          localized: "Some items could not be read, so the size is a minimum. Inspect the folder in Finder.")
      case .changedDuringScan: return String(localized: "This folder changed during the scan. Scan again.")
      case .cancelled:
        return String(localized: "The scan was cancelled, so the size is a minimum. Scan the folder again.")
      case .descendant:
        return String(
          localized: "Some areas could not be measured, so the size is a minimum. Inspect the folder in Finder.")
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
    case .symlink: return String(localized: "A symbolic link moves only with its folder. Select its containing folder.")
    case .smallFiles: return String(localized: "Small files are summarized. Select their folder instead.")
    case .systemVolume:
      return String(localized: "The macOS system volume is read-only. Choose an item on your data volume.")
    case .other:
      return String(localized: "Sockets and devices cannot be removed here. Choose an ordinary file or folder.")
    default:
      return state(item)
        ?? String(localized: "Lighten could not confirm this item can be moved. Inspect it in Finder.")
    }
  }

  static func rejection(_ rejection: PlanRejection) -> String { Self.rejection(rejection, turkish: nil) }

  static func rejection(_ rejection: PlanRejection, turkish: Bool?) -> String {
    FailureText.presentation(rejection, turkish: turkish).text + " — " + rejection.path
  }

  static func baseRejection(_ rejection: PlanRejection, turkish: Bool?) -> String {
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
          "This folder contains an app. Select the app itself.",
          "Bu klasörde bir uygulama var. Uygulamanın kendisini seçin."
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
          "Lighten cannot read this folder. Check access to this folder in Finder.",
          "Lighten bu klasörü okuyamıyor. Bu klasöre erişimi Finder’da kontrol edin."
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
          "Lighten could not confirm this item’s current details. Inspect it in Finder.",
          "Lighten bu öğenin güncel bilgilerini doğrulayamadı. Finder’da inceleyin."
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
          "Moving this item requires administrator permission. Use Show in Finder to remove it there.",
          "Bu öğeyi taşımak için yönetici yetkisi gerekiyor. Oradan kaldırmak için Finder’da Göster’i kullanın."
        )
      case .userPermissionDenied:
        (
          "Your account cannot move this item from its folder. Check the folder’s permissions in Finder.",
          "Hesabınız bu öğeyi klasöründen taşıyamıyor. Klasörün izinlerini Finder’da kontrol edin."
        )
      case .processActive:
        (
          "A related process is using this item. Quit it before cleaning.",
          "İlişkili bir işlem bu öğeyi kullanıyor. Temizlemeden önce kapatın."
        )
      case .activityUnavailable:
        (
          "Related process activity could not be checked. Check Activity Monitor.",
          "İlişkili işlem etkinliği kontrol edilemedi. Etkinlik Monitörü’nü kontrol edin."
        )
      case .mountedImage:
        ("This disk image is mounted. Eject it before cleaning.", "Bu disk imajı bağlı. Temizlemeden önce çıkarın.")
      case .imageStateUnavailable:
        (
          "Disk image state could not be checked. Inspect it in Disk Utility.",
          "Disk imajının durumu kontrol edilemedi. Disk İzlencesi’nde inceleyin."
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
          "Lighten could not inspect this item. Inspect its location in Finder.",
          "Lighten bu öğeyi inceleyemedi. Konumunu Finder’da inceleyin."
        )
      }
    return FailureText.text(copy.0, copy.1, turkish: turkish)
  }
}
