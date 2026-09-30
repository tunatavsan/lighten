import Darwin
import Foundation
import Testing

@testable import LightenKit

private func inventoryRoot() throws -> String {
  guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw FileSystemFailure.invalidPath }
  defer { free(resolved) }
  let path = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

private func put(_ path: String, _ text: String = "fixture") throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private func makeApp(_ path: String, bundleID: String) throws {
  try put(path + "/Contents/MacOS/tool", "binary")
  try put(path + "/Contents/Resources/en.lproj/Main.strings", "strings")
  try put(
    path + "/Contents/Info.plist",
    """
    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\
    <key>CFBundleIdentifier</key><string>\(bundleID)</string></dict></plist>
    """)
}

private func plan(_ path: String, home: String) throws(PlanRejections) -> ActionPlan {
  let identity = try? DescriptorFileSystem.identity(at: path)
  return try PlanService(homeDirectory: home).makeSpacePlan(
    selections: [PlanService.Selection(path: path, device: identity?.device ?? 0, inode: identity?.inode ?? 0)],
    scanRootPath: home, runID: UUID())
}

private func rejection(_ path: String, home: String) -> PlanRejection? {
  do {
    _ = try plan(path, home: home)
    return nil
  } catch {
    return error.rejections.first
  }
}

@Test func folderWithSymlinksAndPackageBecomesSpaceTrashPlan() throws {
  let home = try inventoryRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let outside = home + "/elsewhere"
  try put(outside + "/big", String(repeating: "x", count: 4000))
  let folder = home + "/project"
  try put(folder + "/readme")
  try put(folder + "/Sample.bundle/Contents/Resources/r")
  #expect(symlink("readme", folder + "/link-in") == 0)
  #expect(symlink(outside, folder + "/link-out") == 0)
  let result = try plan(folder, home: home)
  let item = try #require(result.items.first)
  #expect(item.policy == .spaceTrash)
  #expect(item.id == item.inventory[0].id)
  let paths = Set(item.inventory.map(\.path))
  #expect(paths.contains(folder + "/link-out"))
  #expect(paths.contains(folder + "/Sample.bundle/Contents/Resources/r"))
  // The link is a leaf: nothing beneath its target is part of the plan.
  #expect(!paths.contains { $0.hasPrefix(folder + "/link-out/") })
  #expect(item.inventory.first { $0.path == folder + "/link-out" }?.identity?.kind == .symbolicLink)
  try ActionGuard(homeDirectory: home).validate(item)
}

@Test func guardComparesTheLinkItselfAndNeverItsTarget() throws {
  let home = try inventoryRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let outside = home + "/elsewhere"
  try put(outside + "/target")
  let folder = home + "/links"
  try put(folder + "/keep")
  #expect(symlink(outside, folder + "/to-outside") == 0)
  let item = try #require(try plan(folder, home: home).items.first)
  // Changing the target's contents does not touch the planned inventory.
  try put(outside + "/new-file")
  try ActionGuard(homeDirectory: home).validate(item)
  // Replacing the link itself is a changed item.
  #expect(unlink(folder + "/to-outside") == 0)
  #expect(symlink(home, folder + "/to-outside") == 0)
  #expect(throws: GuardFailure.changedItem) { try ActionGuard(homeDirectory: home).validate(item) }
}

@Test func guardStillChecksEveryDescendant() throws {
  let home = try inventoryRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let folder = home + "/tree"
  try put(folder + "/a/b/c/deep")
  let item = try #require(try plan(folder, home: home).items.first)
  try ActionGuard(homeDirectory: home).validate(item)
  try put(folder + "/a/b/c/added")
  // The new child changes the deepest folder; only a descendant check sees it.
  #expect(throws: GuardFailure.self) { try ActionGuard(homeDirectory: home).validate(item) }
  #expect(try DescriptorFileSystem.identity(at: folder) == item.inventory[0].identity)
}

