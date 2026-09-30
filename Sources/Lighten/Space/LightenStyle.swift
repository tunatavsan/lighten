import AppKit
import SwiftUI

enum LightenStyle {
  static let canvas = Color(nsColor: .windowBackgroundColor)
  static let surface = Color(nsColor: .controlBackgroundColor)
  static let text = Color(nsColor: .labelColor)
  static let muted = Color(nsColor: .secondaryLabelColor)
  static let separator = Color(nsColor: .separatorColor)

  static let accent = adaptive(light: 0x3A6C93, dark: 0x72A6CD)
  static let fileTile = adaptive(light: 0xDCE5EB, dark: 0x435661)
  static let folderTile = adaptive(light: 0xC7D9E5, dark: 0x365F79)
  static let warning = adaptive(light: 0x795000, dark: 0xE4B451)

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

    var lightHex: UInt32 { [0xE7F0F8, 0xC4DAF2, 0xB0B5EE, 0xB97FC6, 0xC34E54, 0x9A4312][rawValue] }
    var darkHex: UInt32 { [0x2F3F4F, 0x375479, 0x635EA5, 0xAC63B1, 0xF17871, 0xFEB354][rawValue] }
    var lightTextHex: UInt32 { rawValue < 4 ? 0 : 0xFFFFFF }
    var darkTextHex: UInt32 { rawValue < 3 ? 0xFFFFFF : 0 }
    var color: Color { LightenStyle.adaptive(light: lightHex, dark: darkHex) }
    var textColor: Color { LightenStyle.adaptive(light: lightTextHex, dark: darkTextHex) }
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

  private static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
          green: CGFloat((value >> 8) & 0xFF) / 255,
          blue: CGFloat(value & 0xFF) / 255,
          alpha: 1)
      })
  }
}
