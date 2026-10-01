import AppKit
import LightenKit
import SwiftUI

struct ConfirmationView: View {
  let presentation: ActionPresentation
  @Bindable var actions: ActionStore
  @Environment(\.dismiss) private var dismiss

  private var logicalSummary: String {
    let logical = ObservedPlanSize.total(presentation.items.map(\.observedSize)).logical
    let summary = PlanItemSize.text(logical)
    let unknownCount = presentation.items.filter { $0.observedSize.logical == nil }.count
    if logical != nil, unknownCount > 0 {
      return "\(summary) · \(unknownCount) \(String(localized: "sizes unknown"))"
    }
    return summary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        Text(String(localized: "Review removal"))
          .font(.system(size: 21, weight: .semibold))
        Text("\(presentation.items.count) \(String(localized: "items")) · \(logicalSummary)")
          .font(.system(size: 16, weight: .medium)).monospacedDigit()
        Text(
          presentation.plan.kind == .trash
            ? String(
              localized: "These items move to macOS Trash. Space is not freed until Trash is emptied outside Lighten.")
            : String(localized: "Permanent cleanup cannot be undone. Cached data may need to be downloaded or rebuilt.")
        )
        .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)
      Divider()
      List {
        ForEach(presentation.items, id: \.id) { item in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc").foregroundStyle(LightenStyle.muted)
            VStack(alignment: .leading, spacing: 3) {
              Text(item.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
              Text(item.reason).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
              if let warning = item.warning {
                Label(String(localized: "Check before removing"), systemImage: "exclamationmark.triangle.fill")
                  .font(.system(size: 11, weight: .semibold)).foregroundStyle(LightenStyle.warning)
                Text(SpaceText.warning(warning))
                  .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Text(item.path).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
                .lineLimit(1).truncationMode(.middle).help(item.path)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
              Text(PlanItemSize.text(item.observedSize.logical)).font(.system(size: 13, weight: .medium))
              Text(String(localized: "Logical")).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
            }
            .monospacedDigit()
          }
          .padding(.vertical, 3)
        }
        if !presentation.rejectedItems.isEmpty {
          Section(String(localized: "Skipped items — will stay in place")) {
            ForEach(Array(presentation.rejectedItems.enumerated()), id: \.offset) { _, rejection in
              Text(SpaceText.rejection(rejection))
                .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
          }
        }
      }
      Divider()
      HStack {
        Button(String(localized: "Cancel")) {
          actions.pending = nil
          dismiss()
        }
        Spacer()
        if presentation.permanentPlanBuilder != nil {
          Button(String(localized: "Permanently clean instead")) {
            Task { await actions.requestPermanent(presentation) }
          }
          .disabled(actions.busy || actions.preparingAlternate)
        }
        Button(
          presentation.plan.kind == .trash
            ? String(localized: "Move to Trash")
            : String(localized: "Permanently clean — cannot undo")
        ) {
          guard let confirmedPlan = actions.takeConfirmedPlan(presentation) else { return }
          dismiss()
          Task { await actions.executeConfirmed(confirmedPlan) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(actions.busy || actions.preparingAlternate)
      }
      .padding(16)
    }
    .tint(LightenStyle.accent)
    .frame(width: 560, height: 420)
  }
}

struct HistoryView: View {
  @Bindable var actions: ActionStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(String(localized: "History")).font(.system(size: 24, weight: .semibold))
          Text(String(localized: "History shows actions taken in Lighten."))
            .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
        }
        Spacer()
        Button(String(localized: "Refresh")) { Task { await actions.reloadHistory() } }
      }
      .padding(.bottom, 18)
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(String(localized: "Pending Trash"))
          .font(.system(size: 13, weight: .medium))
        Text("\(actions.pendingTrashCount) \(String(localized: "items"))")
          .font(.system(size: 13)).monospacedDigit()
        Spacer()
        Text(PlanItemSize.text(actions.pendingTrashSize.logical))
          .font(.system(size: 17, weight: .semibold)).monospacedDigit()
      }
      Text(String(localized: "Trash items have not freed disk space."))
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        .padding(.top, 3).padding(.bottom, 12)
      if let issues = actions.history?.issues, !issues.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(String(localized: "Some history records could not be read. Archive them to continue safely."))
            .font(.system(size: 12)).foregroundStyle(LightenStyle.warning)
          Button(String(localized: "Archive history and start again")) {
            Task { await actions.repairHistory() }
          }
          .disabled(actions.busy)
          .help(String(localized: "The original history is kept. Items still in Trash keep their Undo action."))
        }
        .padding(.bottom, 12)
      }
      if let message = actions.message {
        Text(message)
          .font(.system(size: 12)).foregroundStyle(LightenStyle.warning)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 12)
      }
      Divider()
      HStack {
        Text(String(localized: "Name"))
        Spacer()
        Text(String(localized: "Size"))
          .frame(width: 90, alignment: .trailing)
        Text(String(localized: "Status"))
          .frame(width: 105, alignment: .trailing)
      }
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(LightenStyle.muted)
      .padding(.horizontal, 8).padding(.vertical, 9)
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          // Newest first: the action just taken, and its Undo, are at the top.
          ForEach((actions.history?.plans ?? []).reversed()) { plan in
            DisclosureGroup(
              isExpanded: Binding(
                get: { actions.expandedHistoryGroups.contains(plan.id) },
                set: { expanded in Task { await actions.setHistoryGroupExpanded(plan.id, expanded: expanded) } }
              )
            ) {
              if actions.loadingHistoryGroups.contains(plan.id) {
                ProgressView(String(localized: "Loading history details…"))
                  .controlSize(.small)
              }
              if plan.detailsLoaded {
                ForEach(plan.items, id: \.itemID) { item in
                  historyItem(item, plan: plan)
                }
                if plan.canUndo {
                  HStack {
                    Spacer()
                    Button(String(localized: "Undo")) { Task { await actions.undo(plan) } }
                      .buttonStyle(.bordered)
                      .disabled(actions.busy || actions.loadingHistoryGroups.contains(plan.id))
                      .accessibilityLabel(String(localized: "Undo") + " " + title(plan))
                      .accessibilityIdentifier("history.undo.\(plan.id.uuidString)")
                  }
                }
              }
            } label: {
              HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(title(plan))
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                  Text(plan.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
                  if plan.metadata.count == 1, let path = plan.metadata.first?.sourcePath {
                    Text(path)
                      .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
                      .lineLimit(1).truncationMode(.middle).help(path)
                  }
                  if plan.kind == .catalogDelete {
                    Text(String(localized: "Undo unavailable — permanently cleaned"))
                      .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
                  }
                  if plan.deletedCount > 0 {
                    Text(
                      "\(plan.deletedCount) \(String(localized: "entries removed")) · \(format(plan.deletedLogicalBytes))"
                    )
                    .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
                  }
                }
                Spacer(minLength: 5)
                Text(
                  plan.deletedCount > 0
                    ? format(plan.deletedLogicalBytes) : PlanItemSize.text(actions.historySize(plan).logical)
                )
                .font(.system(size: 12)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)
                Text(status(plan.state))
                  .font(.system(size: 12)).foregroundStyle(statusColor(plan.state))
                  .frame(width: 105, alignment: .trailing)
              }
              .accessibilityElement(children: .combine)
            }
            .accessibilityIdentifier("history.group.\(plan.id.uuidString)")
            .padding(.horizontal, 8).padding(.vertical, 7)
            Divider()
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      if let result = actions.result {
        Text(
          "\(String(localized: "Last result")): \(result.items.map { status($0.outcome, kind: actions.resultKind) }.joined(separator: ", "))"
        )
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        .padding(.top, 8)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(LightenStyle.canvas)
    .tint(LightenStyle.accent)
    .navigationTitle(String(localized: "History"))
    .task { await actions.reloadHistory() }
  }

  private func title(_ plan: HistoryPlan) -> String {
    if plan.metadata.count == 1, let path = plan.metadata.first?.sourcePath {
      return URL(fileURLWithPath: path).lastPathComponent
    }
    let completed =
      plan.kind == .trash
      ? String(localized: "items moved") : String(localized: "items completed")
    return "\(plan.appliedCount) \(completed)"
  }

  private func historyItem(_ item: HistoryItem, plan: HistoryPlan) -> some View {
    let path = plan.metadata.first { $0.id == item.itemID }?.sourcePath
    let size = plan.metadata.first { $0.id == item.itemID }?.displaySize ?? .unknown
    let showProblem = item.state == .inTrash ? !item.canUndo : item.state != .reversed
    let detail =
      showProblem
      ? actions.undoResults[plan.id]?.items.first { $0.itemID == item.itemID }?.detail ?? item.detail : nil
    return VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(path ?? item.itemID.uuidString)
          .font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
          .textSelection(.enabled)
        Spacer(minLength: 4)
        Text(PlanItemSize.text(size.logical)).font(.system(size: 10)).monospacedDigit()
        Text(status(item.state))
          .font(.system(size: 10)).foregroundStyle(statusColor(item.state))
      }
      if let detail {
        Text(FailureText.describe(detail))
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
      if item.detail == String(describing: UndoFailure.trashItemMissing) {
        HStack {
          Text(SpaceText.trashMissing())
            .font(.system(size: 10)).foregroundStyle(LightenStyle.warning)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          Button(String(localized: "Show Trash in Finder")) {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
          }
          .buttonStyle(.link)
        }
      }
      if item.state == .inTrash && !item.canUndo {
        Text(String(localized: "Cannot restore yet. Resolve the reason above, then refresh History."))
          .font(.system(size: 10)).foregroundStyle(LightenStyle.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.leading, 10).padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("history.item.\(item.itemID.uuidString)")
  }

  private func statusColor(_ state: HistoryState) -> Color {
    switch state {
    case .uncertain, .failed: LightenStyle.warning
    case .inTrash: LightenStyle.accent
    default: LightenStyle.muted
    }
  }

  private func status(_ state: HistoryState) -> String {
    switch state {
    case .atSource: String(localized: "At source")
    case .inTrash: String(localized: "In Trash")
    case .reversed: String(localized: "Restored")
    case .failed: String(localized: "Failed")
    case .skipped: String(localized: "Skipped")
    case .uncertain: String(localized: "Uncertain")
    case .deleted: String(localized: "Permanently cleaned")
    case .partiallyDeleted: String(localized: "Partially cleaned")
    }
  }

  private func status(_ outcome: ActionOutcome, kind: ActionKind?) -> String {
    switch outcome {
    case .applied:
      kind == .catalogDelete
        ? String(localized: "Permanently cleaned") : String(localized: "Moved to Trash")
    case .skipped: String(localized: "Skipped")
    case .failed: String(localized: "Failed")
    case .uncertain: String(localized: "Uncertain")
    case .notAttempted: String(localized: "Not attempted")
    }
  }
}
