import CLightenPlatform
import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Display provenance is deliberately separate from native execution authority.
public enum RelatedDataProvenanceKind: String, Sendable, Hashable {
  case bundleIdentifier, teamIdentifier, electron, mozilla, installerReceipt, launchService
  case configuredDirectory, vendorDirectory, liveProcess, executableName, explicitUserChoice
}

public struct RelatedDataProvenance: Sendable {
  public let kind: RelatedDataProvenanceKind
  public let sourcePath: String?
  public let detail: String?

  public init(kind: RelatedDataProvenanceKind, sourcePath: String? = nil, detail: String? = nil) {
    self.kind = kind
    self.sourcePath = sourcePath
    self.detail = detail
  }
}

enum ApplicationOwnedDataEvidence: Sendable {
  case framework(ApplicationFrameworkEvidence)
  case auxiliary(ApplicationAuxiliaryEvidence)

  var packagePath: String {
    switch self {
    case .framework(let value): value.packagePath
    case .auxiliary(let value): value.packagePath
    }
  }
  var bundleID: String {
    switch self {
    case .framework(let value): value.bundleIdentifier
    case .auxiliary(let value): value.bundleID
    }
  }
  var dataPath: String {
    switch self {
    case .framework(let value): value.dataPath
    case .auxiliary(let value): value.dataPath
    }
  }
  var provenance: RelatedDataProvenance {
    switch self {
    case .framework(let value):
      RelatedDataProvenance(
        kind: value.framework == .electron ? .electron : .mozilla,
        sourcePath: value.packagePath, detail: value.productName)
    case .auxiliary(let value): value.provenance
    }
  }
  var matchStrength: RelatedMatchStrength {
    switch self {
    case .framework: .strong
    case .auxiliary(let value): value.matchStrength
    }
  }
  func validate(relocatedPackagePath: String? = nil) throws {
    switch self {
    case .framework(let value):
      if let relocatedPackagePath {
        try value.validate(relocatedPackagePath: relocatedPackagePath)
      } else {
        try value.validate()
      }
    case .auxiliary(let value): try value.validate(relocatedPackagePath: relocatedPackagePath)
    }
  }
}

struct ApplicationAuxiliaryIssue: Sendable {
  let path: String
  let detail: String
  var bundleID: String? = nil
  var provenanceKind: RelatedDataProvenanceKind? = nil
}

struct ApplicationAuxiliaryDiscovery: Sendable {
  var evidence: [ApplicationAuxiliaryEvidence] = []
  var issues: [ApplicationAuxiliaryIssue] = []
}

/// Only native producers in this file can construct the bound observations.
struct ApplicationAuxiliaryEvidence: Sendable {
  let packagePath: String
  let bundleID: String
  let dataPath: String
  let provenance: RelatedDataProvenance
  fileprivate let nodes: [AuxiliaryNode]
  fileprivate let volumeID: UUID
  fileprivate let dataVolumeID: UUID
  fileprivate let receiptSources: [ApplicationPathObservation]
  private let referenceClaim: ApplicationReferenceClaim?

  fileprivate init(
    packagePath: String, bundleID: String, dataPath: String, provenance: RelatedDataProvenance,
    nodes: [AuxiliaryNode], volumeID: UUID, dataVolumeID: UUID, receiptSources: [ApplicationPathObservation],
    referenceClaim: ApplicationReferenceClaim? = nil
  ) {
    self.packagePath = packagePath
    self.bundleID = bundleID
    self.dataPath = dataPath
    self.provenance = provenance
    self.nodes = nodes
    self.volumeID = volumeID
    self.dataVolumeID = dataVolumeID
    self.receiptSources = receiptSources
    self.referenceClaim = referenceClaim
  }

  var matchStrength: RelatedMatchStrength { referenceClaim?.matchStrength ?? .strong }

  fileprivate static func reference(app: InstalledApplication, claim: ApplicationReferenceClaim) throws -> Self {
    try claim.validateBinding(to: app)
    let package = app.linkTarget ?? app.path
    guard let packageVolume = try DescriptorFileSystem.volumeID(at: package),
      let dataVolume = try DescriptorFileSystem.volumeID(at: claim.dataPath)
    else { throw RelatedFailure.incompleteInventory }
    let evidence = Self(
      packagePath: package, bundleID: app.bundleID, dataPath: claim.dataPath,
      provenance: RelatedDataProvenance(kind: claim.kind, sourcePath: claim.sourcePath, detail: claim.ownerBundleID),
      nodes: [], volumeID: packageVolume, dataVolumeID: dataVolume, receiptSources: [], referenceClaim: claim)
    try evidence.validate()
    return evidence
  }

  func validate(relocatedPackagePath: String? = nil) throws {
    try Task.checkCancellation()
    let package = relocatedPackagePath ?? packagePath
    guard try DescriptorFileSystem.volumeID(at: package) == volumeID else { throw RelatedFailure.changedItem }
    guard try DescriptorFileSystem.volumeID(at: dataPath) == dataVolumeID else { throw RelatedFailure.changedItem }
    try referenceClaim?.validate(relocatedPackagePath: relocatedPackagePath)
    for node in nodes {
      let path =
        relocatedPackagePath.flatMap { moved in
          node.path == packagePath
            ? moved
            : node.path.hasPrefix(packagePath + "/") ? moved + node.path.dropFirst(packagePath.count) : nil
        } ?? node.path
      let current = try DescriptorFileSystem.identity(at: path)
      guard
        node.path == packagePath && relocatedPackagePath != nil
          ? node.identity.matchesStableTrashIdentity(current) : node.identity == current
      else { throw RelatedFailure.changedItem }
      if let digest = node.digest {
        guard let data = try SecureMetadataFile.read(path: path, limit: 1024 * 1024, ownerOnly: false),
          AuxiliaryNode.digest(data) == digest
        else { throw RelatedFailure.changedItem }
      }
    }
  }
}

