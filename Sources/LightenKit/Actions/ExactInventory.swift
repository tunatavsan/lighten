import Darwin
import Foundation

/// How a Trash plan treats its descendants. `nil` on a plan item keeps the
/// original strict rules, including for journal records written before this field.
public enum TreePolicy: String, Codable, Sendable {
  /// Space selection: symbolic links and intact packages move as leaves.
  case spaceTrash
  /// A whole application package moved intact. Its root still receives every
  /// protection check; its contents do not supply Trash or Undo authority.
  case wholeBundle
  /// Catalog cache packages and symbolic links, authorized only by a Trash proof.
  case catalogTrash
  /// Regenerable build output also permits debug symbols below the selected root.
  case catalogBuildOutput
  /// Exact app-domain data; a matching installed or absent-owner proof is required.
  case relatedTrash
  /// A whole sandbox container, including its Documents directory.
  case relatedContainer
  /// A group container whose sole installed owner claims it in signed entitlements.
  case relatedGroupContainer
}

public enum RejectionReason: String, Codable, Sendable, Equatable {
  case bulkRoot
  case scanRoot
  case insidePackage
  case protectedItem
  case containsProtectedItem
  case containsApplication
  case mountPoint
  case cloudItem
  case unreadableFolder
  case specialFile
  case symbolicLinkRoot
  case missingMetadata
  case changedSinceScan
  case differentVolume
  case needsAdministrator
  case userPermissionDenied
  case processActive, activityUnavailable, mountedImage, imageStateUnavailable
  case applicationRunning
  case lightenItself
  case tooManyItems
  case unavailable
}

/// A refused selection always names the reason and the path that caused it.
public struct PlanRejection: Error, Sendable, Equatable, Codable {
  public let reason: RejectionReason
  public let path: String
  public let ruleID: String?

  public init(_ reason: RejectionReason, path: String, ruleID: String? = nil) {
    self.reason = reason
    self.path = path
    self.ruleID = ruleID
  }
}

public struct PlanRejections: Error, Sendable, Equatable {
  public let rejections: [PlanRejection]

  public init(rejections: [PlanRejection]) { self.rejections = rejections }
}

/// The exact, current inventory of one selected root, built at action time from
/// descriptor-relative no-follow metadata. Scan trees and caches are never used.
public struct ExactInventory: Sendable {
  public static let applicationRules: Set<String> = ["universal-thinning", "localization-bundles"]

  static func permits(
    _ rules: [NeverRule], policy: TreePolicy, path: String, rootPath: String, homeDirectory: String
  ) -> Bool {
    if policy == .spaceTrash || policy == .wholeBundle {
      return ProtectionPolicy.spaceTrashPermits(
        rules, path: path, rootPath: rootPath, homeDirectory: homeDirectory)
    }
    let exemptions: Set<String>
    switch policy {
    case .spaceTrash: exemptions = []
    case .wholeBundle, .catalogTrash: exemptions = applicationRules
    case .catalogBuildOutput: exemptions = applicationRules.union(["xcode-debug-symbols"])
    case .relatedTrash: exemptions = applicationRules
    case .relatedContainer: exemptions = applicationRules.union(["container-documents"])
    case .relatedGroupContainer: exemptions = applicationRules.union(["group-containers"])
    }
    return rules.allSatisfy { exemptions.contains($0.id) }
  }
  public let homeDirectory: String
  public let limit: Int

  public init(homeDirectory: String = NSHomeDirectory(), limit: Int = 2_000_000) {
    self.homeDirectory = homeDirectory
    self.limit = limit
  }

  public struct Result: Sendable {
    public let entries: [ScanEntry]
    public let policy: TreePolicy
    public let volumeID: UUID
    public let ancestors: [PathIdentity]
    /// Identifiers of application packages included by this tree policy.
    public let nestedApplicationIDs: [String]
  }

  static func isApplicationName(_ path: String) -> Bool {
    ApplicationPackage.isApplication(path)
  }

