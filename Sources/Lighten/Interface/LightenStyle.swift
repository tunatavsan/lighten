import SwiftUI

/// Former style names, now resolved from `Theme`.
enum LightenStyle {
  typealias SizeBucket = Lighten.SizeBucket
  static let canvas = Theme.Palette.canvas
  static let surface = Theme.Palette.surface
  static let text = Theme.Palette.ink
  static let muted = Theme.Palette.inkSecondary
  static let separator = Theme.Palette.hairline
  static let accent = Theme.Palette.accent
  static let fileTile = Theme.Palette.selection
  static let folderTile = Theme.Palette.selection
  static let warning = Theme.Palette.warning
}