private struct AuxiliaryNode: Sendable {
  let path: String
  let identity: FileIdentity
  let digest: String?

  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func observe(_ path: String, contents: Bool = false) throws -> Self {
    let identity = try DescriptorFileSystem.identity(at: path)
    guard identity.kind == .directory || identity.kind == .regular,
      identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
    else { throw RelatedFailure.unsupportedInstalledData }
    let digest: String?
    if contents {
      guard let data = try SecureMetadataFile.read(path: path, limit: 1024 * 1024, ownerOnly: false) else {
        throw RelatedFailure.changedItem
      }
      digest = Self.digest(data)
    } else {
      digest = nil
    }
    guard try DescriptorFileSystem.identity(at: path) == identity else { throw RelatedFailure.changedItem }
    return Self(path: path, identity: identity, digest: digest)
  }
}

/// Cached parsing is reused only after every original namespace observation
/// has been freshly checked. Selected evidence itself is never reminted.
final class ApplicationDataEvidenceCache: Sendable {
  struct Discovery: Sendable {
    let evidence: [ApplicationOwnedDataEvidence]
    let issues: [ApplicationAuxiliaryIssue]
    let sources: [ApplicationPathObservation]
  }
  private struct Entry: Sendable {
    let observations: [ApplicationPathObservation]
    let discovery: Discovery
    let vendorExclusive: Bool
  }
  private let entries = Mutex<[String: Entry]>([:])
  private let receipts = Mutex<ApplicationInstallerReceipts?>(nil)
  private let live = Mutex<ApplicationLiveDataObservation?>(nil)

  private func observations(_ path: String, home: String, bundleID: String) throws -> [ApplicationPathObservation] {
    let paths = [
      path, path + "/Contents", path + "/Contents/Info.plist", path + "/Info.plist", path + "/Wrapper",
      path + "/Contents/Frameworks", path + "/Contents/Frameworks/Electron Framework.framework",
      path + "/Contents/Resources", path + "/Contents/Resources/app", path + "/Contents/Resources/app/package.json",
      path + "/Contents/Resources/app.asar", path + "/Contents/Resources/application.ini",
      home + "/Library/Preferences/" + bundleID + ".plist",
      home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons",
      home + "/Library/Application Scripts", home + "/Library/Cookies", home + "/Library/Preferences/ByHost",
      home + "/Library/Application Support", home + "/Library/Caches", home + "/Library/Logs",
      "/Library/Application Scripts", "/Library/Cookies", "/Library/Preferences/ByHost",
      "/private/var/db/receipts",
    ]
    return try paths.map { candidate in
      let identity: FileIdentity?
      do { identity = try DescriptorFileSystem.identity(at: candidate) } catch FileSystemFailure.systemCall(_, let code)
        where code == ENOENT || code == ENOTDIR
      { identity = nil }
      return ApplicationPathObservation(path: candidate, identity: identity)
    }
  }

  func liveObservation(
    using read: @Sendable () -> ApplicationLiveDataObservation = { .observe() }
  ) -> ApplicationLiveDataObservation {
    live.withLock { cached in
      if let cached { return cached }
      let observed = read()
      cached = observed
      return observed
    }
  }

  func discover(
    app: InstalledApplication, home: String, vendorExclusive: Bool = false,
    liveData: @Sendable () -> ApplicationLiveDataObservation = { .observe() }
  ) -> Discovery {
    let path = app.linkTarget ?? app.path
    if let cached = entries.withLock({ $0[path] }),
      cached.vendorExclusive == vendorExclusive,
      cached.observations.allSatisfy({ (try? $0.validate()) != nil })
    {
      return cached.discovery
    }
    do {
      let before = try observations(path, home: home, bundleID: app.bundleID)
      let framework = ApplicationFrameworkEvidenceProducer.discover(packagePath: path, homeDirectory: home)
      let installer = receipts.withLock { cached in
        if let cached, cached.namespaceIsCurrent { return cached }
        let observed = ApplicationInstallerReceipts.observe()
        cached = observed
        return observed
      }
      let processes = liveObservation(using: liveData)
      let auxiliary = ApplicationAuxiliaryEvidenceProducer.discover(
        app: app, homeDirectory: home, receipts: installer, live: processes,
        vendorExclusive: vendorExclusive, frameworkDirectories: framework.evidence.map(\.dataPath))
      let reference = ApplicationReferenceEvidenceProducer.discover(app: app, homeDirectory: home)
      var referenceEvidence: [ApplicationAuxiliaryEvidence] = []
      var referenceIssues = reference.issues
      for claim in reference.claims {
        do { referenceEvidence.append(try .reference(app: app, claim: claim)) } catch {
          referenceIssues.append(
            ApplicationAuxiliaryIssue(
              path: claim.dataPath, detail: String(describing: error), bundleID: app.bundleID,
              provenanceKind: claim.kind))
        }
      }
      let sourceObservations =
        framework.evidence.flatMap(\.sourceObservations)
        + auxiliary.evidence.flatMap { evidence in
          evidence.nodes.filter { $0.path != evidence.dataPath }.map {
            ApplicationPathObservation(path: $0.path, identity: $0.identity)
          } + evidence.receiptSources
        } + reference.sources
      let mutableDataParents = Set(["Application Support", "Caches", "Logs"].map { home + "/Library/" + $0 })
      let result = Discovery(
        evidence: framework.evidence.map(ApplicationOwnedDataEvidence.framework)
          + (auxiliary.evidence + referenceEvidence).map(ApplicationOwnedDataEvidence.auxiliary),
        issues: framework.issues.filter { $0.reason != .unsupportedFramework }.map {
          ApplicationAuxiliaryIssue(path: $0.path, detail: String(describing: $0.reason) + ": " + $0.detail)
        } + auxiliary.issues + referenceIssues,
        sources: before.filter { !mutableDataParents.contains($0.path) } + sourceObservations)
      let after = try observations(path, home: home, bundleID: app.bundleID)
      guard before.count == after.count,
        zip(before, after).allSatisfy({ $0.path == $1.path && $0.identity == $1.identity })
      else { throw RelatedFailure.changedItem }
      entries.withLock {
        $0[path] = Entry(
          observations: before + sourceObservations + reference.censusSources,
          discovery: result, vendorExclusive: vendorExclusive)
      }
      return result
    } catch {
      return Discovery(
        evidence: [], issues: [ApplicationAuxiliaryIssue(path: path, detail: String(describing: error))], sources: [])
    }
  }
}

