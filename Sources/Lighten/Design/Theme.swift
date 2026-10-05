import AppKit
import SwiftUI

// Lighten's design tokens. Colour, type, spacing, radius and motion are defined here and
// nowhere else; DesignTokenLiteralTests fails on a literal colour, font size or animation
// timing anywhere else in the app target.
//
// The palette comes from the app icon: four golden-ratio tiles in indigo, violet, orchid and
// amber. Violet is the accent. Amber is the hero colour, reserved for space a user gets back
// and for the single main action on a screen.

enum Theme {}

// MARK: - Colour

/// One adaptive colour: light and dark values plus their Increase Contrast twins.
struct ThemeColor: Sendable {
  let light: UInt32
  let dark: UInt32
  let highContrastLight: UInt32
  let highContrastDark: UInt32
  let alpha: CGFloat

  init(
    light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil, alpha: CGFloat = 1
  ) {
    self.light = light
    self.dark = dark
    self.highContrastLight = highContrastLight ?? light
    self.highContrastDark = highContrastDark ?? dark
    self.alpha = alpha
  }

  func hex(dark isDark: Bool, highContrast: Bool = false) -> UInt32 {
    switch (isDark, highContrast) {
    case (true, true): highContrastDark
    case (true, false): dark
    case (false, true): highContrastLight
    case (false, false): light
    }
  }

  var nsColor: NSColor {
    let token = self
    return NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      return Self.rgb(token.hex(dark: isDark, highContrast: contrast), alpha: token.alpha)
    }
  }

  var color: Color { Color(nsColor: nsColor) }

  static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
  }
}

extension Theme {
  enum Palette {
    // Brand, from the icon's PALETTE.txt (OKLCH 0.48–0.82).
    static let indigo = ThemeColor(light: 0x2256BB, dark: 0x5B8AE6).color
    static let violet = ThemeColor(light: 0x6B58CA, dark: 0x8F80EE, highContrastLight: 0x4F3DA8).color
    static let orchid = ThemeColor(light: 0xA25CC8, dark: 0xC487E8).color
    static let amber = ThemeColor(light: 0xE79703, dark: 0xFFB138).color

    /// Interactive elements, selection and focus.
    static let accent = violet
    /// Space a user gets back, and the one main action per screen.
    static let hero = amber
    /// Hero numbers set as text: amber darkened until it reads on a light surface.
    static let heroText = ThemeColor(light: 0xA45F00, dark: 0xFFBE55, highContrastLight: 0x7A4500).color
    /// Ink on a hero (amber) fill.
    static let heroInk = ThemeColor(light: 0x2E1C00, dark: 0x2E1C00).color

    // Neutrals. Text follows the system label colours so vibrancy and contrast settings apply.
    static let ink = Color(nsColor: .labelColor)
    static let inkSecondary = Color(nsColor: .secondaryLabelColor)
    static let inkTertiary = Color(nsColor: .tertiaryLabelColor)
    static let inkOnAccent = ThemeColor(light: 0xFFFFFF, dark: 0xFFFFFF).color

    /// The content canvas, a faint lavender taken from the icon's background.
    static let canvas = ThemeColor(
      light: 0xF6F6FA, dark: 0x1C1C21, highContrastLight: 0xFFFFFF, highContrastDark: 0x121215
    )
    .color
    /// Cards and grouped rows on the canvas.
    static let surface = ThemeColor(light: 0xFFFFFF, dark: 0x26262D, highContrastDark: 0x1E1E24).color
    /// A recessed well inside a card: tracks, empty treemap tiles, code-like values.
    static let well = ThemeColor(light: 0xEFEEF6, dark: 0x1F1F26, highContrastLight: 0xE4E3EE).color
    /// Selected and hovered rows.
    static let selection = ThemeColor(light: 0xECE9FC, dark: 0x343050, highContrastLight: 0xDCD6FA).color
    static let hairline = ThemeColor(
      light: 0x000000, dark: 0xFFFFFF, highContrastLight: 0x000000, highContrastDark: 0xFFFFFF, alpha: 0.09
    ).color
    static let hairlineStrong = ThemeColor(light: 0x5A5A66, dark: 0xB4B4C0).color

