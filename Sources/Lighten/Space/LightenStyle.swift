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

  private static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(
          calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
          green: CGFloat((value >> 8) & 0xFF) / 255,
          blue: CGFloat(value & 0xFF) / 255,
          alpha: 1)
      })
  }
}