enum ApplicationAuxiliaryEvidenceProducer {
  static func hasVendorDirectory(vendor: String, home: String) -> Bool {
    guard vendor.count > 1, !isGeneralToolDirectory(vendor) else { return false }
    for directory in ["Application Support", "Caches", "Logs"] {
      let parent = home + "/Library/" + directory
      guard let root = try? DescriptorFileSystem.identity(at: parent),
        let names = try? DescriptorFileSystem.children(at: parent, expected: root)
      else { continue }
      for name in names where name.caseInsensitiveCompare(vendor) == .orderedSame {
        let path = parent + "/" + name
        if (try? DescriptorFileSystem.identity(at: path))?.kind == .directory,
          RelatedDataService.currentUserOwns(path), ProtectionPolicy.rule(for: path, homeDirectory: home) == nil
        {
          return true
        }
      }
    }
    return false
  }

  static func liveSharedOwnerPaths(
    dataPath: String, excludingPackage: String, applications: [InstalledApplication], home: String,
    observation: ApplicationLiveDataObservation = .observe()
  ) throws -> [String] {
    guard observation.complete else { throw RelatedFailure.incompleteInventory }
    var owners: Set<String> = []
    for record in observation.records
    where record.path == dataPath || record.path.hasPrefix(dataPath + "/") {
      guard let held = try? DescriptorFileSystem.identity(at: record.path),
        held.device == record.device, held.inode == record.inode
      else { throw RelatedFailure.changedItem }
      var matched = false
      for app in applications {
        let package = app.linkTarget ?? app.path
        guard package != excludingPackage, record.executable.hasPrefix(package + "/"),
          !RelatedDataService.isCachedApplication(package, homeDirectory: home)
        else { continue }
        matched = true
        let metadata = try ApplicationPackagePlanning.metadata(at: package)
        guard metadata.observation.bundleIdentifier == app.bundleID,
          (try DescriptorFileSystem.identity(at: record.executable)).kind == .regular
        else { throw RelatedFailure.changedItem }
        owners.insert(package)
      }
      if !matched {
        let components = record.executable.split(separator: "/")
        guard let outer = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
          throw RelatedFailure.incompleteInventory
        }
        let package = "/" + components[...outer].joined(separator: "/")
        guard package != excludingPackage, !RelatedDataService.isCachedApplication(package, homeDirectory: home)
        else { continue }
        let metadata = ApplicationMetadataObservation.read(at: package)
        guard let root = metadata.root, root.kind == .directory,
          (try DescriptorFileSystem.identity(at: record.executable)).kind == .regular
        else { throw RelatedFailure.incompleteInventory }
        switch metadata.state {
        case .declaredID, .identifierless: owners.insert(package)
        case .absentInfo, .unknown: throw RelatedFailure.incompleteInventory
        }
      }
    }
    return owners.sorted()
  }

  static func discover(
    app: InstalledApplication, homeDirectory: String,
    receipts: ApplicationInstallerReceipts? = nil, live: ApplicationLiveDataObservation? = nil,
    vendorExclusive: Bool = false, frameworkDirectories: [String] = []
  ) -> ApplicationAuxiliaryDiscovery {
    var result = ApplicationAuxiliaryDiscovery()
    guard RelatedDataService.validBundleID(app.bundleID),
      !RelatedDataService.isCachedApplication(app.linkTarget ?? app.path, homeDirectory: homeDirectory),
      let metadata = try? ApplicationPackagePlanning.metadata(at: app.linkTarget ?? app.path),
      metadata.observation.bundleIdentifier == app.bundleID
    else { return result }
    let package = app.linkTarget ?? app.path
    let info = package + "/" + metadata.observation.infoRelativePath
    func add(
      _ path: String, kind: RelatedDataProvenanceKind, source: String? = nil, references: [String] = [],
      sourceContents: Bool = true, receiptSources: [ApplicationPathObservation] = []
    ) {
      do {
        var nodes = try [
          AuxiliaryNode.observe(package), AuxiliaryNode.observe(info, contents: true),
          AuxiliaryNode.observe(path),
        ]
        if let source { nodes.append(try AuxiliaryNode.observe(source, contents: sourceContents)) }
        for reference in references { nodes.append(try AuxiliaryNode.observe(reference)) }
        guard let packageVolume = try DescriptorFileSystem.volumeID(at: package),
          let dataVolume = try DescriptorFileSystem.volumeID(at: path)
        else { throw RelatedFailure.incompleteInventory }
        let evidence = ApplicationAuxiliaryEvidence(
          packagePath: package, bundleID: app.bundleID, dataPath: path,
          provenance: RelatedDataProvenance(kind: kind, sourcePath: source ?? info),
          nodes: nodes, volumeID: packageVolume, dataVolumeID: dataVolume, receiptSources: receiptSources)
        try evidence.validate()
        for source in receiptSources { try source.validate() }
        result.evidence.append(evidence)
      } catch {
        result.issues.append(ApplicationAuxiliaryIssue(path: path, detail: String(describing: error)))
      }
    }
    for library in [homeDirectory + "/Library", "/Library"] {
      for (directory, suffix) in [("Application Scripts", ""), ("Cookies", ".binarycookies")] {
        let path = library + "/" + directory + "/" + app.bundleID + suffix
        if (try? DescriptorFileSystem.identity(at: path)) != nil { add(path, kind: .bundleIdentifier) }
      }
      for directory in ["Caches", "Application Support", "WebKit", "HTTPStorages", "Logs"] where library == "/Library" {
        let path = library + "/" + directory + "/" + app.bundleID
        if (try? DescriptorFileSystem.identity(at: path)) != nil { add(path, kind: .bundleIdentifier) }
      }
      let parent = library + "/Preferences/ByHost"
      if let root = try? DescriptorFileSystem.identity(at: parent),
        let names = try? DescriptorFileSystem.children(at: parent, expected: root)
      {
        for name in names where name.hasPrefix(app.bundleID + ".") && name.hasSuffix(".plist") {
          let uuid = String(name.dropFirst(app.bundleID.count + 1).dropLast(6))
          if UUID(uuidString: uuid) != nil { add(parent + "/" + name, kind: .bundleIdentifier) }
        }
      }
      for directory in ["LaunchAgents", "LaunchDaemons"] {
        let parent = library + "/" + directory
        guard let root = try? DescriptorFileSystem.identity(at: parent),
          let names = try? DescriptorFileSystem.children(at: parent, expected: root)
        else { continue }
        for name in names where name.hasSuffix(".plist") {
          let path = parent + "/" + name
          guard let bytes = try? SecureMetadataFile.read(path: path, limit: 1024 * 1024, ownerOnly: false),
            let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
          else { continue }
          let program =
            (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
            ?? (plist["BundleProgram"] as? String).map { package + "/" + $0 }
          guard let program, program.hasPrefix(package + "/"),
            (try? DescriptorFileSystem.identity(at: program))?.kind == .regular
          else { continue }
          add(path, kind: .launchService, source: path, references: [program])
        }
      }
    }
    let preferences = homeDirectory + "/Library/Preferences/" + app.bundleID + ".plist"
    if let bytes = try? SecureMetadataFile.read(path: preferences, limit: 1024 * 1024, ownerOnly: false),
      let dictionary = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
    {
      func directories(_ values: [String: Any], depth: Int) {
        guard depth < 8 else { return }
        for (key, value) in values {
          let folded = key.lowercased()
          guard !folded.contains("recent"), !folded.contains("documentlist"), !folded.contains("sharedfile") else {
            continue
          }
          if let nested = value as? [String: Any] {
            directories(nested, depth: depth + 1)
            continue
          }
          let path: String?
          if folded.hasSuffix("directoryurl"), let text = value as? String, let url = URL(string: text), url.isFileURL {
            path = url.path
          } else if folded.hasSuffix("directorypath"), let text = value as? String, text.hasPrefix("/") {
            path = text
          } else if folded.hasSuffix("directorybookmark"), let data = value as? Data {
            var stale = false
            let url = try? URL(
              resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
              relativeTo: nil, bookmarkDataIsStale: &stale)
            path = !stale && url?.isFileURL == true ? url?.path : nil
          } else {
            path = nil
          }
          guard let path, (try? DescriptorFileSystem.validatedComponents(path)) != nil,
            (try? DescriptorFileSystem.identity(at: path))?.kind == .directory,
            ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) == nil,
            RelatedDataService.currentUserOwns(path), !ExactInventory(homeDirectory: homeDirectory).isBulkRoot(path),
            !ScanService.isInsidePackage(path)
          else { continue }
          add(path, kind: .configuredDirectory, source: preferences)
        }
      }
      directories(dictionary, depth: 0)
    }
    let vendor = app.bundleID.split(separator: ".").dropFirst().first.map(String.init)
    if let vendor, vendor.count > 1, vendorExclusive, !isGeneralToolDirectory(vendor) {
      for directory in ["Application Support", "Caches", "Logs"] {
        let parent = homeDirectory + "/Library/" + directory
        guard let root = try? DescriptorFileSystem.identity(at: parent),
          let names = try? DescriptorFileSystem.children(at: parent, expected: root)
        else { continue }
        for name in names where name.caseInsensitiveCompare(vendor) == .orderedSame {
          add(parent + "/" + name, kind: .vendorDirectory)
        }
      }
    }
    if let receipts {
      for receipt in receipts.entries(bundleID: app.bundleID) {
        for path in receipt.paths where path != package && !path.hasPrefix(package + "/") {
          guard let identity = try? DescriptorFileSystem.identity(at: path) else { continue }
          guard identity.kind == .directory || identity.kind == .regular else { continue }
          let protected =
            ExactInventory(homeDirectory: homeDirectory).isBulkRoot(path)
            || ProtectionPolicy.rule(for: path, homeDirectory: homeDirectory) != nil
          let issue =
            protected
            ? "receipt-protected-location"
            : identity.kind == .directory
              ? receipts.directoryIssue(path: path, identifier: receipt.identifier, homeDirectory: homeDirectory) : nil
          if let issue {
            result.issues.append(
              ApplicationAuxiliaryIssue(
                path: path, detail: issue, bundleID: app.bundleID, provenanceKind: .installerReceipt))
            continue
          }
          add(
            path, kind: .installerReceipt, source: receipt.sourcePath, references: [receipt.bomPath],
            sourceContents: receipt.sourceContents,
            receiptSources: receipt.sources + (identity.kind == .directory ? receipts.directorySources : []))
        }
      }
      result.issues += receipts.issues(bundleID: app.bundleID).map { original in
        var issue = original
        issue.bundleID = app.bundleID
        issue.provenanceKind = .installerReceipt
        return issue
      }
    }
    if let live {
      for record in live.records where record.executable.hasPrefix(package + "/") {
        guard let held = try? DescriptorFileSystem.identity(at: record.path),
          held.device == record.device, held.inode == record.inode,
          let dataPath = liveDirectory(
            record.path, isCWD: record.isCWD, home: homeDirectory, frameworkDirectories: frameworkDirectories),
          dataPath != package, !dataPath.hasPrefix(package + "/"),
          (try? DescriptorFileSystem.identity(at: record.executable))?.kind == .regular
        else { continue }
        if live.complete {
          add(dataPath, kind: .liveProcess, references: [record.executable, record.path])
        } else {
          result.issues.append(
            ApplicationAuxiliaryIssue(
              path: dataPath, detail: "live-process-census-incomplete", bundleID: app.bundleID,
              provenanceKind: .liveProcess))
        }
      }
    }
    return result
  }

  static func isGeneralToolDirectory(_ name: String) -> Bool {
    let tools: Set<String> = [
      "electron", "ms-playwright", "node-gyp", "homebrew", "pip", "cypress", "puppeteer",
      "npm", "yarn", "pnpm", "node", "python", "cargo", "go", "gradle", "maven",
    ]
    return tools.contains(name.lowercased(with: Locale(identifier: "en_US_POSIX")))
  }

  private static func liveDirectory(
    _ path: String, isCWD: Bool, home: String, frameworkDirectories: [String]
  ) -> String? {
    guard (try? DescriptorFileSystem.validatedComponents(path)) != nil else { return nil }
    let library = home + "/Library/"
    guard path.hasPrefix(library) else { return nil }
    var candidate: String?
    for directory in [
      "Application Support", "Caches", "Containers", "Group Containers", "Preferences", "Logs",
      "Saved Application State", "WebKit", "HTTPStorages", "Cookies",
    ] {
      let parent = home + "/Library/" + directory
      if path.hasPrefix(parent + "/") {
        let name = path.dropFirst(parent.count + 1).split(separator: "/").first.map(String.init)
        if let name {
          candidate = parent + "/" + name
          if directory == "Preferences", name == "ByHost" { candidate = isCWD ? nil : path }
        }
      }
    }
    if candidate == nil {
      candidate = frameworkDirectories.first {
        $0.hasPrefix(library) && (path == $0 || path.hasPrefix($0 + "/"))
      }
    }
    guard let candidate, let identity = try? DescriptorFileSystem.identity(at: candidate),
      identity.kind == .directory || identity.kind == .regular,
      RelatedDataService.currentUserOwns(candidate), !ScanService.isInsidePackage(candidate),
      !ExactInventory(homeDirectory: home).isBulkRoot(candidate),
      ProtectionPolicy.rule(for: candidate, homeDirectory: home) == nil
    else { return nil }
    return candidate
  }
}

