import Foundation

/// Journal and error codes stay machine-readable; people read a reason.
enum FailureText {
  static func describe(_ error: any Error) -> String { describe(String(describing: error)) }

  static func describe(_ raw: String) -> String {
    let code = raw.split(separator: "(").first.map(String.init) ?? raw
    return switch code {
    case "catalogDeleteDenied":
      String(localized: "A related tool was running or its activity could not be checked, so nothing was changed.")
    case "runningOrUnknown":
      String(localized: "The app was running or its state could not be checked, so it was left in place.")
    case "selfRemoval": String(localized: "Lighten does not remove itself.")
    case "changedItem", "changedAncestor", "changedInventory", "changed", "changedSinceScan", "changedDuringInspection",
      "changedTrashItem":
      String(localized: "The item changed after it was checked, so it was left in place. Scan again.")
    case "protectedItem": String(localized: "Protected by Lighten's safety rules.")
    case "unsupportedItem", "unsafeSelection":
      String(localized: "The item no longer meets the conditions for a safe move, so it was left in place.")
    case "incompleteInventory": String(localized: "The app inventory was incomplete, so nothing was changed.")
    case "ownerPresent", "ambiguousOwner":
      String(localized: "An app that may own this data is installed, so it was left in place.")
    case "invalidReceipt", "invalidProof", "unauthorizedPath", "invalidPlan", "planAlreadyUsed":
      String(localized: "The prepared action is no longer valid. Scan again.")
    case "corruptHistory":
      String(localized: "The action history needs attention. Review History before another action.")
    case "alreadyRunning": String(localized: "Another action is still running.")
    case "nameOccupied": String(localized: "Another item now uses the original name, so both were kept.")
    case "unsafeParent", "noAppliedRecord", "unknownItem":
      String(localized: "The original location could not be verified, so the item stays in the Trash.")
    case "invalidSelection", "metadataUnknown", "metadataDifferent", "dataDifferent":
      String(localized: "The copies no longer match exactly, so nothing was moved. Scan again.")
    case "notDirectory", "rootNotDirectory": String(localized: "The chosen item is not a folder.")
    case "unavailable", "childUnavailable", "invalidPath":
      String(localized: "The folder is not available. It may have moved or you may not have access.")
    case "systemCall", "renameFailed":
      String(localized: "macOS refused the operation. Check permissions and try again.")
    default: "\(String(localized: "The action did not complete.")) (\(raw))"
    }
  }
}
