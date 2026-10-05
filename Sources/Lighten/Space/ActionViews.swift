import AppKit
import LightenKit
import SwiftUI

struct ConfirmationView: View {
  private let initialPresentation: ActionPresentation
  @Bindable var actions: ActionStore

  init(presentation: ActionPresentation, actions: ActionStore) {
    initialPresentation = presentation
    self.actions = actions
  }

  private var presentation: ActionPresentation {
    if let current = actions.pending, current.id == initialPresentation.id { return current }
    return initialPresentation
  }
  @Environment(\.dismiss) private var dismiss
  @State private var confirmingPermanent = false
  @State private var permanentPresentation: ActionPresentation?
  @State private var returnToTrashAfterCancel = false

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
            : String(localized: "Permanent deletion cannot be undone.")
        )
        .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)
      Divider()
      List {
        ForEach(ConfirmationItemGroup.make(presentation.items)) { group in
          Section {
            ForEach(group.items, id: \.id) { item in
              confirmationItem(item)
            }
          } header: {
            if let app = group.application {
              HStack(spacing: 10) {
                ApplicationIconView(path: app.path)
                Text(app.name).font(.headline)
                Spacer()
                Text(PlanItemSize.text(group.size.logical)).monospacedDigit()
              }
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("removal.app-group.\(app.path)")
            } else if ConfirmationItemGroup.make(presentation.items).contains(where: { $0.application != nil }) {
              Text(String(localized: "Other selected items"))
            }
          }
        }
        if !presentation.rejectedItems.isEmpty {
          Section(String(localized: "Skipped items — will stay in place")) {
            ForEach(Array(presentation.rejectedItems.enumerated()), id: \.offset) { _, rejection in
              FailureReasonView(presentation: FailureText.presentation(rejection), path: rejection.path)
            }
          }
        }
      }
      Divider()
      HStack {
        Button(
          presentation.hasRunningApplications
            ? String(localized: "Close and permanently delete") : String(localized: "Permanently delete"),
          action: requestPermanentRemoval
        )
        .buttonStyle(.bordered)
        .disabled(actions.busy || actions.preparingAlternate)
        Spacer(minLength: 24)
        Button(String(localized: "Cancel")) {
          actions.pending = nil
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button(primaryButtonTitle, action: requestTrashRemoval)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(actions.busy || actions.preparingAlternate)
      }
      .padding(16)
    }
    .tint(LightenStyle.accent)
    .frame(width: 560, height: 420)
    .confirmationDialog(
      String(localized: "Permanently delete these items?"), isPresented: $confirmingPermanent,
      titleVisibility: .visible
    ) {
      Button(
        (permanentPresentation ?? presentation).hasRunningApplications
          ? String(localized: "Close and permanently delete") : String(localized: "Permanently delete — cannot undo"),
        role: .destructive
      ) {
        confirm(permanent: true, selection: permanentPresentation)
      }
      Button(String(localized: "Cancel"), role: .cancel) {
        if returnToTrashAfterCancel, let pending = actions.pending {
          Task { await actions.requestTrash(pending) }
        }
        permanentPresentation = nil
      }
    } message: {
      Text(String(localized: "This deletes the selected items without using Trash. This cannot be undone."))
    }
  }

  private func confirmationItem(_ item: ActionItemSummary) -> some View {
    HStack(alignment: .top, spacing: 12) {
      if item.path == item.applicationGroup?.path {
        ApplicationIconView(path: item.path)
      } else {
        Image(systemName: "doc").foregroundStyle(LightenStyle.muted)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(item.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
        if let warning = item.warning {
          Text(SpaceText.warning(warning, paths: Array(item.warningPaths.prefix(1))))
            .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
            .fixedSize(horizontal: false, vertical: true)
        } else if let example = presentation.plan.items.first(where: { $0.id == item.id })?
          .userSelectionWarnings?.first?.examplePath
        {
          Text(
            String(localized: "This selection may contain personal or sensitive data. Check it before removal.")
              + " — " + example
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
          .fixedSize(horizontal: false, vertical: true)
        }
        Text(item.path).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          .lineLimit(1).truncationMode(.middle).help(item.path)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        Text(PlanItemSize.text(item.observedSize.logical)).font(.system(size: 13, weight: .medium))
      }
      .monospacedDigit()
    }
    .padding(.vertical, 3)
  }

  private var primaryButtonTitle: String {
    presentation.hasRunningApplications
      ? String(localized: "Close and move to Trash") : String(localized: "Move to Trash")
  }

  private func requestPermanentRemoval() {
    if presentation.plan.kind == .catalogDelete {
      permanentPresentation = presentation
      returnToTrashAfterCancel = false
      confirmingPermanent = true
    } else {
      Task {
        await actions.requestPermanent(presentation)
        guard let permanent = actions.pending, permanent.plan.kind == .catalogDelete else { return }
        permanentPresentation = permanent
        returnToTrashAfterCancel = true
        confirmingPermanent = true
      }
    }
  }

  private func requestTrashRemoval() {
    if presentation.plan.kind == .catalogDelete {
      Task { await actions.requestTrash(presentation) }
    } else {
      confirm(permanent: false)
    }
  }

  private func confirm(permanent: Bool, selection: ActionPresentation? = nil) {
    let selected = selection ?? presentation
    guard
      let plan = actions.takeConfirmedPlan(
        selected, permanentConfirmed: permanent,
        closeRunningApplications: selected.hasRunningApplications)
    else { return }
    dismiss()
    Task { await actions.executeConfirmed(plan) }
  }
}

struct ActionFeedbackView: View {
  @Bindable var actions: ActionStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if let summary = actions.completedSummary {
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(summary).font(.system(size: 12, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          if !actions.latestTrashPaths.isEmpty {
            Button(String(localized: "Show in Trash")) {
              NSWorkspace.shared.activateFileViewerSelecting(actions.latestTrashPaths.map { URL(fileURLWithPath: $0) })
            }
          }
        }
        if actions.resultKind == .trash && actions.canUndoLatest {
          Text(String(localized: "Empty Trash to free disk space."))
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        }
        if !actions.resultFailures.isEmpty || !actions.resultRejections.isEmpty {
          if actions.result == nil {
            Text(String(localized: "Items that stayed in place"))
              .font(.system(size: 11, weight: .medium))
            failureReasons
          } else {
            DisclosureGroup(
              actions.unverifiedResultCount > 0
                ? String(localized: "Items needing review") : String(localized: "Items that stayed in place")
            ) {
              failureReasons
            }
            .font(.system(size: 11))
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("action.completed-result")
      .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
    }
  }

  private var failureReasons: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(actions.resultRejections, id: \.path) { rejection in
        FailureReasonView(presentation: FailureText.presentation(rejection), path: rejection.path)
      }
      ForEach(actions.resultFailures, id: \.itemID) { item in
        if let presentation = item.presentation {
          FailureReasonView(presentation: presentation, path: item.path)
        } else {
          Text(item.detail).font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
            .fixedSize(horizontal: false, vertical: true).help(item.path)
        }
      }
    }
  }
}

struct HistoryView: View {
  @Bindable var actions: ActionStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ToolScreen(String(localized: "History")) {
      GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 0) {
          Text(String(localized: "History shows actions taken in Lighten."))
            .font(.callout).foregroundStyle(LightenStyle.muted).padding(.bottom, 12)
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
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
                    .help(
                      String(localized: "The original history is kept. Items still in Trash keep their Undo action."))
                  }
                  .padding(.bottom, 12)
                }
                if let message = actions.message {
                  Text(message)
                    .font(.system(size: 12)).foregroundStyle(LightenStyle.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                }
                ActionFeedbackView(actions: actions).padding(.bottom, 12)
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
                        if plan.canUndo {
                          Button(String(localized: "Undo")) {
                            Task {
                              await actions.undo(plan)
                              proxy.scrollTo(plan.id, anchor: .top)
                            }
                          }
                          .buttonStyle(.bordered)
                          .disabled(actions.busy || actions.loadingHistoryGroups.contains(plan.id))
                          .accessibilityLabel(String(localized: "Undo") + " " + title(plan))
                          .accessibilityIdentifier("history.undo.\(plan.id.uuidString)")
                        }
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
                      .accessibilityElement(children: .contain)
                    }
                    .id(plan.id)
                    .accessibilityIdentifier("history.group.\(plan.id.uuidString)")
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    Divider()
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
          }
        }
        .padding(.vertical, 12)
        // History content must not increase the split view's minimum window height.
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      }
    } toolbar: {
      Button(String(localized: "Refresh")) { Task { await actions.reloadHistory() } }
        .disabled(actions.busy)
        .accessibilityIdentifier("history.refresh")
    }
    .tint(LightenStyle.accent)
    .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: actions.displayRevision)
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
        FailureReasonView(presentation: FailureText.presentation(detail))
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

/// App membership is supplied by the selection that created the review.
struct ConfirmationItemGroup: Identifiable {
  let id: String
  let application: ActionApplicationGroup?
  var items: [ActionItemSummary]
  var size: ObservedPlanSize { ObservedPlanSize.total(items.map(\.observedSize)) }

  static func make(_ items: [ActionItemSummary]) -> [Self] {
    var groups: [Self] = []
    for item in items {
      let id = item.applicationGroup.map { "app:" + $0.path } ?? "other-selected-items"
      if let index = groups.firstIndex(where: { $0.id == id }) {
        groups[index].items.append(item)
      } else {
        groups.append(Self(id: id, application: item.applicationGroup, items: [item]))
      }
    }
    return groups
  }
}