struct ApplicationLiveDataObservation: Sendable {
  struct Record: Sendable {
    let pid: Int32
    let executable: String
    let path: String
    let isCWD: Bool
    let device: UInt64
    let inode: UInt64
  }
  let records: [Record]
  let complete: Bool
  var report: ApplicationLiveDataCensusReport? = nil

  static func observe(
    maximumBytes: Int = 256 * 1024 * 1024, timeoutMilliseconds: UInt32 = 3000,
    read: (Int, UInt32) -> Self = readNative,
    uptime: () -> UInt64 = { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }
  ) -> Self {
    let started = uptime()
    let deadline = started.addingReportingOverflow(UInt64(timeoutMilliseconds))
    func timed(_ observation: Self, now: UInt64, extraFlags: UInt32 = 0) -> Self {
      let original = observation.report
      let flags = (original?.failureFlags ?? UInt32(LIGHTEN_CENSUS_UNAVAILABLE)) | extraFlags
      let complete = observation.complete && flags == 0
      return Self(
        records: observation.records, complete: complete,
        report: ApplicationLiveDataCensusReport(
          complete: complete, recordCount: observation.records.count,
          processesInspected: original?.processesInspected ?? 0,
          applicationProcesses: original?.applicationProcesses ?? 0,
          descriptorsInspected: original?.descriptorsInspected ?? 0,
          failureFlags: flags, elapsedMilliseconds: now >= started ? now - started : 0))
    }
    var observed = Self(records: [], complete: false)
    for _ in 0..<3 {
      let before = uptime()
      guard !Task.isCancelled else { return timed(observed, now: before) }
      guard !deadline.overflow, timeoutMilliseconds > 0, timeoutMilliseconds <= 10_000,
        before >= started, before < deadline.partialValue
      else { return timed(observed, now: before, extraFlags: UInt32(LIGHTEN_CENSUS_TIME_LIMIT)) }
      let remaining = UInt32(deadline.partialValue - before)
      // Each retry replaces a whole observation. Partial records never combine
      // into evidence that another live owner is absent.
      observed = read(maximumBytes, remaining)
      let after = uptime()
      guard after >= before, after < deadline.partialValue else {
        return timed(observed, now: after, extraFlags: UInt32(LIGHTEN_CENSUS_TIME_LIMIT))
      }
      if observed.complete || observed.report?.failureFlags != UInt32(LIGHTEN_CENSUS_PROCESS_CHANGED) {
        return timed(observed, now: after)
      }
    }
    return timed(observed, now: uptime())
  }

