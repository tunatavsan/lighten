import AppKit
import LightenKit

struct MacOSRunningApplicationSource: RunningApplicationSource {
  func isRunning(bundleID: String) async -> Bool? {
    await MainActor.run {
      NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == bundleID
      }
    }
  }
}
