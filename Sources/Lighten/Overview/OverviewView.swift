import LightenKit
import SwiftUI

struct OverviewView: View {
  @Bindable var store: OverviewStore
  @Bindable var space: SpaceStore
  @Bindable var actions: ActionStore
  let presentations: [LightenSection: ToolPresentation]
  let show: (LightenSection) -> Void

  var body: some View {
    ToolScreen(String(localized: "Overview"), subtitle: subtitle) {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
              DiskCard(store: store, space: space, actions: actions, show: show)
              MemoryCard(store: store).frame(width: Theme.Layout.memoryCardWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Theme.Space.l) {
              DiskCard(store: store, space: space, actions: actions, show: show)
              MemoryCard(store: store)
            }
          }
          VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(String(localized: "Tools"))
            LazyVGrid(
              columns: Array(
                repeating: GridItem(.flexible(minimum: Theme.Layout.toolCardMinimum), spacing: Theme.Space.m),
                count: ToolCatalog.toolEntries.count),
              spacing: Theme.Space.m
            ) {
              ForEach(ToolCatalog.toolEntries) { entry in
                ToolCard(entry: entry, presentation: presentations[entry.id], actions: actions) { show(entry.id) }
              }
            }
          }
          ProcessSection(store: store)
        }
        .screenColumn()
        .padding(.vertical, Theme.Space.xl)
      }
    }
    .task { await store.run(rootPath: space.selectedRoot.path) }
    .onAppear { space.showCachedSummary() }
    .onDisappear { store.stop() }
  }

  private var subtitle: String? {
    guard let date = store.system?.observedAt else { return nil }
    return String(localized: "System checked") + " " + date.formatted(date: .omitted, time: .shortened)
  }
}

// MARK: - Disk