  private static func readNative(maximumBytes: Int, timeoutMilliseconds: UInt32) -> Self {
    var values: UnsafeMutablePointer<LightenApplicationDataPath>?
    var count: UInt32 = 0
    var census = LightenApplicationDataCensus()
    let status = lighten_copy_application_data_paths(
      max(0, maximumBytes), timeoutMilliseconds, &values, &count, &census)
    defer { lighten_free_application_data_paths(values) }
    let native = UnsafeBufferPointer(start: values, count: values == nil ? 0 : Int(count))
    let records = native.compactMap { value -> Record? in
      var value = value
      let executable = withUnsafePointer(to: &value.executable_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(validatingCString: $0) }
      }
      let path = withUnsafePointer(to: &value.data_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(validatingCString: $0) }
      }
      guard value.uid == geteuid(), value.pid > 0, let executable, let path else { return nil }
      return Record(
        pid: value.pid, executable: executable, path: path, isCWD: value.is_cwd != 0,
        device: value.data_device, inode: value.data_inode)
    }
    let complete = status == 0 && records.count == Int(count)
    let report = ApplicationLiveDataCensusReport(
      complete: complete, recordCount: Int(count), processesInspected: Int(census.processes_inspected),
      applicationProcesses: Int(census.application_processes), descriptorsInspected: census.descriptors_inspected,
      failureFlags: census.failure_flags | (records.count == Int(count) ? 0 : UInt32(LIGHTEN_CENSUS_UNAVAILABLE)),
      elapsedMilliseconds: census.elapsed_milliseconds)
    return Self(records: records, complete: complete, report: report)
  }
}

