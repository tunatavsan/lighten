import AppKit
import LightenKit
import SwiftUI

struct AppsView: View {
  @Bindable var store: AppsStore
  @Bindable var actions: ActionStore
  @State private var searchText = ""
  @State private var visibleListPaths: Set<String> = []
  @State private var showingCompactDetail = false
  @State private var expandedOrphans: Set<String> = []
  @State private var showingOtherLocations = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var filtered: [ApplicationReport] {
    matching(store.defaultApplicationReports)
  }

  private var otherFiltered: [ApplicationReport] { matching(store.otherLocationReports) }

  private func matching(_ reports: [ApplicationReport]) -> [ApplicationReport] {
    let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return reports }
    return reports.filter {
      store.displayName($0).localizedStandardContains(term) || $0.path.localizedStandardContains(term)
        || ($0.bundleID?.localizedStandardContains(term) == true)
    }
  }

  var body: some View {
    let scanBusy = store.busy
    ToolScreen(String(localized: "Apps"), subtitle: subtitle) {
      VStack(alignment: .leading, spacing: 0) {
        header
        GeometryReader { geometry in
          content(compact: geometry.size.width < Theme.Layout.appsCompactWidth)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .padding(.bottom, Theme.Space.l)
      }
      .padding(.horizontal, Theme.Layout.gutter)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .floatingBar(isPresented: !store.selectedAppPaths.isEmpty || !store.selectedOrphanPaths.isEmpty) {
        AppsBasketView(store: store, actions: actions)
      }
    } toolbar: {
      ToolbarItem(placement: .primaryAction) {
        Button(
          store.busy ? String(localized: "Cancel scan") : String(localized: "Scan"),
          systemImage: store.busy ? "stop.fill" : "arrow.clockwise"
        ) {
          if store.busy { store.cancelScan() } else { store.startScan(actions: actions) }
        }
        .labelStyle(.titleAndIcon)
        .accessibilityIdentifier("apps.scan-control")
      }
    }
    .searchable(text: $searchText, prompt: String(localized: "Search by name or path"))
    .onGeometryChange(for: Bool.self) { _ in
      scanBusy
    } action: { busy in
      if !busy { store.scanDidLayout() }
    }
    .animation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion), value: store.displayRevision)
    .sheet(item: $actions.pending) { presentation in
      ConfirmationView(presentation: presentation, actions: actions)
    }
    .animation(Theme.Motion.resolve(Theme.Motion.quick, reduceMotion: reduceMotion), value: store.selectedPath)
    .animation(Theme.Motion.resolve(Theme.Motion.quick, reduceMotion: reduceMotion), value: store.selectedDataPaths)
    .onChange(of: store.selectedPath) { _, path in
      if path == nil { showingCompactDetail = false }
    }
    .onChange(of: actions.result?.planID) { _, _ in store.observeResult(actions: actions) }
    .onAppear {
      store.observeResult(actions: actions)
      store.open(actions: actions)
    }
    .onDisappear { store.deactivate(actions: actions) }
    .dropDestination(for: URL.self) { urls, _ in
      Task { await store.acceptDrop(urls, actions: actions) }
      return true
    }
  }

  private var subtitle: String {
    if store.busy { return String(localized: "Scanning") }
    let date = store.pictureObservedAt ?? store.scannedAt
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
            String(localized: "%lld applications"),
            Int64(store.showsPreviousResult ? store.defaultPictureRows.count : store.defaultApplicationReports.count)))
        Spacer(minLength: Theme.Space.l)
        InfoButton(
          text: String(
            localized: "The app and its data are measured separately. Disk space is freed when you empty Trash."))
      }
      statusRow
    }
    .padding(.top, Theme.Space.l)
    .padding(.bottom, Theme.Space.m)
  }

  @ViewBuilder private var statusRow: some View {
    if store.busy {
      ScanStatusRow(
        status: store.measuringPaths.isEmpty
          ? String(localized: "Checking app data") : String(localized: "Measuring apps"),
        count: store.defaultMeasuredCount)
    }
    if store.needsRescan {
      NoticeBar(
        String(localized: "This list needs a new scan before actions are available."),
        symbol: "arrow.clockwise.circle")
    }
    if let message = store.message {
      NoticeBar(message).textSelection(.enabled)
    }
    let chips = coverageChips
    FlowChips {
      chips
      omittedChip
      ForEach(store.packageItemResults) { item in
        DetailChip(
          (item.isLink ? String(localized: "Application link") : String(localized: "Application")) + ": "
            + packageOutcome(item.outcome),
          symbol: item.outcome == .applied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
          tone: item.outcome == .applied ? .positive : .warning
        ) {
          VStack(alignment: .leading, spacing: Theme.Space.s) {
            PathLabel(path: item.sourcePath, lines: 3).textSelection(.enabled)
            if item.outcome != .applied {
              FailureReasonView(
                presentation: FailureText.executionPresentation(
                  ItemActionResult(
                    itemID: item.id, outcome: item.outcome, detail: item.detail, mutationStage: item.mutationStage)))
            }
          }
        }
      }
    }
    ActionFeedbackView(actions: actions)
  }

  @ViewBuilder private var coverageChips: some View {
    let incompleteInventory = !store.busy && store.backgroundFinishedAt != nil && !store.inventoryComplete
    if store.hasCoverageIssue || store.relatedDiscoveryStopped {
      let stopped = incompleteInventory || store.relatedDiscoveryStopped
      DetailChip(
        stopped ? String(localized: "Incomplete list") : String(localized: "Some open files not checked"),
        symbol: stopped ? "exclamationmark.triangle.fill" : "info.circle", tone: stopped ? .warning : .neutral
      ) {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
          if stopped {
            Text(
              store.relatedDiscoveryStopped
                ? String(
                  localized: "App data checking stopped before all items were found. Scan again to complete the list.")
                : String(localized: "Some apps could not be checked. Scan again to complete the list."))
          } else {
            Text(String(localized: "Some open files could not be checked. Your selections are still available."))
          }
          ForEach(store.coverageIssueDescriptions, id: \.self) { reason in
            Text(reason).foregroundStyle(Theme.Palette.inkSecondary).textSelection(.enabled)
          }
        }
      }
    }
    if store.externalVolumesUnchecked {
      DetailChip(String(localized: "Other disks not included"), symbol: "externaldrive", tone: .neutral) {
        Text(String(localized: "Apps on disks that are disconnected or unavailable are not included."))
      }
    }
  }

  @ViewBuilder private var omittedChip: some View {
    let counts = omittedCounts
    let total = counts.values.reduce(0, +)
    if total > 0 {
      DetailChip(
        String.localizedStringWithFormat(String(localized: "%lld hidden"), Int64(total)), symbol: "eye.slash",
        tone: .neutral
      ) {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
          Text(
            String.localizedStringWithFormat(
              String(localized: "%lld applications omitted from this list"), Int64(total))
          )
          .font(Theme.Font.bodyMedium)
          ForEach(AppListScope.ExclusionReason.allCases, id: \.self) { reason in
            if let count = counts[reason], count > 0 {
              Text("\(omissionLabel(reason)): \(count)").foregroundStyle(Theme.Palette.inkSecondary)
            }
          }
        }
      }
    }
  }

  // MARK: Content

  @ViewBuilder private func content(compact: Bool) -> some View {
    if store.showsPreviousResult {
      pictureList.moduleSurface()
    } else if store.reports.isEmpty && store.orphanCandidates.isEmpty && !store.busy {
      EmptyState(
        symbol: "app.dashed",
        title: store.scannedAt == nil
          ? String(localized: "Scan installed apps") : String(localized: "No applications found"),
        message: String(localized: "Inspect applications in /Applications and your Applications folder."),
        tint: Theme.Palette.toolApps
      ) {
        if store.scannedAt == nil {
          Button(String(localized: "Scan")) { store.startScan(actions: actions) }.buttonStyle(.hero)
        }
      }
    } else if store.busy && store.reports.isEmpty {
      EmptyState(symbol: "app.dashed", title: String(localized: "Scanning applications"), tint: Theme.Palette.toolApps)
      {
        ProgressView().controlSize(.small)
      }
    } else if compact {
      if showingCompactDetail, let app = store.selectedReport {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
          Button {
            withAnimation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion)) {
              showingCompactDetail = false
            }
          } label: {
            Label(String(localized: "All apps"), systemImage: "chevron.left")
          }
          .buttonStyle(.borderless)
          detail(app).moduleSurface()
        }
      } else {
        applicationList.moduleSurface()
      }
    } else {
      HStack(alignment: .top, spacing: Theme.Space.m) {
        applicationList
          .frame(width: Theme.Layout.listColumn)
          .moduleSurface()
        Group {
          if let app = store.selectedReport {
            detail(app)
          } else {
            EmptyState(
              symbol: "cursorarrow.click.2", title: String(localized: "Select an application"),
              tint: Theme.Palette.inkTertiary)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .moduleSurface()
      }
    }
  }

  private var omittedCounts: [AppListScope.ExclusionReason: Int] {
    let paths =
      store.omittedApplicationPaths
      + (store.showsPreviousResult ? store.pictureRows.map(\.path) : store.reports.map(\.path))
    return AppListScope.omittedCounts(paths: paths, homeDirectory: store.listScopeHomeDirectory)
  }

  private func omissionLabel(_ reason: AppListScope.ExclusionReason) -> String {
    switch reason {
    case .system: String(localized: "System applications")
    case .nestedApplication: String(localized: "Helpers inside another application")
    case .buildArtifact: String(localized: "Build and development artifacts")
    case .trash: String(localized: "Applications in Trash")
    case .iosPlaceholder: String(localized: "iOS application placeholders")
    }
  }

  private func otherLocationExplanation(_ path: String) -> String? {
    switch AppListScope.otherLocationReason(of: path, homeDirectory: store.listScopeHomeDirectory) {
    case .hiddenFolder: String(localized: "Application copy in a hidden folder")
    case .outsideApplicationsFolders: String(localized: "Outside the standard Applications folders")
    case nil: nil
    }
  }

  private var applicationList: some View {
    Group {
      if filtered.isEmpty && otherFiltered.isEmpty && store.orphanCandidates.isEmpty {
        EmptyState(
          symbol: "magnifyingglass", title: String(localized: "No matching applications"),
          tint: Theme.Palette.inkTertiary)
      } else {
        ScrollView {
          LazyVStack(spacing: Theme.Space.xxs) {
            applicationRows(filtered)
            if !otherFiltered.isEmpty {
              DisclosureGroup(isExpanded: $showingOtherLocations) {
                applicationRows(otherFiltered)
              } label: {
                Text("\(String(localized: "Other locations")) (\(otherFiltered.count))")
                  .font(Theme.Font.headline)
              }
              .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.s)
            }
            orphanSection
          }
          .padding(Theme.Space.xs + 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(listViewport(paths: filtered.map(\.path) + (showingOtherLocations ? otherFiltered.map(\.path) : [])))
      }
    }
  }

  private func applicationRows(_ applications: [ApplicationReport]) -> some View {
    ForEach(applications) { app in
      appRow(app)
        .transformAnchorPreference(key: ApplicationRowPreferenceKey.self, value: .bounds) { values, anchor in
          var row = values[app.path] ?? ApplicationRowPreference()
          row.bounds = anchor
          values[app.path] = row
        }
        .transition(Theme.Motion.transition(Theme.Motion.pop, reduceMotion: reduceMotion))
    }
  }

  private func matchingPictures(_ rows: [AppsPicture.Row]) -> [AppsPicture.Row] {
    rows.filter {
      searchText.isEmpty || $0.path.localizedStandardContains(searchText)
        || $0.bundleID?.localizedStandardContains(searchText) == true
    }
  }

  private var pictureList: some View {
    let primary = matchingPictures(store.defaultPictureRows)
    let other = matchingPictures(store.otherPictureRows)
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: Theme.Space.xxs) {
        NoticeBar(
          store.busy
            ? String(localized: "Previous result · refreshing before actions")
            : String(localized: "Previous result · scan again before actions"), symbol: "clock", tone: .neutral
        )
        .padding(.bottom, Theme.Space.xs)
        if primary.isEmpty && other.isEmpty {
          Text(String(localized: "No applications found"))
            .font(Theme.Font.body).foregroundStyle(Theme.Palette.inkSecondary).padding(Theme.Space.s)
        }
        ForEach(primary) { pictureRow($0) }
        if !other.isEmpty {
          DisclosureGroup(isExpanded: $showingOtherLocations) {
            ForEach(other) { pictureRow($0) }
          } label: {
            Text("\(String(localized: "Other locations")) (\(other.count))").font(Theme.Font.headline)
          }
          .padding(Theme.Space.s)
        }
      }
      .padding(Theme.Space.s)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .modifier(listViewport(paths: primary.map(\.path) + (showingOtherLocations ? other.map(\.path) : [])))
  }

  private func pictureRow(_ row: AppsPicture.Row) -> some View {
    HStack(spacing: Theme.Space.m) {
      ApplicationIconView(path: row.path, isVisible: visibleListPaths.contains(row.path))
      VStack(alignment: .leading, spacing: Theme.Space.xxs) {
        Text(URL(fileURLWithPath: row.path).deletingPathExtension().lastPathComponent)
          .font(Theme.Font.bodyMedium).lineLimit(1)
        Text(otherLocationExplanation(row.path) ?? row.path)
          .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
          .lineLimit(1).truncationMode(.middle).help(row.path)
      }
      Spacer(minLength: Theme.Space.s)
      Text(format(row.logical.completeTotal ?? row.logical.knownLowerBound))
        .font(Theme.Font.mono).foregroundStyle(Theme.Palette.inkSecondary)
    }
    .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs + 2)
    .accessibilityElement(children: .combine)
    .transformAnchorPreference(key: ApplicationRowPreferenceKey.self, value: .bounds) { values, anchor in
      var value = values[row.path] ?? ApplicationRowPreference()
      value.bounds = anchor
      values[row.path] = value
    }
  }

  private func listViewport(paths: [String]) -> ApplicationListViewport {
    ApplicationListViewport(
      orderedPaths: paths, revision: store.openingRevision,
      visibilityChanged: { paths in
        visibleListPaths = paths
        store.viewportVisibilityChanged(paths)
      },
      didDraw: { [revision = store.openingRevision] snapshot in
        store.viewportDidDraw(snapshot, revision: revision)
      })
  }

  private var orphanSection: some View {
    let groups = Dictionary(grouping: store.orphanCandidates) {
      $0.bundleID ?? $0.receipt?.bundleID ?? String(localized: "Unknown")
    }
    return VStack(alignment: .leading, spacing: Theme.Space.s) {
      if !groups.isEmpty {
        HStack {
          Text(String(localized: "Data from removed apps")).font(Theme.Font.headline)
          Spacer()
          InfoButton(
            text: String(
              localized:
                "Remaining app data may contain settings or documents. Review each reason; nothing is selected automatically."
            ))
        }
        ForEach(groups.keys.sorted(), id: \.self) { bundleID in
          DisclosureGroup(
            isExpanded: Binding(
              get: { expandedOrphans.contains(bundleID) },
              set: { if $0 { expandedOrphans.insert(bundleID) } else { expandedOrphans.remove(bundleID) } }
            )
          ) {
            ForEach(groups[bundleID] ?? []) { candidate in
              HStack(alignment: .top, spacing: Theme.Space.s) {
                if store.canSelectOrphan(candidate) {
                  Button {
                    store.toggleOrphan(candidate.path, actions: actions)
                  } label: {
                    CheckSymbol(isOn: store.selectedOrphanPaths.contains(candidate.path))
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel(candidate.path)
                } else {
                  Image(systemName: "info.circle.fill").foregroundStyle(Theme.Palette.warning)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                  Text(URL(fileURLWithPath: candidate.path).lastPathComponent).font(Theme.Font.callout)
                    .lineLimit(1).truncationMode(.middle).help(candidate.path)
                  FailureReasonView(
                    presentation: store.retainedReason(candidate) ?? FailureText.candidate(candidate))
                  if let date = candidate.modifiedAt {
                    HStack(spacing: Theme.Space.xxs) {
                      Text(String(localized: "Modified:"))
                      Text(date, style: .date)
                    }
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
                  }
                }
                Spacer(minLength: Theme.Space.xs)
                ShowInFinderButton(path: candidate.path, compact: true).buttonStyle(.borderless)
              }
              .padding(.vertical, Theme.Space.xs)
            }
          } label: {
            Text(bundleID).font(Theme.Font.bodyMedium).lineLimit(1).truncationMode(.middle)
          }
        }
        if store.preparing || actions.busy { reviewExplanation }
      }
    }
    .padding(.horizontal, Theme.Space.s)
    .padding(.top, groups.isEmpty ? 0 : Theme.Space.l)
  }

  private var reviewExplanation: some View {
    Text(store.reviewExplanation(actions: actions))
      .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
  }

  private func appRow(_ app: ApplicationReport) -> some View {
    let selected = store.selectedPath == app.path
    let warning: String? =
      store.busy
      ? nil
      : store.packageUnavailableReason(app)
        ?? (store.ownershipPendingPaths.contains(app.path)
          ? String(localized: "Some app data could not be matched.") : nil)
    return HStack(spacing: Theme.Space.xs) {
      Toggle(
        isOn: Binding(
          get: { store.selectedAppPaths.contains(app.path) },
          set: { _ in store.selectApp(app.path, intent: .toggle, actions: actions) }
        )
      ) { EmptyView() }
      .toggleStyle(.checkbox)
      .accessibilityLabel("\(String(localized: "Select app for removal")): \(store.displayName(app))")
      .disabled(store.needsRescan || actions.busy || store.packageUnavailableReason(app) != nil)
      Button {
        let modifiers = NSEvent.modifierFlags
        let intent: AppSelectionIntent =
          modifiers.contains(.shift) ? .range : modifiers.contains(.command) ? .toggle : .single
        let ordered = filtered.map(\.path) + (showingOtherLocations ? otherFiltered.map(\.path) : [])
        store.selectApp(app.path, intent: intent, orderedPaths: ordered, actions: actions)
        showingCompactDetail = true
      } label: {
        HStack(spacing: Theme.Space.s) {
          ApplicationIconView(path: app.path, isVisible: visibleListPaths.contains(app.path))
          VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(store.displayName(app))
              .font(Theme.Font.bodyMedium).lineLimit(1).truncationMode(.middle)
            Text(otherLocationExplanation(app.path) ?? app.bundleID ?? String(localized: "Identity unavailable"))
              .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
              .lineLimit(1).truncationMode(.middle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if let warning {
            Image(systemName: "exclamationmark.triangle.fill").font(Theme.Font.iconTiny)
              .foregroundStyle(Theme.Palette.warning)
              .help(warning)
              .accessibilityLabel(warning)
          }
          Text(store.measuringPaths.contains(app.path) ? String(localized: "Measuring") : rowSize(app))
            .font(Theme.Font.monoSmall).foregroundStyle(Theme.Palette.inkSecondary)
            .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs + 2)
        .background {
          if selected {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.selection)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(store.needsRescan || actions.busy)
      .accessibilityLabel(
        "\(app.path), \(store.measuringPaths.contains(app.path) ? String(localized: "Measuring") : app.partial ? String(localized: "Partial size") : String(localized: "Measured size"))"
      )
    }
    .padding(.leading, Theme.Space.xs)
    .overlay(alignment: .bottomLeading) {
      if let reason = actions.failure(at: app.path) {
        Color.clear.help(reason).accessibilityLabel(reason)
      }
    }
  }

  private func rowSize(_ app: ApplicationReport) -> String {
    let size = sizeText(app)
    return app.partial && app.logical.knownLowerBound > 0 ? "≥ " + size : size
  }

  // MARK: Detail

  private func detail(_ app: ApplicationReport) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Space.l) {
        HStack(alignment: .center, spacing: Theme.Space.m) {
          ApplicationIconView(path: app.path, size: Theme.Layout.appIconLarge)
          VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(store.displayName(app))
              .font(Theme.Font.title).lineLimit(2).truncationMode(.middle)
            PathLabel(path: app.path).textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
            Text(store.measuringPaths.contains(app.path) ? String(localized: "Measuring") : sizeText(app))
              .font(Theme.Font.metric).monospacedDigit()
            Text(
              app.partial && app.logical.knownLowerBound == 0
                ? String(localized: "Size unavailable")
                : app.partial ? String(localized: "At least") : String(localized: "File size")
            )
            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
          }
        }
        if let reason = actions.failure(at: app.path) {
          NoticeBar(reason)
        }
        FlowChips {
          if let id = app.bundleID, store.runningIDs.contains(id) {
            DetailChip(String(localized: "Running"), symbol: "pause.circle") {
              Text(
                String(
                  localized: "App is running. You can close it and remove your selected items in the confirmation."))
            }
          }
          if app.manualUninstallerSuggested {
            DetailChip(String(localized: "Has a helper"), symbol: "puzzlepiece.extension") {
              Text(String(localized: "This app contains a system extension or helper. Check the vendor's uninstaller."))
            }
          }
          if app.bundleID == nil {
            DetailChip(String(localized: "No identifier"), symbol: "info.circle", tone: .neutral) {
              Text(String(localized: "Some app data could not be matched because this app has no identifier."))
            }
          }
          if let reason = otherLocationExplanation(app.path) {
            Chip(title: reason, symbol: "folder", tone: .neutral)
          }
        }
        VStack(spacing: 0) {
          metadataRow(String(localized: "App identifier"), app.bundleID ?? String(localized: "Unknown"))
          if let target = app.linkTarget {
            RowDivider(leading: Theme.Space.m)
            metadataRow(String(localized: "Application"), target)
          }
          RowDivider(leading: Theme.Space.m)
          metadataRow(String(localized: "Version"), app.version ?? String(localized: "Unknown"))
          if let signer = app.signerTeamID, !signer.isEmpty {
            RowDivider(leading: Theme.Space.m)
            metadataRow(String(localized: "Signer"), signer)
          }
        }
        .background(Theme.Palette.well, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        packageSelection(app)
        relatedSection(app)
      }
      .padding(Theme.Space.l)
    }
    .modifier(
      RelatedListViewport(
        candidatePaths: Set(app.related.map(\.path)), revision: store.selectedDrawRevision,
        didDraw: { snapshot, revision in store.selectedListDidDraw(snapshot, revision: revision) }))
  }

  private func metadataRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
      Text(title).font(Theme.Font.callout).foregroundStyle(Theme.Palette.inkSecondary)
      Spacer(minLength: Theme.Space.m)
      Text(value).font(Theme.Font.callout).textSelection(.enabled)
        .lineLimit(1).truncationMode(.middle).help(value)
    }
    .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
  }

  private func packageSelection(_ app: ApplicationReport) -> some View {
    let reason = store.packageUnavailableReason(app)
    return HStack(alignment: .top, spacing: Theme.Space.m) {
      if reason == nil {
        Button {
          store.togglePackage(actions: actions)
        } label: {
          CheckSymbol(isOn: store.packageSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Move the whole app to Trash"))
      } else {
        Image(systemName: "info.circle.fill").foregroundStyle(Theme.Palette.warning)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: Theme.Space.xxs) {
        Text(String(localized: "Move the whole app to Trash")).font(Theme.Font.bodyMedium)
        Text(
          reason
            ?? (app.linkTarget != nil
              ? String(localized: "Only this link is selected. The application it points to stays in place.")
              : String(localized: "The app moves as one package. Its data below stays unless you select it too."))
        )
        .font(Theme.Font.caption).foregroundStyle(reason == nil ? Theme.Palette.inkSecondary : Theme.Palette.warning)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      if reason != nil {
        ShowInFinderButton(path: app.path, compact: true).buttonStyle(.borderless)
      }
    }
    .padding(Theme.Space.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.Palette.well, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
  }

  private func relatedSection(_ app: ApplicationReport) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      SectionHeader(String(localized: "App data")) {
        InfoButton(
          text: String(localized: "Choose which app data to remove along with the app.") + " "
            + String(localized: "Data shared with other apps is never selected automatically."))
      }
      if app.related.isEmpty {
        Text(
          store.needsRescan
            ? String(localized: "Scan again to review app data")
            : store.relatedDiscoveryStopped
              ? String(localized: "App data checking stopped before all items were found.")
              : store.selectedReviewPending && !store.selectedShallowComplete
                ? String(localized: "App data is being reviewed")
                : String(localized: "No app data found in the locations checked")
        )
        .font(Theme.Font.callout).foregroundStyle(Theme.Palette.inkSecondary)
        .anchorPreference(key: RelatedRowPreferenceKey.self, value: .bounds) {
          store.selectedShallowComplete ? [RelatedListViewportSnapshot.emptyResultID: $0] : [:]
        }
      }
      if let note = store.lateSelectedDataNote {
        NoticeBar(note, symbol: "info.circle", tone: .neutral)
          .accessibilityIdentifier("apps.late-selected-data")
      }
      if let progress = store.selectedMeasurementProgress {
        ScanStatusRow(
          status: String.localizedStringWithFormat(
            String(localized: "Measuring app data: %lld / %lld"), Int64(progress.completed), Int64(progress.total)))
      }
      if store.selectedEvidencePending || store.ownershipPendingPaths.contains(app.path) {
        NoticeBar(
          store.selectedEvidencePending
            ? String(localized: "Checking app data. You can review your selection now.")
            : String(localized: "Some app data could not be matched. You can still choose items yourself."),
          symbol: store.selectedEvidencePending ? "clock" : "info.circle", tone: .neutral)
      }
      let main = app.related.filter {
        $0.classification != .unprovenNameOnly && $0.provenance?.kind != .configuredDirectory
      }
      if !main.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(main.enumerated()), id: \.element.id) { index, candidate in
            if index > 0 { RowDivider(leading: Theme.Layout.rowTextInset) }
            relatedRow(candidate, app: app)
          }
        }
        .background(Theme.Palette.well, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
      }
      let documents = app.related.filter { $0.provenance?.kind == .configuredDirectory }
      if !documents.isEmpty {
        relatedGroup(
          title: String(localized: "App’s documents folders"),
          note: String(localized: "These folders may contain your documents and are never selected automatically."),
          candidates: documents, app: app)
      }
      let unproven = app.related.filter { $0.classification == .unprovenNameOnly }
      if !unproven.isEmpty {
        relatedGroup(
          title: String.localizedStringWithFormat(
            String(localized: "These names resemble %@. Choose only items you recognize."),
            URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent),
          note: String(
            localized: "These items are not selected automatically. Check them before choosing to remove them."),
          candidates: unproven, app: app)
      }
    }
  }

  private func relatedGroup(
    title: String, note: String, candidates: [RelatedDataCandidate], app: ApplicationReport
  ) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(Theme.Font.headline).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: Theme.Space.s)
        DetailChip(String(localized: "Why"), symbol: "info.circle") { Text(note) }
      }
      .padding(.top, Theme.Space.s)
      VStack(spacing: 0) {
        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
          if index > 0 { RowDivider(leading: Theme.Layout.rowTextInset) }
          relatedRow(candidate, app: app)
        }
      }
      .background(Theme.Palette.well, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
    .accessibilityElement(children: .contain)
  }

  private func relatedRow(_ candidate: RelatedDataCandidate, app: ApplicationReport) -> some View {
    let eligible = canSelect(candidate, app: app)
    let selected = store.selectedDataPaths.contains(candidate.path)
    let automatic = store.isAutomaticallySelected(candidate, app: app)
    let note = automatic ? nil : selected ? nil : automaticSelectionNote(candidate, app: app)
    let otherPaths = store.otherInstallationPaths(candidate: candidate, app: app)
    let mozilla = selected && (candidate.provenance?.kind == .mozilla || candidate.evidenceKinds.contains(.mozilla))
    let summary =
      candidate.provenance.map { AppsSurfaceText.provenance($0.kind) }
      ?? (candidate.reason == .installed && candidate.refusalEvidence.isEmpty
        ? AppsSurfaceText.associatedData(candidate) : FailureText.candidate(candidate).primaryReason)
    return HStack(alignment: .center, spacing: Theme.Space.m) {
      if eligible {
        Button {
          store.toggleData(candidate.path, actions: actions)
        } label: {
          CheckSymbol(isOn: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "\(selected ? String(localized: "Deselect") : String(localized: "Select")) \(URL(fileURLWithPath: candidate.path).lastPathComponent)"
        )
      } else {
        Image(systemName: "lock.fill").font(Theme.Font.iconSmall).foregroundStyle(Theme.Palette.inkTertiary)
          .frame(width: Theme.Space.l)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: Theme.Space.xxs) {
        Text(URL(fileURLWithPath: candidate.path).lastPathComponent)
          .font(Theme.Font.callout).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
        Text(automatic ? String(localized: "Selected automatically as app data.") : summary)
          .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1)
      }
      .help(candidate.path)
      Spacer(minLength: Theme.Space.s)
      if !otherPaths.isEmpty || mozilla || actions.failure(at: candidate.path) != nil {
        DetailChip(String(localized: "Review"), symbol: "exclamationmark.triangle.fill") {
          VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let reason = actions.failure(at: candidate.path) { Text(reason) }
            if mozilla {
              Text(
                String(
                  localized: "Profiles may contain mail, browsing history, and personal data. Review before removal."))
            }
            if !otherPaths.isEmpty {
              Text(
                String(
                  localized:
                    "This data is also used by another installation. Removing it may affect that installation."))
              ForEach(otherPaths, id: \.self) { path in
                Button {
                  Task { await store.openOtherInstallation(path, candidate: candidate, app: app, actions: actions) }
                } label: {
                  Label(path, systemImage: "arrow.up.forward.app").lineLimit(2).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.accent)
                .help(String(localized: "Review this installation in Apps"))
                .accessibilityLabel("\(String(localized: "Review this installation in Apps")): \(path)")
              }
            }
          }
        }
      }
      DetailChip(String(localized: "Why"), symbol: "info.circle", tone: .neutral) {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
          PathLabel(path: candidate.path, lines: 3).textSelection(.enabled)
          if let provenance = candidate.provenance {
            Text(AppsSurfaceText.provenance(provenance.kind)).font(Theme.Font.bodyMedium)
            if let source = provenance.sourcePath { PathLabel(path: source, lines: 2) }
          }
          if candidate.reason == .installed && candidate.refusalEvidence.isEmpty {
            Text(AppsSurfaceText.associatedData(candidate))
          } else {
            FailureReasonView(presentation: FailureText.candidate(candidate))
          }
          if automatic {
            Text(String(localized: "Selected automatically as app data."))
          } else if let note {
            Text(note).foregroundStyle(Theme.Palette.inkSecondary)
          }
          ShowInFinderButton(path: candidate.path).controlSize(.small)
        }
      }
      Group {
        if let observation = candidate.observation {
          if let total = observation.logical.completeTotal {
            Text(format(total))
          } else {
            Text(
              String.localizedStringWithFormat(
                String(localized: "At least %@"), format(observation.logical.knownLowerBound)))
          }
        } else {
          Text(String(localized: "Size not measured")).foregroundStyle(Theme.Palette.inkTertiary)
        }
      }
      .font(Theme.Font.monoSmall).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1).fixedSize()
    }
    .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
    .accessibilityElement(children: .contain)
    .anchorPreference(key: RelatedRowPreferenceKey.self, value: .bounds) { [candidate.path: $0] }
  }

  private func automaticSelectionNote(_ candidate: RelatedDataCandidate, app: ApplicationReport) -> String? {
    let kinds = candidate.evidenceKinds.isEmpty ? candidate.provenance.map { [$0.kind] } ?? [] : candidate.evidenceKinds
    if kinds.contains(.mozilla) {
      return String(localized: "Not selected automatically: profiles may contain mail and browsing data.")
    }
    if kinds.contains(.configuredDirectory) {
      return String(localized: "Not selected automatically: this folder may contain your documents.")
    }
    if candidate.reason == .nameOnly || candidate.classification == .unprovenNameOnly
      || (!kinds.isEmpty && kinds.allSatisfy { $0 == .executableName })
    {
      return String(localized: "Not selected automatically: only the name matches this app.")
    }
    if store.ownershipPendingPaths.contains(app.path) || candidate.reason == .ownershipUnavailable {
      return String(localized: "Not selected automatically: Lighten could not confirm which app uses it.")
    }
    if candidate.classification == .shared || candidate.path.contains("/Library/Group Containers/") {
      return String(localized: "Not selected automatically: this data may be shared with other apps.")
    }
    if candidate.matchStrength != .strong || candidate.classification == .unprovenNameOnly {
      return String(localized: "Not selected automatically: Lighten could not match it to this app.")
    }
    guard !candidate.defaultSelected else { return nil }
    if kinds.isEmpty {
      return String(localized: "Not selected automatically: Lighten could not match it to this app.")
    }
    if kinds.allSatisfy({ $0 == .liveProcess }) {
      return String(localized: "Not selected automatically: an open file may be used by more than one app.")
    }
    if kinds.allSatisfy({ $0 == .vendorDirectory }) {
      return String(
        localized: "Not selected automatically: this folder may be used by other apps from the same developer.")
    }
    if kinds.allSatisfy({ $0 == .executableName }) {
      return String(localized: "Not selected automatically: only the name matches this app.")
    }
    if kinds.allSatisfy({ $0 == .explicitUserChoice }) {
      return String(localized: "Not selected automatically: this item requires your explicit choice.")
    }
    return String(
      localized: "Not selected automatically: other apps may use this data.")
  }

  private func canSelect(_ candidate: RelatedDataCandidate, app: ApplicationReport) -> Bool {
    store.canSelect(candidate, app: app)
  }

  private func packageOutcome(_ outcome: ActionOutcome) -> String {
    switch outcome {
    case .applied: String(localized: "Moved to Trash")
    case .skipped: String(localized: "Skipped")
    case .failed: String(localized: "Failed")
    case .uncertain: String(localized: "Needs review")
    case .notAttempted: String(localized: "Not attempted")
    }
  }

  private func sizeText(_ app: ApplicationReport) -> String {
    if app.partial && app.logical.knownLowerBound == 0 { return String(localized: "Unknown") }
    return format(app.logical.completeTotal ?? app.logical.knownLowerBound)
  }
}

