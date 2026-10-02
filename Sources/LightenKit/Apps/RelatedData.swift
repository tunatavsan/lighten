import Darwin
import Foundation
import Synchronization

/// Native signing and process APIs can wait on libdispatch internally. Keep
/// that blocking work off Swift's cooperative executor and bound concurrency.
private enum ApplicationEvidenceWork {
  private static let queue = DispatchQueue(label: "com.tavsn.lighten.application-evidence", qos: .utility)
  final class Cancellation: Sendable {
    private let cancelled = Mutex(false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
  }

  static func perform<Value: Sendable>(
    cancelledValue: Value, _ work: @escaping @Sendable (Cancellation) -> Value
  ) async -> Value {
    let cancellation = Cancellation()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        queue.async {
          continuation.resume(returning: cancellation.isCancelled ? cancelledValue : work(cancellation))
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }
}

public struct InstalledApplication: Sendable, Equatable {
  public let bundleID: String
  public let path: String
  public let version: String?
  /// Set when `path` is a symbolic link; the app lives at this resolved location.
  /// A linked app is identified read-only and never followed for an action.
  public var linkTarget: String? = nil
}

public struct ApplicationScopeExclusion: Sendable, Equatable {
  public let path: String
  public let bundleID: String?
  public let reason: String
  public let nextStep: String

  public init(path: String, bundleID: String?, reason: String, nextStep: String) {
    self.path = path
    self.bundleID = bundleID
    self.reason = reason
    self.nextStep = nextStep
  }
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
  public var scopeExclusions: [ApplicationScopeExclusion] = []
  public var registrationReport: ApplicationRegistrationReport? = nil
  var observedDirectories: [ApplicationPathObservation] = []
  // Completeness of the installed roots, before unrelated registration leads
  // are enriched. Only a private service context can use this with fresh
  // per-ID registration to prove a standard domain's owner or absence.
  var installedRootsComplete: Bool? = nil
  var unresolvedApplicationMetadata: [ApplicationMetadataIssue] = []
  var applicationMetadata: [ApplicationMetadataObservation] = []

  public func contains(_ bundleID: String) -> Bool {
    applications.contains { foldedAppID($0.bundleID) == foldedAppID(bundleID) }
  }
}

private func foldedAppID(_ value: String) -> String {
  value.lowercased(with: Locale(identifier: "en_US_POSIX"))
}

public enum RelatedClassification: String, Sendable {
  case installed, historicallyVerifiedAbsent, orphanVerified, uncertain, protected, shared
  case unprovenNameOnly
}

public enum RelatedReason: String, Sendable {
  case candidateAreaUnreadable, recordUnsafe, protected, installed
  case incompleteInventory, recordUnavailable, historicallyVerified, nameOnly
  case registrationUnavailable, liveCensusUnavailable
  case sharedGroup, sharedInstalledData, literalIdentifierOwner, installedElsewhere, orphanVerified, foreignOwner,
    mediumMatch, ownershipUnavailable
}

public enum RelatedOwnershipRefusalReason: String, Sendable, Codable {
  case unknownMetadata, observedLiteralOwner, sharedInstalledOwners, infoAbsenceChanged
}

/// Display evidence only. Ownership decisions use the service's private native observations.
public struct RelatedOwnershipRefusalEvidence: Sendable, Equatable {
  public let candidatePath: String
  public let bundleID: String?
  public let reason: RelatedOwnershipRefusalReason
  public let ownerPaths: [String]
  public let nextStep: String
  public let detail: String?
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
  public var refusalEvidence: [RelatedOwnershipRefusalEvidence] = []
  public var provenance: RelatedDataProvenance? = nil
  /// Explicit UI authorization is passed separately; this marker is not authority.
  public var explicitManualChoiceAvailable: Bool = false
  /// All observed proof kinds, independent of the first display provenance.
  public var evidenceKinds: [RelatedDataProvenanceKind] = []
  /// Root metadata for display and explicit user choice, never an ownership grant.
  public var displayRootIdentity: FileIdentity? = nil

  public var canSelect: Bool {
    (classification == .installed || classification == .historicallyVerifiedAbsent
      || classification == .orphanVerified)
      && matchStrength != .weak && snapshot != nil
  }

  public var defaultSelected: Bool {
    automaticSelectionAllowed && classification == .installed && matchStrength == .strong
      && !path.contains("/Library/Group Containers/")
      && provenance?.kind != .configuredDirectory
  }

