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
      HStack(alignment: .top, spacing: Theme.Space.m) {
        Image(systemName: presentation.plan.kind == .trash ? "trash.circle.fill" : "exclamationmark.octagon.fill")
          .font(Theme.Font.iconLarge)
          .foregroundStyle(presentation.plan.kind == .trash ? Theme.Palette.accent : Theme.Palette.critical)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
          Text(String(localized: "Review removal")).font(Theme.Font.title)
          Text("\(presentation.items.count) \(String(localized: "items")) · \(logicalSummary)")
            .font(Theme.Font.metricSmall).monospacedDigit().foregroundStyle(Theme.Palette.heroText)
          Text(
            presentation.plan.kind == .trash
              ? String(
                localized: "These items move to macOS Trash. Space is not freed until Trash is emptied outside Lighten."
              )
              : String(localized: "Permanent deletion cannot be undone.")
          )
          .font(Theme.Font.callout)
          .foregroundStyle(presentation.plan.kind == .trash ? Theme.Palette.inkSecondary : Theme.Palette.critical)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(Theme.Space.xl)
      RowDivider()
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
          if !presentation.reviewNotes.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
              Text(String(localized: "Review notes")).font(Theme.Font.headline)
              Text(presentation.reviewNotes.joined(separator: "\n"))
                .font(Theme.Font.callout).foregroundStyle(Theme.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityIdentifier("removal.review-notes")
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.neutralTint, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
          }
          let groups = ConfirmationItemGroup.make(presentation.items)
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 0) {
              if let app = group.application {
                HStack(spacing: Theme.Space.m) {
                  ApplicationIconView(path: app.path)
                  Text(app.name).font(Theme.Font.headline)
                  Spacer()
                  Text(PlanItemSize.text(group.size.logical)).font(Theme.Font.mono)
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("removal.app-group.\(app.path)")
                RowDivider()
              } else if groups.contains(where: { $0.application != nil }) {
                Text(String(localized: "Other selected items")).font(Theme.Font.headline)
                  .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                RowDivider()
              }
              ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider(leading: Theme.Layout.rowTextInset) }
                confirmationItem(item)
              }
            }
            .moduleSurface()
          }
          if !presentation.rejectedItems.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
              Text(String(localized: "Skipped items — will stay in place")).font(Theme.Font.headline)
              VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(Array(presentation.rejectedItems.enumerated()), id: \.offset) { _, rejection in
                  FailureReasonView(presentation: FailureText.presentation(rejection), path: rejection.path)
                }
              }
              .padding(Theme.Space.m)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Theme.Palette.warningTint, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
          }
        }
        .padding(Theme.Space.xl)
      }
      .frame(minHeight: 0, maxHeight: .infinity)
      RowDivider()
      HStack {
        Button(
          presentation.hasRunningApplications
            ? String(localized: "Close and permanently delete") : String(localized: "Permanently delete"),
          action: requestPermanentRemoval
        )
        .foregroundStyle(Theme.Palette.critical)
        .disabled(actions.busy || actions.preparingAlternate)
        Spacer(minLength: Theme.Space.xl)
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
      .controlSize(.large)
      .padding(Theme.Space.l)
    }
    .background(Theme.Palette.canvas)
    .tint(Theme.Palette.accent)
    .frame(width: Theme.Layout.sheetWidth, height: Theme.Layout.sheetHeight)
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
    HStack(alignment: .top, spacing: Theme.Space.m) {
      Group {
        if item.path == item.applicationGroup?.path {
          ApplicationIconView(path: item.path, size: Theme.Layout.rowIcon)
        } else {
          Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable()
            .frame(width: Theme.Layout.rowIcon, height: Theme.Layout.rowIcon)
        }
      }
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Space.xxs) {
        Text(item.label).font(Theme.Font.bodyMedium).lineLimit(1)
        if let warning = item.warning {
          Label(
            SpaceText.warning(warning, paths: Array(item.warningPaths.prefix(1))),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning)
          .fixedSize(horizontal: false, vertical: true)
        } else if let example = presentation.plan.items.first(where: { $0.id == item.id })?
          .userSelectionWarnings?.first?.examplePath
        {
          Label(
            String(localized: "This selection may contain personal or sensitive data. Check it before removal.")
              + " — " + example,
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning)
          .fixedSize(horizontal: false, vertical: true)
        }
        PathLabel(path: item.path)
      }
      Spacer(minLength: Theme.Space.s)
      Text(PlanItemSize.text(item.observedSize.logical)).font(Theme.Font.mono).foregroundStyle(Theme.Palette.ink)
    }
    .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
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