nonisolated struct RelatedRowPreferenceKey: PreferenceKey {
  static var defaultValue: [String: Anchor<CGRect>] { [:] }
  static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

nonisolated struct RelatedListViewportSnapshot: Sendable, Equatable {
  static let emptyResultID = "empty-related-result"
  let candidatePaths: Set<String>
  let visibleCount: Int
  let isComplete: Bool

  init(frames: [String: CGRect], candidatePaths: Set<String>, viewport: CGRect) {
    self.candidatePaths = candidatePaths
    func visible(_ frame: CGRect) -> Bool {
      let intersection = frame.intersection(viewport)
      return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
    visibleCount = candidatePaths.filter { frames[$0].map(visible) == true }.count
    if candidatePaths.isEmpty {
      isComplete = !viewport.isEmpty && frames[Self.emptyResultID].map(visible) == true
    } else {
      // Detail rows use a non-lazy stack. Require the entire candidate geometry
      // wave, then count only rows intersecting the clipped scroll viewport.
      isComplete =
        !viewport.isEmpty && visibleCount > 0
        && candidatePaths.allSatisfy { frames[$0].map { !$0.isEmpty && !$0.isNull } == true }
    }
  }
}

private struct RelatedListViewport: ViewModifier {
  let candidatePaths: Set<String>
  let revision: Int
  let didDraw: (RelatedListViewportSnapshot, Int) -> Void

  func body(content: Content) -> some View {
    content.overlayPreferenceValue(RelatedRowPreferenceKey.self) { anchors in
      GeometryReader { geometry in
        let snapshot = RelatedListViewportSnapshot(
          frames: anchors.mapValues { geometry[$0] }, candidatePaths: candidatePaths,
          viewport: CGRect(origin: .zero, size: geometry.size))
        RelatedListDrawProbe(snapshot: snapshot, revision: revision, didDraw: didDraw).allowsHitTesting(false)
      }
    }
  }
}

private struct RelatedListDrawProbe: NSViewRepresentable {
  let snapshot: RelatedListViewportSnapshot
  let revision: Int
  let didDraw: (RelatedListViewportSnapshot, Int) -> Void

  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) {
    view.didDraw = didDraw
    if view.snapshot != snapshot || view.revision != revision {
      view.snapshot = snapshot
      view.revision = revision
      view.needsDisplay = true
    }
  }

  final class Probe: NSView {
    var snapshot: RelatedListViewportSnapshot?
    var revision = -1
    var didDraw: ((RelatedListViewportSnapshot, Int) -> Void)?
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
      guard window != nil, !isHiddenOrHasHiddenAncestor, let snapshot else { return }
      let callback = didDraw
      let revision = revision
      DispatchQueue.main.async { callback?(snapshot, revision) }
    }
  }
}

