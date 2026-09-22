import Foundation

public enum ProtectionPolicy {
  /// Case aliases on a case-insensitive volume must not weaken NeverRule.
  /// The exact spelling remains in ScanEntry for display and journal history.
  public static func rule(for path: String, homeDirectory: String) -> NeverRule? {
    if let rule = NeverRule.protects(path, homeDirectory: homeDirectory) { return rule }
    let locale = Locale(identifier: "en_US_POSIX")
    let foldedPath = path.lowercased(with: locale)
    let foldedHome = homeDirectory.lowercased(with: locale)
    return NeverRule.all.first {
      PathPattern($0.pattern.lowercased(with: locale), homeDirectory: foldedHome)
        .matches(foldedPath)
    }
  }
}