/// The latest action's result on one line: what happened, where it went, and any item that stayed,
/// each with its full reason in a popover.
struct ActionFeedbackView: View {
  @Bindable var actions: ActionStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if let summary = actions.completedSummary {
      let problems = actions.resultFailures.count + actions.resultRejections.count
      HStack(spacing: Theme.Space.s) {
        Image(systemName: problems > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
          .font(Theme.Font.iconSmall)
          .foregroundStyle(problems > 0 ? Theme.Palette.warning : Theme.Palette.positive)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
          Text(summary).font(Theme.Font.calloutMedium).lineLimit(2)
          if actions.resultKind == .trash && actions.canUndoLatest {
            Text(String(localized: "Empty Trash to free disk space."))
              .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
          }
        }
        .help(summary)
        Spacer(minLength: Theme.Space.s)
        if problems > 0 {
          DetailChip(
            actions.result != nil && actions.unverifiedResultCount > 0
              ? String(localized: "Items needing review") : String(localized: "Items that stayed in place"),
            symbol: "exclamationmark.triangle.fill"
          ) {
            failureReasons
          }
        }
        if !actions.latestTrashPaths.isEmpty {
          Button(String(localized: "Show in Trash")) {
            NSWorkspace.shared.activateFileViewerSelecting(actions.latestTrashPaths.map { URL(fileURLWithPath: $0) })
          }
          .controlSize(.small)
        }
      }
      .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
      .background(
        problems > 0 ? Theme.Palette.warningTint : Theme.Palette.positiveTint,
        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
      )
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("action.completed-result")
      .transition(Theme.Motion.transition(Theme.Motion.rise, reduceMotion: reduceMotion))
    }
  }

  private var failureReasons: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      ForEach(actions.resultRejections, id: \.path) { rejection in
        FailureReasonView(presentation: FailureText.presentation(rejection), path: rejection.path)
      }
      ForEach(actions.resultFailures, id: \.itemID) { item in
        if let presentation = item.presentation {
          FailureReasonView(presentation: presentation, path: item.path)
        } else {
          Text(item.detail).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning)
            .fixedSize(horizontal: false, vertical: true).help(item.path)
        }
      }
    }
  }
}

