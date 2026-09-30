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

/// Available candidates share one action; unavailable candidates retain their
/// individual reason and path for the confirmation screen.
public struct CatalogPlanOutcome: Sendable {
  public let plan: ActionPlan?
  public let rejections: [PlanRejection]

  public init(plan: ActionPlan?, rejections: [PlanRejection]) {
    self.plan = plan
    self.rejections = rejections
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

  /// Generic app caches and logs are scoped to one app; tool caches share one row root.
  public func activityRoot(for row: CatalogRow, candidatePath: String) -> String {
    row.relativeRoot == "Library/Caches" || row.relativeRoot == "Library/Logs" ? candidatePath : root(for: row)
  }

  /// A display-time filter; it grants no authority to mutate the candidate.
  public func allowsCandidate(path: String, row: CatalogRow, kind: ActionKind = .trash) -> Bool {
    candidateRejection(path: path, row: row, kind: kind) == nil
  }

  /// Eligibility refusals are also available to report-only rows. A new plan
  /// and its execution both perform the same current checks again.
  public func candidateRejection(path: String, row: CatalogRow, kind: ActionKind = .trash) -> PlanRejection? {
    let allowedRoot = root(for: row)
    guard self.row(id: row.id) == row, row.methods.contains(kind),
      path.hasPrefix(allowedRoot + "/"),
      (path as NSString).deletingLastPathComponent == allowedRoot,
      (try? DescriptorFileSystem.validatedComponents(path)) != nil
    else { return PlanRejection(.unavailable, path: path, ruleID: "catalog-scope") }
    if let rule = ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) {
      return PlanRejection(.protectedItem, path: path, ruleID: rule.id)
    }
    if row.relativeRoot == "Library/Caches" {
      let name = (path as NSString).lastPathComponent.lowercased(with: Locale(identifier: "en_US_POSIX"))
      if name.hasPrefix("com.apple.") || Self.appleCacheNames.contains(name) {
        return PlanRejection(.protectedItem, path: path, ruleID: "apple-system-cache")
      }
      if rows.contains(where: {
        $0.id != row.id && (root(for: $0) == path || root(for: $0).hasPrefix(path + "/"))
      }) {
        return PlanRejection(.unavailable, path: path, ruleID: "catalog-overlap")
      }
    }
    if row.minAgeDays > 0 {
      guard let modified = newestContentModification(at: path) else {
        return PlanRejection(.unavailable, path: path, ruleID: "age-unavailable")
      }
      guard Date().timeIntervalSince1970 - Double(modified) >= Double(row.minAgeDays) * 86_400 else {
        return PlanRejection(.unavailable, path: path, ruleID: "minimum-age")
      }
    }
    return nil
  }

  private static let appleCacheNames: Set<String> = [
    "cloudkit", "familycircle", "passkit", "askpermissiond", "gamekit", "siritts", "geoservices", "familycircled",
  ]

