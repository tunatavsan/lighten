import Darwin
import Foundation
import Synchronization

/// A user's chosen root. Sizes and warning examples are presentation observations.
public struct UserSelection: Sendable {
  public let path: String
  public let expectedIdentity: FileIdentity?
  public let observedSize: ObservedPlanSize?
  public let warnings: [UserSelectionWarning]

  public init(
    path: String, expectedIdentity: FileIdentity? = nil, observedSize: ObservedPlanSize? = nil,
    warnings: [UserSelectionWarning] = []
  ) {
    self.path = path
    self.expectedIdentity = expectedIdentity
    self.observedSize = observedSize?.validated
    self.warnings = warnings
  }
}

public struct UserSelectionWarning: Codable, Sendable, Equatable {
  public let examplePath: String
  public init(examplePath: String) { self.examplePath = examplePath }
}

extension PlanService {
  /// Captures roots only. Descendant inventories and recommendation proofs are
  /// not conditions for a user choosing an item in the confirmation window.
  public func makeAvailableUserSelectionPlan(
    selections: [UserSelection], kind: ActionKind = .trash, runID: UUID = UUID()
  ) async -> AvailableSpacePlan {
    await Task.detached(priority: .userInitiated) {
      var roots: [UserSelection] = []
      for selection in selections.sorted(by: { $0.path < $1.path })
      where !roots.contains(where: { selection.path == $0.path || selection.path.hasPrefix($0.path + "/") }) {
        roots.append(selection)
      }
      var items: [PlanItem] = []
      var rejections: [PlanRejection] = []
      for selection in roots {
        do {
          try UserSelectionSafety.validateBase(selection.path, homeDirectory: homeDirectory)
          let identity = try UserSelectionFileSystem.identity(at: selection.path)
          if let expected = selection.expectedIdentity,
            !UserSelectionSafety.sameRoot(identity, expected)
          {
            throw PlanRejection(.changedSinceScan, path: selection.path)
          }
          var details = stat()
          guard lstat(selection.path, &details) == 0 else { throw FileSystemFailure.systemCall("lstat", errno) }
          guard details.st_uid == geteuid() else {
            throw PlanRejection(.needsAdministrator, path: selection.path)
          }
          let root = ScanEntry(parentID: nil, path: selection.path, identity: identity, issues: [], readable: true)
          let warning =
            selection.warnings.first
            ?? UserSelectionSafety.warning(for: selection.path, homeDirectory: homeDirectory)
          items.append(
            PlanItem(
              id: root.id, sourcePath: selection.path,
              volumeID: try? DescriptorFileSystem.volumeID(at: selection.path),
              inventory: [root], ancestors: [], snapshotRunID: runID,
              observedSize: selection.observedSize, userSelection: true,
              userSelectionWarnings: warning.map { [$0] }))
        } catch let rejection as PlanRejection { rejections.append(rejection) } catch {
          rejections.append(PlanRejection(.unavailable, path: selection.path, ruleID: String(describing: error)))
        }
      }
      guard !items.isEmpty else { return AvailableSpacePlan(plan: nil, rejections: rejections) }
      let plan = ActionPlan(snapshotRunID: runID, kind: kind, items: items)
      UserSelectionBindings.bind(plan, homeDirectory: homeDirectory)
      return AvailableSpacePlan(plan: plan, rejections: rejections)
    }.value
  }

  /// The confirmation selection replaces prior recommendation authority.
  public func finalizeUserSelection(plan: ActionPlan, kind: ActionKind? = nil) async -> AvailableSpacePlan {
    let outcome = await makeAvailableUserSelectionPlan(
      selections: plan.items.map {
        UserSelection(
          path: $0.sourcePath, expectedIdentity: $0.inventory.first?.identity, observedSize: $0.displaySize,
          warnings: $0.userSelectionWarnings ?? [])
      }, kind: kind ?? plan.kind, runID: plan.snapshotRunID)
    guard let fresh = outcome.plan else { return outcome }
    let items = fresh.items.map { item in
      let id = plan.items.first(where: { $0.sourcePath == item.sourcePath })?.id ?? item.id
      let root = ScanEntry(
        id: id, parentID: nil, path: item.sourcePath, identity: item.inventory.first?.identity,
        issues: [], readable: true)
      return PlanItem(
        id: id, sourcePath: item.sourcePath, volumeID: item.volumeID, inventory: [root], ancestors: [],
        snapshotRunID: item.snapshotRunID, observedSize: item.observedSize, userSelection: true,
        userSelectionWarnings: item.userSelectionWarnings)
    }
    let selected = ActionPlan(
      id: plan.id, snapshotRunID: plan.snapshotRunID, kind: fresh.kind, createdAt: plan.createdAt, items: items)
    UserSelectionBindings.bind(selected, homeDirectory: homeDirectory)
    return AvailableSpacePlan(plan: selected, rejections: outcome.rejections)
  }
}

/// Public journal provenance cannot recreate a private confirmation binding.
enum UserSelectionBindings {
  private struct Binding: Sendable {
    let plan: ActionPlan
    let homeDirectory: String
  }
  private static let plans = Mutex<[UUID: Binding]>([:])

