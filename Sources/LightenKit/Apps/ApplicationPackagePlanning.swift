import Darwin
import Foundation

struct ApplicationPackageMetadata: Sendable {
  let rootIdentity: FileIdentity
  let observation: ApplicationPackageObservation
  let version: String?
}

struct ApplicationPackagePlan: Sendable {
  let physicalApplication: InstalledApplication?
  let physicalPackage: PlanItem
  let linkItem: PlanItem?
  let plan: ActionPlan
}

struct ApplicationPackagePreparation: Sendable {
  var packages: [UUID: PreparedApplicationPackage] = [:]
  var links: [UUID: PreparedApplicationLink] = [:]
  var failures: [UUID: PlanRejection] = [:]
}

/// Package requests and metadata observations never bypass the current native
/// inventory, process census, protection, volume or ownership checks.
struct ApplicationPackagePlanning: Sendable {
  let homeDirectory: String
  private let runningApplications: any RunningApplicationSource
  private let applicationActivity: any ApplicationActivitySource
  private let measure: @Sendable (String, String) async -> ObservedPlanSize

  init(
    homeDirectory: String = NSHomeDirectory(),
    runningApplications: any RunningApplicationSource = NativeRunningApplicationSource(),
    applicationActivity: any ApplicationActivitySource = NativeApplicationActivitySource(),
    measure: @escaping @Sendable (String, String) async -> ObservedPlanSize = { path, home in
      let size = await ApplicationDiscovery.measure(path: path, homeDirectory: home)
      return ObservedPlanSize(logical: size.logical, allocated: size.allocated)
    }
  ) {
    self.homeDirectory = homeDirectory
    self.runningApplications = runningApplications
    self.applicationActivity = applicationActivity
    self.measure = measure
  }

  func makePlan(path: String, expectedBundleID: String?, runID: UUID = UUID()) async throws
    -> ApplicationPackagePlan
  {
    let initial = try makeIdentityPlan(path: path, expectedBundleID: expectedBundleID, runID: runID)
    let original = initial.physicalPackage
    let metadata = try Self.validatePackage(original)
    try await validateActivity(
      path: original.sourcePath, metadata: metadata, nested: original.nestedApplicationIDs ?? [])
    let size = await measure(original.sourcePath, homeDirectory)
    try Task.checkCancellation()
    _ = try Self.validatePackage(original)
    let physical = PlanItem(
      id: original.id, sourcePath: original.sourcePath, volumeID: original.volumeID,
      inventory: original.inventory, ancestors: original.ancestors, policy: .wholeBundle,
      applicationBundleID: original.applicationBundleID, nestedApplicationIDs: original.nestedApplicationIDs,
      snapshotRunID: original.snapshotRunID, observedSize: size,
      sizeMetadataVersion: original.sizeMetadataVersion,
      applicationPackageObservation: original.applicationPackageObservation,
      packageLinkTargetItemID: original.packageLinkTargetItemID)
    let plan = ActionPlan(snapshotRunID: runID, kind: .trash, items: [physical] + [initial.linkItem].compactMap { $0 })
    let prepared = prepare(plan: plan)
    guard prepared.failures.isEmpty else {
      throw PlanRejections(rejections: plan.items.compactMap { prepared.failures[$0.id] })
    }
    return ApplicationPackagePlan(
      physicalApplication: initial.physicalApplication, physicalPackage: physical, linkItem: initial.linkItem,
      plan: plan)
  }

