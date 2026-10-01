import AppKit
import LightenKit
import SwiftUI

struct AppsView: View {
  @Bindable var store: AppsStore
  @Bindable var actions: ActionStore
  @State private var searchText = ""
  @State private var showingCompactDetail = false
  @State private var expandedOrphans: Set<String> = []
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var filtered: [ApplicationReport] {
    let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return store.reports }
    return store.reports.filter {
      $0.path.localizedStandardContains(term)
        || ($0.bundleID?.localizedStandardContains(term) == true)
    }
  }

  var body: some View {
    let scanBusy = store.busy
    GeometryReader { geometry in
      let compact = geometry.size.width < 800
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 14) {
          VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Apps"))
              .font(.system(size: 24, weight: .semibold))
            Text(String(localized: "Installed applications and their related data"))
              .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
          }
          Spacer()
          Button(store.busy ? String(localized: "Cancel scan") : String(localized: "Scan")) {
            if store.busy { store.cancelScan() } else { store.startScan(actions: actions) }
          }
          .accessibilityIdentifier("apps.scan-control")
        }
        .padding(.bottom, 14)
        HStack(spacing: 12) {
          TextField(String(localized: "Search by name or path"), text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 340)
          Text(
            store.pictureRows.isEmpty
              ? "\(filtered.count) / \(store.reports.count)" : "\(store.pictureRows.count)"
          )
          .font(.system(size: 11)).monospacedDigit().foregroundStyle(LightenStyle.muted)
          Spacer()
          if let date = store.pictureObservedAt ?? store.scannedAt {
            HStack(spacing: 4) {
              Text(String(localized: "Last scan:"))
              Text(date, style: .date)
              Text(date, style: .time)
            }
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          }
        }
        .padding(.bottom, 10)
        if store.busy {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(store.measuredCount) \(String(localized: "applications measured"))")
              .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
            if !store.reports.isEmpty {
              Text(
                store.measuringPaths.isEmpty
                  ? String(localized: "Reviewing related data")
                  : String(localized: "Remaining sizes are being measured")
              )
              .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
            }
          }
          .padding(.bottom, 10)
        }
        if store.needsRescan {
          Label(
            String(localized: "This list needs a new scan before actions are available."),
            systemImage: "arrow.clockwise.circle"
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
          .padding(.bottom, 10)
        }
        if store.scannedAt != nil && !store.inventoryComplete {
          Label(
            String(
              localized: "Application inventory is incomplete. Other locations and unreadable apps remain unknown."),
            systemImage: "exclamationmark.circle"
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
          .padding(.bottom, 10)
        }
        Divider()
        if !store.pictureRows.isEmpty {
          pictureList
        } else if store.reports.isEmpty && store.orphanCandidates.isEmpty && !store.busy {
          ContentUnavailableView(
            store.scannedAt == nil
              ? String(localized: "Scan installed apps") : String(localized: "No applications found"),
            systemImage: "app.dashed",
            description: Text(String(localized: "Inspect applications in /Applications and your Applications folder."))
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.busy && store.reports.isEmpty {
          VStack(spacing: 10) {
            ProgressView()
            Text(String(localized: "Scanning applications"))
              .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if compact {
          if showingCompactDetail, let app = store.selectedReport {
            VStack(spacing: 0) {
              HStack {
                Button {
                  withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    showingCompactDetail = false
                  }
                } label: {
                  Label(String(localized: "All apps"), systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LightenStyle.accent)
                Spacer()
              }
              .padding(.vertical, 10)
              detail(app)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          } else {
            applicationList
          }
        } else {
          HStack(spacing: 0) {
            applicationList
              .frame(width: min(420, (geometry.size.width - 40) * 0.34))
            Divider()
            if let app = store.selectedReport {
              detail(app)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
              ContentUnavailableView(
                String(localized: "Select an application"), systemImage: "app.dashed"
              )
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
        if store.selectedReport != nil && (!compact || showingCompactDetail) {
          Divider()
          if compact {
            VStack(alignment: .leading, spacing: 8) {
              reviewExplanation
              HStack {
                Spacer()
                reviewButton
              }
            }
            .padding(.top, 10)
          } else {
            HStack {
              reviewExplanation
              Spacer()
              reviewButton
            }
            .padding(.top, 10)
          }
        }
        if let message = store.message {
          Divider()
          Text(message).font(.system(size: 11)).foregroundStyle(LightenStyle.warning).padding(.top, 9)
        }
        if let result = actions.result, result.planID == store.presentedPlanID {
          Text(resultLine(result))
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted).padding(.top, 7)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(LightenStyle.canvas)
    .onGeometryChange(for: Bool.self) { _ in
      scanBusy
    } action: { busy in
      if !busy { store.scanDidLayout() }
    }
    .navigationTitle(String(localized: "Apps"))
    .sheet(item: $actions.pending) { presentation in
      ConfirmationView(presentation: presentation, actions: actions)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.selectedPath)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.selectedDataPaths)
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

  private var applicationList: some View {
    Group {
      if filtered.isEmpty && store.orphanCandidates.isEmpty {
        ContentUnavailableView(String(localized: "No matching applications"), systemImage: "magnifyingglass")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 5) {
            ForEach(filtered) { app in appRow(app) }
            orphanSection
          }
          .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
  }

  private var pictureList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        Label(String(localized: "Previous result · refreshing before actions"), systemImage: "clock")
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        ForEach(
          store.pictureRows.filter {
            searchText.isEmpty || $0.path.localizedStandardContains(searchText)
              || $0.bundleID?.localizedStandardContains(searchText) == true
          }
        ) { row in
          HStack(spacing: 10) {
            ApplicationIconView(path: row.path)
            VStack(alignment: .leading, spacing: 3) {
              Text(URL(fileURLWithPath: row.path).deletingPathExtension().lastPathComponent)
                .font(.system(size: 12, weight: .medium))
              Text(row.path).font(.system(size: 10)).foregroundStyle(LightenStyle.muted)
                .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(format(row.logical.completeTotal ?? row.logical.knownLowerBound))
              .font(.system(size: 11)).monospacedDigit()
          }
          .accessibilityElement(children: .combine)
        }
      }
      .padding(.vertical, 10)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var orphanSection: some View {
    let groups = Dictionary(grouping: store.orphanCandidates) {
      $0.bundleID ?? $0.receipt?.bundleID ?? String(localized: "Unknown")
    }
    return VStack(alignment: .leading, spacing: 10) {
      if !groups.isEmpty {
        Text(String(localized: "Data from removed apps")).font(.system(size: 14, weight: .semibold))
        Text(
          String(
            localized:
              "No installed owner was found. These files may contain settings or documents; nothing is selected automatically."
          )
        )
        .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
        ForEach(groups.keys.sorted(), id: \.self) { bundleID in
          DisclosureGroup(
            isExpanded: Binding(
              get: { expandedOrphans.contains(bundleID) },
              set: { if $0 { expandedOrphans.insert(bundleID) } else { expandedOrphans.remove(bundleID) } }
            )
          ) {
            ForEach(groups[bundleID] ?? []) { candidate in
              HStack(alignment: .top, spacing: 8) {
                if candidate.canSelect && candidate.classification != .installed && !store.busy && !store.needsRescan {
                  Button {
                    store.toggleOrphan(candidate.path, actions: actions)
                  } label: {
                    Image(
                      systemName: store.selectedOrphanPaths.contains(candidate.path)
                        ? "checkmark.square.fill" : "square")
                  }.buttonStyle(.plain)
                    .accessibilityLabel(candidate.path)
                } else {
                  Image(systemName: "info.circle.fill").foregroundStyle(LightenStyle.warning)
                }
                VStack(alignment: .leading, spacing: 3) {
                  Text(candidate.path).font(.system(size: 10)).lineLimit(2).truncationMode(.middle)
                  Text(
                    candidate.classification == .installed
                      ? String(localized: "Refresh Apps to review data left after removal.")
                      : String(localized: "App no longer found · review carefully")
                  )
                  .font(.system(size: 10)).foregroundStyle(LightenStyle.warning)
                  if let date = candidate.modifiedAt {
                    HStack(spacing: 3) {
                      Text(String(localized: "Modified:"))
                      Text(date, style: .date)
                    }.font(.system(size: 10)).foregroundStyle(LightenStyle.muted)
                  }
                }
              }.padding(.vertical, 4)
            }
          } label: {
            Text(bundleID).font(.system(size: 11, weight: .medium))
          }
        }
        Button(String(localized: "Review selected removed-app data")) {
          Task { await store.prepareOrphans(actions: actions) }
        }.disabled(
          store.selectedOrphanPaths.isEmpty || store.busy || store.preparing || store.needsRescan || actions.busy)
      }
    }.padding(.top, groups.isEmpty ? 0 : 14)
  }

  private var reviewExplanation: some View {
    Text(
      store.needsRescan
        ? String(localized: "Scan again to review data")
        : store.selectedReviewPending
          ? String(localized: "Checking this app’s data. You can review the app itself now.")
          : String(localized: "Select the app, its data, or both")
    )
    .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
  }

  private var reviewButton: some View {
    Button(String(localized: "Review selected")) {
      Task { await store.prepareSelectedData(actions: actions) }
    }
    .buttonStyle(.borderedProminent)
    .disabled(
      (store.selectedDataPaths.isEmpty && !store.packageSelected) || store.preparing
        || store.needsRescan || actions.busy)
  }

  private func appRow(_ app: ApplicationReport) -> some View {
    let selected = store.selectedPath == app.path
    return Button {
      store.select(app.path, actions: actions)
      showingCompactDetail = true
    } label: {
      HStack(spacing: 10) {
        ApplicationIconView(path: app.path)
        VStack(alignment: .leading, spacing: 3) {
          Text(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent)
            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
          Text(app.bundleID ?? String(localized: "Identity unavailable"))
            .font(.system(size: 10)).foregroundStyle(LightenStyle.muted)
            .lineLimit(1).truncationMode(.middle)
          if let reason = store.packageUnavailableReason(app), !store.busy || store.unsupportedPackageReason(app) != nil
          {
            Text(reason).font(.system(size: 10)).foregroundStyle(LightenStyle.warning)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 2) {
          Text(store.measuringPaths.contains(app.path) ? String(localized: "Measuring") : sizeText(app))
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
          if !store.measuringPaths.contains(app.path) && app.partial && app.logical.knownLowerBound > 0 {
            Text(String(localized: "At least"))
              .font(.system(size: 9)).foregroundStyle(LightenStyle.muted)
          }
        }
        .fixedSize(horizontal: true, vertical: false)
      }
      .padding(.horizontal, 9).padding(.vertical, 8)
      .background(
        selected ? LightenStyle.fileTile.opacity(0.7) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(store.needsRescan || store.unsupportedPackageReason(app) != nil)
    .accessibilityLabel(
      "\(app.path), \(store.measuringPaths.contains(app.path) ? String(localized: "Measuring") : app.partial ? String(localized: "Partial size") : String(localized: "Measured size"))"
    )
  }

  private func detail(_ app: ApplicationReport) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 12) {
          ApplicationIconView(path: app.path)
          VStack(alignment: .leading, spacing: 3) {
            Text(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent)
              .font(.system(size: 19, weight: .semibold)).lineLimit(2).truncationMode(.middle)
            Text(app.path).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
              .lineLimit(2).truncationMode(.middle).help(app.path)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(alignment: .firstTextBaseline) {
          Text(store.measuringPaths.contains(app.path) ? String(localized: "Measuring") : sizeText(app))
            .font(.system(size: 23, weight: .semibold)).monospacedDigit()
          Text(
            app.partial && app.logical.knownLowerBound == 0
              ? String(localized: "Size unavailable")
              : app.partial ? String(localized: "Known lower bound") : String(localized: "Logical size")
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          Spacer()
        }
        Text(
          String(
            localized: "Protected package contents are measured from metadata. Trash size is not freed disk space.")
        )
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        VStack(alignment: .leading, spacing: 5) {
          metadataRow(String(localized: "Bundle ID"), app.bundleID ?? String(localized: "Unknown"))
          metadataRow(String(localized: "Version"), app.version ?? String(localized: "Unknown"))
          metadataRow(String(localized: "Signer"), app.signerTeamID ?? String(localized: "Unavailable"))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 9))
        if let id = app.bundleID, store.runningIDs.contains(id) {
          Label(
            String(localized: "App is running. Quit it normally before reviewing its data."),
            systemImage: "pause.circle"
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
        }
        if app.manualUninstallerSuggested {
          Label(
            String(localized: "This app contains a system extension or helper. Check the vendor's uninstaller."),
            systemImage: "info.circle"
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
        }
        packageSelection(app)
        relatedSection(app)
      }
      .padding(14)
    }
  }

  private func metadataRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        .frame(width: 75, alignment: .leading)
      Text(value).font(.system(size: 11)).textSelection(.enabled)
        .lineLimit(2).truncationMode(.middle).help(value)
    }
  }

  private func packageSelection(_ app: ApplicationReport) -> some View {
    let reason = store.packageUnavailableReason(app)
    return VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .top, spacing: 8) {
        if reason == nil {
          Button {
            store.togglePackage(actions: actions)
          } label: {
            Image(systemName: store.packageSelected ? "checkmark.square.fill" : "square")
          }
          .buttonStyle(.plain)
          .accessibilityLabel(String(localized: "Move the whole app to Trash"))
        } else {
          Image(systemName: "info.circle.fill").foregroundStyle(LightenStyle.warning)
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(String(localized: "Move the whole app to Trash"))
            .font(.system(size: 13, weight: .medium))
          Text(
            reason
              ?? String(localized: "The app moves as one package. Its data below stays unless you select it too.")
          )
          .font(.system(size: 11)).foregroundStyle(reason == nil ? LightenStyle.muted : LightenStyle.warning)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      if reason != nil, app.linkTarget == nil {
        Button(String(localized: "Show in Finder")) {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
        }
        .font(.system(size: 11))
      }
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 9))
  }

  private func relatedSection(_ app: ApplicationReport) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(String(localized: "Related data"))
        .font(.system(size: 15, weight: .semibold))
      Text(
        String(localized: "Data is separate from the app. Exact names show a possible link, not guaranteed ownership.")
      )
      .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      .fixedSize(horizontal: false, vertical: true)
      if app.related.isEmpty {
        Text(
          store.needsRescan
            ? String(localized: "Scan again to review related data")
            : store.selectedReviewPending
              ? String(localized: "Related data is being reviewed")
              : String(localized: "No matching standard data locations found")
        )
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      }
      if store.ownershipPendingPaths.contains(app.path) {
        Label(
          String(localized: "Checking which apps use the shared folder. You can review other items now."),
          systemImage: "clock"
        )
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      }
      ForEach(app.related) { candidate in
        relatedRow(candidate, app: app)
      }
      Label(
        String(localized: "Shared containers are included only when this app is their sole verified owner."),
        systemImage: "lock.shield"
      )
      .font(.system(size: 10)).foregroundStyle(LightenStyle.muted)
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 9))
  }

  private func relatedRow(_ candidate: RelatedDataCandidate, app: ApplicationReport) -> some View {
    let eligible = canSelect(candidate, app: app)
    let selected = store.selectedDataPaths.contains(candidate.path)
    return HStack(alignment: .top, spacing: 8) {
      if eligible {
        Button {
          store.toggleData(candidate.path, actions: actions)
        } label: {
          Image(systemName: selected ? "checkmark.square.fill" : "square")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "\(selected ? String(localized: "Deselect") : String(localized: "Select")) \(URL(fileURLWithPath: candidate.path).lastPathComponent)"
        )
      } else {
        Image(systemName: "info.circle.fill").foregroundStyle(LightenStyle.warning)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(URL(fileURLWithPath: candidate.path).lastPathComponent)
          .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
        Text(candidate.path).font(.system(size: 10)).foregroundStyle(LightenStyle.muted)
          .lineLimit(1).truncationMode(.middle).help(candidate.path)
        Text(relatedReason(candidate, eligible: eligible))
          .font(.system(size: 10)).foregroundStyle(eligible ? LightenStyle.muted : LightenStyle.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 3)
      if let observation = candidate.observation {
        Text(format(observation.logical.completeTotal ?? observation.logical.knownLowerBound))
          .font(.system(size: 10)).monospacedDigit()
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func canSelect(_ candidate: RelatedDataCandidate, app: ApplicationReport) -> Bool {
    store.canSelect(candidate, app: app)
  }

  private func relatedReason(_ candidate: RelatedDataCandidate, eligible: Bool) -> String {
    if candidate.reason == .candidateAreaUnreadable || candidate.reason == .recordUnsafe {
      return String(localized: "Metadata unavailable or unsafe · report only")
    }
    return switch candidate.classification {
    case .installed:
      eligible
        ? String(localized: "Exact standard app location · separate Trash choice")
        : String(localized: "Needs complete, safe scan and a closed app")
    case .protected: String(localized: "Protected · report only")
    case .shared: String(localized: "Shared · report only")
    case .uncertain: String(localized: "Association uncertain · report only")
    case .historicallyVerifiedAbsent: String(localized: "Previously associated · review in Clean")
    case .orphanVerified: String(localized: "App no longer found · review carefully")
    }
  }

  private func resultLine(_ result: ActionResult) -> String {
    let categories: [(ActionOutcome, String)] = [
      (.applied, String(localized: "Moved to Trash")),
      (.skipped, String(localized: "Skipped")),
      (.failed, String(localized: "Failed")),
      (.uncertain, String(localized: "Uncertain")),
      (.notAttempted, String(localized: "Not attempted")),
    ]
    let counts = categories.compactMap { outcome, label -> String? in
      let count = result.items.filter { $0.outcome == outcome }.count
      return count > 0 ? "\(count) \(label)" : nil
    }
    let details = result.items.compactMap(\.detail).map(FailureText.describe)
    return (counts + details).joined(separator: " · ")
  }

  private func sizeText(_ app: ApplicationReport) -> String {
    if app.partial && app.logical.knownLowerBound == 0 { return String(localized: "Unknown") }
    return format(app.logical.completeTotal ?? app.logical.knownLowerBound)
  }
}
