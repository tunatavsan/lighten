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
    LegacyToolScreen(String(localized: "Duplicates")) {
      VStack(alignment: .leading, spacing: 12) {
        Text(String(localized: "Exact local file copies in a folder you choose"))
          .foregroundStyle(LightenStyle.muted)
        if let folder = store.folderPath {
          Label(folder, systemImage: "folder")
            .font(.callout).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).help(folder)
        }
        if store.busy {
          ToolScanProgress(
            status: store.checkingPreviousResult
              ? String(localized: "Verifying previous copies") : String(localized: "Scanning and comparing files"),
            count: store.scanned, bytes: store.scannedLogicalBytes)
          Text(String.localizedStringWithFormat(String(localized: "%lld files compared"), Int64(store.compared)))
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
        } else if let date = store.picture?.observedAt ?? store.scannedAt {
          Text(String(localized: "Last scan") + ": " + date.formatted())
            .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            scanDetails
            if store.needsRescan {
              emptyState(
                title: String(localized: "Scan is out of date after this operation"),
                detail: String(localized: "Scan again to refresh duplicate groups before another action."))
            } else if store.excludedRoot != nil {
              emptyState(
                title: String(localized: "This folder is outside duplicate scanning"),
                detail: String(localized: "Choose another folder or review duplicate scanning settings."))
            } else if store.picture != nil {
              Text(String(localized: "Previous result. Selecting copies verifies these files again."))
                .font(.caption).foregroundStyle(.secondary)
              if pictureGroups.isEmpty {
                emptyState(
                  title: searchText.isEmpty
                    ? String(localized: "No exact copies found") : String(localized: "No matching groups"),
                  detail: String(localized: "Choose a folder or scan again to check for new copies.")
                )
                .background(DuplicatePictureDrawProbe(didDraw: store.pictureDidDraw).allowsHitTesting(false))
              } else {
                ForEach(pictureGroups) { group in
                  pictureGroupCard(group)
                    .background(DuplicatePictureDrawProbe(didDraw: store.pictureDidDraw).allowsHitTesting(false))
                }
              }
            } else if store.report == nil && !store.busy {
              emptyState(
                title: String(localized: "Choose a folder to compare"),
                detail: String(localized: "No files are selected for removal by default."))
            } else if groups.isEmpty && !store.busy {
              emptyState(
                title: searchText.isEmpty
                  ? String(localized: "No exact copies found") : String(localized: "No matching groups"),
                detail: String(localized: "Choose a folder or scan again to check for new copies."))
            } else {
              ForEach(groups) { group in groupCard(group) }
            }
            ActionFeedbackView(actions: actions)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 4)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        Divider()
        Text(
          String.localizedStringWithFormat(
            String(localized: "%lld groups · %lld copies"), Int64(store.selectedGroupCount),
            Int64(store.selectedCopyCount))
        )
        .font(.callout).monospacedDigit()
        .contentTransition(reduceMotion ? .identity : .numericText())
        Text(String(localized: "Reclaimable space: Unknown"))
          .font(.callout.weight(.medium))
          .accessibilityIdentifier("duplicates.reclaimable-space")
        Text(
          String.localizedStringWithFormat(
            String(localized: "Selected copy file size: %@"), format(store.selectedLogicalBytes))
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(
          String(
            localized: "Shared APFS storage cannot be measured here. Moving copies to Trash does not free space yet.")
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        selectionActions
        if let message = store.message ?? actions.message {
          Text(message).font(.caption).foregroundStyle(LightenStyle.warning).textSelection(.enabled)
        }
      }
      .padding(.vertical, 20)
    } toolbar: {
      Menu(String(localized: "Scan location")) {
        Button(String(localized: "Choose folder")) { chooseFolder() }
        if let path = store.folderPath {
          Button(String(localized: "Scan again")) { store.startScan(folder: path, actions: actions) }
        }
        Divider()
        Button(String(localized: "Home")) { scanLocation(store.homeDirectory) }
        Button(String(localized: "Desktop")) { scanLocation(store.homeDirectory + "/Desktop") }
        Button(String(localized: "Documents")) { scanLocation(store.homeDirectory + "/Documents") }
        Button(String(localized: "Downloads")) { scanLocation(store.homeDirectory + "/Downloads") }
        Button(String(localized: "Pictures")) { scanLocation(store.homeDirectory + "/Pictures") }
      }
      .disabled(actions.busy || store.busy)
      if store.busy {
        Button(String(localized: "Cancel scan")) { store.cancelScan() }
      }
    }
    .searchable(text: $searchText, prompt: String(localized: "Search by name or path"))
    .sheet(item: $preview) { request in DuplicatePreviewSheet(request: request) }
    .sheet(item: $actions.pending) { presentation in
      ConfirmationView(presentation: presentation, actions: actions)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.targets)
    .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: store.displayRevision)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.report?.groups.count)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.needsRescan)
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

  private var selectionActions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        keeperMenu
        reduceButton
        Spacer(minLength: 0)
        clearButton
        reviewButton
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          keeperMenu
          reduceButton
        }
        HStack(spacing: 12) {
          clearButton
          reviewButton
        }
      }
    }
    .buttonStyle(.bordered)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var keeperMenu: some View {
    Menu(ruleLabel) {
      Button(String(localized: "Smart")) { keeperRule = .smart }
      Button(String(localized: "Keep newest")) { keeperRule = .newest }
      Button(String(localized: "Keep oldest")) { keeperRule = .oldest }
      Button(String(localized: "Prefer a folder…")) { chooseKeeperFolder() }
    }
    .lineLimit(1)
    .help(ruleLabel)
    .disabled(store.busy || actions.busy)
  }

  private var reduceButton: some View {
    Button(String(localized: "Reduce all to one")) { store.reduceToOne(rule: keeperRule, actions: actions) }
      .fixedSize()
      .disabled(!canApplySelection).accessibilityIdentifier("duplicates.reduce-all")
  }

  private var clearButton: some View {
    Button(String(localized: "Clear selection")) { store.clearSelection(actions: actions) }
      .fixedSize()
      .disabled(actions.busy || store.busy || store.targets.isEmpty)
  }

  private var reviewButton: some View {
    Button(String(localized: "Review selection")) { Task { await store.prepare(actions: actions) } }
      .buttonStyle(.borderedProminent)
      .fixedSize()
      .disabled(
        store.picture != nil || store.report == nil || !store.tool.allowsPreparation || store.targets.isEmpty
          || actions.busy || store.needsRescan
      )
      .accessibilityIdentifier("duplicates.review-selection")
  }

  private func emptyState(title: String, detail: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(.secondary)
      Text(title).font(.headline)
      Text(detail).font(.callout).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
  }

  @ViewBuilder private var scanDetails: some View {
    HStack {
      Text(
        String.localizedStringWithFormat(
          String(localized: "Minimum file size: %@ MB"), store.duplicatePreferences.minimumMegabytes.formatted()))
      Spacer()
      SettingsLink { Label(String(localized: "Scanning settings"), systemImage: "gearshape") }
    }
    .font(.caption).foregroundStyle(.secondary)
    if store.additionalHardLinkCount > 0 {
      Text(
        String.localizedStringWithFormat(
          String(localized: "%lld additional hard links. File data remains while another link exists."),
          Int64(store.additionalHardLinkCount))
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("duplicates.additional-hard-links")
    }
    if let report = store.report, !report.exclusions.isEmpty {
      DisclosureGroup {
        ForEach(Array(report.exclusions.enumerated()), id: \.offset) { _, exclusion in
          VStack(alignment: .leading, spacing: 2) {
            Text(exclusionLabel(exclusion.reason))
            Text(exclusion.path).textSelection(.enabled)
              .lineLimit(2).truncationMode(.middle).help(exclusion.path)
          }
          .font(.caption).foregroundStyle(.secondary)
        }
      } label: {
        Text(
          String.localizedStringWithFormat(
            String(localized: "%lld items outside scope · %lld folders · %lld cloud-only files"),
            Int64(report.exclusions.count), Int64(store.excludedDirectoryCount), Int64(store.cloudOnlyCount))
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    if !store.needsRescan {
      if store.report?.partial == true {
        PartialResultNotice(
          reason: String.localizedStringWithFormat(
            String(localized: "%lld files could not be checked. Results are partial."), Int64(store.unreadableCount)))
      } else if store.picture?.content.partial == true {
        PartialResultNotice(reason: String(localized: "Previous scan was incomplete. Scan again to check these files."))
      } else if store.cancelled {
        PartialResultNotice(reason: String(localized: "Scan cancelled. Scan again to complete the comparison."))
      }
    }
    if let refusals = store.report?.refusals, !refusals.isEmpty {
      DisclosureGroup(String(localized: "Files needing review")) {
        ForEach(Array(refusals.enumerated()), id: \.offset) { _, refusal in
          VStack(alignment: .leading, spacing: 2) {
            Text(refusalLabel(refusal.reason)).foregroundStyle(LightenStyle.warning)
            Text(refusal.path).foregroundStyle(.secondary).textSelection(.enabled)
              .lineLimit(2).truncationMode(.middle).help(refusal.path)
          }.font(.caption)
        }
      }
    }
    if !store.preparationRefusals.isEmpty {
      DisclosureGroup {
        ForEach(Array(store.preparationRefusals.enumerated()), id: \.offset) { _, refusal in
          VStack(alignment: .leading, spacing: 2) {
            Text(planRefusalLabel(refusal.reason)).foregroundStyle(LightenStyle.warning)
            Text(refusal.path).foregroundStyle(.secondary).textSelection(.enabled)
              .lineLimit(2).truncationMode(.middle).help(refusal.path)
          }.font(.caption)
        }
      } label: {
        Text(
          String.localizedStringWithFormat(
            String(localized: "%lld groups could not be verified. Details"), Int64(store.preparationRefusals.count))
        )
        .font(.caption).foregroundStyle(LightenStyle.warning)
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

  private func pictureGroupCard(_ group: DuplicatePicture.Group) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("\(group.members.count) \(String(localized: "identical copies"))")
          .font(.system(size: 15, weight: .semibold))
        Spacer()
        Text(format(group.logicalBytes)).font(.system(size: 13, weight: .medium)).monospacedDigit()
      }
      Divider()
      if group.members.contains(where: { isICloudPath($0.path) }) {
        iCloudNotice
      }
      ForEach(group.members) { member in
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(URL(fileURLWithPath: member.path).lastPathComponent)
              .font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(member.path).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
              .lineLimit(1).truncationMode(.middle).help(member.path)
          }
          Spacer(minLength: 8)
          Text(
            member.eligibility == .eligible ? String(localized: "Previously verified copy") : label(member.eligibility)
          )
          .font(.system(size: 10)).foregroundStyle(LightenStyle.muted)
        }
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
    .padding(13)
    .background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 10))
  }

  private func groupCard(_ group: DuplicateGroup) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(group.members.count) \(String(localized: "identical copies"))")
            .font(.system(size: 15, weight: .semibold))
          Text(
            group.members.contains(where: { isICloudPath($0.entry.path) })
              ? iCloudNoticeText
              : group.reportOnlyReason.map(reportOnlyLabel)
                ?? String(localized: "One copy stays in each group. Choose another keeper if needed.")
          )
          .font(.caption).foregroundStyle(.secondary)
          let warnings = Array(Set(group.members.flatMap(\.metadataWarnings))).sorted { $0.rawValue < $1.rawValue }
          if !warnings.isEmpty {
            Text(warnings.map(metadataWarningLabel).joined(separator: " · "))
              .font(.caption).foregroundStyle(.secondary)
          }
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
    let keeperID = store.keeperID(for: member)
    let isKeeper = keeperID == member.id
    let canTarget = keeperID.map { group.canTarget(member.id, keeperID: $0) } ?? false
    let selected = store.targets.contains(member.id)
    return HStack(spacing: 10) {
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
        Label(
          isKeeper ? String(localized: "Keep") : selected ? String(localized: "Trash") : String(localized: "Choose"),
          systemImage: isKeeper ? "checkmark.shield" : selected ? "trash" : "circle"
        )
        .frame(width: 78, alignment: .leading)
      }
      .menuStyle(.borderlessButton)
      .disabled(actions.busy || store.tool.phase != .ready)
      .accessibilityLabel(
        isKeeper
          ? String(localized: "Keep this copy")
          : selected ? String(localized: "Select copy for Trash") : String(localized: "Choose as keeper"))
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
        if let seconds = member.entry.identity?.modificationSeconds {
          Text(Date(timeIntervalSince1970: Double(seconds)), format: .dateTime.year().month().day().hour().minute())
            .font(.system(size: 10)).foregroundStyle(LightenStyle.muted)
        }
        if let links = member.entry.identity?.linkCount, links > 1 {
          Text(
            String.localizedStringWithFormat(
              String(localized: "%lld other hard links retain this file's data"), Int64(clamping: links - 1))
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      Text(
        isKeeper ? String(localized: "Keep") : label(member.eligibility)
      )
      .font(.system(size: 10))
      .foregroundStyle(member.eligibility == .eligible ? LightenStyle.muted : .orange)
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

  private var iCloudNotice: some View {
    Text(iCloudNoticeText).font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
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
    VStack(spacing: 12) {
      HStack {
        Text(URL(fileURLWithPath: currentPath).lastPathComponent).font(.headline).lineLimit(1)
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
        .frame(minWidth: 520, minHeight: 380)
      Text(currentPath).font(.caption).foregroundStyle(LightenStyle.muted).textSelection(.enabled)
    }
    .padding(16).focusable().focused($focused)
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