struct HistoryView: View {
  @Bindable var actions: ActionStore
  /// How the screen asks for a fresh read of history; the window shares one so reads never overlap.
  var reload: (() async -> Void)?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ToolScreen(String(localized: "History"), subtitle: String(localized: "History shows actions taken in Lighten.")) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            if let issues = actions.history?.issues, !issues.isEmpty {
              NoticeBar(String(localized: "Some history records could not be read. Archive them to continue safely.")) {
                Button(String(localized: "Archive history and start again")) {
                  Task { await actions.repairHistory() }
                }
                .disabled(actions.busy)
                .help(String(localized: "The original history is kept. Items still in Trash keep their Undo action."))
              }
            }
            if let message = actions.message {
              NoticeBar(message).textSelection(.enabled)
            }
            ActionFeedbackView(actions: actions)
            let plans = (actions.history?.plans ?? []).reversed()
            if plans.isEmpty {
              EmptyState(
                symbol: "clock.arrow.circlepath", title: String(localized: "No actions yet"),
                message: String(localized: "Items you move to Trash appear here, ready to restore."),
                tint: Theme.Palette.toolHistory)
            } else {
              VStack(spacing: 0) {
                // Newest first: the action just taken, and its Undo, are at the top.
                ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                  if index > 0 { RowDivider(leading: Theme.Layout.rowTextInset) }
                  planRow(plan, proxy: proxy)
                }
              }
              .moduleSurface()
            }
          }
          .screenColumn()
          .padding(.bottom, Theme.Space.xl)
        }
      }
    } toolbar: {
      ToolbarItem(placement: .primaryAction) {
        Button(String(localized: "Refresh"), systemImage: "arrow.clockwise") {
          Task { await reloadHistory() }
        }
        .disabled(actions.busy)
        .accessibilityIdentifier("history.refresh")
      }
    }
    .animation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion), value: actions.displayRevision)
    .task { await reloadHistory() }
  }

  private func reloadHistory() async {
    if let reload { await reload() } else { await actions.reloadHistory() }
  }

  private var header: some View {
    HStack(alignment: .bottom, spacing: Theme.Space.xl) {
      HeroMetric(
        value: .aggregate(actions.pendingTrashSize.logical),
        caption: String(localized: "Pending Trash") + " · "
          + String.localizedStringWithFormat(String(localized: "%lld items"), Int64(actions.pendingTrashCount)),
        tone: actions.pendingTrashCount > 0 ? .hero : .neutral)
      Spacer(minLength: Theme.Space.l)
      InfoButton(text: String(localized: "Trash items have not freed disk space."))
    }
    .padding(.top, Theme.Space.l)
  }

  private func planRow(_ plan: HistoryPlan, proxy: ScrollViewProxy) -> some View {
    let expanded = actions.expandedHistoryGroups.contains(plan.id)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Space.m) {
        Button {
          Task { await actions.setHistoryGroupExpanded(plan.id, expanded: !expanded) }
        } label: {
          Image(systemName: "chevron.right").font(Theme.Font.iconSmall)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .foregroundStyle(Theme.Palette.inkSecondary)
            .frame(width: Theme.Space.l, height: Theme.Space.xl)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          expanded ? String(localized: "Hide history details") : String(localized: "Show history details")
        )
        .accessibilityIdentifier("history.group.\(plan.id.uuidString)")
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
          Text(title(plan)).font(Theme.Font.bodyMedium).lineLimit(1).truncationMode(.middle)
          HStack(spacing: Theme.Space.xs) {
            Text(plan.createdAt, format: .dateTime.month().day().hour().minute())
            if plan.kind == .catalogDelete {
              Text(verbatim: "·")
              Text(String(localized: "Undo unavailable — permanently cleaned"))
            } else if plan.deletedCount > 0 {
              Text(verbatim: "·")
              Text(
                "\(plan.deletedCount) \(String(localized: "entries removed")) · \(format(plan.deletedLogicalBytes))")
            }
          }
          .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1)
        }
        .help(plan.metadata.count == 1 ? plan.metadata.first?.sourcePath ?? "" : "")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.summary.\(plan.id.uuidString)")
        Spacer(minLength: Theme.Space.s)
        Text(
          plan.deletedCount > 0
            ? format(plan.deletedLogicalBytes) : PlanItemSize.text(actions.historySize(plan).logical)
        )
        .font(Theme.Font.mono).foregroundStyle(Theme.Palette.ink).lineLimit(1).fixedSize()
        .accessibilityIdentifier("history.size.\(plan.id.uuidString)")
        Chip(title: status(plan.state), tone: tone(plan.state))
          .accessibilityLabel(String(localized: "Status"))
          .accessibilityValue(status(plan.state))
          .accessibilityIdentifier("history.status.\(plan.id.uuidString)")
        if plan.canUndo {
          Button(String(localized: "Undo"), systemImage: "arrow.uturn.backward") {
            Task {
              await actions.undo(plan)
              proxy.scrollTo(plan.id, anchor: .top)
            }
          }
          .labelStyle(.titleAndIcon)
          .controlSize(.small)
          .fixedSize()
          .disabled(actions.busy || actions.loadingHistoryGroups.contains(plan.id))
          .accessibilityLabel(String(localized: "Undo") + " " + title(plan))
          .accessibilityIdentifier("history.undo.\(plan.id.uuidString)")
        }
      }
      .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s + 2)
      .accessibilityElement(children: .contain)
      if expanded {
        VStack(alignment: .leading, spacing: 0) {
          if actions.loadingHistoryGroups.contains(plan.id) {
            ScanStatusRow(status: String(localized: "Loading history details…"))
              .padding(.vertical, Theme.Space.xs)
          }
          if plan.detailsLoaded {
            ForEach(plan.items, id: \.itemID) { item in
              historyItem(item, plan: plan)
            }
          }
        }
        .padding(.leading, Theme.Layout.rowTextInset).padding(.trailing, Theme.Space.l)
        .padding(.bottom, Theme.Space.s)
        .transition(Theme.Motion.transition(Theme.Motion.rise, reduceMotion: reduceMotion))
      }
    }
    .accessibilityElement(children: .contain)
    .id(plan.id)
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
    return VStack(alignment: .leading, spacing: Theme.Space.xs) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
        Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.itemID.uuidString)
          .font(Theme.Font.callout).lineLimit(1).truncationMode(.middle)
          .help(path ?? "")
        Spacer(minLength: Theme.Space.xs)
        Text(PlanItemSize.text(size.logical)).font(Theme.Font.monoSmall).foregroundStyle(Theme.Palette.inkSecondary)
        Text(status(item.state)).font(Theme.Font.caption).foregroundStyle(tone(item.state).foreground)
      }
      if let path { PathLabel(path: path).textSelection(.enabled) }
      if let detail {
        FailureReasonView(presentation: FailureText.presentation(detail))
      }
      if item.detail == String(describing: UndoFailure.trashItemMissing) {
        HStack {
          Text(SpaceText.trashMissing())
            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: Theme.Space.xs)
          Button(String(localized: "Show Trash in Finder")) {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
          }
          .buttonStyle(.link)
        }
      }
      if item.state == .inTrash && !item.canUndo {
        Text(String(localized: "Cannot restore yet. Resolve the reason above, then refresh History."))
          .font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, Theme.Space.xs + 2)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("history.item.\(item.itemID.uuidString)")
  }

  private func tone(_ state: HistoryState) -> Tone {
    switch state {
    case .uncertain, .failed: .warning
    case .inTrash: .accent
    case .reversed: .positive
    default: .neutral
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
