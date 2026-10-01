import AppKit
import LightenKit
import SwiftUI

struct DuplicateView: View {
  @Bindable var store: DuplicateStore
  @Bindable var actions: ActionStore
  @State private var searchText = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var groups: [DuplicateGroup] {
    guard let report = store.report, !store.needsRescan else { return [] }
    let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return report.groups }
    return report.groups.filter { group in
      group.members.contains { $0.entry.path.localizedStandardContains(term) }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(String(localized: "Duplicates"))
            .font(.system(size: 24, weight: .semibold))
          Text(String(localized: "Exact local file copies in a folder you choose"))
            .foregroundStyle(LightenStyle.muted)
        }
        Spacer()
        Button(String(localized: "Choose folder")) { chooseFolder() }
          .disabled(actions.busy)
        if store.busy {
          Button(String(localized: "Cancel scan")) { store.cancelScan() }
        } else if let path = store.folderPath {
          Button(String(localized: "Scan again")) { store.startScan(folder: path, actions: actions) }
            .disabled(actions.busy)
        }
      }
      .padding(.bottom, 14)
      if let folder = store.folderPath {
        Label(folder, systemImage: "folder")
          .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
          .lineLimit(1).truncationMode(.middle).help(folder)
          .padding(.bottom, 8)
      }
      if store.busy || store.report != nil || store.cancelled {
        HStack {
          Text(
            store.busy
              ? String(localized: "Scanning and comparing files")
              : store.needsRescan
                ? String(localized: "Scan is out of date after this operation")
                : store.cancelled
                  ? String(localized: "Scan cancelled")
                  : String(localized: "Comparison complete")
          )
          Spacer()
          Text("\(store.scanned) \(String(localized: "scanned")) · \(store.compared) \(String(localized: "compared"))")
            .monospacedDigit()
        }
        .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
        .padding(.bottom, 9)
      }
      if store.report != nil && !store.needsRescan {
        HStack {
          TextField(String(localized: "Search by name or path"), text: $searchText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(String(localized: "Search by name or path"))
            .frame(maxWidth: 360)
          Button(String(localized: "Clear search")) { searchText = "" }
            .disabled(searchText.isEmpty)
          Spacer()
          Text("\(groups.count) / \(store.report?.groups.count ?? 0) \(String(localized: "groups"))")
            .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
        }
        .padding(.bottom, 10)
      }
      if let report = store.report, report.partial, !store.needsRescan {
        Label {
          Text(
            report.skippedCount > 0
              ? "\(report.skippedCount) \(String(localized: "known files skipped")) · \(String(localized: "Some files or areas could not be verified; results are partial."))"
              : String(localized: "Some files or areas could not be verified; results are partial.")
          )
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.system(size: 12)).foregroundStyle(LightenStyle.warning)
        .padding(.bottom, 9)
      }
      Divider()
      if store.needsRescan {
        ContentUnavailableView(
          String(localized: "Scan is out of date after this operation"), systemImage: "arrow.clockwise",
          description: Text(String(localized: "Scan again to refresh duplicate groups before another action."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if store.report == nil && !store.busy {
        ContentUnavailableView(
          String(localized: "Choose a folder to compare"), systemImage: "doc.on.doc",
          description: Text(String(localized: "No files are selected for removal by default."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if groups.isEmpty && !store.busy {
        ContentUnavailableView(
          searchText.isEmpty
            ? String(localized: "No exact copies found")
            : String(localized: "No matching groups"), systemImage: "checkmark.circle"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in groupCard(group) }
          }
          .padding(.vertical, 12)
        }
      }
      Divider()
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(store.targets.count) \(String(localized: "selected")) · \(format(store.selectedLogicalBytes))")
            .font(.system(size: 13, weight: .medium)).monospacedDigit()
          Text(String(localized: "Logical bytes to move to Trash; disk space is not yet freed."))
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        }
        Spacer()
        Button(String(localized: "Review selection")) {
          Task { await store.prepare(actions: actions) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.targets.isEmpty || store.busy || store.preparing || actions.busy || store.needsRescan)
      }
      .padding(.top, 12)
      if let message = store.message ?? actions.message {
        Text(message).font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
          .padding(.top, 5)
      }
      ActionFeedbackView(actions: actions).padding(.top, 5)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(LightenStyle.canvas)
    .navigationTitle(String(localized: "Duplicates"))
    .sheet(item: $actions.pending) { presentation in
      ConfirmationView(presentation: presentation, actions: actions)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.targets)
    .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: store.displayRevision)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.report?.groups.count)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.needsRescan)
    .onAppear { store.observeResult(actions: actions) }
    .onChange(of: actions.result?.planID) { _, _ in store.observeResult(actions: actions) }
    .onDisappear { store.deactivate(actions: actions) }
  }

  private func groupCard(_ group: DuplicateGroup) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(group.members.count) \(String(localized: "data-identical files"))")
            .font(.system(size: 15, weight: .semibold))
          Text(
            group.members.contains { $0.eligibility == .eligible }
              ? String(localized: "Choose one verified copy to keep, then select others.")
              : String(localized: "Metadata differs or is unknown. Review the copies before choosing.")
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        }
        Spacer()
        Text(format(group.logicalBytes)).font(.system(size: 13, weight: .medium))
          .monospacedDigit()
      }
      Divider()
      ForEach(group.members) { member in
        memberRow(member, group: group)
          .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.96)))
      }
    }
    .padding(13)
    .background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 10))
  }

  private func memberRow(_ member: DuplicateMember, group: DuplicateGroup) -> some View {
    let keeperID = store.keepers[group.id]
    let isKeeper = keeperID == member.id
    let canTarget = keeperID.map { $0 != member.id } ?? false
    return HStack(spacing: 10) {
      Button {
        store.chooseKeeper(member.id, for: group, actions: actions)
      } label: {
        Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
          .frame(width: 20)
      }
      .buttonStyle(.plain)
      .disabled(actions.busy)
      .accessibilityLabel(isKeeper ? String(localized: "Keep this copy") : String(localized: "Choose as keeper"))
      Button {
        store.toggleTarget(member.id, in: group, actions: actions)
      } label: {
        Image(systemName: store.targets.contains(member.id) ? "checkmark.square.fill" : "square")
          .frame(width: 20)
      }
      .buttonStyle(.plain)
      .disabled(!canTarget || isKeeper || actions.busy)
      .accessibilityLabel(String(localized: "Select copy for Trash"))
      VStack(alignment: .leading, spacing: 2) {
        Text(URL(fileURLWithPath: member.entry.path).lastPathComponent)
          .font(.system(size: 12, weight: .medium)).lineLimit(1)
        if let reason = actions.failure(at: member.entry.path) {
          Text(reason).font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(member.entry.path)
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          .lineLimit(1).truncationMode(.middle).help(member.entry.path)
      }
      Spacer(minLength: 8)
      Text(
        member.eligibility == .eligible && keeperID != nil && !isKeeper && !canTarget
          ? String(localized: "Different metadata subset · choose its keeper")
          : label(member.eligibility)
      )
      .font(.system(size: 10))
      .foregroundStyle(member.eligibility == .eligible ? LightenStyle.muted : .orange)
    }
    .accessibilityElement(children: .contain)
  }

  private func label(_ eligibility: DuplicateEligibility) -> String {
    switch eligibility {
    case .eligible: String(localized: "Metadata equal")
    case .metadataDifferent: String(localized: "Metadata differs · review before choosing")
    case .metadataUnknown: String(localized: "Metadata unknown · review before choosing")
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Scan folder")
    if panel.runModal() == .OK, let path = panel.url?.path {
      store.startScan(folder: path, actions: actions)
    }
  }
}
