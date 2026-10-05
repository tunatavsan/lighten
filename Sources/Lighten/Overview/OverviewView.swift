import LightenKit
import SwiftUI

struct OverviewView: View {
  @Bindable var store: OverviewStore
  @Bindable var space: SpaceStore
  @Bindable var actions: ActionStore
  let showSpace: () -> Void
  let showHistory: () -> Void

  var body: some View {
    ToolScreen(String(localized: "Overview")) {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack(alignment: .firstTextBaseline) {
            if let date = store.system?.observedAt {
              Text("\(String(localized: "System checked")) \(date.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
            }
          }
          diskSection
          Divider()
          memorySection
          Divider()
          processSection
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } toolbar: {
      Button(String(localized: "Explore space"), action: showSpace)
    }
    .task { await store.run(rootPath: space.selectedRoot.path) }
    .onAppear { space.showCachedSummary() }
    .onDisappear { store.stop() }
  }

  private var diskSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        sectionHeading(String(localized: "Disk"), symbol: "externaldrive")
        Spacer()
      }
      Text(space.selectedRoot.path)
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        .lineLimit(1).truncationMode(.middle).help(space.selectedRoot.path)
      if let date = store.volumeObservedAt {
        Text("\(String(localized: "Disk checked")) \(date.formatted(date: .omitted, time: .shortened))")
          .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      }
      HStack(alignment: .firstTextBaseline, spacing: 30) {
        metric(String(localized: "Used on volume"), store.volume?.usedBytes)
        metric(String(localized: "Free on volume"), store.volume?.freeBytes)
        Spacer(minLength: 0)
      }
      HStack(alignment: .firstTextBaseline, spacing: 18) {
        VStack(alignment: .leading, spacing: 3) {
          Text(
            "\(String(localized: "Selected scan")): \(scanSize)"
              + (space.cachedAt.map {
                " · \(String(localized: "Last scan")) \($0.formatted(date: .abbreviated, time: .shortened))"
              } ?? ""))
          Text(
            "\(String(localized: "Scanned items")): \(space.rootSummary.map { $0.itemCount.formatted() } ?? String(localized: "Not scanned"))"
          )
        }
        Spacer(minLength: 0)
        Button(
          "\(String(localized: "Pending Trash")): \(format(actions.pendingTrashLogicalBytes))", action: showHistory
        )
        .buttonStyle(.link)
      }
      .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      Text(
        String(
          localized: "Volume usage includes snapshots and shared data. Scan totals and items in Trash are separate.")
      )
      .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var scanSize: String {
    guard let root = space.rootSummary else {
      return String(localized: "Not scanned")
    }
    if let complete = root.logical.completeTotal { return format(complete) }
    if root.logical.knownLowerBound == 0 { return String(localized: "Unknown") }
    return "\(String(localized: "At least")) \(format(root.logical.knownLowerBound))"
  }

  private var memorySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeading(String(localized: "Memory"), symbol: "memorychip")
      HStack(alignment: .firstTextBaseline, spacing: 30) {
        VStack(alignment: .leading, spacing: 4) {
          Text(pressureText(store.system?.pressure ?? .unknown))
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(pressureColor(store.system?.pressure ?? .unknown))
          Text(String(localized: "Memory pressure"))
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(store.system?.swap.map { format(Int64(clamping: $0.usedBytes)) } ?? String(localized: "Unknown"))
            .font(.system(size: 21, weight: .semibold)).monospacedDigit()
          Text(String(localized: "Swap used"))
            .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
        }
        Spacer(minLength: 0)
      }
      if let swap = store.system?.swap {
        Text(
          swap.totalBytes == 0
            ? String(localized: "No swap is allocated; a percentage is unavailable.")
            : "\(String(localized: "Allocated swap")): \(format(Int64(clamping: swap.totalBytes)))"
        )
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      }
      if store.system?.pressure == .unknown {
        Text(String(localized: "Memory pressure is unavailable on this Mac right now."))
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
      }
    }
  }

  private var processSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeading(String(localized: "Processes using memory"), symbol: "list.bullet.rectangle")
      Text(String(localized: "Top 10 processes for your account by resident memory. CPU is a share of one core."))
        .font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
      if let census = store.system?.census {
        if census.partial {
          Text(
            "\(String(localized: "Partial process list")): \(census.unreadableCount) \(String(localized: "unreadable"))\(census.truncated ? " · " + String(localized: "limit reached") : "")"
          )
          .font(.system(size: 11)).foregroundStyle(LightenStyle.warning)
        }
        if store.topProcesses.isEmpty {
          Text(String(localized: "No readable processes in this sample"))
            .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
        } else {
          HStack {
            Text(String(localized: "Process"))
            Spacer()
            Text(String(localized: "Memory used")).frame(width: 100, alignment: .trailing)
            Text(String(localized: "CPU / core")).frame(width: 95, alignment: .trailing)
          }
          .font(.system(size: 11, weight: .medium)).foregroundStyle(LightenStyle.muted)
          ForEach(store.topProcesses) { row in
            HStack(spacing: 8) {
              Text(row.process.name).font(.system(size: 13)).lineLimit(1)
              Spacer(minLength: 8)
              Text(format(Int64(clamping: row.process.residentBytes)))
                .frame(width: 100, alignment: .trailing)
              Text(
                row.corePercent.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" }
                  ?? String(localized: "Unknown")
              )
              .frame(width: 95, alignment: .trailing)
            }
            .font(.system(size: 11)).monospacedDigit()
            .padding(.vertical, 4)
            Divider()
          }
        }
      } else {
        Text(
          store.sampling
            ? String(localized: "Reading system status")
            : String(localized: "Process information unavailable")
        )
        .font(.system(size: 12)).foregroundStyle(LightenStyle.muted)
      }
    }
  }

  private func sectionHeading(_ title: String, symbol: String) -> some View {
    Label(title, systemImage: symbol)
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(LightenStyle.accent)
  }

  private func metric(_ title: String, _ value: Int64?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(format(value)).font(.system(size: 21, weight: .semibold)).monospacedDigit()
      Text(title).font(.system(size: 11)).foregroundStyle(LightenStyle.muted)
    }
  }

  private func pressureText(_ pressure: MemoryPressure) -> String {
    switch pressure {
    case .normal: String(localized: "Normal")
    case .warning: String(localized: "Elevated")
    case .critical: String(localized: "Critical")
    case .unknown: String(localized: "Unknown")
    }
  }

  private func pressureColor(_ pressure: MemoryPressure) -> Color {
    switch pressure {
    case .normal: LightenStyle.accent
    case .warning: LightenStyle.warning
    case .critical: .red
    case .unknown: LightenStyle.muted
    }
  }
}