  /// Home folders whose removal would take whole categories of user data.
  public func isBulkRoot(_ path: String) -> Bool {
    if PlanService.isBulkRoot(path, homeDirectory: homeDirectory) { return true }
    let standard = [
      "Library", "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
    ].map { homeDirectory + "/" + $0 }
    let locale = Locale(identifier: "en_US_POSIX")
    let folded = path.lowercased(with: locale)
    return standard.contains { $0.lowercased(with: locale) == folded }
  }

  public func collect(
    rootPath: String, expected: (device: UInt64, inode: UInt64)?, policy requestedPolicy: TreePolicy? = nil,
    isCancelled: @Sendable () -> Bool = { false }
  ) throws(PlanRejection) -> Result {
    guard (try? DescriptorFileSystem.validatedComponents(rootPath)) != nil else {
      throw PlanRejection(.unavailable, path: rootPath)
    }
    if isBulkRoot(rootPath) { throw PlanRejection(.bulkRoot, path: rootPath) }
    let root: FileIdentity
    do { root = try DescriptorFileSystem.identity(at: rootPath) } catch {
      throw Self.readFailure(error, path: rootPath)
    }
    let wholeBundle = root.kind == .directory && Self.isApplicationName(rootPath)
    let policy: TreePolicy = requestedPolicy ?? (wholeBundle ? .wholeBundle : .spaceTrash)
    let opaque = Self.isOpaquePackage(path: rootPath, identity: root, policy: policy)
    if wholeBundle,
      ApplicationIdentity.bundleIdentifier(ofApplicationAt: rootPath)?
        .caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame
    {
      throw PlanRejection(.lightenItself, path: rootPath)
    }
    if ScanService.isInsidePackage(rootPath) {
      throw PlanRejection(.insidePackage, path: rootPath)
    }
    let relatedPolicy =
      requestedPolicy == .relatedTrash || requestedPolicy == .relatedContainer
      || requestedPolicy == .relatedGroupContainer
    if (relatedPolicy || opaque) && !RelatedDataService.currentUserOwns(rootPath) {
      throw PlanRejection(.needsAdministrator, path: rootPath)
    }
    if let expected, root.device != expected.device || root.inode != expected.inode {
      throw PlanRejection(.changedSinceScan, path: rootPath)
    }
    switch root.kind {
    case .symbolicLink:
      guard requestedPolicy == .catalogTrash || requestedPolicy == .catalogBuildOutput else {
        throw PlanRejection(.symbolicLinkRoot, path: rootPath)
      }
    case .other: throw PlanRejection(.specialFile, path: rootPath)
    case .regular, .directory: break
    }
    guard opaque ? root.hasOpaquePackageProof : root.hasStableTrashProof else {
      throw PlanRejection(.missingMetadata, path: rootPath)
    }
    if root.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0 { throw PlanRejection(.cloudItem, path: rootPath) }
    guard let volumeID = try? DescriptorFileSystem.volumeID(at: rootPath) else {
      throw PlanRejection(.differentVolume, path: rootPath)
    }
    let parent = (rootPath as NSString).deletingLastPathComponent
    if let parentIdentity = try? DescriptorFileSystem.identity(at: parent), parentIdentity.device != root.device {
      throw PlanRejection(.mountPoint, path: rootPath)
    }
    if access(parent, W_OK) != 0 || (root.kind == .directory && access(rootPath, W_OK) != 0) {
      let permissionError = errno
      var details = stat()
      let owned = lstat(rootPath, &details) == 0 && details.st_uid == geteuid()
      throw PlanRejection(
        owned ? .userPermissionDenied : .needsAdministrator, path: rootPath, ruleID: "errno:\(permissionError)")
    }
    let ancestors: [PathIdentity]
    do { ancestors = try DescriptorFileSystem.ancestorIdentities(of: rootPath) } catch {
      throw PlanRejection(.changedSinceScan, path: rootPath)
    }
    // Catalog Trash permissions come from a later manifest-proof validation.
    let rootRules = ProtectionPolicy.rules(for: rootPath, homeDirectory: homeDirectory)
    let permittedRoot =
      (policy == .spaceTrash || policy == .wholeBundle)
      ? ProtectionPolicy.spaceTrashPermits(rootRules, path: rootPath, rootPath: rootPath, homeDirectory: homeDirectory)
      : rootRules.allSatisfy { policy == .relatedGroupContainer && $0.id == "group-containers" }
    if !permittedRoot, let rule = rootRules.first {
      let blockingRule =
        rootRules.first { candidate in
          (policy == .spaceTrash || policy == .wholeBundle)
            ? !ProtectionPolicy.spaceTrashPermits(
              [candidate], path: rootPath, rootPath: rootPath, homeDirectory: homeDirectory)
            : !(policy == .relatedGroupContainer && candidate.id == "group-containers")
        } ?? rule
      throw PlanRejection(.protectedItem, path: rootPath, ruleID: blockingRule.id)
    }
    for ancestor in ancestors {
      let rules = ProtectionPolicy.rules(for: ancestor.path, homeDirectory: homeDirectory)
      let permitted =
        (policy == .spaceTrash || policy == .wholeBundle)
        ? ProtectionPolicy.spaceTrashPermits(
          rules, path: ancestor.path, rootPath: rootPath, homeDirectory: homeDirectory, ancestor: true)
        : rules.allSatisfy { policy == .relatedGroupContainer && $0.id == "group-containers" }
      if !permitted, let rule = rules.first {
        let blockingRule =
          rules.first { candidate in
            (policy == .spaceTrash || policy == .wholeBundle)
              ? !ProtectionPolicy.spaceTrashPermits(
                [candidate], path: ancestor.path, rootPath: rootPath, homeDirectory: homeDirectory, ancestor: true)
              : !(policy == .relatedGroupContainer && candidate.id == "group-containers")
          } ?? rule
        throw PlanRejection(.protectedItem, path: ancestor.path, ruleID: blockingRule.id)
      }
    }
    var nested: [String] = []
    let rootEntry = ScanEntry(parentID: nil, path: rootPath, identity: root, issues: [], readable: true)
    var entries = [rootEntry]
    if opaque {
      try Self.validateOpaqueRoot(path: rootPath, expected: root)
      nested = try Self.observePackage(
        path: rootPath, rootPath: rootPath, policy: policy,
        homeDirectory: homeDirectory, includeRootIdentifier: policy != .wholeBundle, isCancelled: isCancelled
      ).applicationIDs
    } else if root.kind == .directory {
      let automaton = ProtectionAutomaton(homeDirectory: homeDirectory)
      try walk(
        path: rootPath, parentID: rootEntry.id, identity: root, rootDevice: root.device,
        rootPath: rootPath, policy: policy, automaton: automaton,
        state: automaton.state(forPath: rootPath), entries: &entries, nested: &nested, isCancelled: isCancelled)
    }
    if nested.contains(where: {
      $0.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame
    }) {
      throw PlanRejection(.lightenItself, path: rootPath)
    }
    return Result(
      entries: entries, policy: policy, volumeID: volumeID, ancestors: ancestors, nestedApplicationIDs: nested)
  }

