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
    WindowGroup { LightenRootView() }
      .defaultSize(width: 1220, height: 800)
    Settings { Text(String(localized: "Settings")).scenePadding() }
  }
}

private enum LightenSection: String, CaseIterable, Identifiable {
  case overview, space, clean, duplicates, apps, history
  var id: Self { self }
  var title: String {
    switch self {
    case .overview: String(localized: "Overview")
    case .space: String(localized: "Space")
    case .clean: String(localized: "Clean")
    case .duplicates: String(localized: "Duplicates")
    case .apps: String(localized: "Apps")
    case .history: String(localized: "History")
    }
  }
  var icon: String {
    switch self {
    case .overview: "rectangle.grid.2x2"
    case .space: "square.grid.3x3.fill"
    case .clean: "sparkles"
    case .duplicates: "doc.on.doc"
    case .apps: "app.dashed"
    case .history: "clock.arrow.circlepath"
    }
  }
}

private struct LightenRootView: View {
  @State private var section: LightenSection? = .space
  @State private var space = SpaceStore()
  @State private var actions = ActionStore()
  @State private var clean = CleanStore()
  @State private var duplicates = DuplicateStore()

  var body: some View {
    NavigationSplitView {
      List(LightenSection.allCases, selection: $section) { item in
        Label(item.title, systemImage: item.icon).tag(item)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 250)
    } detail: {
      switch section ?? .space {
      case .space:
        SpaceView(store: space, actions: actions, showHistory: { section = .history })
      case .clean:
        CleanView(store: clean, actions: actions)
      case .duplicates:
        DuplicateView(store: duplicates, actions: actions)
      case .history:
        HistoryView(actions: actions)
      case let item:
        ContentUnavailableView(item.title, systemImage: item.icon)
          .navigationTitle(item.title)
      }
    }
    .frame(minWidth: 820, minHeight: 560)
    .tint(LightenStyle.accent)
    .task { await actions.reloadHistory() }
  }
}
