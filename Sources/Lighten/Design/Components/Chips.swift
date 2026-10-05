import AppKit
import SwiftUI

/// A compact capsule label: a state, a count, a reason's short name.
struct Chip: View {
  let title: String
  var symbol: String?
  var tone: Tone = .neutral

  var body: some View {
    HStack(spacing: Theme.Space.xs) {
      if let symbol { Image(systemName: symbol).font(Theme.Font.iconTiny) }
      Text(title).lineLimit(1)
    }
    .font(Theme.Font.captionMedium)
    .foregroundStyle(tone.foreground)
    .padding(.horizontal, Theme.Space.s)
    .padding(.vertical, Theme.Space.xxs + 1)
    .background(tone.tint, in: Capsule())
    .accessibilityElement(children: .combine)
  }
}

/// A chip that opens a popover with the full, named explanation. Reasons are never dropped:
/// the chip carries the short form and the popover the rest.
struct DetailChip<Detail: View>: View {
  let title: String
  var symbol: String?
  var tone: Tone = .warning
  private let detail: Detail
  @State private var showing = false

  init(_ title: String, symbol: String? = nil, tone: Tone = .warning, @ViewBuilder detail: () -> Detail) {
    self.title = title
    self.symbol = symbol
    self.tone = tone
    self.detail = detail()
  }

  var body: some View {
    Button {
      showing.toggle()
    } label: {
      HStack(spacing: Theme.Space.xs) {
        Chip(title: title, symbol: symbol, tone: tone)
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(title)
    .popover(isPresented: $showing, arrowEdge: .bottom) {
      ScrollView {
        detail
          .font(Theme.Font.callout)
          .foregroundStyle(Theme.Palette.ink)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .padding(Theme.Space.l)
      }
      .frame(width: Theme.Layout.popoverWidth)
      .frame(maxHeight: Theme.Layout.popoverMaximumHeight)
    }
    .accessibilityLabel(title)
    .accessibilityHint(String(localized: "Shows details"))
  }
}

extension DetailChip where Detail == ReasonDetail {
  /// A chip for a failure or refusal: its primary reason as the title, everything in the popover.
  init(
    reason: FailurePresentation, path: String? = nil, tone: Tone = .warning,
    symbol: String = "exclamationmark.triangle.fill"
  ) {
    self.init(reason.primaryReason, symbol: symbol, tone: tone) {
      ReasonDetail(presentation: reason, path: path)
    }
  }
}

/// The full text of a failure: every reason, the next step and the path.
struct ReasonDetail: View {
  let presentation: FailurePresentation
  var path: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      ForEach(presentation.reasons, id: \.self) { reason in
        Text(reason).font(Theme.Font.bodyMedium)
      }
      if !presentation.nextStep.isEmpty {
        Text(presentation.nextStep).foregroundStyle(Theme.Palette.inkSecondary)
      }
      if let path {
        PathLabel(path: path, lines: 3).textSelection(.enabled)
        Button(String(localized: "Show in Finder")) {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .controlSize(.small)
      }
    }
  }
}

/// An ⓘ button whose popover holds the explanation a screen no longer prints inline.
struct InfoButton: View {
  let text: String
  @State private var showing = false

  var body: some View {
    Button {
      showing.toggle()
    } label: {
      Image(systemName: "info.circle").font(Theme.Font.icon).foregroundStyle(Theme.Palette.inkSecondary)
    }
    .buttonStyle(.plain)
    .help(text)
    .accessibilityLabel(String(localized: "More information"))
    .accessibilityHint(text)
    .popover(isPresented: $showing, arrowEdge: .bottom) {
      Text(text).font(Theme.Font.callout).fixedSize(horizontal: false, vertical: true)
        .frame(width: Theme.Layout.popoverWidth - Theme.Space.xxl, alignment: .leading)
        .padding(Theme.Space.l)
    }
  }
}

/// A coloured dot and a word: the state of a scan, an item or a permission.
struct StatusLabel: View {
  let title: String
  var tone: Tone = .neutral

  var body: some View {
    HStack(spacing: Theme.Space.xs + 1) {
      Circle().fill(tone == .neutral ? Theme.Palette.inkTertiary : tone.foreground)
        .frame(width: Theme.Space.s - 1, height: Theme.Space.s - 1)
      Text(title).foregroundStyle(tone == .neutral ? Theme.Palette.inkSecondary : tone.foreground)
    }
    .font(Theme.Font.callout)
    .accessibilityElement(children: .combine)
  }
}

/// A path that keeps its start and end: shortened in the middle, complete in the tooltip.
struct PathLabel: View {
  let path: String
  var lines = 1

  var body: some View {
    Text(path)
      .font(Theme.Font.caption)
      .foregroundStyle(Theme.Palette.inkSecondary)
      .lineLimit(lines).truncationMode(.middle)
      .help(path)
  }
}

/// Chips that wrap onto as many lines as they need.
struct FlowChips<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    FlowLayout(spacing: Theme.Space.xs) { content }
  }
}

/// Places subviews left to right and starts a new line when one does not fit.
struct FlowLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map { $0.width }.max() ?? 0
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if needed > width, !current.indices.isEmpty {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
