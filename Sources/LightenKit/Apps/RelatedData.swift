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
  case installed, historicallyVerifiedAbsent, orphanVerified, uncertain, protected, shared
}

public enum RelatedReason: String, Sendable {
  case candidateAreaUnreadable, recordUnsafe, protected, installed
  case incompleteInventory, recordUnavailable, historicallyVerified, nameOnly
  case sharedGroup, installedElsewhere, orphanVerified, foreignOwner, mediumMatch
}

public struct RelatedDataCandidate: Sendable, Identifiable {
  public let id: String
  public let path: String
  public let classification: RelatedClassification
  public let reason: RelatedReason
  public let snapshot: ScanSnapshot?
  public let receipt: RelatedReceipt?
  public var bundleID: String? = nil
  public var matchStrength: RelatedMatchStrength = .strong
  public var observation: RelatedDataObservation? = nil
  public var modifiedAt: Date? = nil

  public var canSelect: Bool {
    (classification == .installed || classification == .historicallyVerifiedAbsent
      || classification == .orphanVerified)
      && matchStrength != .weak && snapshot != nil
  }

  public var defaultSelected: Bool { canSelect && classification == .installed && matchStrength == .strong }
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

public struct OrphanRelatedProof: Codable, Sendable, Equatable {
  public let bundleID: String
  public let relatedPath: String
  public let identity: FileIdentity
  public let observedAt: Date
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
  private let writeVerifiedReceipts: Bool
  /// Whether the system knows an app with this bundle ID anywhere outside the
  /// Trash. A known app elsewhere keeps its data from being called a leftover.
  private let installedElsewhere: @Sendable (String) -> Bool
  private let signingMetadata: @Sendable (String) -> ApplicationSigningMetadata?

  /// Disable receipt writes for read-only observations. Existing receipts are
  /// still read and validated; this option does not change action authority.
  public init(
    homeDirectory: String = NSHomeDirectory(),
    writeVerifiedReceipts: Bool = true,
    installedElsewhere: (@Sendable (String) -> Bool)? = nil
  ) {
    self.homeDirectory = homeDirectory
    self.applicationRoots = ["/Applications", homeDirectory + "/Applications"]
    self.writeVerifiedReceipts = writeVerifiedReceipts
    self.installedElsewhere = installedElsewhere ?? ApplicationRegistration.isInstalled
    self.signingMetadata = ApplicationSigningMetadata.read
  }

  init(
    homeDirectory: String, applicationRoots: [String],
    writeVerifiedReceipts: Bool = true,
    installedElsewhere: @escaping @Sendable (String) -> Bool = { _ in false },
    signingMetadata: @escaping @Sendable (String) -> ApplicationSigningMetadata? = ApplicationSigningMetadata.read
  ) {
    self.homeDirectory = homeDirectory
    self.applicationRoots = applicationRoots
    self.writeVerifiedReceipts = writeVerifiedReceipts
    self.installedElsewhere = installedElsewhere
    self.signingMetadata = signingMetadata
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
    await discover(inventory: inventory(), only: nil)
  }

  /// A focused observation for a dropped or selected application.
  public func discover(for app: InstalledApplication) async -> [RelatedDataCandidate] {
    await focusedObservation(for: app).candidates
  }

  func focusedObservation(for app: InstalledApplication) async
    -> (candidates: [RelatedDataCandidate], signerTeamID: String?)
  {
    let apps = inventory(including: app)
    var signatures: [String: ApplicationSigningMetadata] = [:]
    let selected = signingMetadata(app.linkTarget ?? app.path)
    signatures[app.path] = selected
    // Other signers are relevant only when a selected entitlement names a
    // present group container whose exclusive ownership must be checked.
    let hasGroupData =
      selected?.groupIdentifiers.contains { domain in
        (try? DescriptorFileSystem.identity(
          at: RelatedLocation.groupContainers.path(domain: domain, homeDirectory: homeDirectory))) != nil
      } == true
    if hasGroupData {
      for owner in apps.applications where owner.path != app.path {
        signatures[owner.path] = signingMetadata(owner.linkTarget ?? owner.path)
      }
    }
    return (
      await discover(inventory: apps, only: app, signatures: signatures),
      selected?.teamID
    )
  }

