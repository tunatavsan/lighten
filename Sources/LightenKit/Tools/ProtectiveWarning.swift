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
    let secretExtensions: Set<String> = ["pem", "p12", "kdbx", "gpg"]
    if files.contains(where: { entry in
      let url = URL(fileURLWithPath: entry.path)
      let name = url.lastPathComponent.lowercased()
      return secretExtensions.contains(url.pathExtension.lowercased()) || name == "id_rsa"
        || name == ".env" || name.hasPrefix(".env.")
    }) {
      return .secrets
    }
    let personalExtensions: Set<String> = [
      "jpg", "jpeg", "png", "heic", "raw", "dng", "tiff", "gif", "webp", "mov", "mp4", "m4v", "avi",
      "mp3", "wav", "aiff", "m4a", "flac", "pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers",
      "ppt", "pptx", "key", "txt", "md", "rtf", "swift", "m", "h", "c", "cpp", "rs", "go", "py",
      "js", "jsx", "ts", "tsx", "java", "kt", "rb", "php", "html", "css", "sql", "sh",
    ]
    let personal = files.filter {
      personalExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
    }
    return !files.isEmpty && personal.count * 2 > files.count ? .copyUnknown : nil
  }
}
