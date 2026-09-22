import AppKit
import CLightenPlatform
import Foundation
import LightenKit

struct MacOSProcessActivitySource: ProcessActivitySource {
  func activity(for rowID: String) async -> ProcessActivity {
    let category: Int32
    switch rowID {
    case "pip-http-v2", "pip-wheels": category = 0
    case "homebrew-downloads": category = 1
    default: return ProcessActivity(state: .unknown)
    }
    let native = await Task.detached(priority: .utility) {
      lighten_process_activity(category)
    }.value
    if native == 1 { return ProcessActivity(state: .active) }
    if native != 0 { return ProcessActivity(state: .unknown) }
    let running = await MainActor.run { NSWorkspace.shared.runningApplications }
    let names: Set<String> =
      category == 0
      ? ["com.python.python", "org.python.python", "com.astral-sh.uv"]
      : ["sh.brew.homebrew"]
    if running.contains(where: { app in
      guard let id = app.bundleIdentifier?.lowercased() else { return false }
      return names.contains(id)
    }) {
      return ProcessActivity(state: .active)
    }
    return ProcessActivity(state: .clearObservedCurrentUID)
  }
}
