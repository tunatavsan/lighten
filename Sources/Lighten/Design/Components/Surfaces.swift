import SwiftUI

/// The tone of a chip, badge or metric.
enum Tone: Sendable {
  case neutral, accent, positive, warning, critical, hero

  var foreground: Color {
    switch self {
    case .neutral: Theme.Palette.inkSecondary
    case .accent: Theme.Palette.accent
    case .positive: Theme.Palette.positive
    case .warning: Theme.Palette.warning
    case .critical: Theme.Palette.critical
    case .hero: Theme.Palette.heroText
    }
  }

  var tint: Color {
    switch self {
    case .neutral: Theme.Palette.neutralTint
    case .accent: Theme.Palette.accentTint
    case .positive: Theme.Palette.positiveTint
    case .warning, .hero: Theme.Palette.warningTint
    case .critical: Theme.Palette.criticalTint
    }
  }
}

private struct CardSurface: ViewModifier {
  var padding: CGFloat
  var radius: CGFloat
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(
            contrast == .increased ? Theme.Palette.hairlineStrong : Theme.Palette.hairline,
            lineWidth: Theme.Stroke.hairline)
      }
  }
}

private struct ModuleEdge: ViewModifier {
  let radius: CGFloat
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    content.overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(
          contrast == .increased ? Theme.Palette.hairlineStrong : Theme.Palette.hairline,
          lineWidth: Theme.Stroke.hairline)
    }
  }
}

extension View {
  /// A content card: surface fill, hairline edge, concentric radius.
  func cardSurface(padding: CGFloat = Theme.Space.l, radius: CGFloat = Theme.Radius.card) -> some View {
    modifier(CardSurface(padding: padding, radius: radius))
  }

  /// A module on the glass pane with no padding of its own: content that reaches its edges, such as a list.
  func moduleSurface(radius: CGFloat = Theme.Radius.card) -> some View {
    background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .modifier(ModuleEdge(radius: radius))
  }

  /// The screen gutter and readable width used by every scrolling screen.
  func screenColumn() -> some View {
    frame(maxWidth: Theme.Layout.readableWidth, alignment: .topLeading)
      .padding(.horizontal, Theme.Layout.gutter)
      .frame(maxWidth: .infinity, alignment: .top)
  }
}

/// A small uppercase-free section heading with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
  let title: String
  private let accessory: Accessory

  init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
    self.title = title
    self.accessory = accessory()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
      Text(title).font(Theme.Font.title2).foregroundStyle(Theme.Palette.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: Theme.Space.s)
      accessory
    }
  }
}

/// A divider inset to align with row text, as grouped lists do.
struct RowDivider: View {
  var leading: CGFloat = 0

  var body: some View {
    Rectangle().fill(Theme.Palette.hairline).frame(height: Theme.Stroke.hairline)
      .padding(.leading, leading)
  }
}

/// A tool's symbol on a quiet neutral tile: monochrome, so colour stays for data and the one main action.
struct ToolGlyph: View {
  let symbol: String
  var size: CGFloat = Theme.Layout.toolTile

  var body: some View {
    Image(systemName: symbol)
      .font(size > Theme.Layout.toolTile ? Theme.Font.title2 : Theme.Font.iconSmall)
      .foregroundStyle(Theme.Palette.ink)
      .frame(width: size, height: size)
      .background(Theme.Palette.well, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
      .accessibilityHidden(true)
  }
}
