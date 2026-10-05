import Darwin
import Foundation
import LightenKit
import SwiftUI

@main
struct LightenApp: App {
  @State private var access = FullDiskAccessMonitor()
  private let onboarding = OnboardingPreferences()

  init() {
    guard Bundle.main.bundleIdentifier == LightenIdentity.bundleIdentifier else {
      let message = "Lighten must run from a packaged bundle: scripts/run.sh\n"
      FileHandle.standardError.write(Data(message.utf8))
      Darwin.exit(2)
    }
    MainThreadWatchdog.startIfEnabled()
  }

  var body: some Scene {
    WindowGroup {
      LightenRootView(access: access, onboarding: onboarding)
        .environment(\.fullDiskAccessMonitor, access)
    }
    .defaultSize(width: 1220, height: 800)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified)
    Settings { LightenSettingsView(access: access) }
  }
}

private struct LightenRootView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let access: FullDiskAccessMonitor
  let onboarding: OnboardingPreferences
  @State private var section: LightenSection? = .overview
  @State private var overview = OverviewStore()
  @State private var space = SpaceStore()
  @State private var actions = ActionStore()
  @State private var clean = CleanStore()
  @State private var duplicates = DuplicateStore()
  @State private var apps = AppsStore()
  @State private var feedback = ActionFeedbackState()
  @State private var showingWelcome = false

  private var presentations: [LightenSection: ToolPresentation] {
    var spacePhase: ToolPhase {
      switch space.phase {
      case .idle: .idle
      case .scanning: .scanning
      case .cancelled, .partial: .partial
      case .complete: .ready
      case .error: .failed
      }
    }
    let spaceSummary = ToolSummary(
      count: Int(clamping: space.rootSummary?.itemCount ?? 0),
      logicalBytes: space.rootSummary?.logical.knownLowerBound ?? 0,
      observedAt: space.cachedAt ?? space.tree?.startedAt,
      partial: space.rootSummary?.partial == true || spacePhase == .partial)
    return [
      .space: ToolPresentation(phase: spacePhase, summary: spaceSummary),
      .clean: ToolPresentation(phase: clean.phase, summary: clean.toolSummary),
      .duplicates: ToolPresentation(phase: duplicates.phase, summary: duplicates.toolSummary),
      .apps: ToolPresentation(phase: apps.phase, summary: apps.toolSummary),
    ]
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $section) {
        ForEach(ToolGroup.allCases) { group in
          Section(group.title) {
            ForEach(ToolCatalog.entries.filter { $0.group == group }) { entry in
              ToolSidebarRow(entry: entry, presentation: presentations[entry.id])
                .tag(entry.id)
            }
          }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 260)
    } detail: {
      switch section ?? .overview {
      case .overview:
        OverviewView(
          store: overview, space: space, actions: actions,
          showSpace: { section = .space }, showHistory: { section = .history })
      case .tools:
        ToolsGridView(presentations: presentations) { section = $0 }
      case .space:
        SpaceView(store: space, actions: actions, showHistory: { section = .history })
      case .clean:
        CleanView(store: clean, actions: actions)
      case .duplicates:
        DuplicateView(store: duplicates, actions: actions)
      case .apps:
        AppsView(store: apps, actions: actions)
      case .history:
        HistoryView(actions: actions)
      }
    }
    .frame(minWidth: 820, minHeight: 560)
    .tint(LightenStyle.accent)
    .overlay(alignment: .bottom) {
      if let presentation = feedback.presentation {
        ActionFeedbackToast(feedback: presentation, actions: actions, dismiss: feedback.dismiss)
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: feedback.presentation?.id)
    .task(id: feedback.presentation?.id) {
      if let id = feedback.presentation?.id { await feedback.expire(id) }
    }
    .onChange(of: actions.result?.planID) { _, _ in showActionFeedback() }
    .onChange(of: reduceMotion, initial: true) { _, value in
      actions.reduceMotion = value
      space.reduceMotion = value
    }
    .sheet(isPresented: $showingWelcome) { FileAccessWelcome(access: access, preferences: onboarding) }
    .task { await prepareShell() }
  }

  private func showActionFeedback() {
    guard let result = actions.result, let kind = actions.resultKind,
      let message = actions.completedSummary
    else { return }
    feedback.show(
      planID: result.planID, kind: kind,
      appliedCount: result.items.filter { $0.outcome == .applied }.count, message: message)
  }

  private func prepareShell() async {
    actions.onDisplayChange = { [weak space, weak clean, weak apps, weak duplicates] change in
      space?.applyDisplayChange(change)
      clean?.applyDisplayChange(change)
      apps?.applyDisplayChange(change)
      duplicates?.applyDisplayChange(change)
    }
    actions.onDisplayDiscrepancy = { [weak space, weak clean, weak apps, weak duplicates, weak actions] _ in
      guard let actions else { return }
      if space?.tree != nil { space?.startScan() }
      if clean?.scannedAt != nil { clean?.startScan(actions: actions) }
      if apps?.scannedAt != nil { apps?.startScan(actions: actions) }
      if let folder = duplicates?.folderPath { duplicates?.startScan(folder: folder, actions: actions) }
    }
    await actions.reloadHistory()
    await access.refresh()
    showingWelcome = onboarding.shouldPresent(for: access.state)
  }
}
