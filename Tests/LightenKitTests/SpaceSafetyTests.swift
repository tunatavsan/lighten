import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private func spaceFixture() throws -> String {
  let resolved = try #require(realpath("/tmp", nil))
  defer { free(resolved) }
  let root = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  return root
}

private func spacePut(_ path: String, bytes: Int = 12) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try Data(repeating: 0x42, count: bytes).write(to: URL(fileURLWithPath: path))
}

private func spaceApp(_ path: String, id: String) throws {
  try spacePut(path + "/Contents/MacOS/tool")
  try spacePut(path + "/Contents/Resources/Base.lproj/Main.strings")
  let metadata = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
  try metadata.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
}

private func spaceSelection(_ path: String) throws -> PlanService.Selection {
  let identity = try DescriptorFileSystem.identity(at: path)
  return PlanService.Selection(path: path, device: identity.device, inode: identity.inode)
}

private struct SpaceClosedApps: RunningApplicationSource {
  var running: Set<String> = []
  func isRunning(bundleID: String) async -> Bool? { running.contains(bundleID) }
}

private final class SpaceObservedActivity: SpaceActivitySource {
  let observation = Mutex(ProcessActivity(state: .clearObservedCurrentUID))
  func activity(rootPath: String) async -> ProcessActivity { observation.withLock { $0 } }
  func set(_ state: ProcessActivityState) {
    observation.withLock { $0 = ProcessActivity(state: state, processNames: ["LightenQA writer"]) }
  }
}

private final class SpaceObservedMounts: MountedImageSource {
  let observation = Mutex(MountedImageState.detached)
  func state(imagePath: String) async -> MountedImageState { observation.withLock { $0 } }
  func set(_ state: MountedImageState) { observation.withLock { $0 = state } }
}

private struct SpaceRenameTrash: TrashMoving {
  let destination: String
  func moveToTrash(path: String) async throws -> String {
    let result = destination + "/" + (path as NSString).lastPathComponent
    try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: path, toPath: result)
    return result
  }
}

private func spacePlan(_ path: String, home: String) throws -> ActionPlan {
  try PlanService(homeDirectory: home).makeSpacePlan(
    selections: [try spaceSelection(path)], scanRootPath: home, runID: UUID())
}

@Suite("Space safety")
struct SpaceSafetyTests {
  @Test("Rule scopes keep generic cleanup protected")
  func ruleScopes() {
    let ids: Set<String> = [
      "xcode-archives", "xcode-debug-symbols", "maven-repository", "parallels-images", "utm-images",
      "vmware-images", "docker-disk-image", "orbstack-disk-image", "sparse-bundles", "sparse-images", "mobile-sync",
    ]
    #expect(Set(NeverRule.all.filter { $0.scope == .explicitTrashOnly }.map(\.id)) == ids)
    #expect(NeverRule(id: "example", pattern: "~/**", reason: "fixture").scope == .never)
    let home = "/Users/LightenQA-" + UUID().uuidString
    for (suffix, id) in [
      ("Library/Developer/Xcode/Archives/Fixture.xcarchive", "xcode-archives"),
      ("Library/Application Support/MobileSync/Backup/device", "mobile-sync"),
      ("Library/Mail/message", "mail"), (".ssh/id_rsa", "ssh"),
    ] {
      #expect(ProtectionPolicy.rule(for: home + "/" + suffix, homeDirectory: home)?.id == id)
    }
  }

  @Test("Only a whole device backup can be explicitly selected")
  func wholeBackupBoundary() throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let backup = home + "/Library/Application Support/MobileSync/Backup/LightenQA-" + UUID().uuidString
    try spacePut(backup + "/data/chunk")
    let plan = try spacePlan(backup, home: home)
    try ActionGuard(homeDirectory: home).validate(try #require(plan.items.first))
    for path in [backup + "/data", backup + "/data/chunk", (backup as NSString).deletingLastPathComponent] {
      #expect(throws: PlanRejections.self) { try spacePlan(path, home: home) }
    }
    let strict = PlanItem(
      id: plan.items[0].id, sourcePath: backup, volumeID: plan.items[0].volumeID,
      inventory: plan.items[0].inventory, ancestors: plan.items[0].ancestors)
    #expect(throws: GuardFailure.self) { try ActionGuard(homeDirectory: home).validate(strict) }
  }

