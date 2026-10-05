import SwiftUI

/// Size classes for treemap tiles and size swatches, smallest to largest.
enum SizeBucket: Int, CaseIterable {
  case under100MB, under1GB, under5GB, under20GB, under60GB, atLeast60GB

  static func forBytes(_ bytes: Int64) -> Self {
    switch max(0, bytes) {
    case ..<100_000_000: .under100MB
    case ..<1_000_000_000: .under1GB
    case ..<5_000_000_000: .under5GB
    case ..<20_000_000_000: .under20GB
    case ..<60_000_000_000: .under60GB
    default: .atLeast60GB
    }
  }

  var token: ThemeColor { Theme.Palette.sizeRamp[rawValue] }
  var inkToken: ThemeColor { Theme.Palette.sizeRampInk[rawValue] }
  var color: Color { token.color }
  var textColor: Color { inkToken.color }

  var label: String {
    switch self {
    case .under100MB: "< 100 MB"
    case .under1GB: "100 MB–1 GB"
    case .under5GB: "1–5 GB"
    case .under20GB: "5–20 GB"
    case .under60GB: "20–60 GB"
    case .atLeast60GB: "≥ 60 GB"
    }
  }
}
