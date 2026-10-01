import Foundation
import Synchronization

public enum ProtectionPolicy {
  struct Matcher: Sendable {
    let homeDirectory: String
    private let exact: [(NeverRule, PathPattern)]
    private let aliases: [(NeverRule, PathPattern)]

    init(homeDirectory: String) {
      self.homeDirectory = homeDirectory
      let foldedHome = ProtectionPolicy.folded(homeDirectory)
      self.exact = NeverRule.all.map { ($0, PathPattern($0.pattern, homeDirectory: homeDirectory)) }
      self.aliases = NeverRule.all.map {
        ($0, PathPattern(ProtectionPolicy.folded($0.pattern), homeDirectory: foldedHome))
      }
    }

    private init(homeDirectory: String, exact: [(NeverRule, PathPattern)], aliases: [(NeverRule, PathPattern)]) {
      self.homeDirectory = homeDirectory
      self.exact = exact
      self.aliases = aliases
    }

    func selecting(_ ids: Set<String>) -> Matcher {
      Matcher(
        homeDirectory: homeDirectory,
        exact: exact.filter { ids.contains($0.0.id) }, aliases: aliases.filter { ids.contains($0.0.id) })
    }

    func rule(for path: String) -> NeverRule? {
      if let target = PathPattern.components(path),
        let found = exact.first(where: { $0.1.matches(components: target) })
      {
        return found.0
      }
      guard let target = PathPattern.components(ProtectionPolicy.folded(path)) else { return nil }
      return aliases.first { $0.1.matches(components: target) }?.0
    }

    func rules(for path: String) -> [NeverRule] {
      guard let target = PathPattern.components(ProtectionPolicy.folded(path)) else { return [] }
      return aliases.compactMap { $0.1.matches(components: target) ? $0.0 : nil }
    }
  }

  // Only immutable pattern/home compilations are retained. Paths, matches and
  // filesystem observations are evaluated afresh and never stored here.
  private static let matchers = Mutex<[Matcher]>([])
  private static let locale = Locale(identifier: "en_US_POSIX")

  static func matcher(homeDirectory: String) -> Matcher {
    if let found = matchers.withLock({ $0.first { $0.homeDirectory == homeDirectory } }) { return found }
    let compiled = Matcher(homeDirectory: homeDirectory)
    guard homeDirectory.utf8.count <= 4096, (PathPattern.components(homeDirectory)?.count ?? 0) <= 128 else {
      return compiled
    }
    return matchers.withLock { entries in
      if let found = entries.first(where: { $0.homeDirectory == homeDirectory }) { return found }
      if entries.count == 16 { entries.removeFirst() }
      entries.append(compiled)
      return compiled
    }
  }

  /// Case aliases on a case-insensitive volume must not weaken NeverRule.
  /// The exact spelling remains in ScanEntry for display and journal history.
  public static func rule(for path: String, homeDirectory: String) -> NeverRule? {
    matcher(homeDirectory: homeDirectory).rule(for: path)
  }

  static func rules(for path: String, homeDirectory: String) -> [NeverRule] {
    matcher(homeDirectory: homeDirectory).rules(for: path)
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
    path.lowercased(with: locale)
  }

}