  public var automaticSelectionAllowed: Bool {
    guard canSelect else { return false }
    let kinds = evidenceKinds.isEmpty ? provenance.map { [$0.kind] } ?? [] : evidenceKinds
    return kinds.isEmpty || kinds.contains { $0 != .liveProcess && $0 != .vendorDirectory && $0 != .executableName }
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

private enum InstalledListingFailure: Error {
  case traversalLimitExceeded, unsupportedDirectory, unsupportedEntry, unfollowedDirectoryLink
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
  private let liveData: @Sendable () -> ApplicationLiveDataObservation
  private let relatedMeasurement: @Sendable (String, String) async -> ApplicationDiscovery.Measurement
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
    self.liveData = { .observe() }
    self.relatedMeasurement = ApplicationDiscovery.measure
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
    nativeRead: (@Sendable (String) -> Void)? = nil,
    liveData: @escaping @Sendable () -> ApplicationLiveDataObservation = {
      ApplicationLiveDataObservation(records: [], complete: true)
    },
    relatedMeasurement: @escaping @Sendable (String, String) async -> ApplicationDiscovery.Measurement =
      ApplicationDiscovery.measure
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
    self.liveData = liveData
    self.relatedMeasurement = relatedMeasurement
  }

  public func inventory() -> BundleInventory { makeContext().inventory }

  /// Configured discovery roots only; no ownership or action authority.
  var lightweightListingRoots: [String] {
    applicationRoots + ownershipRoots.filter { $0 == "/System/Applications" || $0 == "/System/Library/CoreServices" }
  }

  /// Initial installed metadata has no code-owner or signature walk.
  func installedListing() -> BundleInventory {
    var apps: [InstalledApplication] = []
    var unidentifiedPaths: [String] = []
    var complete = true
    var rootsComplete = true
    var visited = 0
    var directories: [ApplicationPathObservation] = []
    var metadataIssues: [ApplicationMetadataIssue] = []
    var issues: [ApplicationOwnershipIssue] = []
    var applicationMetadata: [ApplicationMetadataObservation] = []
    var scopeExclusions: [ApplicationScopeExclusion] = []

    func recordExclusion(_ excluded: ApplicationScopeExclusion, identity: FileIdentity) {
      scopeExclusions.append(excluded)
      let observation = ApplicationMetadataObservation.read(at: excluded.path)
      applicationMetadata.append(observation)
      directories.append(ApplicationPathObservation(path: excluded.path, identity: identity))
      switch observation.state {
      case .unknown, .absentInfo:
        complete = false
        metadataIssues.append(
          ApplicationMetadataIssue(
            path: excluded.path, error: ApplicationMetadataFailure.invalidInfoPlist))
      case .declaredID, .identifierless: break
      }
    }

    func listingFailure(_ path: String, _ error: any Error) {
      complete = false
      rootsComplete = false
      if let failure = error as? FileSystemFailure, case .systemCall(_, let code) = failure {
        issues.append(ApplicationOwnershipIssue(path: path, code: code))
      } else {
        metadataIssues.append(ApplicationMetadataIssue(path: path, error: error))
      }
    }

    func visit(_ root: String, depth: Int, volumeID: UUID?) {
      guard depth <= 4, visited < 10_000 else {
        listingFailure(root, InstalledListingFailure.traversalLimitExceeded)
        return
      }
      let identity: FileIdentity
      let currentVolume: UUID?
      do {
        identity = try DescriptorFileSystem.identity(at: root)
        currentVolume = try DescriptorFileSystem.volumeID(at: root)
      } catch {
        listingFailure(root, error)
        return
      }
      guard identity.kind == .directory, currentVolume == volumeID,
        ProtectionPolicy.rule(for: root, homeDirectory: homeDirectory) == nil
      else {
        listingFailure(root, InstalledListingFailure.unsupportedDirectory)
        return
      }
      directories.append(ApplicationPathObservation(path: root, identity: identity))
      let names: [String]
      do { names = try DescriptorFileSystem.children(at: root, expected: identity) } catch {
        listingFailure(root, error)
        return
      }
      for name in names {
        visited += 1
        if visited > 10_000 {
          listingFailure(root, InstalledListingFailure.traversalLimitExceeded)
          return
        }
        let path = root + "/" + name
        let child: FileIdentity
        do { child = try DescriptorFileSystem.identity(at: path) } catch {
          listingFailure(path, error)
          continue
        }
        guard child.device == identity.device, child.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
          ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) == nil
        else {
          listingFailure(path, InstalledListingFailure.unsupportedEntry)
          continue
        }
        if child.kind == .symbolicLink {
          if let excluded = scopeExclusion(at: path) {
            recordExclusion(excluded, identity: child)
            continue
          }
          // Resolve read-only: the link's target identifies an app, never an action path.
          if let linked = Self.resolveLinkedApplication(at: path) {
            applicationMetadata.append(ApplicationMetadataObservation.read(at: path))
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
            let observation = ApplicationMetadataObservation.read(at: path)
            if ApplicationRegistration.hasApplicationSuffix(observation.physicalPath),
              observation.root != nil
            {
              applicationMetadata.append(observation)
              unidentifiedPaths.append(path)
              directories.append(ApplicationPathObservation(path: path, identity: child))
              switch observation.state {
              case .identifierless: break
              case .absentInfo:
                complete = false
                metadataIssues.append(
                  ApplicationMetadataIssue(
                    path: path, error: ApplicationMetadataFailure.missingInfoPlist))
              case .declaredID, .unknown:
                complete = false
                metadataIssues.append(
                  ApplicationMetadataIssue(
                    path: path, error: ApplicationMetadataFailure.invalidInfoPlist))
              }
            } else {
              // A link to a folder may hide apps that are never followed.
              listingFailure(path, InstalledListingFailure.unfollowedDirectoryLink)
            }
          }
          continue
        }
        guard child.kind == .directory else { continue }
        if name.lowercased(with: Locale(identifier: "en_US_POSIX")).hasSuffix(".app") {
          applicationMetadata.append(ApplicationMetadataObservation.read(at: path))
          if let excluded = scopeExclusion(at: path) {
            recordExclusion(excluded, identity: child)
            continue
          }
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
        directories.append(ApplicationPathObservation(path: root, identity: nil))
        continue
      } catch {
        listingFailure(root, error)
        continue
      }
      let volumeID: UUID?
      do { volumeID = try DescriptorFileSystem.volumeID(at: root) } catch {
        listingFailure(root, error)
        continue
      }
      guard rootIdentity.kind == .directory, volumeID != nil else {
        listingFailure(root, InstalledListingFailure.unsupportedDirectory)
        continue
      }
      visit(root, depth: 0, volumeID: volumeID)
    }
    return BundleInventory(
      applications: apps.sorted { $0.path < $1.path }, unidentifiedPaths: unidentifiedPaths,
      complete: complete, observedAt: Date(), ownershipIssues: issues,
      metadataIssues: metadataIssues, scopeExclusions: scopeExclusions,
      observedDirectories: directories,
      installedRootsComplete: rootsComplete, unresolvedApplicationMetadata: metadataIssues,
      applicationMetadata: applicationMetadata)
  }

  static func isSimulatorDeviceApplication(_ path: String, homeDirectory: String) -> Bool {
    guard let components = try? DescriptorFileSystem.validatedComponents(path),
      let home = try? DescriptorFileSystem.validatedComponents(homeDirectory)
    else { return false }
    let aliases = [home, ["System", "Volumes", "Data"] + home]
    for prefix in aliases where components.starts(with: prefix) {
      let suffix = Array(components.dropFirst(prefix.count))
      guard suffix.count >= 11,
        Array(suffix.prefix(4)) == ["Library", "Developer", "CoreSimulator", "Devices"],
        !suffix[4].isEmpty,
        Array(suffix[5..<9]) == ["data", "Containers", "Bundle", "Application"],
        !suffix[9].isEmpty,
        ApplicationRegistration.hasApplicationSuffix(suffix[10])
      else { continue }
      return true
    }
    return false
  }

  func scopeExclusion(at path: String) -> ApplicationScopeExclusion? {
    let observation = ApplicationMetadataObservation.read(at: path)
    guard observation.root?.kind == .directory,
      Self.isSimulatorDeviceApplication(path, homeDirectory: homeDirectory)
        || Self.isSimulatorDeviceApplication(observation.physicalPath, homeDirectory: homeDirectory)
    else { return nil }
    let id: String?
    if case .declaredID(let declared) = observation.state { id = declared } else { id = nil }
    return ApplicationScopeExclusion(
      path: path, bundleID: id, reason: "simulator-device-application",
      nextStep: "Remove from the simulator using Xcode > Devices or xcrun simctl uninstall.")
  }

  static func isDanglingLink(_ path: String) -> Bool {
    if let resolved = realpath(path, nil) {
      free(resolved)
      return false
    }
    return errno == ENOENT
  }

  func makeContext(
    base: BundleInventory? = nil, including selected: [InstalledApplication] = [],
    metadata: ApplicationContextMetadata? = nil
  )
    -> AuthenticApplicationContext
  {
    let listing = base ?? installedListing()
    let registered = registration()
    var apps = listing.applications
    var issues = listing.ownershipIssues
    var metadataIssues = listing.metadataIssues
    var unresolvedApplicationMetadata = listing.metadataIssues
    var applicationMetadata = listing.applicationMetadata
    var scopeExclusions = listing.scopeExclusions
    var unidentifiedPaths = listing.unidentifiedPaths
    var registeredCodePaths = Set(
      listing.scopeExclusions.compactMap { exclusion in
        let observation = ApplicationMetadataObservation.read(at: exclusion.path)
        return observation.root == nil ? nil : observation.physicalPath
      })
    var complete = listing.complete && registered.complete
    var lineage = listing.observedDirectories
    for path in registered.paths {
      if ApplicationRegistration.isTrash(path) { continue }
      do {
        let identity = try DescriptorFileSystem.identity(at: path)
        if !applicationMetadata.contains(where: { $0.path == path }),
          identity.kind == .directory || identity.kind == .symbolicLink
        {
          applicationMetadata.append(ApplicationMetadataObservation.read(at: path))
        }
        if identity.kind == .directory {
          registeredCodePaths.insert(path)
        } else if identity.kind == .symbolicLink, let resolved = realpath(path, nil) {
          let physical = String(cString: resolved)
          free(resolved)
          if (try? DescriptorFileSystem.identity(at: physical))?.kind == .directory {
            registeredCodePaths.insert(physical)
          }
        }
        if let excluded = scopeExclusion(at: path) {
          if !scopeExclusions.contains(excluded) { scopeExclusions.append(excluded) }
          let observation = ApplicationMetadataObservation.read(at: path)
          switch observation.state {
          case .unknown, .absentInfo:
            let issue = ApplicationMetadataIssue(
              path: path, error: ApplicationMetadataFailure.invalidInfoPlist)
            metadataIssues.append(issue)
            unresolvedApplicationMetadata.append(issue)
            if !path.hasPrefix("/System/") { complete = false }
          case .declaredID, .identifierless: break
          }
          continue
        }
        let observed =
          identity.kind == .symbolicLink
          ? Self.resolveLinkedApplication(at: path) : try inspectApplication(at: path, allowProtected: true)
        guard let app = observed else {
          if identity.kind == .symbolicLink, Self.isDanglingLink(path) { continue }
          // An identifierless, readable launcher cannot own an exact-ID
          // domain. It remains visible and still contributes code candidates.
          let observation = ApplicationMetadataObservation.read(at: path)
          if identity.kind == .directory
            || (observation.root != nil && ApplicationRegistration.hasApplicationSuffix(observation.physicalPath))
          {
            if !unidentifiedPaths.contains(path) { unidentifiedPaths.append(path) }
            if identity.kind == .symbolicLink {
              switch observation.state {
              case .identifierless: break
              case .absentInfo, .declaredID, .unknown:
                let issue = ApplicationMetadataIssue(path: path, error: ApplicationMetadataFailure.invalidInfoPlist)
                metadataIssues.append(issue)
                unresolvedApplicationMetadata.append(issue)
                if !path.hasPrefix("/System/") { complete = false }
              }
            }
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
      metadataIssues: metadataIssues + owners.metadataIssues, scopeExclusions: scopeExclusions,
      registrationReport: registered.report,
      observedDirectories: listing.observedDirectories,
      installedRootsComplete: listing.installedRootsComplete,
      unresolvedApplicationMetadata: unresolvedApplicationMetadata.filter {
        !$0.path.hasPrefix("/System/")
      },
      applicationMetadata: applicationMetadata)
    return AuthenticApplicationContext(
      scope: contextScope, inventory: inventory, lineage: lineage, registeredPaths: registered.paths,
      installedListing: listing, metadata: metadata)
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
  func makeStandardContext(
    app: InstalledApplication, listing: BundleInventory, metadata: ApplicationContextMetadata? = nil,
    dataEvidenceSource: AuthenticApplicationContext? = nil
  ) -> AuthenticApplicationContext {
    let metadata = metadata ?? ApplicationContextMetadata()
    let registered = registeredByID(app.bundleID)
    var apps = listing.applications
    var complete = listing.complete && registered.complete
    var rootsComplete = (listing.installedRootsComplete ?? listing.complete) && registered.complete
    var applicationMetadata = listing.applicationMetadata
    var lineage = listing.observedDirectories
    for observed in listing.applications {
      let physical = observed.linkTarget ?? observed.path
      do {
        let current = try decisionApplication(
          at: observed.path, registered: observed.linkTarget != nil, metadata: metadata)
        if current?.bundleID != observed.bundleID {
          if foldedAppID(observed.bundleID) == foldedAppID(app.bundleID)
            || current.map({ foldedAppID($0.bundleID) == foldedAppID(app.bundleID) }) == true
          {
            complete = false
            rootsComplete = false
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
        if !applicationMetadata.contains(where: { $0.path == path }) {
          applicationMetadata.append(ApplicationMetadataObservation.read(at: path))
        }
        let current = try decisionApplication(at: path, registered: true, metadata: metadata)
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
      for path in [
        app.path, Self.infoPlistPath(ofBundleAt: app.path),
        (app.path as NSString).deletingLastPathComponent,
      ] {
        if let identity = try? DescriptorFileSystem.identity(at: path) {
          lineage.append(ApplicationPathObservation(path: path, identity: identity))
        } else {
          complete = false
          rootsComplete = false
        }
      }
    }
    return AuthenticApplicationContext(
      scope: contextScope,
      inventory: BundleInventory(
        applications: apps.sorted { $0.path < $1.path }, unidentifiedPaths: listing.unidentifiedPaths,
        complete: complete, observedAt: Date(), ownershipComplete: false,
        metadataIssues: listing.metadataIssues, scopeExclusions: listing.scopeExclusions,
        registrationReport: listing.registrationReport,
        observedDirectories: listing.observedDirectories,
        installedRootsComplete: rootsComplete, applicationMetadata: applicationMetadata),
      lineage: lineage,
      registeredPaths: registered.paths, standardBundleID: app.bundleID,
      installedListing: listing, metadata: metadata, dataEvidenceSource: dataEvidenceSource)
  }

  func validateContext(
    _ context: AuthenticApplicationContext, groups: Bool, bundleIDs: Set<String> = []
  ) throws {
    if groups, registrationIsOnlyMissingSource(context.inventory),
      context.inventory.ownershipCandidates.filter({ !$0.path.hasPrefix("/System/") }).allSatisfy({
        signingMetadata($0.path, context: context) != nil
      })
    {
      throw PlanRejection(
        .unavailable, path: RelatedLocation.groupContainers.parent(homeDirectory: homeDirectory),
        ruleID: "registrationUnavailable")
    }
    if context.standardBundleID != nil, groups { throw RelatedFailure.unsupportedInstalledData }
    let selectedIDs = context.standardBundleID.map { Set([$0]) } ?? bundleIDs
    do { try validateLineage(context, groups: groups, bundleIDs: selectedIDs) } catch RelatedFailure.changedItem {
      if !groups {
        for id in selectedIDs {
          if let app = context.inventory.applications.first(where: { foldedAppID($0.bundleID) == foldedAppID(id) }),
            sharedOwnerEvidence(
              app: app, candidatePath: RelatedLocation.caches.path(domain: id, homeDirectory: homeDirectory),
              context: context) != nil
          {
            throw RelatedFailure.ambiguousOwner
          }
        }
      }
      throw RelatedFailure.changedItem
    }
    if groups {
      let current = registration()
      guard current.complete, current.paths == context.registeredPaths else { throw RelatedFailure.incompleteInventory }
      try context.validateSignatures()
    } else {
      for id in selectedIDs {
        let registered = registeredByID(id)
        guard registered.complete else { throw RelatedFailure.incompleteInventory }
        for path in registered.paths
        where !ApplicationRegistration.isTrash(path)
          && !Self.isCachedApplication(path, homeDirectory: homeDirectory)
        {
          do {
            guard let app = try decisionApplication(at: path, registered: true, metadata: context.metadata) else {
              continue
            }
            if Self.isCachedApplication(app.linkTarget ?? app.path, homeDirectory: homeDirectory) { continue }
            if foldedAppID(app.bundleID) == foldedAppID(id),
              !context.inventory.applications.contains(where: {
                ($0.linkTarget ?? $0.path) == (app.linkTarget ?? app.path)
                  && foldedAppID($0.bundleID) == foldedAppID(id)
              })
            {
              throw RelatedFailure.ambiguousOwner
            }
          } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT { continue } catch RelatedFailure
            .incompleteInventory
          {
            let observation = ApplicationMetadataObservation.read(at: path)
            switch observation.state {
            case .identifierless: continue
            case .absentInfo:
              try observation.validateAbsence()
              context.recordInfoAbsence(observation)
              continue
            case .declaredID(let currentID):
              if foldedAppID(currentID) == foldedAppID(id) { throw RelatedFailure.ownerPresent }
            case .unknown: throw RelatedFailure.incompleteInventory
            }
          }
        }
      }
    }
  }

  private func validateInstallationDirectories(_ inventory: BundleInventory) throws {
    let packages = Set(
      inventory.applications.flatMap { [$0.path, $0.linkTarget ?? $0.path] }
        + inventory.unidentifiedPaths + inventory.scopeExclusions.map(\.path))
    for observation in inventory.observedDirectories {
      if packages.contains(where: { observation.path == $0 || observation.path.hasPrefix($0 + "/") }) { continue }
      try observation.validate()
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
    try validateInstallationDirectories(context.inventory)
    let foldedIDs = Set(bundleIDs.map(foldedAppID))
    func affectsDecision(_ id: String) -> Bool {
      foldedIDs.contains(foldedAppID(id))
        || foldedIDs.contains { target in
          target.hasPrefix(foldedAppID(id) + ".") || target.hasPrefix(foldedAppID(id) + "-")
        }
    }
    for observed in apps {
      if Self.isCachedApplication(observed.path, homeDirectory: homeDirectory)
        || Self.isCachedApplication(observed.linkTarget ?? observed.path, homeDirectory: homeDirectory)
      {
        continue
      }
      do {
        let physical = observed.linkTarget ?? observed.path
        let current =
          observed.linkTarget != nil
          ? try decisionApplication(at: observed.path, registered: true, metadata: context.metadata)
          : try decisionApplication(at: physical, metadata: context.metadata)
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
      } catch RelatedFailure.incompleteInventory {
        if affectsDecision(observed.bundleID) { throw RelatedFailure.incompleteInventory }
        let observation = ApplicationMetadataObservation.read(at: observed.path)
        for id in bundleIDs {
          let path = RelatedLocation.caches.path(domain: id, homeDirectory: homeDirectory)
          if !metadataRefusals(
            inventory: context.inventory, bundleID: id, candidatePath: path,
            observations: [observation], fresh: true
          ).isEmpty {
            throw RelatedFailure.incompleteInventory
          }
        }
      }
    }
    for path in context.inventory.unidentifiedPaths {
      if Self.isCachedApplication(path, homeDirectory: homeDirectory) { continue }
      do {
        if let app = try decisionApplication(at: path, metadata: context.metadata), affectsDecision(app.bundleID) {
          throw RelatedFailure.ambiguousOwner
        }
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT { continue } catch RelatedFailure
        .incompleteInventory
      {
        let observation = ApplicationMetadataObservation.read(at: path)
        for id in bundleIDs {
          if !metadataRefusals(
            inventory: context.inventory, bundleID: id,
            candidatePath: RelatedLocation.caches.path(domain: id, homeDirectory: homeDirectory),
            observations: [observation], fresh: true
          ).isEmpty {
            throw RelatedFailure.incompleteInventory
          }
        }
      }
    }
  }

  private func context(for plan: ActionPlan, item: PlanItem) throws -> AuthenticApplicationContext {
    guard plan.items.contains(item) else { throw RelatedFailure.unsupportedInstalledData }
    if let context = planContexts.context(for: plan, scope: contextScope, itemID: item.id) { return context }
    if item.orphanRelatedProof != nil || item.relatedProof != nil { throw RelatedFailure.incompleteInventory }
    // Eviction or a separately constructed legacy plan requires one fresh
    // validation universe for the whole plan, never one inventory per item.
    let selected = plan.items.compactMap { item -> InstalledApplication? in
      guard let proof = item.installedRelatedProof else { return nil }
      return readApplication(at: proof.appPath, allowProtected: false)
    }
    let listing = installedListing()
    let needsOwners = plan.items.contains { candidate in
      guard let proof = candidate.installedRelatedProof,
        let (location, domain) = RelatedLocation.matching(path: candidate.sourcePath, homeDirectory: homeDirectory)
      else { return candidate.relatedProof != nil || candidate.orphanRelatedProof != nil }
      return location == .groupContainers || domain != proof.bundleID
    }
    let full = needsOwners ? makeContext(base: listing, including: selected) : nil
    let metadata = full?.metadata ?? ApplicationContextMetadata()
    var standards: [String: AuthenticApplicationContext] = [:]
    var contexts: [UUID: AuthenticApplicationContext] = [:]
    for candidate in plan.items {
      if let proof = candidate.installedRelatedProof,
        let app = selected.first(where: { $0.path == proof.appPath && $0.bundleID == proof.bundleID }),
        let (location, domain) = RelatedLocation.matching(path: candidate.sourcePath, homeDirectory: homeDirectory),
        location != .groupContainers, domain == proof.bundleID
      {
        if standards[app.path] == nil {
          standards[app.path] = makeStandardContext(app: app, listing: listing, metadata: metadata)
        }
        contexts[candidate.id] = standards[app.path]
      } else if let full {
        contexts[candidate.id] = full
      }
    }
    try planContexts.bind(plan, contexts: contexts)
    guard let context = contexts[item.id] else { throw RelatedFailure.unsupportedInstalledData }
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
    guard let original = try? DescriptorFileSystem.identity(at: path),
      original.kind == .symbolicLink,
      let resolved = realpath(path, nil)
    else { return nil }
    defer { free(resolved) }
    let target = String(cString: resolved)
    guard ApplicationRegistration.hasApplicationSuffix(target),
      (try? DescriptorFileSystem.identity(at: target))?.kind == .directory,
      let dictionary = try? ApplicationIdentity.metadata(ofBundleAt: target),
      let bundleID = dictionary["CFBundleIdentifier"] as? String, validBundleID(bundleID),
      (try? DescriptorFileSystem.identity(at: path)) == original
    else { return nil }
    let version = (dictionary["CFBundleShortVersionString"] as? String) ?? (dictionary["CFBundleVersion"] as? String)
    return InstalledApplication(bundleID: bundleID, path: path, version: version, linkTarget: target)
  }

  public func discover() async -> [RelatedDataCandidate] {
    let context = makeContext()
    return await discover(
      inventory: context.inventory, only: nil,
      signatures: signatures(inventory: context.inventory, context: context), authenticatedContext: context)
  }

  /// A focused observation for a dropped or selected application.
  public func discover(for app: InstalledApplication) async -> [RelatedDataCandidate] {
    await focusedObservation(for: app).candidates
  }

  func focusedObservation(for app: InstalledApplication) async
    -> (candidates: [RelatedDataCandidate], signerTeamID: String?)
  {
    guard let physical = application(at: app.linkTarget ?? app.path), physical.bundleID == app.bundleID,
      let context = try? selectedContext(app: physical, base: makeContext(including: [physical]))
    else { return ([], nil) }
    let signatures = signatures(inventory: context.inventory, context: context, selected: physical)
    return (
      await discover(
        inventory: context.inventory, only: physical, signatures: signatures, authenticatedContext: context,
        allowReceipts: false),
      signatures[physical.path]?.teamID
    )
  }

  /// Reads one explicitly selected application without walking installed roots.
  /// Returned metadata is an observation; action plans still revalidate it.
  public func application(at path: String) -> InstalledApplication? {
    if (try? DescriptorFileSystem.identity(at: path))?.kind == .symbolicLink {
      return Self.resolveLinkedApplication(at: path)
    }
    return readApplication(at: path, allowProtected: false)
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
  private func decisionApplication(
    at path: String, registered: Bool = false, metadata: ApplicationContextMetadata? = nil
  ) throws -> InstalledApplication? {
    do {
      if let metadata {
        return try metadata.application(at: path, registered: registered) {
          if registered { return try inspectRegisteredApplication(at: path) }
          return try inspectApplication(at: path, allowProtected: true)
        }
      }
      if registered { return try inspectRegisteredApplication(at: path) }
      return try inspectApplication(at: path, allowProtected: true)
    } catch let rejection as PlanRejection {
      if rejection.reason == .changedSinceScan { throw RelatedFailure.changedItem }
      throw RelatedFailure.incompleteInventory
    } catch is ApplicationMetadataFailure {
      throw RelatedFailure.incompleteInventory
    } catch let error as SecureMetadataFailure {
      switch error {
      case .changed: throw RelatedFailure.changedItem
      case .unsafe, .tooLarge: throw RelatedFailure.incompleteInventory
      }
    } catch FileSystemFailure.changedDuringInspection {
      throw RelatedFailure.changedItem
    } catch FileSystemFailure.systemCall(_, let code) where code != ENOENT {
      throw RelatedFailure.incompleteInventory
    }
  }

  private func selectedContext(
    app: InstalledApplication, base: AuthenticApplicationContext
  ) throws -> AuthenticApplicationContext {
    guard application(at: app.path) == app else { throw RelatedFailure.changedItem }
    let selectedRoot = try DescriptorFileSystem.identity(at: app.path)
    let current = base.inventory
    var aliases: Set<String> = []
    for observed in current.applications
    where foldedAppID(observed.bundleID) == foldedAppID(app.bundleID) {
      let physical = observed.linkTarget ?? observed.path
      if try DescriptorFileSystem.identity(at: physical) == selectedRoot {
        guard
          let fresh = try decisionApplication(
            at: observed.path, registered: observed.linkTarget != nil, metadata: base.metadata),
          fresh.bundleID == app.bundleID, (fresh.linkTarget ?? fresh.path) == app.path
        else { throw RelatedFailure.changedItem }
        aliases.insert(observed.path)
      }
    }
    if aliases == [app.path] { return base }
    let knownPhysicalOwner = !aliases.isEmpty
    let apps = current.applications.filter { !aliases.contains($0.path) } + [app]
    let owners = current.ownershipCandidates.map { owner in
      aliases.contains(owner.packagePath)
        ? ApplicationOwnerCandidate(path: owner.path, packagePath: app.path) : owner
    }
    let listing = BundleInventory(
      applications: apps, unidentifiedPaths: current.unidentifiedPaths,
      complete: current.complete, observedAt: current.observedAt, ownershipCandidates: owners,
      ownershipComplete: current.ownershipComplete && knownPhysicalOwner,
      ownershipIssues: current.ownershipIssues, metadataIssues: current.metadataIssues,
      scopeExclusions: current.scopeExclusions, registrationReport: current.registrationReport,
      observedDirectories: current.observedDirectories,
      installedRootsComplete: current.installedRootsComplete,
      unresolvedApplicationMetadata: current.unresolvedApplicationMetadata,
      applicationMetadata: current.applicationMetadata)
    let metadata = try ApplicationPackagePlanning.metadata(at: app.path)
    let paths = [
      app.path, app.path + "/" + metadata.observation.infoRelativePath,
      (app.path as NSString).deletingLastPathComponent,
    ]
    return AuthenticApplicationContext(
      scope: base.scope, inventory: listing,
      lineage: base.lineage
        + (try paths.map {
          ApplicationPathObservation(
            path: $0, identity: try DescriptorFileSystem.identity(at: $0))
        }),
      registeredPaths: base.registeredPaths, standardBundleID: base.standardBundleID,
      installedListing: base.installedListing, metadata: base.metadata, dataEvidenceSource: base)
  }

  private func signingMetadata(_ path: String, context: AuthenticApplicationContext?) -> ApplicationSigningMetadata? {
    if let context { return context.signature(at: path, cache: signatureCache)?.metadata }
    return signingMetadata(path)
  }

  private func signatures(
    inventory: BundleInventory, context: AuthenticApplicationContext, selected: InstalledApplication? = nil,
    cancelled: @Sendable () -> Bool = { false }
  ) -> [String: ApplicationSigningMetadata] {
    var result: [String: ApplicationSigningMetadata] = [:]
    let owners = inventory.ownershipCandidates.filter { !$0.path.hasPrefix("/System/") }
    if let selected {
      let physical = selected.linkTarget ?? selected.path
      result[physical] = signingMetadata(physical, context: context)
      result[selected.path] = result[physical]
      for owner in owners where owner.packagePath == selected.path {
        if Task.isCancelled || cancelled() { return result }
        result[owner.path] = signingMetadata(owner.path, context: context)
      }
      let hasGroupData = result.values.flatMap(\.groupIdentifiers).contains {
        (try? DescriptorFileSystem.identity(
          at: RelatedLocation.groupContainers.path(domain: $0, homeDirectory: homeDirectory))) != nil
      }
      if !hasGroupData { return result }
    }
    for owner in owners {
      if Task.isCancelled || cancelled() { return result }
      result[owner.path] = signingMetadata(owner.path, context: context)
    }
    return result
  }

  private func ownedDataClaims(
    _ context: AuthenticApplicationContext, cancelled: @Sendable () -> Bool = { false }
  ) -> [String: [ApplicationOwnedDataEvidence]] {
    if let observed = context.observedDataClaims() { return observed }
    var result: [String: [ApplicationOwnedDataEvidence]] = [:]
    var seen: Set<String> = []
    var sources: [String: ApplicationPathObservation] = [:]
    var issues: [ApplicationAuxiliaryIssue] = []
    for app in context.inventory.applications {
      if Task.isCancelled || cancelled() { return result }
      let physical = app.linkTarget ?? app.path
      guard !Self.isCachedApplication(physical, homeDirectory: homeDirectory), seen.insert(physical).inserted else {
        continue
      }
      let exclusive = vendorIsExclusive(app: app, context: context, cancelled: cancelled)
      if Task.isCancelled || cancelled() { return result }
      let observed = context.metadata.ownedData.discover(
        app: app, home: homeDirectory, vendorExclusive: exclusive, liveData: liveData)
      if Task.isCancelled || cancelled() { return result }
      for source in observed.sources where sources[source.path] == nil { sources[source.path] = source }
      issues += observed.issues
      for evidence in observed.evidence where evidence.bundleID == app.bundleID {
        result[evidence.dataPath, default: []].append(evidence)
        context.recordDataEvidence(evidence)
      }
    }
    if Task.isCancelled || cancelled() { return result }
    context.recordDataClaims(
      result, sources: sources.values.sorted { $0.path < $1.path }, issues: issues)
    return context.observedDataClaims() ?? result
  }

  private func vendorIsExclusive(
    app: InstalledApplication, context: AuthenticApplicationContext, cancelled: @Sendable () -> Bool = { false }
  ) -> Bool {
    guard context.inventory.ownershipComplete,
      let vendor = app.bundleID.split(separator: ".").dropFirst().first.map(String.init), vendor.count > 1,
      !ApplicationAuxiliaryEvidenceProducer.isGeneralToolDirectory(vendor),
      ApplicationAuxiliaryEvidenceProducer.hasVendorDirectory(vendor: vendor, home: homeDirectory),
      let signature = signingMetadata(app.linkTarget ?? app.path, context: context), let team = signature.teamID
    else { return false }
    let selected = app.linkTarget ?? app.path
    let prefix = app.bundleID.split(separator: ".").prefix(2).joined(separator: ".") + "."
    for other in context.inventory.applications {
      if Task.isCancelled || cancelled() { return false }
      let physical = other.linkTarget ?? other.path
      guard physical != selected, !Self.isCachedApplication(physical, homeDirectory: homeDirectory) else { continue }
      if other.bundleID.lowercased().hasPrefix(prefix.lowercased()) { return false }
      guard let otherSignature = signingMetadata(physical, context: context) else { return false }
      if otherSignature.teamID == team { return false }
    }
    return true
  }

  private func validateDataEvidence(
    _ evidence: ApplicationOwnedDataEvidence, context: AuthenticApplicationContext
  ) throws {
    if context.inventory.registrationReport?.complete == false,
      RelatedLocation.matching(path: evidence.dataPath, homeDirectory: homeDirectory)?.1 != evidence.bundleID
    {
      guard registrationIsOnlyMissingSource(context.inventory) else { throw RelatedFailure.incompleteInventory }
      throw PlanRejection(.unavailable, path: evidence.dataPath, ruleID: "registrationUnavailable")
    }
    try context.validateDataSources()
    if evidence.provenance.kind == .vendorDirectory {
      try context.validateSignatures()
      guard
        let app = context.inventory.applications.first(where: { ($0.linkTarget ?? $0.path) == evidence.packagePath }),
        vendorIsExclusive(app: app, context: context)
      else { throw RelatedFailure.ambiguousOwner }
    }
    guard !Self.isCachedApplication(evidence.packagePath, homeDirectory: homeDirectory) else {
      throw RelatedFailure.ambiguousOwner
    }
    try evidence.validate()
    let owners = ownedDataClaims(context)[evidence.dataPath] ?? []
    guard Set(owners.map(\.packagePath)) == [evidence.packagePath] else { throw RelatedFailure.ambiguousOwner }
    try validateMetadataScope(context, bundleID: evidence.bundleID, candidatePath: evidence.dataPath)
  }

  private func validateDataEnvironment(
    _ evidence: ApplicationOwnedDataEvidence, context: AuthenticApplicationContext,
    movedOwner: MovedApplicationOwner?, liveObservation: ApplicationLiveDataObservation? = nil
  ) throws {
    guard
      try ApplicationAuxiliaryEvidenceProducer.liveSharedOwnerPaths(
        dataPath: evidence.dataPath, excludingPackage: evidence.packagePath,
        applications: context.inventory.applications, home: homeDirectory, observation: liveObservation ?? liveData()
      ).isEmpty
    else { throw RelatedFailure.ambiguousOwner }
    if let movedOwner {
      // Relocation is authorized only by the executor's native moved-owner
      // envelope. Original negative metadata observations still receive their
      // own fresh checks before a new complete installed listing is observed.
      for observation in context.observedInfoAbsences() { try observation.validateAbsence() }
      try context.validateDataSources(excludingPackage: evidence.packagePath)
      try evidence.validate(relocatedPackagePath: movedOwner.movedPackage.sourcePath)
      let app = InstalledApplication(
        bundleID: evidence.bundleID, path: movedOwner.movedPackage.sourcePath, version: nil)
      let current = makeStandardContext(app: app, listing: installedListing(), metadata: context.metadata)
      guard standardInventoryIsComplete(current.inventory) else { throw RelatedFailure.incompleteInventory }
      try validateMetadataScope(current, bundleID: app.bundleID, candidatePath: evidence.dataPath)
      try validateMetadataScope(
        current, bundleID: (evidence.dataPath as NSString).lastPathComponent, candidatePath: evidence.dataPath)
      // The moved-owner envelope authenticates the selected package. Trash is
      // deliberately excluded from the installed-owner universe, so only
      // another installation or data claim can veto the remaining data.
      let owners = installedOwners(bundleID: app.bundleID, applications: current.inventory.applications)
        .filter { ($0.linkTarget ?? $0.path) != app.path }
      guard owners.isEmpty else { throw RelatedFailure.ambiguousOwner }
      let claims = ownedDataClaims(current)[evidence.dataPath] ?? []
      guard claims.allSatisfy({ $0.packagePath == app.path }) else { throw RelatedFailure.ambiguousOwner }
    } else {
      try validateContext(context, groups: false, bundleIDs: [evidence.bundleID])
      try validateDataEvidence(evidence, context: context)
    }
  }

  private func validateLiveSharing(
    path: String, excludingPackage: String, applications: [InstalledApplication],
    observation: ApplicationLiveDataObservation? = nil
  ) throws {
    let observed = observation ?? liveData()
    guard observed.complete else {
      throw PlanRejection(.activityUnavailable, path: path, ruleID: "live-process-census-incomplete")
    }
    guard
      try ApplicationAuxiliaryEvidenceProducer.liveSharedOwnerPaths(
        dataPath: path, excludingPackage: excludingPackage, applications: applications,
        home: homeDirectory, observation: observed
      ).isEmpty
    else { throw RelatedFailure.ambiguousOwner }
  }

  /// Shallow filename associations are display observations. They do not use
  /// signatures, processes, receipts, recursive sizes, or an owner universe.
  func shallowCandidates(for app: InstalledApplication) -> [RelatedDataCandidate] {
    var identifiers: Set<String> = [app.bundleID.lowercased()]
    var names: Set<String> = [URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent.lowercased()]
    func readNames(_ package: String) {
      let info = Self.infoPlistPath(ofBundleAt: package)
      guard let bytes = try? SecureMetadataFile.read(path: info, limit: 1024 * 1024, ownerOnly: false),
        let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
      else { return }
      if let id = plist["CFBundleIdentifier"] as? String { identifiers.insert(id.lowercased()) }
      for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
        if let name = plist[key] as? String, name.count >= 4 { names.insert(name.lowercased()) }
      }
    }
    let package = app.linkTarget ?? app.path
    readNames(package)
    let frameworks = package + "/Contents/Frameworks"
    if let root = try? DescriptorFileSystem.identity(at: frameworks),
      let children = try? DescriptorFileSystem.children(at: frameworks, expected: root)
    {
      for child in children where child.hasSuffix(".app") { readNames(frameworks + "/" + child) }
    }
    let words = names.flatMap { $0.split(separator: " ").map(String.init) }.filter { $0.count >= 4 }
    names.formUnion(words)
    let family = app.bundleID.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
    let vendor = app.bundleID.split(separator: ".").dropFirst().first.map { String($0).lowercased() }
    let namedVendor = vendor.map { names.contains($0) } ?? false
    func matches(_ name: String) -> Bool {
      let value = name.lowercased()
      if identifiers.contains(where: { value == $0 || value.hasPrefix($0 + ".") || value.hasPrefix($0 + "-") }) {
        return true
      }
      // A shared vendor or a team-prefixed ID is only a possible association.
      if namedVendor, app.bundleID.split(separator: ".").count >= 3, value.hasPrefix(family + ".") { return true }
      if identifiers.contains(where: { value.contains("." + $0) }) { return true }
      return names.contains { name in
        guard let range = value.range(of: name) else { return false }
        let before = value[..<range.lowerBound].last
        let after = value[range.upperBound...].first
        return (before == nil || before?.isLetter == false)
          && (after == nil || after?.isLetter == false)
      }
    }
    var parents: Set<String> = [homeDirectory + "/Library"]
    for library in [homeDirectory + "/Library", "/Library"] {
      for directory in [
        "Application Support", "Caches", "Preferences", "Containers", "Group Containers", "Saved Application State",
        "LaunchAgents", "LaunchDaemons", "Logs", "HTTPStorages", "WebKit", "Cookies", "Application Scripts",
        "Preferences/ByHost", "Application Support/CrashReporter", "Logs/CrashReporter",
        "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
      ] { parents.insert(library + "/" + directory) }
    }
    if homeDirectory == NSHomeDirectory() {
      let native = ApplicationReferenceDirectories.currentUser()
      if (try? native.validate()) != nil { parents.formUnion([native.cache, native.temporary].compactMap { $0 }) }
    }
    var observed: [String: RelatedDataCandidate] = [:]
    func inspect(_ parent: String, inspectChildren: Bool) {
      guard !Task.isCancelled, let root = try? DescriptorFileSystem.identity(at: parent), root.kind == .directory,
        let children = try? DescriptorFileSystem.children(at: parent, expected: root)
      else { return }
      for child in children {
        if Task.isCancelled { return }
        let path = parent + "/" + child
        let associated = matches(child)
        guard associated || inspectChildren else { continue }
        guard let identity = try? DescriptorFileSystem.identity(at: path) else { continue }
        if associated {
          var candidate = RelatedDataCandidate(
            id: path, path: path, classification: .unprovenNameOnly, reason: .nameOnly, snapshot: nil, receipt: nil)
          candidate.bundleID = app.bundleID
          candidate.matchStrength = .weak
          candidate.explicitManualChoiceAvailable = true
          candidate.displayRootIdentity = identity
          observed[path] = candidate
        }
        // One extra shallow level finds named logs and vendor data, without
        // walking directory interiors or producing deletion authority.
        if inspectChildren, identity.kind == .directory { inspect(path, inspectChildren: false) }
      }
    }
    for parent in parents.sorted() {
      inspect(
        parent, inspectChildren: parent.hasSuffix("/Application Support") || parent.hasSuffix("/Logs"))
    }
    return observed.values.sorted { $0.path < $1.path }
  }

  func initialReview(
    for app: InstalledApplication, progress: (@Sendable (ApplicationRelatedReview) -> Void)?
  ) async -> ApplicationRelatedReview {
    let shallow = shallowCandidates(for: app)
    guard !Task.isCancelled else { return ApplicationRelatedReview(application: app, candidates: []) }
    progress?(ApplicationRelatedReview(application: app, candidates: shallow, phase: .shallow))
    let merged: @Sendable ([RelatedDataCandidate]) -> [RelatedDataCandidate] = { measured in
      let paths = Set(measured.map(\.path))
      return (measured + shallow.filter { !paths.contains($0.path) }).sorted { $0.path < $1.path }
    }
    let listing = BundleInventory(applications: [app], unidentifiedPaths: [], complete: false, observedAt: Date())
    let candidates = await discover(inventory: listing, only: app, signatures: [:], allowReceipts: false) { partial in
      progress?(
        ApplicationRelatedReview(
          application: app, candidates: merged(partial),
          phase: .measuring(completed: partial.filter { $0.observation != nil }.count, total: partial.count)))
    }
    return ApplicationRelatedReview(application: app, candidates: merged(candidates), phase: .initialComplete)
  }

  func review(for app: InstalledApplication, context: AuthenticApplicationContext) async -> ApplicationRelatedReview {
    guard let physical = application(at: app.linkTarget ?? app.path), physical.bundleID == app.bundleID,
      let selected = try? selectedContext(app: physical, base: context)
    else { return ApplicationRelatedReview(application: app, candidates: [], ownershipPending: true, phase: .enriched) }
    let signatures = await ApplicationEvidenceWork.perform(cancelledValue: [:]) { cancellation in
      self.signatures(
        inventory: selected.inventory, context: selected, selected: physical, cancelled: { cancellation.isCancelled })
    }
    guard !Task.isCancelled else { return ApplicationRelatedReview(application: app, candidates: []) }
    let candidates = await discover(
      inventory: selected.inventory, only: physical, signatures: signatures,
      authenticatedContext: selected, allowReceipts: false)
    let paths = Set(candidates.map(\.path))
    return ApplicationRelatedReview(
      application: app,
      candidates: candidates + shallowCandidates(for: physical).filter { !paths.contains($0.path) },
      signerTeamID: signatures[physical.path]?.teamID,
      ownershipPending: !selected.inventory.ownershipComplete,
      registrationReport: selected.inventory.registrationReport, phase: .enriched)
  }

  func discover(context: AuthenticApplicationContext) async -> [RelatedDataCandidate] {
    let signatures = await ApplicationEvidenceWork.perform(cancelledValue: [:]) { cancellation in
      self.signatures(inventory: context.inventory, context: context, cancelled: { cancellation.isCancelled })
    }
    guard !Task.isCancelled else { return [] }
    return await discover(
      inventory: context.inventory, only: nil,
      signatures: signatures, authenticatedContext: context,
      allowReceipts: false)
  }

  private func discover(
    inventory apps: BundleInventory, only app: InstalledApplication?,
    signatures suppliedSignatures: [String: ApplicationSigningMetadata]? = nil,
    authenticatedContext: AuthenticApplicationContext? = nil,
    allowReceipts: Bool = true,
    progress: (@Sendable ([RelatedDataCandidate]) -> Void)? = nil
  ) async
    -> [RelatedDataCandidate]
  {
    if Task.isCancelled { return [] }
    let standardInventoryComplete = standardInventoryIsComplete(apps)
    let receipts = (try? loadReceipts()) ?? []
    let receiptStoreHealthy = (try? loadReceipts()) != nil
    let signatures: [String: ApplicationSigningMetadata]
    if let suppliedSignatures {
      signatures = suppliedSignatures
    } else {
      signatures = await ApplicationEvidenceWork.perform(cancelledValue: [:]) { cancellation in
        Dictionary(
          apps.ownershipCandidates.compactMap { owner -> (String, ApplicationSigningMetadata)? in
            guard !cancellation.isCancelled else { return nil }
            return self.signingMetadata(owner.path).map { (owner.path, $0) }
          },
          uniquingKeysWith: { first, _ in first })
      }
    }
    guard !Task.isCancelled else { return [] }
    let evidence: ([String: [ApplicationOwnedDataEvidence]], Bool, ApplicationLiveDataObservation?)
    if let context = authenticatedContext {
      evidence = await ApplicationEvidenceWork.perform(cancelledValue: ([:], false, nil)) { cancellation in
        let claims = self.ownedDataClaims(context, cancelled: { cancellation.isCancelled })
        guard !cancellation.isCancelled else { return (claims, false, nil) }
        return (
          claims, (try? context.validateDataSources()) != nil,
          context.metadata.ownedData.liveObservation(using: self.liveData)
        )
      }
    } else {
      evidence = ([:], false, nil)
    }
    guard !Task.isCancelled else { return [] }
    let (ownedClaims, dataSourcesValid, liveSnapshot) = evidence
    var candidates: [RelatedDataCandidate] = []
    for issue in authenticatedContext?.observedDataIssues() ?? [] {
      guard let id = issue.bundleID, issue.provenanceKind == .installerReceipt,
        app == nil || app?.bundleID == id, ownedClaims[issue.path] == nil
      else { continue }
      var candidate = RelatedDataCandidate(
        id: issue.path, path: issue.path, classification: .uncertain,
        reason: .ownershipUnavailable, snapshot: nil, receipt: nil)
      candidate.bundleID = id
      candidate.provenance = RelatedDataProvenance(
        kind: .installerReceipt, detail: issue.detail)
      candidates.append(candidate)
    }
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
        if location == .applicationSupport || location == .logs {
          let name = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
          if let root = try? DescriptorFileSystem.identity(at: parent),
            let names = try? DescriptorFileSystem.children(at: parent, expected: root)
          {
            for observed in names where observed.caseInsensitiveCompare(name) == .orderedSame {
              let path = parent + "/" + observed
              if !paths.contains(where: { $0.2 == path }) { paths.append((location, observed, path)) }
            }
          }
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
    let existingPaths = Set(paths.map { $0.2 })
    for path in ownedClaims.keys.sorted() where !existingPaths.contains(path) {
      // The location is an observation tag here. The private native evidence
      // authorizes auxiliary paths independently of the standard-domain parser.
      paths.append(
        (
          RelatedLocation.matching(path: path, homeDirectory: homeDirectory)?.0 ?? .applicationSupport,
          (path as NSString).lastPathComponent, path
        ))
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
      let registrationMissingOnly =
        registrationIsOnlyMissingSource(apps)
        && apps.ownershipCandidates.filter { !$0.path.hasPrefix("/System/") }.allSatisfy { signatures[$0.path] != nil }
      let exactOwners = installedOwners(bundleID: domain, applications: apps.applications)
      let prefixOwners = apps.applications.filter { owner in
        guard !Self.isCachedApplication(owner.linkTarget ?? owner.path, homeDirectory: homeDirectory) else {
          return false
        }
        guard let team = signatures[owner.path]?.teamID else { return false }
        return domain.hasPrefix(team + "." + owner.bundleID)
          && (domain == team + "." + owner.bundleID || domain.hasPrefix(team + "." + owner.bundleID + "."))
      }
      let weakOwners =
        (location == .applicationSupport || location == .logs)
        ? apps.applications.filter {
          guard !Self.isCachedApplication($0.linkTarget ?? $0.path, homeDirectory: homeDirectory) else { return false }
          return (URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent)
            .caseInsensitiveCompare(domain) == .orderedSame
        } : []
      let claims = ownedClaims[path] ?? []
      let artifactOwners = apps.applications.filter { owner in
        claims.contains { $0.packagePath == (owner.linkTarget ?? owner.path) && $0.bundleID == owner.bundleID }
      }
      let owners =
        location == .groupContainers
        ? groupOwners
        : !exactOwners.isEmpty
          ? exactOwners
          : !claims.isEmpty
            ? artifactOwners
            : !prefixOwners.isEmpty ? prefixOwners : weakOwners
      let liveSharing: Result<[String], any Error>? = owners.first.flatMap { owner in
        guard let liveSnapshot, liveSnapshot.complete else { return nil }
        return Result {
          try ApplicationAuxiliaryEvidenceProducer.liveSharedOwnerPaths(
            dataPath: path, excludingPackage: owner.linkTarget ?? owner.path,
            applications: apps.applications, home: homeDirectory, observation: liveSnapshot)
        }
      }
      let liveSharingFailed: Bool
      let liveSharingOwners: [String]
      switch liveSharing {
      case .some(.success(let paths)):
        liveSharingFailed = false
        liveSharingOwners = paths
      case .some(.failure):
        liveSharingFailed = true
        liveSharingOwners = []
      case nil:
        liveSharingFailed = false
        liveSharingOwners = []
      }
      let claimStrength: RelatedMatchStrength =
        claims.contains { $0.matchStrength == .strong }
        ? .strong
        : claims.contains { $0.matchStrength == .medium } ? .medium : .weak
      let strength: RelatedMatchStrength =
        location == .groupContainers || !exactOwners.isEmpty
        ? .strong
        : !claims.isEmpty
          ? claimStrength
          : !prefixOwners.isEmpty ? .medium : !weakOwners.isEmpty ? .weak : .strong
      let focusedOwner = app.flatMap { selected in
        owners.contains(where: { $0.path == selected.path }) ? selected.bundleID : nil
      }
      let literalOwner = apps.applicationMetadata.contains { observation in
        if case .declaredID(let id) = observation.state { return foldedAppID(id) == foldedAppID(domain) }
        return false
      }
      let bundleID =
        focusedOwner ?? owners.first?.bundleID ?? (Self.validBundleID(domain) || literalOwner ? domain : nil)
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
      var evidence =
        location == .groupContainers
        ? []
        : metadataRefusals(
          inventory: apps, bundleID: bundleID, candidatePath: path, signatures: signatures)
      if location != .groupContainers, domain != bundleID {
        evidence += metadataRefusals(
          inventory: apps, bundleID: domain, candidatePath: path, signatures: signatures)
      }
      if location != .groupContainers, owners.isEmpty, let context = authenticatedContext {
        evidence += registeredMetadataRefusals(bundleID: bundleID, candidatePath: path, context: context)
      }
      if location == .groupContainers && (!ownershipVerified || domain.lowercased().hasPrefix("group.com.apple.")) {
        classification = .shared
        reason =
          ownershipVerified
          ? .sharedGroup
          : registrationMissingOnly ? .registrationUnavailable : .ownershipUnavailable
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
      } else if evidence.contains(where: { $0.reason == .observedLiteralOwner }) {
        classification = .uncertain
        reason = .literalIdentifierOwner
      } else if !evidence.isEmpty {
        classification = .uncertain
        reason = .incompleteInventory
      } else if !exactOwners.isEmpty && liveSnapshot?.complete == false {
        classification = .uncertain
        reason = .liveCensusUnavailable
      } else if exactOwners.isEmpty && !claims.isEmpty && apps.registrationReport?.complete == false {
        classification = .uncertain
        reason = registrationIsOnlyMissingSource(apps) ? .registrationUnavailable : .ownershipUnavailable
      } else if !claims.isEmpty && !dataSourcesValid {
        classification = .uncertain
        reason = .ownershipUnavailable
      } else if liveSnapshot?.complete == false {
        classification = .uncertain
        reason = .liveCensusUnavailable
      } else if liveSharingFailed {
        classification = .uncertain
        reason = .ownershipUnavailable
      } else if let selectedOwner = owners.first, !liveSharingOwners.isEmpty {
        classification = .shared
        reason = .sharedInstalledData
        evidence = [
          RelatedOwnershipRefusalEvidence(
            candidatePath: path, bundleID: bundleID, reason: .sharedInstalledOwners,
            ownerPaths: Array(Set(liveSharingOwners + [selectedOwner.linkTarget ?? selectedOwner.path])).sorted(),
            nextStep: "review-other-installations", detail: nil)
        ]
      } else if Set(claims.map(\.packagePath)).count > 1 {
        if let context = authenticatedContext, let owner = owners.first,
          let shared = sharedOwnerEvidence(
            app: owner, candidatePath: path, context: context,
            discoverySourcesValid: dataSourcesValid, liveObservation: liveSnapshot)
        {
          classification = .shared
          reason = .sharedInstalledData
          evidence = [shared]
        } else {
          classification = .uncertain
          reason = .ownershipUnavailable
        }
      } else if location != .groupContainers, exactOwners.count > 1 {
        if let context = authenticatedContext, let owner = exactOwners.first,
          let shared = sharedOwnerEvidence(
            app: owner, candidatePath: path, context: context,
            discoverySourcesValid: dataSourcesValid, liveObservation: liveSnapshot)
        {
          classification = .shared
          reason = .sharedInstalledData
          evidence = [shared]
        } else {
          classification = .uncertain
          reason = .ownershipUnavailable
        }
      } else if !owners.isEmpty {
        classification = strength == .weak ? .unprovenNameOnly : .installed
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
      candidate.displayRootIdentity = identity
      candidate.matchStrength = strength
      candidate.modifiedAt = identity?.modificationSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
      candidate.refusalEvidence = evidence
      candidate.provenance = claims.first?.provenance
      candidate.evidenceKinds = Array(
        Set(claims.map { $0.provenance.kind } + (exactOwners.isEmpty ? [] : [.bundleIdentifier]))
      ).sorted { $0.rawValue < $1.rawValue }
      candidate.explicitManualChoiceAvailable = classification == .unprovenNameOnly && evidence.isEmpty
      pending.append(candidate)
    }
    if !Task.isCancelled { progress?(candidates + pending) }
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
          let measurement = await relatedMeasurement(candidate.path, homeDirectory)
          result.observation = RelatedDataObservation(
            logical: measurement.logical, allocated: measurement.allocated,
            knownItemCount: measurement.count, partial: measurement.partial)
          // A metadata-only compatibility snapshot is an observation, never an inventory grant.
          if (standardInventoryComplete
            || (candidate.classification == .installed && candidate.matchStrength == .strong
              && RelatedLocation.matching(path: candidate.path, homeDirectory: homeDirectory)?.0 != .groupContainers))
            && receiptStoreHealthy && (candidate.matchStrength != .weak || candidate.explicitManualChoiceAvailable),
            candidate.classification == .installed || candidate.classification == .historicallyVerifiedAbsent
              || candidate.classification == .orphanVerified || candidate.classification == .unprovenNameOnly,
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
              modifiedAt: candidate.modifiedAt, refusalEvidence: candidate.refusalEvidence,
              provenance: candidate.provenance, explicitManualChoiceAvailable: candidate.explicitManualChoiceAvailable,
              evidenceKinds: candidate.evidenceKinds)
          }
          return (index, result)
        }
      }
      for _ in 0..<4 { enqueue() }
      while let (index, result) = await group.next() {
        results[index] = result
        if !Task.isCancelled { progress?(results) }
        enqueue()
      }
      return results
    }
    candidates += measured
    if let context = authenticatedContext, (try? context.validateDataSources()) == nil {
      candidates = candidates.map { candidate in
        guard ownedClaims[candidate.path] != nil else { return candidate }
        return RelatedDataCandidate(
          id: candidate.id, path: candidate.path, classification: .uncertain, reason: .ownershipUnavailable,
          snapshot: candidate.snapshot, receipt: candidate.receipt, bundleID: candidate.bundleID,
          matchStrength: candidate.matchStrength, observation: candidate.observation, modifiedAt: candidate.modifiedAt,
          refusalEvidence: candidate.refusalEvidence, provenance: candidate.provenance,
          explicitManualChoiceAvailable: false, evidenceKinds: candidate.evidenceKinds)
      }
    }
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
      // Report-only rows have a concrete observation refusal, but no proof
      // from which an action could be constructed.
      if !candidate.canSelect {
        guard candidate.classification != .historicallyVerifiedAbsent,
          candidate.classification != .orphanVerified, candidate.classification != .installed,
          candidate.reason != .historicallyVerified, candidate.reason != .orphanVerified,
          candidate.reason != .installed
        else { throw RelatedFailure.invalidReceipt }
        var reason = String(describing: candidate.reason)
        if candidate.reason == .incompleteInventory, let detail = installedListingFailureDetail(context) {
          reason = detail
        }
        let evidence = absenceRefusalEvidence(candidate: candidate, context: context)
        if let first = evidence.first {
          reason += ": " + (first.detail ?? first.reason.rawValue) + ": " + first.ownerPaths.joined(separator: ", ")
        }
        return AvailableUninstallPlan(
          plan: nil, rejections: [PlanRejection(.unavailable, path: candidate.path, ruleID: reason)],
          refusalEvidence: evidence)
      }
      return AvailableUninstallPlan(plan: try plan(candidate: candidate, context: context), rejections: [])
    } catch {
      return AvailableUninstallPlan(
        plan: nil, rejections: scopedRejections(error, path: candidate.path, context: context, groups: false),
        refusalEvidence: absenceRefusalEvidence(candidate: candidate, context: context))
    }
  }

  private func plan(candidate: RelatedDataCandidate, context: AuthenticApplicationContext) throws -> ActionPlan {
    if let id = candidate.bundleID ?? candidate.receipt?.bundleID,
      Self.standardPath(bundleID: id, homeDirectory: homeDirectory).contains(candidate.path),
      !standardInventoryIsComplete(context.inventory)
    {
      throw RelatedFailure.incompleteInventory
    }
    guard candidate.classification == .historicallyVerifiedAbsent || candidate.classification == .orphanVerified,
      candidate.canSelect, let bundleID = candidate.bundleID ?? candidate.receipt?.bundleID,
      Self.validBundleID(bundleID),
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
    try planContexts.bind(plan, context: context)
    return plan
  }

  public func planInstalled(app: InstalledApplication, candidate: RelatedDataCandidate) throws -> ActionPlan {
    guard app.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame else {
      throw PlanRejection(.lightenItself, path: app.path)
    }
    let package = try packagePlan(app: app)
    guard let physicalPath = package.items.first(where: { $0.policy == .wholeBundle })?.sourcePath,
      let physical = application(at: physicalPath), physical.bundleID == app.bundleID
    else { throw RelatedFailure.changedItem }
    let app = physical
    let context =
      isExactStandardSelection(app: app, candidates: [candidate])
      ? makeStandardContext(app: app, listing: installedListing()) : makeContext(including: [app])
    let selected = try selectedContext(app: app, base: context)
    try validateContext(
      selected, groups: candidate.path.contains("/Library/Group Containers/"),
      bundleIDs: [app.bundleID])
    return try planInstalled(app: app, candidate: candidate, context: selected)
  }

  private func planInstalled(
    app: InstalledApplication, candidate: RelatedDataCandidate, context: AuthenticApplicationContext,
    liveObservation: ApplicationLiveDataObservation? = nil
  ) throws -> ActionPlan {
    let apps = context.inventory
    if !isExactStandardSelection(app: app, candidates: [candidate]) { _ = ownedDataClaims(context) }
    let evidence = context.observedDataEvidence(packagePath: app.path, dataPath: candidate.path)
    if let id = context.standardBundleID {
      guard id == app.bundleID, isExactStandardSelection(app: app, candidates: [candidate]) || evidence != nil else {
        throw RelatedFailure.unsupportedInstalledData
      }
    }
    let groups = RelatedLocation.matching(path: candidate.path, homeDirectory: homeDirectory)?.0 == .groupContainers
    guard groups ? apps.complete : standardInventoryIsComplete(apps) else {
      throw RelatedFailure.incompleteInventory
    }
    if !groups { try validateMetadataScope(context, bundleID: app.bundleID, candidatePath: candidate.path) }
    if let evidence { try validateDataEvidence(evidence, context: context) }
    let owners =
      groups
      ? apps.applications.filter({ foldedAppID($0.bundleID) == foldedAppID(app.bundleID) })
      : installedOwners(bundleID: app.bundleID, applications: apps.applications)
    guard owners.count == 1,
      (try? DescriptorFileSystem.identity(at: owners[0].linkTarget ?? owners[0].path))
        == (try? DescriptorFileSystem.identity(at: app.path))
    else {
      throw RelatedFailure.ambiguousOwner
    }
    let metadata = try ApplicationPackagePlanning.metadata(at: app.path)
    guard apps.applications.contains(app), candidate.classification == .installed,
      candidate.canSelect,
      let observation = candidate.snapshot, let expected = observation.entries.first?.identity,
      let appIdentity = try? DescriptorFileSystem.identity(at: app.path),
      appIdentity.kind == .directory,
      metadata.rootIdentity == appIdentity, metadata.observation.bundleIdentifier == app.bundleID,
      let policy = installedPolicy(
        app: app, relatedPath: candidate.path, inventory: apps, context: context)
    else { throw RelatedFailure.unsupportedInstalledData }
    let current = try ExactInventory(homeDirectory: homeDirectory).collect(
      rootPath: candidate.path,
      expected: (expected.device, expected.inode), policy: policy)
    let root = current.entries[0]
    let proof = InstalledRelatedProof(
      bundleID: app.bundleID, appPath: app.path, appIdentity: appIdentity,
      infoIdentity: metadata.observation.infoIdentity, relatedPath: candidate.path,
      relatedIdentity: root.identity!,
      snapshotRunID: observation.runID)
    let item = PlanItem(
      id: root.id, sourcePath: candidate.path, volumeID: current.volumeID, inventory: current.entries,
      ancestors: current.ancestors, installedRelatedProof: proof, policy: policy,
      nestedApplicationIDs: current.nestedApplicationIDs, snapshotRunID: observation.runID)
    let plan = ActionPlan(snapshotRunID: observation.runID, kind: .trash, items: [item])
    try planContexts.bind(plan, context: context)
    try validateInstalled(item, plan: plan, context: context, liveObservation: liveObservation)
    return plan
  }

  public struct AvailableUninstallPlan: Sendable {
    public let plan: ActionPlan?
    public let rejections: [PlanRejection]
    public let refusalEvidence: [RelatedOwnershipRefusalEvidence]

    public init(
      plan: ActionPlan?, rejections: [PlanRejection], refusalEvidence: [RelatedOwnershipRefusalEvidence] = []
    ) {
      self.plan = plan
      self.rejections = rejections
      self.refusalEvidence = refusalEvidence
    }
  }

  /// The user may choose retained data even after its former owner moved.
  /// Original discovery observations supply display size and an optional root binding.
  @concurrent
  public func makeAvailableRemainingDataPlan(selected: [RelatedDataCandidate]) async -> AvailableUninstallPlan {
    let selections = selected.map { candidate in
      UserSelection(
        path: candidate.path, expectedIdentity: candidate.snapshot?.entries.first?.identity,
        observedSize: candidate.observation.map { ObservedPlanSize(logical: $0.logical, allocated: $0.allocated) })
    }
    let outcome = await PlanService(homeDirectory: homeDirectory).makeAvailableUserSelectionPlan(selections: selections)
    return AvailableUninstallPlan(plan: outcome.plan, rejections: outcome.rejections)
  }

  /// Preflights the application first, then keeps independently valid data in
  /// one plan. Data-only choices still depend on a movable application.
  @concurrent
  public func makeAvailableUninstallPlan(
    app: InstalledApplication, selectedRelated: [RelatedDataCandidate], includePackage: Bool = true,
    selectedUnprovenRelated: [RelatedDataCandidate] = []
  ) async -> AvailableUninstallPlan {
    await makeAvailableUninstallPlan(
      path: app.path, expectedBundleID: app.bundleID, selectedRelated: selectedRelated,
      includePackage: includePackage, selectedUnprovenRelated: selectedUnprovenRelated)
  }

  @concurrent
  public func makeAvailableUninstallPlan(
    path: String, expectedBundleID: String?, selectedRelated: [RelatedDataCandidate],
    includePackage: Bool = true, selectedUnprovenRelated: [RelatedDataCandidate] = []
  ) async -> AvailableUninstallPlan {
    await makeAvailableUninstallPlan(
      path: path, expectedBundleID: expectedBundleID, selectedRelated: selectedRelated,
      includePackage: includePackage, selectedUnprovenRelated: selectedUnprovenRelated, context: nil)
  }

  @concurrent
  func makeAvailableUninstallPlan(
    app: InstalledApplication, selectedRelated: [RelatedDataCandidate], includePackage: Bool,
    context: AuthenticApplicationContext?, selectedUnprovenRelated: [RelatedDataCandidate] = []
  ) async -> AvailableUninstallPlan {
    await makeAvailableUninstallPlan(
      path: app.path, expectedBundleID: app.bundleID, selectedRelated: selectedRelated,
      includePackage: includePackage, selectedUnprovenRelated: selectedUnprovenRelated, context: context)
  }

  private struct SelectedPackageActivity: ApplicationActivitySource {
    let observe: @Sendable (String) -> ApplicationActivity
    func activity(applicationPath: String) async -> ApplicationActivity { observe(applicationPath) }
  }

  @concurrent
  func makeAvailableUninstallPlan(
    path: String, expectedBundleID: String?, selectedRelated: [RelatedDataCandidate],
    includePackage: Bool, selectedUnprovenRelated: [RelatedDataCandidate] = [],
    context suppliedContext: AuthenticApplicationContext?
  ) async -> AvailableUninstallPlan {
    let helper = ApplicationPackagePlanning(
      homeDirectory: homeDirectory,
      applicationActivity: SelectedPackageActivity(observe: packageActivity))
    let built: ApplicationPackagePlan
    do {
      try Self.preflightPackageRootOwnership(at: path)
      if let excluded = scopeExclusion(at: path) {
        throw PlanRejection(.unavailable, path: excluded.path, ruleID: excluded.reason)
      }
      built = try await helper.makePlan(path: path, expectedBundleID: expectedBundleID)
      if let excluded = scopeExclusion(at: built.physicalPackage.sourcePath) {
        throw PlanRejection(.unavailable, path: excluded.path, ruleID: excluded.reason)
      }
    } catch {
      return AvailableUninstallPlan(
        plan: nil, rejections: Self.uninstallRejections(error, path: path))
    }
    let package = built.plan
    guard let app = built.physicalApplication else {
      return AvailableUninstallPlan(
        plan: includePackage ? package : nil,
        rejections: (selectedRelated + selectedUnprovenRelated).map {
          PlanRejection(.missingMetadata, path: $0.path, ruleID: "application-identifier-absent")
        })
    }
    var context: AuthenticApplicationContext?
    var contextError: (any Error)?
    if !selectedRelated.isEmpty || !selectedUnprovenRelated.isEmpty {
      do {
        let base =
          suppliedContext
          ?? (!selectedRelated.contains {
            RelatedLocation.matching(path: $0.path, homeDirectory: homeDirectory)?.0 == .groupContainers
          }
            ? makeStandardContext(app: app, listing: installedListing()) : makeContext(including: [app]))
        context = try selectedContext(app: app, base: base)
      } catch { contextError = error }
    }
    var standard: AuthenticApplicationContext?
    var validations: [ContextValidationKey: Result<Void, any Error>] = [:]
    var contexts: [UUID: AuthenticApplicationContext] = [:]
    var items: [PlanItem] = []
    var rejections: [PlanRejection] = []
    var refusalEvidence: [RelatedOwnershipRefusalEvidence] = []
    let selectedLive = selectedRelated.isEmpty ? nil : liveData()
    for candidate in selectedRelated {
      var candidateContext = context
      do {
        if let contextError { throw contextError }
        guard let context, !Task.isCancelled else { throw CancellationError() }
        let scoped: AuthenticApplicationContext
        if isExactStandardSelection(app: app, candidates: [candidate]), context.standardBundleID == nil {
          if standard == nil {
            standard = makeStandardContext(
              app: app, listing: context.installedListing, metadata: context.metadata, dataEvidenceSource: context)
          }
          guard let standard else { throw RelatedFailure.incompleteInventory }
          scoped = standard
        } else {
          scoped = context
        }
        candidateContext = scoped
        let groups = RelatedLocation.matching(path: candidate.path, homeDirectory: homeDirectory)?.0 == .groupContainers
        let key = ContextValidationKey(context: ObjectIdentifier(scoped), groups: groups, bundleID: app.bundleID)
        if validations[key] == nil {
          validations[key] = Result { try validateContext(scoped, groups: groups, bundleIDs: [app.bundleID]) }
        }
        try validations[key]?.get()
        let selected = try planInstalled(
          app: app, candidate: candidate, context: scoped, liveObservation: selectedLive)
        guard !items.contains(where: { $0.sourcePath == candidate.path }) else { continue }
        items += selected.items
        for item in selected.items { contexts[item.id] = scoped }
      } catch {
        if RelatedLocation.matching(path: candidate.path, homeDirectory: homeDirectory)?.0 != .groupContainers,
          Self.isCachedApplication(app.path, homeDirectory: homeDirectory)
        {
          let ownerPaths =
            candidateContext.map {
              installedOwners(bundleID: app.bundleID, applications: $0.inventory.applications)
                .map { $0.linkTarget ?? $0.path }.sorted()
            } ?? []
          rejections.append(
            PlanRejection(
              .unavailable, path: candidate.path,
              ruleID: "cache-copy-is-not-installed-owner: " + app.path
                + (ownerPaths.isEmpty ? "" : "; installed owner: " + ownerPaths.joined(separator: ", "))))
        } else {
          rejections += scopedRejections(
            error, path: candidate.path, context: candidateContext,
            groups: RelatedLocation.matching(path: candidate.path, homeDirectory: homeDirectory)?.0 == .groupContainers)
        }
        if let candidateContext {
          refusalEvidence += metadataRefusals(
            inventory: candidateContext.inventory,
            bundleID: app.bundleID, candidatePath: candidate.path, fresh: true)
          if error as? RelatedFailure == .ambiguousOwner,
            let shared = sharedOwnerEvidence(app: app, candidatePath: candidate.path, context: candidateContext)
          {
            refusalEvidence.append(shared)
          }
        }
      }
    }
    var manualItems: [PlanItem] = []
    for candidate in selectedUnprovenRelated {
      do {
        guard !Task.isCancelled, let context else { throw RelatedFailure.incompleteInventory }
        if let contextError { throw contextError }
        guard candidate.classification == .unprovenNameOnly, candidate.reason == .nameOnly,
          let snapshot = candidate.snapshot, snapshot.rootPath == candidate.path,
          let expected = snapshot.entries.first?.identity,
          (try DescriptorFileSystem.identity(at: candidate.path)) == expected
        else { throw RelatedFailure.changedItem }
        try validateUnprovenSelection(path: candidate.path, app: app, original: context)
        let current = try ExactInventory(homeDirectory: homeDirectory).collect(
          rootPath: candidate.path, expected: (expected.device, expected.inode), policy: .spaceTrash)
        guard current.entries.first?.identity == expected else { throw RelatedFailure.changedItem }
        let item = PlanItem(
          id: current.entries[0].id, sourcePath: candidate.path, volumeID: current.volumeID,
          inventory: current.entries, ancestors: current.ancestors, policy: .spaceTrash,
          nestedApplicationIDs: current.nestedApplicationIDs, snapshotRunID: snapshot.runID)
        guard !items.contains(where: { $0.sourcePath == item.sourcePath }) else { continue }
        items.append(item)
        manualItems.append(item)
      } catch { rejections += Self.uninstallRejections(error, path: candidate.path) }
    }
    if includePackage { items += package.items }
    var plan =
      items.isEmpty
      ? nil
      : ActionPlan(
        snapshotRunID: items.first?.snapshotRunID ?? package.snapshotRunID, kind: .trash,
        items: items)
    if let combined = plan {
      // A new combined plan receives a new private physical/link preparation.
      let prepared = helper.prepare(plan: combined)
      if !prepared.failures.isEmpty {
        let refusedPackages = Set(
          combined.items.compactMap { item in
            item.policy == .wholeBundle && prepared.failures[item.id] != nil ? item.sourcePath : nil
          })
        items = combined.items.filter { item in
          if let refusal = prepared.failures[item.id] {
            rejections.append(refusal)
            return false
          }
          if let proof = item.installedRelatedProof, refusedPackages.contains(proof.appPath) {
            rejections.append(
              PlanRejection(
                .changedSinceScan, path: item.sourcePath, ruleID: "application-package-changed"))
            return false
          }
          return true
        }
        plan =
          items.isEmpty
          ? nil
          : ActionPlan(
            snapshotRunID: combined.snapshotRunID, kind: .trash, items: items)
      }
    }
    if let plan {
      do {
        try planContexts.bind(plan, contexts: contexts)
        if let context {
          try ApplicationExplicitSelections.bind(plan, items: manualItems) { item in
            try validateUnprovenSelection(path: item.sourcePath, app: app, original: context)
          }
        }
      } catch {
        return AvailableUninstallPlan(
          plan: nil, rejections: rejections + Self.uninstallRejections(error, path: path),
          refusalEvidence: refusalEvidence)
      }
    }
    return AvailableUninstallPlan(plan: plan, rejections: rejections, refusalEvidence: refusalEvidence)
  }

  private func validateUnprovenSelection(
    path: String, app: InstalledApplication, original: AuthenticApplicationContext
  ) throws {
    guard let (location, domain) = RelatedLocation.matching(path: path, homeDirectory: homeDirectory),
      location == .applicationSupport || location == .logs,
      domain.caseInsensitiveCompare(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent)
        == .orderedSame,
      !Self.isCachedApplication(app.path, homeDirectory: homeDirectory), Self.currentUserOwns(path),
      ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) == nil,
      (try DescriptorFileSystem.identity(at: path)).kind == .directory
    else { throw RelatedFailure.unsupportedInstalledData }
    for observation in original.observedInfoAbsences() { try observation.validateAbsence() }
    let listing: BundleInventory
    if (try? validateInstallationDirectories(original.installedListing)) != nil {
      listing = original.installedListing
    } else {
      listing = installedListing()
    }
    let current = makeStandardContext(app: app, listing: listing, metadata: original.metadata)
    guard standardInventoryIsComplete(current.inventory) else { throw RelatedFailure.incompleteInventory }
    try validateMetadataScope(current, bundleID: app.bundleID, candidatePath: path)
    try validateMetadataScope(current, bundleID: domain, candidatePath: path)
    guard (ownedDataClaims(current)[path] ?? []).isEmpty else { throw RelatedFailure.ownerPresent }
    let owners = installedOwners(bundleID: app.bundleID, applications: current.inventory.applications)
    guard owners.count <= 1 else { throw RelatedFailure.ambiguousOwner }
    let activity = packageActivity(app.path)
    switch activity.state {
    case .clearObservedProcesses: break
    case .active: throw ProcessActivityFailure.active(processNames: activity.processNames)
    case .unknown: throw ProcessActivityFailure.unavailable
    }
  }

  func validateExplicitSelection(_ item: PlanItem, plan: ActionPlan) throws {
    try ApplicationExplicitSelections.validate(item, plan: plan)
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
    let prepared = prepareInstalledOwners(plan: plan, readOnlyReview: true)
    let packages = ApplicationPackagePlanning(homeDirectory: homeDirectory).prepare(plan: plan)
    let guardService = ActionGuard(homeDirectory: homeDirectory)
    let running = NativeRunningApplicationSource()
    var packageResults: [String: [PlanRejection]] = [:]
    var rejections: [PlanRejection] = []
    for item in plan.items {
      if Task.isCancelled {
        rejections.append(PlanRejection(.unavailable, path: item.sourcePath, ruleID: "cancelled"))
        continue
      }
      do {
        if let proof = item.installedRelatedProof {
          guard let owner = prepared.owners[item.id] else {
            let failure = prepared.failures[item.id] ?? "owner-unavailable"
            if failure == String(describing: RelatedFailure.changedItem),
              let context = planContexts.context(for: plan, scope: contextScope, itemID: item.id),
              let rejection = scopedRejections(
                RelatedFailure.changedItem, path: item.sourcePath, context: context,
                groups: item.policy == .relatedGroupContainer
              ).first
            {
              throw rejection
            }
            throw PlanRejection(.unavailable, path: item.sourcePath, ruleID: failure)
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
          let absentContext = try context(for: plan, item: item)
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
        } else if item.policy == .applicationLink {
          if let failure = packages.failures[item.id] { throw failure }
          guard let link = packages.links[item.id] else {
            throw PlanRejection(
              .unavailable, path: item.sourcePath, ruleID: "application-link-pair")
          }
          try guardService.validate(item, plan: plan, preparedLink: link)
        } else if item.policy == .spaceTrash {
          guard ApplicationExplicitSelections.containsBoundSelection(item, plan: plan) else {
            throw PlanRejection(.unavailable, path: item.sourcePath, ruleID: "invalid-scope")
          }
          try guardService.validate(item, plan: plan)
        } else {
          guard item.policy == .wholeBundle else {
            throw PlanRejection(.unavailable, path: item.sourcePath, ruleID: "invalid-scope")
          }
          if let excluded = scopeExclusion(at: item.sourcePath) {
            throw PlanRejection(.unavailable, path: excluded.path, ruleID: excluded.reason)
          }
          if let failure = packages.failures[item.id] { throw failure }
          let metadata = try ApplicationPackagePlanning.validatePackage(item)
          // Activity remains fresh for identifierless packages too.
          let activity = packageActivity(item.sourcePath)
          switch activity.state {
          case .clearObservedProcesses: break
          case .active: throw ProcessActivityFailure.active(processNames: activity.processNames)
          case .unknown: throw ProcessActivityFailure.unavailable
          }
          try guardService.validate(item)
          for id in [metadata.observation.bundleIdentifier].compactMap({ $0 })
            + (item.nestedApplicationIDs ?? [])
          {
            switch await running.isRunning(bundleID: id) {
            case false: break
            case true: throw PlanRejection(.applicationRunning, path: item.sourcePath, ruleID: id)
            case nil: throw PlanRejection(.activityUnavailable, path: item.sourcePath, ruleID: id)
            }
          }
        }
      } catch {
        let context = planContexts.context(for: plan, scope: contextScope, itemID: item.id)
        if error as? RelatedFailure == .incompleteInventory, context == nil,
          item.orphanRelatedProof != nil || item.relatedProof != nil
        {
          rejections.append(
            PlanRejection(
              .unavailable, path: item.sourcePath,
              ruleID: "incompleteInventory: original private plan context unavailable; review again"))
        } else {
          rejections += scopedRejections(
            error, path: item.sourcePath, context: context, groups: item.policy == .relatedGroupContainer)
        }
      }
    }
    return rejections
  }

  private func installedListingFailureDetail(_ context: AuthenticApplicationContext) -> String? {
    guard !standardInventoryIsComplete(context.installedListing) else { return nil }
    let listing = context.installedListing
    let failures =
      listing.ownershipIssues.map { $0.path + " (errno " + String($0.code) + ")" }
      + listing.metadataIssues.map { $0.path + " (" + $0.reason + ")" }
    return "incompleteInventory: installed application listing incomplete: "
      + (failures.isEmpty ? applicationRoots.joined(separator: ", ") : failures.joined(separator: ", "))
  }

  private func scopedRejections(
    _ error: any Error, path: String, context: AuthenticApplicationContext?, groups: Bool
  ) -> [PlanRejection] {
    if error as? RelatedFailure == .changedItem, let context, groups,
      let changed = context.lineage.first(where: {
        !$0.path.hasPrefix("/System/") && (try? $0.validate()) == nil
      })
    {
      return [
        PlanRejection(
          .unavailable, path: path,
          ruleID: "changedItem: ownership observation changed: " + changed.path)
      ]
    }
    if error as? RelatedFailure == .incompleteInventory, let context,
      let detail = installedListingFailureDetail(context)
    {
      return [PlanRejection(.unavailable, path: path, ruleID: detail)]
    }
    return Self.uninstallRejections(error, path: path)
  }

  private static func uninstallRejections(_ error: any Error, path: String) -> [PlanRejection] {
    if let rejection = error as? PlanRejection { return [normalizedActivityRejection(rejection)] }
    if let rejections = error as? PlanRejections { return rejections.rejections.map(normalizedActivityRejection) }
    if let activity = error as? ProcessActivityFailure {
      switch activity {
      case .active(let names): return [PlanRejection(.processActive, path: path, ruleID: names.joined(separator: ", "))]
      case .unavailable: return [PlanRejection(.activityUnavailable, path: path)]
      }
    }
    return [PlanRejection(.unavailable, path: path, ruleID: String(describing: error))]
  }

  private static func normalizedActivityRejection(_ rejection: PlanRejection) -> PlanRejection {
    guard rejection.reason == .activityUnavailable, rejection.ruleID == "" else { return rejection }
    return PlanRejection(.activityUnavailable, path: rejection.path)
  }

  /// One action and one grouped Undo for an application and explicitly selected data.
  public func planUninstall(app: InstalledApplication, selectedRelated: [RelatedDataCandidate]) throws -> ActionPlan {
    guard app.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame else {
      throw PlanRejection(.lightenItself, path: app.path)
    }
    let package = try packagePlan(app: app)
    guard let physicalPath = package.items.first(where: { $0.policy == .wholeBundle })?.sourcePath,
      let physical = application(at: physicalPath), physical.bundleID == app.bundleID
    else { throw RelatedFailure.changedItem }
    let app = physical
    let context =
      selectedRelated.isEmpty
      ? nil
      : (isExactStandardSelection(app: app, candidates: selectedRelated)
        ? makeStandardContext(app: app, listing: installedListing()) : makeContext(including: [app]))
    var standard: AuthenticApplicationContext?
    var contexts: [UUID: AuthenticApplicationContext] = [:]
    var items: [PlanItem] = []
    for candidate in selectedRelated {
      guard let context else { throw RelatedFailure.incompleteInventory }
      let scoped: AuthenticApplicationContext
      if isExactStandardSelection(app: app, candidates: [candidate]), context.standardBundleID == nil {
        if standard == nil {
          standard = makeStandardContext(
            app: app, listing: context.installedListing, metadata: context.metadata, dataEvidenceSource: context)
        }
        guard let standard else { throw RelatedFailure.incompleteInventory }
        scoped = standard
      } else {
        scoped = try selectedContext(app: app, base: context)
      }
      try validateContext(
        scoped, groups: candidate.path.contains("/Library/Group Containers/"), bundleIDs: [app.bundleID])
      let selected = try planInstalled(app: app, candidate: candidate, context: scoped)
      items += selected.items
      for item in selected.items { contexts[item.id] = scoped }
    }
    items += package.items
    let plan = ActionPlan(
      snapshotRunID: items.first?.snapshotRunID ?? package.snapshotRunID, kind: .trash, items: items)
    try planContexts.bind(plan, contexts: contexts)
    return plan
  }

  /// Owner observations order refusals only; the package helper still builds
  /// and revalidates every native metadata, protection and link binding.
  private static func preflightPackageRootOwnership(at path: String) throws {
    var original = stat()
    guard lstat(path, &original) == 0 else { throw FileSystemFailure.systemCall("lstat", errno) }
    guard original.st_uid == geteuid() else { throw PlanRejection(.needsAdministrator, path: path) }
    if original.st_mode & S_IFMT == S_IFLNK {
      guard let resolved = realpath(path, nil) else { throw FileSystemFailure.systemCall("realpath", errno) }
      defer { free(resolved) }
      let physical = String(cString: resolved)
      var target = stat()
      guard lstat(physical, &target) == 0 else { throw FileSystemFailure.systemCall("lstat", errno) }
      guard target.st_uid == geteuid() else { throw PlanRejection(.needsAdministrator, path: physical) }
      guard (try DescriptorFileSystem.identity(at: path)) == DescriptorFileSystem.identity(from: original) else {
        throw PlanRejection(.changedSinceScan, path: path)
      }
    }
  }

  func packagePlan(app: InstalledApplication) throws -> ActionPlan {
    try Self.preflightPackageRootOwnership(at: app.path)
    if let excluded = scopeExclusion(at: app.path) {
      throw PlanRejection(.unavailable, path: excluded.path, ruleID: excluded.reason)
    }
    let built = try ApplicationPackagePlanning(homeDirectory: homeDirectory)
      .makeIdentityPlan(path: app.path, expectedBundleID: app.bundleID)
    let observation = packageActivity(built.physicalPackage.sourcePath)
    switch observation.state {
    case .clearObservedProcesses: break
    case .active: throw ProcessActivityFailure.active(processNames: observation.processNames)
    case .unknown: throw ProcessActivityFailure.unavailable
    }
    return built.plan
  }

  func installedPolicy(
    app: InstalledApplication, relatedPath: String, inventory: BundleInventory,
    context: AuthenticApplicationContext? = nil
  ) -> TreePolicy? {
    if let context, let evidence = context.observedDataEvidence(packagePath: app.path, dataPath: relatedPath),
      (try? validateDataEvidence(evidence, context: context)) != nil
    {
      return .relatedTrash
    }
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

  private struct ContextValidationKey: Hashable {
    let context: ObjectIdentifier
    let groups: Bool
    let bundleID: String
  }

  func prepareInstalledOwners(plan: ActionPlan, readOnlyReview: Bool = false) -> InstalledOwnerPreparation {
    let items = plan.items.filter { $0.installedRelatedProof != nil }
    guard !items.isEmpty else { return InstalledOwnerPreparation() }
    let live = liveData()
    var result = InstalledOwnerPreparation()
    var validations: [ContextValidationKey: Result<Void, any Error>] = [:]
    for item in items {
      do {
        let context = try self.context(for: plan, item: item)
        guard let proof = item.installedRelatedProof else { throw RelatedFailure.unsupportedInstalledData }
        let groups = item.policy == .relatedGroupContainer
        let key = ContextValidationKey(context: ObjectIdentifier(context), groups: groups, bundleID: proof.bundleID)
        if validations[key] == nil {
          validations[key] = Result { try validateContext(context, groups: groups, bundleIDs: [proof.bundleID]) }
        }
        try validations[key]?.get()
        let apps = context.inventory
        try validateInstalled(item, plan: plan, context: context, liveObservation: live)
        guard let proof = item.installedRelatedProof else { throw RelatedFailure.unsupportedInstalledData }
        let evidence = context.observedDataEvidence(packagePath: proof.appPath, dataPath: item.sourcePath)
        let matched = RelatedLocation.matching(path: item.sourcePath, homeDirectory: homeDirectory)
        guard evidence != nil || matched != nil else { throw RelatedFailure.unsupportedInstalledData }
        // Exact-ID data is authorized by the current private app/Info proof.
        // Cryptographic code identity is additional authority only when a
        // group entitlement or a team prefix supplied the ownership claim.
        var identities: [ApplicationSignatureIdentity] = []
        if matched?.0 == .groupContainers {
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
        } else if evidence == nil && matched?.1 != proof.bundleID {
          identities.append(try ApplicationSignatureIdentity.capture(proof.appPath))
          guard let observation = context.signature(at: proof.appPath, cache: signatureCache),
            observation.metadata != nil
          else {
            throw RelatedFailure.unsupportedInstalledData
          }
          identities.append(observation.identity)
        }
        for identity in identities { try identity.validate() }
        let validateEnvironment: (@Sendable (MovedApplicationOwner?) throws -> Void)?
        if let evidence {
          validateEnvironment = { moved in
            try self.validateDataEnvironment(
              evidence, context: context, movedOwner: moved, liveObservation: readOnlyReview ? live : nil)
          }
        } else {
          validateEnvironment = { _ in
            try self.validateLiveSharing(
              path: item.sourcePath, excludingPackage: proof.appPath,
              applications: context.inventory.applications, observation: readOnlyReview ? live : nil)
          }
        }
        result.owners[item.id] = PreparedInstalledOwner(
          planID: plan.id, item: item, signatures: identities, dataEvidence: evidence,
          validateDataEnvironment: validateEnvironment)
      } catch { result.failures[item.id] = String(describing: error) }
    }
    return result
  }

  public func validateInstalled(_ item: PlanItem, plan: ActionPlan) throws {
    let context = try self.context(for: plan, item: item)
    try validateContext(
      context, groups: item.policy == .relatedGroupContainer,
      bundleIDs: Set([item.installedRelatedProof?.bundleID].compactMap { $0 }))
    try validateInstalled(item, plan: plan, context: context)
  }

  private func validateInstalled(
    _ item: PlanItem, plan: ActionPlan, context: AuthenticApplicationContext,
    liveObservation: ApplicationLiveDataObservation? = nil
  ) throws {
    let apps = context.inventory
    let dataEvidence = item.installedRelatedProof.flatMap {
      context.observedDataEvidence(packagePath: $0.appPath, dataPath: item.sourcePath)
    }
    if let id = context.standardBundleID {
      guard let proof = item.installedRelatedProof, proof.bundleID == id,
        dataEvidence != nil
          || (RelatedLocation.matching(path: item.sourcePath, homeDirectory: homeDirectory).map {
            $0.0 != .groupContainers && $0.1 == id
          } == true)
      else { throw RelatedFailure.unsupportedInstalledData }
    }
    try validateScope(item, plan: plan)
    guard let installedProof = item.installedRelatedProof else {
      throw RelatedFailure.unsupportedInstalledData
    }
    guard let metadata = try? ApplicationPackagePlanning.metadata(at: installedProof.appPath) else {
      throw RelatedFailure.unsupportedInstalledData
    }
    guard plan.kind == .trash, let proof = item.installedRelatedProof,
      proof.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame,
      proof.snapshotRunID == (item.snapshotRunID ?? plan.snapshotRunID), proof.relatedPath == item.sourcePath,
      item.inventory.first?.identity == proof.relatedIdentity,
      (try? DescriptorFileSystem.validatedComponents(proof.appPath)) != nil,
      ProtectionPolicy.rule(for: proof.appPath, homeDirectory: homeDirectory) == nil,
      metadata.rootIdentity == proof.appIdentity,
      metadata.observation.infoIdentity == proof.infoIdentity,
      metadata.observation.bundleIdentifier == proof.bundleID,
      (try? DescriptorFileSystem.identity(at: item.sourcePath)) == proof.relatedIdentity,
      Self.currentUserOwns(item.sourcePath)
    else { throw RelatedFailure.unsupportedInstalledData }
    guard item.policy == .relatedGroupContainer ? apps.complete : standardInventoryIsComplete(apps) else {
      throw RelatedFailure.incompleteInventory
    }
    if item.policy != .relatedGroupContainer {
      try validateMetadataScope(context, bundleID: proof.bundleID, candidatePath: item.sourcePath)
    }
    try validateLiveSharing(
      path: item.sourcePath, excludingPackage: proof.appPath, applications: apps.applications,
      observation: liveObservation)
    if let dataEvidence { try validateDataEvidence(dataEvidence, context: context) }
    let currentOwners = installedOwners(bundleID: proof.bundleID, applications: apps.applications)
    let selectedRoot = currentOwners.first.map { $0.linkTarget ?? $0.path }
    let uniqueStandardOwner =
      currentOwners.count == 1
      && selectedRoot.flatMap { try? DescriptorFileSystem.identity(at: $0) } == proof.appIdentity
    guard
      item.policy == .relatedGroupContainer
        ? apps.applications.filter({ foldedAppID($0.bundleID) == foldedAppID(proof.bundleID) }).map(\.path) == [
          proof.appPath
        ]
        : uniqueStandardOwner,
      let app = apps.applications.first(where: { $0.path == proof.appPath }),
      let policy = installedPolicy(app: app, relatedPath: item.sourcePath, inventory: apps, context: context),
      item.policy == nil || item.policy == policy
    else { throw RelatedFailure.ambiguousOwner }
  }

  public func validateOrphan(_ item: PlanItem, plan: ActionPlan) throws {
    try validateOrphan(item, plan: plan, context: context(for: plan, item: item))
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
    try validateAbsentOwner(bundleID: proof.bundleID, candidatePath: item.sourcePath, context: context)
  }

  public func validate(_ item: PlanItem, plan: ActionPlan) throws {
    try validate(item, plan: plan, context: context(for: plan, item: item))
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
    try validateAbsentOwner(bundleID: proof.bundleID, candidatePath: item.sourcePath, context: context)
  }

  private func validateAbsentOwner(bundleID: String, candidatePath: String, context: AuthenticApplicationContext) throws
  {
    // Absence is never granted by the selected-owner-only standard scope.
    guard context.standardBundleID == nil else { throw RelatedFailure.unsupportedInstalledData }
    try validateMetadataScope(context, bundleID: bundleID, candidatePath: candidatePath)
    try validateLineage(context, bundleIDs: [bundleID])
    let apps = context.inventory
    guard standardInventoryIsComplete(apps) else { throw RelatedFailure.incompleteInventory }
    let registered = registeredByID(bundleID)
    guard registered.complete else { throw RelatedFailure.incompleteInventory }
    for path in registered.paths
    where !ApplicationRegistration.isTrash(path)
      && !Self.isCachedApplication(path, homeDirectory: homeDirectory)
    {
      do {
        let current = try decisionApplication(at: path, registered: true, metadata: context.metadata)
        guard let current else {
          continue
        }
        if Self.isCachedApplication(current.linkTarget ?? current.path, homeDirectory: homeDirectory) { continue }
        if foldedAppID(current.bundleID) == foldedAppID(bundleID) { throw RelatedFailure.ownerPresent }
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT { continue } catch RelatedFailure
        .incompleteInventory
      {
        let observation = ApplicationMetadataObservation.read(at: path)
        switch observation.state {
        case .identifierless: continue
        case .absentInfo:
          try observation.validateAbsence()
          context.recordInfoAbsence(observation)
          continue
        case .declaredID(let id):
          if foldedAppID(id) == foldedAppID(bundleID) { throw RelatedFailure.ownerPresent }
        case .unknown: throw RelatedFailure.incompleteInventory
        }
      }
    }
    try validateMetadataScope(context, bundleID: bundleID, candidatePath: candidatePath)
    guard installedOwners(bundleID: bundleID, applications: apps.applications).isEmpty,
      !registered.paths.isEmpty || !installedElsewhere(bundleID),
      !apps.applications.filter({ !Self.isCachedApplication($0.linkTarget ?? $0.path, homeDirectory: homeDirectory) })
        .contains(where: {
          bundleID.hasPrefix($0.bundleID + "-") || bundleID.hasPrefix($0.bundleID + ".")
        })
    else { throw RelatedFailure.ownerPresent }
  }

  static func currentUserOwns(_ path: String) -> Bool {
    var details = stat()
    return lstat(path, &details) == 0 && details.st_uid == geteuid()
  }

  private func standardInventoryIsComplete(_ inventory: BundleInventory) -> Bool {
    inventory.installedRootsComplete ?? inventory.complete
  }

  private func registrationIsOnlyMissingSource(_ inventory: BundleInventory) -> Bool {
    inventory.registrationReport?.complete == false
      && standardInventoryIsComplete(inventory)
      && inventory.ownershipIssues.allSatisfy(\.systemScope)
      && inventory.metadataIssues.allSatisfy { $0.path.hasPrefix("/System/") }
      && inventory.unresolvedApplicationMetadata.isEmpty
  }

  static func isCachedApplication(_ path: String, homeDirectory: String) -> Bool {
    let folded = foldedAppID(path)
    let homes = [homeDirectory, "/System/Volumes/Data" + homeDirectory]
    if homes.contains(where: { home in
      let cache = foldedAppID(home + "/Library/Caches")
      return folded == cache || folded.hasPrefix(cache + "/")
    }) {
      return true
    }
    return folded.split(separator: "/").contains {
      ["deriveddata", "coresimulator", ".trash", ".trashes", "node_modules"].contains(String($0))
    }
  }

  private func installedOwners(bundleID: String, applications: [InstalledApplication]) -> [InstalledApplication] {
    var seen: Set<String> = []
    return applications.sorted { $0.path < $1.path }.filter { app in
      let physical = app.linkTarget ?? app.path
      guard foldedAppID(app.bundleID) == foldedAppID(bundleID),
        !Self.isCachedApplication(app.path, homeDirectory: homeDirectory),
        !Self.isCachedApplication(physical, homeDirectory: homeDirectory),
        let root = try? DescriptorFileSystem.identity(at: physical), root.kind == .directory
      else { return false }
      return seen.insert("\(root.device):\(root.inode)").inserted
    }
  }

  private func metadataRefusals(
    inventory: BundleInventory, bundleID: String, candidatePath: String,
    signatures: [String: ApplicationSigningMetadata] = [:],
    observations: [ApplicationMetadataObservation]? = nil, fresh: Bool = false
  ) -> [RelatedOwnershipRefusalEvidence] {
    let target = foldedAppID(bundleID + " " + candidatePath)
    return (observations ?? inventory.applicationMetadata).compactMap { original in
      guard !Self.isCachedApplication(original.path, homeDirectory: homeDirectory),
        !Self.isCachedApplication(original.physicalPath, homeDirectory: homeDirectory)
      else { return nil }
      let observation: ApplicationMetadataObservation
      if fresh {
        switch original.state {
        case .unknown: observation = ApplicationMetadataObservation.read(at: original.path)
        case .declaredID(let id) where !Self.validBundleID(id):
          observation = ApplicationMetadataObservation.read(at: original.path)
        default: observation = original
        }
      } else {
        observation = original
      }
      switch observation.state {
      case .declaredID(let id):
        if observations == nil, case .declaredID(let previous) = original.state, Self.validBundleID(previous) {
          return nil
        }
        guard foldedAppID(id) == foldedAppID(bundleID) else { return nil }
        return RelatedOwnershipRefusalEvidence(
          candidatePath: candidatePath, bundleID: bundleID, reason: .observedLiteralOwner,
          ownerPaths: [observation.physicalPath], nextStep: "review-observed-owner", detail: id)
      case .unknown(let reason):
        var names = [((observation.physicalPath as NSString).deletingPathExtension as NSString).lastPathComponent]
        if let executable = observation.executableName { names.append(executable) }
        names += inventory.ownershipCandidates.filter {
          $0.packagePath == observation.path || $0.packagePath == observation.physicalPath
        }.map { ($0.path as NSString).lastPathComponent }
        let team =
          fresh ? signingMetadata(observation.physicalPath)?.teamID : signatures[observation.physicalPath]?.teamID
        let sharesKnownOwnerTeam =
          team.map { team in
            inventory.applications.contains { owner in
              guard foldedAppID(owner.bundleID) == foldedAppID(bundleID),
                !Self.isCachedApplication(owner.path, homeDirectory: homeDirectory),
                !Self.isCachedApplication(owner.linkTarget ?? owner.path, homeDirectory: homeDirectory)
              else { return false }
              let ownerTeam =
                fresh ? signingMetadata(owner.linkTarget ?? owner.path)?.teamID : signatures[owner.path]?.teamID
              return ownerTeam == team
            }
          } ?? false
        guard
          names.contains(where: { !$0.isEmpty && target.contains(foldedAppID($0)) })
            || team.map({ foldedAppID(bundleID).hasPrefix(foldedAppID($0) + ".") }) == true
            || sharesKnownOwnerTeam
        else { return nil }
        return RelatedOwnershipRefusalEvidence(
          candidatePath: candidatePath, bundleID: bundleID, reason: .unknownMetadata,
          ownerPaths: [observation.physicalPath], nextStep: "inspect-owner-metadata", detail: reason)
      case .identifierless, .absentInfo: return nil
      }
    }
  }

  private func validateMetadataScope(
    _ context: AuthenticApplicationContext, bundleID: String, candidatePath: String
  ) throws {
    for observation in context.observedInfoAbsences() {
      if Self.isCachedApplication(observation.path, homeDirectory: homeDirectory)
        || Self.isCachedApplication(observation.physicalPath, homeDirectory: homeDirectory)
      {
        continue
      }
      if case .absentInfo = observation.state { try observation.validateAbsence() }
    }
    let refusals = metadataRefusals(
      inventory: context.inventory, bundleID: bundleID, candidatePath: candidatePath, fresh: true)
    if refusals.contains(where: { $0.reason == .observedLiteralOwner }) { throw RelatedFailure.ownerPresent }
    guard refusals.isEmpty else { throw RelatedFailure.incompleteInventory }
  }

  private func absenceRefusalEvidence(
    candidate: RelatedDataCandidate, context: AuthenticApplicationContext
  ) -> [RelatedOwnershipRefusalEvidence] {
    guard let id = candidate.bundleID ?? candidate.receipt?.bundleID else { return [] }
    var evidence = metadataRefusals(
      inventory: context.inventory, bundleID: id, candidatePath: candidate.path, fresh: true)
    for observation in context.observedInfoAbsences() {
      guard case .absentInfo = observation.state,
        !Self.isCachedApplication(observation.path, homeDirectory: homeDirectory),
        !Self.isCachedApplication(observation.physicalPath, homeDirectory: homeDirectory)
      else { continue }
      do { try observation.validateAbsence() } catch {
        evidence.append(
          RelatedOwnershipRefusalEvidence(
            candidatePath: candidate.path, bundleID: id, reason: .infoAbsenceChanged,
            ownerPaths: [observation.physicalPath], nextStep: "scan-again", detail: String(describing: error)))
      }
    }
    return evidence
  }

  private func currentInstalledListing(_ context: AuthenticApplicationContext) -> BundleInventory {
    if standardInventoryIsComplete(context.installedListing),
      (try? validateInstallationDirectories(context.installedListing)) != nil
    {
      return context.installedListing
    }
    return installedListing()
  }

  private func sharedOwnerEvidence(
    app: InstalledApplication, candidatePath: String, context: AuthenticApplicationContext,
    discoverySourcesValid: Bool? = nil, liveObservation: ApplicationLiveDataObservation? = nil
  ) -> RelatedOwnershipRefusalEvidence? {
    let sourcesValid = discoverySourcesValid ?? ((try? context.validateDataSources()) != nil)
    if let selected = context.observedDataEvidence(packagePath: app.linkTarget ?? app.path, dataPath: candidatePath),
      let others = try? ApplicationAuxiliaryEvidenceProducer.liveSharedOwnerPaths(
        dataPath: candidatePath, excludingPackage: selected.packagePath,
        applications: context.inventory.applications, home: homeDirectory,
        observation: liveObservation ?? liveData()), !others.isEmpty,
      (try? selected.validate()) != nil, sourcesValid
    {
      return RelatedOwnershipRefusalEvidence(
        candidatePath: candidatePath, bundleID: app.bundleID, reason: .sharedInstalledOwners,
        ownerPaths: Array(Set(others + [selected.packagePath])).sorted(),
        nextStep: "review-other-installations", detail: nil)
    }
    let claims = context.observedDataClaims()?[candidatePath] ?? []
    if Set(claims.map(\.packagePath)).count > 1 {
      do {
        guard sourcesValid else { throw RelatedFailure.changedItem }
        var physical: Set<String> = []
        for claim in claims {
          try claim.validate()
          guard !Self.isCachedApplication(claim.packagePath, homeDirectory: homeDirectory),
            let current = try decisionApplication(at: claim.packagePath, metadata: context.metadata),
            current.bundleID == claim.bundleID,
            let resolved = realpath(claim.packagePath, nil)
          else { return nil }
          physical.insert(String(cString: resolved))
          free(resolved)
        }
        if physical.count > 1 {
          return RelatedOwnershipRefusalEvidence(
            candidatePath: candidatePath, bundleID: app.bundleID, reason: .sharedInstalledOwners,
            ownerPaths: physical.sorted(), nextStep: "review-other-installations", detail: nil)
        }
      } catch { return nil }
    }
    let registered = registeredByID(app.bundleID)
    guard registered.complete else { return nil }
    let listing = currentInstalledListing(context)
    guard standardInventoryIsComplete(listing),
      metadataRefusals(inventory: listing, bundleID: app.bundleID, candidatePath: candidatePath, fresh: true).isEmpty
    else { return nil }
    let known = context.inventory.applications + listing.applications
    let originallySelected = Set(
      known.filter { foldedAppID($0.bundleID) == foldedAppID(app.bundleID) }.map(\.path))
    let paths = Set(known.map(\.path) + registered.paths)
    var owners: [InstalledApplication] = []
    for path in paths where !Self.isCachedApplication(path, homeDirectory: homeDirectory) {
      do {
        if let current = try decisionApplication(at: path, registered: true, metadata: context.metadata),
          foldedAppID(current.bundleID) == foldedAppID(app.bundleID)
        {
          owners.append(current)
        }
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT { continue } catch {
        let observation = ApplicationMetadataObservation.read(at: path)
        switch observation.state {
        case .identifierless, .absentInfo: continue
        case .declaredID(let id):
          if foldedAppID(id) != foldedAppID(app.bundleID) { continue }
          return nil
        case .unknown:
          if registered.paths.contains(path) || originallySelected.contains(path)
            || !metadataRefusals(
              inventory: listing, bundleID: app.bundleID, candidatePath: candidatePath,
              observations: [observation], fresh: true
            ).isEmpty
          {
            return nil
          }
        }
      }
    }
    let physical = installedOwners(bundleID: app.bundleID, applications: owners).compactMap { owner -> String? in
      guard let resolved = realpath(owner.linkTarget ?? owner.path, nil) else { return nil }
      defer { free(resolved) }
      return String(cString: resolved)
    }.sorted()
    guard physical.count > 1 else { return nil }
    return RelatedOwnershipRefusalEvidence(
      candidatePath: candidatePath, bundleID: app.bundleID, reason: .sharedInstalledOwners,
      ownerPaths: physical, nextStep: "review-other-installations", detail: nil)
  }

  private func registeredMetadataRefusals(
    bundleID: String, candidatePath: String, context: AuthenticApplicationContext
  ) -> [RelatedOwnershipRefusalEvidence] {
    let registered = registeredByID(bundleID)
    guard registered.complete else {
      return [
        RelatedOwnershipRefusalEvidence(
          candidatePath: candidatePath, bundleID: bundleID,
          reason: .unknownMetadata, ownerPaths: registered.paths, nextStep: "scan-again",
          detail: "registrationUnavailable")
      ]
    }
    return registered.paths.compactMap { path in
      guard !Self.isCachedApplication(path, homeDirectory: homeDirectory) else { return nil }
      do { _ = try DescriptorFileSystem.identity(at: path) } catch FileSystemFailure.systemCall(_, let code)
        where code == ENOENT
      { return nil } catch {
        return RelatedOwnershipRefusalEvidence(
          candidatePath: candidatePath, bundleID: bundleID,
          reason: .unknownMetadata, ownerPaths: [path], nextStep: "inspect-owner-metadata",
          detail: String(describing: error))
      }
      let observation = ApplicationMetadataObservation.read(at: path)
      guard !Self.isCachedApplication(observation.physicalPath, homeDirectory: homeDirectory) else { return nil }
      switch observation.state {
      case .absentInfo:
        context.recordInfoAbsence(observation)
        return nil
      case .identifierless: return nil
      case .declaredID(let id):
        guard foldedAppID(id) == foldedAppID(bundleID) else { return nil }
        return RelatedOwnershipRefusalEvidence(
          candidatePath: candidatePath, bundleID: bundleID,
          reason: .observedLiteralOwner, ownerPaths: [observation.physicalPath], nextStep: "review-observed-owner",
          detail: id)
      case .unknown(let detail):
        return RelatedOwnershipRefusalEvidence(
          candidatePath: candidatePath, bundleID: bundleID,
          reason: .unknownMetadata, ownerPaths: [observation.physicalPath], nextStep: "inspect-owner-metadata",
          detail: detail)
      }
    }
  }

  /// Current refusal evidence for an exact privately bound plan. This is a
  /// read-only display API; returned observations cannot authorize execution.
  public func ownershipRefusalEvidence(for plan: ActionPlan) -> [RelatedOwnershipRefusalEvidence] {
    var evidence: [RelatedOwnershipRefusalEvidence] = []
    for item in plan.items {
      guard let context = planContexts.context(for: plan, scope: contextScope, itemID: item.id) else { continue }
      if let proof = item.installedRelatedProof {
        do {
          try validateContext(context, groups: item.policy == .relatedGroupContainer, bundleIDs: [proof.bundleID])
          try validateInstalled(item, plan: plan, context: context)
        } catch {
          let listing = installedListing()
          let unknown =
            (context.inventory.applicationMetadata.map { ApplicationMetadataObservation.read(at: $0.path) }
            + listing.applicationMetadata).filter {
              if case .unknown = $0.state { return true }
              return false
            }
          evidence += metadataRefusals(
            inventory: context.inventory, bundleID: proof.bundleID,
            candidatePath: item.sourcePath, observations: unknown, fresh: true)
          evidence += registeredMetadataRefusals(
            bundleID: proof.bundleID, candidatePath: item.sourcePath, context: context
          ).filter { $0.reason == .unknownMetadata }
          if error as? RelatedFailure == .ambiguousOwner,
            let app = try? inspectApplication(at: proof.appPath, allowProtected: false),
            let shared = sharedOwnerEvidence(app: app, candidatePath: item.sourcePath, context: context)
          {
            evidence.append(shared)
          }
        }
      } else if let id = item.orphanRelatedProof?.bundleID ?? item.relatedProof?.bundleID {
        do {
          if item.orphanRelatedProof != nil {
            try validateOrphan(item, plan: plan, context: context)
          } else {
            try validate(item, plan: plan, context: context)
          }
        } catch {
          let candidate = RelatedDataCandidate(
            id: item.sourcePath, path: item.sourcePath, classification: .uncertain,
            reason: .incompleteInventory, snapshot: nil, receipt: nil, bundleID: id)
          evidence += absenceRefusalEvidence(candidate: candidate, context: context)
          let listing = currentInstalledListing(context)
          let current =
            context.inventory.applicationMetadata.map { ApplicationMetadataObservation.read(at: $0.path) }
            + listing.applicationMetadata
          evidence += metadataRefusals(
            inventory: context.inventory, bundleID: id, candidatePath: item.sourcePath,
            observations: current, fresh: true)
          evidence += registeredMetadataRefusals(bundleID: id, candidatePath: item.sourcePath, context: context)
        }
      }
    }
    return evidence.reduce(into: []) { result, item in
      if !result.contains(item) { result.append(item) }
    }
  }

  /// The tree-policy gate checks current scope and signed claims. The executor
  /// separately rechecks complete ownership inventory and registered apps.
  func validateScope(_ item: PlanItem, plan: ActionPlan) throws {
    if let proof = item.installedRelatedProof,
      let context = planContexts.context(for: plan, scope: contextScope, itemID: item.id),
      let evidence = context.observedDataEvidence(packagePath: proof.appPath, dataPath: item.sourcePath)
    {
      guard plan.kind == .trash, item.policy == .relatedTrash,
        proof.bundleID == evidence.bundleID, proof.relatedPath == evidence.dataPath,
        proof.snapshotRunID == (item.snapshotRunID ?? plan.snapshotRunID),
        proof.relatedIdentity == item.inventory.first?.identity,
        (try? DescriptorFileSystem.identity(at: item.sourcePath)) == proof.relatedIdentity,
        Self.currentUserOwns(item.sourcePath)
      else { throw RelatedFailure.unsupportedInstalledData }
      try validateDataEvidence(evidence, context: context)
      return
    }
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
      guard let metadata = try? ApplicationPackagePlanning.metadata(at: proof.appPath) else {
        throw RelatedFailure.unsupportedInstalledData
      }
      guard proof.bundleID.caseInsensitiveCompare(LightenIdentity.bundleIdentifier) != .orderedSame,
        proof.snapshotRunID == run, proof.relatedPath == item.sourcePath,
        proof.relatedIdentity == item.inventory.first?.identity,
        (try? DescriptorFileSystem.identity(at: item.sourcePath)) == proof.relatedIdentity,
        metadata.rootIdentity == proof.appIdentity,
        metadata.observation.infoIdentity == proof.infoIdentity,
        metadata.observation.bundleIdentifier == proof.bundleID
      else { throw RelatedFailure.unsupportedInstalledData }
      if location == .groupContainers {
        let app = InstalledApplication(bundleID: proof.bundleID, path: proof.appPath, version: nil)
        let bound = planContexts.context(for: plan, scope: contextScope, itemID: item.id)
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
      guard location != .groupContainers, domain == proof.bundleID, Self.validBundleID(proof.bundleID),
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
    try? ApplicationPackagePlanning.metadata(at: appPath).observation.bundleIdentifier
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
