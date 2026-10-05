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
    ToolScreen(String(localized: "Clean"), subtitle: subtitle) {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
          header
          if let picture = store.picture {
            previousResults(picture)
          } else if store.phase == .idle && store.scannedAt == nil {
            EmptyState(
              symbol: "sparkles", title: String(localized: "Find caches and leftovers"),
              message: String(
                localized: "Review caches and temporary files apps can recreate, plus data left by removed apps."),
              tint: Theme.Palette.toolClean
            ) {
              Button(String(localized: "Scan")) { store.startScan(actions: actions) }.buttonStyle(.hero)
            }
          } else {
            if !actionableRows.isEmpty { categories }
            if store.discoveringRelated {
              ScanStatusRow(status: String(localized: "Checking removed app data"))
            }
            if !related.isEmpty { removedData }
            if !reviewRows.isEmpty { reportOnly }
            if filtered.isEmpty && related.isEmpty && store.phase != .scanning {
              EmptyState(
                symbol: "checkmark.circle",
                title: searchTerm.isEmpty
                  ? String(localized: "No items to clean") : String(localized: "No matching items"),
                message: String(localized: "Scan again to check for new items."), tint: Theme.Palette.positive)
            }
          }
          ActionFeedbackView(actions: actions)
        }
        .screenColumn()
        .padding(.bottom, Theme.Space.xl)
      }
      .floatingBar(isPresented: !store.selected.isEmpty && store.picture == nil) { selectionBar }
    } toolbar: {
      ToolbarItem(placement: .primaryAction) {
        Button(
          store.phase == .scanning ? String(localized: "Cancel scan") : String(localized: "Scan"),
          systemImage: store.phase == .scanning ? "stop.fill" : "arrow.clockwise"
        ) {
          if store.phase == .scanning { store.cancelScan(actions: actions) } else { store.startScan(actions: actions) }
        }
        .labelStyle(.titleAndIcon)
        .disabled(actions.busy || store.tool.preparation.preparing)
      }
      ToolbarItem(placement: .primaryAction) {
        Button(String(localized: "Select all"), systemImage: "checklist") { store.selectAll(actions: actions) }
          .disabled(store.picture != nil || store.phase != .ready || actions.busy)
          .help(String(localized: "Select all"))
      }
    }
    .searchable(text: $searchText, prompt: String(localized: "Search by name or path"))
    .sheet(item: $actions.pending) { ConfirmationView(presentation: $0, actions: actions) }
    .task { store.open() }
    .onChange(of: actions.result?.planID) { store.observeResult(actions: actions) }
    .onDisappear { store.deactivate(actions: actions) }
    .animation(Theme.Motion.resolve(Theme.Motion.quick, reduceMotion: reduceMotion), value: store.selected)
    .animation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion), value: store.displayRevision)
  }

  private var subtitle: String {
    if store.phase == .scanning { return String(localized: "Scanning") }
    let date = store.picture?.observedAt ?? store.scannedAt
    return date.map { String(localized: "Last scan") + " " + $0.formatted(date: .abbreviated, time: .shortened) }
      ?? String(localized: "Not scanned")
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      HStack(alignment: .bottom, spacing: Theme.Space.xl) {
        HeroMetric(
          value: .bytes(store.toolSummary.logicalBytes, atLeast: store.toolSummary.partial),
          caption: String.localizedStringWithFormat(
            String(localized: "%lld items you can review"), Int64(store.toolSummary.count)),
          tone: store.toolSummary.logicalBytes > 0 ? .hero : .neutral)
        Spacer(minLength: Theme.Space.l)
        if !store.selected.isEmpty {
          Metric(
            value: .bytes(store.selectedLogicalBytes),
            caption: String.localizedStringWithFormat(String(localized: "%lld selected"), Int64(store.selected.count)),
            tone: .accent, compact: true)
        }
        InfoButton(
          text: String(
            localized: "Review caches and temporary files apps can recreate, plus data left by removed apps."))
      }
      statusRow
    }
    .padding(.top, Theme.Space.l)
  }

  @ViewBuilder private var statusRow: some View {
    if store.phase == .scanning {
      ScanStatusRow(
        status: String(localized: "Checking cache and temporary file locations"),
        count: store.scanProgress.count, bytes: store.scanProgress.bytes
      )
      .help(String(localized: "Counts update when each location finishes."))
    }
    if store.picture != nil {
      NoticeBar(String(localized: "Previous result. Scan again before cleaning."), symbol: "clock", tone: .neutral)
    } else if store.partial || !unreadableRows.isEmpty || !store.scanProgress.unreadablePaths.isEmpty {
      PartialNotice(
        store.partial
          ? String(localized: "Partial scan. Scan again before cleaning.")
          : String(localized: "Some locations could not be read")
      ) {
        if !store.scanProgress.unreadablePaths.isEmpty || !unreadableRows.isEmpty {
          DetailChip(String(localized: "Details"), symbol: "info.circle", tone: .neutral) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
              Text(String(localized: "Some cleaning locations could not be read. Details are listed below."))
              ForEach(unreadableRows) { row in
                Text(row.title(turkish: turkish)).font(Theme.Font.bodyMedium)
              }
              ForEach(store.scanProgress.unreadablePaths.sorted(), id: \.self) { path in
                PathLabel(path: path, lines: 2).textSelection(.enabled)
              }
            }
          }
        }
      }
    }
    if let message = store.message ?? actions.message {
      NoticeBar(message).textSelection(.enabled)
    }
  }

  private var unreadableRows: [CatalogRow] { store.rows.filter { store.rowStatuses[$0.id] == .unavailable } }

  // MARK: Categories

  private var categories: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      SectionHeader(String(localized: "Categories"))
      VStack(spacing: 0) {
        ForEach(Array(actionableRows.enumerated()), id: \.element.id) { index, row in
          if index > 0 { RowDivider(leading: Theme.Layout.rowTextInset) }
          CleanCategoryRow(
            row: row, candidates: filtered.filter { $0.row.id == row.id }, store: store, actions: actions,
            turkish: turkish)
        }
      }
      .moduleSurface()
    }
  }

  private var selectionBar: some View {
    FloatingBar {
      SelectionSummary(
        symbol: "sparkles",
        title: String.localizedStringWithFormat(String(localized: "%lld selected"), Int64(store.selected.count)),
        value: .bytes(store.selectedLogicalBytes))
    } actions: {
      if store.busy || actions.busy { ProgressView().controlSize(.small) }
      Button(String(localized: "Review selection")) { Task { await store.prepare(actions: actions) } }
        .buttonStyle(.glassProminent)
        .disabled(store.selected.isEmpty || store.phase != .ready || store.busy || actions.busy)
    }
  }

  // MARK: Previous result

  private func previousResults(_ picture: ResultPicture<CleanPicture>) -> some View {
    let rows = picture.content.rows.filter { row in
      searchTerm.isEmpty || row.path.localizedStandardContains(searchTerm)
        || store.rows.first { $0.id == row.categoryID }?.title(turkish: turkish)
          .localizedStandardContains(searchTerm) == true
    }
    let related = picture.content.relatedRows.filter {
      searchTerm.isEmpty || $0.path.localizedStandardContains(searchTerm)
    }
    var order: [String] = []
    var grouped: [String: [CleanPicture.Row]] = [:]
    for row in rows {
      if grouped[row.categoryID] == nil { order.append(row.categoryID) }
      grouped[row.categoryID, default: []].append(row)
    }
    let groups: [PreviousGroup] =
      order.map { id in
        let members = grouped[id] ?? []
        return PreviousGroup(
          id: id, title: store.rows.first { $0.id == id }?.title(turkish: turkish) ?? id,
          bytes: members.reduce(0) { $0 + $1.logicalBytes }, complete: members.allSatisfy(\.sizeComplete),
          items: members.map {
            PreviousItem(id: $0.id, path: $0.path, bytes: $0.logicalBytes, complete: $0.sizeComplete, detail: $0.detail)
          })
      }
      + (related.isEmpty
        ? []
        : [
          PreviousGroup(
            id: "related", title: String(localized: "Removed app data"),
            bytes: related.reduce(0) { $0 + ($1.logicalBytes ?? 0) }, complete: false,
            items: related.map {
              PreviousItem(id: $0.id, path: $0.path, bytes: $0.logicalBytes, complete: false, detail: $0.detail)
            })
        ])
    return VStack(alignment: .leading, spacing: Theme.Space.m) {
      SectionHeader(String(localized: "Categories"))
      VStack(spacing: 0) {
        if groups.isEmpty {
          Text(String(localized: "No items")).font(Theme.Font.body).foregroundStyle(Theme.Palette.inkSecondary)
            .padding(Theme.Space.l).frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
          if index > 0 { RowDivider(leading: Theme.Space.l) }
          PreviousCategoryRow(group: group)
        }
      }
      .moduleSurface()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CleanPictureDrawProbe { store.pictureDidDraw() })
  }

  // MARK: Needs review

  private var reviewRows: [CatalogRow] {
    store.rows.filter { row in
      filtered.contains { $0.row.id == row.id && !$0.canAct }
        || store.rowStatuses[row.id] == .unavailable || store.rowStatuses[row.id] == .toolRunning
        || store.rowStatuses[row.id] == .processUnknown
    }
  }

  private var reportOnly: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      SectionHeader(String(localized: "Needs review")) {
        InfoButton(text: String(localized: "These items stay out of a cleaning plan. Each one shows why."))
      }
      VStack(spacing: 0) {
        ForEach(Array(reviewRows.enumerated()), id: \.element.id) { index, row in
          if index > 0 { RowDivider(leading: Theme.Space.l) }
          let reasons = reportReasons(row)
          HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
              Text(row.title(turkish: turkish)).font(Theme.Font.bodyMedium)
              Text(reasons.first ?? "").font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
                .lineLimit(1).help(reasons.joined(separator: "\n"))
            }
            Spacer(minLength: Theme.Space.s)
            DetailChip(
              reasons.count > 1
                ? String.localizedStringWithFormat(String(localized: "%lld reasons"), Int64(reasons.count))
                : String(localized: "Why"),
              symbol: "info.circle", tone: .neutral
            ) {
              VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(reasons, id: \.self) { Text($0) }
              }
            }
            ShowInFinderButton(path: store.homeDirectory + "/" + row.relativeRoot, compact: true)
              .buttonStyle(.borderless)
            if store.rowStatuses[row.id] == .unavailable
              || store.candidates.contains(where: { $0.row.id == row.id && $0.requiresFullDiskAccess })
            {
              Button(String(localized: "Open Full Disk Access settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                  NSWorkspace.shared.open(url)
                }
              }
              .controlSize(.small)
            }
          }
          .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s + 2)
        }
      }
      .moduleSurface()
    }
  }

  // MARK: Removed app data

  private var removedData: some View {
    let grouped = Dictionary(grouping: related, by: bundleID)
    return VStack(alignment: .leading, spacing: Theme.Space.m) {
      SectionHeader(String(localized: "Removed app data"))
      VStack(spacing: 0) {
        ForEach(Array(grouped.keys.sorted().enumerated()), id: \.element) { index, id in
          if index > 0 { RowDivider(leading: Theme.Space.l) }
          DisclosureGroup {
            ForEach(grouped[id] ?? []) { candidate in
              HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                  Text(URL(fileURLWithPath: candidate.path).lastPathComponent).font(Theme.Font.body).lineLimit(1)
                  Text(relatedReason(candidate.reason)).font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.inkSecondary).lineLimit(2)
                }
                .help(candidate.path)
                Spacer(minLength: Theme.Space.s)
                if store.phase == .ready {
                  Button(String(localized: "Review Trash")) {
                    Task { await store.prepareRelated(candidate, actions: actions) }
                  }
                  .controlSize(.small)
                  .disabled(store.phase != .ready || store.busy || actions.busy)
                } else {
                  ShowInFinderButton(path: candidate.path, compact: true).buttonStyle(.borderless)
                }
              }
              .padding(.vertical, Theme.Space.xs)
            }
          } label: {
            HStack {
              Text(id).font(Theme.Font.bodyMedium).lineLimit(1)
              Spacer()
              Text((grouped[id] ?? []).count.formatted()).font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Palette.inkSecondary)
            }
          }
          .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s + 2)
        }
      }
      .moduleSurface()
    }
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

