import Foundation
import Testing

@testable import Lighten

@Test("Real applications under development folders remain visible in other locations")
@MainActor func applicationDevelopmentFoldersAreNotMachineSpecificExclusions() {
  for home in ["/Users/fixture", "/fixture/home"] {
    let path = home + "/dev/products/Example.app"
    #expect(AppListScope.location(of: path, homeDirectory: home) == .other)
    #expect(AppListScope.exclusionReason(of: path, homeDirectory: home) == nil)
    #expect(AppListScope.otherLocationReason(of: path, homeDirectory: home) == .outsideApplicationsFolders)
  }
}

@Test("Application backup copies in hidden parent folders are visible with a reason")
@MainActor func hiddenApplicationCopiesAreOtherLocations() {
  let home = "/fixture/home"
  let paths = [
    "/Applications/.example-install.123/previous-Example.app",
    home + "/Applications/.backups/Example.app",
    home + "/.archives/Example.app",
  ]
  for path in paths {
    #expect(AppListScope.location(of: path, homeDirectory: home) == .other)
    #expect(AppListScope.exclusionReason(of: path, homeDirectory: home) == nil)
    #expect(AppListScope.otherLocationReason(of: path, homeDirectory: home) == .hiddenFolder)
  }
}

@Test("System, helper, build, Trash and iOS placeholder packages keep named exclusions")
@MainActor func applicationScopeKeepsGeneralExclusions() {
  let home = "/fixture/home"
  let examples: [(String, AppListScope.ExclusionReason)] = [
    ("/System/Applications/Example.app", .system),
    ("/Applications/Host.app/Contents/Helpers/Helper.app", .nestedApplication),
    (home + "/dev/product/.build/release/Example.app", .buildArtifact),
    (home + "/Library/Developer/Xcode/DerivedData/product/Build/Example.app", .buildArtifact),
    (home + "/src/dist/Example.app", .buildArtifact),
    (home + "/src/target/Example.app", .buildArtifact),
    (home + "/src/.swiftpm/Example.app", .buildArtifact),
    (home + "/.Trash/Example.app", .trash),
    ("/Volumes/Fixture/.Trashes/501/Example.app", .trash),
    (home + "/Library/Daemon Containers/uuid/Placeholders-v6.noindex/Example.app", .iosPlaceholder),
  ]
  for (path, reason) in examples {
    #expect(AppListScope.location(of: path, homeDirectory: home) == .excluded)
    #expect(AppListScope.exclusionReason(of: path, homeDirectory: home) == reason)
    #expect(AppListScope.otherLocationReason(of: path, homeDirectory: home) == nil)
  }
}

@Test("Omitted application counts use distinct actual paths without inflating installed applications")
@MainActor func applicationOmissionCountsAreActualDistinctPaths() {
  let home = "/fixture/home"
  let installed = ["/Applications/Example.app", home + "/Applications/Second.app"]
  let hidden = "/Applications/.backups/Example.app"
  let helper = "/Applications/Host.app/Contents/Helpers/Helper.app"
  let system = "/System/Applications/System.app"
  let build = home + "/dev/product/build/Example.app"
  let all = installed + [hidden, helper, system, build, system]
  #expect(
    AppListScope.omittedCounts(paths: all, homeDirectory: home) == [
      .system: 1, .nestedApplication: 1, .buildArtifact: 1,
    ])
  #expect(all.filter { AppListScope.location(of: $0, homeDirectory: home) == .installed } == installed)
  #expect(AppListScope.location(of: hidden, homeDirectory: home) == .other)
}