  /// Reads one explicitly selected application without walking installed roots.
  /// Returned metadata is an observation; action plans still revalidate it.
  public func application(at path: String) -> InstalledApplication? {
    guard ExactInventory.isApplicationName(path),
      ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) == nil,
      let identity = try? DescriptorFileSystem.identity(at: path), identity.kind == .directory
    else { return nil }
    let infoPath = Self.infoPlistPath(ofBundleAt: path)
    guard let infoIdentity = try? DescriptorFileSystem.identity(at: infoPath), infoIdentity.kind == .regular,
      let data = try? SecureMetadataFile.read(path: infoPath, limit: 1024 * 1024, ownerOnly: false),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = plist as? [String: Any],
      let id = dictionary["CFBundleIdentifier"] as? String, Self.validBundleID(id),
      (try? DescriptorFileSystem.identity(at: infoPath)) == infoIdentity,
      (try? DescriptorFileSystem.identity(at: path)) == identity
    else { return nil }
    return InstalledApplication(
      bundleID: id, path: path,
      version: (dictionary["CFBundleShortVersionString"] as? String) ?? (dictionary["CFBundleVersion"] as? String))
  }

  private func inventory(including app: InstalledApplication) -> BundleInventory {
    let current = inventory()
    guard !current.applications.contains(where: { $0.path == app.path }),
      app.linkTarget == nil, ExactInventory.isApplicationName(app.path),
      (try? DescriptorFileSystem.identity(at: app.path))?.kind == .directory,
      ProtectionPolicy.rule(for: app.path, homeDirectory: homeDirectory) == nil,
      Self.bundleID(at: app.path) == app.bundleID
    else { return current }
    return BundleInventory(
      applications: current.applications + [app], unidentifiedPaths: current.unidentifiedPaths,
      complete: current.complete, observedAt: current.observedAt)
  }