private struct PreviousItem: Identifiable {
  let id: String
  let path: String
  let bytes: Int64?
  let complete: Bool
  let detail: String?
}

private struct PreviousGroup: Identifiable {
  let id: String
  let title: String
  let bytes: Int64
  let complete: Bool
  let items: [PreviousItem]
}

/// A category from the previous result: its total, and its items behind a disclosure.
private struct PreviousCategoryRow: View {
  let group: PreviousGroup
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion)) { expanded.toggle() }
      } label: {
        HStack(spacing: Theme.Space.m) {
          Image(systemName: "chevron.right").font(Theme.Font.iconSmall)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .foregroundStyle(Theme.Palette.inkSecondary)
            .frame(width: Theme.Space.l)
          Text(group.title).font(Theme.Font.bodyMedium).foregroundStyle(Theme.Palette.ink)
          Spacer(minLength: Theme.Space.s)
          VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
            Text(
              (group.complete ? "" : "≥ ") + ByteCountFormatter.string(fromByteCount: group.bytes, countStyle: .file)
            )
            .font(Theme.Font.mono).foregroundStyle(Theme.Palette.ink)
            Text(String.localizedStringWithFormat(String(localized: "%lld items"), Int64(group.items.count)))
              .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
          }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
      if expanded {
        LazyVStack(spacing: 0) {
          ForEach(group.items) { item in
            HStack(spacing: Theme.Space.s) {
              Text(URL(fileURLWithPath: item.path).lastPathComponent).font(Theme.Font.callout)
                .lineLimit(1).truncationMode(.middle)
              if let detail = item.detail {
                Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1)
              }
              Spacer(minLength: Theme.Space.s)
              if let bytes = item.bytes {
                Text((item.complete ? "" : "≥ ") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                  .font(Theme.Font.monoSmall).foregroundStyle(Theme.Palette.inkSecondary)
              }
              ShowInFinderButton(path: item.path, compact: true).buttonStyle(.borderless)
            }
            .help(item.path)
            .padding(.vertical, Theme.Space.xs)
          }
        }
        .padding(.leading, Theme.Layout.rowTextInset).padding(.trailing, Theme.Space.l)
        .padding(.bottom, Theme.Space.m)
        .transition(Theme.Motion.transition(Theme.Motion.rise, reduceMotion: reduceMotion))
      }
    }
  }
}

