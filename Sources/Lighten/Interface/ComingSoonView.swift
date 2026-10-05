import SwiftUI

/// A tool that has its place in Lighten but is not built yet: its symbol, what it will do, and nothing
/// that could pass for a result.
struct ComingSoonView: View {
  let entry: ToolCatalogEntry

  var body: some View {
    ToolScreen(entry.title, subtitle: String(localized: "Coming soon")) {
      VStack(spacing: Theme.Space.l) {
        ToolGlyph(symbol: entry.symbol, size: Theme.Layout.comingSoonGlyph)
        Text(entry.description).font(Theme.Font.title2).foregroundStyle(Theme.Palette.ink)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        Chip(title: String(localized: "Coming soon"), symbol: "clock", tone: .accent)
      }
      .frame(maxWidth: Theme.Layout.emptyStateWidth)
      .padding(Theme.Space.xxl)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    }
  }
}