@Test func protectedDescendantsAndAppsAreRefusedWithPath() throws {
  let home = try inventoryRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  try put(home + "/photos/Library.photoslibrary/database/db")
  let photos = rejection(home + "/photos", home: home)
  #expect(photos?.reason == .containsProtectedItem)
  #expect(photos?.path == home + "/photos/Library.photoslibrary")
  #expect(photos?.ruleID == "photos-library")

  try makeApp(home + "/downloads-copy/Tool.app", bundleID: "qa.lighten.tool")
  let app = rejection(home + "/downloads-copy", home: home)
  #expect(app?.reason == .containsApplication)
  #expect(app?.path == home + "/downloads-copy/Tool.app")
}

@Test func wholeAppIsOneBundleAndItsInteriorIsNeverSelectable() throws {
  let home = try inventoryRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let app = home + "/Apps/Tool.app"
  try makeApp(app, bundleID: "qa.lighten.tool")
  let item = try #require(try plan(app, home: home).items.first)
  #expect(item.policy == .wholeBundle)
  #expect(item.applicationBundleID == "qa.lighten.tool")
  try ActionGuard(homeDirectory: home).validate(item)
  #expect(rejection(app + "/Contents/MacOS/tool", home: home)?.reason == .insidePackage)
  #expect(rejection(app + "/Contents/Resources/en.lproj", home: home)?.reason == .insidePackage)
}

@Test func wholeBundleExceptionAppliesOnlyWhenThePackageIsTheRoot() throws {
  let home = try inventoryRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let app = home + "/Apps/Tool.app"
  try makeApp(app, bundleID: "qa.lighten.tool")
  let item = try #require(try plan(app, home: home).items.first)
  let asFolder = PlanItem(
    id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID, inventory: item.inventory,
    ancestors: item.ancestors, policy: .spaceTrash)
  #expect(throws: GuardFailure.protectedItem) { try ActionGuard(homeDirectory: home).validate(asFolder) }

  // The same app beneath a selected folder keeps its application rules.
  let parentPath = home + "/Apps"
  let parent = ScanEntry(
    parentID: nil, path: parentPath, identity: try DescriptorFileSystem.identity(at: parentPath), issues: [],
    readable: true)
  let appRoot = item.inventory[0]
  let reparented =
    [
      parent,
      ScanEntry(
        id: appRoot.id, parentID: parent.id, path: appRoot.path, identity: appRoot.identity, issues: [],
        readable: true),
    ] + item.inventory.dropFirst()
  let container = PlanItem(
    id: parent.id, sourcePath: parentPath, volumeID: item.volumeID, inventory: reparented,
    ancestors: try DescriptorFileSystem.ancestorIdentities(of: parentPath), policy: .spaceTrash)
  #expect(throws: GuardFailure.protectedItem) { try ActionGuard(homeDirectory: home).validate(container) }
  let containerClaim = PlanItem(
    id: parent.id, sourcePath: parentPath, volumeID: item.volumeID, inventory: reparented,
    ancestors: container.ancestors, policy: .wholeBundle)
  #expect(throws: GuardFailure.unsupportedItem) { try ActionGuard(homeDirectory: home).validate(containerClaim) }
  let strict = PlanItem(
    id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID, inventory: item.inventory,
    ancestors: item.ancestors)
  #expect(throws: GuardFailure.unsupportedItem) { try ActionGuard(homeDirectory: home).validate(strict) }

  // A plain folder cannot claim the whole-bundle policy.
  let folder = home + "/plain"
  try put(folder + "/file")
  let plain = try #require(try plan(folder, home: home).items.first)
  let forged = PlanItem(
    id: plain.id, sourcePath: plain.sourcePath, volumeID: plain.volumeID, inventory: plain.inventory,
    ancestors: plain.ancestors, policy: .wholeBundle)
  #expect(throws: GuardFailure.unsupportedItem) { try ActionGuard(homeDirectory: home).validate(forged) }
}

@Test func strictItemsStillRefuseLinksAndPackages() throws {
  let home = try inventoryRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let folder = home + "/legacy"
  try put(folder + "/file")
  #expect(symlink("file", folder + "/link") == 0)
  let item = try #require(try plan(folder, home: home).items.first)
  let strict = PlanItem(
    id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID, inventory: item.inventory,
    ancestors: item.ancestors)
  #expect(throws: GuardFailure.unsupportedItem) { try ActionGuard(homeDirectory: home).validate(strict) }
}