    // Status. Text tones meet 4.5:1 on `surface`; tints are their chip backgrounds.
    static let positive = ThemeColor(light: 0x1C7C45, dark: 0x57CC8F).color
    static let warning = ThemeColor(light: 0x8F5300, dark: 0xF2B44E, highContrastLight: 0x6B3E00).color
    static let critical = ThemeColor(light: 0xBF3129, dark: 0xFF7A70, highContrastLight: 0x9A1F18).color
    static let positiveTint = ThemeColor(light: 0x1C7C45, dark: 0x57CC8F, alpha: 0.14).color
    static let warningTint = ThemeColor(light: 0xE79703, dark: 0xFFB138, alpha: 0.16).color
    static let criticalTint = ThemeColor(light: 0xBF3129, dark: 0xFF7A70, alpha: 0.14).color
    static let accentTint = ThemeColor(light: 0x6B58CA, dark: 0x8F80EE, alpha: 0.14).color
    static let neutralTint = ThemeColor(light: 0x5A5A70, dark: 0xB4B4C8, alpha: 0.12).color

    /// Tool tiles in the sidebar and on Overview: one brand tone per tool.
    static let toolSpace = indigo
    static let toolClean = violet
    static let toolDuplicates = orchid
    static let toolApps = ThemeColor(light: 0x4E62D6, dark: 0x7D8CF0).color
    static let toolHistory = ThemeColor(light: 0x6E6A86, dark: 0x9C98B4).color
    static let toolComingSoon = ThemeColor(light: 0x8A88A0, dark: 0x77758C).color

    // Glass tints (system Liquid Glass, never a blur plus a fill).
    static let glassTintChrome = ThemeColor(light: 0xFFFFFF, dark: 0x2A2933, alpha: 0.18).color
    static let glassTintAccent = ThemeColor(light: 0x6B58CA, dark: 0x8F80EE, alpha: 0.22).color
    /// What Reduce Transparency shows instead of glass.
    static let glassSolid = ThemeColor(light: 0xF9F9FC, dark: 0x2B2B33).color

    /// Treemap and size swatches, smallest to largest: one family from lavender to deep orchid.
    static let sizeRamp: [ThemeColor] = [
      ThemeColor(light: 0xECEBFA, dark: 0x2C2B40),
      ThemeColor(light: 0xD5D1F6, dark: 0x38355E),
      ThemeColor(light: 0xB6AEF0, dark: 0x4B4588),
      ThemeColor(light: 0x7462D6, dark: 0x6554C4),
      ThemeColor(light: 0x9550C6, dark: 0x9459CA),
      ThemeColor(light: 0x7A3DAC, dark: 0xC683EA),
    ]
    /// Text on each `sizeRamp` step.
    static let sizeRampInk: [ThemeColor] = [
      ThemeColor(light: 0x1E1844, dark: 0xFFFFFF),
      ThemeColor(light: 0x1E1844, dark: 0xFFFFFF),
      ThemeColor(light: 0x1E1844, dark: 0xFFFFFF),
      ThemeColor(light: 0xFFFFFF, dark: 0xFFFFFF),
      ThemeColor(light: 0xFFFFFF, dark: 0xFFFFFF),
      ThemeColor(light: 0xFFFFFF, dark: 0x22103A),
    ]
    /// Protected and system blocks in the treemap.
    static let protectedTile = ThemeColor(light: 0xE4E3EC, dark: 0x2A2A31).color
    static let hatch = ThemeColor(light: 0x000000, dark: 0xFFFFFF, alpha: 0.16).color
  }
}

// MARK: - Type

extension Theme {
  /// System font only. Sizes follow the macOS type ramp (body 13).
  enum Font {
    /// The one large number at the top of a screen.
    static let hero = SwiftUI.Font.system(size: 40, weight: .semibold)
    /// The unit after a hero number ("GB").
    static let heroUnit = SwiftUI.Font.system(size: 22, weight: .medium)
    /// Secondary metrics beside the hero.
    static let metric = SwiftUI.Font.system(size: 20, weight: .semibold)
    static let metricSmall = SwiftUI.Font.system(size: 15, weight: .semibold)
    static let title = SwiftUI.Font.system(size: 22, weight: .bold)
    static let title2 = SwiftUI.Font.system(size: 17, weight: .semibold)
    static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
    static let body = SwiftUI.Font.system(size: 13)
    static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
    static let callout = SwiftUI.Font.system(size: 12)
    static let calloutMedium = SwiftUI.Font.system(size: 12, weight: .medium)
    static let caption = SwiftUI.Font.system(size: 11)
    static let captionMedium = SwiftUI.Font.system(size: 11, weight: .medium)
    static let micro = SwiftUI.Font.system(size: 10, weight: .medium)
    /// Sizes and counts in lists, set in SF Mono so columns align.
    static let mono = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
    static let monoSmall = SwiftUI.Font.system(size: 11, design: .monospaced)
    /// Glyphs inside tiles and badges.
    static let iconLarge = SwiftUI.Font.system(size: 28, weight: .medium)
    static let icon = SwiftUI.Font.system(size: 15, weight: .medium)
    static let iconSmall = SwiftUI.Font.system(size: 11, weight: .semibold)
    static let iconTiny = SwiftUI.Font.system(size: 9, weight: .bold)
    static let emptySymbol = SwiftUI.Font.system(size: 44, weight: .light)
  }
}

