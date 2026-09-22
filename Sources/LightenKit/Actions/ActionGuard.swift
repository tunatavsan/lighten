import Darwin
import Foundation

public enum GuardFailure: Error, Codable, Sendable, Equatable {
  case changedAncestor, changedItem, changedInventory, protectedItem, unsupportedItem
}

public struct ActionGuard: Sendable {
  public let homeDirectory: String

  public init(homeDirectory: String = NSHomeDirectory()) {
    self.homeDirectory = homeDirectory
  }

  public func validate(_ item: PlanItem) throws {
    guard let root = item.inventory.first, root.id == item.id,
      root.path == item.sourcePath,
      root.identity?.kind == .regular || root.identity?.kind == .directory,
      !PlanService.isBulkRoot(item.sourcePath, homeDirectory: homeDirectory),
      !ScanService.isPackage(item.sourcePath),
      !ScanService.isInsidePackage(item.sourcePath),
      let volumeID = item.volumeID,
      (try? DescriptorFileSystem.volumeID(at: item.sourcePath)) == volumeID
    else { throw GuardFailure.unsupportedItem }
    let components: [String]
    do { components = try DescriptorFileSystem.validatedComponents(item.sourcePath) } catch {
      throw GuardFailure.changedAncestor
    }
    var prefix = ""
    let expectedAncestorPaths = components.dropLast().map { component in
      prefix += "/" + component
      return prefix
    }
    guard item.ancestors.map(\.path) == expectedAncestorPaths else {
      throw GuardFailure.changedAncestor
    }
    for ancestor in item.ancestors {
      let current: FileIdentity
      do { current = try DescriptorFileSystem.identity(at: ancestor.path) } catch { throw GuardFailure.changedAncestor }
      guard current.sameStableDirectory(as: ancestor.identity),
        ProtectionPolicy.rule(for: ancestor.path, homeDirectory: homeDirectory) == nil
      else {
        throw GuardFailure.changedAncestor
      }
    }
    let knownPaths = Set(item.inventory.map(\.path))
    let entriesByID = Dictionary(item.inventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let childrenByParent = Dictionary(
      grouping: item.inventory.dropFirst().compactMap { entry -> (UUID, String)? in
        guard let parentID = entry.parentID else { return nil }
        return (parentID, (entry.path as NSString).lastPathComponent)
      }, by: { $0.0 })
    guard item.inventory.first?.path == item.sourcePath,
      knownPaths.count == item.inventory.count,
      entriesByID.count == item.inventory.count
    else { throw GuardFailure.changedInventory }
    for entry in item.inventory {
      if let parentID = entry.parentID, entry.id != item.id {
        guard let parent = entriesByID[parentID],
          entry.path == parent.path + "/" + (entry.path as NSString).lastPathComponent
        else { throw GuardFailure.changedInventory }
      }
      guard let expected = entry.identity, expected.hasStableTrashProof,
        entry.issues.isEmpty, entry.readable
      else {
        throw GuardFailure.unsupportedItem
      }
      if ProtectionPolicy.rule(for: entry.path, homeDirectory: homeDirectory) != nil {
        throw GuardFailure.protectedItem
      }
      if ScanService.isPackage(entry.path) || ScanService.isInsidePackage(entry.path)
        || expected.device != root.identity?.device
        || expected.kind == .symbolicLink || expected.kind == .other
        || expected.flags & UInt32(SF_DATALESS | UF_DATAVAULT) != 0
      {
        throw GuardFailure.unsupportedItem
      }
      let current: FileIdentity
      do { current = try DescriptorFileSystem.identity(at: entry.path) } catch { throw GuardFailure.changedItem }
      guard current == expected else { throw GuardFailure.changedItem }
      if expected.kind == .directory {
        let names: [String]
        do { names = try DescriptorFileSystem.children(at: entry.path, expected: expected) } catch {
          throw GuardFailure.changedInventory
        }
        let planned = (childrenByParent[entry.id] ?? []).map(\.1).sorted()
        guard names == planned else { throw GuardFailure.changedInventory }
      }
    }
  }
}

extension FileIdentity {
  /// Moving one sibling changes its parent's ctime and sometimes its size.
  /// Stable ancestry still requires the same volume, inode, directory kind,
  /// and file flags; selected roots and descendants use full equality.
  func sameStableDirectory(as other: FileIdentity) -> Bool {
    device == other.device && inode == other.inode && kind == .directory
      && other.kind == .directory && flags == other.flags
      && flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
  }
}