  private func walk(
    path: String, parentID: UUID, identity: FileIdentity, rootDevice: UInt64, rootPath: String,
    policy: TreePolicy, automaton: ProtectionAutomaton, state: ProtectionAutomaton.State,
    entries: inout [ScanEntry], nested: inout [String], isCancelled: @Sendable () -> Bool
  ) throws(PlanRejection) {
    if isCancelled() { throw PlanRejection(.unavailable, path: path) }
    let names: [String]
    let fd = DirectoryReader.openDirectory(path)
    guard fd >= 0 else { throw PlanRejection(.unreadableFolder, path: path) }
    defer { close(fd) }
    var opened = stat()
    guard fstat(fd, &opened) == 0, DescriptorFileSystem.identity(from: opened) == identity else {
      throw PlanRejection(.changedSinceScan, path: path)
    }
    do { names = try Self.names(fd: fd) } catch { throw PlanRejection(.unreadableFolder, path: path) }
    for name in names {
      let childPath = path + "/" + name
      var details = stat()
      guard fstatat(fd, name, &details, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
        throw PlanRejection(.changedSinceScan, path: childPath)
      }
      let child = DescriptorFileSystem.identity(from: details)
      if policy == .relatedTrash || policy == .relatedContainer || policy == .relatedGroupContainer,
        details.st_uid != geteuid()
      {
        throw PlanRejection(.needsAdministrator, path: childPath)
      }
      let childState = automaton.step(state, name)
      let rules = automaton.matches(childState, path: childPath, homeDirectory: homeDirectory)
      if let rule = rules.first,
        !Self.permits(rules, policy: policy, path: childPath, rootPath: rootPath, homeDirectory: homeDirectory)
      {
        let blockingRule =
          rules.first {
            !Self.permits([$0], policy: policy, path: childPath, rootPath: rootPath, homeDirectory: homeDirectory)
          } ?? rule
        let package = Self.enclosingPackage(of: childPath, below: rootPath)
        let inApplication = Self.applicationRules.contains(blockingRule.id) && Self.isApplicationName(package)
        throw PlanRejection(
          inApplication ? .containsApplication : .containsProtectedItem,
          path: inApplication ? package : childPath, ruleID: blockingRule.id)
      }
      if child.device != rootDevice { throw PlanRejection(.mountPoint, path: childPath) }
      if child.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0 { throw PlanRejection(.cloudItem, path: childPath) }
      let opaque = Self.isOpaquePackage(path: childPath, identity: child, policy: policy)
      if opaque && details.st_uid != geteuid() { throw PlanRejection(.needsAdministrator, path: childPath) }
      guard opaque ? child.hasOpaquePackageProof : child.hasStableTrashProof else {
        throw PlanRejection(.missingMetadata, path: childPath)
      }
      let entry = ScanEntry(parentID: parentID, path: childPath, identity: child, issues: [], readable: true)
      entries.append(entry)
      if entries.count > limit { throw PlanRejection(.tooManyItems, path: rootPath) }
      switch child.kind {
      case .other:
        guard policy == .spaceTrash || policy == .wholeBundle,
          details.st_mode & S_IFMT == S_IFSOCK || details.st_mode & S_IFMT == S_IFIFO
        else { throw PlanRejection(.specialFile, path: childPath) }
        continue
      case .symbolicLink, .regular: continue
      case .directory:
        if opaque {
          try Self.validateOpaqueRoot(path: childPath, expected: child)
          nested += try Self.observePackage(
            path: childPath, rootPath: rootPath, policy: policy,
            homeDirectory: homeDirectory, includeRootIdentifier: true, isCancelled: isCancelled
          ).applicationIDs
          continue
        }
        try walk(
          path: childPath, parentID: entry.id, identity: child, rootDevice: rootDevice, rootPath: rootPath,
          policy: policy, automaton: automaton, state: childState, entries: &entries, nested: &nested,
          isCancelled: isCancelled)
      }
    }
  }

