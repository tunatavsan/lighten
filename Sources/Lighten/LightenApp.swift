import Darwin
import Foundation
import LightenKit
import SwiftUI

@main
struct LightenApp: App {
  init() {
    guard Bundle.main.bundleIdentifier == LightenIdentity.bundleIdentifier else {
      let message = "Lighten must run from a packaged bundle: scripts/run.sh\n"
      FileHandle.standardError.write(Data(message.utf8))
      Darwin.exit(2)
    }
  }

  var body: some Scene {
    WindowGroup {
      LightenRootView()
    }
    .defaultSize(width: 880, height: 600)

    Settings {
      LightenSettingsView()
    }
  }
}

private enum LightenSection: String, CaseIterable, Identifiable {
  case overview
  case clean
  case memory
  case health

  var id: Self { self }

  var title: String {
    switch self {
    case .overview:
      String(localized: "Overview")
    case .clean:
      String(localized: "Clean")
    case .memory:
      String(localized: "Memory")
    case .health:
      String(localized: "Health")
    }
  }

  var systemImage: String {
    switch self {
    case .overview:
      "rectangle.grid.2x2"
    case .clean:
      "sparkles"
    case .memory:
      "memorychip"
    case .health:
      "heart.text.square"
    }
  }
}

private struct LightenRootView: View {
  @State private var selection: LightenSection? = .overview

  var body: some View {
    NavigationSplitView {
      List(LightenSection.allCases, selection: $selection) { section in
        Label(section.title, systemImage: section.systemImage)
          .tag(section)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    } detail: {
      PlaceholderView(section: selection ?? .overview)
    }
    .frame(minWidth: 680, minHeight: 440)
  }
}

private struct PlaceholderView: View {
  let section: LightenSection

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: section.systemImage)
        .font(.system(size: 42))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(section.title)
        .font(.title)
      Text(String(localized: "Pre-alpha build"))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(section.title)
  }
}

private struct LightenSettingsView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(String(localized: "Settings"))
        .font(.title2)
      Text(String(localized: "Pre-alpha build"))
        .foregroundStyle(.secondary)
    }
    .scenePadding()
    .frame(width: 320, height: 120, alignment: .topLeading)
  }
}
