import Darwin
import Foundation

public struct CatalogRow: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let relativeRoot: String
  public let removal: String
  public let `class`: String
  public let activity: [String]
  public let methods: [ActionKind]
  public let defaultSelected: Bool
  public let minAgeDays: Int
  public let titleEN: String
  public let titleTR: String
  public let reasonEN: String
  public let reasonTR: String
  public let costEN: String
  public let costTR: String
  public let evidenceURL: String
  public let ruleSource: String
  public let verifiedOn: String

  public func title(turkish: Bool) -> String { turkish ? titleTR : titleEN }
  public func reason(turkish: Bool) -> String { turkish ? reasonTR : reasonEN }
  public func cost(turkish: Bool) -> String { turkish ? costTR : costEN }
}

private struct CatalogDocument: Codable {
  let version: Int
  let rows: [CatalogRow]
}

enum CatalogResourceLocator {
  enum MetadataState {
    case regular, absent, unsafe
  }

  static func metadataState(at path: String) -> MetadataState {
    do {
      let identity = try DescriptorFileSystem.identity(at: path)
      return identity.kind == .regular && identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
        ? .regular : .unsafe
    } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
      return .absent
    } catch {
      return .unsafe
    }
  }

  /// Only the trusted resource bundle root is canonicalized. The catalog and
  /// every component below it still pass descriptor-relative no-follow checks.
  static func canonicalRoot(_ url: URL) -> URL? {
    guard let resolved = realpath(url.path, nil) else { return nil }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
  }

  static func url(
    mainBundleURL: URL, mainResourceURL: URL?, moduleURL: URL?,
    probe: (String) -> MetadataState = metadataState(at:)
  ) -> URL? {
    if mainBundleURL.pathExtension == "app" {
      guard let mainResourceURL,
        mainResourceURL.path == mainBundleURL.appendingPathComponent("Contents/Resources").path,
        let app = canonicalRoot(mainBundleURL)
      else { return nil }
      let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
      let unresolved = resources.appendingPathComponent("Lighten_LightenKit.bundle", isDirectory: true)
      guard let bundle = canonicalRoot(unresolved), bundle.path.hasPrefix(resources.path + "/")
      else { return nil }
      let info = bundle.appendingPathComponent("Contents/Info.plist")
      let catalog: URL
      switch probe(info.path) {
      case .regular: catalog = bundle.appendingPathComponent("Contents/Resources/catalog.json")
      case .absent: catalog = bundle.appendingPathComponent("catalog.json")
      case .unsafe: return nil
      }
      return probe(catalog.path) == .regular ? catalog : nil
    }
    guard let moduleURL else { return nil }
    var trustedRoot = moduleURL.deletingLastPathComponent()
    var cursor = trustedRoot
    while cursor.path != "/" {
      if cursor.pathExtension == "bundle" {
        trustedRoot = cursor
        break
      }
      cursor.deleteLastPathComponent()
    }
    guard let bundle = canonicalRoot(trustedRoot),
      moduleURL.path.hasPrefix(trustedRoot.path + "/")
    else { return nil }
    let relative = String(moduleURL.path.dropFirst(trustedRoot.path.count + 1))
    let catalog = bundle.appendingPathComponent(relative)
    guard catalog.path.hasPrefix(bundle.path + "/") else { return nil }
    return probe(catalog.path) == .regular ? catalog : nil
  }
}

public struct CatalogProof: Codable, Sendable, Equatable {
  public let version: Int
  public let rowID: String
  public let allowedRoot: String
  public let method: ActionKind
  public let snapshotRunID: UUID

  public init(version: Int, rowID: String, allowedRoot: String, method: ActionKind, snapshotRunID: UUID) {
    self.version = version
    self.rowID = rowID
    self.allowedRoot = allowedRoot
    self.method = method
    self.snapshotRunID = snapshotRunID
  }
}

public struct CatalogSelection: Sendable {
  public let snapshot: ScanSnapshot
  public let selectedIDs: Set<UUID>
  public let rowID: String

  public init(snapshot: ScanSnapshot, selectedIDs: Set<UUID>, rowID: String) {
    self.snapshot = snapshot
    self.selectedIDs = selectedIDs
    self.rowID = rowID
  }
}

public enum CatalogFailure: Error, Sendable {
  case invalidManifest, unauthorizedPath, invalidProof, unavailable
  case resourceFailure(stage: String, code: Int32)
}

public struct CleanCatalog: Sendable {
  public let homeDirectory: String
  public let rows: [CatalogRow]
  public let version: Int