enum AppsSurfaceText {
  static func provenance(_ kind: RelatedDataProvenanceKind) -> String {
    switch kind {
    case .bundleIdentifier: String(localized: "Matches this app’s identifier")
    case .teamIdentifier: String(localized: "Matches this app’s developer")
    case .electron, .mozilla: String(localized: "Listed in this app’s settings")
    case .installerReceipt: String(localized: "Listed in this app’s installation record")
    case .launchService: String(localized: "Used by this app’s background service")
    case .configuredDirectory: String(localized: "Chosen in this app’s settings")
    case .vendorDirectory: String(localized: "Used by apps from this developer")
    case .liveProcess: String(localized: "Currently used by this app")
    case .executableName: String(localized: "Only the name matches this app")
    case .explicitUserChoice: String(localized: "Selected by you")
    }
  }

  static func associatedData(_ candidate: RelatedDataCandidate, turkish: Bool? = nil) -> String {
    let kind =
      candidate.displayRootIdentity?.kind
      ?? candidate.snapshot?.entries.first(where: { $0.path == candidate.path })?.identity?.kind
    switch kind {
    case .directory:
      return FailureText.text(
        "This folder contains app data. Review it before removal.",
        "Bu klasör uygulama verisi içeriyor. Kaldırmadan önce inceleyin.", turkish: turkish)
    case .regular:
      return FailureText.text(
        "This file contains app data. Review it before removal.",
        "Bu dosya uygulama verisi içeriyor. Kaldırmadan önce inceleyin.", turkish: turkish)
    default:
      return FailureText.text(
        "This item contains app data. Review it before removal.",
        "Bu öğe uygulama verisi içeriyor. Kaldırmadan önce inceleyin.", turkish: turkish)
    }
  }
}
