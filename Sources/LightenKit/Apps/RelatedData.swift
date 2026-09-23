import Darwin
import Foundation

public struct InstalledApplication: Sendable, Equatable {
  public let bundleID: String
  public let path: String
  public let version: String?
  /// Set when `path` is a symbolic link; the app lives at this resolved location.
  /// A linked app is identified read-only and never followed for an action.
  public var linkTarget: String? = nil
}

public struct BundleInventory: Sendable {
  public let applications: [InstalledApplication]
  public let unidentifiedPaths: [String]
  public let complete: Bool
  public let observedAt: Date

  public func contains(_ bundleID: String) -> Bool {
    applications.contains { foldedAppID($0.bundleID) == foldedAppID(bundleID) }
  }
}

private func foldedAppID(_ value: String) -> String {
  value.lowercased(with: Locale(identifier: "en_US_POSIX"))
}

public enum RelatedClassification: String, Sendable {
  case installed, historicallyVerifiedAbsent, uncertain, protected, shared
}

public enum RelatedReason: String, Sendable {
  case candidateAreaUnreadable, recordUnsafe, protected, installed
  case incompleteInventory, recordUnavailable, historicallyVerified, nameOnly
  case sharedGroup, installedElsewhere
}

public struct RelatedDataCandidate: Sendable, Identifiable {
  public let id: String
  public let path: String
  public let classification: RelatedClassification
  public let reason: RelatedReason
  public let snapshot: ScanSnapshot?
  public let receipt: RelatedReceipt?
}

public struct RelatedReceipt: Codable, Sendable, Equatable {
  public let schema: Int
  public let bundleID: String
  public let appPath: String
  public let relatedPath: String
  public let identity: FileIdentity
  public let observedAt: Date
  public let ruleSource: String
}

public struct RelatedProof: Codable, Sendable, Equatable {
  public let bundleID: String
  public let relatedPath: String
  public let identity: FileIdentity
  public let receiptObservedAt: Date
  public let snapshotRunID: UUID
}

public struct InstalledRelatedProof: Codable, Sendable, Equatable {
  public let bundleID: String
  public let appPath: String
  public let appIdentity: FileIdentity
  public let infoIdentity: FileIdentity
  public let relatedPath: String
  public let relatedIdentity: FileIdentity
  public let snapshotRunID: UUID
}

public enum RelatedFailure: Error, Sendable {
  case incompleteInventory, invalidReceipt, ownerPresent, changedItem, runningOrUnknown
  case ambiguousOwner, unsupportedInstalledData
}

public protocol RunningApplicationSource: Sendable {
  func isRunning(bundleID: String) async -> Bool?
}

public struct UnknownRunningApplicationSource: RunningApplicationSource {
  public init() {}
  public func isRunning(bundleID: String) async -> Bool? { nil }
}

public struct RelatedDataService: Sendable {
  public let homeDirectory: String
  private let applicationRoots: [String]
  /// Whether the system knows an app with this bundle ID anywhere outside the
  /// Trash. A known app elsewhere keeps its data from being called a leftover.
  private let installedElsewhere: @Sendable (String) -> Bool

  public init(
    homeDirectory: String = NSHomeDirectory(),
    installedElsewhere: @escaping @Sendable (String) -> Bool = { _ in false }
  ) {
    self.homeDirectory = homeDirectory
    self.applicationRoots = ["/Applications", homeDirectory + "/Applications"]
    self.installedElsewhere = installedElsewhere
  }

  init(
    homeDirectory: String, applicationRoots: [String],
    installedElsewhere: @escaping @Sendable (String) -> Bool = { _ in false }
  ) {
    self.homeDirectory = homeDirectory
    self.applicationRoots = applicationRoots
    self.installedElsewhere = installedElsewhere
  }

