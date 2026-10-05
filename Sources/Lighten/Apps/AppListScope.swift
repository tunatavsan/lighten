import Foundation

enum AppListScope: Equatable, Sendable {
  case installed, other, excluded

  enum ExclusionReason: String, CaseIterable, Sendable {
    case system, nestedApplication, buildArtifact, trash, iosPlaceholder
  }

  enum OtherReason: Equatable, Sendable {
    case hiddenFolder, outsideApplicationsFolders
  }

  static func location(of path: String, homeDirectory: String) -> Self {
    guard exclusionReason(of: path, homeDirectory: homeDirectory) == nil else { return .excluded }
    let parents = (path as NSString).pathComponents.dropLast()
    // Hidden parent folders can contain real backup copies of installed applications.
    if parents.contains(where: { $0.hasPrefix(".") }) { return .other }
    if path.hasPrefix("/Applications/") || path.hasPrefix(homeDirectory + "/Applications/") {
      return .installed
    }
    return .other
  }

  static func exclusionReason(of path: String, homeDirectory: String) -> ExclusionReason? {
    let parents = (path as NSString).pathComponents.dropLast()
    if path == "/System" || path.hasPrefix("/System/") { return .system }
    if parents.contains(where: { [".trash", ".trashes"].contains($0.lowercased()) }) { return .trash }
    if path.hasPrefix(homeDirectory + "/Library/Daemon Containers/")
      && parents.contains("Placeholders-v6.noindex")
    {
      return .iosPlaceholder
    }
    if parents.contains(where: { $0.lowercased().hasSuffix(".app") }) { return .nestedApplication }
    let buildFolders: Set<String> = [
      ".build", ".swiftpm", ".git", "deriveddata", "build", "dist", "target", "node_modules",
    ]
    if parents.contains(where: { buildFolders.contains($0.lowercased()) }) { return .buildArtifact }
    return nil
  }

  static func otherLocationReason(of path: String, homeDirectory: String) -> OtherReason? {
    guard location(of: path, homeDirectory: homeDirectory) == .other else { return nil }
    return (path as NSString).pathComponents.dropLast().contains { $0.hasPrefix(".") }
      ? .hiddenFolder : .outsideApplicationsFolders
  }

  static func omittedCounts(paths: [String], homeDirectory: String) -> [ExclusionReason: Int] {
    Set(paths).reduce(into: [:]) { counts, path in
      if let reason = exclusionReason(of: path, homeDirectory: homeDirectory) {
        counts[reason, default: 0] += 1
      }
    }
  }
}
