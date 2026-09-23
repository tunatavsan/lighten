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

  static func rejection(_ rejection: PlanRejection) -> String {
    let reason: String =
      switch rejection.reason {
      case .bulkRoot: String(localized: "A whole standard folder cannot be moved. Choose items inside it.")
      case .scanRoot: String(localized: "The scanned folder itself cannot be removed.")
      case .insidePackage:
        String(localized: "This is inside an app or package. Select the whole app or package instead.")
      case .protectedItem: String(localized: "Protected by Lighten's safety rules.")
      case .containsProtectedItem: String(localized: "Contains an item protected by Lighten's safety rules.")
      case .containsApplication:
        String(localized: "Contains an app. Select the app itself to move it whole, or choose other items.")
      case .mountPoint: String(localized: "Contains another mounted volume.")
      case .cloudItem: String(localized: "Contains cloud files that are not downloaded.")
      case .unreadableFolder: String(localized: "Contains a folder Lighten cannot read.")
      case .specialFile: String(localized: "Contains a special file such as a socket or device.")
      case .symbolicLinkRoot: String(localized: "A symbolic link moves only together with its folder.")
      case .missingMetadata: String(localized: "Its file metadata is incomplete, so undo could not be guaranteed.")
      case .changedSinceScan: String(localized: "It changed after the scan. Scan again.")
      case .differentVolume: String(localized: "Its volume cannot be identified.")
      case .needsAdministrator:
        String(localized: "Administrator permission is needed. Use Show in Finder to remove it there.")
      case .applicationRunning: String(localized: "The app is running. Quit it first.")
      case .lightenItself: String(localized: "Lighten does not remove itself.")
      case .tooManyItems: String(localized: "It contains too many items to verify at once.")
      case .unavailable: String(localized: "It is no longer available.")
      }
    return "\(reason) — \(rejection.path)"
  }
}
