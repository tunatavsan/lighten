import Darwin
import Foundation

/// How a Trash plan treats its descendants. `nil` on a plan item keeps the
/// original strict rules, including for journal records written before this field.
public enum TreePolicy: String, Codable, Sendable {
  /// Space selection: symlinks move as leaves, packages without protected contents move with their folder.
  case spaceTrash
  /// A whole package selected as the operation root. The application-slice and
  /// localization rules do not apply beneath that root; every other rule does.
  case wholeBundle
  /// Catalog cache packages and symbolic links, authorized only by a Trash proof.
  case catalogTrash
  /// Regenerable build output also permits debug symbols below the selected root.
  case catalogBuildOutput
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

  static func permits(_ rules: [NeverRule], policy: TreePolicy) -> Bool {
    let exemptions: Set<String>
    switch policy {
    case .spaceTrash: exemptions = []
    case .wholeBundle, .catalogTrash: exemptions = applicationRules
    case .catalogBuildOutput: exemptions = applicationRules.union(["xcode-debug-symbols"])
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
    path.lowercased(with: Locale(identifier: "en_US_POSIX")).hasSuffix(".app")
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
    if ScanService.isInsidePackage(rootPath) { throw PlanRejection(.insidePackage, path: rootPath) }
    if let rule = ProtectionPolicy.rule(for: rootPath, homeDirectory: homeDirectory) {
      throw PlanRejection(.protectedItem, path: rootPath, ruleID: rule.id)
    }
    let root: FileIdentity
    do { root = try DescriptorFileSystem.identity(at: rootPath) } catch {
      throw PlanRejection(.changedSinceScan, path: rootPath)
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
    guard root.hasStableTrashProof else { throw PlanRejection(.missingMetadata, path: rootPath) }
    if root.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0 { throw PlanRejection(.cloudItem, path: rootPath) }
    guard let volumeID = try? DescriptorFileSystem.volumeID(at: rootPath) else {
      throw PlanRejection(.differentVolume, path: rootPath)
    }
    let parent = (rootPath as NSString).deletingLastPathComponent
    if access(parent, W_OK) != 0 || (root.kind == .directory && access(rootPath, W_OK) != 0) {
      var details = stat()
      let owned = lstat(rootPath, &details) == 0 && details.st_uid == geteuid()
      throw PlanRejection(owned ? .userPermissionDenied : .needsAdministrator, path: rootPath)
    }
    let ancestors: [PathIdentity]
    do { ancestors = try DescriptorFileSystem.ancestorIdentities(of: rootPath) } catch {
      throw PlanRejection(.changedSinceScan, path: rootPath)
    }
    // Catalog Trash permissions come from a later manifest-proof validation.
    let wholeBundle = root.kind == .directory && Self.isApplicationName(rootPath)
    let policy: TreePolicy = requestedPolicy ?? (wholeBundle ? .wholeBundle : .spaceTrash)
    var nested: [String] = []
    if (policy == .catalogTrash || policy == .catalogBuildOutput) && wholeBundle {
      guard let id = ApplicationIdentity.bundleIdentifier(ofApplicationAt: rootPath) else {
        throw PlanRejection(.missingMetadata, path: rootPath)
      }
      nested.append(id)
    }
    let rootEntry = ScanEntry(parentID: nil, path: rootPath, identity: root, issues: [], readable: true)
    var entries = [rootEntry]
    if root.kind == .directory {
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
      let childState = automaton.step(state, name)
      let rules = automaton.matches(childState, path: childPath, homeDirectory: homeDirectory)
      if let rule = rules.first,
        !Self.permits(rules, policy: policy)
      {
        let package = Self.enclosingPackage(of: childPath, below: rootPath)
        let inApplication = Self.applicationRules.contains(rule.id) && Self.isApplicationName(package)
        throw PlanRejection(
          inApplication ? .containsApplication : .containsProtectedItem,
          path: inApplication ? package : childPath, ruleID: rule.id)
      }
      if child.device != rootDevice { throw PlanRejection(.mountPoint, path: childPath) }
      if child.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0 { throw PlanRejection(.cloudItem, path: childPath) }
      guard child.hasStableTrashProof else { throw PlanRejection(.missingMetadata, path: childPath) }
      let entry = ScanEntry(parentID: parentID, path: childPath, identity: child, issues: [], readable: true)
      entries.append(entry)
      if entries.count > limit { throw PlanRejection(.tooManyItems, path: rootPath) }
      switch child.kind {
      case .other: throw PlanRejection(.specialFile, path: childPath)
      case .symbolicLink, .regular: continue
      case .directory:
        if policy != .spaceTrash, Self.isApplicationName(name) {
          // A nested app (a helper or bundled tool) must also be closed before the move.
          guard let id = ApplicationIdentity.bundleIdentifier(ofApplicationAt: childPath) else {
            throw PlanRejection(.missingMetadata, path: childPath)
          }
          nested.append(id)
        }
        try walk(
          path: childPath, parentID: entry.id, identity: child, rootDevice: rootDevice, rootPath: rootPath,
          policy: policy, automaton: automaton, state: childState, entries: &entries, nested: &nested,
          isCancelled: isCancelled)
      }
    }
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