  public func inventory() -> BundleInventory {
    var apps: [InstalledApplication] = []
    var unidentifiedPaths: [String] = []
    var complete = true
    var visited = 0

    func visit(_ root: String, depth: Int, volumeID: UUID?) {
      guard depth <= 4, visited < 10_000,
        let identity = try? DescriptorFileSystem.identity(at: root),
        identity.kind == .directory,
        let currentVolume = try? DescriptorFileSystem.volumeID(at: root),
        currentVolume == volumeID,
        ProtectionPolicy.rule(for: root, homeDirectory: homeDirectory) == nil
      else {
        complete = false
        return
      }
      let names: [String]
      do { names = try DescriptorFileSystem.children(at: root, expected: identity) } catch {
        complete = false
        return
      }
      for name in names {
        visited += 1
        if visited > 10_000 {
          complete = false
          return
        }
        let path = root + "/" + name
        guard let child = try? DescriptorFileSystem.identity(at: path),
          child.device == identity.device,
          child.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
          ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) == nil
        else {
          complete = false
          continue
        }
        if child.kind == .symbolicLink {
          // Resolve read-only: the link's target identifies an app, never an action path.
          if let linked = Self.resolveLinkedApplication(at: path) {
            apps.append(linked)
          } else if !Self.linksToPlainFile(path) {
            // A link to a folder may hide apps that are never followed.
            complete = false
          }
          continue
        }
        guard child.kind == .directory else { continue }
        if name.lowercased(with: Locale(identifier: "en_US_POSIX")).hasSuffix(".app") {
          let metadataPath = Self.infoPlistPath(ofBundleAt: path)
          guard
            let data = try? SecureMetadataFile.read(
              path: metadataPath,
              limit: 1024 * 1024, ownerOnly: false),
            (try? DescriptorFileSystem.identity(at: path)) == child,
            (try? DescriptorFileSystem.volumeID(at: metadataPath)) == volumeID,
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any]
          else {
            complete = false
            unidentifiedPaths.append(path)
            continue
          }
          guard let bundleID = dict["CFBundleIdentifier"] as? String, Self.validBundleID(bundleID) else {
            // A readable bundle that declares no identifier cannot own a data
            // folder named by one, and receipts come only from identified apps,
            // so it is listed without making the inventory incomplete.
            if dict["CFBundleIdentifier"] == nil {
              unidentifiedPaths.append(path)
            } else {
              complete = false
              unidentifiedPaths.append(path)
            }
            continue
          }
          let version =
            (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)
          apps.append(InstalledApplication(bundleID: bundleID, path: path, version: version))
        } else if !ScanService.isPackage(path) {
          visit(path, depth: depth + 1, volumeID: volumeID)
        }
      }
    }
    for root in applicationRoots {
      let rootIdentity: FileIdentity
      do { rootIdentity = try DescriptorFileSystem.identity(at: root) } catch FileSystemFailure.systemCall(_, let code)
        where code == ENOENT
      {
        continue
      } catch {
        complete = false
        continue
      }
      guard rootIdentity.kind == .directory,
        let volumeID = try? DescriptorFileSystem.volumeID(at: root)
      else {
        complete = false
        continue
      }
      visit(root, depth: 0, volumeID: volumeID)
    }
    return BundleInventory(
      applications: apps, unidentifiedPaths: unidentifiedPaths,
      complete: complete, observedAt: Date())
  }

  /// A link resolving to a regular file (a document or script) cannot be an app.
  static func linksToPlainFile(_ path: String) -> Bool {
    guard !path.lowercased(with: Locale(identifier: "en_US_POSIX")).hasSuffix(".app"),
      let resolved = realpath(path, nil)
    else { return false }
    defer { free(resolved) }
    return (try? DescriptorFileSystem.identity(at: String(cString: resolved)))?.kind == .regular
  }

  /// Info.plist of a Mac bundle, or of the single app inside an iOS wrapper.
  static func infoPlistPath(ofBundleAt path: String) -> String {
    let mac = path + "/Contents/Info.plist"
    if (try? DescriptorFileSystem.identity(at: path + "/Contents"))?.kind == .directory { return mac }
    let wrapper = path + "/Wrapper"
    guard let identity = try? DescriptorFileSystem.identity(at: wrapper), identity.kind == .directory,
      let names = try? DescriptorFileSystem.children(at: wrapper, expected: identity)
    else { return mac }
    let apps = names.filter { $0.lowercased(with: Locale(identifier: "en_US_POSIX")).hasSuffix(".app") }
    guard apps.count == 1 else { return mac }
    return wrapper + "/" + apps[0] + "/Info.plist"
  }

  /// A link in an application folder counts only when it resolves, without
  /// further links, to an `.app` whose own Info.plist names a valid bundle ID.
  static func resolveLinkedApplication(at path: String) -> InstalledApplication? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    let target = String(cString: resolved)
    guard target.lowercased(with: Locale(identifier: "en_US_POSIX")).hasSuffix(".app"),
      let identity = try? DescriptorFileSystem.identity(at: target), identity.kind == .directory,
      let data = try? SecureMetadataFile.read(
        path: target + "/Contents/Info.plist", limit: 1024 * 1024, ownerOnly: false),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = plist as? [String: Any],
      let bundleID = dictionary["CFBundleIdentifier"] as? String, validBundleID(bundleID)
    else { return nil }
    let version = (dictionary["CFBundleShortVersionString"] as? String) ?? (dictionary["CFBundleVersion"] as? String)
    return InstalledApplication(bundleID: bundleID, path: path, version: version, linkTarget: target)
  }

  public func discover() async -> [RelatedDataCandidate] {
    if Task.isCancelled { return [] }
    let apps = inventory()
    let receipts: [RelatedReceipt]
    let receiptStoreHealthy: Bool
    do {
      receipts = try loadReceipts()
      receiptStoreHealthy = true
    } catch {
      receipts = []
      receiptStoreHealthy = false
    }
    var candidates: [RelatedDataCandidate] = []
    if !receiptStoreHealthy {
      candidates.append(
        RelatedDataCandidate(
          id: "receipt-store", path: receiptPath,
          classification: .uncertain, reason: .recordUnsafe,
          snapshot: nil, receipt: nil))
    }
    var pending:
      [(
        path: String, classification: RelatedClassification, reason: RelatedReason, receipt: RelatedReceipt?,
        identity: FileIdentity?, needsSnapshot: Bool
      )] = []
    for parent in [homeDirectory + "/Library/Caches", homeDirectory + "/Library/Preferences"] {
      if Task.isCancelled { return [] }
      guard let parentIdentity = try? DescriptorFileSystem.identity(at: parent),
        parentIdentity.kind == .directory,
        let names = try? DescriptorFileSystem.children(at: parent, expected: parentIdentity)
      else {
        candidates.append(
          RelatedDataCandidate(
            id: parent, path: parent,
            classification: .uncertain, reason: .candidateAreaUnreadable,
            snapshot: nil, receipt: nil))
        continue
      }
      for name in names {
        if Task.isCancelled { return [] }
        let bundleID =
          parent.hasSuffix("Preferences") && name.hasSuffix(".plist")
          ? String(name.dropLast(6)) : name
        guard Self.validBundleID(bundleID) else { continue }
        let path = parent + "/" + name
        let receipt = receipts.first { $0.relatedPath == path && $0.bundleID == bundleID }
        let protected = ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) != nil
        let identity = try? DescriptorFileSystem.identity(at: path)
        let validReceipt =
          receipt.map { receipt in
            receipt.schema == 1 && receipt.ruleSource == "exact-standard-domain-v1"
              && Self.standardPath(bundleID: bundleID, homeDirectory: homeDirectory).contains(path)
              && receipt.identity.matchesStableTrashIdentity(identity ?? receipt.identity)
              && identity != nil
          } ?? false
        let classification: RelatedClassification
        let reason: RelatedReason
        if protected {
          classification = .protected
          reason = .protected
        } else if apps.contains(bundleID) {
          classification = .installed
          reason = .installed
        } else if !apps.complete || !receiptStoreHealthy {
          classification = .uncertain
          reason = !apps.complete ? .incompleteInventory : .recordUnavailable
        } else if installedElsewhere(bundleID) {
          classification = .uncertain
          reason = .installedElsewhere
        } else if validReceipt {
          classification = .historicallyVerifiedAbsent
          reason = .historicallyVerified
        } else {
          classification = .uncertain
          reason = .nameOnly
        }
        let needsSnapshot =
          classification == .historicallyVerifiedAbsent
          || (classification == .installed && apps.complete && receiptStoreHealthy)
        pending.append((path, classification, reason, receipt, needsSnapshot ? identity : nil, needsSnapshot))
      }
    }
    // Evidence snapshots are independent subtree walks; a few run at once.
    let snapshots = await withTaskGroup(of: (Int, ScanSnapshot?).self) { group in
      var results = [ScanSnapshot?](repeating: nil, count: pending.count)
      var next = 0
      func enqueue() {
        while next < pending.count && !pending[next].needsSnapshot { next += 1 }
        guard next < pending.count else { return }
        let index = next
        let item = pending[index]
        next += 1
        group.addTask { (index, await snapshotForCandidate(path: item.path, identity: item.identity)) }
      }
      for _ in 0..<6 { enqueue() }
      while let (index, snapshot) = await group.next() {
        results[index] = snapshot
        enqueue()
      }
      return results
    }
    if Task.isCancelled { return [] }
    for (index, item) in pending.enumerated() {
      let snapshot = snapshots[index]
      candidates.append(
        RelatedDataCandidate(
          id: item.path, path: item.path,
          classification: snapshot == nil && item.classification == .historicallyVerifiedAbsent
            ? .uncertain : item.classification,
          reason: item.reason, snapshot: snapshot, receipt: item.receipt))
    }
    // Group Containers are shared and protected. Only root metadata is observed;
    // their names and contents are never enumerated for cleanup.
    let groupRoot = homeDirectory + "/Library/Group Containers"
    if (try? DescriptorFileSystem.identity(at: groupRoot)) != nil {
      candidates.append(
        RelatedDataCandidate(
          id: groupRoot, path: groupRoot,
          classification: .shared, reason: .sharedGroup, snapshot: nil, receipt: nil))
    }
    if !Task.isCancelled && apps.complete && receiptStoreHealthy {
      do {
        try saveVerifiedReceipts(apps: apps, candidates: candidates, existing: receipts)
      } catch {
        candidates.append(
          RelatedDataCandidate(
            id: "receipt-write", path: receiptPath,
            classification: .uncertain, reason: .recordUnsafe,
            snapshot: nil, receipt: nil))
      }
    }
    return candidates
  }

  public func plan(candidate: RelatedDataCandidate) throws -> ActionPlan {
    guard candidate.classification == .historicallyVerifiedAbsent,
      let receipt = candidate.receipt, let snapshot = candidate.snapshot,
      let root = snapshot.entries.first(where: { $0.path == candidate.path })
    else { throw RelatedFailure.invalidReceipt }
    let base = try PlanService(homeDirectory: homeDirectory).makePlan(
      snapshot: snapshot, selectedIDs: [root.id])
    let item = base.items[0]
    let proof = RelatedProof(
      bundleID: receipt.bundleID, relatedPath: receipt.relatedPath,
      identity: receipt.identity, receiptObservedAt: receipt.observedAt,
      snapshotRunID: snapshot.runID)
    return ActionPlan(
      id: base.id, snapshotRunID: base.snapshotRunID, kind: .trash,
      createdAt: base.createdAt,
      items: [
        PlanItem(
          id: item.id, sourcePath: item.sourcePath,
          volumeID: item.volumeID, inventory: item.inventory,
          ancestors: item.ancestors, relatedProof: proof)
      ])
  }

  /// Installed-app data is a separate opt-in. An exact standard-domain path
  /// and a single observed owner are required; this does not grant package access.
  public func planInstalled(app: InstalledApplication, candidate: RelatedDataCandidate) throws -> ActionPlan {
    let apps = inventory()
    guard apps.complete else { throw RelatedFailure.incompleteInventory }
    guard apps.applications.filter({ foldedAppID($0.bundleID) == foldedAppID(app.bundleID) }).count == 1,
      apps.applications.contains(app),
      candidate.classification == .installed,
      Self.standardPath(bundleID: app.bundleID, homeDirectory: homeDirectory).contains(candidate.path),
      let snapshot = candidate.snapshot,
      let root = snapshot.entries.first(where: { $0.path == candidate.path }),
      let relatedIdentity = root.identity,
      relatedIdentity.hasStableTrashProof,
      let appIdentity = try? DescriptorFileSystem.identity(at: app.path),
      appIdentity.kind == .directory,
      let infoIdentity = try? DescriptorFileSystem.identity(at: app.path + "/Contents/Info.plist"),
      infoIdentity.kind == .regular,
      Self.bundleID(at: app.path) == app.bundleID
    else { throw RelatedFailure.unsupportedInstalledData }
    let base = try PlanService(homeDirectory: homeDirectory).makePlan(
      snapshot: snapshot, selectedIDs: [root.id])
    let item = base.items[0]
    let proof = InstalledRelatedProof(
      bundleID: app.bundleID, appPath: app.path, appIdentity: appIdentity,
      infoIdentity: infoIdentity, relatedPath: candidate.path,
      relatedIdentity: relatedIdentity, snapshotRunID: snapshot.runID)
    return ActionPlan(
      id: base.id, snapshotRunID: base.snapshotRunID, kind: .trash,
      createdAt: base.createdAt,
      items: [
        PlanItem(
          id: item.id, sourcePath: item.sourcePath, volumeID: item.volumeID,
          inventory: item.inventory, ancestors: item.ancestors,
          installedRelatedProof: proof)
      ])
  }

  public func validateInstalled(_ item: PlanItem, plan: ActionPlan) throws {
    guard plan.kind == .trash, let proof = item.installedRelatedProof,
      proof.snapshotRunID == plan.snapshotRunID,
      proof.relatedPath == item.sourcePath,
      item.inventory.first?.identity == proof.relatedIdentity,
      Self.standardPath(bundleID: proof.bundleID, homeDirectory: homeDirectory).contains(item.sourcePath),
      applicationRoots.contains(where: { proof.appPath.hasPrefix($0 + "/") }),
      (try? DescriptorFileSystem.identity(at: proof.appPath)) == proof.appIdentity,
      (try? DescriptorFileSystem.identity(at: proof.appPath + "/Contents/Info.plist")) == proof.infoIdentity,
      Self.bundleID(at: proof.appPath) == proof.bundleID,
      (try? DescriptorFileSystem.identity(at: item.sourcePath)) == proof.relatedIdentity,
      ProtectionPolicy.rule(for: item.sourcePath, homeDirectory: homeDirectory) == nil
    else { throw RelatedFailure.unsupportedInstalledData }
    let apps = inventory()
    guard apps.complete else { throw RelatedFailure.incompleteInventory }
    guard
      apps.applications.filter({ foldedAppID($0.bundleID) == foldedAppID(proof.bundleID) })
        .map(\.path) == [proof.appPath]
    else { throw RelatedFailure.ambiguousOwner }
  }

  private func snapshotForCandidate(
    path: String,
    identity: FileIdentity?
  ) async -> ScanSnapshot? {
    guard let identity else { return nil }
    guard identity.kind == .directory || identity.kind == .regular else { return nil }
    let root = (path as NSString).deletingLastPathComponent
    let name = (path as NSString).lastPathComponent
    guard
      let snapshot = try? await ScanService(homeDirectory: homeDirectory)
        .scanImmediateChild(parentPath: root, name: name),
      let entry = snapshot.entries.first(where: { $0.path == path }),
      let node = snapshot.nodes.first(where: { $0.id == entry.id }),
      !node.partial, !node.protected
    else { return nil }
    return snapshot
  }

  public func validate(_ item: PlanItem, plan: ActionPlan) throws {
    guard plan.kind == .trash, let proof = item.relatedProof,
      proof.snapshotRunID == plan.snapshotRunID,
      proof.relatedPath == item.sourcePath,
      Self.standardPath(bundleID: proof.bundleID, homeDirectory: homeDirectory).contains(item.sourcePath),
      let receipt = (try? loadReceipts())?.first(where: {
        $0.bundleID == proof.bundleID
          && $0.relatedPath == proof.relatedPath && $0.observedAt == proof.receiptObservedAt
      }),
      receipt.schema == 1, receipt.ruleSource == "exact-standard-domain-v1",
      receipt.identity == proof.identity,
      let current = try? DescriptorFileSystem.identity(at: item.sourcePath),
      receipt.identity.matchesStableTrashIdentity(current),
      ProtectionPolicy.rule(for: item.sourcePath, homeDirectory: homeDirectory) == nil
    else { throw RelatedFailure.invalidReceipt }
    let apps = inventory()
    guard apps.complete else { throw RelatedFailure.incompleteInventory }
    guard !apps.contains(proof.bundleID) else { throw RelatedFailure.ownerPresent }
  }

  private func saveVerifiedReceipts(
    apps: BundleInventory,
    candidates: [RelatedDataCandidate], existing: [RelatedReceipt]
  ) throws {
    var receipts = existing
    for candidate in candidates where candidate.classification == .installed {
      guard let bundleID = Self.bundleID(for: candidate.path),
        let app = apps.applications.first(where: { $0.bundleID == bundleID }),
        apps.applications.filter({ foldedAppID($0.bundleID) == foldedAppID(bundleID) }).count == 1,
        candidate.snapshot != nil,
        let identity = try? DescriptorFileSystem.identity(at: candidate.path),
        identity.hasStableTrashProof,
        ProtectionPolicy.rule(for: candidate.path, homeDirectory: homeDirectory) == nil
      else { continue }
      let receipt = RelatedReceipt(
        schema: 1, bundleID: bundleID, appPath: app.path,
        relatedPath: candidate.path, identity: identity,
        observedAt: apps.observedAt, ruleSource: "exact-standard-domain-v1")
      receipts.removeAll { $0.relatedPath == candidate.path }
      receipts.append(receipt)
    }
    guard receipts != existing else { return }
    let data = try JSONEncoder().encode(receipts)
    try SecureMetadataFile.write(path: receiptPath, data: data, limit: 4 * 1024 * 1024)
  }

  private var receiptPath: String {
    homeDirectory + "/Library/Application Support/com.tavsn.lighten/related-receipts.json"
  }

  private func loadReceipts() throws -> [RelatedReceipt] {
    guard
      let data = try SecureMetadataFile.read(
        path: receiptPath,
        limit: 4 * 1024 * 1024, ownerOnly: true)
    else { return [] }
    let receipts = try JSONDecoder().decode([RelatedReceipt].self, from: data)
    guard receipts.count <= 10_000,
      Set(receipts.map(\.relatedPath)).count == receipts.count,
      receipts.allSatisfy({ receipt in
        receipt.schema == 1 && Self.validBundleID(receipt.bundleID)
          && receipt.ruleSource == "exact-standard-domain-v1"
          && receipt.identity.hasStableTrashProof
          && (receipt.identity.kind == .directory || receipt.identity.kind == .regular)
          && Self.standardPath(bundleID: receipt.bundleID, homeDirectory: homeDirectory)
            .contains(receipt.relatedPath)
          && (receipt.appPath.hasPrefix("/Applications/")
            || receipt.appPath.hasPrefix(homeDirectory + "/Applications/"))
          && (try? DescriptorFileSystem.validatedComponents(receipt.appPath)) != nil
      })
    else { throw RelatedFailure.invalidReceipt }
    return receipts
  }

  private static func bundleID(for path: String) -> String? {
    let name = URL(fileURLWithPath: path).lastPathComponent
    let id = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
    return validBundleID(id) ? id : nil
  }

  private static func bundleID(at appPath: String) -> String? {
    guard
      let data = try? SecureMetadataFile.read(
        path: appPath + "/Contents/Info.plist", limit: 1024 * 1024, ownerOnly: false),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = plist as? [String: Any],
      let id = dictionary["CFBundleIdentifier"] as? String, validBundleID(id)
    else { return nil }
    return id
  }

  static func validBundleID(_ id: String) -> Bool {
    let parts = id.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count >= 2
      && parts.allSatisfy { part in
        !part.isEmpty && part.count <= 63
          && part.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
              .contains($0)
          }
      }
  }

  private static func standardPath(bundleID: String, homeDirectory: String) -> [String] {
    [
      homeDirectory + "/Library/Caches/" + bundleID,
      homeDirectory + "/Library/Preferences/" + bundleID + ".plist",
    ]
  }
}