  @Test(
    "Explicit Trash-only roots retain complete exact inventories",
    arguments: [
      "Library/Developer/Xcode/Archives/LightenQA-fixture.xcarchive",
      "build/LightenQA-fixture.dSYM", ".m2/repository/LightenQA-fixture",
      "VMs/LightenQA-fixture.utm", "VMs/LightenQA-fixture.pvm", "VMs/LightenQA-fixture.vmwarevm",
      "Images/LightenQA-fixture.sparsebundle",
      "Library/Containers/com.docker.docker/Data/vms/LightenQA-fixture/Docker.raw",
      "Library/Group Containers/qa.lighten.fixture.orbstack/data.img",
    ])
  func explicitInventory(_ relative: String) throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/" + relative
    let file = relative.hasSuffix(".raw") || relative.hasSuffix(".img")
    try spacePut(file ? path : path + "/contents/payload")
    let item = try #require(try spacePlan(path, home: home).items.first)
    try ActionGuard(homeDirectory: home).validate(item)
    #expect(ProtectionPolicy.rule(for: path, homeDirectory: home) != nil)
    #expect(item.inventory.contains { $0.path == (file ? path : path + "/contents/payload") })
  }

  @Test("Permanent and strict plans never gain Space permissions")
  func permanentIsStrict() async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/build/LightenQA-fixture.dSYM"
    try spacePut(path + "/Contents/Resources/DWARF/symbols")
    let plan = try spacePlan(path, home: home)
    let item = plan.items[0]
    #expect(throws: GuardFailure.self) {
      try ActionGuard(homeDirectory: home).validate(
        PlanItem(
          id: item.id, sourcePath: path, volumeID: item.volumeID, inventory: item.inventory, ancestors: item.ancestors))
    }
    let permanent = ActionPlan(id: plan.id, snapshotRunID: plan.snapshotRunID, kind: .catalogDelete, items: plan.items)
    let executor = ActionExecutor(
      journal: JSONLActionJournal(path: home + "/actions.jsonl"), trash: SpaceRenameTrash(destination: home + "/trash"),
      guardService: ActionGuard(homeDirectory: home))
    await #expect(throws: ExecutionFailure.invalidPlan) { try await executor.execute(permanent) }
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test("One refusal leaves nine independently available selections")
  func mixedBasket() async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    var paths: [String] = []
    for number in 0..<9 {
      let path = home + "/selection-\(number)"
      try spacePut(path)
      paths.append(path)
    }
    let protected = home + "/Photos/LightenQA-fixture.photoslibrary"
    try spacePut(protected + "/database")
    paths.append(protected)
    let outcome = await PlanService(homeDirectory: home).makeAvailableSpacePlan(
      selections: try paths.map(spaceSelection), scanRootPath: home, runID: UUID())
    let plan = try #require(outcome.plan)
    #expect(plan.items.count == 9)
    #expect(outcome.rejections.count == 1)
    #expect(outcome.rejections[0].path == protected)
    let executor = ActionExecutor(
      journal: JSONLActionJournal(path: home + "/actions.jsonl"), trash: SpaceRenameTrash(destination: home + "/trash"),
      guardService: ActionGuard(homeDirectory: home))
    #expect(try await executor.execute(plan).items.filter { $0.outcome == .applied }.count == 9)
    await #expect(throws: ExecutionFailure.planAlreadyUsed) { try await executor.execute(plan) }
    #expect(FileManager.default.fileExists(atPath: protected))
  }

  @Test("Nested applications are checked independently during planning")
  func nestedAppPlanning() async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try spaceApp(home + "/old-installs/LightenQA-tool.app", id: "qa.lighten.tool")
    try spacePut(home + "/ordinary")
    let planner = PlanService(homeDirectory: home, runningApplications: SpaceClosedApps(running: ["qa.lighten.tool"]))
    let result = await planner.makeAvailableSpacePlan(
      selections: [try spaceSelection(home + "/old-installs"), try spaceSelection(home + "/ordinary")],
      scanRootPath: home, runID: UUID())
    #expect(result.plan?.items.map(\.sourcePath) == [home + "/ordinary"])
    #expect(result.rejections.first?.reason == .applicationRunning)
    #expect(result.rejections.first?.path == home + "/old-installs")
    #expect(throws: PlanRejections.self) {
      try spacePlan(home + "/old-installs/LightenQA-tool.app/Contents/MacOS/tool", home: home)
    }
  }

  @Test("A folder with intact apps, resources, socket and FIFO moves and restores")
  func intactTreeMovesAndRestores() async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/old-installs"
    try spaceApp(path + "/LightenQA-tool.app", id: "qa.lighten.tool")
    try spacePut(path + "/Resources/Base.lproj/Main.strings")
    #expect(mkfifo(path + "/pipe", 0o600) == 0)
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(socketFD >= 0)
    defer { if socketFD >= 0 { close(socketFD) } }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array((path + "/socket").utf8) + [0]
    try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    #expect(bound == 0)
    let plan = try spacePlan(path, home: home)
    #expect(plan.items[0].nestedApplicationIDs == ["qa.lighten.tool"])
    #expect(throws: PlanRejections.self) { try spacePlan(path + "/pipe", home: home) }
    let journal = JSONLActionJournal(path: home + "/actions.jsonl")
    let result = try await ActionExecutor(
      journal: journal, trash: SpaceRenameTrash(destination: home + "/trash"),
      guardService: ActionGuard(homeDirectory: home),
      runningApplications: SpaceClosedApps()
    ).execute(plan)
    #expect(result.items.first?.outcome == .applied)
    let history = ActionHistory(journal: journal, homeDirectory: home)
    #expect(try await history.undo(planID: plan.id).restoredCount == 1)
    #expect(FileManager.default.fileExists(atPath: path + "/pipe"))
    #expect(FileManager.default.fileExists(atPath: path + "/LightenQA-tool.app/Contents/MacOS/tool"))
  }

  @Test("Confirmation-time additions are refreshed, reported, and journaled")
  func changedTreeRefreshes() async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/live-cache"
    try spacePut(path + "/old", bytes: 16)
    let plan = try spacePlan(path, home: home)
    try spacePut(path + "/new", bytes: 1234)
    let journal = JSONLActionJournal(path: home + "/actions.jsonl")
    let result = try await ActionExecutor(
      journal: journal, trash: SpaceRenameTrash(destination: home + "/trash"),
      guardService: ActionGuard(homeDirectory: home)
    )
    .execute(plan)
    #expect(result.items.first?.outcome == .applied)
    #expect(result.items.first?.addedFileCount == 1)
    #expect(result.items.first?.logicalByteDelta == 1234)
    let recorded = try await journal.loadPlan(id: plan.id)
    #expect(recorded.items[0].id == plan.items[0].id)
    #expect(recorded.items[0].inventory.contains { $0.path == path + "/new" })
    #expect(try await ActionHistory(journal: journal, homeDirectory: home).undo(planID: plan.id).restoredCount == 1)
    #expect(FileManager.default.fileExists(atPath: path + "/new"))
  }

  @Test("Fresh collection refuses new protected and running-app descendants", arguments: ["photos", "running-app"])
  func unsafeNewDescendant(_ variant: String) async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/cache"
    try spacePut(path + "/old")
    let plan = try spacePlan(path, home: home)
    if variant == "photos" {
      try spacePut(path + "/LightenQA-library.photoslibrary/database")
    } else {
      try spaceApp(path + "/LightenQA-tool.app", id: "qa.lighten.tool")
    }
    let result = try await ActionExecutor(
      journal: JSONLActionJournal(path: home + "/actions.jsonl"), trash: SpaceRenameTrash(destination: home + "/trash"),
      guardService: ActionGuard(homeDirectory: home), runningApplications: SpaceClosedApps(running: ["qa.lighten.tool"])
    )
    .execute(plan)
    #expect(result.items.first?.outcome == .skipped)
    #expect(FileManager.default.fileExists(atPath: path))
    if variant == "running-app" { #expect(result.items.first?.detail == "runningOrUnknown") }
  }

  @Test("A current-user open file refuses a fresh Space tree")
  func openFileRefuses() async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/cache"
    try spacePut(path + "/file")
    let plan = try spacePlan(path, home: home)
    let fd = open(path + "/file", O_RDONLY | O_NOFOLLOW)
    try #require(fd >= 0)
    defer { close(fd) }
    let result = try await ActionExecutor(
      journal: JSONLActionJournal(path: home + "/actions.jsonl"), trash: SpaceRenameTrash(destination: home + "/trash"),
      guardService: ActionGuard(homeDirectory: home)
    ).execute(plan)
    #expect(result.items.first?.outcome == .skipped)
    #expect(result.items.first?.detail?.hasPrefix("processActive:") == true)
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test("VM owner apps and attached or unobservable sparse images refuse", arguments: ["vm", "mounted", "unknown"])
  func ownerOrMountRefuses(_ variant: String) async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + (variant == "vm" ? "/LightenQA-fixture.utm" : "/LightenQA-fixture.sparsebundle")
    try spacePut(path + "/payload")
    let plan = try spacePlan(path, home: home)
    let mounts = SpaceObservedMounts()
    mounts.set(variant == "unknown" ? .unknown : .attached)
    let apps = SpaceClosedApps(running: variant == "vm" ? ["com.utmapp.UTM"] : [])
    let planner = PlanService(homeDirectory: home, runningApplications: apps, mountedImages: mounts)
    let proposed = await planner.makeAvailableSpacePlan(
      selections: [try spaceSelection(path)], scanRootPath: home, runID: UUID())
    #expect(proposed.plan == nil)
    #expect(
      proposed.rejections.first?.reason
        == (variant == "vm" ? .applicationRunning : variant == "mounted" ? .mountedImage : .imageStateUnavailable))
    let result = try await ActionExecutor(
      journal: JSONLActionJournal(path: home + "/actions.jsonl"), trash: SpaceRenameTrash(destination: home + "/trash"),
      guardService: ActionGuard(homeDirectory: home), runningApplications: apps, mountedImages: mounts
    ).execute(plan)
    #expect(result.items.first?.outcome == .skipped)
  }

  @Test(
    "Changes after the durable intent cannot move an older inventory", arguments: ["protected", "activity", "mount"])
  func afterIntentRefuses(_ variant: String) async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + (variant == "mount" ? "/LightenQA-fixture.sparsebundle" : "/cache")
    try spacePut(path + "/old")
    let plan = try spacePlan(path, home: home)
    let activity = SpaceObservedActivity()
    let mounts = SpaceObservedMounts()
    let result = try await ActionExecutor(
      journal: JSONLActionJournal(path: home + "/actions.jsonl"), trash: SpaceRenameTrash(destination: home + "/trash"),
      guardService: ActionGuard(homeDirectory: home),
      beforeMutation: { _ in
        switch variant {
        case "protected": try spacePut(path + "/LightenQA-library.photoslibrary/database")
        case "activity": activity.set(.active)
        default: mounts.set(.attached)
        }
      }, spaceActivity: activity, mountedImages: mounts
    ).execute(plan)
    #expect(result.items.first?.outcome == .skipped)
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test("Finder directory metadata does not block Undo; files remain strict")
  func finderMetadataUndo() async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/folder"
    try spacePut(path + "/file")
    let plan = try spacePlan(path, home: home)
    let journal = JSONLActionJournal(path: home + "/actions.jsonl")
    let result = try await ActionExecutor(
      journal: journal, trash: SpaceRenameTrash(destination: home + "/trash"),
      guardService: ActionGuard(homeDirectory: home)
    )
    .execute(plan)
    #expect(result.items.first?.outcome == .applied)
    try spacePut(home + "/trash/folder/.DS_Store")
    let history = ActionHistory(journal: journal, homeDirectory: home)
    #expect(try await history.reconcile().items.first?.canUndo == true)
    #expect(try await history.undo(planID: plan.id).restoredCount == 1)
    #expect(FileManager.default.fileExists(atPath: path + "/.DS_Store"))
    let regular = home + "/single-file"
    try spacePut(regular)
    let regularPlan = try spacePlan(regular, home: home)
    #expect(
      try await ActionExecutor(
        journal: journal, trash: SpaceRenameTrash(destination: home + "/trash"),
        guardService: ActionGuard(homeDirectory: home)
      )
      .execute(regularPlan).items.first?.outcome == .applied)
    try spacePut(home + "/trash/single-file", bytes: 100)
    #expect(try await history.undo(planID: regularPlan.id).restoredCount == 0)
  }

  @Test("A removed Trash item has a specific recovery reason")
  func missingTrashReason() async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/folder"
    try spacePut(path + "/file")
    let plan = try spacePlan(path, home: home)
    let journal = JSONLActionJournal(path: home + "/actions.jsonl")
    #expect(
      try await ActionExecutor(
        journal: journal, trash: SpaceRenameTrash(destination: home + "/trash"),
        guardService: ActionGuard(homeDirectory: home)
      )
      .execute(plan).items.first?.outcome == .applied)
    try FileManager.default.removeItem(atPath: home + "/trash/folder")
    let history = ActionHistory(journal: journal, homeDirectory: home)
    #expect(try await history.reconcile().items.first?.detail == "trashItemMissing")
    #expect(try await history.undo(planID: plan.id).items.first?.failure == .trashItemMissing)
  }

  @Test("Native mounted-image properties are parsed without executing tools")
  func imageProperties() {
    #expect(
      NativeMountedImageSource.imagePathValue("file:///tmp/LightenQA%20disk.sparseimage", urlProperty: true)
        == "/tmp/LightenQA disk.sparseimage")
    #expect(
      NativeMountedImageSource.imagePathValue(Data("/tmp/LightenQA-disk.sparseimage\0".utf8), urlProperty: false)
        == "/tmp/LightenQA-disk.sparseimage")
    #expect(NativeMountedImageSource.imagePathValue("https://example.test/image", urlProperty: true) == nil)
    #expect(NativeMountedImageSource.imagePathValue(Data(), urlProperty: false) == nil)
  }
}