/// One cleaning category: a checkbox for the whole category, its reason on one line, and the items
/// it would clean behind a disclosure.
private struct CleanCategoryRow: View {
  let row: CatalogRow
  let candidates: [CleanCandidate]
  @Bindable var store: CleanStore
  @Bindable var actions: ActionStore
  let turkish: Bool
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var ids: Set<UUID> { Set(candidates.map(\.id)) }
  private var isOn: Bool { !ids.isEmpty && ids.isSubset(of: store.selected) }
  private var isMixed: Bool { !isOn && !ids.isDisjoint(with: store.selected) }
  private var bytes: Int64 { candidates.reduce(Int64(0)) { $0 + $1.logicalBytes } }
  private var incomplete: Bool { candidates.contains { !$0.sizeComplete } }
  private var explanation: String { row.reason(turkish: turkish) + " " + row.cost(turkish: turkish) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Space.m) {
        Button {
          store.toggleCategory(row.id, actions: actions)
        } label: {
          CheckSymbol(isOn: isOn, isMixed: isMixed)
        }
        .buttonStyle(.plain)
        .disabled(store.phase != .ready || actions.busy)
        .accessibilityLabel(row.title(turkish: turkish))
        .accessibilityValue(isOn ? String(localized: "Selected") : String(localized: "Not selected"))
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
          Text(row.title(turkish: turkish)).font(Theme.Font.bodyMedium).foregroundStyle(Theme.Palette.ink)
          Text(explanation).font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1)
        }
        .help(explanation)
        Spacer(minLength: Theme.Space.s)
        VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
          Text((incomplete ? "≥ " : "") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            .font(Theme.Font.mono).foregroundStyle(Theme.Palette.ink)
            .contentTransition(reduceMotion ? .opacity : .numericText())
          Text(String.localizedStringWithFormat(String(localized: "%lld items"), Int64(candidates.count)))
            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
        }
        Button {
          withAnimation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion)) { expanded.toggle() }
        } label: {
          Image(systemName: "chevron.right").font(Theme.Font.iconSmall)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .foregroundStyle(Theme.Palette.inkSecondary)
            .frame(width: Theme.Space.l, height: Theme.Space.l)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Inspect items"))
        .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
      }
      .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
      if expanded {
        VStack(spacing: 0) {
          ForEach(candidates) { candidate in
            HStack(spacing: Theme.Space.s) {
              VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(URL(fileURLWithPath: candidate.entry.path).lastPathComponent).font(Theme.Font.callout)
                  .lineLimit(1).truncationMode(.middle)
                if let reason = actions.failure(at: candidate.entry.path) {
                  Text(reason).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              .help(candidate.entry.path)
              Spacer(minLength: Theme.Space.s)
              Text(ByteCountFormatter.string(fromByteCount: candidate.logicalBytes, countStyle: .file))
                .font(Theme.Font.monoSmall).foregroundStyle(Theme.Palette.inkSecondary)
              ShowInFinderButton(path: candidate.entry.path, compact: true).buttonStyle(.borderless)
            }
            .padding(.vertical, Theme.Space.xs)
          }
        }
        .padding(.leading, Theme.Layout.rowTextInset).padding(.trailing, Theme.Space.l)
        .padding(.bottom, Theme.Space.m)
        .transition(Theme.Motion.transition(Theme.Motion.rise, reduceMotion: reduceMotion))
      }
    }
    .accessibilityElement(children: .contain)
  }
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
