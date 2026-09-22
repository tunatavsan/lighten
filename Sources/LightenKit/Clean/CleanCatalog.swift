import Foundation

public struct CatalogRow: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let relativeRoot: String
  public let removal: String
  public let `class`: String
  public let activity: String
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
  static func url(
    mainBundleURL: URL, mainResourceURL: URL?, moduleURL: URL?
  ) -> URL? {
    if mainBundleURL.pathExtension == "app" {
      return mainResourceURL?
        .appendingPathComponent("Lighten_LightenKit.bundle", isDirectory: true)
        .appendingPathComponent("catalog.json")
    }
    return moduleURL
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

public enum CatalogFailure: Error, Sendable {
  case invalidManifest, unauthorizedPath, invalidProof, unavailable
}

public struct CleanCatalog: Sendable {
  public let homeDirectory: String
  public let rows: [CatalogRow]
  public let version: Int

  public init(homeDirectory: String = NSHomeDirectory()) throws {
    let packaged = Bundle.main.bundleURL.pathExtension == "app"
    let moduleURL = packaged ? nil : Bundle.module.url(forResource: "catalog", withExtension: "json")
    let url = CatalogResourceLocator.url(
      mainBundleURL: Bundle.main.bundleURL,
      mainResourceURL: Bundle.main.resourceURL,
      moduleURL: moduleURL)
    guard let url,
      let data = try? SecureMetadataFile.read(
        path: url.path,
        limit: 64 * 1024, ownerOnly: false),
      let document = try? JSONDecoder().decode(CatalogDocument.self, from: data),
      document.version == 1, document.rows.count == 3,
      Set(document.rows.map(\.id)).count == document.rows.count
    else { throw CatalogFailure.invalidManifest }
    let expected: [String: (String, String)] = [
      "pip-http-v2": ("Library/Caches/pip/http-v2", "pip"),
      "pip-wheels": ("Library/Caches/pip/wheels", "pip"),
      "homebrew-downloads": ("Library/Caches/Homebrew/downloads", "homebrew"),
    ]
    guard
      document.rows.allSatisfy({ row in
        guard let entry = expected[row.id] else { return false }
        return row.relativeRoot == entry.0 && row.activity == entry.1
          && row.removal == "delete" && row.class == "regenerableCache"
          && !row.titleEN.isEmpty && !row.titleTR.isEmpty
          && !row.reasonEN.isEmpty && !row.reasonTR.isEmpty
          && !row.costEN.isEmpty && !row.costTR.isEmpty
          && !row.ruleSource.isEmpty && !row.verifiedOn.isEmpty
          && URL(string: row.evidenceURL)?.scheme == "https"
      })
    else { throw CatalogFailure.invalidManifest }
    _ = try DescriptorFileSystem.validatedComponents(homeDirectory)
    self.homeDirectory = homeDirectory
    self.rows = document.rows
    self.version = document.version
  }

  public func root(for row: CatalogRow) -> String {
    homeDirectory + "/" + row.relativeRoot
  }

  public func row(id: String) -> CatalogRow? { rows.first { $0.id == id } }

  public func validate(_ item: PlanItem, in plan: ActionPlan) throws -> CatalogRow {
    guard plan.kind == .catalogDelete || plan.kind == .trash, let proof = item.catalogProof,
      proof.method == plan.kind, proof.version == version,
      proof.snapshotRunID == plan.snapshotRunID,
      let row = row(id: proof.rowID),
      proof.allowedRoot == root(for: row),
      item.sourcePath.hasPrefix(proof.allowedRoot + "/"),
      try DescriptorFileSystem.validatedComponents(item.sourcePath).count
        == DescriptorFileSystem.validatedComponents(proof.allowedRoot).count + 1,
      ProtectionPolicy.rule(for: item.sourcePath, homeDirectory: homeDirectory) == nil
    else { throw CatalogFailure.invalidProof }
    return row
  }

  public func plan(
    snapshot: ScanSnapshot, selectedIDs: Set<UUID>, rowID: String,
    kind: ActionKind = .catalogDelete
  ) throws -> ActionPlan {
    guard kind == .trash || kind == .catalogDelete,
      let row = row(id: rowID), snapshot.rootPath == root(for: row)
    else {
      throw CatalogFailure.unauthorizedPath
    }
    let base = try PlanService(homeDirectory: homeDirectory).makePlan(
      snapshot: snapshot, selectedIDs: selectedIDs, kind: kind)
    let items = base.items.map { item in
      PlanItem(
        id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
        inventory: item.inventory, ancestors: item.ancestors,
        catalogProof: CatalogProof(
          version: version, rowID: row.id, allowedRoot: root(for: row),
          method: kind, snapshotRunID: snapshot.runID))
    }
    let plan = ActionPlan(
      id: base.id, snapshotRunID: base.snapshotRunID, kind: kind,
      createdAt: base.createdAt, items: items)
    for item in items { _ = try validate(item, in: plan) }
    return plan
  }
}
