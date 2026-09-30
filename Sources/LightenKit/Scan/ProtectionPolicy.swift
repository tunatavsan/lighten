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

  static func rules(for path: String, homeDirectory: String) -> [NeverRule] {
    let locale = Locale(identifier: "en_US_POSIX")
    return NeverRule.all.filter {
      PathPattern($0.pattern.lowercased(with: locale), homeDirectory: homeDirectory.lowercased(with: locale))
        .matches(path.lowercased(with: locale))
    }
  }

  /// A whole device backup is the only selectable MobileSync operation root.
  static func isWholeDeviceBackup(_ path: String, homeDirectory: String) -> Bool {
    let parts = folded(path).split(separator: "/").map(String.init)
    let base = folded(homeDirectory + "/Library/Application Support/MobileSync/Backup")
      .split(separator: "/").map(String.init)
    return parts.count == base.count + 1 && Array(parts.prefix(base.count)) == base
      && parts.last != "." && parts.last != ".."
  }

  /// Scope is granted only to an explicit Space Trash root, never to a generic caller.
  static func spaceTrashPermits(
    _ rules: [NeverRule], path: String, rootPath: String, homeDirectory: String, ancestor: Bool = false
  ) -> Bool {
    let descendant = path != rootPath && path.hasPrefix(rootPath + "/")
    let orbstack = Self.rules(for: rootPath, homeDirectory: homeDirectory)
      .contains { $0.id == "orbstack-disk-image" }
    return rules.allSatisfy { rule in
      if rule.scope == .explicitTrashOnly {
        if rule.id == "mobile-sync" {
          return isWholeDeviceBackup(rootPath, homeDirectory: homeDirectory)
            && (ancestor || path == rootPath || descendant)
        }
        return true
      }
      if ExactInventory.applicationRules.contains(rule.id) { return descendant }
      // The specific OrbStack image rule overlaps the broader shared-data rule.
      return rule.id == "group-containers" && orbstack && (ancestor || path == rootPath || descendant)
    }
  }

  /// Scanning can measure explicit selections without granting removal authority.
  static func scanRule(for path: String, homeDirectory: String) -> NeverRule? {
    rules(for: path, homeDirectory: homeDirectory).first { rule in
      guard rule.scope == .never else { return false }
      guard rule.id == "group-containers" else { return true }
      let groupRoot = folded(homeDirectory + "/Library/Group Containers")
      let current = folded(path)
      if current == groupRoot { return false }
      let suffix = current.dropFirst(groupRoot.count + 1).split(separator: "/")
      if let domain = suffix.first, domain.hasSuffix(".orbstack") {
        return suffix.count > 1 && suffix[1] != "data.img"
      }
      return true
    }
  }

  private static func folded(_ path: String) -> String {
    path.lowercased(with: Locale(identifier: "en_US_POSIX"))
  }

}
