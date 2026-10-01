import Foundation

/// A reminder based only on exact inventory metadata. It never changes a plan,
/// reads file contents, or establishes that a file is the sole remaining copy.
public enum ProtectiveWarning: String, Sendable, Equatable {
  case valuableData, secrets, copyUnknown

  public static func evaluate(
    _ item: PlanItem, homeDirectory: String = NSHomeDirectory(), knownOtherCopy: Bool = false
  ) -> Self? {
    guard !knownOtherCopy, item.duplicateProof == nil else { return nil }
    let components = item.sourcePath.split(separator: "/").map { $0.lowercased() }
    let rebuildable: Set<String> = ["caches", "logs", "node_modules", "deriveddata"]
    guard !components.contains(where: rebuildable.contains) else { return nil }
    let rootExtension = URL(fileURLWithPath: item.sourcePath).pathExtension.lowercased()
    guard !["dmg", "pkg", "mpkg"].contains(rootExtension) else { return nil }
    let explicit = NeverRule.all.filter { $0.scope == .explicitTrashOnly }
    if item.inventory.contains(where: { entry in
      explicit.contains { PathPattern($0.pattern, homeDirectory: homeDirectory).matches(entry.path) }
    }) {
      return .valuableData
    }
    let files = item.inventory.filter { $0.identity?.kind == .regular }
    if files.contains(where: { entry in
      let url = URL(fileURLWithPath: entry.path)
      return Self.isSecretName(url)
    }) {
      return .secrets
    }
    let personalExtensions = Self.personalExtensions
    let personal = files.filter {
      personalExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
    }
    return !files.isEmpty && personal.count * 2 > files.count ? .copyUnknown : nil
  }

  private static let personalExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "raw", "dng", "tiff", "gif", "webp", "mov", "mp4", "m4v", "avi",
    "mp3", "wav", "aiff", "m4a", "flac", "pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers",
    "ppt", "pptx", "key", "txt", "md", "rtf", "swift", "m", "h", "c", "cpp", "rs", "go", "py",
    "js", "jsx", "ts", "tsx", "java", "kt", "rb", "php", "html", "css", "sql", "sh",
  ]

  private static func isSecretName(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    return ["pem", "p12", "kdbx", "gpg", "key"].contains(url.pathExtension.lowercased()) || name == "id_rsa"
      || name == ".env" || name.hasPrefix(".env.")
  }

  /// Actual inventory paths that triggered this warning, never invented examples.
  public func examplePaths(_ item: PlanItem, homeDirectory: String = NSHomeDirectory()) -> [String] {
    let matches = item.inventory.filter { entry in
      switch self {
      case .valuableData:
        return NeverRule.all.filter { $0.scope == .explicitTrashOnly }.contains {
          PathPattern($0.pattern, homeDirectory: homeDirectory).matches(entry.path)
        }
      case .secrets:
        return entry.identity?.kind == .regular && Self.isSecretName(URL(fileURLWithPath: entry.path))
      case .copyUnknown:
        return entry.identity?.kind == .regular
          && Self.personalExtensions.contains(URL(fileURLWithPath: entry.path).pathExtension.lowercased())
      }
    }
    return Array(Set(matches.map(\.path)).sorted().prefix(3))
  }
}
