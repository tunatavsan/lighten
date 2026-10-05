import AppKit
import SwiftUI

/// Settings in the macOS shape: a few tabs, each one grouped form. No menu opens another menu.
struct LightenSettingsView: View {
  @State private var cacheStore = SpaceStore()
  @State private var removal = RemovalPreferences.shared
  @State private var duplicates = DuplicatePreferences.shared
  @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system
  @AppStorage(MenuBarPreference.key) private var showsMenuBarExtra = false
  var access = FullDiskAccessMonitor()
  var space: SpaceStore?
  var retrySpace: (() -> Void)?
  var retryClean: (() -> Void)?
  var retryDuplicates: (() -> Void)?
  var retryApps: (() -> Void)?

  var body: some View {
    TabView {
      Tab(String(localized: "General"), systemImage: "gearshape") { general }
      Tab(String(localized: "Removal"), systemImage: "trash") { removalSettings }
      Tab(String(localized: "File access"), systemImage: "hand.raised") { fileAccess }
    }
    .frame(width: Theme.Layout.settingsWidth)
    .frame(minHeight: Theme.Layout.settingsMinimumHeight)
    .task {
      await access.refresh()
      (space ?? cacheStore).loadCacheUsage()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await access.checkPermissionWindow() }
    }
  }

  // MARK: General

  private var general: some View {
    let space = space ?? cacheStore
    return Form {
      Section {
        Picker(String(localized: "Appearance"), selection: $appearance) {
          ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Toggle(String(localized: "Show in menu bar"), isOn: $showsMenuBarExtra)
      } footer: {
        footnote(String(localized: "The menu bar item shows free space and memory pressure, and opens each tool."))
      }
      Section {
        LabeledContent(String(localized: "Stored previous scans")) {
          HStack(spacing: Theme.Space.m) {
            Text(ByteCountFormatter.string(fromByteCount: space.cacheUsageBytes, countStyle: .file))
              .font(Theme.Font.mono).foregroundStyle(Theme.Palette.inkSecondary)
            Button(String(localized: "Clear scan cache")) { Task { await space.clearScanCache() } }
          }
        }
        if let message = space.cacheMessage {
          Text(message).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning)
        }
      } header: {
        Text(String(localized: "Scan cache"))
      } footer: {
        footnote(
          String(localized: "Previous scan pictures help Space open quickly. Clearing them does not remove your files.")
        )
      }
    }
    .formStyle(.grouped)
  }

  // MARK: Removal

  private var removalSettings: some View {
    Form {
      Section {
        Picker(String(localized: "Default removal method"), selection: $removal.deletionDefault) {
          ForEach(RemovalPreferences.DefaultMethod.allCases) { method in
            Text(method.title).tag(method)
          }
        }
        Toggle(
          String(localized: "Automatically select discovered app data"),
          isOn: $removal.automaticallySelectRelatedData)
      } footer: {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
          footnote(
            String(
              localized:
                "Only data supported by independent evidence is selected automatically. You can select other rows yourself."
            ))
          Text(String(localized: "Permanent deletion always needs a separate confirmation and cannot be undone."))
            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning)
        }
      }
      Section {
        LabeledContent(String(localized: "Minimum duplicate file size (MB)")) {
          TextField(
            String(localized: "Minimum duplicate file size (MB)"), value: $duplicates.minimumMegabytes,
            format: .number.precision(.fractionLength(0...6))
          )
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: Theme.Layout.numberField)
        }
      } header: {
        Text(String(localized: "Duplicates"))
      } footer: {
        footnote(
          String(localized: "Enter a size greater than zero. Changes apply to the next duplicate scan.") + " "
            + String(
              localized:
                "Hidden folders, developer folders, caches, and package contents are skipped. Home scans also skip Library."
            ))
      }
    }
    .formStyle(.grouped)
  }

  // MARK: File access

  private var fileAccess: some View {
    Form {
      Section {
        FileAccessStatus(access: access)
        HStack {
          Button(String(localized: "Open Full Disk Access settings"), action: access.openSettings)
          Button(String(localized: "Check again")) { Task { await access.checkPermissionWindow() } }
        }
      } footer: {
        footnote(
          String(
            localized:
              "Lighten scans only locations your account and macOS allow. Full Disk Access is optional. Without it, protected locations may stay unreadable and scans can be partial."
          ) + " "
            + String(
              localized:
                "macOS controls this permission. Opening Settings does not grant access. Return to Lighten and retry a scan after changing access."
            ))
      }
      if retrySpace != nil || retryClean != nil || retryDuplicates != nil || retryApps != nil {
        Section {
          HStack { retryButtons }
        } header: {
          Text(String(localized: "Retry a scan"))
        } footer: {
          footnote(
            String(
              localized:
                "Choose an area to check access again. Previous results are not proof of newly granted access."))
        }
      }
    }
    .formStyle(.grouped)
  }

  private func footnote(_ text: String) -> some View {
    Text(text).font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
      .fixedSize(horizontal: false, vertical: true)
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

/// Whether Lighten also lives in the menu bar. Off until the user turns it on.
enum MenuBarPreference {
  static let key = "LightenShowsMenuBarExtra"
}
