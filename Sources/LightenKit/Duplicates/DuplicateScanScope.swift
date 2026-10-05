import Foundation

/// Discovery scope only. Inclusion never authorizes a file operation.
public struct DuplicateScanScope: Sendable, Equatable {
  public static let defaultMinimumBytes: Int64 = 1_000_000

  public enum ExclusionReason: String, Sendable, Equatable {
    case invalidPath, outsideScanRoot, hiddenDirectory, sourceControl, buildOutput
    case dependencyDirectory, derivedData, libraryCache, package, homeLibrary
  }

  public let minimumBytes: Int64
  public let homeDirectory: String

  public init(
    minimumBytes: Int64 = DuplicateScanScope.defaultMinimumBytes,
    homeDirectory: String = NSHomeDirectory()
  ) {
    self.minimumBytes = max(1, minimumBytes)
    self.homeDirectory = homeDirectory
  }

  public func includesFile(path: String, logicalBytes: Int64, scanRoot: String) -> Bool {
    logicalBytes > 0 && logicalBytes >= minimumBytes
      && exclusionReason(for: path, isDirectory: false, scanRoot: scanRoot) == nil
  }

  /// Library itself is only a corridor to local iCloud Drive files during a Home scan.
  public func traversesDirectory(path: String, scanRoot: String) -> Bool {
    if Self.components(scanRoot) == Self.components(homeDirectory),
      Self.components(path) == Self.components(homeDirectory + "/Library")
    {
      return true
    }
    return exclusionReason(for: path, isDirectory: true, scanRoot: scanRoot) == nil
  }

  public func isLocalICloudPath(_ path: String) -> Bool {
    guard let components = Self.components(path),
      let cloud = Self.components(homeDirectory + "/Library/Mobile Documents")
    else { return false }
    return components.starts(with: cloud)
  }

  public func exclusionReason(for path: String, isDirectory: Bool, scanRoot: String) -> ExclusionReason? {
    guard let components = Self.components(path), let root = Self.components(scanRoot) else {
      return .invalidPath
    }
    guard components.starts(with: root) else { return .outsideScanRoot }
    let directories = isDirectory ? components : Array(components.dropLast())
    if let home = Self.components(homeDirectory), root == home, directories.count > root.count,
      directories[root.count].lowercased() == "library", !isLocalICloudPath(path)
    {
      return .homeLibrary
    }
    let firstScopedDirectory = max(0, root.count - 1)
    for (index, name) in directories.enumerated() {
      let folded = name.lowercased()
      switch folded {
      case ".git": return .sourceControl
      case ".build": return .buildOutput
      case "node_modules": return .dependencyDirectory
      case "deriveddata": return .derivedData
      default: break
      }
      if folded == "caches", index > 0, directories[index - 1].lowercased() == "library" {
        return .libraryCache
      }
      if PackageNames.isPackage(name) { return .package }
      if index >= firstScopedDirectory, name.hasPrefix(".") { return .hiddenDirectory }
    }
    if PackageNames.containsPackage(in: path, isDirectory: isDirectory) { return .package }
    return nil
  }

  private static func components(_ path: String) -> [String]? {
    var trimmed = path
    while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
    if trimmed == "/" { return [] }
    return try? DescriptorFileSystem.validatedComponents(trimmed)
  }
}