@Test func unreadableBulkAndSelfSelectionsExplainThemselves() throws {
  let home = try inventoryRoot()
  defer {
    chmod(home + "/work/closed", 0o755)
    try? FileManager.default.removeItem(atPath: home)
  }
  try put(home + "/work/closed/secret")
  #expect(chmod(home + "/work/closed", 0o000) == 0)
  let unreadable = rejection(home + "/work", home: home)
  #expect(unreadable?.reason == .unreadableFolder)
  #expect(unreadable?.path == home + "/work/closed")

  try put(home + "/Documents/file")
  #expect(rejection(home + "/Documents", home: home)?.reason == .bulkRoot)
  #expect(rejection(home, home: home)?.reason == .scanRoot)

  try makeApp(home + "/Copies/Lighten.app", bundleID: LightenIdentity.bundleIdentifier)
  #expect(rejection(home + "/Copies/Lighten.app", home: home)?.reason == .lightenItself)
}

@Test func nestedSelectionsCollapseToTheirAncestor() throws {
  let home = try inventoryRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  try put(home + "/outer/inner/file")
  func selection(_ path: String) throws -> PlanService.Selection {
    let identity = try DescriptorFileSystem.identity(at: path)
    return PlanService.Selection(path: path, device: identity.device, inode: identity.inode)
  }
  let result = try PlanService(homeDirectory: home).makeSpacePlan(
    selections: [try selection(home + "/outer/inner"), try selection(home + "/outer")],
    scanRootPath: home, runID: UUID())
  #expect(result.items.map(\.sourcePath) == [home + "/outer"])
}

@Test func legacyJournalItemsDecodeAsStrict() throws {
  let item = PlanItem(id: UUID(), sourcePath: "/tmp/x", inventory: [], ancestors: [])
  var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
  object.removeValue(forKey: "policy")
  object.removeValue(forKey: "applicationBundleID")
  let decoded = try JSONDecoder().decode(PlanItem.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(decoded.policy == nil)
  #expect(decoded.applicationBundleID == nil)
}

@Test func onlyApplicationsUseTheWholeBundlePolicy() throws {
  let home = try inventoryRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  try put(home + "/Frameworks/Kit.framework/Resources/en.lproj/Localizable.strings")
  let framework = rejection(home + "/Frameworks/Kit.framework", home: home)
  #expect(framework?.reason == .containsProtectedItem)
  #expect(framework?.ruleID == "localization-bundles")

  try put(home + "/Frameworks/Plain.bundle/Contents/Resources/data")
  let bundle = try #require(try plan(home + "/Frameworks/Plain.bundle", home: home).items.first)
  #expect(bundle.policy == .spaceTrash)
  try ActionGuard(homeDirectory: home).validate(bundle)

  try put(home + "/Docs/Report.pages", "single file document")
  let document = try #require(try plan(home + "/Docs/Report.pages", home: home).items.first)
  #expect(document.policy == .spaceTrash)
  try ActionGuard(homeDirectory: home).validate(document)
}

@Test func nestedApplicationsAreRecordedAndLightenIsNeverRemoved() throws {
  let home = try inventoryRoot()
  defer { try? FileManager.default.removeItem(atPath: home) }
  try makeApp(home + "/Apps/Suite.app", bundleID: "qa.lighten.suite")
  try makeApp(home + "/Apps/Suite.app/Contents/Helpers/Agent.app", bundleID: "qa.lighten.agent")
  let item = try #require(try plan(home + "/Apps/Suite.app", home: home).items.first)
  #expect(item.applicationBundleID == "qa.lighten.suite")
  #expect(item.nestedApplicationIDs == ["qa.lighten.agent"])
  try ActionGuard(homeDirectory: home).validate(item)

  try makeApp(home + "/Apps/Carrier.app", bundleID: "qa.lighten.carrier")
  try makeApp(home + "/Apps/Carrier.app/Contents/Helpers/Lighten.app", bundleID: LightenIdentity.bundleIdentifier)
  #expect(rejection(home + "/Apps/Carrier.app", home: home)?.reason == .lightenItself)
}