@Suite("Space scan protection")
struct SpaceScanProtectionTests {
  @Test("Space measures whole backups while their parents and interiors remain unselectable")
  func backupScanSelection() async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let base = home + "/Library/Application Support/MobileSync"
    let backup = base + "/Backup/LightenQA-" + UUID().uuidString
    try spacePut(backup + "/payload")
    let run = try ScanEngine(configuration: ScanConfiguration(workers: 1, homeDirectory: home)).start(root: home)
    await run.waitUntilFinished()
    func find(_ path: String, node: ScanItemID) -> SpaceItem? {
      if let item = run.tree.item(node), item.path == path { return item }
      for child in run.tree.children(of: node, metric: .logical) {
        if child.path == path { return child }
        if child.id.isNode, let match = find(path, node: child.id) { return match }
      }
      return nil
    }
    let whole = try #require(find(backup, node: run.tree.rootID))
    #expect(whole.canSelect)
    #expect(whole.logical.completeTotal != nil)
    #expect(!whole.isProtected)
    #expect(find(base, node: run.tree.rootID)?.canSelect == false)
    #expect(find(base + "/Backup", node: run.tree.rootID)?.canSelect == false)
    #expect(find(backup + "/payload", node: run.tree.rootID)?.canSelect == false)
    #expect(ProtectionPolicy.rule(for: backup, homeDirectory: home)?.id == "mobile-sync")
  }

  @Test(
    "Permanent sensitive trees remain protected during Space scans",
    arguments: [
      "Library/Mail", "Library/Messages", "Library/Keychains", ".ssh", "Photos/LightenQA-library.photoslibrary",
    ])
  func permanentAreas(_ relative: String) async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/" + relative
    try spacePut(path + "/payload")
    #expect(throws: PlanRejections.self) { try spacePlan(path, home: home) }
    let rules = ProtectionPolicy.rules(for: path, homeDirectory: home)
    #expect(rules.contains { $0.scope == .never })
    let automaton = ProtectionAutomaton(homeDirectory: home)
    #expect(automaton.scanMatch(automaton.state(forPath: path), path: path, homeDirectory: home) != nil)
  }

  @Test("A native detached-image observation reads the current registry")
  func nativeDetachedImage() async throws {
    let home = try spaceFixture()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/LightenQA-" + UUID().uuidString + ".sparseimage"
    try spacePut(path)
    #expect(await NativeMountedImageSource().state(imagePath: path) == .detached)
  }
}

