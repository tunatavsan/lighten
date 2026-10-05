import Foundation
import LightenKit
import Observation

/// The stores one window and the menu bar panel share, and which screen is showing.
@MainActor @Observable
final class LightenModel {
  /// The screen showing. Remembered between launches; `-LightenSection <name>` on the command line opens a
  /// given screen through the defaults argument domain.
  var section: LightenSection? = LightenModel.restoredSection() {
    didSet { UserDefaults.standard.set(section?.rawValue, forKey: Self.sectionKey) }
  }
  let access = FullDiskAccessMonitor()
  let onboarding = OnboardingPreferences()
  let overview = OverviewStore()
  let space = SpaceStore()
  let actions = ActionStore()
  let clean = CleanStore()
  let duplicates = DuplicateStore()
  let apps = AppsStore()
  let feedback = ActionFeedbackState()
  var showingWelcome = false
  private(set) var previousSummaries: [LightenSection: ToolSummary] = [:]
  @ObservationIgnored private var prepared = false

  var presentations: [LightenSection: ToolPresentation] {
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
      .clean: ToolPresentation(
        phase: clean.phase, summary: clean.toolSummary, previousSummary: previousSummaries[.clean]),
      .duplicates: ToolPresentation(
        phase: duplicates.phase, summary: duplicates.toolSummary,
        previousSummary: previousSummaries[.duplicates]),
      .apps: ToolPresentation(phase: apps.phase, summary: apps.toolSummary, previousSummary: previousSummaries[.apps]),
    ]
  }

  func show(_ section: LightenSection) { self.section = section }

  static let sectionKey = "LightenSection"

  private static func restoredSection() -> LightenSection {
    UserDefaults.standard.string(forKey: sectionKey).flatMap(LightenSection.init(rawValue:)) ?? .overview
  }

  func showActionFeedback() {
    guard let result = actions.result, let kind = actions.resultKind,
      let message = actions.completedSummary
    else { return }
    feedback.show(
      planID: result.planID, kind: kind,
      appliedCount: result.items.filter { $0.outcome == .applied }.count, message: message)
  }

  /// Wires display changes between stores, reads history and access once per process.
  func prepare() async {
    guard !prepared else { return }
    prepared = true
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

  func loadPreviousSummaries() async {
    let loaded = await ToolCatalog.previousSummaries(from: ResultPictureStore())
    guard !Task.isCancelled else { return }
    previousSummaries = loaded
  }
}
