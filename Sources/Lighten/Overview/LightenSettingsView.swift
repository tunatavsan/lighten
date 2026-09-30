import AppKit
import SwiftUI

struct LightenSettingsView: View {
  @State private var cacheStore = SpaceStore()
  @State private var settingsOpenFailed = false
  @State private var access: FullDiskAccessState?
  var space: SpaceStore?
  var retrySpace: (() -> Void)?
  var retryClean: (() -> Void)?
  var retryDuplicates: (() -> Void)?
  var retryApps: (() -> Void)?

  private let fullDiskAccessURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text(String(localized: "Settings"))
          .font(.system(size: 24, weight: .semibold))
        Label(String(localized: "File access"), systemImage: "hand.raised")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(LightenStyle.accent)
        Text(
          String(
            localized:
              "Lighten scans only locations your account and macOS allow. Full Disk Access is optional. Without it, protected locations may stay unreadable and scans can be partial."
          )
        )
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
        Text(
          String(
            localized:
              "macOS controls this permission. Opening Settings does not grant access. Return to Lighten and retry a scan after changing access."
          )
        )
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        .fixedSize(horizontal: false, vertical: true)
        accessStatus
        HStack(spacing: 10) {
          Button(String(localized: "Open Full Disk Access settings")) {
            settingsOpenFailed = !NSWorkspace.shared.open(fullDiskAccessURL)
          }
          .buttonStyle(.borderedProminent)
          Button(String(localized: "Check again")) { refreshAccess() }
        }
        if settingsOpenFailed {
          Text(
            String(localized: "Could not open Settings. Go to System Settings → Privacy & Security → Full Disk Access.")
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
          .fixedSize(horizontal: false, vertical: true)
        }
        let space = space ?? cacheStore
        Group {
          Divider()
          Text(String(localized: "Scan cache")).font(.system(size: 16, weight: .semibold))
          HStack {
            Text(format(space.cacheUsageBytes)).monospacedDigit()
            Spacer()
            Button(String(localized: "Clear scan cache")) { Task { await space.clearScanCache() } }
          }
          Text(
            String(
              localized: "Previous scan pictures help Space open quickly. Clearing them does not remove your files.")
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          .fixedSize(horizontal: false, vertical: true)
          if let message = space.cacheMessage {
            Text(message).font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
          }
        }
        if retrySpace != nil || retryClean != nil || retryDuplicates != nil || retryApps != nil {
          Divider()
          Text(String(localized: "Retry a scan"))
            .font(.system(size: 16, weight: .semibold))
          Text(
            String(
              localized: "Choose an area to check access again. Previous results are not proof of newly granted access."
            )
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { retryButtons }
              .fixedSize(horizontal: true, vertical: false)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
              retryButtons
            }
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(LightenStyle.canvas)
    .navigationTitle(String(localized: "Settings"))
    .task {
      refreshAccess()
      (space ?? cacheStore).loadCacheUsage()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshAccess()
    }
  }

  private func refreshAccess() {
    Task {
      access = await Task.detached { FullDiskAccess.check() }.value
    }
  }

  @ViewBuilder private var accessStatus: some View {
    switch access {
    case .granted:
      Label(String(localized: "Full Disk Access: granted"), systemImage: "checkmark.seal.fill")
        .font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
    case .notGranted:
      VStack(alignment: .leading, spacing: 4) {
        Label(String(localized: "Full Disk Access: not granted"), systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 13, weight: .medium)).foregroundStyle(LightenStyle.warning)
        Text(
          String(
            localized:
              "If you just turned it on, macOS may ask you to quit and reopen Lighten before the permission applies.")
        )
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        .fixedSize(horizontal: false, vertical: true)
      }
    case .unknown:
      Label(String(localized: "Full Disk Access: could not be determined"), systemImage: "questionmark.circle")
        .font(.system(size: 13, weight: .medium)).foregroundStyle(LightenStyle.muted)
    case nil:
      ProgressView().controlSize(.small)
    }
  }

  @ViewBuilder private var retryButtons: some View {
    if let retrySpace { Button(String(localized: "Retry Space"), action: retrySpace) }
    if let retryClean { Button(String(localized: "Retry Clean"), action: retryClean) }
    if let retryDuplicates {
      Button(String(localized: "Retry Duplicates"), action: retryDuplicates)
    }
    if let retryApps { Button(String(localized: "Retry Apps"), action: retryApps) }
  }
}
