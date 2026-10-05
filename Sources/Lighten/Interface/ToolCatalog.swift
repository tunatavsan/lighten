import LightenKit
import SwiftUI

enum LightenSection: String, CaseIterable, Identifiable {
  case overview, tools, space, clean, duplicates, apps, history
  var id: Self { self }
}

enum ToolGroup: String, CaseIterable, Identifiable {
  case general, storage, applications, activity
  var id: Self { self }
  var title: String {
    switch self {
    case .general: String(localized: "General")
    case .storage: String(localized: "Storage")
    case .applications: String(localized: "Applications")
    case .activity: String(localized: "Activity")
    }
  }
}

struct ToolCatalogEntry: Identifiable {
  let id: LightenSection
  let group: ToolGroup
  let title: String
  let symbol: String
  let description: String
}

enum ToolCatalog {
  static var entries: [ToolCatalogEntry] {
    [
      ToolCatalogEntry(
        id: .overview, group: .general, title: String(localized: "Overview"),
        symbol: "rectangle.grid.2x2", description: String(localized: "Disk, memory, and activity at a glance")),
      ToolCatalogEntry(
        id: .tools, group: .general, title: String(localized: "Tools"),
        symbol: "square.grid.2x2", description: String(localized: "Choose a tool for your Mac")),
      ToolCatalogEntry(
        id: .space, group: .storage, title: String(localized: "Space"),
        symbol: "square.grid.3x3.fill", description: String(localized: "See what takes up disk space")),
      ToolCatalogEntry(
        id: .clean, group: .storage, title: String(localized: "Clean"),
        symbol: "sparkles", description: String(localized: "Review caches and other removable data")),
      ToolCatalogEntry(
        id: .duplicates, group: .storage, title: String(localized: "Duplicates"),
        symbol: "doc.on.doc", description: String(localized: "Find extra copies of your files")),
      ToolCatalogEntry(
        id: .apps, group: .applications, title: String(localized: "Apps"),
        symbol: "app.dashed", description: String(localized: "Review applications and their related data")),
      ToolCatalogEntry(
        id: .history, group: .activity, title: String(localized: "History"),
        symbol: "clock.arrow.circlepath", description: String(localized: "Review actions and restore items from Trash")),
    ]
  }

  static var gridEntries: [ToolCatalogEntry] { entries.filter { $0.id != .tools } }
}

struct ToolPresentation {
  let phase: ToolPhase
  let summary: ToolSummary

  var isWorking: Bool { phase == .scanning || phase == .preparing }
  var resultText: String {
    if isWorking { return String(localized: "Scanning") }
    if phase == .failed { return String(localized: "Could not finish") }
    guard summary.observedAt != nil else { return String(localized: "Not scanned") }
    let size = ByteCountFormatter.string(fromByteCount: summary.logicalBytes, countStyle: .file)
    return summary.partial ? "\(String(localized: "At least")) \(size)" : size
  }

  func resultText(for section: LightenSection) -> String {
    guard !isWorking, phase != .failed, summary.observedAt != nil else { return resultText }
    if section == .apps {
      return String.localizedStringWithFormat(String(localized: "%lld applications"), summary.count)
    }
    return resultText
  }

}

struct ToolSidebarRow: View {
  let entry: ToolCatalogEntry
  let presentation: ToolPresentation?

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        Label(entry.title, systemImage: entry.symbol)
        Spacer(minLength: 0)
        if presentation?.isWorking == true {
          ProgressView().controlSize(.mini)
            .accessibilityLabel(String(localized: "Working in the background"))
        }
      }
      if let presentation, !presentation.isWorking, presentation.summary.observedAt != nil {
        HStack(spacing: 5) {
          Text(presentation.resultText(for: entry.id))
          if let date = presentation.summary.observedAt { Text(date, style: .relative) }
        }
        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct ToolsGridView: View {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let presentations: [LightenSection: ToolPresentation]
  let select: (LightenSection) -> Void

  var body: some View {
    ToolScreen(String(localized: "Tools")) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(String(localized: "Choose a tool for your Mac"))
            .font(.callout).foregroundStyle(.secondary)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
            ForEach(ToolCatalog.gridEntries) { entry in
              Button {
                select(entry.id)
              } label: {
                ToolGridCard(entry: entry, presentation: presentations[entry.id])
                  .padding(18).frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
                  .background(LightenStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                  .overlay {
                    RoundedRectangle(cornerRadius: 14)
                      .stroke(
                        contrast == .increased ? Color.primary : LightenStyle.separator,
                        lineWidth: contrast == .increased || reduceTransparency ? 1.5 : 0.5)
                  }
                  .contentShape(RoundedRectangle(cornerRadius: 14))
              }
              .buttonStyle(.plain)
            }
          }
        }
        .padding(.vertical, 24)
      }
    } toolbar: {
      EmptyView()
    }
  }
}

private struct ToolGridCard: View {
  let entry: ToolCatalogEntry
  let presentation: ToolPresentation?

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Image(systemName: entry.symbol).font(.title2).foregroundStyle(LightenStyle.accent)
        .accessibilityHidden(true)
      Text(entry.title).font(.headline)
      Text(entry.description).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let presentation {
        HStack {
          if presentation.isWorking { ProgressView().controlSize(.mini) }
          Text(presentation.resultText(for: entry.id)).font(.callout.weight(.medium))
        }
        if !presentation.isWorking, presentation.summary.observedAt != nil, entry.id != .apps {
          Text(
            String.localizedStringWithFormat(
              entry.id == .duplicates ? String(localized: "%lld groups") : String(localized: "%lld items"),
              presentation.summary.count)
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if let date = presentation.summary.observedAt {
          Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ToolsPreview: View {
  let dark: Bool

  var body: some View {
    ToolsGridView(presentations: [
      .space: ToolPresentation(
        phase: .ready,
        summary: ToolSummary(
          count: 240, logicalBytes: 256_000_000_000,
          observedAt: Date(timeIntervalSince1970: 1_790_000_000))),
      .clean: ToolPresentation(
        phase: .partial,
        summary: ToolSummary(
          count: 12, logicalBytes: 3_100_000_000,
          observedAt: Date(timeIntervalSince1970: 1_790_000_000), partial: true)),
      .duplicates: ToolPresentation(phase: .scanning, summary: ToolSummary()),
      .apps: ToolPresentation(phase: .idle, summary: ToolSummary()),
    ]) { _ in }
    .preferredColorScheme(dark ? .dark : .light)
    .frame(width: 610, height: 560)
  }
}

#Preview("Tools · Light · Minimum detail width") { ToolsPreview(dark: false) }
#Preview("Tools · Dark · Minimum detail width") { ToolsPreview(dark: true) }
