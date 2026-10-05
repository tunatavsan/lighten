import Foundation
import LightenKit
import Observation
import SwiftUI

struct ActionFeedback: Identifiable {
  let id: UUID
  let planID: UUID
  let message: String
  let offersUndo: Bool
}

@MainActor @Observable final class ActionFeedbackState {
  @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
  private(set) var presentation: ActionFeedback?

  init(sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
    self.sleep = sleep
  }

  func show(planID: UUID, kind: ActionKind, appliedCount: Int, message: String) {
    guard appliedCount > 0 else { return }
    presentation = ActionFeedback(
      id: UUID(), planID: planID,
      message: kind == .trash ? message : message + " " + String(localized: "This action cannot be undone."),
      offersUndo: kind == .trash)
  }

  func dismiss() { presentation = nil }

  func expire(_ id: UUID) async {
    do { try await sleep(.seconds(6)) } catch { return }
    guard !Task.isCancelled, presentation?.id == id else { return }
    presentation = nil
  }
}

/// The result of an action as a glass capsule over the bottom of the window, with Undo while it applies.
struct ActionFeedbackToast: View {
  let feedback: ActionFeedback
  let actions: ActionStore
  let dismiss: () -> Void

  var body: some View {
    GlassEffectContainer(spacing: Theme.Space.s) {
      HStack(spacing: Theme.Space.m) {
        Image(systemName: feedback.offersUndo ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .font(Theme.Font.icon)
          .foregroundStyle(feedback.offersUndo ? Theme.Palette.positive : Theme.Palette.warning)
          .accessibilityHidden(true)
        Text(feedback.message).font(Theme.Font.calloutMedium).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        if feedback.offersUndo {
          Button(String(localized: "Undo")) { Task { await actions.undoLatest() } }
            .buttonStyle(.glass)
            .disabled(actions.busy || !actions.canUndoLatest || actions.result?.planID != feedback.planID)
        }
        Button(action: dismiss) {
          Image(systemName: "xmark").font(Theme.Font.iconSmall).foregroundStyle(Theme.Palette.inkSecondary)
        }
        .buttonStyle(.plain).accessibilityLabel(String(localized: "Dismiss"))
      }
      .padding(.leading, Theme.Space.l).padding(.trailing, Theme.Space.m)
      .padding(.vertical, Theme.Space.s + 2)
      .lightenGlass(.chrome, in: Capsule())
    }
    .frame(maxWidth: Theme.Layout.floatingBarMaximum)
    .padding(Theme.Space.xl)
    .accessibilityElement(children: .contain)
  }
}
