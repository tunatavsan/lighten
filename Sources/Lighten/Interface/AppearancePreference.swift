import AppKit
import SwiftUI

/// Light, dark, or whatever macOS uses. `-LightenAppearance dark` on the command line overrides it
/// through the defaults argument domain.
enum AppearancePreference: String, CaseIterable, Identifiable {
  case system, light, dark

  static let key = "LightenAppearance"

  var id: Self { self }

  var title: String {
    switch self {
    case .system: String(localized: "System")
    case .light: String(localized: "Light")
    case .dark: String(localized: "Dark")
    }
  }

  var appearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

private struct AppliesAppearancePreference: ViewModifier {
  @AppStorage(AppearancePreference.key) private var preference = AppearancePreference.system

  func body(content: Content) -> some View {
    content.onChange(of: preference, initial: true) { _, value in NSApp.appearance = value.appearance }
  }
}

extension View {
  /// Applies the stored appearance to the whole app.
  func appliesAppearancePreference() -> some View { modifier(AppliesAppearancePreference()) }
}