  /// Synchronous identity construction for callers that separately observe
  /// package activity. The async normal planner also measures fresh contents.
  func makeIdentityPlan(path: String, expectedBundleID: String?, runID: UUID = UUID()) throws
    -> ApplicationPackagePlan
  {
    let selected = try DescriptorFileSystem.identity(at: path)
    let link: ApplicationLinkObservation?
    if selected.kind == .symbolicLink { link = try ApplicationLinkObservation.capture(path: path) } else { link = nil }
    let physicalPath = link?.targetPath ?? path
    let metadata = try Self.metadata(at: physicalPath)
    guard metadata.observation.bundleIdentifier == expectedBundleID else {
      throw PlanRejection(.changedSinceScan, path: physicalPath, ruleID: "application-identifier-changed")
    }
    let inventory = try ExactInventory(homeDirectory: homeDirectory).collect(
      rootPath: physicalPath, expected: (metadata.rootIdentity.device, metadata.rootIdentity.inode),
      policy: .wholeBundle)
    let finished = try Self.metadata(at: physicalPath)
    guard metadata.rootIdentity.matchesStableTrashIdentity(finished.rootIdentity),
      finished.observation == metadata.observation
    else { throw PlanRejection(.changedSinceScan, path: physicalPath, ruleID: "application-metadata-changed") }
    let physical = PlanItem(
      id: inventory.entries[0].id, sourcePath: physicalPath, volumeID: inventory.volumeID,
      inventory: inventory.entries, ancestors: inventory.ancestors, policy: .wholeBundle,
      applicationBundleID: metadata.observation.bundleIdentifier,
      nestedApplicationIDs: inventory.nestedApplicationIDs, snapshotRunID: runID,
      observedSize: .unknown, applicationPackageObservation: metadata.observation)
    let leaf: PlanItem?
    if let link {
      try link.validate()
      let exact = try ExactInventory(homeDirectory: homeDirectory).collect(
        rootPath: path, expected: (selected.device, selected.inode), policy: .applicationLink)
      leaf = PlanItem(
        id: exact.entries[0].id, sourcePath: path, volumeID: exact.volumeID,
        inventory: exact.entries, ancestors: exact.ancestors, policy: .applicationLink,
        snapshotRunID: runID, packageLinkTargetItemID: physical.id)
    } else {
      leaf = nil
    }
    let plan = ActionPlan(snapshotRunID: runID, kind: .trash, items: [physical] + [leaf].compactMap { $0 })
    let prepared = prepare(plan: plan)
    guard prepared.failures.isEmpty else {
      throw PlanRejections(rejections: plan.items.compactMap { prepared.failures[$0.id] })
    }
    let app = metadata.observation.bundleIdentifier.map {
      InstalledApplication(bundleID: $0, path: physicalPath, version: metadata.version)
    }
    return ApplicationPackagePlan(physicalApplication: app, physicalPackage: physical, linkItem: leaf, plan: plan)
  }

  private func validateActivity(path: String, metadata: ApplicationPackageMetadata, nested: [String]) async throws {
    let activity = await applicationActivity.activity(applicationPath: path)
    switch activity.state {
    case .clearObservedProcesses: break
    case .active: throw PlanRejection(.processActive, path: path, ruleID: activity.processNames.joined(separator: ", "))
    case .unknown:
      throw PlanRejection(.activityUnavailable, path: path, ruleID: activity.processNames.joined(separator: ", "))
    }
    for id in Set([metadata.observation.bundleIdentifier].compactMap { $0 } + nested) {
      guard id.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame else {
        throw PlanRejection(.lightenItself, path: path, ruleID: id)
      }
      switch await runningApplications.isRunning(bundleID: id) {
      case false: break
      case true: throw PlanRejection(.applicationRunning, path: path, ruleID: id)
      case nil: throw PlanRejection(.activityUnavailable, path: path, ruleID: id)
      }
    }
  }

  func prepare(plan: ActionPlan) -> ApplicationPackagePreparation {
    var result = ApplicationPackagePreparation()
    let guardService = ActionGuard(homeDirectory: homeDirectory)
    for item in plan.items where item.policy == .wholeBundle {
      do {
        let package = try PreparedApplicationPackage.capture(item: item, plan: plan)
        try guardService.validate(item)
        result.packages[item.id] = package
      } catch { result.failures[item.id] = Self.refusal(error, path: item.sourcePath) }
    }
    for item in plan.items where item.policy == .applicationLink {
      do {
        guard let targetID = item.packageLinkTargetItemID,
          plan.items.filter({ $0.id == targetID }).count == 1,
          let package = result.packages[targetID]
        else { throw PlanRejection(.unavailable, path: item.sourcePath, ruleID: "application-link-pair") }
        let link = try PreparedApplicationLink.capture(item: item, plan: plan, package: package)
        try guardService.validate(item, plan: plan, preparedLink: link)
        result.links[item.id] = link
      } catch {
        let failure = Self.refusal(error, path: item.sourcePath)
        result.failures[item.id] = failure
        if let targetID = item.packageLinkTargetItemID,
          let target = plan.items.first(where: { $0.id == targetID && $0.policy == .wholeBundle })
        {
          result.failures[targetID] = PlanRejection(failure.reason, path: target.sourcePath, ruleID: failure.ruleID)
        }
      }
    }
    return result
  }

