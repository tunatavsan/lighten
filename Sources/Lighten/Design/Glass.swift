import SwiftUI

// Glass is the system's own Liquid Glass and is used on chrome only: the floating basket,
// the result toast, the menu bar panel and controls laid over content. Content surfaces are
// opaque cards. Glass never samples glass: neighbours share one GlassEffectContainer.

enum GlassRole: Sendable {
  /// Floating chrome: the basket bar, the toast, the menu bar panel.
  case chrome
  /// Chrome that is itself a control.
  case interactive
  /// Chrome that carries the accent, such as a selected floating control.
  case accent

  var glass: Glass {
    switch self {
    case .chrome: .regular.tint(Theme.Palette.glassTintChrome)
    case .interactive: .regular.tint(Theme.Palette.glassTintChrome).interactive()
    case .accent: .regular.tint(Theme.Palette.glassTintAccent).interactive()
    }
  }
}

private struct LightenGlassModifier<S: Shape>: ViewModifier {
  let role: GlassRole
  let shape: S
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    Group {
      if reduceTransparency {
        content.background(shape.fill(Theme.Palette.glassSolid))
      } else {
        content.glassEffect(role.glass, in: shape)
      }
    }
    .overlay {
      if reduceTransparency || contrast == .increased {
        shape.stroke(
          contrast == .increased ? Theme.Palette.hairlineStrong : Theme.Palette.hairline,
          lineWidth: Theme.Stroke.hairline)
      }
    }
  }
}

extension View {
  /// System Liquid Glass in `shape`, an opaque token under Reduce Transparency and a visible edge
  /// under Increase Contrast.
  func lightenGlass(_ role: GlassRole = .chrome, in shape: some Shape = Capsule()) -> some View {
    modifier(LightenGlassModifier(role: role, shape: shape))
  }
}