/// Read-only metrics from one native current-user application fd/cwd census.
/// An incomplete report never establishes that selected data has no other user.
public struct ApplicationLiveDataCensusReport: Codable, Sendable {
  public let complete: Bool
  public let recordCount: Int
  public let processesInspected: Int
  public let applicationProcesses: Int
  public let descriptorsInspected: UInt64
  public let failureFlags: UInt32
  public let elapsedMilliseconds: UInt64

  public var timedOut: Bool { failureFlags & 4 != 0 }
  public var incompleteReasons: [String] {
    [(UInt32(1), "process-unavailable"), (2, "memory-limit"), (4, "time-limit"), (8, "process-changed")]
      .compactMap { failureFlags & $0.0 == 0 ? nil : $0.1 }
  }
}

public enum ApplicationLiveDataCensus {
  public static func observe() -> ApplicationLiveDataCensusReport {
    ApplicationLiveDataObservation.observe().report!
  }
}

/// One scan reuses exact receipt parsing and a lazily built, bounded cross-package census.
final class ApplicationInstallerReceipts: Sendable {
  typealias Query = @Sendable ([String], TimeInterval, Int) -> Data?
  struct Entry: Sendable {
    let identifier: String
    let paths: [String]
    let plistPath: String
    let bomPath: String
    let sourcePath: String
    let sourceContents: Bool
    let sources: [ApplicationPathObservation]
  }
  private struct Record: Sendable {
    let entry: Entry?
    let issue: ApplicationAuxiliaryIssue?
    let sources: [ApplicationPathObservation]
  }
  private struct Census: Sendable {
    var owners: [String: Set<String>] = [:]
    var sources: [ApplicationPathObservation] = []
    var complete = true
  }
  private struct Budget: Sendable {
    let deadline: TimeInterval
    var remainingBytes: Int
    var remainingPathBytes: Int
  }
  private let identifiers: [String]
  private let complete: Bool
  private let receiptDirectory: String
  private let namespace: ApplicationPathObservation
  private let standardRoots = Mutex<[String: [FileIdentity]]>([:])
  private let runQuery: Query
  private let records = Mutex<[String: Record]>([:])
  private let census = Mutex<Census?>(nil)
  private let budget: Mutex<Budget>

  init(
    identifiers: [String], complete: Bool, receiptDirectory: String = "/private/var/db/receipts",
    timeout: TimeInterval = 20, maximumBytes: Int = 128 * 1024 * 1024,
    query: @escaping Query = { ApplicationReceiptQuery.run($0, timeout: $1, maximumBytes: $2) }
  ) {
    let valid = identifiers.filter(Self.validIdentifier)
    self.identifiers = Array(Set(valid.prefix(100_000))).sorted()
    self.complete = complete && valid.count == identifiers.count && valid.count <= 100_000
    self.receiptDirectory = receiptDirectory
    self.namespace = ApplicationPathObservation(
      path: receiptDirectory, identity: try? DescriptorFileSystem.identity(at: receiptDirectory))
    self.runQuery = query
    self.budget = Mutex(
      Budget(
        deadline: ProcessInfo.processInfo.systemUptime + max(0, timeout), remainingBytes: max(0, maximumBytes),
        remainingPathBytes: 128 * 1024 * 1024))
  }

  static func observe() -> ApplicationInstallerReceipts {
    guard let output = ApplicationReceiptQuery.run(["--pkgs"]),
      let text = String(data: output, encoding: .utf8)
    else { return ApplicationInstallerReceipts(identifiers: [], complete: false) }
    return ApplicationInstallerReceipts(identifiers: text.split(separator: "\n").map(String.init), complete: true)
  }

  var namespaceIsCurrent: Bool { (try? namespace.validate()) != nil }
  var directorySources: [ApplicationPathObservation] { directoryCensus().sources }
  func entries(bundleID: String) -> [Entry] { matching(bundleID).compactMap { record($0).entry } }
  func issues(bundleID: String) -> [ApplicationAuxiliaryIssue] {
    var issues = matching(bundleID).compactMap { record($0).issue }
    if !complete {
      issues.append(ApplicationAuxiliaryIssue(path: receiptDirectory, detail: "receipt-enumeration-unavailable"))
    }
    return issues
  }

  func directoryIssue(path: String, identifier: String, homeDirectory: String) -> String? {
    let sharedRoots =
      [
        "/", "/Applications", homeDirectory + "/Applications", "/usr/local", "/usr/local/bin", "/usr/local/lib",
        "/usr/local/share", "/opt/homebrew", "/opt/homebrew/bin",
      ]
      + ["/Library", homeDirectory + "/Library"].flatMap { library in
        [
          "", "/Application Support", "/LaunchAgents", "/LaunchDaemons", "/Caches", "/Logs", "/Preferences", "/Fonts",
          "/Frameworks", "/Application Scripts", "/Containers", "/Group Containers",
        ].map { library + $0 }
      }
    let locale = Locale(identifier: "en_US_POSIX")
    if sharedRoots.contains(where: { $0.lowercased(with: locale) == path.lowercased(with: locale) }) {
      return "receipt-shared-standard-directory"
    }
    let roots = standardRoots.withLock { cached in
      if let roots = cached[homeDirectory] { return roots }
      let roots = sharedRoots.compactMap { try? DescriptorFileSystem.identity(at: $0) }
      cached[homeDirectory] = roots
      return roots
    }
    if let selected = try? DescriptorFileSystem.identity(at: path),
      roots.contains(where: {
        $0.device == selected.device && $0.inode == selected.inode && $0.kind == selected.kind
      })
    {
      return "receipt-shared-standard-directory"
    }
    let observed = directoryCensus()
    guard observed.complete else { return "receipt-cross-package-census-incomplete" }
    guard observed.owners[path] == Set([identifier]) else { return "receipt-directory-shared-packages" }
    return nil
  }