  static func refusal(_ error: any Error, path: String) -> PlanRejection {
    if let refusal = error as? PlanRejection { return refusal }
    if let refusals = error as? PlanRejections,
      let refusal = refusals.rejections.first(where: { $0.path == path }) ?? refusals.rejections.first
    {
      return refusal
    }
    if let failure = error as? GuardFailure {
      switch failure {
      case .protectedItem: return PlanRejection(.protectedItem, path: path, ruleID: "application-package-protected")
      case .unsupportedItem: return PlanRejection(.unavailable, path: path, ruleID: "application-package-unsupported")
      case .changedAncestor, .changedItem, .changedInventory:
        return PlanRejection(.changedSinceScan, path: path, ruleID: String(describing: failure))
      }
    }
    if let failure = error as? SecureMetadataFailure {
      switch failure {
      case .unsafe, .tooLarge: return PlanRejection(.missingMetadata, path: path, ruleID: "application-info-unsafe")
      case .changed: return PlanRejection(.changedSinceScan, path: path, ruleID: "application-info-changed")
      }
    }
    if case FileSystemFailure.invalidPath = error {
      return PlanRejection(.unavailable, path: path, ruleID: "application-native-path-invalid")
    }
    if case FileSystemFailure.systemCall(_, let code) = error {
      return PlanRejection(
        code == EACCES || code == EPERM ? .unreadableFolder : .changedSinceScan,
        path: path, ruleID: "errno:\(code)")
    }
    return PlanRejection(.changedSinceScan, path: path, ruleID: "application-package-changed")
  }

  /// A conservative boundary observation. Ambiguous layouts remain packages,
  /// while actionable metadata below still requires one exact supported layout.
  static func recognizesPackageLayout(at path: String) -> Bool {
    guard ApplicationRegistration.hasApplicationSuffix(path),
      (try? DescriptorFileSystem.identity(at: path))?.kind == .directory
    else { return false }
    if (try? DescriptorFileSystem.identity(at: path + "/Contents"))?.kind == .directory,
      (try? DescriptorFileSystem.identity(at: path + "/Contents/Info.plist"))?.kind == .regular
    {
      return true
    }
    if (try? DescriptorFileSystem.identity(at: path + "/Info.plist"))?.kind == .regular { return true }
    guard let wrapper = try? DescriptorFileSystem.identity(at: path + "/Wrapper"), wrapper.kind == .directory,
      let names = try? DescriptorFileSystem.children(at: path + "/Wrapper", expected: wrapper)
    else { return false }
    return names.contains { name in
      ApplicationRegistration.hasApplicationSuffix(name)
        && (try? DescriptorFileSystem.identity(at: path + "/Wrapper/" + name))?.kind == .directory
        && (try? DescriptorFileSystem.identity(at: path + "/Wrapper/" + name + "/Info.plist"))?.kind == .regular
    }
  }

  /// Identifiers here supply only self/running vetoes, never package authority.
  /// Inspecting every recognizable layout keeps an extra Info file from hiding
  /// a protected application's existing identifier.
  static func observedBundleIdentifiers(at path: String) throws(PlanRejection) -> [String] {
    do {
      let root = try DescriptorFileSystem.identity(at: path)
      let paths = try recognizedInfoPaths(at: path)
      var identifiers: Set<String> = []
      for relative in paths {
        let infoPath = path + "/" + relative
        let info = try DescriptorFileSystem.identity(at: infoPath)
        guard let data = try SecureMetadataFile.read(path: infoPath, limit: 1024 * 1024, ownerOnly: false) else {
          throw PlanRejection(.changedSinceScan, path: infoPath)
        }
        if let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dictionary = value as? [String: Any], let id = dictionary["CFBundleIdentifier"] as? String,
          RelatedDataService.validBundleID(id)
        {
          identifiers.insert(id)
        }
        guard try DescriptorFileSystem.identity(at: infoPath) == info else {
          throw PlanRejection(.changedSinceScan, path: infoPath)
        }
      }
      guard paths == (try recognizedInfoPaths(at: path)),
        root.matchesStableTrashIdentity(try DescriptorFileSystem.identity(at: path))
      else { throw PlanRejection(.changedSinceScan, path: path) }
      return identifiers.sorted()
    } catch { throw refusal(error, path: path) }
  }

