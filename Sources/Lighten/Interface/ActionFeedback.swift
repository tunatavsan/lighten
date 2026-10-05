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

struct ActionFeedbackToast: View {
  @Environment(\.colorSchemeContrast) private var contrast
  let feedback: ActionFeedback
  let actions: ActionStore
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 16) {
      Label(feedback.message, systemImage: feedback.offersUndo ? "checkmark.circle" : "exclamationmark.circle")
        .font(.callout).fixedSize(horizontal: false, vertical: true)
      if feedback.offersUndo {
        Button(String(localized: "Undo")) { Task { await actions.undoLatest() } }
          .disabled(actions.busy || !actions.canUndoLatest || actions.result?.planID != feedback.planID)
      }
      Button(action: dismiss) { Image(systemName: "xmark") }
        .buttonStyle(.plain).accessibilityLabel(String(localized: "Dismiss"))
    }
    .padding(16)
    .background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(
          contrast == .increased ? Color.primary : LightenStyle.separator,
          lineWidth: contrast == .increased ? 1.5 : 0.5)
    }
    .frame(maxWidth: 720)
    .padding(24)
  }
}
