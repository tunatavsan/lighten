import AppKit
import LightenKit
import SwiftUI

struct CleanView: View {
  @Bindable var store: CleanStore
  @Bindable var actions: ActionStore
  @State private var searchText = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var turkish: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("tr") == true }
  private var searchTerm: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var filtered: [CleanCandidate] {
    store.candidates.filter {
      searchTerm.isEmpty || $0.entry.path.localizedStandardContains(searchTerm)
        || $0.row.title(turkish: turkish).localizedStandardContains(searchTerm)
    }
  }
  private var actionableRows: [CatalogRow] {
    store.rows.filter { row in filtered.contains { $0.row.id == row.id } }
  }
  private var related: [RelatedDataCandidate] {
    store.relatedCandidates.filter { searchTerm.isEmpty || $0.path.localizedStandardContains(searchTerm) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(String(localized: "Clean")).font(.system(size: 24, weight: .semibold))
          Text(String(localized: "Documented caches and related app data")).foregroundStyle(LightenStyle.muted)
        }
        Spacer()
        Button(store.phase == .scanning ? String(localized: "Cancel scan") : String(localized: "Scan")) {
          if store.phase == .scanning { store.cancelScan(actions: actions) } else { store.startScan(actions: actions) }
        }
        .disabled(actions.busy || store.tool.preparation.preparing)
      }
      HStack {
        TextField(String(localized: "Search by name or path"), text: $searchText)
          .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
          .accessibilityLabel(String(localized: "Search by name or path"))
        Button(String(localized: "Clear search")) { searchText = "" }.disabled(searchText.isEmpty)
        Spacer()
        Text(
          "\(store.toolSummary.count) \(String(localized: "candidates")) · \(format(store.toolSummary.logicalBytes))"
        )
        .font(.system(size: 12)).monospacedDigit()
        .contentTransition(reduceMotion ? .identity : .numericText())
      }
      HStack {
        Text(scanStatus).font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
        Spacer()
        Button(String(localized: "Select all")) { store.selectAll(actions: actions) }
          .disabled(store.picture != nil || store.phase != .ready || actions.busy)
      }
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if let picture = store.picture {
            previousResults(picture)
          } else {
            ForEach(Array(actionableRows.prefix(7))) { row in categoryCard(row) }
            if actionableRows.count > 7 {
              DisclosureGroup(String(localized: "More categories")) {
                ForEach(Array(actionableRows.dropFirst(7))) { row in categoryCard(row) }
              }
            }
            if store.discoveringRelated {
              HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Checking removed app data"))
                  .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
              }
            }
            if !related.isEmpty { removedData }
            reportOnly
          }
        }
        .padding(.vertical, 4)
      }
      Divider()
      HStack {
        Text("\(store.selected.count) \(String(localized: "selected")) · \(format(store.selectedLogicalBytes))")
          .font(.system(size: 12)).monospacedDigit()
          .contentTransition(reduceMotion ? .identity : .numericText())
        Spacer()
        Button(String(localized: "Clean")) { Task { await store.prepare(actions: actions) } }
          .buttonStyle(.borderedProminent)
          .disabled(
            store.picture != nil || store.selected.isEmpty || store.phase != .ready || store.busy || actions.busy)
      }
      if let message = store.message {
        Text(message).font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
          .textSelection(.enabled)
      } else if let message = actions.message {
        Text(message).font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
      }
      ActionFeedbackView(actions: actions)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(LightenStyle.canvas)
    .navigationTitle(String(localized: "Clean"))
    .sheet(item: $actions.pending) { ConfirmationView(presentation: $0, actions: actions) }
    .task { store.open() }
    .onChange(of: actions.result?.planID) { store.observeResult(actions: actions) }
    .onDisappear { store.deactivate(actions: actions) }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.selected)
    .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: store.displayRevision)
  }

  private var scanStatus: String {
    if let picture = store.picture {
      let date = String(localized: "Last scan") + ": " + picture.observedAt.formatted()
      return store.phase == .scanning ? date + " · " + String(localized: "Scanning") : date
    }
    if store.partial { return String(localized: "Partial scan. Scan again before cleaning.") }
    if store.phase == .scanning { return String(localized: "Scanning") }
    return store.scannedAt.map { String(localized: "Last scan") + ": " + $0.formatted() }
      ?? String(localized: "Scan to inspect candidate areas")
  }

  private func previousResults(_ picture: ResultPicture<CleanPicture>) -> some View {
    let rows = picture.content.rows.filter { row in
      searchTerm.isEmpty || row.path.localizedStandardContains(searchTerm)
        || store.rows.first { $0.id == row.categoryID }?.title(turkish: turkish)
          .localizedStandardContains(searchTerm) == true
    }
    let related = picture.content.relatedRows.filter {
      searchTerm.isEmpty || $0.path.localizedStandardContains(searchTerm)
    }
    return LazyVStack(alignment: .leading, spacing: 12) {
      Text(String(localized: "Previous result. Scan again before cleaning."))
        .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
      if picture.content.partial {
        Text(String(localized: "Partial scan. Scan again before cleaning."))
          .font(.system(size: 12)).foregroundStyle(LightenStyle.warning)
      }
      if rows.isEmpty && related.isEmpty {
        Text(String(localized: "No items"))
          .font(.system(size: 13)).foregroundStyle(LightenStyle.muted)
      }
      ForEach(rows) { row in
        previousRow(
          path: row.path,
          category: store.rows.first { $0.id == row.categoryID }?.title(turkish: turkish),
          bytes: row.logicalBytes, complete: row.sizeComplete, detail: row.detail)
      }
      ForEach(related) { row in
        previousRow(
          path: row.path, category: String(localized: "Removed app data"),
          bytes: row.logicalBytes, complete: false, detail: row.detail)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CleanPictureDrawProbe { store.pictureDidDraw() })
  }

  private func previousRow(
    path: String, category: String?, bytes: Int64?, complete: Bool, detail: String?
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 14, weight: .medium))
        Spacer()
        if let bytes {
          Text((complete ? "" : String(localized: "At least") + " ") + format(bytes))
            .font(.system(size: 12)).monospacedDigit()
        }
      }
      if let category { Text(category).font(.system(size: 11)).foregroundStyle(LightenStyle.muted) }
      Text(path).font(.system(size: 11)).foregroundStyle(LightenStyle.muted).textSelection(.enabled)
      if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(LightenStyle.muted) }
      Button(String(localized: "Show in Finder")) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      }.font(.system(size: 11))
    }
    .padding(13).background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 9))
  }

  private func categoryCard(_ row: CatalogRow) -> some View {
    let candidates = filtered.filter { $0.row.id == row.id }
    let ids = Set(candidates.map(\.id))
    let bytes = candidates.reduce(Int64(0)) { $0 + $1.logicalBytes }
    let incomplete = candidates.contains { !$0.sizeComplete }
    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Button {
          store.toggleCategory(row.id, actions: actions)
        } label: {
          Image(systemName: ids.isSubset(of: store.selected) ? "checkmark.square.fill" : "square")
        }
        .buttonStyle(.plain).disabled(store.phase != .ready || actions.busy)
        .accessibilityLabel(row.title(turkish: turkish))
        Text(row.title(turkish: turkish)).font(.system(size: 15, weight: .semibold))
        Spacer()
        Text(
          "\(candidates.count) \(String(localized: "items")) · \(incomplete ? String(localized: "At least") + " " : "")\(format(bytes))"
        )
        .font(.system(size: 12)).monospacedDigit()
        .contentTransition(reduceMotion ? .identity : .numericText())
      }
      Text(row.reason(turkish: turkish) + " " + row.cost(turkish: turkish))
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      DisclosureGroup(String(localized: "Inspect items")) {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(candidates) { candidate in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: candidate.entry.path).lastPathComponent).lineLimit(1)
                  .help(candidate.entry.path)
                if let reason = actions.failure(at: candidate.entry.path) {
                  Text(reason).foregroundStyle(LightenStyle.warning).fixedSize(horizontal: false, vertical: true)
                }
              }
              Spacer()
              Text(format(candidate.logicalBytes)).monospacedDigit()
            }.font(.system(size: 11))
          }
        }
      }
      .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
    }
    .padding(13).background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 9))
  }

  private var reportOnly: some View {
    DisclosureGroup(String(localized: "Needs review")) {
      ForEach(
        store.rows.filter { row in
          filtered.contains { $0.row.id == row.id && !$0.canAct }
            || store.rowStatuses[row.id] == .unavailable || store.rowStatuses[row.id] == .toolRunning
            || store.rowStatuses[row.id] == .processUnknown
        }
      ) { row in
        VStack(alignment: .leading, spacing: 5) {
          Text(row.title(turkish: turkish)).font(.system(size: 13, weight: .medium))
          ForEach(reportReasons(row), id: \.self) { reason in
            Text(reason).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          }
          HStack {
            Button(String(localized: "Show in Finder")) {
              NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: store.homeDirectory + "/" + row.relativeRoot)
              ])
            }
            if store.rowStatuses[row.id] == .unavailable
              || store.candidates.contains(where: { $0.row.id == row.id && $0.requiresFullDiskAccess })
            {
              Button(String(localized: "Open Full Disk Access settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                  NSWorkspace.shared.open(url)
                }
              }
            }
          }.font(.system(size: 11))
        }.padding(.vertical, 6)
      }
    }
    .padding(13).background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 9))
  }

  private var removedData: some View {
    DisclosureGroup(String(localized: "Removed app data")) {
      let grouped = Dictionary(grouping: related, by: bundleID)
      ForEach(grouped.keys.sorted(), id: \.self) { id in
        DisclosureGroup(id) {
          let items = grouped[id] ?? []
          ForEach(items) { candidate in
            VStack(alignment: .leading, spacing: 4) {
              Text(URL(fileURLWithPath: candidate.path).lastPathComponent).font(.system(size: 12))
              Text(relatedReason(candidate.reason)).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
              if store.phase == .ready {
                Button(String(localized: "Review Trash")) {
                  Task { await store.prepareRelated(candidate, actions: actions) }
                }.disabled(store.phase != .ready || store.busy || actions.busy)
              } else {
                Button(String(localized: "Show in Finder")) {
                  NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
                }
              }
            }.padding(.vertical, 4)
          }
        }.padding(.vertical, 4)
      }
    }
    .padding(13).background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 9))
  }

  private func bundleID(_ candidate: RelatedDataCandidate) -> String {
    if let id = candidate.receipt?.bundleID { return id }
    let name = URL(fileURLWithPath: candidate.path).lastPathComponent
    return name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
  }

  private func reportReasons(_ row: CatalogRow) -> [String] {
    let reasons = filtered.filter { $0.row.id == row.id && !$0.canAct }.map { candidate in
      if let refusal = candidate.refusal { return refusal }
      if candidate.activity == .active {
        let names = candidate.processNames.isEmpty ? "" : " " + candidate.processNames.joined(separator: ", ")
        return String(localized: "A related process is running. Quit it before cleaning.") + names
      }
      if candidate.activity == .unknown {
        return String(localized: "Process activity could not be checked. Check Activity Monitor.")
      }
      if ProtectionPolicy.rule(
        for: candidate.entry.path,
        homeDirectory: store.homeDirectory) != nil
      {
        return String(localized: "A safety rule protects this item. Inspect it in Finder.")
      }
      if row.relativeRoot == "Library/Caches" {
        if URL(fileURLWithPath: candidate.entry.path).lastPathComponent.lowercased().hasPrefix("com.apple.") {
          return String(localized: "Apple-managed caches are excluded. Inspect this cache in Finder.")
        }
        if store.rows.contains(where: {
          $0.id != row.id
            && $0.relativeRoot.hasPrefix(
              row.relativeRoot + "/" + URL(fileURLWithPath: candidate.entry.path).lastPathComponent + "/")
        }) {
          return String(localized: "This cache is covered by another category. Review that category.")
        }
      }
      if row.minAgeDays > 0 {
        return String(localized: "Recently changed items are kept. Inspect them in Finder.")
      }
      if candidate.entry.identity == nil {
        return SpaceText.rejection(PlanRejection(.missingMetadata, path: candidate.entry.path))
      }
      return reportReason(row)
    }
    return reasons.isEmpty ? [reportReason(row)] : Array(Set(reasons)).sorted()
  }

  private func reportReason(_ row: CatalogRow) -> String {
    switch store.rowStatuses[row.id] {
    case .toolRunning: String(localized: "A related process is running. Quit it before cleaning.")
    case .processUnknown: String(localized: "Process activity could not be checked. Check Activity Monitor.")
    case .unavailable:
      String(
        localized: "Lighten could not read this area. Inspect its location in Finder.")
    default:
      row.methods.isEmpty
        ? row.reason(turkish: turkish) + " " + row.cost(turkish: turkish)
          + " " + String(localized: "Inspect these items in Finder.")
        : String(localized: "These items do not meet this category's safety rules. Inspect them in Finder.")
    }
  }

  private func relatedReason(_ value: RelatedReason) -> String {
    switch value {
    case .candidateAreaUnreadable:
      String(localized: "Lighten could not read this data area. Check access to this folder in Finder.")
    case .recordUnsafe: String(localized: "The ownership record could not be verified. Inspect this data in Finder.")
    case .protected: String(localized: "A safety rule protects this data. Inspect it in Finder.")
    case .installed, .literalIdentifierOwner:
      String(localized: "An installed app owns this data. Review the app in Applications.")
    case .incompleteInventory, .registrationUnavailable, .liveCensusUnavailable:
      String(localized: "Lighten could not check every possible app owner of this data. Inspect it in Finder.")
    case .recordUnavailable: String(localized: "The ownership record is unavailable. Inspect this data in Finder.")
    case .historicallyVerified: String(localized: "Previously verified owner absent here; it may exist elsewhere")
    case .nameOnly: String(localized: "The name alone does not prove former ownership. Inspect this data in Finder.")
    case .ownershipUnavailable:
      String(localized: "Lighten could not confirm which apps use this shared folder. Inspect the folder in Finder.")
    case .sharedGroup:
      String(localized: "Shared Group Containers may contain data from several apps. Inspect the folder in Finder.")
    case .installedElsewhere, .sharedInstalledData:
      String(localized: "An app with this identifier is installed elsewhere. Review the app in Applications.")
    case .orphanVerified:
      String(localized: "No installed app with this identifier was found. Review before moving to Trash.")
    case .foreignOwner:
      String(localized: "Another user owns this data. Inspect it in Finder.")
    case .mediumMatch:
      String(localized: "The name and signing team suggest a match. Review this data before selecting it.")
    }
  }

  private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Reports an AppKit draw separately from the store's first publication.
private struct CleanPictureDrawProbe: NSViewRepresentable {
  let didDraw: @MainActor () -> Void

  func makeNSView(context: Context) -> ProbeView { ProbeView(didDraw: didDraw) }
  func updateNSView(_ view: ProbeView, context: Context) {
    view.didDraw = didDraw
    view.needsDisplay = true
  }

  final class ProbeView: NSView {
    var didDraw: @MainActor () -> Void
    init(didDraw: @escaping @MainActor () -> Void) {
      self.didDraw = didDraw
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { return nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
      guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
      let callback = didDraw
      DispatchQueue.main.async { callback() }
    }
  }
}