private final class SpaceNativeTrash: TrashMoving {
  private let returned = Mutex<[String: String]>([:])
  func moveToTrash(path: String) async throws -> String {
    let moved = try await Task.detached {
      var result: NSURL?
      try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
      return try #require(result?.path)
    }.value
    returned.withLock { $0[path] = moved }
    return moved
  }
  func paths() -> [String: String] { returned.withLock { $0 } }
}

@Suite("Real-location Space fixtures")
struct RealLocationSpaceSafetyTests {
  @Test("Own whole device backup and Xcode archive move through native Trash and Undo")
  func nativeBackupAndArchive() async throws {
    guard let identifier = ProcessInfo.processInfo.environment["LIGHTEN_REAL_SPACE_FIXTURE_ID"],
      UUID(uuidString: identifier) != nil
    else { return }
    let name = "LightenQA-" + identifier
    let home = NSHomeDirectory()
    let roots = [
      home + "/Library/Application Support/MobileSync/Backup/" + name,
      home + "/Library/Developer/Xcode/Archives/" + name + ".xcarchive",
    ]
    let temporary = "/private/tmp/" + name
    let mover = SpaceNativeTrash()
    for path in roots + [temporary] {
      try #require(!FileManager.default.fileExists(atPath: path), "Refuse an existing fixture path")
    }
    var createdParents: [String] = []
    for root in roots {
      var parent = (root as NSString).deletingLastPathComponent
      while !FileManager.default.fileExists(atPath: parent), parent.hasPrefix(home + "/Library/") {
        createdParents.append(parent)
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
    defer {
      for (source, trash) in mover.paths() {
        if FileManager.default.fileExists(atPath: trash), !FileManager.default.fileExists(atPath: source) {
          try? FileManager.default.moveItem(atPath: trash, toPath: source)
        }
      }
      for path in roots + [temporary] { try? FileManager.default.removeItem(atPath: path) }
      for path in Set(createdParents).sorted(by: { $0.count > $1.count }) {
        if (try? FileManager.default.contentsOfDirectory(atPath: path).isEmpty) == true {
          try? FileManager.default.removeItem(atPath: path)
        }
      }
    }
    try spacePut(roots[0] + "/device-data/chunk", bytes: 4096)
    try spacePut(roots[1] + "/dSYMs/LightenQA-symbols.dSYM/Contents/Resources/DWARF/tool", bytes: 8192)
    try FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: true)
    let outcome = await PlanService().makeAvailableSpacePlan(
      selections: try roots.map(spaceSelection), scanRootPath: home, runID: UUID())
    #expect(outcome.rejections.isEmpty)
    let plan = try #require(outcome.plan)
    #expect(plan.items.count == 2)
    let journal = JSONLActionJournal(path: temporary + "/actions.jsonl")
    let result = try await ActionExecutor(journal: journal, trash: mover).execute(plan)
    #expect(result.items.filter { $0.outcome == .applied }.count == 2)
    let returnedArchive = try #require(mover.paths()[roots[1]])
    try spacePut(returnedArchive + "/.DS_Store")
    let undo = try await ActionHistory(journal: journal).undo(planID: plan.id)
    #expect(undo.restoredCount == 2)
    #expect(FileManager.default.fileExists(atPath: roots[0] + "/device-data/chunk"))
    #expect(FileManager.default.fileExists(atPath: roots[1] + "/.DS_Store"))
  }
}
