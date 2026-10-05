import AppKit
import SwiftUI

struct FileAccessStatus: View {
  let access: FullDiskAccessMonitor

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch access.state {
      case .granted:
        Label(String(localized: "Full Disk Access: granted"), systemImage: "checkmark.seal.fill")
          .foregroundStyle(.green)
      case .notGranted:
        Label(String(localized: "Full Disk Access: not granted"), systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(LightenStyle.warning)
      case .unknown:
        Label(String(localized: "Full Disk Access: could not be determined"), systemImage: "questionmark.circle")
          .foregroundStyle(.secondary)
      case nil:
        ProgressView().controlSize(.small)
      }
      if access.needsReopen, access.state != .granted {
        Text(String(localized: "If you enabled access, reopen Lighten so macOS can apply it."))
          .font(.callout).fixedSize(horizontal: false, vertical: true)
        Button(String(localized: "Reopen Lighten")) { Task { await access.reopen() } }
      }
      if access.settingsOpenFailed {
        Text(
          String(
            localized:
              "Open System Settings → Privacy & Security → Full Disk Access, or quit and reopen Lighten manually.")
        )
        .font(.caption).foregroundStyle(LightenStyle.warning)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct FileAccessWelcome: View {
  @Environment(\.dismiss) private var dismiss
  let access: FullDiskAccessMonitor
  let preferences: OnboardingPreferences

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label(String(localized: "Welcome to Lighten"), systemImage: "sparkles")
        .font(.title2.bold())
      Text(String(localized: "See more of your Mac"))
        .font(.headline)
      Text(
        String(
          localized:
            "Full Disk Access lets Lighten check protected folders. Without it, you can still use Lighten, but some scan results may be incomplete."
        )
      )
      .fixedSize(horizontal: false, vertical: true)
      Text(String(localized: "You control this permission in System Settings. Lighten never grants it automatically."))
        .font(.callout).foregroundStyle(.secondary)
      Text(
        String(
          localized: "If Lighten’s signing identity changes after an update, macOS may ask you to grant access again.")
      )
      .font(.caption).foregroundStyle(.secondary)
      FileAccessStatus(access: access)
      HStack {
        Button(String(localized: "Skip for now"), action: finish)
        Spacer()
        if access.state == .granted {
          Button(String(localized: "Continue"), action: finish).buttonStyle(.borderedProminent)
        } else {
          Button(String(localized: "Open Full Disk Access settings"), action: access.openSettings)
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(28)
    .frame(width: 520)
    .task { await access.checkPermissionWindow() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await access.checkPermissionWindow() }
    }
  }

  private func finish() {
    preferences.dismiss()
    dismiss()
  }
}