  static func bind(_ plan: ActionPlan, homeDirectory: String) {
    plans.withLock { $0[plan.id] = Binding(plan: plan, homeDirectory: homeDirectory) }
  }

  static func validate(_ plan: ActionPlan, homeDirectory: String) throws {
    guard plans.withLock({ $0[plan.id].map { $0.plan == plan && $0.homeDirectory == homeDirectory } ?? false }),
      !plan.items.isEmpty, plan.items.allSatisfy({ $0.userSelection == true && $0.inventory.count == 1 })
    else { throw ExecutionFailure.invalidPlan }
  }
}

enum UserSelectionSafety {
  static func sameRoot(_ current: FileIdentity, _ expected: FileIdentity) -> Bool {
    current.device == expected.device && current.inode == expected.inode && current.kind == expected.kind
      && (expected.birthSeconds == nil || current.birthSeconds == expected.birthSeconds)
      && (expected.birthNanoseconds == nil || current.birthNanoseconds == expected.birthNanoseconds)
  }

  static func sameReturnedItem(_ current: FileIdentity, _ expected: FileIdentity) -> Bool {
    sameRoot(current, expected) && current.flags == expected.flags
      && current.modificationSeconds == expected.modificationSeconds
      && current.modificationNanoseconds == expected.modificationNanoseconds
      && (current.kind == .directory || current.logicalBytes == expected.logicalBytes)
  }

  static func validateBase(_ path: String, homeDirectory: String) throws {
    let blocked = ["/", "/System", "/Library", "/Users", "/Applications", homeDirectory, homeDirectory + "/Library"]
    let normalized = path == "/" ? path : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let folded = normalized.lowercased(with: Locale(identifier: "en_US_POSIX"))
    if blocked.contains(where: {
      ($0 == "/" ? $0 : $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        .lowercased(with: Locale(identifier: "en_US_POSIX")) == folded
    }) {
      throw PlanRejection(.bulkRoot, path: path)
    }
    _ = try DescriptorFileSystem.validatedComponents(path)
    let selected = try? UserSelectionFileSystem.identity(at: path)
    if selected?.kind == .directory {
      for root in blocked where root != "/" {
        if let selected, let identity = try? UserSelectionFileSystem.identity(at: root),
          sameRoot(selected, identity)
        {
          throw PlanRejection(.bulkRoot, path: path)
        }
      }
    }
    let executable = ProcessInfo.processInfo.arguments.first ?? ""
    let components = executable.split(separator: "/")
    if let app = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
      let package = "/" + components[...app].joined(separator: "/")
      if selected?.kind != .symbolicLink,
        path == package || package.hasPrefix(path + "/") || path.hasPrefix(package + "/")
      {
        throw PlanRejection(.lightenItself, path: path)
      }
      if let selected, selected.kind == .directory {
        var parent = package
        while parent != "/" {
          if let identity = try? UserSelectionFileSystem.identity(at: parent), sameRoot(selected, identity) {
            throw PlanRejection(.lightenItself, path: path)
          }
          parent = (parent as NSString).deletingLastPathComponent
        }
      }
    }
    if selected?.kind == .directory, path.lowercased().hasSuffix(".app"),
      let metadata = try? ApplicationPackagePlanning.metadata(at: path),
      metadata.observation.bundleIdentifier?.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) == .orderedSame
    {
      throw PlanRejection(.lightenItself, path: path)
    }
  }

  static func warning(for path: String, homeDirectory: String) -> UserSelectionWarning? {
    let name = (path as NSString).lastPathComponent.lowercased()
    let sensitive = ["keychains", "mail", "messages", ".ssh"]
    if sensitive.contains(name) || name.hasSuffix(".photoslibrary") || name.hasSuffix(".photolibrary")
      || [".fcpbundle", ".logicx", ".band", ".imovielibrary"].contains(where: name.hasSuffix)
      || ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) != nil
    {
      return UserSelectionWarning(examplePath: path)
    }
    return nil
  }

  static func validateRoot(_ item: PlanItem, homeDirectory: String) throws {
    try validateBase(item.sourcePath, homeDirectory: homeDirectory)
    guard item.userSelection == true, item.inventory.count == 1,
      let expected = item.inventory.first?.identity,
      sameRoot(try UserSelectionFileSystem.identity(at: item.sourcePath), expected)
    else { throw GuardFailure.changedItem }
    var details = stat()
    guard lstat(item.sourcePath, &details) == 0 else { throw FileSystemFailure.systemCall("lstat", errno) }
    guard details.st_uid == geteuid() else { throw PlanRejection(.needsAdministrator, path: item.sourcePath) }
    if let volumeID = item.volumeID,
      (try? DescriptorFileSystem.volumeID(at: item.sourcePath)) != volumeID
    {
      throw PlanRejection(.differentVolume, path: item.sourcePath)
    }
  }
}

enum UserSelectionFileSystem {
  static func identity(at path: String) throws -> FileIdentity { try KnownPathFileSystem.identity(at: path) }
  static func openParent(of path: String) throws -> (Int32, String) {
    _ = try DescriptorFileSystem.validatedComponents(path)
    let parent = (path as NSString).deletingLastPathComponent
    let fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open", errno) }
    return (fd, (path as NSString).lastPathComponent)
  }
}