  private func matching(_ bundleID: String) -> [String] {
    identifiers.filter { $0 == bundleID || $0.hasPrefix(bundleID + ".") }
  }
  private static func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1024 && value != "." && value != ".."
      && !value.contains("/") && !value.unicodeScalars.contains { $0.value < 33 || $0.value == 127 }
  }
  private func query(_ arguments: [String]) -> Data? {
    budget.withLock { state in
      let remaining = state.deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0, state.remainingBytes > 0, !Task.isCancelled else { return nil }
      guard let data = runQuery(arguments, min(3, remaining), min(16 * 1024 * 1024, state.remainingBytes)),
        data.count <= state.remainingBytes
      else { return nil }
      state.remainingBytes -= data.count
      return data
    }
  }
  private var withinBudget: Bool {
    budget.withLock { $0.deadline > ProcessInfo.processInfo.systemUptime && $0.remainingBytes > 0 } && !Task.isCancelled
  }

  private func record(_ identifier: String) -> Record {
    records.withLock { cached in
      let plist = receiptDirectory + "/" + identifier + ".plist"
      let bom = receiptDirectory + "/" + identifier + ".bom"
      do {
        if let record = cached[identifier] {
          for source in record.sources { try source.validate() }
          return record
        }
        guard withinBudget, Self.validIdentifier(identifier) else { throw RelatedFailure.incompleteInventory }
        try namespace.validate()
        let originalBOM = ApplicationPathObservation(path: bom, identity: try DescriptorFileSystem.identity(at: bom))
        guard originalBOM.identity?.kind == .regular else { throw RelatedFailure.incompleteInventory }
        let originalPlist = ApplicationPathObservation(
          path: plist, identity: try? DescriptorFileSystem.identity(at: plist))
        var before = [namespace, originalBOM, originalPlist]
        let bytes = try? SecureMetadataFile.read(path: plist, limit: 1024 * 1024, ownerOnly: false)
        let prefix: String
        let source: String
        let sourceContents: Bool
        if let bytes {
          try originalPlist.validate()
          let dictionary = try Self.dictionary(bytes)
          guard dictionary["PackageIdentifier"] as? String == identifier,
            let nativePrefix = dictionary["InstallPrefixPath"] as? String
          else { throw RelatedFailure.invalidReceipt }
          prefix = try Self.absolutePrefix(nativePrefix)
          source = plist
          sourceContents = true
        } else {
          guard let data = query(["--pkg-info-plist", identifier]) else { throw RelatedFailure.incompleteInventory }
          prefix = try Self.fallbackPrefix(data, identifier: identifier)
          source = bom
          sourceContents = false
        }
        guard try DescriptorFileSystem.volumeID(at: prefix) != nil
        else { throw RelatedFailure.incompleteInventory }
        before.append(ApplicationPathObservation(path: prefix, identity: try DescriptorFileSystem.identity(at: prefix)))
        for source in before { try source.validate() }
        guard let output = query(["--files", identifier]), let text = String(data: output, encoding: .utf8)
        else { throw RelatedFailure.incompleteInventory }
        let lines = text.split(separator: "\n")
        guard lines.count <= 100_000 else { throw RelatedFailure.incompleteInventory }
        let paths = try lines.compactMap { line -> String? in
          guard withinBudget else { throw RelatedFailure.incompleteInventory }
          let relative = String(line)
          if relative == "." { return nil }
          guard !relative.hasPrefix("/"), !relative.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
          else { throw RelatedFailure.invalidReceipt }
          let stripped = relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative
          let path = (prefix == "/" ? "" : prefix) + "/" + stripped
          _ = try DescriptorFileSystem.validatedComponents(path)
          guard
            budget.withLock({ state in
              let cost = path.utf8.count + 128
              guard cost <= state.remainingPathBytes else { return false }
              state.remainingPathBytes -= cost
              return true
            })
          else { throw RelatedFailure.incompleteInventory }
          return path
        }
        for source in before { try source.validate() }
        let result = Record(
          entry: Entry(
            identifier: identifier, paths: paths, plistPath: plist, bomPath: bom, sourcePath: source,
            sourceContents: sourceContents, sources: before), issue: nil, sources: before)
        cached[identifier] = result
        return result
      } catch {
        let result = Record(
          entry: nil,
          issue: ApplicationAuxiliaryIssue(
            path: plist, detail: "receipt-install-prefix-or-files-unproven: " + String(describing: error)), sources: [])
        cached[identifier] = result
        return result
      }
    }
  }

  static func fallbackPrefix(_ bytes: Data, identifier: String) throws -> String {
    let dictionary = try dictionary(bytes)
    guard dictionary["pkgid"] as? String == identifier,
      dictionary["PackageIdentifier"] == nil || dictionary["PackageIdentifier"] as? String == identifier,
      let volume = dictionary["volume"] as? String,
      let location = dictionary["install-location"] as? String, !location.isEmpty
    else { throw RelatedFailure.invalidReceipt }
    let root = try absolutePrefix(volume)
    let suffix = location == "/" ? "" : location.hasPrefix("/") ? String(location.dropFirst()) : location
    let prefix = suffix.isEmpty ? root : (root == "/" ? "" : root) + "/" + suffix
    let valid = try absolutePrefix(prefix)
    if let native = dictionary["InstallPrefixPath"] {
      guard let native = native as? String, try absolutePrefix(native) == valid else {
        throw RelatedFailure.invalidReceipt
      }
    }
    return valid
  }
  private static func dictionary(_ bytes: Data) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
      throw RelatedFailure.invalidReceipt
    }
    return value
  }
  private static func absolutePrefix(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
      throw RelatedFailure.invalidReceipt
    }
    if path != "/" {
      do { _ = try DescriptorFileSystem.validatedComponents(path) } catch { throw RelatedFailure.invalidReceipt }
    }
    return path
  }

  private func directoryCensus() -> Census {
    census.withLock { cached in
      if let cached { return cached }
      var result = Census(complete: complete && namespaceIsCurrent)
      var bytes = 0
      var observations: [String: ApplicationPathObservation] = [:]
      observations[namespace.path] = namespace
      for identifier in identifiers {
        guard withinBudget else {
          result.complete = false
          break
        }
        let observed = record(identifier)
        guard let entry = observed.entry else {
          result.complete = false
          continue
        }
        for source in observed.sources { observations[source.path] = source }
        for path in entry.paths {
          guard withinBudget else {
            result.complete = false
            break
          }
          var parent = path
          while parent != "/" {
            if !result.owners[parent, default: []].contains(identifier) {
              bytes += parent.utf8.count + identifier.utf8.count + 128
              guard bytes <= 128 * 1024 * 1024 else {
                result.complete = false
                break
              }
              result.owners[parent, default: []].insert(identifier)
            }
            parent = (parent as NSString).deletingLastPathComponent
          }
          if !result.complete && bytes > 128 * 1024 * 1024 { break }
        }
        if bytes > 128 * 1024 * 1024 { break }
      }
      result.sources = observations.values.sorted { $0.path < $1.path }
      if result.complete {
        for source in result.sources {
          guard withinBudget, (try? source.validate()) != nil else {
            result.complete = false
            break
          }
        }
      }
      cached = result
      return result
    }
  }
}