  private static func recognizedInfoPaths(at path: String) throws -> [String] {
    guard ApplicationRegistration.hasApplicationSuffix(path),
      try DescriptorFileSystem.identity(at: path).kind == .directory
    else { return [] }
    var paths: [String] = []
    if (try optionalIdentity(at: path + "/Contents"))?.kind == .directory,
      (try optionalIdentity(at: path + "/Contents/Info.plist"))?.kind == .regular
    {
      paths.append("Contents/Info.plist")
    }
    if (try optionalIdentity(at: path + "/Info.plist"))?.kind == .regular { paths.append("Info.plist") }
    if let wrapper = try optionalIdentity(at: path + "/Wrapper"), wrapper.kind == .directory {
      for name in try DescriptorFileSystem.children(at: path + "/Wrapper", expected: wrapper)
      where ApplicationRegistration.hasApplicationSuffix(name) {
        if (try optionalIdentity(at: path + "/Wrapper/" + name))?.kind == .directory,
          (try optionalIdentity(at: path + "/Wrapper/" + name + "/Info.plist"))?.kind == .regular
        {
          paths.append("Wrapper/" + name + "/Info.plist")
        }
      }
    }
    return paths
  }

  /// Resolves one actionable layout from current no-follow native metadata.
  static func infoRelativePath(at path: String) throws -> String {
    guard ApplicationRegistration.hasApplicationSuffix(path),
      try DescriptorFileSystem.identity(at: path).kind == .directory
    else { throw PlanRejection(.missingMetadata, path: path, ruleID: "application-layout") }
    let contents = try optionalIdentity(at: path + "/Contents")
    let flat = try optionalIdentity(at: path + "/Info.plist")
    let wrapper = try optionalIdentity(at: path + "/Wrapper")
    if let contents {
      guard contents.kind == .directory, flat == nil, wrapper == nil,
        try DescriptorFileSystem.identity(at: path + "/Contents/Info.plist").kind == .regular
      else { throw PlanRejection(.missingMetadata, path: path, ruleID: "application-layout") }
      return "Contents/Info.plist"
    }
    if let flat {
      guard flat.kind == .regular, wrapper == nil else {
        throw PlanRejection(.missingMetadata, path: path, ruleID: "application-layout")
      }
      return "Info.plist"
    }
    guard let wrapper, wrapper.kind == .directory else {
      throw PlanRejection(.missingMetadata, path: path, ruleID: "application-info-missing")
    }
    let apps = try DescriptorFileSystem.children(at: path + "/Wrapper", expected: wrapper)
      .filter { ApplicationRegistration.hasApplicationSuffix($0) }
    guard apps.count == 1,
      try DescriptorFileSystem.identity(at: path + "/Wrapper/" + apps[0]).kind == .directory,
      try DescriptorFileSystem.identity(at: path + "/Wrapper/" + apps[0] + "/Info.plist").kind == .regular
    else { throw PlanRejection(.missingMetadata, path: path, ruleID: "application-wrapper-layout") }
    return "Wrapper/" + apps[0] + "/Info.plist"
  }

  private static func optionalIdentity(at path: String) throws -> FileIdentity? {
    do { return try DescriptorFileSystem.identity(at: path) } catch FileSystemFailure.systemCall(_, let code)
      where code == ENOENT || code == ENOTDIR
    { return nil }
  }

  static func metadata(at path: String) throws(PlanRejection) -> ApplicationPackageMetadata {
    do { return try readMetadata(at: path) } catch { throw refusal(error, path: path) }
  }

