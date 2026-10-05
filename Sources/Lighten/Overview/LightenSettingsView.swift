import AppKit
import SwiftUI

struct LightenSettingsView: View {
  @State private var cacheStore = SpaceStore()
  @State private var removal = RemovalPreferences.shared
  @State private var duplicates = DuplicatePreferences.shared
  var access = FullDiskAccessMonitor()
  var space: SpaceStore?
  var retrySpace: (() -> Void)?
  var retryClean: (() -> Void)?
  var retryDuplicates: (() -> Void)?
  var retryApps: (() -> Void)?

  var body: some View {
    LegacyToolScreen(String(localized: "Settings")) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Group {
            Picker(String(localized: "Default removal method"), selection: $removal.deletionDefault) {
              ForEach(RemovalPreferences.DefaultMethod.allCases) { method in
                Text(method.title).tag(method)
              }
            }
            Toggle(
              String(localized: "Automatically select discovered app data"),
              isOn: $removal.automaticallySelectRelatedData
            )
            Text(
              String(
                localized:
                  "Only data supported by independent evidence is selected automatically. You can select other rows yourself."
              )
            )
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
            Text(String(localized: "Permanent deletion always needs a separate confirmation and cannot be undone."))
              .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
            Divider()
          }
          duplicateSettings
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
          FileAccessStatus(access: access)
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
                localized:
                  "Choose an area to check access again. Previous results are not proof of newly granted access."
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
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } toolbar: {
      Button(String(localized: "Open Full Disk Access settings"), action: access.openSettings)
      Button(String(localized: "Check again")) { Task { await access.checkPermissionWindow() } }
    }
    .frame(minWidth: 560, minHeight: 500)
    .task {
      await access.refresh()
      (space ?? cacheStore).loadCacheUsage()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await access.checkPermissionWindow() }
    }
  }

  private var duplicateSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(String(localized: "Duplicates")).font(.system(size: 16, weight: .semibold))
      HStack {
        Text(String(localized: "Minimum duplicate file size (MB)"))
        Spacer()
        TextField(
          String(localized: "Minimum duplicate file size (MB)"), value: $duplicates.minimumMegabytes,
          format: .number.precision(.fractionLength(0...6))
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 110)
      }
      Text(
        String(localized: "Enter a size greater than zero. Changes apply to the next duplicate scan.")
      )
      .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      Text(
        String(
          localized:
            "Hidden folders, developer folders, caches, and package contents are skipped. Home scans also skip Library."
        )
      )
      .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      .fixedSize(horizontal: false, vertical: true)
      Divider()
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
