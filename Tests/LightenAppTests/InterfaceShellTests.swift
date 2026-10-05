import Foundation
import LightenKit
import Testing

@testable import Lighten

@MainActor private final class PermissionClock {
  var instant = Date(timeIntervalSince1970: 1000)
  var elapsed = 0.0
  var calls = 0
  var grantOnCall: Int?
  var unavailable = false

  func check() -> FullDiskAccessState {
    calls += 1
    return grantOnCall.map { calls >= $0 } == true ? .granted : unavailable ? .unknown : .notGranted
  }

  func sleep(_ duration: Duration) {
    let components = duration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    elapsed += seconds
    instant = instant.addingTimeInterval(seconds)
  }

  func monitor() -> FullDiskAccessMonitor {
    FullDiskAccessMonitor(check: { self.check() }, sleep: { self.sleep($0) }, now: { self.instant })
  }
}

@Test("Permission check reaches granted or restart guidance within two seconds in ten attempts")
@MainActor func fileAccessPermissionWindowIsBounded() async {
  for attempt in 0..<10 {
    let clock = PermissionClock()
    clock.grantOnCall = attempt.isMultiple(of: 2) ? 4 : nil
    let monitor = clock.monitor()
    await monitor.checkPermissionWindow()
    #expect(clock.elapsed <= 2)
    #expect(monitor.state == .granted || monitor.needsReopen)
    #expect(clock.calls <= 7)
    if clock.grantOnCall != nil {
      #expect(monitor.state == .granted)
      #expect(!monitor.needsReopen)
    } else {
      #expect(monitor.state == .notGranted)
      #expect(monitor.needsReopen)
    }
  }
}

@Test("Unknown permission gets restart guidance and an existing grant never gets onboarding")
@MainActor func fileAccessUnknownAndAlreadyGranted() async {
  let clock = PermissionClock()
  clock.unavailable = true
  let monitor = clock.monitor()
  await monitor.checkPermissionWindow()
  #expect(monitor.state == .unknown)
  #expect(monitor.needsReopen)
  clock.grantOnCall = clock.calls + 1
  await monitor.checkPermissionWindow()
  #expect(monitor.state == .granted)
  #expect(!monitor.needsReopen)
  #expect(!OnboardingPreferences(defaults: nil).shouldPresent(for: .granted))
}

@Test("Skipping the welcome persists only in its injected defaults")
@MainActor func fileAccessSkipIsPersistentAndIsolated() throws {
  let suite = "qa.lighten.welcome.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let first = OnboardingPreferences(defaults: defaults)
  #expect(first.shouldPresent(for: .notGranted))
  #expect(!first.shouldPresent(for: nil))
  first.dismiss()
  #expect(!OnboardingPreferences(defaults: defaults).shouldPresent(for: .notGranted))
  let processOnly = OnboardingPreferences(defaults: nil)
  #expect(processOnly.shouldPresent(for: .notGranted))
  processOnly.dismiss()
  #expect(!processOnly.shouldPresent(for: .notGranted))
}

@MainActor private final class FeedbackSleep {
  var duration: Duration?
  private var continuation: CheckedContinuation<Void, Never>?
  private var waiting: CheckedContinuation<Void, Never>?

  func sleep(_ duration: Duration) async {
    self.duration = duration
    await withCheckedContinuation {
      continuation = $0
      waiting?.resume()
      waiting = nil
    }
  }

  func waitForRequest() async {
    if continuation != nil { return }
    await withCheckedContinuation { waiting = $0 }
  }

  func finish() {
    continuation?.resume()
    continuation = nil
  }
}

@Test("Trash feedback remains visible until its six second expiry")
@MainActor func actionFeedbackHasSixSecondLifetime() async throws {
  let clock = FeedbackSleep()
  let state = ActionFeedbackState(sleep: { await clock.sleep($0) })
  let plan = UUID()
  state.show(planID: plan, kind: .trash, appliedCount: 1, message: "Moved")
  let feedback = try #require(state.presentation)
  let timer = Task { await state.expire(feedback.id) }
  await clock.waitForRequest()
  #expect(clock.duration == .seconds(6))
  #expect(state.presentation?.planID == plan)
  #expect(state.presentation?.offersUndo == true)
  clock.finish()
  await timer.value
  #expect(state.presentation == nil)
}

@Test("Old, cancelled, and manually dismissed feedback timers cannot dismiss a new result")
@MainActor func actionFeedbackExpiryIsGenerationSafe() async throws {
  let clock = FeedbackSleep()
  let state = ActionFeedbackState(sleep: { await clock.sleep($0) })
  state.show(planID: UUID(), kind: .trash, appliedCount: 1, message: "Moved")
  let original = try #require(state.presentation)
  let timer = Task { await state.expire(original.id) }
  await clock.waitForRequest()
  state.dismiss()
  #expect(state.presentation == nil)
  let newer = UUID()
  state.show(planID: newer, kind: .trash, appliedCount: 2, message: "Moved again")
  timer.cancel()
  clock.finish()
  await timer.value
  #expect(state.presentation?.planID == newer)
  let oldTimer = Task { await state.expire(original.id) }
  await clock.waitForRequest()
  clock.finish()
  await oldTimer.value
  #expect(state.presentation?.planID == newer)
}

@Test("Permanent feedback says irreversible and refused results do not produce success feedback")
@MainActor func actionFeedbackPermanentAndRefusedResults() throws {
  let state = ActionFeedbackState()
  state.show(planID: UUID(), kind: .trash, appliedCount: 0, message: "Refused")
  #expect(state.presentation == nil)
  state.show(planID: UUID(), kind: .catalogDelete, appliedCount: 1, message: "Removed")
  let feedback = try #require(state.presentation)
  #expect(!feedback.offersUndo)
  #expect(feedback.message.contains(String(localized: "This action cannot be undone.")))
}

@Test("Sidebar and grid share one catalog containing only current screens")
@MainActor func toolCatalogHasCurrentScreensOnly() {
  #expect(Set(ToolCatalog.entries.map(\.id)) == Set(LightenSection.allCases))
  #expect(ToolCatalog.entries.count == 7)
  #expect(ToolCatalog.gridEntries.count == 6)
  #expect(!ToolCatalog.gridEntries.contains { $0.id == .tools })
  let summary = ToolSummary(count: 3, logicalBytes: 1000, observedAt: Date(), partial: true)
  let presentation = ToolPresentation(phase: .partial, summary: summary)
  #expect(presentation.resultText.hasPrefix(String(localized: "At least")))
  #expect(ToolPresentation(phase: .scanning, summary: summary).isWorking)
  #expect(ToolPresentation(phase: .preparing, summary: summary).isWorking)
}