  private static func readMetadata(at path: String) throws -> ApplicationPackageMetadata {
    let root = try DescriptorFileSystem.identity(at: path)
    let relative = try infoRelativePath(at: path)
    let infoPath = path + "/" + relative
    let info = try DescriptorFileSystem.identity(at: infoPath)
    if info.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0 {
      throw PlanRejection(.cloudItem, path: infoPath)
    }
    guard info.kind == .regular,
      let data = try SecureMetadataFile.read(path: infoPath, limit: 1024 * 1024, ownerOnly: false)
    else { throw PlanRejection(.missingMetadata, path: infoPath, ruleID: "application-info-invalid") }
    let value: Any
    do { value = try PropertyListSerialization.propertyList(from: data, format: nil) } catch {
      throw PlanRejection(.missingMetadata, path: infoPath, ruleID: "application-info-invalid")
    }
    guard let dictionary = value as? [String: Any] else {
      throw PlanRejection(.missingMetadata, path: infoPath, ruleID: "application-info-invalid")
    }
    let id: String?
    if let value = dictionary["CFBundleIdentifier"] {
      guard let identifier = value as? String, RelatedDataService.validBundleID(identifier) else {
        throw PlanRejection(.missingMetadata, path: infoPath, ruleID: "application-identifier-invalid")
      }
      id = identifier
    } else {
      id = nil
    }
    guard try infoRelativePath(at: path) == relative,
      try DescriptorFileSystem.identity(at: infoPath) == info,
      root.matchesStableTrashIdentity(try DescriptorFileSystem.identity(at: path))
    else { throw PlanRejection(.changedSinceScan, path: path, ruleID: "application-metadata-changed") }
    return ApplicationPackageMetadata(
      rootIdentity: root,
      observation: ApplicationPackageObservation(infoRelativePath: relative, infoIdentity: info, bundleIdentifier: id),
      version: (dictionary["CFBundleShortVersionString"] as? String) ?? (dictionary["CFBundleVersion"] as? String))
  }

  static func validatePackage(_ item: PlanItem) throws -> ApplicationPackageMetadata {
    guard item.policy == .wholeBundle, item.packageLinkTargetItemID == nil,
      item.catalogProof == nil, item.relatedProof == nil, item.installedRelatedProof == nil,
      item.orphanRelatedProof == nil, item.duplicateProof == nil,
      let expectedRoot = item.inventory.first?.identity, expectedRoot.kind == .directory
    else { throw GuardFailure.unsupportedItem }
    guard RelatedDataService.currentUserOwns(item.sourcePath) else {
      throw PlanRejection(.needsAdministrator, path: item.sourcePath)
    }
    let current = try metadata(at: item.sourcePath)
    guard expectedRoot.matchesStableTrashIdentity(current.rootIdentity) else { throw GuardFailure.changedItem }
    if let expected = item.applicationPackageObservation {
      guard expected == current.observation, expected.bundleIdentifier == item.applicationBundleID else {
        throw GuardFailure.changedItem
      }
    } else {
      guard current.observation.infoRelativePath == "Contents/Info.plist",
        item.applicationBundleID == nil || current.observation.bundleIdentifier == item.applicationBundleID
      else { throw GuardFailure.unsupportedItem }
    }
    if let id = current.observation.bundleIdentifier,
      id.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame
    {
      throw PlanRejection(.lightenItself, path: item.sourcePath, ruleID: id)
    }
    return current
  }
}

struct PreparedApplicationPackage: Sendable {
  let planID: UUID
  let item: PlanItem

  private init(planID: UUID, item: PlanItem) {
    self.planID = planID
    self.item = item
  }

  fileprivate static func capture(item: PlanItem, plan: ActionPlan) throws -> Self {
    guard plan.kind == .trash, plan.items.filter({ $0.id == item.id }).count == 1, plan.items.contains(item) else {
      throw GuardFailure.unsupportedItem
    }
    _ = try ApplicationPackagePlanning.validatePackage(item)
    return Self(planID: plan.id, item: item)
  }

  func validate(plan: ActionPlan, movedOwner: MovedApplicationOwner? = nil) throws {
    guard plan.id == planID, plan.kind == .trash, plan.items.filter({ $0.id == item.id }) == [item] else {
      throw GuardFailure.unsupportedItem
    }
    if let movedOwner {
      guard movedOwner.planID == planID, movedOwner.originalPackage == item,
        MovedApplicationOwner.isAbsent(item.sourcePath)
      else { throw GuardFailure.changedItem }
      _ = try ApplicationPackagePlanning.validatePackage(movedOwner.movedPackage)
    } else {
      _ = try ApplicationPackagePlanning.validatePackage(item)
    }
  }
}

struct PreparedApplicationLink: Sendable {
  let planID: UUID
  let item: PlanItem
  let package: PreparedApplicationPackage
  // The private observation keeps the synthesized initializer private.
  private let observation: ApplicationLinkObservation

