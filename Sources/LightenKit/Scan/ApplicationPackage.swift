import Foundation

/// An application suffix identifies a package only when the no-follow metadata
/// also shows a directory and a regular Contents/Info.plist. Cache directories
/// named after a bundle identifier ending in ".app" remain ordinary directories.
enum ApplicationPackage {
  static func isApplication(_ path: String) -> Bool {
    guard path.lowercased(with: Locale(identifier: "en_US_POSIX")).hasSuffix(".app"),
      let root = try? DescriptorFileSystem.identity(at: path), root.kind == .directory,
      let contents = try? DescriptorFileSystem.identity(at: path + "/Contents"), contents.kind == .directory,
      let info = try? DescriptorFileSystem.identity(at: path + "/Contents/Info.plist"), info.kind == .regular
    else { return false }
    return true
  }
}