  struct PackageObservation {
    var applicationIDs: [String] = []
    var imagePaths: [String] = []
  }

  /// Reads directory/code boundaries as observations. Payload files never become
  /// inventory entries or proof for moving or restoring an intact package.
  static func observePackage(
    path: String, rootPath: String, policy: TreePolicy, homeDirectory: String,
    includeRootIdentifier: Bool, isCancelled: @Sendable () -> Bool = { false }
  ) throws(PlanRejection) -> PackageObservation {
    var result = PackageObservation()
    var visited = 0
    let automaton = ProtectionAutomaton(homeDirectory: homeDirectory)
    func visit(
      _ path: String, parentFD: Int32?, name: String?, includeIdentifier: Bool,
      state: ProtectionAutomaton.State, depth: Int, expected: FileIdentity?
    ) throws {
      if isCancelled() { throw PlanRejection(.unavailable, path: path) }
      visited += 1
      guard visited <= 2_000_000, depth < 1024 else { throw PlanRejection(.tooManyItems, path: rootPath) }
      if path.lowercased().hasSuffix(".sparsebundle") { result.imagePaths.append(path) }
      let fd: Int32
      if let parentFD, let name {
        fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      } else {
        fd = DirectoryReader.openDirectory(path)
      }
      guard fd >= 0 else {
        let code = errno
        // A resource-only subtree may be inaccessible while its intact package
        // remains movable. Executable/helper directories remain fail-closed.
        let codeBoundary = [".app", ".bundle", ".framework", ".appex", ".xpc"].contains {
          path.lowercased().hasSuffix($0)
        }
        if code == EACCES || code == EPERM, !codeBoundary,
          path.contains("/Contents/Resources/") || path.hasSuffix("/Contents/Resources")
        {
          return
        }
        throw PlanRejection(.unreadableFolder, path: path, ruleID: "errno:\(code)")
      }
      defer { close(fd) }
      var openedDetails = stat()
      guard fstat(fd, &openedDetails) == 0 else {
        throw PlanRejection(.unreadableFolder, path: path, ruleID: "errno:\(errno)")
      }
      let opened = DescriptorFileSystem.identity(from: openedDetails)
      if let expected, !opened.sameStableDirectory(as: expected) { throw PlanRejection(.changedSinceScan, path: path) }
      if includeIdentifier, Self.isApplicationName(path),
        let id = ApplicationIdentity.bundleIdentifier(ofApplicationAt: path)
      {
        result.applicationIDs.append(id)
      }
      let copy = dup(fd)
      guard copy >= 0, let directory = fdopendir(copy) else {
        let code = errno
        if copy >= 0 { close(copy) }
        throw PlanRejection(.unreadableFolder, path: path, ruleID: "errno:\(code)")
      }
      defer { closedir(directory) }
      var children: [(String, UInt8)] = []
      while true {
        errno = 0
        guard let entry = readdir(directory) else {
          if errno != 0 { throw PlanRejection(.unreadableFolder, path: path, ruleID: "errno:\(errno)") }
          break
        }
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
          $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        if name != "." && name != ".." { children.append((name, entry.pointee.d_type)) }
      }
      for (name, type) in children.sorted(by: { $0.0 < $1.0 }) {
        let childPath = path + "/" + name
        if type != UInt8(DT_LNK), name.lowercased().hasSuffix(".sparseimage") { result.imagePaths.append(childPath) }
        // Most filesystems supply d_type: ordinary payloads need no stat or read.
        guard type == UInt8(DT_DIR) || type == UInt8(DT_UNKNOWN) else { continue }
        var details = stat()
        guard fstatat(fd, name, &details, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
          throw PlanRejection(.changedSinceScan, path: childPath, ruleID: "errno:\(errno)")
        }
        guard details.st_mode & S_IFMT == S_IFDIR else { continue }
        let identity = DescriptorFileSystem.identity(from: details)
        let childState = automaton.step(state, name)
        let rules = automaton.matches(childState, path: childPath, homeDirectory: homeDirectory)
        if let rule = rules.first,
          !Self.permits(
            rules, policy: policy, path: childPath,
            rootPath: rootPath, homeDirectory: homeDirectory)
        {
          let blockingRule =
            rules.first {
              !Self.permits([$0], policy: policy, path: childPath, rootPath: rootPath, homeDirectory: homeDirectory)
            } ?? rule
          throw PlanRejection(.containsProtectedItem, path: childPath, ruleID: blockingRule.id)
        }
        guard identity.device == opened.device else {
          throw PlanRejection(.mountPoint, path: childPath)
        }
        if identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0 { throw PlanRejection(.cloudItem, path: childPath) }
        try visit(
          childPath, parentFD: fd, name: name, includeIdentifier: true, state: childState, depth: depth + 1,
          expected: identity)
      }
      if let parentFD, let name {
        var current = stat()
        guard fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW_ANY) == 0,
          opened.sameStableDirectory(as: DescriptorFileSystem.identity(from: current))
        else {
          throw PlanRejection(.changedSinceScan, path: path)
        }
      }
    }
    do {
      try visit(
        path, parentFD: nil, name: nil, includeIdentifier: includeRootIdentifier,
        state: automaton.state(forPath: path), depth: 0, expected: nil)
    } catch let rejection as PlanRejection { throw rejection } catch { throw PlanRejection(.unavailable, path: path) }
    return result
  }

  static func packageObservations(for item: PlanItem, homeDirectory: String) throws(PlanRejection) -> PackageObservation
  {
    guard let policy = item.policy else { return PackageObservation() }
    var observed = PackageObservation()
    var roots: [String] = []
    for entry in item.inventory {
      guard let identity = entry.identity,
        !roots.contains(where: { entry.path.hasPrefix($0 + "/") }),
        Self.isOpaquePackage(path: entry.path, identity: identity, policy: policy)
      else { continue }
      let current = try Self.observePackage(
        path: entry.path, rootPath: item.sourcePath, policy: policy,
        homeDirectory: homeDirectory, includeRootIdentifier: entry.id != item.id || policy != .wholeBundle)
      observed.applicationIDs += current.applicationIDs
      observed.imagePaths += current.imagePaths
      roots.append(entry.path)
    }
    return observed
  }

  /// The package boundary is observed from the current filesystem, never granted by a cached tree.
  static func isOpaquePackage(path: String, identity: FileIdentity, policy: TreePolicy?) -> Bool {
    policy != nil && identity.kind == .directory && ScanService.isPackage(path)
  }

  static func validateOpaqueRoot(path: String, expected: FileIdentity) throws(PlanRejection) {
    let fd = DirectoryReader.openDirectory(path)
    guard fd >= 0 else { throw PlanRejection(.unreadableFolder, path: path, ruleID: "errno:\(errno)") }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0 else {
      throw PlanRejection(.unreadableFolder, path: path, ruleID: "errno:\(errno)")
    }
    guard details.st_uid == geteuid() else { throw PlanRejection(.needsAdministrator, path: path) }
    guard expected.hasOpaquePackageProof,
      expected.matchesStableTrashIdentity(DescriptorFileSystem.identity(from: details))
    else { throw PlanRejection(.changedSinceScan, path: path) }
  }

  private static func readFailure(_ error: Error, path: String) -> PlanRejection {
    if case FileSystemFailure.systemCall(_, let code) = error {
      return PlanRejection(
        code == EACCES || code == EPERM ? .unreadableFolder : .changedSinceScan,
        path: path, ruleID: "errno:\(code)")
    }
    return PlanRejection(.changedSinceScan, path: path)
  }

  /// The outermost package between the root and a protected application path.
  static func enclosingPackage(of path: String, below root: String) -> String {
    var prefix = root
    for component in path.dropFirst(root.count + 1).split(separator: "/") {
      prefix += "/" + component
      if PackageNames.isPackage(String(component)) { return prefix }
    }
    return path
  }

  static func names(fd: Int32) throws -> [String] {
    let copy = dup(fd)
    guard copy >= 0, let directory = fdopendir(copy) else {
      if copy >= 0 { close(copy) }
      throw FileSystemFailure.systemCall("fdopendir", errno)
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
      errno = 0
      guard let item = readdir(directory) else {
        if errno != 0 { throw FileSystemFailure.systemCall("readdir", errno) }
        break
      }
      let name = withUnsafePointer(to: &item.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name != "." && name != ".." { names.append(name) }
    }
    return names.sorted()
  }
}

extension FileIdentity {
  var hasOpaquePackageProof: Bool {
    kind == .directory && birthSeconds != nil && birthNanoseconds != nil
      && flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
  }
}