  fileprivate static func capture(item: PlanItem, plan: ActionPlan, package: PreparedApplicationPackage) throws -> Self
  {
    guard plan.kind == .trash, plan.items.filter({ $0.id == item.id }) == [item], item.policy == .applicationLink,
      item.packageLinkTargetItemID == package.item.id, package.item.applicationPackageObservation != nil,
      item.applicationPackageObservation == nil, item.applicationBundleID == nil,
      item.inventory.count == 1, item.inventory.first?.identity?.kind == .symbolicLink,
      item.catalogProof == nil, item.relatedProof == nil, item.installedRelatedProof == nil,
      item.orphanRelatedProof == nil, item.duplicateProof == nil
    else { throw GuardFailure.unsupportedItem }
    try package.validate(plan: plan)
    let observation = try ApplicationLinkObservation.capture(path: item.sourcePath)
    guard observation.identity == item.inventory.first?.identity,
      observation.targetPath == package.item.sourcePath
    else { throw GuardFailure.changedItem }
    return Self(planID: plan.id, item: item, package: package, observation: observation)
  }

  func validate(_ selected: PlanItem, plan: ActionPlan, movedOwner: MovedApplicationOwner?) throws {
    guard selected == item, plan.id == planID, plan.kind == .trash,
      plan.items.filter({ $0.id == item.id }) == [item],
      item.packageLinkTargetItemID == package.item.id
    else { throw GuardFailure.unsupportedItem }
    try package.validate(plan: plan, movedOwner: movedOwner)
    // The leaf is intentionally dangling after its physical package moves.
    // Validate its own bytes and identity without resolving its target again.
    try observation.validate()
    if movedOwner == nil {
      guard try ApplicationLinkObservation.capture(path: item.sourcePath).targetPath == package.item.sourcePath else {
        throw GuardFailure.changedItem
      }
    }
  }
}

private struct ApplicationLinkObservation: Sendable {
  let path: String
  let identity: FileIdentity
  let bytes: Data
  let targetPath: String

  static func capture(path: String) throws -> Self {
    let (identity, bytes) = try leaf(at: path)
    guard let raw = String(data: bytes, encoding: .utf8), !raw.isEmpty,
      !raw.unicodeScalars.contains(where: { $0.value == 0 })
    else { throw GuardFailure.unsupportedItem }
    let absolute = raw.hasPrefix("/") ? raw : (path as NSString).deletingLastPathComponent + "/" + raw
    var components: [String] = []
    for part in absolute.split(separator: "/") {
      if part == "." { continue }
      if part == ".." {
        guard !components.isEmpty else { throw GuardFailure.unsupportedItem }
        components.removeLast()
      } else {
        components.append(String(part))
      }
    }
    let target = "/" + components.joined(separator: "/")
    guard ApplicationRegistration.hasApplicationSuffix(path), ApplicationRegistration.hasApplicationSuffix(target),
      try DescriptorFileSystem.identity(at: target).kind == .directory,
      let resolved = realpath(target, nil)
    else { throw GuardFailure.unsupportedItem }
    defer { free(resolved) }
    guard String(cString: resolved) == target else { throw GuardFailure.unsupportedItem }
    let result = Self(path: path, identity: identity, bytes: bytes, targetPath: target)
    try result.validate()
    return result
  }

  func validate() throws {
    let current = try Self.leaf(at: path)
    guard current.0 == identity, current.1 == bytes else { throw GuardFailure.changedItem }
  }

  private static func leaf(at path: String) throws -> (FileIdentity, Data) {
    let (fd, name) = try DescriptorFileSystem.openParent(of: path)
    defer { close(fd) }
    var before = stat()
    guard fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
      throw FileSystemFailure.systemCall("fstatat", errno)
    }
    guard before.st_mode & S_IFMT == S_IFLNK, before.st_uid == geteuid() else {
      throw PlanRejection(.needsAdministrator, path: path)
    }
    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
    let count = bytes.withUnsafeMutableBytes {
      readlinkat(fd, name, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count)
    }
    guard count > 0, count < bytes.count else { throw FileSystemFailure.systemCall("readlinkat", errno) }
    var after = stat()
    let identity = DescriptorFileSystem.identity(from: before)
    guard fstatat(fd, name, &after, AT_SYMLINK_NOFOLLOW_ANY) == 0,
      DescriptorFileSystem.identity(from: after) == identity
    else { throw GuardFailure.changedItem }
    return (identity, Data(bytes.prefix(count)))
  }
}