  public init(homeDirectory: String = NSHomeDirectory()) throws {
    let packaged = Bundle.main.bundleURL.pathExtension == "app"
    let moduleURL = packaged ? nil : Bundle.module.url(forResource: "catalog", withExtension: "json")
    var lookupFailure: CatalogFailure?
    guard
      let url = CatalogResourceLocator.url(
        mainBundleURL: Bundle.main.bundleURL, mainResourceURL: Bundle.main.resourceURL, moduleURL: moduleURL,
        probe: { path in
          do {
            let identity = try DescriptorFileSystem.identity(at: path)
            guard identity.kind == .regular && identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0 else {
              lookupFailure = .resourceFailure(stage: "validate catalog resource", code: EINVAL)
              return .unsafe
            }
            return .regular
          } catch FileSystemFailure.systemCall(let stage, let code) {
            lookupFailure = .resourceFailure(stage: stage, code: code)
            return code == ENOENT ? .absent : .unsafe
          } catch {
            lookupFailure = .resourceFailure(stage: "validate catalog path", code: EINVAL)
            return .unsafe
          }
        })
    else { throw lookupFailure ?? CatalogFailure.resourceFailure(stage: "locate catalog bundle", code: errno) }
    let data: Data
    do {
      guard let contents = try SecureMetadataFile.read(path: url.path, limit: 128 * 1024, ownerOnly: false)
      else { throw CatalogFailure.resourceFailure(stage: "read catalog", code: ENOENT) }
      data = contents
    } catch FileSystemFailure.systemCall(let stage, let code) {
      throw CatalogFailure.resourceFailure(stage: stage, code: code)
    }
    try self.init(data: data, homeDirectory: homeDirectory)
  }

  /// A manifest is validated independently of row identifiers and row count.
  public init(data: Data, homeDirectory: String = NSHomeDirectory()) throws {
    _ = try DescriptorFileSystem.validatedComponents(homeDirectory)
    guard let document = try? JSONDecoder().decode(CatalogDocument.self, from: data),
      document.version == 2, !document.rows.isEmpty,
      Set(document.rows.map(\.id)).count == document.rows.count,
      Set(document.rows.map(\.relativeRoot)).count == document.rows.count
    else { throw CatalogFailure.invalidManifest }
    for row in document.rows {
      let root = homeDirectory + "/" + row.relativeRoot
      guard !row.id.isEmpty, !row.relativeRoot.hasPrefix("/"),
        (try? DescriptorFileSystem.validatedComponents(root)) != nil,
        !ExactInventory(homeDirectory: homeDirectory).isBulkRoot(root),
        ProtectionPolicy.rule(for: root, homeDirectory: homeDirectory) == nil,
        ["regenerableCache", "buildOutput", "userDataRisk"].contains(row.class),
        ["delete", "reportOnly"].contains(row.removal),
        Set(row.methods).count == row.methods.count,
        row.class != "userDataRisk" || (row.removal == "reportOnly" && row.methods.isEmpty),
        row.removal != "reportOnly" || (row.methods.isEmpty && !row.defaultSelected),
        row.removal != "delete" || !row.methods.isEmpty,
        row.class != "buildOutput" || row.methods == [.trash],
        row.minAgeDays >= 0 && row.minAgeDays <= 3650,
        row.activity.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") }),
        !row.titleEN.isEmpty && !row.titleTR.isEmpty,
        !row.reasonEN.isEmpty && !row.reasonTR.isEmpty,
        !row.costEN.isEmpty && !row.costTR.isEmpty,
        !row.ruleSource.isEmpty && !row.verifiedOn.isEmpty,
        let evidence = URL(string: row.evidenceURL), evidence.scheme == "https", evidence.host != nil
      else { throw CatalogFailure.invalidManifest }
    }
    self.homeDirectory = homeDirectory
    self.rows = document.rows
    self.version = document.version
  }

  public func root(for row: CatalogRow) -> String { homeDirectory + "/" + row.relativeRoot }
  public func row(id: String) -> CatalogRow? { rows.first { $0.id == id } }

  /// Generic app caches are scoped to a single app; tool caches share one row root.
  public func activityRoot(for row: CatalogRow, candidatePath: String) -> String {
    row.relativeRoot == "Library/Caches" ? candidatePath : root(for: row)
  }

