import AppKit
import Foundation
import LightenKit

extension RelatedDataService {
  /// Related data with a LaunchServices check: an app known anywhere outside
  /// the Trash keeps its data from being offered as a leftover.
  nonisolated static var system: RelatedDataService {
    RelatedDataService(installedElsewhere: { bundleID in
      let trash = NSHomeDirectory() + "/.Trash/"
      return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains { url in
        let path = url.resolvingSymlinksInPath().path
        // LaunchServices can remember a removed app for a while; only a present bundle counts.
        return !path.hasPrefix(trash) && !path.contains("/.Trashes/")
          && FileManager.default.fileExists(atPath: path + "/Contents/Info.plist")
      }
    })
  }
}