  /// Metadata-only, no-follow age evidence. Nonempty folder timestamps do not
  /// stand in for their contents; empty folders and symlinks use their own mtime.
  /// Unknown, protected, changing, cross-volume or over-limit trees stay unavailable.
  func newestContentModification(at path: String, limit: Int = 100_000) -> Int64? {
    guard limit > 0, let root = try? DescriptorFileSystem.identity(at: path) else { return nil }
    var pending: [(path: String, identity: FileIdentity, depth: Int)] = [(path, root, 0)]
    var observed: [String: FileIdentity] = [:]
    var newest: Int64?
    while let current = pending.popLast() {
      guard !Task.isCancelled, current.depth <= 128, observed.count < limit,
        current.identity.device == root.device,
        current.identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
        current.identity.kind != .other,
        ProtectionPolicy.rule(for: current.path, homeDirectory: homeDirectory) == nil,
        let modified = current.identity.modificationSeconds
      else { return nil }
      observed[current.path] = current.identity
      if current.identity.kind == .directory {
        guard let names = try? DescriptorFileSystem.children(at: current.path, expected: current.identity),
          observed.count + pending.count + names.count <= limit
        else { return nil }
        if names.isEmpty { newest = max(newest ?? modified, modified) }
        for name in names {
          let child = current.path + "/" + name
          guard let identity = try? DescriptorFileSystem.identity(at: child) else { return nil }
          pending.append((child, identity, current.depth + 1))
        }
      } else {
        newest = max(newest ?? modified, modified)
      }
    }
    for (path, identity) in observed {
      guard (try? DescriptorFileSystem.identity(at: path)) == identity else { return nil }
    }
    return newest
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

  /// Builds each selected candidate through the strict planner, then combines
  /// only validated, nonoverlapping items. Permanent candidates keep every
  /// strict snapshot, package, protection and method check.
  public func planAvailable(selections: [CatalogSelection], kind: ActionKind = .trash) -> CatalogPlanOutcome {
    var items: [PlanItem] = []
    var rejections: [PlanRejection] = []
    for selection in selections {
      for id in selection.selectedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
        let observedPath =
          selection.snapshot.entries.first(where: { $0.id == id })?.path
          ?? selection.snapshot.rootPath
        do {
          let candidate = try plan(snapshot: selection.snapshot, selectedIDs: [id], rowID: selection.rowID, kind: kind)
          for item in candidate.items {
            guard
              !items.contains(where: {
                $0.id == item.id || $0.sourcePath == item.sourcePath
                  || $0.sourcePath.hasPrefix(item.sourcePath + "/")
                  || item.sourcePath.hasPrefix($0.sourcePath + "/")
              })
            else {
              rejections.append(PlanRejection(.unavailable, path: item.sourcePath, ruleID: "overlapping-selection"))
              continue
            }
            items.append(item)
          }
        } catch let rejected as PlanRejection {
          rejections.append(rejected)
        } catch let rejected as PlanRejections {
          rejections += rejected.rejections
        } catch {
          if let row = row(id: selection.rowID),
            let refusal = candidateRejection(path: observedPath, row: row, kind: kind)
          {
            rejections.append(refusal)
          } else if let failure = error as? PlanFailure, failure == .changedSinceScan {
            rejections.append(PlanRejection(.changedSinceScan, path: observedPath))
          } else if let failure = error as? FileSystemFailure {
            switch failure {
            case .changedDuringInspection:
              rejections.append(PlanRejection(.changedSinceScan, path: observedPath))
            case .systemCall(_, let code) where code == ENOENT || code == ENOTDIR:
              rejections.append(PlanRejection(.changedSinceScan, path: observedPath))
            case .systemCall(_, let code) where code == EACCES || code == EPERM:
              rejections.append(PlanRejection(.unreadableFolder, path: observedPath))
            default:
              rejections.append(PlanRejection(.unavailable, path: observedPath, ruleID: "catalog-unavailable"))
            }
          } else {
            rejections.append(PlanRejection(.unavailable, path: observedPath, ruleID: "catalog-unavailable"))
          }
        }
      }
    }
    guard let runID = selections.first?.snapshot.runID, !items.isEmpty else {
      return CatalogPlanOutcome(plan: nil, rejections: rejections)
    }
    let combined = ActionPlan(snapshotRunID: runID, kind: kind, items: items.sorted { $0.sourcePath < $1.sourcePath })
    var validated: [PlanItem] = []
    for item in combined.items {
      do {
        _ = try validate(item, in: combined)
        validated.append(item)
      } catch {
        if let rowID = item.catalogProof?.rowID, let row = row(id: rowID),
          let refusal = candidateRejection(path: item.sourcePath, row: row, kind: kind)
        {
          rejections.append(refusal)
        } else {
          rejections.append(PlanRejection(.unavailable, path: item.sourcePath, ruleID: "catalog-unavailable"))
        }
      }
    }
    let plan = validated.isEmpty ? nil : ActionPlan(snapshotRunID: runID, kind: kind, items: validated)
    return CatalogPlanOutcome(plan: plan, rejections: rejections)
  }

  private func proof(row: CatalogRow, runID: UUID, kind: ActionKind) -> CatalogProof {
    CatalogProof(version: version, rowID: row.id, allowedRoot: root(for: row), method: kind, snapshotRunID: runID)
  }
}
