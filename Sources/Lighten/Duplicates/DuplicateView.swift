import AppKit
import LightenKit
import QuickLookUI
import SwiftUI

struct DuplicateView: View {
  @Bindable var store: DuplicateStore
  @Bindable var actions: ActionStore
  @State private var searchText = ""
  @State private var keeperRule: DuplicateSelectionRule = .smart
  @State private var preview: DuplicatePreviewRequest?
  @FocusState private var focusedPath: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var groups: [DuplicateGroup] {
    guard let report = store.report, !store.needsRescan else { return [] }
    let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return report.groups }
    return report.groups.filter { group in
      group.members.contains { $0.entry.path.localizedStandardContains(term) }
    }
  }

  private var pictureGroups: [DuplicatePicture.Group] {
    guard let picture = store.picture else { return [] }
    let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return picture.content.groups }
    return picture.content.groups.filter { group in
      group.members.contains { $0.path.localizedStandardContains(term) }
    }
  }

  var body: some View {
    ToolScreen(
      String(localized: "Duplicates"), subtitle: subtitle, search: $searchText,
      searchPrompt: String(localized: "Search by name or path")
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
          header
          if store.needsRescan {
            EmptyState(
              symbol: "arrow.clockwise.circle", title: String(localized: "Scan is out of date after this operation"),
              message: String(localized: "Scan again to refresh duplicate groups before another action."),
              tint: Theme.Palette.toolDuplicates
            ) {
              if let path = store.folderPath {
                Button(String(localized: "Scan again")) { scanLocation(path) }.buttonStyle(.hero)
              }
            }
          } else if store.excludedRoot != nil {
            EmptyState(
              symbol: "folder.badge.minus", title: String(localized: "This folder is outside duplicate scanning"),
              message: String(localized: "Choose another folder or review duplicate scanning settings."),
              tint: Theme.Palette.toolDuplicates)
          } else if store.picture != nil {
            if pictureGroups.isEmpty {
              noCopies
                .background(DuplicatePictureDrawProbe(didDraw: store.pictureDidDraw).allowsHitTesting(false))
            } else {
              ForEach(pictureGroups) { group in
                pictureGroupCard(group)
                  .background(DuplicatePictureDrawProbe(didDraw: store.pictureDidDraw).allowsHitTesting(false))
              }
            }
          } else if store.report == nil && !store.busy {
            EmptyState(
              symbol: "doc.on.doc", title: String(localized: "Choose a folder to compare"),
              message: String(localized: "No files are selected for removal by default."),
              tint: Theme.Palette.toolDuplicates
            ) {
              Button(String(localized: "Choose folder")) { chooseFolder() }.buttonStyle(.hero)
            }
          } else if groups.isEmpty && !store.busy {
            noCopies
          } else {
            ForEach(groups) { group in groupCard(group) }
          }
          ActionFeedbackView(actions: actions)
        }
        .screenColumn()
        .padding(.bottom, Theme.Space.xl)
      }
      .floatingBar(isPresented: !store.targets.isEmpty) { selectionBar }
    } actions: {
      Menu {
        Button(String(localized: "Choose folder")) { chooseFolder() }
        if let path = store.folderPath {
          Button(String(localized: "Scan again")) { scanLocation(path) }
        }
        Divider()
        Button(String(localized: "Home")) { scanLocation(store.homeDirectory) }
        Button(String(localized: "Desktop")) { scanLocation(store.homeDirectory + "/Desktop") }
        Button(String(localized: "Documents")) { scanLocation(store.homeDirectory + "/Documents") }
        Button(String(localized: "Downloads")) { scanLocation(store.homeDirectory + "/Downloads") }
        Button(String(localized: "Pictures")) { scanLocation(store.homeDirectory + "/Pictures") }
      } label: {
        Label(MenuLabel.short(folderName), systemImage: "folder")
      }
      .fixedSize()
      .help(folderName)
      .disabled(actions.busy || store.busy)
      keeperMenu.fixedSize()
      Button(String(localized: "Reduce all to one"), systemImage: "square.stack.3d.down.right") {
        store.reduceToOne(rule: keeperRule, actions: actions)
      }
      .labelStyle(.iconOnly)
      .help(String(localized: "Reduce all to one"))
      .disabled(!canApplySelection).accessibilityIdentifier("duplicates.reduce-all")
      if store.busy {
        Button(String(localized: "Cancel scan"), systemImage: "stop.fill") { store.cancelScan() }
          .labelStyle(.iconOnly)
          .help(String(localized: "Cancel scan"))
      }
    }
    .sheet(item: $preview) { request in DuplicatePreviewSheet(request: request) }
    .sheet(item: $actions.pending) { presentation in
      ConfirmationView(presentation: presentation, actions: actions)
    }
    .animation(Theme.Motion.resolve(Theme.Motion.quick, reduceMotion: reduceMotion), value: store.targets)
    .animation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion), value: store.displayRevision)
    .animation(
      Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion), value: store.report?.groups.count
    )
    .animation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion), value: store.needsRescan)
    .task { store.open() }
    .onAppear { store.observeResult(actions: actions) }
    .onChange(of: actions.result?.planID) { _, _ in store.observeResult(actions: actions) }
    .onDisappear { store.deactivate(actions: actions) }
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first, url.isFileURL,
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
        !actions.busy, !store.busy
      else { return false }
      scanLocation(url.path)
      return true
    }
  }

  private var folderName: String {
    guard let path = store.folderPath else { return String(localized: "Choose folder") }
    return URL(fileURLWithPath: path).lastPathComponent
  }

  private var subtitle: String {
    if store.busy { return String(localized: "Scanning") }
    let date = store.picture?.observedAt ?? store.scannedAt
    return date.map { String(localized: "Last scan") + " " + $0.formatted(date: .abbreviated, time: .shortened) }
      ?? String(localized: "Exact local file copies in a folder you choose")
  }

  private var noCopies: some View {
    EmptyState(
      symbol: "checkmark.circle",
      title: searchText.isEmpty ? String(localized: "No exact copies found") : String(localized: "No matching groups"),
      message: String(localized: "Choose a folder or scan again to check for new copies."), tint: Theme.Palette.positive
    )
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      HStack(alignment: .bottom, spacing: Theme.Space.xl) {
        HeroMetric(
          value: .bytes(store.toolSummary.logicalBytes, atLeast: store.toolSummary.partial),
          caption: String(localized: "Copy file size"))
        Spacer(minLength: Theme.Space.l)
        if !store.targets.isEmpty {
          Metric(
            value: .bytes(store.selectedLogicalBytes),
            caption: String.localizedStringWithFormat(
              String(localized: "%lld groups · %lld copies"), Int64(store.selectedGroupCount),
              Int64(store.selectedCopyCount)),
            tone: .accent, compact: true)
        }
      }
      if store.busy {
        ScanStatusRow(
          status: store.checkingPreviousResult
            ? String(localized: "Verifying previous copies") : String(localized: "Scanning and comparing files"),
          count: store.scanned, bytes: store.scannedLogicalBytes
        )
        .help(String.localizedStringWithFormat(String(localized: "%lld files compared"), Int64(store.compared)))
      }
      scanDetails
      if let message = store.message ?? actions.message {
        NoticeBar(message).textSelection(.enabled)
      }
    }
    .padding(.top, Theme.Space.l)
  }

  private var selectionBar: some View {
    FloatingBar {
      SelectionSummary(
        symbol: "doc.on.doc",
        title: String.localizedStringWithFormat(
          String(localized: "%lld groups · %lld copies"), Int64(store.selectedGroupCount),
          Int64(store.selectedCopyCount)),
        value: .bytes(store.selectedLogicalBytes))
      DetailChip(String(localized: "Reclaimable space: Unknown"), symbol: "info.circle", tone: .neutral) {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
          Text(
            String.localizedStringWithFormat(
              String(localized: "Selected copy file size: %@"), format(store.selectedLogicalBytes)))
          Text(
            String(
              localized: "Shared APFS storage cannot be measured here. Moving copies to Trash does not free space yet.")
          )
        }
      }
      .accessibilityIdentifier("duplicates.reclaimable-space")
    } actions: {
      clearButton.buttonStyle(.glass)
      reviewButton.buttonStyle(.glassProminent)
    }
  }

  private var keeperMenu: some View {
    Menu {
      Button(String(localized: "Smart")) { keeperRule = .smart }
      Button(String(localized: "Keep newest")) { keeperRule = .newest }
      Button(String(localized: "Keep oldest")) { keeperRule = .oldest }
      Button(String(localized: "Prefer a folder…")) { chooseKeeperFolder() }
    } label: {
      Label(ruleLabel, systemImage: "checkmark.shield")
    }
    .labelStyle(.titleAndIcon)
    .help(ruleLabel)
    .disabled(store.busy || actions.busy)
  }

  private var clearButton: some View {
    Button(String(localized: "Clear selection")) { store.clearSelection(actions: actions) }
      .fixedSize()
      .disabled(actions.busy || store.busy || store.targets.isEmpty)
  }

  private var reviewButton: some View {
    Button(String(localized: "Review selection")) { Task { await store.prepare(actions: actions) } }
      .fixedSize()
      .disabled(
        store.picture != nil || store.report == nil || !store.tool.allowsPreparation || store.targets.isEmpty
          || actions.busy || store.needsRescan
      )
      .accessibilityIdentifier("duplicates.review-selection")
  }

  /// Scope, exclusions and refusals as a row of chips; each opens its full list.
  @ViewBuilder private var scanDetails: some View {
    if !store.needsRescan {
      if store.report?.partial == true {
        PartialNotice(
          String.localizedStringWithFormat(
            String(localized: "%lld files could not be checked. Results are partial."), Int64(store.unreadableCount)))
      } else if store.picture?.content.partial == true {
        PartialNotice(String(localized: "Previous scan was incomplete. Scan again to check these files."))
      } else if store.cancelled {
        PartialNotice(String(localized: "Scan cancelled. Scan again to complete the comparison."))
      } else if store.picture != nil {
        NoticeBar(
          String(localized: "Previous result. Selecting copies verifies these files again."), symbol: "clock",
          tone: .neutral)
      }
    }
    FlowChips {
      SettingsLink {
        Chip(
          title: String.localizedStringWithFormat(
            String(localized: "Minimum file size: %@ MB"), store.duplicatePreferences.minimumMegabytes.formatted()),
          symbol: "gearshape")
      }
      .buttonStyle(.plain)
      .help(String(localized: "Scanning settings"))
      if store.additionalHardLinkCount > 0 {
        DetailChip(
          String.localizedStringWithFormat(String(localized: "%lld hard links"), Int64(store.additionalHardLinkCount)),
          symbol: "link", tone: .neutral
        ) {
          Text(
            String.localizedStringWithFormat(
              String(localized: "%lld additional hard links. File data remains while another link exists."),
              Int64(store.additionalHardLinkCount)))
        }
        .accessibilityIdentifier("duplicates.additional-hard-links")
      }
      if let report = store.report, !report.exclusions.isEmpty {
        DetailChip(
          String.localizedStringWithFormat(
            String(localized: "%lld outside scope"), Int64(report.exclusions.count)),
          symbol: "eye.slash", tone: .neutral
        ) {
          VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(
              String.localizedStringWithFormat(
                String(localized: "%lld items outside scope · %lld folders · %lld cloud-only files"),
                Int64(report.exclusions.count), Int64(store.excludedDirectoryCount), Int64(store.cloudOnlyCount))
            )
            .font(Theme.Font.bodyMedium)
            ForEach(Array(report.exclusions.enumerated()), id: \.offset) { _, exclusion in
              VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(exclusionLabel(exclusion.reason))
                PathLabel(path: exclusion.path, lines: 2).textSelection(.enabled)
              }
            }
          }
        }
      }
      if let refusals = store.report?.refusals, !refusals.isEmpty {
        DetailChip(
          String.localizedStringWithFormat(String(localized: "%lld files need review"), Int64(refusals.count)),
          symbol: "exclamationmark.triangle.fill"
        ) {
          VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(String(localized: "Files needing review")).font(Theme.Font.bodyMedium)
            ForEach(Array(refusals.enumerated()), id: \.offset) { _, refusal in
              VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(refusalLabel(refusal.reason)).foregroundStyle(Theme.Palette.warning)
                PathLabel(path: refusal.path, lines: 2).textSelection(.enabled)
              }
            }
          }
        }
      }
      if !store.preparationRefusals.isEmpty {
        DetailChip(
          String.localizedStringWithFormat(
            String(localized: "%lld groups could not be verified. Details"), Int64(store.preparationRefusals.count)),
          symbol: "exclamationmark.triangle.fill"
        ) {
          VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(store.preparationRefusals.enumerated()), id: \.offset) { _, refusal in
              VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(planRefusalLabel(refusal.reason)).foregroundStyle(Theme.Palette.warning)
                PathLabel(path: refusal.path, lines: 2).textSelection(.enabled)
              }
            }
          }
        }
      }
    }
  }

  private var canApplySelection: Bool {
    !store.busy && !actions.busy && !store.needsRescan
      && (store.report?.groups.isEmpty == false || store.picture?.content.groups.isEmpty == false)
  }

  private var ruleLabel: String {
    switch keeperRule {
    case .smart: String(localized: "Keep: Smart")
    case .newest: String(localized: "Keep: Newest")
    case .oldest: String(localized: "Keep: Oldest")
    case .folder(let path): String(localized: "Prefer folder:") + " " + URL(fileURLWithPath: path).lastPathComponent
    }
  }

  private func chooseKeeperFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Prefer this folder")
    if panel.runModal() == .OK, let path = panel.url?.path { keeperRule = .folder(path) }
  }

  private func scanLocation(_ path: String) { store.startScan(folder: path, actions: actions) }

  private var visiblePaths: [String] {
    if store.picture != nil { return pictureGroups.flatMap { $0.members.map(\.path) } }
    return groups.flatMap { $0.members.map { $0.entry.path } }
  }

  private func showPreview(_ path: String) {
    preview = DuplicatePreviewRequest(path: path, paths: visiblePaths)
  }

  private func moveFocus(_ offset: Int, from path: String) -> KeyPress.Result {
    let paths = visiblePaths
    guard let index = paths.firstIndex(of: path), paths.indices.contains(index + offset) else { return .ignored }
    focusedPath = paths[index + offset]
    return .handled
  }

  @ViewBuilder private func rowContextMenu(_ path: String) -> some View {
    Button(String(localized: "Quick Look")) { showPreview(path) }
    Button(String(localized: "Show in Finder")) {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    Button(String(localized: "Copy path")) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([path as NSString])
    }
  }

  private func groupHeader(count: Int, bytes: Int64, note: String?, warnings: [String] = []) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
      VStack(alignment: .leading, spacing: Theme.Space.xxs) {
        Text(String.localizedStringWithFormat(String(localized: "%lld identical copies"), Int64(count)))
          .font(Theme.Font.headline)
        if let note {
          Text(note).font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1).help(note)
        }
      }
      Spacer(minLength: Theme.Space.s)
      if !warnings.isEmpty {
        DetailChip(
          warnings.count == 1
            ? warnings[0]
            : String.localizedStringWithFormat(String(localized: "%lld differences"), Int64(warnings.count)),
          symbol: "exclamationmark.triangle.fill"
        ) {
          VStack(alignment: .leading, spacing: Theme.Space.xs) { ForEach(warnings, id: \.self) { Text($0) } }
        }
      }
      Text(format(bytes)).font(Theme.Font.mono).foregroundStyle(Theme.Palette.ink)
    }
    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
  }

  private func pictureGroupCard(_ group: DuplicatePicture.Group) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      groupHeader(
        count: group.members.count, bytes: group.logicalBytes,
        note: group.members.contains(where: { isICloudPath($0.path) }) ? iCloudNoticeText : nil)
      RowDivider()
      ForEach(group.members) { member in
        HStack(spacing: Theme.Space.m) {
          FileKindIcon(path: member.path)
          VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(URL(fileURLWithPath: member.path).lastPathComponent)
              .font(Theme.Font.bodyMedium).lineLimit(1)
            PathLabel(path: member.path)
          }
          Spacer(minLength: Theme.Space.s)
          Chip(
            title: member.eligibility == .eligible
              ? String(localized: "Previously verified copy") : label(member.eligibility),
            tone: member.eligibility == .eligible ? .neutral : .warning)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .contextMenu { rowContextMenu(member.path) }
        .focusable().focused($focusedPath, equals: member.path)
        .onKeyPress(.space) {
          showPreview(member.path)
          return .handled
        }
        .onKeyPress(.upArrow) { moveFocus(-1, from: member.path) }
        .onKeyPress(.downArrow) { moveFocus(1, from: member.path) }
      }
    }
    .padding(.bottom, Theme.Space.xs)
    .moduleSurface()
  }

  private func groupCard(_ group: DuplicateGroup) -> some View {
    let warnings = Array(Set(group.members.flatMap(\.metadataWarnings))).sorted { $0.rawValue < $1.rawValue }
    return VStack(alignment: .leading, spacing: 0) {
      groupHeader(
        count: group.members.count, bytes: group.logicalBytes,
        note: group.members.contains(where: { isICloudPath($0.entry.path) })
          ? iCloudNoticeText
          : group.reportOnlyReason.map(reportOnlyLabel)
            ?? String(localized: "One copy stays in each group. Choose another keeper if needed."),
        warnings: warnings.map(metadataWarningLabel))
      RowDivider()
      ForEach(group.members) { member in
        memberRow(member, group: group)
          .transition(Theme.Motion.transition(Theme.Motion.pop, reduceMotion: reduceMotion))
      }
    }
    .padding(.bottom, Theme.Space.xs)
    .moduleSurface()
  }

  private func memberRow(_ member: DuplicateMember, group: DuplicateGroup) -> some View {
    let keeperID = store.keeperID(for: member)
    let isKeeper = keeperID == member.id
    let canTarget = keeperID.map { group.canTarget(member.id, keeperID: $0) } ?? false
    let selected = store.targets.contains(member.id)
    return HStack(spacing: Theme.Space.m) {
      Toggle(
        String(localized: "Select copy for Trash"),
        isOn: Binding(
          get: { selected },
          set: { value in
            if value != selected { store.toggleTarget(member.id, in: group, actions: actions) }
          })
      )
      .labelsHidden().toggleStyle(.checkbox)
      .disabled(!canTarget || isKeeper || actions.busy || store.tool.phase != .ready)
      .accessibilityLabel(
        String(localized: "Select copy for Trash") + " " + URL(fileURLWithPath: member.entry.path).lastPathComponent)
      FileKindIcon(path: member.entry.path)
      VStack(alignment: .leading, spacing: Theme.Space.xxs) {
        Text(URL(fileURLWithPath: member.entry.path).lastPathComponent)
          .font(Theme.Font.bodyMedium).lineLimit(1)
        HStack(spacing: Theme.Space.xs) {
          PathLabel(path: member.entry.path)
          if let seconds = member.entry.identity?.modificationSeconds {
            Text(verbatim: "·").font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkTertiary)
            Text(Date(timeIntervalSince1970: Double(seconds)), format: .dateTime.year().month().day().hour().minute())
              .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1).fixedSize()
          }
        }
        if let reason = actions.failure(at: member.entry.path) {
          Text(reason).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: Theme.Space.s)
      if let links = member.entry.identity?.linkCount, links > 1 {
        DetailChip(
          String.localizedStringWithFormat(String(localized: "%lld hard links"), Int64(clamping: links - 1)),
          symbol: "link", tone: .neutral
        ) {
          Text(
            String.localizedStringWithFormat(
              String(localized: "%lld other hard links retain this file's data"), Int64(clamping: links - 1)))
        }
      }
      if member.eligibility != .eligible {
        Chip(title: label(member.eligibility), symbol: "exclamationmark.triangle.fill", tone: .warning)
          .help(label(member.eligibility))
      }
      Menu {
        Button(String(localized: "Keep this copy")) {
          store.chooseKeeper(member.id, for: group, actions: actions)
        }
        .disabled(member.eligibility != .eligible || member.compatibilityID == nil)
        Button(selected ? String(localized: "Deselect") : String(localized: "Select copy for Trash")) {
          store.toggleTarget(member.id, in: group, actions: actions)
        }
        .disabled(!canTarget || isKeeper)
      } label: {
        Chip(
          title: isKeeper
            ? String(localized: "Keep") : selected ? String(localized: "Trash") : String(localized: "Choose"),
          symbol: isKeeper ? "checkmark.shield.fill" : selected ? "trash.fill" : "circle",
          tone: isKeeper ? .positive : selected ? .accent : .neutral)
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      .disabled(actions.busy || store.tool.phase != .ready)
      .accessibilityLabel(
        isKeeper
          ? String(localized: "Keep this copy")
          : selected ? String(localized: "Select copy for Trash") : String(localized: "Choose as keeper"))
    }
    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
    .background {
      if selected { Theme.Palette.selection.opacity(0.6) }
    }
    .accessibilityElement(children: .contain)
    .contextMenu { rowContextMenu(member.entry.path) }
    .focusable().focused($focusedPath, equals: member.entry.path)
    .onKeyPress(.space) {
      showPreview(member.entry.path)
      return .handled
    }
    .onKeyPress(.upArrow) { moveFocus(-1, from: member.entry.path) }
    .onKeyPress(.downArrow) { moveFocus(1, from: member.entry.path) }
  }

  private func isICloudPath(_ path: String) -> Bool {
    DuplicateScanScope(homeDirectory: store.homeDirectory).isLocalICloudPath(path)
  }

  private var iCloudNoticeText: String {
    String(localized: "iCloud Drive copies are not removed here. Manage them in Finder.")
  }

  private func refusalLabel(_ reason: DuplicateObservationRefusal.Reason) -> String {
    switch reason {
    case .unavailable: String(localized: "File or volume is unavailable")
    case .outOfScope: String(localized: "File is outside the current scan scope")
    case .notRegular: String(localized: "File is no longer a regular file")
    case .unreadable: String(localized: "File could not be read")
    case .changed: String(localized: "File changed during verification")
    case .noLongerDuplicate: String(localized: "No identical copy remains")
    case .metadataUnknown: String(localized: "File information could not be checked")
    case .metadataDifferent: String(localized: "Important file information differs")
    case .protectedArea: String(localized: "Protected files are shown for review only")
    }
  }

  private func reportOnlyLabel(_ reason: DuplicateReportOnlyReason) -> String {
    switch reason {
    case .protectiveMetadataDifferent:
      String(localized: "Review only: important file information differs between copies.")
    case .metadataUnknown: String(localized: "Review only: file information could not be checked.")
    case .protectedArea: String(localized: "Review only: these copies are in a protected area.")
    }
  }

  private func planRefusalLabel(_ reason: DuplicatePlanRefusal.Reason) -> String {
    switch reason {
    case .changed: String(localized: "File changed during verification")
    case .unavailable: String(localized: "File or volume is unavailable")
    case .unreadable: String(localized: "File could not be read")
    case .outOfScope: String(localized: "File is outside the current scan scope")
    case .metadataUnknown: String(localized: "File information could not be checked")
    case .metadataDifferent: String(localized: "Important file information differs")
    case .dataDifferent: String(localized: "File contents no longer match")
    case .protectedArea: String(localized: "Protected files are shown for review only")
    }
  }

  private func exclusionLabel(_ reason: DuplicateScanExclusion.Reason) -> String {
    switch reason {
    case .invalidPath, .outsideScanRoot: String(localized: "Outside the selected folder")
    case .hiddenDirectory: String(localized: "Hidden folder")
    case .sourceControl: String(localized: "Source control folder")
    case .buildOutput, .derivedData: String(localized: "Build output")
    case .dependencyDirectory: String(localized: "Dependency folder")
    case .libraryCache: String(localized: "Cache folder")
    case .package: String(localized: "App or document package")
    case .homeLibrary: String(localized: "App data folder")
    case .cloudOnly: String(localized: "In iCloud only; not downloaded for scanning")
    case .protectedArea: String(localized: "Protected area")
    case .mountBoundary: String(localized: "On another volume")
    case .hardLinkAlias: String(localized: "Another link to the same file")
    case .configuration: String(localized: "Excluded by scanning settings")
    }
  }

  private func metadataWarningLabel(_ warning: DuplicateMetadataWarning) -> String {
    switch warning {
    case .quarantine: String(localized: "Download quarantine differs")
    case .downloadSource: String(localized: "Download source differs")
    case .finderTags: String(localized: "Finder tags differ")
    case .permissions: String(localized: "Permissions differ")
    case .compression: String(localized: "Compression differs")
    case .fileInformation: String(localized: "File information differs")
    }
  }

  private func label(_ eligibility: DuplicateEligibility) -> String {
    switch eligibility {
    case .eligible: String(localized: "Verified copy")
    case .metadataDifferent: String(localized: "Important file information differs")
    case .metadataUnknown: String(localized: "File information could not be checked")
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

/// The Finder icon for a file, small enough to sit in a row.
private struct FileKindIcon: View {
  let path: String

  var body: some View {
    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
      .resizable().interpolation(.high)
      .frame(width: Theme.Layout.rowIcon, height: Theme.Layout.rowIcon)
      .accessibilityHidden(true)
  }
}

private struct DuplicatePictureDrawProbe: NSViewRepresentable {
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

private struct DuplicatePreviewRequest: Identifiable {
  let path: String
  let paths: [String]
  var id: String { path }
}

private struct DuplicatePreviewSheet: View {
  let request: DuplicatePreviewRequest
  @State private var currentPath: String
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focused: Bool

  init(request: DuplicatePreviewRequest) {
    self.request = request
    _currentPath = State(initialValue: request.path)
  }

  var body: some View {
    VStack(spacing: Theme.Space.m) {
      HStack {
        Text(URL(fileURLWithPath: currentPath).lastPathComponent).font(Theme.Font.headline).lineLimit(1)
        Spacer()
        Button {
          navigate(-1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(!canNavigate(-1)).accessibilityLabel(String(localized: "Previous file"))
        Button {
          navigate(1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(!canNavigate(1)).accessibilityLabel(String(localized: "Next file"))
        Button(String(localized: "Done")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      DuplicateQuickLookView(path: currentPath)
        .frame(minWidth: Theme.Layout.previewMinimum.width, minHeight: Theme.Layout.previewMinimum.height)
      PathLabel(path: currentPath, lines: 2).textSelection(.enabled)
    }
    .padding(Theme.Space.l).focusable().focused($focused)
    .onAppear { focused = true }
    .onKeyPress(.leftArrow) {
      navigate(-1)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      navigate(1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      navigate(-1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      navigate(1)
      return .handled
    }
    .onKeyPress(.space) {
      dismiss()
      return .handled
    }
  }

  private func canNavigate(_ offset: Int) -> Bool {
    guard let index = request.paths.firstIndex(of: currentPath) else { return false }
    return request.paths.indices.contains(index + offset)
  }

  private func navigate(_ offset: Int) {
    guard let index = request.paths.firstIndex(of: currentPath), canNavigate(offset) else { return }
    currentPath = request.paths[index + offset]
  }
}

private struct DuplicateQuickLookView: NSViewRepresentable {
  let path: String
  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .normal)!
    view.previewItem = URL(fileURLWithPath: path) as NSURL
    return view
  }
  func updateNSView(_ view: QLPreviewView, context: Context) {
    if (view.previewItem as? NSURL)?.path != path { view.previewItem = URL(fileURLWithPath: path) as NSURL }
  }
  static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
