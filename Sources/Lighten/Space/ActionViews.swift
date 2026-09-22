import LightenKit
import SwiftUI

struct ConfirmationView: View {
  let presentation: ActionPresentation
  @Bindable var actions: ActionStore
  @Environment(\.dismiss) private var dismiss

  private var logical: Int64 {
    presentation.items.reduce(0) { $0 + ($1.logicalBytes ?? 0) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        Text(String(localized: "Review removal"))
          .font(.system(size: 21, weight: .semibold))
        Text("\(presentation.items.count) \(String(localized: "items")) · \(format(logical))")
          .font(.system(size: 16, weight: .medium)).monospacedDigit()
        Text(
          String(
            localized: "These items move to macOS Trash. Space is not freed until Trash is emptied outside Lighten.")
        )
        .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)
      Divider()
      List(presentation.items, id: \.id) { item in
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "doc").foregroundStyle(LightenStyle.muted)
          VStack(alignment: .leading, spacing: 3) {
            Text(item.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(item.reason).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
            Text(item.path).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
              .lineLimit(1).truncationMode(.middle).help(item.path)
          }
          Spacer(minLength: 8)
          VStack(alignment: .trailing, spacing: 2) {
            Text(format(item.logicalBytes)).font(.system(size: 13, weight: .medium))
            Text(String(localized: "Logical")).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          }
          .monospacedDigit()
        }
        .padding(.vertical, 3)
      }
      Divider()
      HStack {
        Button(String(localized: "Cancel")) {
          actions.pending = nil
          dismiss()
        }
        Spacer()
        Button(String(localized: "Move to Trash")) {
          guard let confirmedPlan = actions.takeConfirmedPlan(presentation) else { return }
          dismiss()
          Task { await actions.executeConfirmed(confirmedPlan) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(actions.busy)
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
          Text(String(localized: "History")).font(.system(size: 21, weight: .semibold))
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
        Text(format(actions.pendingTrashLogicalBytes))
          .font(.system(size: 17, weight: .semibold)).monospacedDigit()
      }
      Text(String(localized: "Trash items have not freed disk space."))
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        .padding(.top, 3).padding(.bottom, 12)
      if let issues = actions.history?.issues, !issues.isEmpty {
        ForEach(issues, id: \.line) { issue in
          Text("\(String(localized: "Journal issue")) \(issue.line): \(issue.reason)")
            .font(.system(size: 12)).foregroundStyle(.red)
            .padding(.bottom, 5)
        }
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
      List {
        ForEach(actions.history?.items ?? [], id: \.itemID) { item in
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              Text(
                actions.historyMetadata[item.itemID].map {
                  URL(fileURLWithPath: $0.path).lastPathComponent
                } ?? item.itemID.uuidString
              )
              .font(.system(size: 13, weight: .medium)).lineLimit(1)
              if let metadata = actions.historyMetadata[item.itemID] {
                Text(metadata.path)
                  .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
                  .lineLimit(1).truncationMode(.middle).help(metadata.path)
              }
              if let detail = item.detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(LightenStyle.muted).lineLimit(2)
              }
            }
            Spacer(minLength: 5)
            Text(format(actions.historyMetadata[item.itemID]?.logicalBytes))
              .font(.system(size: 12)).monospacedDigit()
              .frame(width: 90, alignment: .trailing)
            Text(status(item.state))
              .font(.system(size: 12)).foregroundStyle(statusColor(item.state))
              .frame(width: 105, alignment: .trailing)
            if item.state == .inTrash {
              Button(String(localized: "Undo")) { Task { await actions.undo(item) } }
                .disabled(actions.busy)
            }
          }
          .padding(.vertical, 4)
        }
      }
      if let result = actions.result {
        Text("\(String(localized: "Last result")): \(result.items.map { status($0.outcome) }.joined(separator: ", "))")
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          .padding(.top, 8)
      }
    }
    .padding(18)
    .background(LightenStyle.canvas)
    .tint(LightenStyle.accent)
    .navigationTitle(String(localized: "History"))
    .task { await actions.reloadHistory() }
  }

  private func statusColor(_ state: HistoryState) -> Color {
    switch state {
    case .uncertain, .failed: .orange
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
    }
  }

  private func status(_ outcome: ActionOutcome) -> String {
    switch outcome {
    case .applied: String(localized: "Moved to Trash")
    case .skipped: String(localized: "Skipped")
    case .failed: String(localized: "Failed")
    case .uncertain: String(localized: "Uncertain")
    case .notAttempted: String(localized: "Not attempted")
    }
  }
}
