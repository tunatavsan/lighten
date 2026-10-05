import SwiftUI

/// The one main action on a screen: an amber capsule with dark ink. Content, not chrome, so it
/// is opaque rather than glass.
struct HeroButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.Font.headline)
      .foregroundStyle(Theme.Palette.heroInk)
      .padding(.horizontal, Theme.Space.l)
      .padding(.vertical, Theme.Space.s)
      .background(Theme.Palette.hero, in: Capsule())
      .overlay {
        if contrast == .increased {
          Capsule().strokeBorder(Theme.Palette.heroInk, lineWidth: Theme.Stroke.hairline)
        }
      }
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
      .contentShape(Capsule())
  }
}

extension ButtonStyle where Self == HeroButtonStyle {
  static var hero: HeroButtonStyle { HeroButtonStyle() }
}

/// A square checkbox drawn as a symbol, for rows whose whole width is a button.
struct CheckSymbol: View {
  let isOn: Bool
  var isMixed = false

  var body: some View {
    Image(systemName: isMixed ? "minus.square.fill" : isOn ? "checkmark.square.fill" : "square")
      .font(Theme.Font.icon)
      .foregroundStyle(isOn || isMixed ? Theme.Palette.accent : Theme.Palette.inkTertiary)
      .contentTransition(.symbolEffect(.replace))
      .accessibilityHidden(true)
  }
}
