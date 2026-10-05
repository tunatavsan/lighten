import Foundation

enum AppListScope: Equatable, Sendable {
  case installed, other, excluded

  static func location(of path: String, homeDirectory: String) -> Self {
    let components = (path as NSString).pathComponents
    let parents = components.dropLast()
    let buildFolders: Set<String> = [".build", "deriveddata", "build", "dist", "target"]
    if path.hasPrefix(homeDirectory + "/Library/Daemon Containers/") && parents.contains("Placeholders-v6.noindex")
      || path == "/System" || path.hasPrefix("/System/")
      || path.hasPrefix(homeDirectory + "/dev/")
      || parents.contains(where: { $0.lowercased().hasSuffix(".app") })
      || parents.contains(where: { $0.hasPrefix(".") || buildFolders.contains($0.lowercased()) })
    {
      return .excluded
    }
    if path.hasPrefix("/Applications/") || path.hasPrefix(homeDirectory + "/Applications/") {
      return .installed
    }
    return .other
  }
}