// MARK: - Space, radius, layout

extension Theme {
  /// A 4-point scale.
  enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
  }

  /// Concentric radii: an inner radius is the outer one minus its inset.
  enum Radius {
    static let tile: CGFloat = 4
    static let chip: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 14
    static let panel: CGFloat = 20
  }

  enum Stroke {
    static let hairline: CGFloat = 1
    static let selection: CGFloat = 2
  }

  enum Layout {
    static let windowDefault = CGSize(width: 1200, height: 780)
    static let windowMinimum = CGSize(width: 900, height: 600)
    static let sidebarMinimum: CGFloat = 200
    static let sidebarIdeal: CGFloat = 220
    static let sidebarMaximum: CGFloat = 280
    /// Horizontal inset of screen content from the window edge.
    static let gutter: CGFloat = 28
    static let readableWidth: CGFloat = 1080
    static let inspectorMinimum: CGFloat = 260
    static let inspectorIdeal: CGFloat = 300
    static let inspectorMaximum: CGFloat = 380
    static let listColumn: CGFloat = 340
    /// Below this content width Space shows the map and the list one at a time.
    static let spaceCompactWidth: CGFloat = 760
    static let basketChipsWidth: CGFloat = 280
    static let toolTile: CGFloat = 28
    static let sidebarGlyph: CGFloat = 20
    static let toolTileLarge: CGFloat = 40
    static let appIcon: CGFloat = 32
    static let appIconLarge: CGFloat = 64
    static let sizeColumn: CGFloat = 84
    static let statusColumn: CGFloat = 110
    static let capacityBarHeight: CGFloat = 10
    static let meterHeight: CGFloat = 6
    static let floatingBarMaximum: CGFloat = 760
    static let floatingBarClearance: CGFloat = 84
    static let sheetWidth: CGFloat = 600
    static let sheetHeight: CGFloat = 520
    static let welcomeWidth: CGFloat = 560
    static let settingsWidth: CGFloat = 520
    static let menuBarWidth: CGFloat = 300
    static let memoryCardWidth: CGFloat = 300
    static let toolCardMinimum: CGFloat = 172
    static let popoverWidth: CGFloat = 320
    static let emptyStateWidth: CGFloat = 380
    static let popoverMaximumHeight: CGFloat = 420
    static let treemapGap: CGFloat = 2
    static let treemapLabelMinimumWidth: CGFloat = 92
    static let treemapLabelMinimumHeight: CGFloat = 44
    static let treemapIconMinimum: CGFloat = 26
  }
}

// MARK: - Motion

extension Theme {
  /// Springs with at most 0.05 bounce. Reduce Motion replaces every movement with a cross-fade.
  enum Motion {
    static let quick = Animation.spring(duration: 0.2, bounce: 0)
    static let standard = Animation.spring(duration: 0.32, bounce: 0.04)
    static let gentle = Animation.spring(duration: 0.5, bounce: 0.02)
    static let reduced = Animation.easeInOut(duration: 0.18)
    /// How long a completion toast stays.
    static let toastLifetime = Duration.seconds(6)

    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
      reduceMotion ? reduced : animation
    }

    /// `transition`, or a plain fade under Reduce Motion.
    static func transition(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
      reduceMotion ? .opacity : transition
    }

    static let rise = AnyTransition.opacity.combined(with: .offset(y: 8))
    static let pop = AnyTransition.opacity.combined(with: .scale(scale: 0.96))
  }
}
