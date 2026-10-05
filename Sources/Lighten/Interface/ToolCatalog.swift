import Foundation
import LightenKit
import SwiftUI

enum LightenSection: String, CaseIterable, Identifiable {
  case overview, space, clean, duplicates, apps, history
  var id: Self { self }
}

enum ToolGroup: String, CaseIterable, Identifiable {
  case general, storage, applications, activity
  var id: Self { self }
  /// Overview stands alone at the top of the sidebar, without a heading.
  var title: String? {
    switch self {
    case .general: nil
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
  let tint: Color
}

enum ToolCatalog {
  static var entries: [ToolCatalogEntry] {
    [
      ToolCatalogEntry(
        id: .overview, group: .general, title: String(localized: "Overview"),
        symbol: "gauge.with.dots.needle.33percent",
        description: String(localized: "Disk, memory, and activity at a glance"),
        tint: Theme.Palette.accent),
      ToolCatalogEntry(
        id: .space, group: .storage, title: String(localized: "Space"),
        symbol: "square.grid.3x3.square", description: String(localized: "See what takes up disk space"),
        tint: Theme.Palette.toolSpace),
      ToolCatalogEntry(
        id: .clean, group: .storage, title: String(localized: "Clean"),
        symbol: "sparkles", description: String(localized: "Review caches and other removable data"),
        tint: Theme.Palette.toolClean),
      ToolCatalogEntry(
        id: .duplicates, group: .storage, title: String(localized: "Duplicates"),
        symbol: "doc.on.doc", description: String(localized: "Find extra copies of your files"),
        tint: Theme.Palette.toolDuplicates),
      ToolCatalogEntry(
        id: .apps, group: .applications, title: String(localized: "Apps"),
        symbol: "app.badge.checkmark", description: String(localized: "Review applications and their related data"),
        tint: Theme.Palette.toolApps),
      ToolCatalogEntry(
        id: .history, group: .activity, title: String(localized: "History"),
        symbol: "clock.arrow.circlepath", description: String(localized: "Review actions and restore items from Trash"),
        tint: Theme.Palette.toolHistory),
    ]
  }

  /// The tools Overview offers as cards.
  static var toolEntries: [ToolCatalogEntry] { entries.filter { $0.id != .overview } }

  static func entry(_ section: LightenSection) -> ToolCatalogEntry? { entries.first { $0.id == section } }

  /// Reads display-only pictures without opening a tool or starting discovery.
  static func previousSummaries(
    from pictures: ResultPictureStore, homeDirectory: String = NSHomeDirectory()
  ) async -> [LightenSection: ToolSummary] {
    let previous = await Task.detached(priority: .utility) {
      (
        clean: pictures.load(CleanPicture.self, named: "clean"),
        duplicates: pictures.load(DuplicatePicture.self, named: "duplicates"),
        apps: pictures.load(AppsPicture.self, named: "apps")
      )
    }.value
    func total(_ values: [Int64]) -> Int64 {
      values.reduce(0) { sum, amount in
        let (next, overflow) = sum.addingReportingOverflow(max(0, amount))
        return overflow ? Int64.max : next
      }
    }
    var summaries: [LightenSection: ToolSummary] = [:]
    if let clean = previous.clean {
      summaries[.clean] = ToolSummary(
        count: clean.content.rows.count + clean.content.relatedRows.count,
        logicalBytes: total(
          clean.content.rows.map(\.logicalBytes)
            + clean.content.relatedRows.compactMap(\.logicalBytes)),
        observedAt: clean.observedAt, partial: clean.content.partial)
    }
    if let duplicates = previous.duplicates {
      summaries[.duplicates] = DuplicateStore.summary(for: duplicates.content, observedAt: duplicates.observedAt)
    }
    if let apps = previous.apps {
      let installed = apps.content.rows.filter {
        AppListScope.location(of: $0.path, homeDirectory: homeDirectory) == .installed
      }
      summaries[.apps] = ToolSummary(
        count: installed.count, logicalBytes: total(installed.map { $0.logical.knownLowerBound }),
        observedAt: apps.observedAt,
        partial: !apps.content.inventoryComplete || installed.contains(where: \.partial))
    }
    return summaries
  }

}

struct ToolPresentation {
  let phase: ToolPhase
  let summary: ToolSummary

  init(phase: ToolPhase, summary: ToolSummary, previousSummary: ToolSummary? = nil) {
    self.phase = phase
    self.summary = phase == .idle && summary.observedAt == nil ? previousSummary ?? summary : summary
  }

  var isPreviousResult: Bool { phase == .idle && summary.observedAt != nil }

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
    if section == .duplicates {
      let size = ByteCountFormatter.string(fromByteCount: summary.logicalBytes, countStyle: .file)
      return String.localizedStringWithFormat(
        summary.partial ? String(localized: "Copy file size: at least %@") : String(localized: "Copy file size: %@"),
        size)
    }
    return resultText
  }

  /// The short value the sidebar shows beside a tool; the full text is its tooltip.
  func sidebarValue(for section: LightenSection) -> String? {
    guard !isWorking, phase != .failed, summary.observedAt != nil else { return nil }
    if section == .apps { return summary.count.formatted() }
    let size = ByteCountFormatter.string(fromByteCount: summary.logicalBytes, countStyle: .file)
    return summary.partial ? "≥ " + size : size
  }
}