  private func discover(
    inventory apps: BundleInventory, only app: InstalledApplication?,
    signatures suppliedSignatures: [String: ApplicationSigningMetadata]? = nil
  ) async
    -> [RelatedDataCandidate]
  {
    if Task.isCancelled { return [] }
    let receipts = (try? loadReceipts()) ?? []
    let receiptStoreHealthy = (try? loadReceipts()) != nil
    let signatures =
      suppliedSignatures
      ?? Dictionary(
        apps.applications.compactMap { app -> (String, ApplicationSigningMetadata)? in
          signingMetadata(app.linkTarget ?? app.path).map { (app.path, $0) }
        },
        uniquingKeysWith: { first, _ in first })
    var candidates: [RelatedDataCandidate] = []
    if !receiptStoreHealthy && app == nil {
      candidates.append(
        RelatedDataCandidate(
          id: "receipt-store", path: receiptPath,
          classification: .uncertain, reason: .recordUnsafe, snapshot: nil, receipt: nil))
    }
    var paths: [(RelatedLocation, String, String)] = []
    for location in RelatedLocation.allCases {
      if Task.isCancelled { return [] }
      let parent = location.parent(homeDirectory: homeDirectory)
      if let app {
        let domains: [String]
        if location == .groupContainers {
          domains = Array(signatures[app.path]?.groupIdentifiers ?? [])
        } else {
          domains = [app.bundleID]
        }
        for domain in domains {
          let path = location.path(domain: domain, homeDirectory: homeDirectory)
          if (try? DescriptorFileSystem.identity(at: path)) != nil { paths.append((location, domain, path)) }
        }
        continue
      }
      let parentIdentity: FileIdentity
      do { parentIdentity = try DescriptorFileSystem.identity(at: parent) } catch FileSystemFailure.systemCall(
        _, let code) where code == ENOENT
      { continue } catch {
        candidates.append(
          RelatedDataCandidate(
            id: parent, path: parent, classification: .uncertain,
            reason: .candidateAreaUnreadable, snapshot: nil, receipt: nil))
        continue
      }
      guard parentIdentity.kind == .directory,
        let names = try? DescriptorFileSystem.children(at: parent, expected: parentIdentity)
      else {
        candidates.append(
          RelatedDataCandidate(
            id: parent, path: parent, classification: .uncertain,
            reason: .candidateAreaUnreadable, snapshot: nil, receipt: nil))
        continue
      }
      for name in names {
        guard let domain = location.domain(name: name) else { continue }
        paths.append((location, domain, parent + "/" + name))
      }
    }
    var pending: [RelatedDataCandidate] = []
    for (location, domain, path) in paths {
      if Task.isCancelled { return [] }
      let identity = try? DescriptorFileSystem.identity(at: path)
      let groupOwners = apps.applications.filter { signatures[$0.path]?.groupIdentifiers.contains(domain) == true }
      let exactOwners = apps.applications.filter { foldedAppID($0.bundleID) == foldedAppID(domain) }
      let prefixOwners = apps.applications.filter { owner in
        guard let team = signatures[owner.path]?.teamID else { return false }
        return domain.hasPrefix(team + "." + owner.bundleID)
          && (domain == team + "." + owner.bundleID || domain.hasPrefix(team + "." + owner.bundleID + "."))
      }
      let weakOwners =
        (location == .applicationSupport || location == .logs)
        ? apps.applications.filter {
          (URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent)
            .caseInsensitiveCompare(domain) == .orderedSame
        } : []
      let owners =
        location == .groupContainers
        ? groupOwners
        : !exactOwners.isEmpty ? exactOwners : !prefixOwners.isEmpty ? prefixOwners : weakOwners
      let strength: RelatedMatchStrength =
        location == .groupContainers || !exactOwners.isEmpty
        ? .strong
        : !prefixOwners.isEmpty ? .medium : !weakOwners.isEmpty ? .weak : .strong
      let focusedOwner = app.flatMap { selected in
        owners.contains(where: { $0.path == selected.path }) ? selected.bundleID : nil
      }
      let bundleID = focusedOwner ?? owners.first?.bundleID ?? (Self.validBundleID(domain) ? domain : nil)
      guard let bundleID else { continue }
      if let app, bundleID != app.bundleID { continue }
      let receipt = receipts.first { $0.relatedPath == path && $0.bundleID == bundleID }
      let validReceipt =
        receipt.map {
          $0.schema == 1 && $0.ruleSource == "exact-standard-domain-v1"
            && identity.map($0.identity.matchesStableTrashIdentity) == true
        } ?? false
      let protection = ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory)
      let classification: RelatedClassification
      let reason: RelatedReason
      if location == .groupContainers && (owners.count != 1 || !apps.complete) {
        classification = .shared
        reason = .sharedGroup
      } else if protection != nil && !(location == .groupContainers && protection?.id == "group-containers") {
        classification = .protected
        reason = .protected
      } else if identity?.kind == .symbolicLink || identity?.kind == .other {
        classification = .uncertain
        reason = .recordUnsafe
      } else if !Self.currentUserOwns(path) {
        classification = .uncertain
        reason = .foreignOwner
      } else if !owners.isEmpty {
        classification = .installed
        reason = strength == .weak ? .nameOnly : strength == .medium ? .mediumMatch : .installed
      } else if !apps.complete || !receiptStoreHealthy {
        classification = .uncertain
        reason = !apps.complete ? .incompleteInventory : .recordUnavailable
      } else if installedElsewhere(bundleID) {
        classification = .uncertain
        reason = .installedElsewhere
      } else if domain.lowercased().hasPrefix("com.apple.") || !Self.currentUserOwns(path)
        || apps.applications.contains(where: {
          domain.hasPrefix($0.bundleID + "-") || domain.hasPrefix($0.bundleID + ".")
        })
        || receipts.contains(where: { domain.hasPrefix($0.bundleID + "-") || domain.hasPrefix($0.bundleID + ".") })
      {
        classification = .uncertain
        reason = Self.currentUserOwns(path) ? .nameOnly : .foreignOwner
      } else if validReceipt {
        classification = .historicallyVerifiedAbsent
        reason = .historicallyVerified
      } else {
        classification = .orphanVerified
        reason = .orphanVerified
      }
      var candidate = RelatedDataCandidate(
        id: path, path: path, classification: classification, reason: reason,
        snapshot: nil, receipt: receipt)
      candidate.bundleID = bundleID
      candidate.matchStrength = strength
      candidate.modifiedAt = identity?.modificationSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
      pending.append(candidate)
    }
    let measured = await withTaskGroup(of: (Int, RelatedDataCandidate).self) { group in
      var results = pending
      var next = 0
      func enqueue() {
        guard next < pending.count, !Task.isCancelled else { return }
        let index = next
        let candidate = pending[index]
        next += 1
        group.addTask {
          var result = candidate
          let measurement = await ApplicationDiscovery.measure(path: candidate.path, homeDirectory: homeDirectory)
          result.observation = RelatedDataObservation(
            logical: measurement.logical, allocated: measurement.allocated,
            knownItemCount: measurement.count, partial: measurement.partial)
          // A metadata-only compatibility snapshot is an observation, never an inventory grant.
          if apps.complete && receiptStoreHealthy && candidate.matchStrength != .weak,
            candidate.classification == .installed || candidate.classification == .historicallyVerifiedAbsent
              || candidate.classification == .orphanVerified,
            let identity = try? DescriptorFileSystem.identity(at: candidate.path), identity.hasStableTrashProof,
            let volumeID = try? DescriptorFileSystem.volumeID(at: candidate.path)
          {
            let entry = ScanEntry(parentID: nil, path: candidate.path, identity: identity, issues: [], readable: true)
            let node = ScanNode(
              id: entry.id, parentID: nil, logical: measurement.logical, allocated: measurement.allocated,
              knownItemCount: measurement.count, completeItemCount: measurement.partial ? nil : measurement.count,
              partial: measurement.partial, protected: false, skipped: false)
            result = RelatedDataCandidate(
              id: candidate.id, path: candidate.path, classification: candidate.classification,
              reason: candidate.reason,
              snapshot: ScanSnapshot(
                rootPath: candidate.path, volumeDevice: identity.device, volumeID: volumeID,
                observedAt: apps.observedAt, entries: [entry], nodes: [node]), receipt: candidate.receipt,
              bundleID: candidate.bundleID, matchStrength: candidate.matchStrength, observation: result.observation,
              modifiedAt: candidate.modifiedAt)
          }
          return (index, result)
        }
      }
      for _ in 0..<4 { enqueue() }
      while let (index, result) = await group.next() {
        results[index] = result
        enqueue()
      }
      return results
    }
    candidates += measured
    let groupRoot = RelatedLocation.groupContainers.parent(homeDirectory: homeDirectory)
    if app == nil, (try? DescriptorFileSystem.identity(at: groupRoot)) != nil {
      candidates.append(
        RelatedDataCandidate(
          id: groupRoot, path: groupRoot, classification: .shared,
          reason: .sharedGroup, snapshot: nil, receipt: nil))
    }
    if app == nil && writeVerifiedReceipts && !Task.isCancelled && apps.complete && receiptStoreHealthy {
      do { try saveVerifiedReceipts(apps: apps, candidates: candidates, existing: receipts) } catch {
        candidates.append(
          RelatedDataCandidate(
            id: "receipt-write", path: receiptPath, classification: .uncertain,
            reason: .recordUnsafe, snapshot: nil, receipt: nil))
      }
    }
    return candidates
  }

  public func plan(candidate: RelatedDataCandidate) throws -> ActionPlan {
    guard candidate.classification == .historicallyVerifiedAbsent || candidate.classification == .orphanVerified,
      candidate.canSelect, let bundleID = candidate.bundleID ?? candidate.receipt?.bundleID,
      let observation = candidate.snapshot, let expected = observation.entries.first?.identity,
      let location = RelatedLocation.matching(path: candidate.path, homeDirectory: homeDirectory)?.0,
      location != .groupContainers,
      Self.standardPath(bundleID: bundleID, homeDirectory: homeDirectory).contains(candidate.path)
    else { throw RelatedFailure.invalidReceipt }
    let policy: TreePolicy = location == .containers ? .relatedContainer : .relatedTrash
    let current = try ExactInventory(homeDirectory: homeDirectory).collect(
      rootPath: candidate.path,
      expected: (expected.device, expected.inode), policy: policy)
    let root = current.entries[0]
    let relatedProof: RelatedProof?
    let orphanProof: OrphanRelatedProof?
    if candidate.classification == .historicallyVerifiedAbsent, let receipt = candidate.receipt {
      relatedProof = RelatedProof(
        bundleID: bundleID, relatedPath: candidate.path, identity: receipt.identity,
        receiptObservedAt: receipt.observedAt, snapshotRunID: observation.runID)
      orphanProof = nil
    } else {
      relatedProof = nil
      orphanProof = OrphanRelatedProof(
        bundleID: bundleID, relatedPath: candidate.path, identity: root.identity!,
        observedAt: Date(), snapshotRunID: observation.runID)
    }
    let item = PlanItem(
      id: root.id, sourcePath: candidate.path, volumeID: current.volumeID, inventory: current.entries,
      ancestors: current.ancestors, relatedProof: relatedProof, policy: policy,
      nestedApplicationIDs: current.nestedApplicationIDs, snapshotRunID: observation.runID,
      orphanRelatedProof: orphanProof)
    let plan = ActionPlan(snapshotRunID: observation.runID, kind: .trash, items: [item])
    if relatedProof != nil { try validate(item, plan: plan) } else { try validateOrphan(item, plan: plan) }
    return plan
  }

  public func planInstalled(app: InstalledApplication, candidate: RelatedDataCandidate) throws -> ActionPlan {
    guard app.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame else {
      throw PlanRejection(.lightenItself, path: app.path)
    }
    let apps = inventory(including: app)
    guard apps.complete else { throw RelatedFailure.incompleteInventory }
    guard apps.applications.filter({ foldedAppID($0.bundleID) == foldedAppID(app.bundleID) }).count == 1,
      apps.applications.contains(app), candidate.classification == .installed, candidate.canSelect,
      let observation = candidate.snapshot, let expected = observation.entries.first?.identity,
      let appIdentity = try? DescriptorFileSystem.identity(at: app.path), appIdentity.kind == .directory,
      let infoIdentity = try? DescriptorFileSystem.identity(at: app.path + "/Contents/Info.plist"),
      infoIdentity.kind == .regular,
      Self.bundleID(at: app.path) == app.bundleID,
      let policy = installedPolicy(app: app, relatedPath: candidate.path, inventory: apps)
    else { throw RelatedFailure.unsupportedInstalledData }
    let current = try ExactInventory(homeDirectory: homeDirectory).collect(
      rootPath: candidate.path,
      expected: (expected.device, expected.inode), policy: policy)
    let root = current.entries[0]
    let proof = InstalledRelatedProof(
      bundleID: app.bundleID, appPath: app.path, appIdentity: appIdentity,
      infoIdentity: infoIdentity, relatedPath: candidate.path, relatedIdentity: root.identity!,
      snapshotRunID: observation.runID)
    let item = PlanItem(
      id: root.id, sourcePath: candidate.path, volumeID: current.volumeID, inventory: current.entries,
      ancestors: current.ancestors, installedRelatedProof: proof, policy: policy,
      nestedApplicationIDs: current.nestedApplicationIDs, snapshotRunID: observation.runID)
    let plan = ActionPlan(snapshotRunID: observation.runID, kind: .trash, items: [item])
    try validateInstalled(item, plan: plan)
    return plan
  }

  /// One action and one grouped Undo for an application and explicitly selected data.
  public func planUninstall(app: InstalledApplication, selectedRelated: [RelatedDataCandidate]) throws -> ActionPlan {
    guard app.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame else {
      throw PlanRejection(.lightenItself, path: app.path)
    }
    var items: [PlanItem] = []
    for candidate in selectedRelated {
      items += try planInstalled(app: app, candidate: candidate).items
    }
    let identity = try DescriptorFileSystem.identity(at: app.path)
    let package = try PlanService(homeDirectory: homeDirectory).makeSpacePlan(
      selections: [PlanService.Selection(path: app.path, device: identity.device, inode: identity.inode)],
      scanRootPath: (app.path as NSString).deletingLastPathComponent, runID: UUID())
    guard package.items.first?.applicationBundleID == app.bundleID else { throw RelatedFailure.changedItem }
    items += package.items
    return ActionPlan(snapshotRunID: items.first?.snapshotRunID ?? package.snapshotRunID, kind: .trash, items: items)
  }

  func installedPolicy(app: InstalledApplication, relatedPath: String, inventory: BundleInventory) -> TreePolicy? {
    guard let (location, domain) = RelatedLocation.matching(path: relatedPath, homeDirectory: homeDirectory) else {
      return nil
    }
    if location == .groupContainers {
      let owners = inventory.applications.filter {
        signingMetadata($0.linkTarget ?? $0.path)?.groupIdentifiers.contains(domain) == true
      }
      return owners.count == 1 && owners[0] == app ? .relatedGroupContainer : nil
    }
    if domain != app.bundleID {
      guard let team = signingMetadata(app.path)?.teamID,
        domain == team + "." + app.bundleID || domain.hasPrefix(team + "." + app.bundleID + ".")
      else { return nil }
    }
    return location == .containers ? .relatedContainer : .relatedTrash
  }

  public func validateInstalled(_ item: PlanItem, plan: ActionPlan) throws {
    try validateScope(item, plan: plan)
    guard plan.kind == .trash, let proof = item.installedRelatedProof,
      proof.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame,
      proof.snapshotRunID == (item.snapshotRunID ?? plan.snapshotRunID), proof.relatedPath == item.sourcePath,
      item.inventory.first?.identity == proof.relatedIdentity,
      (try? DescriptorFileSystem.validatedComponents(proof.appPath)) != nil,
      ProtectionPolicy.rule(for: proof.appPath, homeDirectory: homeDirectory) == nil,
      (try? DescriptorFileSystem.identity(at: proof.appPath)) == proof.appIdentity,
      (try? DescriptorFileSystem.identity(at: proof.appPath + "/Contents/Info.plist")) == proof.infoIdentity,
      Self.bundleID(at: proof.appPath) == proof.bundleID,
      (try? DescriptorFileSystem.identity(at: item.sourcePath)) == proof.relatedIdentity,
      Self.currentUserOwns(item.sourcePath)
    else { throw RelatedFailure.unsupportedInstalledData }
    let apps = inventory(including: InstalledApplication(bundleID: proof.bundleID, path: proof.appPath, version: nil))
    guard apps.complete else { throw RelatedFailure.incompleteInventory }
    guard
      apps.applications.filter({ foldedAppID($0.bundleID) == foldedAppID(proof.bundleID) }).map(\.path) == [
        proof.appPath
      ],
      let app = apps.applications.first(where: { $0.path == proof.appPath }),
      let policy = installedPolicy(app: app, relatedPath: item.sourcePath, inventory: apps),
      item.policy == nil || item.policy == policy
    else { throw RelatedFailure.ambiguousOwner }
  }

  public func validateOrphan(_ item: PlanItem, plan: ActionPlan) throws {
    try validateScope(item, plan: plan)
    guard plan.kind == .trash, let proof = item.orphanRelatedProof,
      proof.snapshotRunID == (item.snapshotRunID ?? plan.snapshotRunID), proof.relatedPath == item.sourcePath,
      item.inventory.first?.identity == proof.identity,
      Self.standardPath(bundleID: proof.bundleID, homeDirectory: homeDirectory).contains(item.sourcePath),
      !proof.bundleID.lowercased().hasPrefix("com.apple."), Self.currentUserOwns(item.sourcePath),
      (try? DescriptorFileSystem.identity(at: item.sourcePath)) == proof.identity,
      let location = RelatedLocation.matching(path: item.sourcePath, homeDirectory: homeDirectory)?.0,
      location != .groupContainers, item.policy == (location == .containers ? .relatedContainer : .relatedTrash)
    else { throw RelatedFailure.invalidReceipt }
    let apps = inventory()
    guard apps.complete else { throw RelatedFailure.incompleteInventory }
    guard !apps.contains(proof.bundleID), !installedElsewhere(proof.bundleID),
      !apps.applications.contains(where: {
        proof.bundleID.hasPrefix($0.bundleID + "-") || proof.bundleID.hasPrefix($0.bundleID + ".")
      })
    else { throw RelatedFailure.ownerPresent }
  }

  public func validate(_ item: PlanItem, plan: ActionPlan) throws {
    try validateScope(item, plan: plan)
    guard plan.kind == .trash, let proof = item.relatedProof,
      proof.snapshotRunID == (item.snapshotRunID ?? plan.snapshotRunID), proof.relatedPath == item.sourcePath,
      Self.standardPath(bundleID: proof.bundleID, homeDirectory: homeDirectory).contains(item.sourcePath),
      let receipt = (try? loadReceipts())?.first(where: {
        $0.bundleID == proof.bundleID && $0.relatedPath == proof.relatedPath && $0.observedAt == proof.receiptObservedAt
      }), receipt.schema == 1, receipt.ruleSource == "exact-standard-domain-v1", receipt.identity == proof.identity,
      let current = try? DescriptorFileSystem.identity(at: item.sourcePath),
      receipt.identity.matchesStableTrashIdentity(current), Self.currentUserOwns(item.sourcePath),
      ProtectionPolicy.rule(for: item.sourcePath, homeDirectory: homeDirectory) == nil
    else { throw RelatedFailure.invalidReceipt }
    let apps = inventory()
    guard apps.complete else { throw RelatedFailure.incompleteInventory }
    guard !apps.contains(proof.bundleID), !installedElsewhere(proof.bundleID) else { throw RelatedFailure.ownerPresent }
  }

  static func currentUserOwns(_ path: String) -> Bool {
    var details = stat()
    return lstat(path, &details) == 0 && details.st_uid == geteuid()
  }

  /// The tree-policy gate checks current scope and signed claims. The executor
  /// separately rechecks complete ownership inventory and registered apps.
  func validateScope(_ item: PlanItem, plan: ActionPlan) throws {
    guard plan.kind == .trash,
      let (location, domain) = RelatedLocation.matching(path: item.sourcePath, homeDirectory: homeDirectory),
      item.policy == nil
        || item.policy
          == (location == .containers
            ? .relatedContainer
            : location == .groupContainers ? .relatedGroupContainer : .relatedTrash),
      Self.currentUserOwns(item.sourcePath)
    else { throw RelatedFailure.unsupportedInstalledData }
    let run = item.snapshotRunID ?? plan.snapshotRunID
    if let proof = item.installedRelatedProof {
      guard proof.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame,
        proof.snapshotRunID == run, proof.relatedPath == item.sourcePath,
        proof.relatedIdentity == item.inventory.first?.identity,
        (try? DescriptorFileSystem.identity(at: item.sourcePath)) == proof.relatedIdentity,
        (try? DescriptorFileSystem.identity(at: proof.appPath)) == proof.appIdentity,
        (try? DescriptorFileSystem.identity(at: proof.appPath + "/Contents/Info.plist")) == proof.infoIdentity,
        Self.bundleID(at: proof.appPath) == proof.bundleID
      else { throw RelatedFailure.unsupportedInstalledData }
      if location == .groupContainers {
        guard signingMetadata(proof.appPath)?.groupIdentifiers.contains(domain) == true else {
          throw RelatedFailure.unsupportedInstalledData
        }
      } else if domain != proof.bundleID {
        guard let team = signingMetadata(proof.appPath)?.teamID,
          domain == team + "." + proof.bundleID || domain.hasPrefix(team + "." + proof.bundleID + ".")
        else { throw RelatedFailure.unsupportedInstalledData }
      }
    } else if let proof = item.orphanRelatedProof {
      guard location != .groupContainers, domain == proof.bundleID,
        !proof.bundleID.lowercased().hasPrefix("com.apple."), proof.snapshotRunID == run,
        proof.relatedPath == item.sourcePath, proof.identity == item.inventory.first?.identity,
        (try? DescriptorFileSystem.identity(at: item.sourcePath)) == proof.identity
      else { throw RelatedFailure.invalidReceipt }
    } else if let proof = item.relatedProof {
      guard location != .groupContainers, domain == proof.bundleID, proof.snapshotRunID == run,
        proof.relatedPath == item.sourcePath,
        let receipt = (try? loadReceipts())?.first(where: {
          $0.bundleID == proof.bundleID && $0.relatedPath == proof.relatedPath
            && $0.observedAt == proof.receiptObservedAt
        }), receipt.identity == proof.identity,
        proof.identity.matchesStableTrashIdentity(item.inventory.first?.identity ?? proof.identity)
      else { throw RelatedFailure.invalidReceipt }
    } else {
      throw RelatedFailure.invalidReceipt
    }
  }

  private func saveVerifiedReceipts(
    apps: BundleInventory,
    candidates: [RelatedDataCandidate], existing: [RelatedReceipt]
  ) throws {
    var receipts = existing
    for candidate in candidates where candidate.classification == .installed {
      guard let bundleID = candidate.bundleID,
        let app = apps.applications.first(where: { $0.bundleID == bundleID }),
        apps.applications.filter({ foldedAppID($0.bundleID) == foldedAppID(bundleID) }).count == 1,
        candidate.snapshot != nil, candidate.matchStrength == .strong,
        Self.standardPath(bundleID: bundleID, homeDirectory: homeDirectory).contains(candidate.path),
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

  static func standardPath(bundleID: String, homeDirectory: String) -> [String] {
    RelatedLocation.allCases.filter { $0 != .groupContainers }.map {
      $0.path(domain: bundleID, homeDirectory: homeDirectory)
    }
  }
}
