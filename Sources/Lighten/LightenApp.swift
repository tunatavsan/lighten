import Darwin
import Foundation
import LightenKit
import SwiftUI

@main
struct LightenApp: App {
  @State private var model: LightenModel

  init() {
    guard Bundle.main.bundleIdentifier == LightenIdentity.bundleIdentifier else {
      let message = "Lighten must run from a packaged bundle: scripts/run.sh\n"
      FileHandle.standardError.write(Data(message.utf8))
      Darwin.exit(2)
    }
    MainThreadWatchdog.startIfEnabled()
    _model = State(initialValue: LightenModel())
  }

  var body: some Scene {
    WindowGroup(id: LightenRootView.windowID) {
      LightenRootView(model: model)
        .environment(\.fullDiskAccessMonitor, model.access)
    }
    .defaultSize(Theme.Layout.windowDefault)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified)
    Settings { LightenSettingsView(access: model.access) }
  }
}

struct LightenRootView: View {
  static let windowID = "main"
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Bindable var model: LightenModel

  var body: some View {
    NavigationSplitView {
      LightenSidebar(selection: $model.section, presentations: model.presentations)
    } detail: {
      ZStack {
        detail
          .id(model.section)
          .transition(Theme.Motion.transition(Theme.Motion.screen, reduceMotion: reduceMotion))
      }
      .animation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion), value: model.section)
      .contentPane()
      .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
    .windowTray()
    .appliesAppearancePreference()
    .frame(minWidth: Theme.Layout.windowMinimum.width, minHeight: Theme.Layout.windowMinimum.height)
    .tint(Theme.Palette.accent)
    .overlay(alignment: .bottom) {
      if let presentation = model.feedback.presentation {
        ActionFeedbackToast(feedback: presentation, actions: model.actions, dismiss: model.feedback.dismiss)
          .transition(Theme.Motion.transition(Theme.Motion.rise, reduceMotion: reduceMotion))
      }
    }
    .animation(
      Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion), value: model.feedback.presentation?.id
    )
    .task(id: model.feedback.presentation?.id) {
      if let id = model.feedback.presentation?.id { await model.feedback.expire(id) }
    }
    .onChange(of: model.actions.result?.planID) { _, _ in model.showActionFeedback() }
    .onChange(of: reduceMotion, initial: true) { _, value in
      model.actions.reduceMotion = value
      model.space.reduceMotion = value
    }
    .sheet(isPresented: $model.showingWelcome) {
      FileAccessWelcome(access: model.access, preferences: model.onboarding)
    }
    .task { await model.prepare() }
    .task { await model.loadPreviousSummaries() }
  }

  @ViewBuilder private var detail: some View {
    switch model.section ?? .overview {
    case .overview:
      OverviewView(
        store: model.overview, space: model.space, actions: model.actions,
        presentations: model.presentations, show: model.show)
    case .space:
      SpaceView(store: model.space, actions: model.actions, showHistory: { model.show(.history) })
    case .clean:
      CleanView(store: model.clean, actions: model.actions)
    case .duplicates:
      DuplicateView(store: model.duplicates, actions: model.actions)
    case .apps:
      AppsView(store: model.apps, actions: model.actions)
    case .history:
      HistoryView(actions: model.actions)
    }
  }
}

/// The sidebar: tools grouped as in System Settings, each with its tile and latest result.
struct LightenSidebar: View {
  @Binding var selection: LightenSection?
  let presentations: [LightenSection: ToolPresentation]

  var body: some View {
    List(selection: $selection) {
      ForEach(ToolGroup.allCases) { group in
        let entries = ToolCatalog.entries.filter { $0.group == group }
        if let title = group.title {
          Section(title) { rows(entries) }
        } else {
          Section { rows(entries) }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(
      min: Theme.Layout.sidebarMinimum, ideal: Theme.Layout.sidebarIdeal, max: Theme.Layout.sidebarMaximum)
  }

  private func rows(_ entries: [ToolCatalogEntry]) -> some View {
    ForEach(entries) { entry in
      SidebarRow(entry: entry, presentation: presentations[entry.id]).tag(entry.id)
    }
  }
}

private struct SidebarRow: View {
  let entry: ToolCatalogEntry
  let presentation: ToolPresentation?

  var body: some View {
    HStack(spacing: Theme.Space.s) {
      Label(entry.title, systemImage: entry.symbol).lineLimit(1)
      Spacer(minLength: Theme.Space.xs)
      if presentation?.isWorking == true {
        ProgressView().controlSize(.mini)
          .accessibilityLabel(String(localized: "Working in the background"))
      } else if let value = presentation?.sidebarValue(for: entry.id) {
        Text(value).font(Theme.Font.monoSmall).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1)
      }
    }
    .help(help)
    .accessibilityElement(children: .combine)
  }

  private var help: String {
    guard let presentation, presentation.summary.observedAt != nil || presentation.isWorking else {
      return entry.description
    }
    let result = presentation.resultText(for: entry.id)
    return presentation.isPreviousResult ? result + " · " + String(localized: "Previous result") : result
  }
}
