import Testing

@testable import LightenKit

@Test("Duplicate discovery starts at one decimal MB and includes the threshold")
func duplicateScopeDefaultThreshold() {
  let scope = DuplicateScanScope(homeDirectory: "/fixture/home")
  #expect(scope.minimumBytes == 1_000_000)
  let path = "/fixture/home/Documents/copy.bin"
  #expect(!scope.includesFile(path: path, logicalBytes: scope.minimumBytes - 1, scanRoot: "/fixture/home/Documents"))
  #expect(scope.includesFile(path: path, logicalBytes: scope.minimumBytes, scanRoot: "/fixture/home/Documents"))
}

@Test("A lowered duplicate threshold still excludes empty files", arguments: [Int64.min, 0, 1, 512])
func duplicateScopeNeverIncludesEmptyFiles(threshold: Int64) {
  let scope = DuplicateScanScope(minimumBytes: threshold, homeDirectory: "/fixture/home")
  #expect(scope.minimumBytes > 0)
  #expect(!scope.includesFile(path: "/fixture/empty", logicalBytes: 0, scanRoot: "/fixture"))
  #expect(!scope.includesFile(path: "/fixture/invalid", logicalBytes: -1, scanRoot: "/fixture"))
  #expect(scope.includesFile(path: "/fixture/copy", logicalBytes: max(1, threshold), scanRoot: "/fixture"))
}

@Test(
  "Duplicate scope names the folders omitted from discovery",
  arguments: [
    ("/fixture/.hidden/file.bin", DuplicateScanScope.ExclusionReason.hiddenDirectory),
    ("/fixture/.git/objects/file.bin", .sourceControl),
    ("/fixture/.build/debug/file.bin", .buildOutput),
    ("/fixture/project/node_modules/dependency/file.bin", .dependencyDirectory),
    ("/fixture/DerivedData/product/file.bin", .derivedData),
    ("/fixture/Library/Caches/app/file.bin", .libraryCache),
    ("/fixture/Library/CACHES/app/file.bin", .libraryCache),
  ])
func duplicateScopeExcludedFolders(path: String, reason: DuplicateScanScope.ExclusionReason) {
  let scope = DuplicateScanScope(minimumBytes: 1, homeDirectory: "/fixture/home")
  #expect(scope.exclusionReason(for: path, isDirectory: false, scanRoot: "/fixture") == reason)
  #expect(!scope.includesFile(path: path, logicalBytes: 4096, scanRoot: "/fixture"))
  let directory = String(path.prefix(upTo: path.lastIndex(of: "/")!))
  #expect(scope.exclusionReason(for: directory, isDirectory: true, scanRoot: "/fixture") == reason)
}

@Test(
  "Package interiors are omitted even when the requested root is inside one",
  arguments: ["app", "APP", "photoslibrary", "rtfd", "pages", "framework"])
func duplicateScopePackageBoundaries(suffix: String) {
  let scope = DuplicateScanScope(minimumBytes: 1)
  let package = "/fixture/Collection." + suffix
  #expect(scope.exclusionReason(for: package, isDirectory: true, scanRoot: "/fixture") == .package)
  #expect(
    scope.exclusionReason(for: package + "/Contents", isDirectory: true, scanRoot: package + "/Contents") == .package)
  #expect(
    !scope.includesFile(path: package + "/Contents/file.bin", logicalBytes: 4096, scanRoot: package + "/Contents"))
}

@Test(
  "A duplicate root inside developer or cache folders cannot bypass the default scope",
  arguments: [".git", ".build", "node_modules", "DerivedData", "Library/Caches"])
func duplicateScopeExcludedInteriorRoots(directory: String) {
  let root = "/fixture/" + directory + "/nested"
  let scope = DuplicateScanScope(minimumBytes: 1)
  #expect(scope.exclusionReason(for: root, isDirectory: true, scanRoot: root) != nil)
  #expect(!scope.includesFile(path: root + "/file.bin", logicalBytes: 4096, scanRoot: root))
}

@Test("Home duplicate scans omit Library while an explicitly chosen Library folder can be scanned")
func duplicateScopeHomeLibraryBoundary() {
  let home = "/fixture/home"
  let scope = DuplicateScanScope(minimumBytes: 1, homeDirectory: home)
  #expect(scope.exclusionReason(for: home + "/Library", isDirectory: true, scanRoot: home) == .homeLibrary)
  #expect(!scope.includesFile(path: home + "/Library/Preferences/copy.plist", logicalBytes: 4096, scanRoot: home))
  #expect(scope.includesFile(path: home + "/Documents/copy.bin", logicalBytes: 4096, scanRoot: home))
  #expect(
    scope.includesFile(path: home + "/Library/Preferences/copy.plist", logicalBytes: 4096, scanRoot: home + "/Library"))
  #expect(!scope.includesFile(path: home + "/Library/Caches/copy.bin", logicalBytes: 4096, scanRoot: home + "/Library"))
}

@Test(
  "Ordinary files and similar folder names are not mistaken for excluded directories",
  arguments: [
    ".notes", ".git", "node_modules", "DerivedData", "notes.app", "Documents/Caches/copy.bin",
    "node_modules-backup/copy.bin", "LibraryCached/Caches/copy.bin",
  ])
func duplicateScopeKeepsOrdinaryFiles(relativePath: String) {
  let scope = DuplicateScanScope(minimumBytes: 1)
  #expect(scope.includesFile(path: "/fixture/" + relativePath, logicalBytes: 4096, scanRoot: "/fixture"))
}

@Test("Duplicate scope respects root component boundaries and rejects invalid paths")
func duplicateScopeRootValidation() {
  let scope = DuplicateScanScope(minimumBytes: 1)
  #expect(
    scope.exclusionReason(for: "/fixture-other/file", isDirectory: false, scanRoot: "/fixture") == .outsideScanRoot)
  for path in ["relative/file", "/fixture/../file", "/fixture/./file", "/fixture//file", "/fixture/\0file"] {
    #expect(scope.exclusionReason(for: path, isDirectory: false, scanRoot: "/fixture") == .invalidPath)
  }
  #expect(scope.includesFile(path: "/fixture/file", logicalBytes: 4096, scanRoot: "/fixture/"))
  #expect(scope.includesFile(path: "/fixture/file", logicalBytes: 4096, scanRoot: "/"))
  #expect(scope.exclusionReason(for: "/", isDirectory: true, scanRoot: "/") == nil)
}