  /// A display-time filter; it grants no authority to mutate the candidate.
  public func allowsCandidate(path: String, row: CatalogRow, kind: ActionKind = .trash) -> Bool {
    let allowedRoot = root(for: row)
    guard self.row(id: row.id) == row, row.methods.contains(kind),
      path.hasPrefix(allowedRoot + "/"),
      (path as NSString).deletingLastPathComponent == allowedRoot,
      (try? DescriptorFileSystem.validatedComponents(path)) != nil,
      ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) == nil
    else { return false }
    if row.relativeRoot == "Library/Caches" {
      let name = (path as NSString).lastPathComponent.lowercased()
      if name.hasPrefix("com.apple.") { return false }
      if rows.contains(where: {
        $0.id != row.id && (root(for: $0) == path || root(for: $0).hasPrefix(path + "/"))
      }) {
        return false
      }
    }
    if row.minAgeDays > 0 {
      guard let identity = try? DescriptorFileSystem.identity(at: path),
        let modified = identity.modificationSeconds,
        Date().timeIntervalSince1970 - Double(modified) >= Double(row.minAgeDays) * 86_400
      else { return false }
    }
    return true
  }

  public func validate(_ item: PlanItem, in plan: ActionPlan) throws -> CatalogRow {
    guard plan.kind == .catalogDelete || plan.kind == .trash, let proof = item.catalogProof,
      proof.method == plan.kind, proof.version == version,
      proof.snapshotRunID == (item.snapshotRunID ?? plan.snapshotRunID),
      let row = row(id: proof.rowID), proof.allowedRoot == root(for: row),
      allowsCandidate(path: item.sourcePath, row: row, kind: plan.kind),
      plan.kind == .trash
        ? item.policy == (row.class == "buildOutput" ? .catalogBuildOutput : .catalogTrash)
          || item.policy == nil
        : item.policy == nil
    else { throw CatalogFailure.invalidProof }
    return row
  }

  public func plan(
    snapshot: ScanSnapshot, selectedIDs: Set<UUID>, rowID: String,
    kind: ActionKind = .catalogDelete
  ) throws -> ActionPlan {
    try plan(selections: [CatalogSelection(snapshot: snapshot, selectedIDs: selectedIDs, rowID: rowID)], kind: kind)
  }

  public func plan(selections: [CatalogSelection], kind: ActionKind = .trash) throws -> ActionPlan {
    guard let first = selections.first, selections.contains(where: { !$0.selectedIDs.isEmpty })
    else { throw PlanFailure.emptySelection }
    var items: [PlanItem] = []
    for selection in selections where !selection.selectedIDs.isEmpty {
      let snapshot = selection.snapshot
      guard snapshot.schema == 1, let row = row(id: selection.rowID),
        snapshot.rootPath == root(for: row), row.methods.contains(kind)
      else { throw CatalogFailure.unauthorizedPath }
      if kind == .catalogDelete {
        let base = try PlanService(homeDirectory: homeDirectory).makePlan(
          snapshot: snapshot, selectedIDs: selection.selectedIDs, kind: kind)
        for item in base.items {
          items.append(
            PlanItem(
              id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
              inventory: item.inventory, ancestors: item.ancestors,
              catalogProof: proof(row: row, runID: snapshot.runID, kind: kind), snapshotRunID: snapshot.runID))
        }
      } else {
        for id in selection.selectedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
          guard let observed = snapshot.entries.first(where: { $0.id == id }),
            let identity = observed.identity, identity.device == snapshot.volumeDevice,
            allowsCandidate(path: observed.path, row: row, kind: kind)
          else { throw CatalogFailure.unauthorizedPath }
          let policy: TreePolicy = row.class == "buildOutput" ? .catalogBuildOutput : .catalogTrash
          let current = try ExactInventory(homeDirectory: homeDirectory).collect(
            rootPath: observed.path, expected: (identity.device, identity.inode), policy: policy)
          guard current.volumeID == snapshot.volumeID else { throw PlanFailure.changedSinceScan }
          let exactRootID = current.entries[0].id
          let entries = current.entries.map { entry in
            ScanEntry(
              id: entry.id == exactRootID ? observed.id : entry.id,
              parentID: entry.parentID == exactRootID ? observed.id : entry.parentID,
              path: entry.path, identity: entry.identity, issues: entry.issues, readable: entry.readable)
          }
          items.append(
            PlanItem(
              id: observed.id, sourcePath: observed.path, volumeID: current.volumeID,
              inventory: entries, ancestors: current.ancestors,
              catalogProof: proof(row: row, runID: snapshot.runID, kind: kind), policy: current.policy,
              nestedApplicationIDs: current.nestedApplicationIDs, snapshotRunID: snapshot.runID))
        }
      }
    }
    let sorted = items.sorted { $0.sourcePath < $1.sourcePath }
    guard
      !sorted.enumerated().contains(where: { index, item in
        sorted.dropFirst(index + 1).contains {
          $0.sourcePath == item.sourcePath || $0.sourcePath.hasPrefix(item.sourcePath + "/")
        }
      })
    else { throw CatalogFailure.unauthorizedPath }
    let plan = ActionPlan(snapshotRunID: first.snapshot.runID, kind: kind, items: sorted)
    for item in sorted { _ = try validate(item, in: plan) }
    return plan
  }

  private func proof(row: CatalogRow, runID: UUID, kind: ActionKind) -> CatalogProof {
    CatalogProof(version: version, rowID: row.id, allowedRoot: root(for: row), method: kind, snapshotRunID: runID)
  }
}
