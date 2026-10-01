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
  public var ownershipCandidates: [ApplicationOwnerCandidate] = []
  public var ownershipComplete: Bool = true
  public var ownershipIssues: [ApplicationOwnershipIssue] = []
  public var metadataIssues: [ApplicationMetadataIssue] = []
  var observedDirectories: [ApplicationPathObservation] = []
  // Completeness of the installed roots, before unrelated registration leads
  // are enriched. Only a private service context can use this with fresh
  // per-ID registration to prove a standard domain's owner or absence.
  var installedRootsComplete: Bool? = nil
  var unresolvedApplicationMetadata: [ApplicationMetadataIssue] = []

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
  case sharedGroup, installedElsewhere, orphanVerified, foreignOwner, mediumMatch, ownershipUnavailable
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

  public var defaultSelected: Bool {
    canSelect && classification == .installed && matchStrength == .strong
      && !path.contains("/Library/Group Containers/")
  }
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
  private let ownershipRoots: [String]
  private let writeVerifiedReceipts: Bool
  /// Whether the system knows an app with this bundle ID anywhere outside the
  /// Trash. A known app elsewhere keeps its data from being called a leftover.
  private let installedElsewhere: @Sendable (String) -> Bool
  private let packageActivity: @Sendable (String) -> ApplicationActivity
  private let signatureCache: ApplicationSignatureCache
  private let registration: @Sendable () -> ApplicationRegistrationObservation
  private let registeredByID: @Sendable (String) -> ApplicationRegistrationObservation
  private let planContexts: ApplicationPlanContexts
  private let ownershipCollected: @Sendable () -> Void
  private let nativeRead: (@Sendable (String) -> Void)?
  private var contextScope: ApplicationContextScope {
    ApplicationContextScope(home: homeDirectory, applicationRoots: applicationRoots, ownershipRoots: ownershipRoots)
  }
  private func signingMetadata(_ path: String) -> ApplicationSigningMetadata? {
    signatureCache.metadata(at: path)
  }

  /// Disable receipt writes for read-only observations. Existing receipts are
  /// still read and validated; this option does not change action authority.
  public init(
    homeDirectory: String = NSHomeDirectory(),
    writeVerifiedReceipts: Bool = true,
    installedElsewhere: (@Sendable (String) -> Bool)? = nil
  ) {
    self.homeDirectory = homeDirectory
    self.applicationRoots = ["/Applications", homeDirectory + "/Applications"]
    self.ownershipRoots =
      self.applicationRoots + [
        "/System/Applications", "/System/Library/CoreServices", "/Library/Application Support",
        homeDirectory + "/Library/Application Support", "/Library/PrivilegedHelperTools", "/Library/LaunchAgents",
        "/Library/LaunchDaemons", homeDirectory + "/Library/LaunchAgents",
      ]
    self.writeVerifiedReceipts = writeVerifiedReceipts
    self.installedElsewhere = installedElsewhere ?? ApplicationRegistration.isInstalled
    self.signatureCache = .native
    self.packageActivity = NativeApplicationActivitySource.observe
    self.registration = { ApplicationRegistration.observe() }
    self.registeredByID = { id in
      guard let paths = ApplicationRegistration.registeredPaths(bundleID: id) else {
        return ApplicationRegistrationObservation(paths: [], complete: false)
      }
      return ApplicationRegistrationObservation(paths: paths, complete: true)
    }
    self.planContexts = .native
    self.ownershipCollected = {}
    self.nativeRead = nil
  }

  init(
    homeDirectory: String, applicationRoots: [String], ownershipApplicationRoots: [String]? = nil,
    writeVerifiedReceipts: Bool = true,
    installedElsewhere: @escaping @Sendable (String) -> Bool = { _ in false },
    signingMetadata: @escaping @Sendable (String) -> ApplicationSigningMetadata? = ApplicationSigningMetadata.read,
    packageActivity: @escaping @Sendable (String) -> ApplicationActivity = NativeApplicationActivitySource.observe,
    registration: @escaping @Sendable () -> ApplicationRegistrationObservation = {
      ApplicationRegistrationObservation(paths: [], complete: true)
    },
    registeredByID: (@Sendable (String) -> ApplicationRegistrationObservation)? = nil,
    ownershipCollected: @escaping @Sendable () -> Void = {},
    nativeRead: (@Sendable (String) -> Void)? = nil
  ) {
    self.homeDirectory = homeDirectory
    self.applicationRoots = applicationRoots
    self.ownershipRoots = ownershipApplicationRoots ?? applicationRoots
    self.writeVerifiedReceipts = writeVerifiedReceipts
    self.installedElsewhere = installedElsewhere
    self.signatureCache = ApplicationSignatureCache(reader: signingMetadata)
    self.packageActivity = packageActivity
    self.registration = registration
    self.registeredByID = registeredByID ?? { _ in registration() }
    self.planContexts = ApplicationPlanContexts()
    self.ownershipCollected = ownershipCollected
    self.nativeRead = nativeRead
  }

  public func inventory() -> BundleInventory { makeContext().inventory }

  /// Initial installed metadata has no code-owner or signature walk.
  func installedListing() -> BundleInventory {
    var apps: [InstalledApplication] = []
    var unidentifiedPaths: [String] = []
    var complete = true
    var visited = 0
    var directories: [ApplicationPathObservation] = []
    var metadataIssues: [ApplicationMetadataIssue] = []
    var issues: [ApplicationOwnershipIssue] = []

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
      directories.append(ApplicationPathObservation(path: root, identity: identity))
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
            directories.append(ApplicationPathObservation(path: path, identity: child))
            if let info = try? DescriptorFileSystem.identity(
              at: Self.infoPlistPath(ofBundleAt: linked.linkTarget ?? path))
            {
              directories.append(
                ApplicationPathObservation(
                  path: Self.infoPlistPath(ofBundleAt: linked.linkTarget ?? path), identity: info))
            }
          } else if !Self.linksToPlainFile(path) && !Self.isDanglingLink(path) {
            // A link to a folder may hide apps that are never followed.
            complete = false
          }
          continue
        }
        guard child.kind == .directory else { continue }
        if name.lowercased(with: Locale(identifier: "en_US_POSIX")).hasSuffix(".app") {
          let metadataPath = Self.infoPlistPath(ofBundleAt: path)
          do {
            let app = try inspectApplication(at: path, allowProtected: true)
            guard try DescriptorFileSystem.identity(at: path) == child,
              try DescriptorFileSystem.volumeID(at: metadataPath) == volumeID
            else { throw FileSystemFailure.changedDuringInspection }
            if let app { apps.append(app) } else { unidentifiedPaths.append(path) }
            directories.append(ApplicationPathObservation(path: path, identity: child))
            directories.append(
              ApplicationPathObservation(
                path: metadataPath, identity: try DescriptorFileSystem.identity(at: metadataPath)))
          } catch FileSystemFailure.systemCall(_, let code) {
            complete = false
            unidentifiedPaths.append(path)
            issues.append(ApplicationOwnershipIssue(path: metadataPath, code: code))
          } catch {
            complete = false
            unidentifiedPaths.append(path)
            metadataIssues.append(ApplicationMetadataIssue(path: path, error: error))
          }
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
      applications: apps.sorted { $0.path < $1.path }, unidentifiedPaths: unidentifiedPaths,
      complete: complete, observedAt: Date(), ownershipIssues: issues,
      metadataIssues: metadataIssues, observedDirectories: directories)
  }

  static func isDanglingLink(_ path: String) -> Bool {
    if let resolved = realpath(path, nil) {
      free(resolved)
      return false
    }
    return errno == ENOENT
  }

  func makeContext(base: BundleInventory? = nil, including selected: [InstalledApplication] = [])
    -> AuthenticApplicationContext
  {
    let listing = base ?? installedListing()
    let registered = registration()
    var apps = listing.applications
    var issues = listing.ownershipIssues
    var metadataIssues = listing.metadataIssues
    var unresolvedApplicationMetadata = listing.metadataIssues
    var unidentifiedPaths = listing.unidentifiedPaths
    var registeredCodePaths: Set<String> = []
    var complete = listing.complete && registered.complete
    var lineage = listing.observedDirectories
    for path in registered.paths {
      if ApplicationRegistration.isTrash(path) { continue }
      do {
        let identity = try DescriptorFileSystem.identity(at: path)
        if identity.kind == .directory {
          registeredCodePaths.insert(path)
        } else if identity.kind == .symbolicLink, let resolved = realpath(path, nil) {
          let physical = String(cString: resolved)
          free(resolved)
          if (try? DescriptorFileSystem.identity(at: physical))?.kind == .directory {
            registeredCodePaths.insert(physical)
          }
        }
        let observed =
          identity.kind == .symbolicLink
          ? Self.resolveLinkedApplication(at: path) : try inspectApplication(at: path, allowProtected: true)
        guard let app = observed else {
          if identity.kind == .symbolicLink, Self.isDanglingLink(path) { continue }
          // An identifierless, readable launcher cannot own an exact-ID
          // domain. It remains visible and still contributes code candidates.
          if identity.kind == .directory {
            if !unidentifiedPaths.contains(path) { unidentifiedPaths.append(path) }
          } else {
            metadataIssues.append(
              ApplicationMetadataIssue(path: path, error: ApplicationMetadataFailure.invalidInfoPlist))
            unresolvedApplicationMetadata.append(
              ApplicationMetadataIssue(path: path, error: ApplicationMetadataFailure.invalidInfoPlist))
            if !path.hasPrefix("/System/") { complete = false }
          }
          continue
        }
        if !apps.contains(where: { ($0.linkTarget ?? $0.path) == (app.linkTarget ?? app.path) }) { apps.append(app) }
        lineage.append(ApplicationPathObservation(path: path, identity: identity))
        let metadataPath = Self.infoPlistPath(ofBundleAt: app.linkTarget ?? app.path)
        lineage.append(
          ApplicationPathObservation(
            path: metadataPath,
            identity: try DescriptorFileSystem.identity(at: metadataPath)))
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
        continue
      } catch FileSystemFailure.systemCall(_, let code) {
        issues.append(ApplicationOwnershipIssue(path: path, code: code))
        unresolvedApplicationMetadata.append(
          ApplicationMetadataIssue(path: path, error: FileSystemFailure.systemCall("application metadata", code)))
        if !path.hasPrefix("/System/") { complete = false }
      } catch {
        metadataIssues.append(ApplicationMetadataIssue(path: path, error: error))
        unresolvedApplicationMetadata.append(ApplicationMetadataIssue(path: path, error: error))
        if !path.hasPrefix("/System/") { complete = false }
      }
    }
    for app in selected where !apps.contains(where: { $0.path == app.path }) {
      if readApplication(at: app.path, allowProtected: false) == app { apps.append(app) }
    }
    for app in apps {
      let path = app.linkTarget ?? app.path
      for metadataPath in [path, Self.infoPlistPath(ofBundleAt: path)] {
        if let identity = try? DescriptorFileSystem.identity(at: metadataPath) {
          lineage.append(ApplicationPathObservation(path: metadataPath, identity: identity))
        } else if !path.hasPrefix("/System/") {
          complete = false
        }
      }
      if readApplication(at: path, allowProtected: true)?.bundleID != app.bundleID,
        !path.hasPrefix("/System/")
      {
        complete = false
      }
    }
    ownershipCollected()
    let owners = ApplicationOwnershipInventory.collect(
      roots: ownershipRoots, applications: apps, additionalCodePaths: registeredCodePaths.sorted(),
      onNativeRead: nativeRead)
    for root in ownershipRoots {
      if let identity = owners.roots[root] {
        lineage.append(ApplicationPathObservation(path: root, identity: identity))
      } else {
        do {
          lineage.append(ApplicationPathObservation(path: root, identity: try DescriptorFileSystem.identity(at: root)))
        } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
          lineage.append(ApplicationPathObservation(path: root, identity: nil))
        } catch {
          // Unreadable ownership roots already retain their scoped issue.
        }
      }
    }
    for (path, identity) in owners.directories {
      lineage.append(ApplicationPathObservation(path: path, identity: identity))
    }
    // New code-bearing locations in installation folders invalidate a saved
    // owner universe. No recursive walk is needed for these fresh checks.
    for owner in owners.candidates {
      if let identity = try? DescriptorFileSystem.identity(at: owner.path) {
        lineage.append(ApplicationPathObservation(path: owner.path, identity: identity))
      }
    }
    let inventory = BundleInventory(
      applications: apps.sorted { $0.path < $1.path }, unidentifiedPaths: unidentifiedPaths,
      complete: complete, observedAt: listing.observedAt, ownershipCandidates: owners.candidates,
      ownershipComplete: owners.thirdPartyComplete && registered.complete
        && issues.allSatisfy(\.systemScope), ownershipIssues: owners.issues + issues,
      metadataIssues: metadataIssues + owners.metadataIssues,
      observedDirectories: listing.observedDirectories, installedRootsComplete: listing.complete,
      unresolvedApplicationMetadata: unresolvedApplicationMetadata.filter { !$0.path.hasPrefix("/System/") })
    return AuthenticApplicationContext(
      scope: contextScope, inventory: inventory, lineage: lineage, registeredPaths: registered.paths)
  }

  func isExactStandardSelection(app: InstalledApplication, candidates: [RelatedDataCandidate]) -> Bool {
    !candidates.isEmpty
      && candidates.allSatisfy {
        guard let (location, domain) = RelatedLocation.matching(path: $0.path, homeDirectory: homeDirectory) else {
          return false
        }
        return location != .groupContainers && domain == app.bundleID
      }
  }

  /// Exact bundle-ID data needs a current, unique installed owner, not the
  /// global code/signature universe. This scope cannot authorize group or
  /// team-prefixed data and does not claim full ownership completeness.
  func makeStandardContext(app: InstalledApplication, listing: BundleInventory) -> AuthenticApplicationContext {
    let registered = registeredByID(app.bundleID)
    var apps = listing.applications
    var complete = listing.complete && registered.complete
    var lineage = listing.observedDirectories
    for observed in listing.applications {
      let physical = observed.linkTarget ?? observed.path
      do {
        let current = try inspectApplication(at: physical, allowProtected: true)
        if current?.bundleID != observed.bundleID {
          if foldedAppID(observed.bundleID) == foldedAppID(app.bundleID)
            || current.map({ foldedAppID($0.bundleID) == foldedAppID(app.bundleID) }) == true
          {
            complete = false
          } else if let index = apps.firstIndex(where: { $0.path == observed.path }) {
            if let current {
              apps[index] = InstalledApplication(
                bundleID: current.bundleID, path: observed.path, version: current.version,
                linkTarget: observed.linkTarget)
            } else {
              apps.remove(at: index)
            }
          }
        }
      } catch { complete = false }
      for path in [observed.path, physical, Self.infoPlistPath(ofBundleAt: physical)] {
        if let identity = try? DescriptorFileSystem.identity(at: path) {
          lineage.append(ApplicationPathObservation(path: path, identity: identity))
        } else {
          complete = false
        }
      }
    }
    for path in registered.paths where !ApplicationRegistration.isTrash(path) {
      do {
        let identity = try DescriptorFileSystem.identity(at: path)
        let current = try inspectRegisteredApplication(at: path)
        guard let current else {
          // Readable launchers without an identifier cannot claim this ID.
          continue
        }
        lineage.append(ApplicationPathObservation(path: path, identity: identity))
        let info = Self.infoPlistPath(ofBundleAt: current.linkTarget ?? current.path)
        lineage.append(ApplicationPathObservation(path: info, identity: try DescriptorFileSystem.identity(at: info)))
        if foldedAppID(current.bundleID) == foldedAppID(app.bundleID),
          !apps.contains(where: { ($0.linkTarget ?? $0.path) == (current.linkTarget ?? current.path) })
        {
          apps.append(current)
        }
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT { continue } catch { complete = false }
    }
    if !apps.contains(where: { $0.path == app.path }), application(at: app.path) == app {
      apps.append(app)
      for path in [app.path, app.path + "/Contents/Info.plist", (app.path as NSString).deletingLastPathComponent] {
        if let identity = try? DescriptorFileSystem.identity(at: path) {
          lineage.append(ApplicationPathObservation(path: path, identity: identity))
        } else {
          complete = false
        }
      }
    }
    return AuthenticApplicationContext(
      scope: contextScope,
      inventory: BundleInventory(
        applications: apps.sorted { $0.path < $1.path }, unidentifiedPaths: listing.unidentifiedPaths,
        complete: complete, observedAt: Date(), ownershipComplete: false,
        metadataIssues: listing.metadataIssues, observedDirectories: listing.observedDirectories), lineage: lineage,
      registeredPaths: registered.paths, standardBundleID: app.bundleID)
  }

  func validateContext(
    _ context: AuthenticApplicationContext, groups: Bool, bundleIDs: Set<String> = []
  ) throws {
    if context.standardBundleID != nil, groups { throw RelatedFailure.unsupportedInstalledData }
    let selectedIDs = context.standardBundleID.map { Set([$0]) } ?? bundleIDs
    try validateLineage(context, groups: groups, bundleIDs: selectedIDs)
    if groups {
      let current = registration()
      guard current.complete, current.paths == context.registeredPaths else { throw RelatedFailure.incompleteInventory }
      try context.validateSignatures()
    } else {
      for id in selectedIDs {
        let registered = registeredByID(id)
        guard registered.complete else { throw RelatedFailure.incompleteInventory }
        for path in registered.paths where !ApplicationRegistration.isTrash(path) {
          do {
            guard let app = try decisionApplication(at: path, registered: true) else { continue }
            if foldedAppID(app.bundleID) == foldedAppID(id),
              !context.inventory.applications.contains(where: {
                ($0.linkTarget ?? $0.path) == (app.linkTarget ?? app.path)
                  && foldedAppID($0.bundleID) == foldedAppID(id)
              })
            {
              throw RelatedFailure.ambiguousOwner
            }
          } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT { continue }
        }
      }
    }
  }

  private func validateLineage(
    _ context: AuthenticApplicationContext, groups: Bool = false, bundleIDs: Set<String> = []
  ) throws {
    guard context.scope == contextScope else { throw RelatedFailure.changedItem }
    if groups {
      for observation in context.lineage where !observation.path.hasPrefix("/System/") {
        try observation.validate()
      }
      return
    }
    // Standard domains depend on installed IDs, not every mutable cache and
    // resource directory walked while collecting potential group owners.
    let apps = context.inventory.applications
    let packages = Set(apps.flatMap { [$0.path, $0.linkTarget ?? $0.path] } + context.inventory.unidentifiedPaths)
    for observation in context.inventory.observedDirectories {
      if packages.contains(where: { observation.path == $0 || observation.path.hasPrefix($0 + "/") }) { continue }
      try observation.validate()
    }
    let foldedIDs = Set(bundleIDs.map(foldedAppID))
    func affectsDecision(_ id: String) -> Bool {
      foldedIDs.contains(foldedAppID(id))
        || foldedIDs.contains { target in
          target.hasPrefix(foldedAppID(id) + ".") || target.hasPrefix(foldedAppID(id) + "-")
        }
    }
    for observed in apps {
      do {
        let physical = observed.linkTarget ?? observed.path
        let current =
          observed.linkTarget != nil
          ? try decisionApplication(at: observed.path, registered: true)
          : try decisionApplication(at: physical)
        if affectsDecision(observed.bundleID) {
          for observation in context.lineage
          where observation.path == observed.path
            || observation.path == physical || observation.path == Self.infoPlistPath(ofBundleAt: physical)
          { try observation.validate() }
          guard current?.bundleID == observed.bundleID else { throw RelatedFailure.changedItem }
        } else if let current, affectsDecision(current.bundleID) {
          // A sibling may acquire this ID in place without changing the
          // installation directory or updating LaunchServices first.
          throw RelatedFailure.ambiguousOwner
        }
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
        if affectsDecision(observed.bundleID) { throw RelatedFailure.changedItem }
      }
    }
    for path in context.inventory.unidentifiedPaths {
      do {
        if let app = try decisionApplication(at: path), affectsDecision(app.bundleID) {
          throw RelatedFailure.ambiguousOwner
        }
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT { continue }
    }
  }

  private func context(for plan: ActionPlan) throws -> AuthenticApplicationContext {
    if let context = planContexts.context(for: plan, scope: contextScope) { return context }
    // Eviction or a separately constructed legacy plan requires one fresh
    // validation universe for the whole plan, never one inventory per item.
    let selected = plan.items.compactMap { item -> InstalledApplication? in
      guard let proof = item.installedRelatedProof else { return nil }
      return readApplication(at: proof.appPath, allowProtected: false)
    }
    let context: AuthenticApplicationContext
    if let app = selected.first, selected.allSatisfy({ $0.bundleID == app.bundleID && $0.path == app.path }),
      plan.items.filter({ $0.installedRelatedProof != nil }).allSatisfy({ item in
        guard let (location, domain) = RelatedLocation.matching(path: item.sourcePath, homeDirectory: homeDirectory)
        else {
          return false
        }
        return location != .groupContainers && domain == app.bundleID
      })
    {
      context = makeStandardContext(app: app, listing: installedListing())
    } else {
      context = makeContext(including: selected)
    }
    planContexts.bind(plan, context: context)
    return context
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
    let flat = path + "/Info.plist"
    if (try? DescriptorFileSystem.identity(at: flat)) != nil { return flat }
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
    let context = makeContext()
    return await discover(
      inventory: context.inventory, only: nil,
      signatures: signatures(inventory: context.inventory, context: context))
  }

  /// A focused observation for a dropped or selected application.
  public func discover(for app: InstalledApplication) async -> [RelatedDataCandidate] {
    await focusedObservation(for: app).candidates
  }

  func focusedObservation(for app: InstalledApplication) async
    -> (candidates: [RelatedDataCandidate], signerTeamID: String?)
  {
    let context = makeContext(including: [app])
    let signatures = signatures(inventory: context.inventory, context: context, selected: app)
    return (
      await discover(inventory: context.inventory, only: app, signatures: signatures, allowReceipts: false),
      signatures[app.linkTarget ?? app.path]?.teamID
    )
  }

  /// Reads one explicitly selected application without walking installed roots.
  /// Returned metadata is an observation; action plans still revalidate it.
  public func application(at path: String) -> InstalledApplication? {
    readApplication(at: path, allowProtected: false)
  }

  private func readApplication(at path: String, allowProtected: Bool) -> InstalledApplication? {
    try? inspectApplication(at: path, allowProtected: allowProtected)
  }

  private func inspectApplication(at path: String, allowProtected: Bool) throws -> InstalledApplication? {
    guard ApplicationRegistration.hasApplicationSuffix(path),
      allowProtected || ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) == nil
    else { return nil }
    let identity = try DescriptorFileSystem.identity(at: path)
    guard identity.kind == .directory else { return nil }
    let infoPath = Self.infoPlistPath(ofBundleAt: path)
    let infoIdentity: FileIdentity
    do { infoIdentity = try DescriptorFileSystem.identity(at: infoPath) } catch FileSystemFailure.systemCall(
      _, let code)
      where code == ENOENT
    { throw ApplicationMetadataFailure.missingInfoPlist }
    guard infoIdentity.kind == .regular else { throw SecureMetadataFailure.unsafe }
    let dictionary = try ApplicationIdentity.metadata(ofBundleAt: path)
    guard try DescriptorFileSystem.identity(at: infoPath) == infoIdentity,
      try DescriptorFileSystem.identity(at: path) == identity
    else { throw FileSystemFailure.changedDuringInspection }
    guard dictionary["CFBundleIdentifier"] != nil else { return nil }
    guard let id = dictionary["CFBundleIdentifier"] as? String, Self.validBundleID(id) else {
      throw ApplicationMetadataFailure.invalidBundleIdentifier
    }
    return InstalledApplication(
      bundleID: id, path: path,
      version: (dictionary["CFBundleShortVersionString"] as? String) ?? (dictionary["CFBundleVersion"] as? String))
  }

  private func inspectRegisteredApplication(at path: String) throws -> InstalledApplication? {
    let identity = try DescriptorFileSystem.identity(at: path)
    guard identity.kind == .symbolicLink else { return try inspectApplication(at: path, allowProtected: true) }
    guard let resolved = realpath(path, nil) else { throw FileSystemFailure.systemCall("realpath", errno) }
    let physical = String(cString: resolved)
    free(resolved)
    guard let app = try inspectApplication(at: physical, allowProtected: true) else { return nil }
    guard try DescriptorFileSystem.identity(at: path) == identity else {
      throw FileSystemFailure.changedDuringInspection
    }
    return InstalledApplication(bundleID: app.bundleID, path: path, version: app.version, linkTarget: physical)
  }

  /// Observation diagnostics retain their precise metadata failure. Decisions
  /// expose the established ownership error types without granting authority
  /// when an application's current identifier cannot be established.
  private func decisionApplication(at path: String, registered: Bool = false) throws -> InstalledApplication? {
    do {
      if registered { return try inspectRegisteredApplication(at: path) }
      return try inspectApplication(at: path, allowProtected: true)
    } catch is ApplicationMetadataFailure {
      throw RelatedFailure.incompleteInventory
    } catch let error as SecureMetadataFailure {
      switch error {
      case .changed: throw RelatedFailure.changedItem
      case .unsafe, .tooLarge: throw RelatedFailure.incompleteInventory
      }
    } catch FileSystemFailure.changedDuringInspection {
      throw RelatedFailure.changedItem
    }
  }

  private func selectedContext(
    app: InstalledApplication, base: AuthenticApplicationContext
  ) throws -> AuthenticApplicationContext {
    if base.inventory.applications.contains(where: { $0.path == app.path }) { return base }
    guard application(at: app.path) == app else { throw RelatedFailure.changedItem }
    let current = base.inventory
    let listing = BundleInventory(
      applications: current.applications + [app], unidentifiedPaths: current.unidentifiedPaths,
      complete: current.complete, observedAt: current.observedAt, ownershipCandidates: current.ownershipCandidates,
      ownershipComplete: false, ownershipIssues: current.ownershipIssues, metadataIssues: current.metadataIssues,
      observedDirectories: current.observedDirectories, installedRootsComplete: current.installedRootsComplete,
      unresolvedApplicationMetadata: current.unresolvedApplicationMetadata)
    let paths = [app.path, app.path + "/Contents/Info.plist", (app.path as NSString).deletingLastPathComponent]
    return AuthenticApplicationContext(
      scope: base.scope, inventory: listing,
      lineage: base.lineage
        + (try paths.map {
          ApplicationPathObservation(
            path: $0, identity: try DescriptorFileSystem.identity(at: $0))
        }),
      registeredPaths: base.registeredPaths, standardBundleID: base.standardBundleID)
  }

  private func signingMetadata(_ path: String, context: AuthenticApplicationContext?) -> ApplicationSigningMetadata? {
    if let context { return context.signature(at: path, cache: signatureCache)?.metadata }
    return signingMetadata(path)
  }

  private func signatures(
    inventory: BundleInventory, context: AuthenticApplicationContext, selected: InstalledApplication? = nil
  ) -> [String: ApplicationSigningMetadata] {
    var result: [String: ApplicationSigningMetadata] = [:]
    let owners = inventory.ownershipCandidates.filter { !$0.path.hasPrefix("/System/") }
    if let selected {
      let physical = selected.linkTarget ?? selected.path
      result[physical] = signingMetadata(physical, context: context)
      result[selected.path] = result[physical]
      for owner in owners where owner.packagePath == selected.path {
        result[owner.path] = signingMetadata(owner.path, context: context)
      }
      let hasGroupData = result.values.flatMap(\.groupIdentifiers).contains {
        (try? DescriptorFileSystem.identity(
          at: RelatedLocation.groupContainers.path(domain: $0, homeDirectory: homeDirectory))) != nil
      }
      if !hasGroupData { return result }
    }
    for owner in owners { result[owner.path] = signingMetadata(owner.path, context: context) }
    return result
  }

  func initialReview(
    for app: InstalledApplication, progress: (@Sendable (ApplicationRelatedReview) -> Void)?
  ) async -> ApplicationRelatedReview {
    let listing = BundleInventory(applications: [app], unidentifiedPaths: [], complete: false, observedAt: Date())
    let candidates = await discover(inventory: listing, only: app, signatures: [:], allowReceipts: false) { partial in
      progress?(ApplicationRelatedReview(application: app, candidates: partial))
    }
    return ApplicationRelatedReview(application: app, candidates: candidates)
  }

  func review(for app: InstalledApplication, context: AuthenticApplicationContext) async -> ApplicationRelatedReview {
    var inventory = context.inventory
    let inUniverse = inventory.applications.contains { $0.path == app.path && $0.bundleID == app.bundleID }
    if !inUniverse, application(at: app.path) == app {
      inventory = BundleInventory(
        applications: inventory.applications + [app], unidentifiedPaths: inventory.unidentifiedPaths,
        complete: inventory.complete, observedAt: inventory.observedAt,
        ownershipCandidates: inventory.ownershipCandidates, ownershipComplete: false,
        ownershipIssues: inventory.ownershipIssues)
    }
    let signatures = signatures(inventory: inventory, context: context, selected: app)
    return ApplicationRelatedReview(
      application: app,
      candidates: await discover(inventory: inventory, only: app, signatures: signatures, allowReceipts: false),
      signerTeamID: signatures[app.linkTarget ?? app.path]?.teamID,
      ownershipPending: !inUniverse || !inventory.ownershipComplete)
  }

  func discover(context: AuthenticApplicationContext) async -> [RelatedDataCandidate] {
    await discover(
      inventory: context.inventory, only: nil,
      signatures: signatures(inventory: context.inventory, context: context), allowReceipts: false)
  }

  private func discover(
    inventory apps: BundleInventory, only app: InstalledApplication?,
    signatures suppliedSignatures: [String: ApplicationSigningMetadata]? = nil,
    allowReceipts: Bool = true,
    progress: (@Sendable ([RelatedDataCandidate]) -> Void)? = nil
  ) async
    -> [RelatedDataCandidate]
  {
    if Task.isCancelled { return [] }
    let standardInventoryComplete = standardInventoryIsComplete(apps)
    let receipts = (try? loadReceipts()) ?? []
    let receiptStoreHealthy = (try? loadReceipts()) != nil
    let signatures =
      suppliedSignatures
      ?? Dictionary(
        apps.ownershipCandidates.compactMap { owner -> (String, ApplicationSigningMetadata)? in
          signingMetadata(owner.path).map { (owner.path, $0) }
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
          domains = Array(
            Set(
              apps.ownershipCandidates.filter { $0.packagePath == app.path }
                .flatMap { signatures[$0.path]?.groupIdentifiers ?? [] }))
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
      let claimingPackages = Set(
        apps.ownershipCandidates.filter {
          signatures[$0.path]?.groupIdentifiers.contains(domain) == true
        }.map(\.packagePath))
      let groupOwners = apps.applications.filter { claimingPackages.contains($0.path) }
      let ownershipVerified =
        apps.ownershipComplete
        && apps.ownershipCandidates
          .filter { !$0.path.hasPrefix("/System/") }.allSatisfy { signatures[$0.path] != nil }
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
      if location == .groupContainers && (!ownershipVerified || domain.lowercased().hasPrefix("group.com.apple.")) {
        classification = .shared
        reason = ownershipVerified ? .sharedGroup : .ownershipUnavailable
      } else if location == .groupContainers && (claimingPackages.count != 1 || owners.count != 1) {
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
      } else if !standardInventoryComplete || !receiptStoreHealthy {
        classification = .uncertain
        reason = !standardInventoryComplete ? .incompleteInventory : .recordUnavailable
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
          if (standardInventoryComplete
            || (candidate.classification == .installed && candidate.matchStrength == .strong
              && RelatedLocation.matching(path: candidate.path, homeDirectory: homeDirectory)?.0 != .groupContainers))
            && receiptStoreHealthy && candidate.matchStrength != .weak,
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
        if !Task.isCancelled { progress?(results.filter { $0.observation != nil }) }
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
    if app == nil && allowReceipts && writeVerifiedReceipts && !Task.isCancelled && apps.complete && receiptStoreHealthy
    {
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
    try plan(candidate: candidate, context: makeContext())
  }

  @concurrent
  func availableOrphanPlan(
    candidate: RelatedDataCandidate, context: AuthenticApplicationContext
  ) async -> AvailableUninstallPlan {
    do {
      try Task.checkCancellation()
      return AvailableUninstallPlan(plan: try plan(candidate: candidate, context: context), rejections: [])
    } catch {
      return AvailableUninstallPlan(plan: nil, rejections: Self.uninstallRejections(error, path: candidate.path))
    }
  }

  private func plan(candidate: RelatedDataCandidate, context: AuthenticApplicationContext) throws -> ActionPlan {
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
    if candidate.classification == .historicallyVerifiedAbsent {
      guard let receipt = candidate.receipt else { throw RelatedFailure.invalidReceipt }
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
    if relatedProof != nil {
      try validate(item, plan: plan, context: context)
    } else {
      try validateOrphan(item, plan: plan, context: context)
    }
    planContexts.bind(plan, context: context)
    return plan
  }

  public func planInstalled(app: InstalledApplication, candidate: RelatedDataCandidate) throws -> ActionPlan {
    guard app.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame else {
      throw PlanRejection(.lightenItself, path: app.path)
    }
    _ = try packagePlan(app: app)
    let context = makeContext(including: [app])
    try validateContext(
      context, groups: candidate.path.contains("/Library/Group Containers/"), bundleIDs: [app.bundleID])
    return try planInstalled(app: app, candidate: candidate, context: context)
  }

  private func planInstalled(
    app: InstalledApplication, candidate: RelatedDataCandidate, context: AuthenticApplicationContext
  ) throws -> ActionPlan {
    let apps = context.inventory
    if let id = context.standardBundleID {
      guard id == app.bundleID, isExactStandardSelection(app: app, candidates: [candidate]) else {
        throw RelatedFailure.unsupportedInstalledData
      }
    }
    let groups = RelatedLocation.matching(path: candidate.path, homeDirectory: homeDirectory)?.0 == .groupContainers
    guard groups ? apps.complete : standardInventoryIsComplete(apps) else {
      throw RelatedFailure.incompleteInventory
    }
    guard apps.applications.filter({ foldedAppID($0.bundleID) == foldedAppID(app.bundleID) }).count == 1,
      apps.applications.contains(app), candidate.classification == .installed, candidate.canSelect,
      let observation = candidate.snapshot, let expected = observation.entries.first?.identity,
      let appIdentity = try? DescriptorFileSystem.identity(at: app.path), appIdentity.kind == .directory,
      let infoIdentity = try? DescriptorFileSystem.identity(at: app.path + "/Contents/Info.plist"),
      infoIdentity.kind == .regular,
      Self.bundleID(at: app.path) == app.bundleID,
      let policy = installedPolicy(app: app, relatedPath: candidate.path, inventory: apps, context: context)
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
    planContexts.bind(plan, context: context)
    try validateInstalled(item, plan: plan, context: context)
    return plan
  }

  public struct AvailableUninstallPlan: Sendable {
    public let plan: ActionPlan?
    public let rejections: [PlanRejection]

    public init(plan: ActionPlan?, rejections: [PlanRejection]) {
      self.plan = plan
      self.rejections = rejections
    }
  }

  /// Preflights the application first, then keeps independently valid data in
  /// one plan. Data-only choices still depend on a movable application.
  @concurrent
  public func makeAvailableUninstallPlan(
    app: InstalledApplication, selectedRelated: [RelatedDataCandidate], includePackage: Bool = true
  ) async -> AvailableUninstallPlan {
    await makeAvailableUninstallPlan(
      app: app, selectedRelated: selectedRelated, includePackage: includePackage,
      context: nil)
  }

  @concurrent
  func makeAvailableUninstallPlan(
    app: InstalledApplication, selectedRelated: [RelatedDataCandidate], includePackage: Bool,
    context suppliedContext: AuthenticApplicationContext?
  ) async -> AvailableUninstallPlan {
    let package: ActionPlan
    do {
      guard app.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame else {
        throw PlanRejection(.lightenItself, path: app.path)
      }
      package = try packagePlan(app: app)
      let running = NativeRunningApplicationSource()
      for id in [app.bundleID] + (package.items.first?.nestedApplicationIDs ?? []) {
        guard await running.isRunning(bundleID: id) == false else {
          throw PlanRejection(.applicationRunning, path: app.path, ruleID: id)
        }
      }
    } catch {
      return AvailableUninstallPlan(plan: nil, rejections: Self.uninstallRejections(error, path: app.path))
    }
    var context: AuthenticApplicationContext?
    var contextError: (any Error)?
    if !selectedRelated.isEmpty {
      do {
        let selected = try selectedContext(app: app, base: suppliedContext ?? makeContext(including: [app]))
        try validateContext(
          selected, groups: selectedRelated.contains { $0.path.contains("/Library/Group Containers/") },
          bundleIDs: [app.bundleID])
        context = selected
      } catch { contextError = error }
    }
    var items: [PlanItem] = []
    var rejections: [PlanRejection] = []
    for candidate in selectedRelated {
      do {
        if let contextError { throw contextError }
        guard let context, !Task.isCancelled else { throw CancellationError() }
        let selected = try planInstalled(app: app, candidate: candidate, context: context)
        guard !items.contains(where: { $0.sourcePath == candidate.path }) else { continue }
        items += selected.items
      } catch {
        rejections += Self.uninstallRejections(error, path: candidate.path)
      }
    }
    if includePackage { items += package.items }
    let plan =
      items.isEmpty
      ? nil
      : ActionPlan(
        snapshotRunID: items.first?.snapshotRunID ?? package.snapshotRunID, kind: .trash, items: items)
    if let plan, let context { planContexts.bind(plan, context: context) }
    return AvailableUninstallPlan(plan: plan, rejections: rejections)
  }

  /// A dry validation uses the same prepared-owner envelope as execution,
  /// without acquiring a journal lease or returning that envelope publicly.
  @concurrent
  func validatePlan(_ plan: ActionPlan) async -> [PlanRejection] {
    guard plan.schema == 1, plan.kind == .trash, !plan.items.isEmpty,
      Set(plan.items.map(\.id)).count == plan.items.count,
      Set(plan.items.map(\.sourcePath)).count == plan.items.count
    else {
      return plan.items.isEmpty
        ? [PlanRejection(.unavailable, path: "", ruleID: "empty-plan")]
        : plan.items.map { PlanRejection(.unavailable, path: $0.sourcePath, ruleID: "invalid-plan") }
    }
    let prepared = prepareInstalledOwners(plan: plan)
    let guardService = ActionGuard(homeDirectory: homeDirectory)
    let running = NativeRunningApplicationSource()
    var packageResults: [String: [PlanRejection]] = [:]
    var absentContext: AuthenticApplicationContext?
    var rejections: [PlanRejection] = []
    for item in plan.items {
      if Task.isCancelled {
        rejections.append(PlanRejection(.unavailable, path: item.sourcePath, ruleID: "cancelled"))
        continue
      }
      do {
        if let proof = item.installedRelatedProof {
          guard let owner = prepared.owners[item.id] else {
            throw PlanRejection(
              .unavailable, path: item.sourcePath,
              ruleID: prepared.failures[item.id] ?? "owner-unavailable")
          }
          if packageResults[proof.appPath] == nil {
            var packageRefusals: [PlanRejection] = []
            do {
              guard let app = application(at: proof.appPath), app.bundleID == proof.bundleID else {
                throw RelatedFailure.changedItem
              }
              let package = try packagePlan(app: app)
              for selected in package.items { try guardService.validate(selected) }
              for id in [app.bundleID] + (package.items.first?.nestedApplicationIDs ?? []) {
                switch await running.isRunning(bundleID: id) {
                case false: break
                case true: throw PlanRejection(.applicationRunning, path: app.path, ruleID: id)
                case nil: throw PlanRejection(.activityUnavailable, path: app.path, ruleID: id)
                }
              }
            } catch { packageRefusals = Self.uninstallRejections(error, path: proof.appPath) }
            packageResults[proof.appPath] = packageRefusals
          }
          if let failures = packageResults[proof.appPath], !failures.isEmpty {
            rejections += failures.map { PlanRejection($0.reason, path: item.sourcePath, ruleID: $0.ruleID) }
            continue
          }
          try guardService.validate(item, plan: plan, preparedOwner: owner)
          for id in item.nestedApplicationIDs ?? [] {
            guard id.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame else {
              throw PlanRejection(.lightenItself, path: item.sourcePath, ruleID: id)
            }
            switch await running.isRunning(bundleID: id) {
            case false: break
            case true: throw PlanRejection(.applicationRunning, path: item.sourcePath, ruleID: id)
            case nil: throw PlanRejection(.activityUnavailable, path: item.sourcePath, ruleID: id)
            }
          }
        } else if item.relatedProof != nil || item.orphanRelatedProof != nil {
          if absentContext == nil { absentContext = try context(for: plan) }
          guard let absentContext else { throw RelatedFailure.incompleteInventory }
          if item.relatedProof != nil {
            try validate(item, plan: plan, context: absentContext)
          } else {
            try validateOrphan(item, plan: plan, context: absentContext)
          }
          try guardService.validate(item)
          for entry in item.inventory {
            guard let identity = entry.identity,
              ExactInventory.isOpaquePackage(path: entry.path, identity: identity, policy: item.policy)
            else { continue }
            let activity = packageActivity(entry.path)
            switch activity.state {
            case .clearObservedProcesses: break
            case .active: throw ProcessActivityFailure.active(processNames: activity.processNames)
            case .unknown: throw ProcessActivityFailure.unavailable
            }
          }
          let ownerID = item.relatedProof?.bundleID ?? item.orphanRelatedProof?.bundleID
          for id in [ownerID].compactMap({ $0 }) + (item.nestedApplicationIDs ?? []) {
            switch await running.isRunning(bundleID: id) {
            case false: break
            case true: throw PlanRejection(.applicationRunning, path: item.sourcePath, ruleID: id)
            case nil: throw PlanRejection(.activityUnavailable, path: item.sourcePath, ruleID: id)
            }
          }
        } else {
          guard item.policy == .wholeBundle, item.relatedProof == nil, item.orphanRelatedProof == nil,
            item.catalogProof == nil, item.duplicateProof == nil,
            let app = application(at: item.sourcePath), app.bundleID == item.applicationBundleID,
            app.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame
          else { throw PlanRejection(.unavailable, path: item.sourcePath, ruleID: "invalid-scope") }
          // Activity is fresh even when a previously prepared package is still
          // byte-for-byte equal to its original plan.
          _ = try packagePlan(app: app)
          try guardService.validate(item)
          for id in [app.bundleID] + (item.nestedApplicationIDs ?? []) {
            switch await running.isRunning(bundleID: id) {
            case false: break
            case true: throw PlanRejection(.applicationRunning, path: item.sourcePath, ruleID: id)
            case nil: throw PlanRejection(.activityUnavailable, path: item.sourcePath, ruleID: id)
            }
          }
        }
      } catch { rejections += Self.uninstallRejections(error, path: item.sourcePath) }
    }
    return rejections
  }

  private static func uninstallRejections(_ error: any Error, path: String) -> [PlanRejection] {
    if let rejection = error as? PlanRejection { return [rejection] }
    if let rejections = error as? PlanRejections { return rejections.rejections }
    if let activity = error as? ProcessActivityFailure {
      switch activity {
      case .active(let names): return [PlanRejection(.processActive, path: path, ruleID: names.joined(separator: ", "))]
      case .unavailable: return [PlanRejection(.activityUnavailable, path: path)]
      }
    }
    return [PlanRejection(.unavailable, path: path, ruleID: String(describing: error))]
  }

  /// One action and one grouped Undo for an application and explicitly selected data.
  public func planUninstall(app: InstalledApplication, selectedRelated: [RelatedDataCandidate]) throws -> ActionPlan {
    guard app.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame else {
      throw PlanRejection(.lightenItself, path: app.path)
    }
    let package = try packagePlan(app: app)
    let context = selectedRelated.isEmpty ? nil : makeContext(including: [app])
    if let context {
      try validateContext(
        context, groups: selectedRelated.contains { $0.path.contains("/Library/Group Containers/") },
        bundleIDs: [app.bundleID])
    }
    var items: [PlanItem] = []
    for candidate in selectedRelated {
      guard let context else { throw RelatedFailure.incompleteInventory }
      items += try planInstalled(app: app, candidate: candidate, context: context).items
    }
    items += package.items
    let plan = ActionPlan(
      snapshotRunID: items.first?.snapshotRunID ?? package.snapshotRunID, kind: .trash, items: items)
    if let context { planContexts.bind(plan, context: context) }
    return plan
  }

  func packagePlan(app: InstalledApplication) throws -> ActionPlan {
    guard Self.currentUserOwns(app.path) else { throw PlanRejection(.needsAdministrator, path: app.path) }
    if app.linkTarget != nil || (try? DescriptorFileSystem.identity(at: app.path))?.kind == .symbolicLink {
      throw PlanRejection(.symbolicLinkRoot, path: app.path)
    }
    guard Self.infoPlistPath(ofBundleAt: app.path) == app.path + "/Contents/Info.plist" else {
      throw PlanRejection(.unavailable, path: app.path, ruleID: "ios-wrapper")
    }
    let observation = packageActivity(app.path)
    switch observation.state {
    case .clearObservedProcesses: break
    case .active: throw ProcessActivityFailure.active(processNames: observation.processNames)
    case .unknown: throw ProcessActivityFailure.unavailable
    }
    let identity = try DescriptorFileSystem.identity(at: app.path)
    let package = try PlanService(homeDirectory: homeDirectory).makeSpacePlan(
      selections: [PlanService.Selection(path: app.path, device: identity.device, inode: identity.inode)],
      scanRootPath: (app.path as NSString).deletingLastPathComponent, runID: UUID())
    guard package.items.first?.applicationBundleID == app.bundleID else { throw RelatedFailure.changedItem }
    return package
  }

  func installedPolicy(
    app: InstalledApplication, relatedPath: String, inventory: BundleInventory,
    context: AuthenticApplicationContext? = nil
  ) -> TreePolicy? {
    guard let (location, domain) = RelatedLocation.matching(path: relatedPath, homeDirectory: homeDirectory) else {
      return nil
    }
    if location == .groupContainers {
      guard inventory.ownershipComplete, !domain.lowercased().hasPrefix("group.com.apple.") else { return nil }
      var owners: Set<String> = []
      for candidate in inventory.ownershipCandidates where !candidate.path.hasPrefix("/System/") {
        guard let signature = signingMetadata(candidate.path, context: context) else { return nil }
        if signature.groupIdentifiers.contains(domain) { owners.insert(candidate.packagePath) }
      }
      return owners == [app.path] ? .relatedGroupContainer : nil
    }
    if domain != app.bundleID {
      guard let team = signingMetadata(app.path, context: context)?.teamID,
        domain == team + "." + app.bundleID || domain.hasPrefix(team + "." + app.bundleID + ".")
      else { return nil }
    }
    return location == .containers ? .relatedContainer : .relatedTrash
  }

  func prepareInstalledOwners(plan: ActionPlan) -> InstalledOwnerPreparation {
    let items = plan.items.filter { $0.installedRelatedProof != nil }
    guard !items.isEmpty else { return InstalledOwnerPreparation() }
    var result = InstalledOwnerPreparation()
    let context: AuthenticApplicationContext
    do {
      context = try self.context(for: plan)
      try validateContext(
        context, groups: items.contains { $0.policy == .relatedGroupContainer },
        bundleIDs: Set(items.compactMap { $0.installedRelatedProof?.bundleID }))
    } catch {
      for item in items { result.failures[item.id] = String(describing: error) }
      return result
    }
    let apps = context.inventory
    for item in items {
      do {
        try validateInstalled(item, plan: plan, context: context)
        guard let proof = item.installedRelatedProof,
          let (location, domain) = RelatedLocation.matching(path: item.sourcePath, homeDirectory: homeDirectory)
        else { throw RelatedFailure.unsupportedInstalledData }
        // Exact-ID data is authorized by the current private app/Info proof.
        // Cryptographic code identity is additional authority only when a
        // group entitlement or a team prefix supplied the ownership claim.
        var identities: [ApplicationSignatureIdentity] = []
        if location == .groupContainers {
          identities.append(try ApplicationSignatureIdentity.capture(proof.appPath))
          let selected = apps.ownershipCandidates.filter { $0.packagePath == proof.appPath }
          guard !selected.isEmpty else { throw RelatedFailure.ambiguousOwner }
          for owner in selected {
            guard let observation = context.signature(at: owner.path, cache: signatureCache),
              observation.metadata != nil
            else {
              throw RelatedFailure.unsupportedInstalledData
            }
            identities.append(observation.identity)
          }
        } else if domain != proof.bundleID {
          identities.append(try ApplicationSignatureIdentity.capture(proof.appPath))
          guard let observation = context.signature(at: proof.appPath, cache: signatureCache),
            observation.metadata != nil
          else {
            throw RelatedFailure.unsupportedInstalledData
          }
          identities.append(observation.identity)
        }
        for identity in identities { try identity.validate() }
        result.owners[item.id] = PreparedInstalledOwner(planID: plan.id, item: item, signatures: identities)
      } catch { result.failures[item.id] = String(describing: error) }
    }
    return result
  }

  public func validateInstalled(_ item: PlanItem, plan: ActionPlan) throws {
    let context = try self.context(for: plan)
    try validateContext(
      context, groups: item.policy == .relatedGroupContainer,
      bundleIDs: Set([item.installedRelatedProof?.bundleID].compactMap { $0 }))
    try validateInstalled(item, plan: plan, context: context)
  }

  private func validateInstalled(
    _ item: PlanItem, plan: ActionPlan, context: AuthenticApplicationContext
  ) throws {
    let apps = context.inventory
    if let id = context.standardBundleID {
      guard let proof = item.installedRelatedProof, proof.bundleID == id,
        let (location, domain) = RelatedLocation.matching(path: item.sourcePath, homeDirectory: homeDirectory),
        location != .groupContainers, domain == id
      else { throw RelatedFailure.unsupportedInstalledData }
    }
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
    guard item.policy == .relatedGroupContainer ? apps.complete : standardInventoryIsComplete(apps) else {
      throw RelatedFailure.incompleteInventory
    }
    guard
      apps.applications.filter({ foldedAppID($0.bundleID) == foldedAppID(proof.bundleID) }).map(\.path) == [
        proof.appPath
      ],
      let app = apps.applications.first(where: { $0.path == proof.appPath }),
      let policy = installedPolicy(app: app, relatedPath: item.sourcePath, inventory: apps, context: context),
      item.policy == nil || item.policy == policy
    else { throw RelatedFailure.ambiguousOwner }
  }

  public func validateOrphan(_ item: PlanItem, plan: ActionPlan) throws {
    try validateOrphan(item, plan: plan, context: makeContext())
  }

  private func validateOrphan(_ item: PlanItem, plan: ActionPlan, context: AuthenticApplicationContext) throws {
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
    try validateAbsentOwner(bundleID: proof.bundleID, context: context)
  }

  public func validate(_ item: PlanItem, plan: ActionPlan) throws {
    try validate(item, plan: plan, context: makeContext())
  }

  private func validate(_ item: PlanItem, plan: ActionPlan, context: AuthenticApplicationContext) throws {
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
    try validateAbsentOwner(bundleID: proof.bundleID, context: context)
  }

  private func validateAbsentOwner(bundleID: String, context: AuthenticApplicationContext) throws {
    // Absence is never granted by the selected-owner-only standard scope.
    guard context.standardBundleID == nil else { throw RelatedFailure.unsupportedInstalledData }
    try validateLineage(context, bundleIDs: [bundleID])
    let apps = context.inventory
    guard standardInventoryIsComplete(apps) else { throw RelatedFailure.incompleteInventory }
    let registered = registeredByID(bundleID)
    guard registered.complete else { throw RelatedFailure.incompleteInventory }
    for path in registered.paths where !ApplicationRegistration.isTrash(path) {
      do {
        let current = try decisionApplication(at: path, registered: true)
        guard let current else {
          continue
        }
        if foldedAppID(current.bundleID) == foldedAppID(bundleID) { throw RelatedFailure.ownerPresent }
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT { continue }
    }
    guard !apps.contains(bundleID), !installedElsewhere(bundleID),
      !apps.applications.contains(where: {
        bundleID.hasPrefix($0.bundleID + "-") || bundleID.hasPrefix($0.bundleID + ".")
      })
    else { throw RelatedFailure.ownerPresent }
  }

  static func currentUserOwns(_ path: String) -> Bool {
    var details = stat()
    return lstat(path, &details) == 0 && details.st_uid == geteuid()
  }

  private func standardInventoryIsComplete(_ inventory: BundleInventory) -> Bool {
    (inventory.installedRootsComplete ?? inventory.complete) && inventory.unresolvedApplicationMetadata.isEmpty
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
        let app = InstalledApplication(bundleID: proof.bundleID, path: proof.appPath, version: nil)
        let bound = planContexts.context(for: plan, scope: contextScope)
        let owners: [ApplicationOwnerCandidate]
        if let bound {
          guard bound.inventory.ownershipComplete else { throw RelatedFailure.unsupportedInstalledData }
          owners = bound.inventory.ownershipCandidates.filter { $0.packagePath == app.path }
        } else {
          let observed = ApplicationOwnershipInventory.collect(roots: [], applications: [app])
          guard observed.complete else { throw RelatedFailure.unsupportedInstalledData }
          owners = observed.candidates
        }
        guard !owners.isEmpty, !domain.lowercased().hasPrefix("group.com.apple.") else {
          throw RelatedFailure.unsupportedInstalledData
        }
        var claimed = false
        for owner in owners {
          guard let signature = signingMetadata(owner.path, context: bound) else {
            throw RelatedFailure.unsupportedInstalledData
          }
          claimed = claimed || (owner.packagePath == app.path && signature.groupIdentifiers.contains(domain))
        }
        guard claimed else { throw RelatedFailure.unsupportedInstalledData }
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
