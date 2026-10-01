import Foundation

/// An application suffix identifies a package only when the no-follow metadata
/// also shows a recognizable directory layout and a regular Info.plist. Cache directories
/// named after a bundle identifier ending in ".app" remain ordinary directories.
enum ApplicationPackage {
  static func isApplication(_ path: String) -> Bool {
    ApplicationPackagePlanning.recognizesPackageLayout(at: path)
  }
}
