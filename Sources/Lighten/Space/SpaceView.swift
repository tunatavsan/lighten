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
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorContrast
  @State private var hoveredTileID: ScanItemID?
  @State private var mapDirection: CGFloat = 1
  @State private var compactSurface: CompactSurface = .map
  @State private var showingCompactInspector = false

  private var navigationAnimation: Animation? {
    reduceMotion ? nil : .easeInOut(duration: 0.23)
  }

  private var mapTransition: AnyTransition {
    reduceMotion ? .opacity : .opacity.combined(with: .offset(y: mapDirection * 10))
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
    return store.showingOther ? group.other : group.items
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if store.current != nil {
        breadcrumb
        Divider()
        GeometryReader { geometry in
          if geometry.size.width < 760 {
            compactPane
          } else {
            HSplitView {
              mapColumn.frame(minWidth: 410)
              sidePane.frame(minWidth: 280, idealWidth: 310, maxWidth: 390)
            }
          }
        }
      } else {
        ContentUnavailableView(
          String(localized: "Choose a folder and scan"),
          systemImage: "square.grid.2x2"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      basketDock
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(LightenStyle.canvas)
    .tint(LightenStyle.accent)
    .navigationTitle(String(localized: "Space"))
    .onAppear {
      store.spaceDidAppear()
      store.loadVolumes()
    }
    .sheet(item: $actions.pending) { presentation in
      ConfirmationView(presentation: presentation, actions: actions)
    }
    .sheet(isPresented: $showingCompactInspector) {
      VStack(spacing: 0) {
        HStack {
          Text(String(localized: "Details"))
            .font(.system(size: 16, weight: .semibold))
          Spacer()
          Button(String(localized: "Done")) { showingCompactInspector = false }
        }
        .padding(14)
        Divider()
        inspector.frame(maxHeight: .infinity)
      }
      .frame(width: 440, height: 260)
      .background(LightenStyle.canvas)
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

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text(store.selectedRoot.lastPathComponent)
            .font(.system(size: 24, weight: .semibold))
            .lineLimit(1)
          HStack(spacing: 8) {
            Text(store.selectedRoot.path)
              .lineLimit(1).truncationMode(.middle)
              .textSelection(.enabled)
              .help(store.selectedRoot.path)
              .accessibilityIdentifier("selected-folder")
            Text(phaseLabel)
              .foregroundStyle(store.phase == .partial ? .orange : LightenStyle.muted)
              .fixedSize()
          }
          .font(.system(size: 12))
          .foregroundStyle(LightenStyle.muted)
        }
        Spacer(minLength: 10)
        Picker(
          String(localized: "Volume"),
          selection: Binding(
            get: { store.selectedRoot.path },
            set: { store.selectRoot(URL(fileURLWithPath: $0)) }
          )
        ) {
          ForEach(store.volumes, id: \.path) { volume in
            Text(volume.lastPathComponent.isEmpty ? "/" : volume.lastPathComponent)
              .tag(volume.path)
          }
          if !store.volumes.contains(where: { $0.path == store.selectedRoot.path }) {
            Text(store.selectedRoot.lastPathComponent).tag(store.selectedRoot.path)
          }
        }
        .frame(width: 170)
        Button(String(localized: "Choose folder")) { store.chooseFolder() }
        if store.phase == .scanning {
          Button(String(localized: "Cancel")) { store.cancel() }
        } else {
          Button(String(localized: "Scan")) { store.startScan() }
            .buttonStyle(.borderedProminent)
        }
      }
      HStack(alignment: .center, spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 14) {
            metricValue(String(localized: "Volume used"), store.volumeMeasure?.usedBytes)
            metricValue(String(localized: "Volume free"), store.volumeMeasure?.freeBytes)
            Image(systemName: "info.circle")
              .foregroundStyle(LightenStyle.muted)
              .help(
                String(
                  localized: "Volume use includes snapshots and shared storage; scan covers only the selected folder.")
              )
              .accessibilityLabel(
                String(
                  localized: "Volume use includes snapshots and shared storage; scan covers only the selected folder."))
          }
          if let total = store.volumeMeasure?.totalBytes,
            let used = store.volumeMeasure?.usedBytes, total > 0, used >= 0
          {
            ProgressView(value: min(1, Double(used) / Double(total)))
              .tint(LightenStyle.accent)
              .frame(maxWidth: 270)
              .accessibilityLabel(String(localized: "Volume used"))
          }
        }
        Spacer(minLength: 10)
        VStack(alignment: .trailing, spacing: 2) {
          Text(String(localized: "Selected scan"))
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          Text(sizeLabel(store.current?.bytes(store.metric)))
            .font(.system(size: 16, weight: .semibold))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(navigationAnimation, value: store.metric)
        }
      }
      if let cachedAt = store.cachedAt {
        HStack(spacing: 8) {
          if store.phase == .scanning { ProgressView().controlSize(.small) }
          Text(
            "\(String(localized: "Last scan")): \(cachedAt.formatted(date: .abbreviated, time: .shortened))"
              + (store.phase == .scanning ? " — \(String(localized: "refreshing"))" : ""))
        }
        .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
      } else if store.phase == .scanning {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("\((store.progress?.itemsSeen ?? 0).formatted()) \(String(localized: "items scanned"))")
            .monospacedDigit()
          Text(String(localized: "Sizes grow as folders are measured"))
            .lineLimit(1)
        }
        .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
      } else if case .error(let detail) = store.phase {
        Text(detail).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
      }
    }
    .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)
  }

  private func metricValue(_ title: String, _ value: Int64?) -> some View {
    HStack(spacing: 5) {
      Text(title).foregroundStyle(LightenStyle.muted)
      Text(format(value)).fontWeight(.medium).monospacedDigit()
    }.font(.system(size: 12))
  }

  private var phaseLabel: String {
    switch store.phase {
    case .idle: String(localized: "Ready")
    case .scanning: String(localized: "Scanning")
    case .cancelled: String(localized: "Cancelled")
    case .partial: String(localized: "Partial scan")
    case .complete: String(localized: "Scan complete")
    case .error: String(localized: "Scan failed")
    }
  }

  private var breadcrumb: some View {
    HStack(spacing: 8) {
      Button {
        goBack()
      } label: {
        Image(systemName: "chevron.left")
      }
      .disabled(store.current?.parentID == nil && !store.showingOther)
      .accessibilityLabel(String(localized: "Back"))
      ScrollView(.horizontal) {
        HStack(spacing: 5) {
          if store.currentID != nil {
            ForEach(store.crumbs) { item in
              Button(item.name) { enter(item.id) }
                .buttonStyle(.plain)
              Image(systemName: "chevron.right")
                .font(.system(size: 9)).foregroundStyle(LightenStyle.muted)
            }
          }
          if store.showingOther { Text(String(localized: "Other")) }
        }
        .font(.system(size: 12))
      }
      .scrollIndicators(.hidden)
      Picker(String(localized: "Size metric"), selection: $store.metric) {
        Text(String(localized: "Logical")).tag(SpaceMetric.logical)
        Text(String(localized: "Allocated")).tag(SpaceMetric.allocated)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 220)
    }
    .padding(.horizontal, 20).padding(.vertical, 9)

  }

  private var mapColumn: some View {
    let appearance = store.appearanceToken
    let ready = store.layout != nil
    return VStack(spacing: 0) {
      GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
          if let layout = store.layout {
            ForEach(layout.tiles) { tile in tileButton(tile) }
              .transition(mapTransition)
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
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
      .background(LightenStyle.surface)
      VStack(alignment: .leading, spacing: 6) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            ForEach(LightenStyle.SizeBucket.allCases, id: \.rawValue) { bucket in
              legendSwatch(bucket.color, bucket.label)
            }
          }
          .fixedSize(horizontal: true, vertical: false)
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading
          ) {
            ForEach(LightenStyle.SizeBucket.allCases, id: \.rawValue) { bucket in
              legendSwatch(bucket.color, bucket.label)
            }
          }
        }
        HStack(spacing: 14) {
          Label(String(localized: "Folders"), systemImage: "folder")
          Label(String(localized: "Files"), systemImage: "doc")
          Label(String(localized: "Hatched: known minimum"), systemImage: "line.3.horizontal.decrease")
          Spacer(minLength: 0)
        }
        .foregroundStyle(LightenStyle.muted)
      }
      .font(.system(size: 10))
      .padding(.horizontal, 12).padding(.vertical, 8)
    }
  }

  private func legendSwatch(_ color: Color, _ title: String) -> some View {
    HStack(spacing: 5) {
      Rectangle().fill(color).frame(width: 10, height: 10)
        .overlay(Rectangle().strokeBorder(LightenStyle.separator, lineWidth: 0.5))
      Text(title).foregroundStyle(LightenStyle.muted)
    }
  }

  private func tileButton(_ tile: TreemapTile) -> some View {
    let isOther = tile.id == Self.otherID
    let item = store.visibleByID[tile.id]
    let name = isOther ? String(localized: "Other") : (item.map(SpaceText.name) ?? "")
    let size = isOther ? store.group?.otherBytes : item?.bytes(store.metric)
    return Button {
      if isOther {
        withAnimation(navigationAnimation) { store.showOther() }
      } else if let item, item.canInspect, isSecondMouseClick {
        enter(item.id)
      } else {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { store.selectedID = tile.id }
      }
    } label: {
      Rectangle()
        .fill(isOther ? LightenStyle.surface : color(for: item))
        .overlay {
          if item?.partial == true {
            PartialHatching().stroke(hatchColor(for: item).opacity(0.18), lineWidth: 1)
          }
        }
        .overlay(
          Rectangle().strokeBorder(
            store.selectedID == tile.id
              ? LightenStyle.accent
              : hoveredTileID == tile.id ? LightenStyle.accent.opacity(0.6) : LightenStyle.separator,
            lineWidth: store.selectedID == tile.id
              ? 2 : hoveredTileID == tile.id ? 1.5 : colorContrast == .increased ? 1.5 : 0.7)
        )
        .overlay {
          if isOther {
            Rectangle().strokeBorder(LightenStyle.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          }
          if store.selectedID == tile.id || hoveredTileID == tile.id {
            Rectangle().inset(by: 2).strokeBorder(tileTextColor(for: item), lineWidth: 1)
          }
        }
        .overlay(alignment: .topTrailing) {
          if tile.width >= 28, tile.height >= 22, let item {
            Image(systemName: item.isProtected || item.kind == .systemVolume ? "lock.fill" : SpaceText.symbol(item))
              .font(.system(size: 10)).foregroundStyle(tileTextColor(for: item))
              .padding(5)
          }
        }
        .overlay(alignment: .topLeading) {
          if tile.width >= 95, tile.height >= 46 {
            VStack(alignment: .leading, spacing: 2) {
              Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
              Text(sizeLabel(size))
                .font(.system(size: 11))
                .monospacedDigit().lineLimit(1)
            }
            .foregroundStyle(tileTextColor(for: item))
            .padding(10)
          }
        }
        .frame(width: tile.width, height: tile.height)
        .clipped()
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .position(x: tile.x + tile.width / 2, y: tile.y + tile.height / 2)
    .onHover { hovering in
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
        hoveredTileID = hovering ? tile.id : (hoveredTileID == tile.id ? nil : hoveredTileID)
      }
    }
    .accessibilityLabel("\(name), \(sizeLabel(size))")
    .accessibilityIdentifier(isOther ? "space-other" : "space-tile-\(tile.id)")
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
    guard let item else { return LightenStyle.surface }
    if item.isProtected || item.kind == .systemVolume { return LightenStyle.surface }
    return LightenStyle.SizeBucket.forBytes(item.bytes(store.metric).knownLowerBound).color
  }

  private func tileTextColor(for item: SpaceItem?) -> Color {
    guard let item, !item.isProtected, item.kind != .systemVolume else { return LightenStyle.text }
    return LightenStyle.SizeBucket.forBytes(item.bytes(store.metric).knownLowerBound).textColor
  }

  private func hatchColor(for item: SpaceItem?) -> Color {
    guard let item else { return LightenStyle.separator }
    let bucket = LightenStyle.SizeBucket.forBytes(item.bytes(store.metric).knownLowerBound)
    let text = colorScheme == .dark ? bucket.darkTextHex : bucket.lightTextHex
    return text == 0 ? .white : .black
  }

  private var sidePane: some View {
    VStack(spacing: 0) {
      listPanel
      Divider()
      inspector
    }
    .background(LightenStyle.surface)
  }

  private var compactPane: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Picker(String(localized: "Space view"), selection: $compactSurface) {
          Text(String(localized: "Map")).tag(CompactSurface.map)
          Text(String(localized: "List")).tag(CompactSurface.list)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
        Spacer(minLength: 0)
        if let item = store.selected {
          Text(item.name).lineLimit(1).truncationMode(.middle)
            .font(.system(size: 12, weight: .medium))
          Text(sizeLabel(item.bytes(store.metric)))
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
            .monospacedDigit().fixedSize()
          Button(String(localized: "Details")) { showingCompactInspector = true }
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 8)
      Divider()
      Group {
        if compactSurface == .map { mapColumn } else { listPanel }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5)))
    }
    .background(LightenStyle.surface)
    .animation(navigationAnimation, value: compactSurface)
  }

  private var listPanel: some View {
    VStack(spacing: 0) {
      HStack {
        Text(store.showingOther ? String(localized: "Other items") : String(localized: "Largest items"))
          .font(.system(size: 15, weight: .semibold))
        Spacer()
        Text(String(localized: "Size"))
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      }
      .padding(.horizontal, 12).padding(.vertical, 11)
      Divider()
      List(selection: $store.selectedID) {
        ForEach(visibleItems) { item in
          HStack(spacing: 8) {
            Rectangle().fill(color(for: item)).frame(width: 4)
            Image(systemName: SpaceText.symbol(item))
              .foregroundStyle(LightenStyle.muted)
              .frame(width: 17)
            Text(SpaceText.name(item)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 5)
            Text(sizeLabel(item.bytes(store.metric)))
              .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
              .monospacedDigit().lineLimit(1)
              .frame(minWidth: 72, alignment: .trailing)
            if item.canInspect {
              Button {
                enter(item.id)
              } label: {
                Image(systemName: "chevron.right")
              }
              .buttonStyle(.borderless)
              .accessibilityLabel(String(localized: "Open folder"))
            }
          }
          .font(.system(size: 12))
          .tag(item.id)
          .accessibilityLabel(
            "\(SpaceText.name(item)), \(sizeLabel(item.bytes(store.metric))), \(SpaceText.state(item) ?? String(localized: "Ready"))"
          )
        }
        if !store.showingOther, let other = store.group?.other, !other.isEmpty {
          Button {
            withAnimation(navigationAnimation) { store.showOther() }
          } label: {
            HStack {
              Text("\(String(localized: "Other")) (\(other.count))")
              Spacer()
              Text(sizeLabel(store.group?.otherBytes)).monospacedDigit()
            }
          }
        }
      }
    }
    .background(LightenStyle.surface)
  }

  private var inspector: some View {
    Group {
      if let item = store.selected {
        ScrollView {
          VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
              Text(SpaceText.name(item)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
              Spacer()
              if item.canInspect {
                Button(String(localized: "Open folder")) { enter(item.id) }
                  .buttonStyle(.link)
              }
            }
            Text(item.path)
              .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
              .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
              .help(item.path)
            HStack(spacing: 18) {
              inspectorMetric(String(localized: "Logical"), item.logical)
              inspectorMetric(String(localized: "Allocated"), item.allocated)
            }
            if store.isShowingCache {
              Text(String(localized: "Refreshing previous scan. Actions become available after checking changes."))
                .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let state = SpaceText.state(item) {
              Text(state).font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = SpaceText.unselectable(item), reason != SpaceText.state(item) {
              Text(reason).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
              Button(String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
              }
              Spacer()
              if item.canSelect {
                Button(
                  actions.basket[item.path] == nil
                    ? String(localized: "Add to basket") : String(localized: "In basket")
                ) {
                  withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { actions.add(item) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isShowingCache || actions.basket[item.path] != nil)
              }
            }
          }
          .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        Text(String(localized: "Select an item to see details"))
          .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
    }
    .frame(maxHeight: 205)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.selectedID)
  }

  private func inspectorMetric(_ title: String, _ bytes: ByteAggregate) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      Text(sizeLabel(bytes)).font(.system(size: 13, weight: .medium)).monospacedDigit()
    }
  }

  private var basketDock: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 10) {
        Image(systemName: "basket").foregroundStyle(LightenStyle.accent)
        Text("\(String(localized: "Basket")): \(actions.basket.count)")
          .font(.system(size: 13, weight: .semibold))
        Text(sizeLabel(actions.basketLogical))
          .font(.system(size: 13, weight: .medium)).monospacedDigit()
        if actions.busy { ProgressView().controlSize(.small) }
        Spacer()
        if !actions.basket.isEmpty {
          Button(String(localized: "Clear basket")) { actions.clearBasket() }
            .disabled(actions.busy)
          Button(String(localized: "Review removal")) {
            Task { await actions.prepare(scanRoot: store.selectedRoot.path, runID: store.tree?.runID) }
          }
          .buttonStyle(.borderedProminent).disabled(actions.busy || store.isShowingCache)
        }
        Button(String(localized: "History"), action: showHistory)
      }
      if !actions.basket.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 5) {
            ForEach(actions.basket.values.sorted { $0.path < $1.path }, id: \.path) { item in
              HStack(spacing: 5) {
                Text(item.label).lineLimit(1)
                Button {
                  actions.remove(item.path)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Remove from basket"))
                .disabled(actions.busy)
              }
              .font(.system(size: 11))
              .padding(.horizontal, 8).padding(.vertical, 5)
              .background(LightenStyle.surface, in: Capsule())
              .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
          }
        }
        .scrollIndicators(.hidden)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: actions.basket.count)
      }
      if let result = actions.result {
        Text(resultLine(result))
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
          .lineLimit(1)
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 10)
    .background(LightenStyle.canvas)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: actions.result?.planID)
  }

  private func resultLine(_ result: ActionResult) -> String {
    let parts: [(ActionOutcome, String)] = [
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
    let counts = parts.compactMap { outcome, label -> String? in
      let count = result.items.filter { $0.outcome == outcome }.count
      return count > 0 ? "\(count) \(label)" : nil
    }
    let deltas = result.items.compactMap { item -> String? in
      guard let added = item.addedFileCount, let bytes = item.logicalByteDelta else { return nil }
      let change = (bytes >= 0 ? "+" : "−") + format(bytes == Int64.min ? Int64.max : abs(bytes))
      return "\(added) \(String(localized: "new files")), \(change)"
    }
    return "\(String(localized: "Last result")): \(counts.joined(separator: " · "))"
      + (deltas.isEmpty ? "" : " · " + deltas.joined(separator: "; "))
  }
}

func sizeLabel(_ bytes: ByteAggregate?) -> String {
  guard let bytes else { return String(localized: "Unknown") }
  if let total = bytes.completeTotal { return format(total) }
  if bytes.knownLowerBound > 0 {
    return "\(String(localized: "Known minimum")) \(format(bytes.knownLowerBound))"
  }
  return String(localized: "Unknown")
}

func format(_ bytes: Int64?) -> String {
  guard let bytes else { return String(localized: "Unknown") }
  return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private struct PartialHatching: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    var x = -rect.height
    while x < rect.width {
      path.move(to: CGPoint(x: x, y: rect.height))
      path.addLine(to: CGPoint(x: x + rect.height, y: 0))
      x += 8
    }
    return path
  }
}
