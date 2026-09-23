import LightenKit
import SwiftUI

struct CleanView: View {
  @Bindable var store: CleanStore
  @Bindable var actions: ActionStore
  @State private var searchText = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var searchTerm: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var filteredCandidates: [CleanCandidate] {
    store.candidates.filter { matches($0.entry.path) }
  }
  private var filteredRelatedCandidates: [RelatedDataCandidate] {
    store.relatedCandidates.filter { matches($0.path) }
  }
  private var totalCount: Int { store.candidates.count + store.relatedCandidates.count }
  private var visibleCount: Int { filteredCandidates.count + filteredRelatedCandidates.count }

  private var selectedCandidate: CleanCandidate? {
    store.candidates.first { store.selected.contains($0.id) }
  }

  private func matches(_ path: String) -> Bool {
    searchTerm.isEmpty || path.localizedStandardContains(searchTerm)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(String(localized: "Clean"))
            .font(.system(size: 24, weight: .semibold))
          Text(String(localized: "Documented caches and related app data"))
            .foregroundStyle(LightenStyle.muted)
        }
        Spacer()
        Button(store.busy ? String(localized: "Cancel scan") : String(localized: "Scan")) {
          if store.busy { store.cancelScan() } else { store.startScan() }
        }
      }
      .padding(.bottom, 14)
      HStack {
        TextField(String(localized: "Search by name or path"), text: $searchText)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(String(localized: "Search by name or path"))
          .frame(maxWidth: 360)
        Button(String(localized: "Clear search")) { searchText = "" }
          .disabled(searchText.isEmpty)
        Spacer()
      }
      .padding(.bottom, 10)
      HStack {
        Text(
          store.busy
            ? String(localized: "Scanning")
            : store.scannedAt.map { String(localized: "Last scan") + ": " + $0.formatted() }
              ?? String(localized: "Scan to inspect candidate areas")
        )
        .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
        Spacer()
        Text(
          searchTerm.isEmpty
            ? "\(totalCount) \(String(localized: "candidates"))"
            : "\(visibleCount) \(String(localized: "matches")) / \(totalCount) \(String(localized: "candidates"))"
        )
        .font(.system(size: 12)).monospacedDigit()
      }
      .padding(.bottom, 10)
      if !searchTerm.isEmpty && visibleCount == 0 && !store.busy && store.scannedAt != nil {
        Text(String(localized: "No matching candidates"))
          .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
          .padding(.bottom, 10)
      }
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 15) {
          ForEach(store.rows) { row in
            cacheSection(row)
          }
          VStack(alignment: .leading, spacing: 5) {
            Text(String(localized: "Removed app data"))
              .font(.system(size: 16, weight: .semibold))
            Text(
              String(
                localized: "Only exact metadata links can qualify. Other locations and incomplete scans remain unknown."
              )
            )
            .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(filteredRelatedCandidates) { candidate in
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: candidate.path).lastPathComponent)
                      .font(.system(size: 12, weight: .medium))
                    Text(relatedReason(candidate.reason)).font(.system(size: 11))
                      .foregroundStyle(LightenStyle.muted)
                  }
                  Spacer()
                  if candidate.classification == .historicallyVerifiedAbsent {
                    Button(String(localized: "Review Trash")) {
                      Task { await store.prepareRelated(candidate, actions: actions) }
                    }
                    .disabled(store.busy || actions.busy)
                  } else {
                    Text(String(localized: "Report only"))
                      .font(.system(size: 10)).foregroundStyle(LightenStyle.warning)
                  }
                }
                .padding(.vertical, 3)
              }
            }
          }
          .padding(13).frame(maxWidth: .infinity, alignment: .leading)
          .background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 9))
        }
        .padding(.vertical, 12)
      }
      if let candidate = selectedCandidate {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
          Text(URL(fileURLWithPath: candidate.entry.path).lastPathComponent)
            .font(.system(size: 13, weight: .medium))
          Text(candidate.entry.path).font(.system(size: 11))
            .foregroundStyle(LightenStyle.muted).lineLimit(1).truncationMode(.middle)
          let turkish = Bundle.main.preferredLocalizations.first?.hasPrefix("tr") == true
          Text(candidate.row.reason(turkish: turkish) + " " + candidate.row.cost(turkish: turkish))
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          Text(candidate.row.evidenceURL).font(.system(size: 10))
            .foregroundStyle(LightenStyle.muted).lineLimit(1)
        }
        .padding(.vertical, 10)
      }
      Divider()
      HStack {
        Picker(String(localized: "Action"), selection: $store.mode) {
          Text(String(localized: "Move to Trash")).tag(ActionKind.trash)
          Text(String(localized: "Permanent cleanup · cannot undo")).tag(ActionKind.catalogDelete)
        }
        .pickerStyle(.segmented).frame(maxWidth: 360)
        Spacer()
        Text("\(store.selected.count) \(String(localized: "selected"))")
          .font(.system(size: 12)).monospacedDigit()
        Button(String(localized: "Review selection")) {
          Task { await store.prepare(actions: actions) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.selected.isEmpty || store.busy || actions.busy)
      }
      .padding(.top, 13)
      if let message = store.message {
        Text(message).font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
      } else if let detail = actions.message {
        Text(String(localized: "Action paused. Review History and scan again."))
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
        Text(detail).font(.system(size: 10)).foregroundStyle(LightenStyle.muted)
      }
      if let result = actions.result, result.planID == store.presentedPlanID {
        Text(resultLine(result))
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(LightenStyle.canvas)
    .navigationTitle(String(localized: "Clean"))
    .sheet(item: $actions.pending) { presentation in
      ConfirmationView(presentation: presentation, actions: actions)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.selected)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: actions.result?.planID)
    .onDisappear { store.cancelScan() }
  }

  private func cacheSection(_ row: CatalogRow) -> some View {
    let turkish = Bundle.main.preferredLocalizations.first?.hasPrefix("tr") == true
    let candidates = filteredCandidates.filter { $0.row.id == row.id }
    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(row.title(turkish: turkish)).font(.system(size: 16, weight: .semibold))
        Spacer()
        Text(rowStatus(store.rowStatuses[row.id]))
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      }
      Text(row.reason(turkish: turkish) + " " + row.cost(turkish: turkish))
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(candidates) { candidate in
          HStack(spacing: 8) {
            Button {
              if store.selected.contains(candidate.id) {
                store.selected.remove(candidate.id)
              } else {
                store.selected.insert(candidate.id)
              }
            } label: {
              Image(systemName: store.selected.contains(candidate.id) ? "checkmark.square.fill" : "square")
            }
            .buttonStyle(.plain).disabled(!candidate.canAct)
            Text(URL(fileURLWithPath: candidate.entry.path).lastPathComponent)
              .lineLimit(1)
            Spacer()
            Text(
              candidate.node.logical.completeTotal.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
              }
                ?? String(localized: "Unknown")
            )
            .monospacedDigit()
            if !candidate.canAct {
              Text(String(localized: "Report only"))
                .font(.system(size: 10)).foregroundStyle(LightenStyle.warning)
            }
          }
          .font(.system(size: 12)).padding(.vertical, 3)
          .accessibilityLabel(
            "\(candidate.entry.path), \(candidate.canAct ? String(localized: "Selectable") : String(localized: "Report only"))"
          )
        }
      }
    }
    .padding(13).frame(maxWidth: .infinity, alignment: .leading)
    .background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 9))
  }

  private func rowStatus(_ value: CleanRowStatus?) -> String {
    switch value {
    case .toolRunning: String(localized: "Tool running — cleaning paused")
    case .processUnknown: String(localized: "Process activity unknown — report only")
    case .empty: String(localized: "No entries")
    case .clear: String(localized: "Current-user process check clear")
    case .unavailable: String(localized: "Unavailable or unreadable")
    case nil: String(localized: "Not scanned")
    }
  }

  private func relatedReason(_ value: RelatedReason) -> String {
    switch value {
    case .candidateAreaUnreadable: String(localized: "Candidate area unreadable")
    case .recordUnsafe: String(localized: "Relation record unreadable or unsafe")
    case .protected: String(localized: "Protected by safety rules")
    case .installed: String(localized: "Owner found in searched app locations")
    case .incompleteInventory: String(localized: "Application inventory incomplete")
    case .recordUnavailable: String(localized: "Relation record unavailable")
    case .historicallyVerified: String(localized: "Previously verified owner absent here; it may exist elsewhere")
    case .nameOnly: String(localized: "Exact name alone does not prove former ownership")
    case .sharedGroup: String(localized: "Shared Group Containers are protected and report only")
    case .installedElsewhere: String(localized: "An app with this identifier is installed elsewhere")
    }
  }

  private func resultLine(_ result: ActionResult) -> String {
    let categories: [(ActionOutcome, String)] = [
      (
        .applied,
        actions.resultKind == .catalogDelete
          ? String(localized: "Permanently cleaned") : String(localized: "Moved to Trash")
      ),
      (.skipped, String(localized: "Skipped")),
      (.failed, String(localized: "Failed")),
      (.uncertain, String(localized: "Uncertain")),
      (.notAttempted, String(localized: "Not attempted")),
    ]
    var parts = categories.compactMap { outcome, label -> String? in
      let count = result.items.filter { $0.outcome == outcome }.count
      return count > 0 ? "\(count) \(label)" : nil
    }
    let removed = result.items.reduce(0) { $0 + $1.deletedCount }
    let bytes = result.items.reduce(Int64(0)) { $0 + $1.deletedLogicalBytes }
    if removed > 0 {
      parts.append(
        "\(removed) \(String(localized: "irreversibly removed entries")) · \(format(bytes)) \(String(localized: "known logical bytes"))"
      )
    }
    return String(localized: "Last result") + ": " + parts.joined(separator: " · ")
  }
}