private struct DiskCard: View {
  @Bindable var store: OverviewStore
  @Bindable var space: SpaceStore
  @Bindable var actions: ActionStore
  let show: (LightenSection) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.l) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
        Label(volumeName, systemImage: "internaldrive")
          .font(Theme.Font.headline).foregroundStyle(Theme.Palette.inkSecondary)
        Spacer(minLength: Theme.Space.s)
        InfoButton(
          text: String(
            localized: "Volume usage includes snapshots and shared data. Scan totals and items in Trash are separate."))
      }
      HeroMetric(value: .bytes(store.volume?.freeBytes), caption: freeCaption)
      CapacityBar(segments: segments)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Theme.Space.l) {
          legends
          Spacer(minLength: 0)
        }
        VStack(alignment: .leading, spacing: Theme.Space.xs) { legends }
      }
      RowDivider()
      HStack(alignment: .center, spacing: Theme.Space.l) {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
          Text(scanSummary).font(Theme.Font.bodyMedium).monospacedDigit()
          Text(scanDetail).font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary)
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: Theme.Space.s)
        Button(String(localized: "Explore space")) { show(.space) }
          .buttonStyle(.hero)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .cardSurface(padding: Theme.Space.xl, radius: Theme.Radius.panel)
  }

  @ViewBuilder private var legends: some View {
    legend(String(localized: "Used on volume"), store.volume?.usedBytes, color: Theme.Palette.indigo)
    Button {
      show(.history)
    } label: {
      legend(String(localized: "Pending Trash"), actions.pendingTrashLogicalBytes, color: Theme.Palette.hero)
    }
    .buttonStyle(.plain)
    .help(String(localized: "Trash items have not freed disk space."))
    legend(String(localized: "Free on volume"), store.volume?.freeBytes, color: Theme.Palette.well)
  }

  private var volumeName: String {
    let url = URL(fileURLWithPath: space.selectedRoot.path)
    return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
      ?? String(localized: "Disk")
  }

  private var freeCaption: String {
    guard let total = store.volume?.totalBytes else { return String(localized: "Free on volume") }
    return String.localizedStringWithFormat(
      String(localized: "Free of %@"), ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
  }

  private var segments: [CapacityBar.Segment] {
    guard let total = store.volume?.totalBytes, total > 0, let used = store.volume?.usedBytes else { return [] }
    let trash = min(actions.pendingTrashLogicalBytes, used)
    return [
      .init(id: "used", fraction: Double(used - trash) / Double(total), color: Theme.Palette.indigo),
      .init(id: "trash", fraction: Double(trash) / Double(total), color: Theme.Palette.hero),
    ]
  }

  private func legend(_ title: String, _ bytes: Int64?, color: Color) -> some View {
    HStack(spacing: Theme.Space.xs + 2) {
      Circle().fill(color).frame(width: Theme.Space.s, height: Theme.Space.s)
        .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: Theme.Stroke.hairline))
      Text(title).foregroundStyle(Theme.Palette.inkSecondary)
      Text(format(bytes)).font(Theme.Font.mono).foregroundStyle(Theme.Palette.ink)
    }
    .font(Theme.Font.callout)
    .accessibilityElement(children: .combine)
  }

  private var scanSummary: String {
    guard let root = space.rootSummary else { return String(localized: "Not scanned") }
    let size: String
    if let complete = root.logical.completeTotal {
      size = format(complete)
    } else if root.logical.knownLowerBound == 0 {
      size = String(localized: "Unknown")
    } else {
      size = String(localized: "At least") + " " + format(root.logical.knownLowerBound)
    }
    return String(localized: "Selected scan") + ": " + size
  }

  private var scanDetail: String {
    var parts = [space.selectedRoot.path]
    if let items = space.rootSummary?.itemCount {
      parts.append(String.localizedStringWithFormat(String(localized: "%lld items"), Int64(clamping: items)))
    }
    if let date = space.cachedAt {
      parts.append(String(localized: "Last scan") + " " + date.formatted(date: .abbreviated, time: .shortened))
    }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Memory

private struct MemoryCard: View {
  @Bindable var store: OverviewStore

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.l) {
      HStack {
        Label(String(localized: "Memory"), systemImage: "memorychip")
          .font(Theme.Font.headline).foregroundStyle(Theme.Palette.inkSecondary)
        Spacer()
      }
      VStack(alignment: .leading, spacing: Theme.Space.xs) {
        Text(PressureText.title(pressure)).font(Theme.Font.title)
          .foregroundStyle(
            PressureText.tone(pressure) == .neutral ? Theme.Palette.ink : PressureText.tone(pressure).foreground)
        Text(String(localized: "Memory pressure")).font(Theme.Font.callout).foregroundStyle(Theme.Palette.inkSecondary)
      }
      .accessibilityElement(children: .combine)
      PressureScale(pressure: pressure)
      RowDivider()
      HStack(alignment: .top) {
        Metric(
          value: store.system?.swap.map { .bytes(Int64(clamping: $0.usedBytes)) }
            ?? .text(String(localized: "Unknown")),
          caption: String(localized: "Swap used"), compact: true)
        Spacer()
        if let swap = store.system?.swap {
          if swap.totalBytes == 0 {
            InfoButton(text: String(localized: "No swap is allocated; a percentage is unavailable."))
          } else {
            Metric(
              value: .bytes(Int64(clamping: swap.totalBytes)), caption: String(localized: "Allocated swap"),
              compact: true)
          }
        }
      }
      if store.system?.pressure == .unknown {
        NoticeBar(String(localized: "Memory pressure is unavailable on this Mac right now."))
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .cardSurface(padding: Theme.Space.xl, radius: Theme.Radius.panel)
  }

  private var pressure: MemoryPressure { store.system?.pressure ?? .unknown }
}

/// Three steps of memory pressure, the current one lit.
private struct PressureScale: View {
  let pressure: MemoryPressure

  var body: some View {
    HStack(spacing: Theme.Space.xs) {
      ForEach([MemoryPressure.normal, .warning, .critical], id: \.self) { step in
        Capsule()
          .fill(step == pressure ? PressureText.tone(step).foreground : Theme.Palette.well)
          .frame(height: Theme.Layout.meterHeight)
      }
    }
    .accessibilityHidden(true)
  }
}

enum PressureText {
  static func title(_ pressure: MemoryPressure) -> String {
    switch pressure {
    case .normal: String(localized: "Normal")
    case .warning: String(localized: "Elevated")
    case .critical: String(localized: "Critical")
    case .unknown: String(localized: "Unknown")
    }
  }

  static func tone(_ pressure: MemoryPressure) -> Tone {
    switch pressure {
    case .normal: .positive
    case .warning: .warning
    case .critical: .critical
    case .unknown: .neutral
    }
  }
}

// MARK: - Tools

private struct ToolCard: View {
  let entry: ToolCatalogEntry
  let presentation: ToolPresentation?
  let actions: ActionStore
  let open: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: Theme.Space.m) {
        HStack(alignment: .top) {
          ToolGlyph(symbol: entry.symbol, size: Theme.Layout.toolTileLarge)
          Spacer()
          if presentation?.isWorking == true {
            ProgressView().controlSize(.small)
          } else if presentation?.isPreviousResult == true {
            Image(systemName: "clock.arrow.circlepath").font(Theme.Font.iconSmall)
              .foregroundStyle(Theme.Palette.inkTertiary)
              .help(String(localized: "Previous result"))
              .accessibilityLabel(String(localized: "Previous result"))
          }
        }
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
          Text(entry.title).font(Theme.Font.headline).foregroundStyle(Theme.Palette.ink)
          Text(value).font(Theme.Font.metricSmall).monospacedDigit().foregroundStyle(Theme.Palette.ink)
            .lineLimit(1).minimumScaleFactor(0.75)
          Text(caption).font(Theme.Font.caption).foregroundStyle(Theme.Palette.inkSecondary).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface()
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
          .strokeBorder(hovering ? Theme.Palette.accent : .clear, lineWidth: Theme.Stroke.hairline)
      }
      .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityElement(children: .combine)
    .accessibilityHint(entry.description)
  }

  private var value: String {
    if entry.id == .history {
      return ByteCountFormatter.string(fromByteCount: actions.pendingTrashLogicalBytes, countStyle: .file)
    }
    guard let presentation else { return String(localized: "Not scanned") }
    if entry.id == .apps { return presentation.resultText(for: .apps) }
    return presentation.sidebarValue(for: entry.id) ?? presentation.resultText
  }

  private var caption: String {
    if entry.id == .history { return String(localized: "Pending Trash") }
    guard let presentation, let date = presentation.summary.observedAt, !presentation.isWorking else {
      return entry.description
    }
    return date.formatted(.relative(presentation: .named))
  }

  private var help: String {
    guard let presentation, presentation.summary.observedAt != nil, entry.id != .history else {
      return entry.description
    }
    var parts = [presentation.resultText(for: entry.id)]
    if entry.id == .space || entry.id == .clean {
      parts.append(String.localizedStringWithFormat(String(localized: "%lld items"), Int64(presentation.summary.count)))
    }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Processes

private struct ProcessSection: View {
  @Bindable var store: OverviewStore

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      SectionHeader(String(localized: "Processes using memory")) {
        InfoButton(
          text: String(localized: "Top 10 processes for your account by resident memory. CPU is a share of one core."))
      }
      VStack(spacing: 0) {
        if let census = store.system?.census {
          if census.partial {
            NoticeBar(partialText(census)).padding(Theme.Space.s)
          }
          if store.topProcesses.isEmpty {
            Text(String(localized: "No readable processes in this sample"))
              .font(Theme.Font.callout).foregroundStyle(Theme.Palette.inkSecondary)
              .padding(Theme.Space.l)
          } else {
            header
            ForEach(Array(store.topProcesses.enumerated()), id: \.element.id) { index, row in
              if index > 0 { RowDivider(leading: Theme.Space.l) }
              processRow(row)
            }
          }
        } else {
          HStack(spacing: Theme.Space.s) {
            if store.sampling { ProgressView().controlSize(.small) }
            Text(
              store.sampling
                ? String(localized: "Reading system status") : String(localized: "Process information unavailable")
            )
            .font(Theme.Font.callout).foregroundStyle(Theme.Palette.inkSecondary)
          }
          .padding(Theme.Space.l)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .cardSurface(padding: 0)
    }
  }

  private var header: some View {
    HStack {
      Text(String(localized: "Process"))
      Spacer()
      Text(String(localized: "Memory used")).frame(width: Theme.Layout.statusColumn, alignment: .trailing)
      Text(String(localized: "CPU / core")).frame(width: Theme.Layout.sizeColumn, alignment: .trailing)
    }
    .font(Theme.Font.captionMedium).foregroundStyle(Theme.Palette.inkSecondary)
    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
    .background(Theme.Palette.well)
  }

  private func processRow(_ row: ProcessDisplay) -> some View {
    HStack(spacing: Theme.Space.s) {
      Text(row.process.name).font(Theme.Font.body).lineLimit(1)
      Spacer(minLength: Theme.Space.s)
      Text(format(Int64(clamping: row.process.residentBytes)))
        .frame(width: Theme.Layout.statusColumn, alignment: .trailing)
      Text(
        row.corePercent.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" }
          ?? String(localized: "Unknown")
      )
      .frame(width: Theme.Layout.sizeColumn, alignment: .trailing)
    }
    .font(Theme.Font.mono).foregroundStyle(Theme.Palette.ink)
    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
    .accessibilityElement(children: .combine)
  }

  private func partialText(_ census: ProcessCensus) -> String {
    "\(String(localized: "Partial process list")): \(census.unreadableCount) \(String(localized: "unreadable"))"
      + (census.truncated ? " · " + String(localized: "limit reached") : "")
  }
}
