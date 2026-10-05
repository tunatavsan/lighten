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
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(String(localized: "Duplicates"))
            .font(.system(size: 24, weight: .semibold))
          Text(String(localized: "Exact local file copies in a folder you choose"))
            .foregroundStyle(LightenStyle.muted)
        }
        Spacer()
        Menu(String(localized: "Scan location")) {
          Button(String(localized: "Home")) { scanLocation(store.homeDirectory) }
          Button(String(localized: "Desktop")) { scanLocation(store.homeDirectory + "/Desktop") }
          Button(String(localized: "Documents")) { scanLocation(store.homeDirectory + "/Documents") }
          Button(String(localized: "Downloads")) { scanLocation(store.homeDirectory + "/Downloads") }
          Button(String(localized: "Pictures")) { scanLocation(store.homeDirectory + "/Pictures") }
        }
        .disabled(actions.busy || store.busy)
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
      if let date = store.picture?.observedAt ?? store.scannedAt {
        Text(String(localized: "Last scan") + ": " + date.formatted())
          .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
          .padding(.bottom, 8)
      }
      if store.picture != nil {
        Text(String(localized: "Previous result. Selecting copies verifies these files again."))
          .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
          .padding(.bottom, 8)
      }
      if store.busy || store.report != nil || store.cancelled || store.picture != nil {
        HStack {
          Text(
            store.busy
              ? (store.checkingPreviousResult
                ? String(localized: "Verifying previous copies") : String(localized: "Scanning and comparing files"))
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
      if (store.report != nil || store.picture != nil) && !store.needsRescan {
        HStack {
          TextField(String(localized: "Search by name or path"), text: $searchText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(String(localized: "Search by name or path"))
            .frame(maxWidth: 360)
          Button(String(localized: "Clear search")) { searchText = "" }
            .disabled(searchText.isEmpty)
          Spacer()
          Text(
            "\(store.picture == nil ? groups.count : pictureGroups.count) / \(store.picture?.content.groups.count ?? store.report?.groups.count ?? 0) \(String(localized: "groups"))"
          )
          .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
        }
        .padding(.bottom, 10)
      }
      if store.picture?.content.partial == true || store.report?.partial == true, !store.needsRescan {
        let skipped = store.picture?.content.skippedCount ?? store.report?.skippedCount ?? 0
        Label {
          Text(
            skipped > 0
              ? "\(skipped) \(String(localized: "known files skipped")) · \(String(localized: "Some files or areas could not be verified; results are partial."))"
              : String(localized: "Some files or areas could not be verified; results are partial.")
          )
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.system(size: 12)).foregroundStyle(LightenStyle.warning)
        .padding(.bottom, 9)
      }
      if let refusals = store.report?.refusals, !refusals.isEmpty {
        DisclosureGroup {
          ForEach(Array(refusals.enumerated()), id: \.offset) { _, refusal in
            VStack(alignment: .leading, spacing: 2) {
              Text(refusalLabel(refusal.reason)).foregroundStyle(LightenStyle.warning)
              Text(refusal.path).foregroundStyle(LightenStyle.muted).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle).help(refusal.path)
            }
            .font(.system(size: 11))
          }
        } label: {
          Text(
            String.localizedStringWithFormat(
              String(localized: "%lld previous files could not be included. Details"), Int64(refusals.count))
          )
          .font(.system(size: 12)).foregroundStyle(LightenStyle.warning)
        }
        .padding(.bottom, 9)
      }
      selectionControls
      Divider()
      if store.needsRescan {
        ContentUnavailableView(
          String(localized: "Scan is out of date after this operation"), systemImage: "arrow.clockwise",
          description: Text(String(localized: "Scan again to refresh duplicate groups before another action."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if store.picture != nil {
        if pictureGroups.isEmpty {
          ContentUnavailableView(
            searchText.isEmpty ? String(localized: "No exact copies found") : String(localized: "No matching groups"),
            systemImage: "checkmark.circle"
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(DuplicatePictureDrawProbe(didDraw: store.pictureDidDraw).allowsHitTesting(false))
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              ForEach(pictureGroups) { group in
                pictureGroupCard(group)
                  .background(DuplicatePictureDrawProbe(didDraw: store.pictureDidDraw).allowsHitTesting(false))
              }
            }
            .padding(.vertical, 12)
          }
        }
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
          Text(
            String.localizedStringWithFormat(
              String(localized: "%lld groups · %lld copies · %@"), Int64(store.selectedGroupCount),
              Int64(store.selectedCopyCount), format(store.selectedLogicalBytes))
          )
          .font(.system(size: 13, weight: .medium)).monospacedDigit()
          Text(String(localized: "Logical bytes to move to Trash; disk space is not yet freed."))
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        }
        Spacer()
        Button(String(localized: "Review selection")) {
          Task { await store.prepare(actions: actions) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          store.picture != nil || store.report == nil || !store.tool.allowsPreparation || store.targets.isEmpty
            || actions.busy || store.needsRescan)
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

  private var selectionControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Text(String(localized: "Minimum size"))
        TextField(
          String(localized: "Minimum size"),
          value: Binding(
            get: { store.duplicatePreferences.minimumMegabytes },
            set: { store.duplicatePreferences.minimumMegabytes = $0 }), format: .number
        )
        .textFieldStyle(.roundedBorder).frame(width: 72)
        .disabled(store.busy)
        Text(String(localized: "MB"))
        Spacer()
        Menu(ruleLabel) {
          Button(String(localized: "Smart")) { keeperRule = .smart }
          Button(String(localized: "Keep newest")) { keeperRule = .newest }
          Button(String(localized: "Keep oldest")) { keeperRule = .oldest }
          Button(String(localized: "Prefer a folder…")) { chooseKeeperFolder() }
        }
        .disabled(store.busy || actions.busy)
        Button(String(localized: "Reduce all to one")) { store.reduceToOne(rule: keeperRule, actions: actions) }
          .buttonStyle(.borderedProminent).disabled(!canApplySelection)
          .accessibilityIdentifier("duplicates.reduce-all")
        Button(String(localized: "Select all")) { store.selectAll(rule: keeperRule, actions: actions) }
          .disabled(!canApplySelection)
        Button(String(localized: "Clear selection")) { store.clearSelection(actions: actions) }
          .disabled(actions.busy || store.busy || store.targets.isEmpty)
      }
      .font(.system(size: 11))
      Text(String(localized: "Hidden folders, app packages, caches, and build outputs are excluded."))
        .font(.system(size: 10)).foregroundStyle(LightenStyle.muted)
    }
    .padding(.vertical, 10)
  }

  private var canApplySelection: Bool {
    !store.busy && !actions.busy && !store.needsRescan && (store.report != nil || store.picture != nil)
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
        Text("\(group.members.count) \(String(localized: "data-identical files"))")
          .font(.system(size: 15, weight: .semibold))
        Spacer()
        Text(format(group.logicalBytes)).font(.system(size: 13, weight: .medium)).monospacedDigit()
      }
      Divider()
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
    let keeperID = store.keeperID(for: member)
    let isKeeper = keeperID == member.id
    let canTarget = keeperID.map { group.canTarget(member.id, keeperID: $0) } ?? false
    let selected = store.targets.contains(member.id)
    return HStack(spacing: 10) {
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
        ForEach(Array(Set(member.metadataWarnings)).sorted { $0.rawValue < $1.rawValue }, id: \.self) { warning in
          Text(metadataWarningLabel(warning)).font(.system(size: 10)).foregroundStyle(LightenStyle.warning)
        }
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
    .contextMenu { rowContextMenu(member.entry.path) }
    .focusable().focused($focusedPath, equals: member.entry.path)
    .onKeyPress(.space) {
      showPreview(member.entry.path)
      return .handled
    }
    .onKeyPress(.upArrow) { moveFocus(-1, from: member.entry.path) }
    .onKeyPress(.downArrow) { moveFocus(1, from: member.entry.path) }
  }

  private func refusalLabel(_ reason: DuplicateObservationRefusal.Reason) -> String {
    switch reason {
    case .unavailable: String(localized: "File or volume is unavailable")
    case .outOfScope: String(localized: "File is outside the current scan scope")
    case .notRegular: String(localized: "File is no longer a regular file")
    case .unreadable: String(localized: "File could not be read")
    case .changed: String(localized: "File changed during verification")
    case .noLongerDuplicate: String(localized: "No matching byte-identical copy remains")
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
