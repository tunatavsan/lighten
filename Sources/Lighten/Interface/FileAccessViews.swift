import AppKit
import SwiftUI

struct FileAccessStatus: View {
  let access: FullDiskAccessMonitor

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      switch access.state {
      case .granted:
        StatusLabel(title: String(localized: "Full Disk Access: granted"), tone: .positive)
      case .notGranted:
        StatusLabel(title: String(localized: "Full Disk Access: not granted"), tone: .warning)
      case .unknown:
        StatusLabel(title: String(localized: "Full Disk Access: could not be determined"))
      case nil:
        ProgressView().controlSize(.small)
      }
      if access.needsReopen, access.state != .granted {
        HStack(spacing: Theme.Space.s) {
          Text(String(localized: "If you enabled access, reopen Lighten so macOS can apply it."))
            .font(Theme.Font.callout).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: Theme.Space.s)
          Button(String(localized: "Reopen Lighten")) { Task { await access.reopen() } }
        }
      }
      if access.settingsOpenFailed {
        Text(
          String(
            localized:
              "Open System Settings → Privacy & Security → Full Disk Access, or quit and reopen Lighten manually.")
        )
        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// The first-run sheet: what Full Disk Access is for, and that the choice is the user's.
struct FileAccessWelcome: View {
  @Environment(\.dismiss) private var dismiss
  let access: FullDiskAccessMonitor
  let preferences: OnboardingPreferences

  var body: some View {
    VStack(spacing: Theme.Space.xl) {
      VStack(spacing: Theme.Space.m) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable().frame(width: Theme.Layout.welcomeIcon, height: Theme.Layout.welcomeIcon)
          .accessibilityHidden(true)
        Text(String(localized: "Welcome to Lighten")).font(Theme.Font.title)
        Text(String(localized: "See more of your Mac")).font(Theme.Font.title2)
          .foregroundStyle(Theme.Palette.inkSecondary)
      }
      VStack(alignment: .leading, spacing: Theme.Space.m) {
        point(
          "lock.open",
          String(
            localized:
              "Full Disk Access lets Lighten check protected folders. Without it, you can still use Lighten, but some scan results may be incomplete."
          ))
        point(
          "hand.raised",
          String(localized: "You control this permission in System Settings. Lighten never grants it automatically."))
        point(
          "signature",
          String(
            localized: "If Lighten’s signing identity changes after an update, macOS may ask you to grant access again."
          ))
      }
      .padding(Theme.Space.l)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.Palette.well, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
      FileAccessStatus(access: access).frame(maxWidth: .infinity, alignment: .leading)
      HStack {
        Button(String(localized: "Skip for now"), action: finish)
        Spacer()
        if access.state == .granted {
          Button(String(localized: "Continue"), action: finish)
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
          Button(String(localized: "Open Full Disk Access settings"), action: access.openSettings)
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
      }
      .controlSize(.large)
    }
    .padding(Theme.Space.xxl)
    .frame(width: Theme.Layout.welcomeWidth)
    .task { await access.checkPermissionWindow() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await access.checkPermissionWindow() }
    }
  }

  private func point(_ symbol: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: Theme.Space.m) {
      Image(systemName: symbol).font(Theme.Font.icon).foregroundStyle(Theme.Palette.accent)
        .frame(width: Theme.Space.xl).accessibilityHidden(true)
      Text(text).font(Theme.Font.body).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func finish() {
    preferences.dismiss()
    dismiss()
  }
}
