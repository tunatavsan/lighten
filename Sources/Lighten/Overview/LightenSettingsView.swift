import AppKit
import SwiftUI

struct LightenSettingsView: View {
  @State private var settingsOpenFailed = false
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
          .font(.system(size: 25, weight: .semibold))
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
        Button(String(localized: "Open Full Disk Access settings")) {
          settingsOpenFailed = !NSWorkspace.shared.open(fullDiskAccessURL)
        }
        .buttonStyle(.borderedProminent)
        if settingsOpenFailed {
          Text(
            String(localized: "Could not open Settings. Go to System Settings → Privacy & Security → Full Disk Access.")
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
          .fixedSize(horizontal: false, vertical: true)
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
      .padding(22)
      .frame(maxWidth: 650, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(LightenStyle.canvas)
    .navigationTitle(String(localized: "Settings"))
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