private enum ApplicationReceiptQuery {
  static func run(_ arguments: [String], timeout: TimeInterval = 3, maximumBytes: Int = 16 * 1024 * 1024) -> Data? {
    guard
      arguments == ["--pkgs"]
        || arguments.count == 2 && ["--files", "--pkg-info-plist"].contains(arguments[0])
          && !arguments[1].isEmpty && !arguments[1].contains("/")
          && !arguments[1].unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 })
    else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    process.arguments = arguments
    process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let fd = pipe.fileHandleForReading.fileDescriptor
    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { return nil }
    do { try process.run() } catch { return nil }
    try? pipe.fileHandleForWriting.close()
    defer {
      if process.isRunning {
        process.terminate()
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      }
      try? pipe.fileHandleForReading.close()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + max(0, min(3, timeout))
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
      let count = read(fd, &buffer, buffer.count)
      if count > 0 {
        guard output.count + count <= max(0, min(16 * 1024 * 1024, maximumBytes)) else { return nil }
        output.append(contentsOf: buffer.prefix(count))
      } else if count == 0 {
        if process.isRunning {
          usleep(1000)
          continue
        }
        return process.terminationStatus == 0 ? output : nil
      } else if errno != EAGAIN && errno != EINTR {
        return nil
      } else {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        _ = poll(&descriptor, 1, 25)
      }
    }
    return nil
  }
}

/// An explicit user selection authorizes Space semantics, never an ownership
/// claim. Its original plan and item remain private and are checked at every
/// preparation and final mutation window.
enum ApplicationExplicitSelections {
  private struct Binding: Sendable {
    let plan: ActionPlan
    let items: [UUID: PlanItem]
    let validate: @Sendable (PlanItem) throws -> Void
  }
  private struct State: Sendable {
    var bindings: [UUID: Binding] = [:]
    var knownItems: Set<UUID> = []
    var order: [UUID] = []
  }
  private static let state = Mutex(State())

  static func containsBoundSelection(_ item: PlanItem, plan: ActionPlan) -> Bool {
    state.withLock { state in
      guard let binding = state.bindings[plan.id], binding.plan == plan else { return false }
      return binding.items[item.id] == item && plan.items.contains(item)
    }
  }

  static func bind(
    _ plan: ActionPlan, items: [PlanItem], validate: @escaping @Sendable (PlanItem) throws -> Void
  ) throws {
    guard !items.isEmpty else { return }
    guard items.allSatisfy({ plan.items.contains($0) }), Set(items.map(\.id)).count == items.count else {
      throw RelatedFailure.changedItem
    }
    try state.withLock { state in
      guard state.knownItems.count + items.count <= 10_000 else {
        throw PlanRejection(.unavailable, path: items[0].sourcePath, ruleID: "manual-selection-capacity: review again")
      }
      state.bindings[plan.id] = Binding(
        plan: plan, items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }), validate: validate)
      state.knownItems.formUnion(items.map(\.id))
      state.order.append(plan.id)
      while state.order.count > 64 { state.bindings.removeValue(forKey: state.order.removeFirst()) }
    }
  }

  static func validate(_ item: PlanItem, plan: ActionPlan) throws {
    let binding = try state.withLock { state -> Binding? in
      guard state.knownItems.contains(item.id) || state.bindings[plan.id] != nil else { return nil }
      guard let binding = state.bindings[plan.id], binding.plan == plan else {
        throw RelatedFailure.incompleteInventory
      }
      guard let original = binding.items[item.id] else {
        if plan.items.contains(item) { return nil }
        throw RelatedFailure.changedItem
      }
      guard plan.items.contains(item), plan.kind == .trash, item.policy == .spaceTrash, item.id == original.id,
        item.sourcePath == original.sourcePath, item.volumeID == original.volumeID,
        item.inventory == original.inventory, item.snapshotRunID == original.snapshotRunID,
        item.installedRelatedProof == nil, item.relatedProof == nil, item.orphanRelatedProof == nil,
        item.catalogProof == nil, item.duplicateProof == nil
      else { throw RelatedFailure.changedItem }
      return binding
    }
    if let binding { try binding.validate(item) }
  }

  static func refuseWithoutPlan(_ item: PlanItem) throws {
    if state.withLock({ $0.knownItems.contains(item.id) }) { throw RelatedFailure.incompleteInventory }
  }
}
