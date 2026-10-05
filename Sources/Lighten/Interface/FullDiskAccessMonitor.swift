import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class FullDiskAccessMonitor {
  @ObservationIgnored private let check: @MainActor () async -> FullDiskAccessState
  @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
  @ObservationIgnored private let now: @MainActor () -> Date
  @ObservationIgnored private var generation = UUID()
  private(set) var state: FullDiskAccessState?
  private(set) var needsReopen = false
  private(set) var settingsOpenFailed = false

  init(
    check: @escaping @MainActor () async -> FullDiskAccessState = {
      await Task.detached { FullDiskAccess.check() }.value
    },
    sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.check = check
    self.sleep = sleep
    self.now = now
  }

  func refresh() async { state = await check() }

  /// macOS may require a restart instead of applying the permission in this process.
  func checkPermissionWindow() async {
    let token = UUID()
    generation = token
    let deadline = now().addingTimeInterval(1.5)
    needsReopen = false
    for attempt in 0...6 {
      let checked = await check()
      guard generation == token, !Task.isCancelled else { return }
      state = checked
      if checked == .granted { return }
      if attempt == 6 || now() >= deadline { break }
      do { try await sleep(.milliseconds(250)) } catch { return }
    }
    guard generation == token, !Task.isCancelled else { return }
    needsReopen = true
  }

  func openSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    settingsOpenFailed = !NSWorkspace.shared.open(url)
  }

  func reopen() async {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    do {
      _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
      NSApplication.shared.terminate(nil)
    } catch {
      settingsOpenFailed = true
    }
  }
}

private struct FullDiskAccessMonitorKey: EnvironmentKey {
  static let defaultValue: FullDiskAccessMonitor? = nil
}

extension EnvironmentValues {
  var fullDiskAccessMonitor: FullDiskAccessMonitor? {
    get { self[FullDiskAccessMonitorKey.self] }
    set { self[FullDiskAccessMonitorKey.self] = newValue }
  }
}

@MainActor final class OnboardingPreferences {
  private let defaults: UserDefaults?
  private var dismissedInProcess = false
  private static let dismissedKey = "fileAccessWelcomeDismissed"

  init(defaults: UserDefaults? = .standard) { self.defaults = defaults }
  var hasDismissed: Bool { defaults?.bool(forKey: Self.dismissedKey) ?? dismissedInProcess }
  func dismiss() {
    dismissedInProcess = true
    defaults?.set(true, forKey: Self.dismissedKey)
  }
  func shouldPresent(for state: FullDiskAccessState?) -> Bool {
    !hasDismissed && state != nil && state != .granted
  }
}
