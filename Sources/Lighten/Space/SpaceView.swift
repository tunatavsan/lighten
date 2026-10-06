import AppKit
import LightenKit
import SwiftUI

struct SpaceView: View {
  private enum CompactSurface: String, CaseIterable {
    case map, list
  }

  nonisolated private struct LayoutObservation: Equatable, Sendable {
    let appearance: UUID?
    let ready: Bool
    let width: Double
    let height: Double
  }

  static let otherID = ScanItemID(node: -1, slot: -3)
  @Bindable var store: SpaceStore
  @Bindable var actions: ActionStore
  let showHistory: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var colorContrast
  @State private var hoveredTileID: ScanItemID?
  @State private var mapDirection: CGFloat = 1
  @State private var compactSurface: CompactSurface = .map
  @State private var showingInspector = false
  @State private var searchText = ""

  private var navigationAnimation: Animation {
    Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion)
  }

  private var mapTransition: AnyTransition {
    Theme.Motion.transition(.opacity.combined(with: .offset(y: mapDirection * 10)), reduceMotion: reduceMotion)
  }

  private func enter(_ id: ScanItemID) {
    mapDirection = 1
    withAnimation(navigationAnimation) { store.navigate(to: id) }
  }

  private func goBack() {
    mapDirection = -1
    withAnimation(navigationAnimation) { store.back() }
  }

  private var visibleItems: [SpaceItem] {
    guard let group = store.group else { return [] }
    let items = store.showingOther ? group.other : group.items
    let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return term.isEmpty
      ? items : items.filter { $0.name.localizedStandardContains(term) || $0.path.localizedStandardContains(term) }
  }

  private var rootName: String {
    store.selectedRoot.lastPathComponent.isEmpty ? "/" : store.selectedRoot.lastPathComponent
  }

  var body: some View {
    ToolScreen(
      String(localized: "Space"), subtitle: subtitle, search: $searchText,
      searchPrompt: String(localized: "Search items in this folder")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        header
        if store.current != nil {
          pathBar
          GeometryReader { geometry in
            Group {
              if geometry.size.width < Theme.Layout.spaceCompactWidth {
                compactPane
              } else {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                  mapColumn
                  listPanel.frame(width: Theme.Layout.listColumn)
                }
              }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
          }
          .frame(minHeight: 0, maxHeight: .infinity)
          .padding(.bottom, Theme.Space.l)
        } else {
          EmptyState(
            symbol: "square.grid.3x3.square", title: String(localized: "Choose a folder and scan"),
            message: store.selectedRoot.path, tint: Theme.Palette.toolSpace
          ) {
            Button(String(localized: "Scan")) { store.startScan() }.buttonStyle(.hero)
          }
        }
      }
      .padding(.horizontal, Theme.Layout.gutter)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .clipped()
      .floatingBar(isPresented: !actions.basket.isEmpty) { basketBar }
    } actions: {
      Menu {
        Button(String(localized: "Choose folder")) { store.chooseFolder() }
        Divider()
        ForEach(store.volumes, id: \.path) { volume in
          Button(volume.lastPathComponent.isEmpty ? "/" : volume.lastPathComponent) { store.selectRoot(volume) }
        }
      } label: {
        Label(MenuLabel.short(rootName), systemImage: "folder")
      }
      .fixedSize()
      .help(rootName)
      Button(
        store.phase == .scanning ? String(localized: "Cancel scan") : String(localized: "Scan"),
        systemImage: store.phase == .scanning ? "stop.fill" : "arrow.clockwise"
      ) {
        if store.phase == .scanning { store.cancel() } else { store.startScan() }
      }
      .accessibilityIdentifier("space.scan-control")
      Button(String(localized: "Details"), systemImage: "sidebar.trailing") {
        withAnimation(navigationAnimation) { showingInspector.toggle() }
      }
      .labelStyle(.iconOnly)
      .help(String(localized: "Details"))
    }
    .inspector(isPresented: $showingInspector) {
      inspector
        .inspectorColumnWidth(
          min: Theme.Layout.inspectorMinimum, ideal: Theme.Layout.inspectorIdeal, max: Theme.Layout.inspectorMaximum)
    }
    .onChange(of: searchText) { _, text in
      if !text.isEmpty { compactSurface = .list }
    }
    .onChange(of: store.selectedID) { _, id in
      if id != nil, !showingInspector {
        withAnimation(navigationAnimation) { showingInspector = true }
      }
    }
    .animation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion), value: store.displayRevision)
    .onAppear {
      store.spaceDidAppear()
      store.loadVolumes()
    }
    .sheet(item: $actions.pending) { presentation in
      ConfirmationView(presentation: presentation, actions: actions)
    }
    .alert(
      String(localized: "Action needs attention"),
      isPresented: Binding(
        get: { actions.message != nil }, set: { if !$0 { actions.message = nil } }
      )
    ) {
      Button(String(localized: "OK")) { actions.message = nil }
    } message: {
      Text(actions.message ?? "")
    }
  }

  private var subtitle: String {
    if let cachedAt = store.cachedAt {
      return String(localized: "Last scan") + " " + cachedAt.formatted(date: .abbreviated, time: .shortened)
    }
    return phaseLabel
  }

  private var phaseLabel: String {
    switch store.phase {
    case .idle: String(localized: "Ready")
    case .scanning: String(localized: "Scanning")
    case .cancelled: String(localized: "Cancelled")
    case .partial: String(localized: "Incomplete sizes")
    case .complete: String(localized: "Scan complete")
    case .error: String(localized: "Scan failed")
    }
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      HStack(alignment: .bottom, spacing: Theme.Space.xl) {
        HeroMetric(
          value: .aggregate(store.current?.bytes(store.metric)),
          caption: store.current.map(SpaceText.name) ?? rootName)
        Spacer(minLength: Theme.Space.l)
        HStack(alignment: .bottom, spacing: Theme.Space.xl) {
          Metric(
            value: .bytes(store.volumeMeasure?.usedBytes), caption: String(localized: "Volume used"), compact: true)
          Metric(
            value: .bytes(store.volumeMeasure?.freeBytes), caption: String(localized: "Volume free"), compact: true)
          InfoButton(
            text: String(
              localized:
                "Volume used includes snapshots and shared storage. Folder size includes only the items measured here.")
          )
        }
      }
      statusRow
    }
    .padding(.top, Theme.Space.l)
    .padding(.bottom, Theme.Space.m)
  }

  /// At most one line: what is happening now, or why the sizes are not final.
  @ViewBuilder private var statusRow: some View {
    if store.phase == .scanning {
      ScanStatusRow(
        status: String(localized: "Measuring this folder"), count: store.progress?.itemsSeen ?? 0,
        bytes: store.current?.bytes(store.metric).knownLowerBound)
    } else if case .error(let detail) = store.phase {
      PartialNotice(String(localized: "Scan failed")) {
        DetailChip(String(localized: "Details"), symbol: "info.circle", tone: .neutral) {
          Text(detail).textSelection(.enabled)
        }
      }
    } else if store.phase == .partial || store.phase == .cancelled {
      PartialNotice(
        store.phase == .cancelled ? String(localized: "Scan cancelled") : String(localized: "Some sizes are incomplete")
      ) {
        DetailChip(String(localized: "Details"), symbol: "info.circle", tone: .neutral) {
          VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(
              store.phase == .cancelled
                ? String(localized: "The scan was cancelled. Sizes shown may be incomplete.")
                : String(localized: "Some items could not be measured. Folder sizes show at least the space found."))
            if let root = store.rootSummary, let reason = SpaceText.state(root) {
              Text(reason).foregroundStyle(Theme.Palette.inkSecondary)
            }
          }
          .textSelection(.enabled)
        }
      }
    }
    if let message = store.displayMessage {
      NoticeBar(message)
    }
    if actions.completedSummary != nil {
      ActionFeedbackView(actions: actions)
        .accessibilityIdentifier("space.feedback-viewport")
    }
  }

  // MARK: Path

  private var pathBar: some View {
    HStack(spacing: Theme.Space.s) {
      Button {
        goBack()
      } label: {
        Image(systemName: "chevron.backward")
      }
      .buttonStyle(.borderless)
      .disabled(store.current?.parentID == nil && !store.showingOther)
      .accessibilityLabel(String(localized: "Back"))
      ScrollView(.horizontal) {
        HStack(spacing: Theme.Space.xs) {
          if store.currentID != nil {
            ForEach(Array(store.crumbs.enumerated()), id: \.element.id) { index, item in
              if index > 0 {
                Image(systemName: "chevron.forward").font(Theme.Font.iconTiny)
                  .foregroundStyle(Theme.Palette.inkTertiary)
              }
              Button(item.name) { enter(item.id) }
                .buttonStyle(.plain)
                .font(index == store.crumbs.count - 1 && !store.showingOther ? Theme.Font.headline : Theme.Font.body)
                .foregroundStyle(
                  index == store.crumbs.count - 1 && !store.showingOther
                    ? Theme.Palette.ink : Theme.Palette.inkSecondary)
            }
          }
          if store.showingOther {
            Image(systemName: "chevron.forward").font(Theme.Font.iconTiny).foregroundStyle(Theme.Palette.inkTertiary)
            Text(String(localized: "Other")).font(Theme.Font.headline)
          }
        }
      }
      .scrollIndicators(.hidden)
      Picker(String(localized: "Size metric"), selection: $store.metric) {
        Text(String(localized: "File size")).tag(SpaceMetric.logical)
        Text(String(localized: "On disk")).tag(SpaceMetric.allocated)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
    }
    .padding(.bottom, Theme.Space.s)
  }

  // MARK: Map

  private var mapColumn: some View {
    let appearance = store.appearanceToken
    let ready = store.layout != nil
    return VStack(alignment: .leading, spacing: Theme.Space.s) {
      GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
          if let layout = store.layout {
            ForEach(layout.tiles) { tile in tileButton(tile) }
              .transition(mapTransition)
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .animation(navigationAnimation, value: store.layout?.tiles.map(\.id))
        .task(
          id:
            "\(store.tree?.runID.uuidString ?? ""):\(store.currentID?.description ?? ""):\(Int(geometry.size.width)):\(Int(geometry.size.height))"
        ) {
          store.updateLayout(width: geometry.size.width, height: geometry.size.height)
        }
      }
      .onGeometryChange(for: LayoutObservation.self) { geometry in
        LayoutObservation(
          appearance: appearance, ready: ready,
          width: geometry.size.width, height: geometry.size.height)
      } action: { observation in
        if observation.ready {
          store.spaceDidLayout(
            appearance: observation.appearance, width: observation.width, height: observation.height)
        }
      }
      .frame(minHeight: 0, maxHeight: .infinity)
      legend
    }
    .padding(Theme.Space.s)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .moduleSurface()
  }

  private var legend: some View {
    HStack(spacing: Theme.Space.m) {
      ForEach(SizeBucket.allCases, id: \.rawValue) { bucket in
        HStack(spacing: Theme.Space.xs) {
          RoundedRectangle(cornerRadius: Theme.Radius.tile / 2).fill(bucket.color)
            .frame(width: Theme.Space.m - 2, height: Theme.Space.m - 2)
            .overlay(
              RoundedRectangle(cornerRadius: Theme.Radius.tile / 2)
                .strokeBorder(Theme.Palette.hairline, lineWidth: Theme.Stroke.hairline))
          Text(bucket.label).lineLimit(1).fixedSize()
        }
      }
      Spacer(minLength: 0)
      InfoButton(text: String(localized: "A warning sign on a tile means its size is at least the amount shown."))
    }
    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
    .padding(.horizontal, Theme.Space.xs)
    .accessibilityElement(children: .combine)
  }

  private func tileButton(_ tile: TreemapTile) -> some View {
    let isOther = tile.id == Self.otherID
    let item = store.visibleByID[tile.id]
    let name = isOther ? String(localized: "Other") : (item.map(SpaceText.name) ?? "")
    let size = isOther ? store.group?.otherBytes : item?.bytes(store.metric)
    let selected = store.selectedID == tile.id
    let hovered = hoveredTileID == tile.id
    let gap = Theme.Layout.treemapGap
    let width = max(0, tile.width - gap)
    let height = max(0, tile.height - gap)
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
    return Button {
      if isOther {
        withAnimation(navigationAnimation) { store.showOther() }
      } else if let item, item.canInspect, isSecondMouseClick {
        enter(item.id)
      } else {
        withAnimation(Theme.Motion.resolve(Theme.Motion.quick, reduceMotion: reduceMotion)) {
          store.selectedID = tile.id
        }
      }
    } label: {
      shape
        .fill(isOther ? Theme.Palette.well : color(for: item))
        .overlay { shape.strokeBorder(Theme.Palette.tileEdge, lineWidth: Theme.Stroke.hairline) }
        .overlay {
          if hovered && !selected { shape.fill(Theme.Palette.tileHover) }
        }
        .overlay {
          if isOther {
            shape.strokeBorder(
              Theme.Palette.hairlineStrong, style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: [4, 3]))
          } else if selected {
            shape.strokeBorder(Theme.Palette.accent, lineWidth: Theme.Stroke.selection)
            shape.inset(by: Theme.Stroke.selection).strokeBorder(
              Theme.Palette.inkOnAccent, lineWidth: Theme.Stroke.hairline)
          } else if colorContrast == .increased {
            shape.strokeBorder(Theme.Palette.hairlineStrong, lineWidth: Theme.Stroke.hairline)
          }
        }
        .overlay(alignment: .topTrailing) {
          if width >= Theme.Layout.treemapIconMinimum, height >= Theme.Layout.treemapIconMinimum - 4, let item {
            Image(systemName: tileSymbol(item))
              .font(Theme.Font.iconTiny).foregroundStyle(tileTextColor(for: item).opacity(0.75))
              .padding(Theme.Space.xs + 2)
          }
        }
        .overlay(alignment: .topLeading) {
          if width >= Theme.Layout.treemapLabelMinimumWidth, height >= Theme.Layout.treemapLabelMinimumHeight {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
              Text(name).font(Theme.Font.headline).lineLimit(1)
              Text(sizeLabel(size)).font(Theme.Font.monoSmall).lineLimit(1).opacity(0.85)
            }
            .foregroundStyle(isOther ? Theme.Palette.ink : tileTextColor(for: item))
            .padding(Theme.Space.s + 2)
          }
        }
        .frame(width: width, height: height)
        .contentShape(shape)
    }
    .buttonStyle(.plain)
    .position(x: tile.x + tile.width / 2, y: tile.y + tile.height / 2)
    .onHover { hovering in
      withAnimation(Theme.Motion.resolve(Theme.Motion.quick, reduceMotion: reduceMotion)) {
        hoveredTileID = hovering ? tile.id : (hoveredTileID == tile.id ? nil : hoveredTileID)
      }
    }
    .help("\(name) · \(sizeLabel(size))")
    .accessibilityLabel("\(name), \(sizeLabel(size))")
    .accessibilityIdentifier(isOther ? "space-other" : "space-tile-\(tile.id)")
  }

  private func tileSymbol(_ item: SpaceItem) -> String {
    if item.isProtected || item.kind == .systemVolume { return "lock.fill" }
    return item.partial ? "exclamationmark.triangle.fill" : SpaceText.symbol(item)
  }

  /// Button fires on each mouse-up. Read the second click inside that action so
  /// the first click never waits for a competing double-tap recognizer.
  private var isSecondMouseClick: Bool {
    guard let event = NSApp.currentEvent,
      event.type == .leftMouseUp || event.type == .leftMouseDown
    else { return false }
    return event.clickCount >= 2
  }

  private func color(for item: SpaceItem?) -> Color {
    guard let item else { return Theme.Palette.well }
    if item.isProtected || item.kind == .systemVolume { return Theme.Palette.protectedTile }
    return SizeBucket.forBytes(item.bytes(store.metric).knownLowerBound).color
  }

  private func tileTextColor(for item: SpaceItem?) -> Color {
    guard let item, !item.isProtected, item.kind != .systemVolume else { return Theme.Palette.ink }
    return SizeBucket.forBytes(item.bytes(store.metric).knownLowerBound).textColor
  }

  // MARK: List

  private var compactPane: some View {
    VStack(spacing: Theme.Space.s) {
      Picker(String(localized: "Space view"), selection: $compactSurface) {
        Text(String(localized: "Map")).tag(CompactSurface.map)
        Text(String(localized: "List")).tag(CompactSurface.list)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      Group {
        if compactSurface == .map { mapColumn } else { listPanel }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .transition(Theme.Motion.transition(Theme.Motion.rise, reduceMotion: reduceMotion))
    }
    .animation(navigationAnimation, value: compactSurface)
  }

  private var listPanel: some View {
    VStack(spacing: 0) {
      HStack {
        Text(store.showingOther ? String(localized: "Other items") : String(localized: "Largest items"))
          .font(Theme.Font.headline)
        Spacer()
        Text(String(localized: "Size")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
      }
      .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s + 2)
      RowDivider()
      ScrollView {
        LazyVStack(spacing: Theme.Space.xxs) {
          ForEach(visibleItems) { item in listRow(item) }
          if !store.showingOther, let other = store.group?.other, !other.isEmpty {
            Button {
              withAnimation(navigationAnimation) { store.showOther() }
            } label: {
              HStack(spacing: Theme.Space.s) {
                Image(systemName: "ellipsis.circle").foregroundStyle(Theme.Palette.inkSecondary)
                  .frame(width: Theme.Space.l + Theme.Space.xs + Theme.Space.s)
                Text("\(String(localized: "Other")) (\(other.count))")
                Spacer()
                Text(sizeLabel(store.group?.otherBytes)).font(Theme.Font.monoSmall)
                  .foregroundStyle(Theme.Palette.inkSecondary)
              }
              .font(Theme.Font.body)
              .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs + 2)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(Theme.Space.xs + 2)
      }
      .scrollIndicators(.automatic)
    }
    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    .moduleSurface()
  }

  private func listRow(_ item: SpaceItem) -> some View {
    let selected = store.selectedID == item.id
    return HStack(spacing: Theme.Space.s) {
      RoundedRectangle(cornerRadius: Theme.Radius.tile / 2).fill(color(for: item))
        .frame(width: Theme.Space.xs, height: Theme.Space.l)
      Image(systemName: SpaceText.symbol(item))
        .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.inkSecondary)
        .frame(width: Theme.Space.l)
      VStack(alignment: .leading, spacing: Theme.Space.xxs) {
        Text(SpaceText.name(item)).font(Theme.Font.body).lineLimit(1).truncationMode(.middle)
        if let reason = actions.failure(at: item.path) {
          Text(reason).font(Theme.Font.caption).foregroundStyle(Theme.Palette.warning).lineLimit(1).help(reason)
        }
      }
      Spacer(minLength: Theme.Space.xs)
      if item.partial {
        Image(systemName: "exclamationmark.triangle.fill").font(Theme.Font.iconTiny)
          .foregroundStyle(Theme.Palette.warning)
          .help(SpaceText.state(item) ?? "")
      }
      Text(sizeLabel(item.bytes(store.metric)))
        .font(Theme.Font.monoSmall).foregroundStyle(Theme.Palette.inkSecondary)
        .lineLimit(1)
      if item.canInspect {
        Button {
          enter(item.id)
        } label: {
          Image(systemName: "chevron.forward").font(Theme.Font.iconSmall)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(String(localized: "Open folder"))
      } else {
        Spacer().frame(width: Theme.Space.m)
      }
    }
    .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs + 2)
    .background {
      if selected {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.selection)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { if item.canInspect { enter(item.id) } }
    .onTapGesture {
      withAnimation(Theme.Motion.resolve(Theme.Motion.quick, reduceMotion: reduceMotion)) { store.selectedID = item.id }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(
      "\(SpaceText.name(item)), \(sizeLabel(item.bytes(store.metric))), \(SpaceText.state(item) ?? String(localized: "Ready"))"
    )
  }

  // MARK: Inspector

  @ViewBuilder private var inspector: some View {
    if let item = store.selected {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
          HStack(spacing: Theme.Space.m) {
            Image(systemName: item.isProtected ? "lock.fill" : SpaceText.symbol(item))
              .font(Theme.Font.iconLarge)
              .foregroundStyle(color(for: item) == Theme.Palette.well ? Theme.Palette.accent : color(for: item))
              .frame(width: Theme.Layout.appIconLarge * 0.75)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
              Text(SpaceText.name(item)).font(Theme.Font.title2).lineLimit(2)
              PathLabel(path: item.path, lines: 2).textSelection(.enabled)
            }
          }
          HStack(spacing: Theme.Space.xl) {
            Metric(value: .aggregate(item.logical), caption: String(localized: "File size"), compact: true)
            Metric(value: .aggregate(item.allocated), caption: String(localized: "On disk"), compact: true)
          }
          if let title = SpaceText.stateTitle(item), let state = SpaceText.state(item) {
            DetailChip(title, symbol: "exclamationmark.triangle.fill") { Text(state).textSelection(.enabled) }
          }
          if store.isShowingCache {
            NoticeBar(
              String(localized: "Refreshing previous scan. Actions become available after checking changes."),
              symbol: "clock", tone: .neutral)
          }
          if !ActionStore.canManuallySelect(item), let reason = SpaceText.unselectable(item),
            reason != SpaceText.state(item)
          {
            NoticeBar(reason, symbol: "info.circle", tone: .neutral)
          }
          VStack(alignment: .leading, spacing: Theme.Space.s) {
            if ActionStore.canManuallySelect(item) {
              Button {
                withAnimation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: reduceMotion)) {
                  actions.add(item, warningPath: store.observedWarningPath(for: item), tree: store.tree)
                }
              } label: {
                Label(
                  actions.basket[item.path] == nil
                    ? String(localized: "Add to basket") : String(localized: "In basket"),
                  systemImage: actions.basket[item.path] == nil ? "basket" : "checkmark"
                )
                .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .disabled(store.isShowingCache || actions.basket[item.path] != nil)
            }
            HStack {
              ShowInFinderButton(path: item.path)
              if item.canInspect {
                Spacer()
                Button(String(localized: "Open folder"), systemImage: "arrow.forward.circle") { enter(item.id) }
              }
            }
            .buttonStyle(.borderless)
          }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .animation(Theme.Motion.resolve(Theme.Motion.quick, reduceMotion: reduceMotion), value: store.selectedID)
    } else {
      EmptyState(
        symbol: "cursorarrow.click.2", title: String(localized: "Select an item to see details"),
        tint: Theme.Palette.inkTertiary)
    }
  }

  // MARK: Basket

  private var basketBar: some View {
    FloatingBar {
      SelectionSummary(
        symbol: "basket",
        title: String.localizedStringWithFormat(String(localized: "Basket: %lld"), Int64(actions.basket.count)),
        value: .aggregate(actions.basketLogical))
      ScrollView(.horizontal) {
        HStack(spacing: Theme.Space.xs) {
          ForEach(actions.basket.values.sorted { $0.path < $1.path }, id: \.path) { item in
            HStack(spacing: Theme.Space.xs) {
              Text(item.label).lineLimit(1)
              Button {
                actions.remove(item.path)
              } label: {
                Image(systemName: "xmark.circle.fill")
              }
              .buttonStyle(.plain)
              .foregroundStyle(Theme.Palette.inkSecondary)
              .accessibilityLabel(String(localized: "Remove from basket"))
              .disabled(actions.busy)
            }
            .font(Theme.Font.caption)
            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
            .background(Theme.Palette.neutralTint, in: Capsule())
            .help(item.path)
          }
        }
      }
      .scrollIndicators(.hidden)
      .frame(maxWidth: Theme.Layout.basketChipsWidth)
    } actions: {
      if actions.busy { ProgressView().controlSize(.small) }
      Button(String(localized: "Clear basket")) { actions.clearBasket() }
        .buttonStyle(.glass)
        .disabled(actions.busy)
      Button(String(localized: "Review removal")) {
        Task { await actions.prepare(scanRoot: store.selectedRoot.path, runID: store.tree?.runID) }
      }
      .buttonStyle(.glassProminent)
      .disabled(actions.busy || store.isShowingCache)
      .accessibilityIdentifier("space.review-removal")
    }
  }
}

extension View {
  /// Header rows span the full width with the screen gutter.
  fileprivate func screenColumnFull() -> some View {
    padding(.horizontal, Theme.Layout.gutter).frame(maxWidth: .infinity, alignment: .leading)
  }
}

func sizeLabel(_ bytes: ByteAggregate?) -> String {
  guard let bytes else { return String(localized: "Unknown") }
  if let total = bytes.completeTotal { return format(total) }
  if bytes.knownLowerBound > 0 {
    return "\(String(localized: "At least")) \(format(bytes.knownLowerBound))"
  }
  return String(localized: "Unknown")
}

func format(_ bytes: Int64?) -> String {
  guard let bytes else { return String(localized: "Unknown") }
  return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
