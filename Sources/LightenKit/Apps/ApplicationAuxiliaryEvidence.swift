import CLightenPlatform
import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Display provenance is deliberately separate from native execution authority.
public enum RelatedDataProvenanceKind: String, Sendable {
  case bundleIdentifier, teamIdentifier, electron, mozilla, installerReceipt, launchService
  case configuredDirectory, vendorDirectory, liveProcess, explicitUserChoice
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

  func validate(relocatedPackagePath: String? = nil) throws {
    try Task.checkCancellation()
    let package = relocatedPackagePath ?? packagePath
    guard try DescriptorFileSystem.volumeID(at: package) == volumeID else { throw RelatedFailure.changedItem }
    guard try DescriptorFileSystem.volumeID(at: dataPath) == dataVolumeID else { throw RelatedFailure.changedItem }
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

  func discover(app: InstalledApplication, home: String) -> Discovery {
    let path = app.linkTarget ?? app.path
    if let cached = entries.withLock({ $0[path] }),
      cached.observations.allSatisfy({ (try? $0.validate()) != nil })
    {
      return cached.discovery
    }
    do {
      let before = try observations(path, home: home, bundleID: app.bundleID)
      let framework = ApplicationFrameworkEvidenceProducer.discover(packagePath: path, homeDirectory: home)
      let installer = receipts.withLock { cached in
        if let cached { return cached }
        let observed = ApplicationInstallerReceipts.observe()
        cached = observed
        return observed
      }
      let processes = live.withLock { cached in
        if let cached { return cached }
        let observed = ApplicationLiveDataObservation.observe()
        cached = observed
        return observed
      }
      let auxiliary = ApplicationAuxiliaryEvidenceProducer.discover(
        app: app, homeDirectory: home, receipts: installer, live: processes)
      let sourceObservations =
        framework.evidence.flatMap(\.sourceObservations)
        + auxiliary.evidence.flatMap { evidence in
          evidence.nodes.filter { $0.path != evidence.dataPath }.map {
            ApplicationPathObservation(path: $0.path, identity: $0.identity)
          }
        }
      let mutableDataParents = Set(["Application Support", "Caches", "Logs"].map { home + "/Library/" + $0 })
      let result = Discovery(
        evidence: framework.evidence.map(ApplicationOwnedDataEvidence.framework)
          + auxiliary.evidence.map(ApplicationOwnedDataEvidence.auxiliary),
        issues: framework.issues.filter { $0.reason != .unsupportedFramework }.map {
          ApplicationAuxiliaryIssue(path: $0.path, detail: String(describing: $0.reason) + ": " + $0.detail)
        } + auxiliary.issues,
        sources: before.filter { !mutableDataParents.contains($0.path) } + sourceObservations)
      let after = try observations(path, home: home, bundleID: app.bundleID)
      guard before.count == after.count,
        zip(before, after).allSatisfy({ $0.path == $1.path && $0.identity == $1.identity })
      else { throw RelatedFailure.changedItem }
      entries.withLock { $0[path] = Entry(observations: before + sourceObservations, discovery: result) }
      return result
    } catch {
      return Discovery(
        evidence: [], issues: [ApplicationAuxiliaryIssue(path: path, detail: String(describing: error))], sources: [])
    }
  }
}

enum ApplicationAuxiliaryEvidenceProducer {
  static func liveSharedOwnerPaths(
    dataPath: String, excludingPackage: String, applications: [InstalledApplication], home: String,
    observation: ApplicationLiveDataObservation = .observe()
  ) throws -> [String] {
    var owners: Set<String> = []
    for record in observation.records
    where record.path == dataPath || record.path.hasPrefix(dataPath + "/") {
      guard let held = try? DescriptorFileSystem.identity(at: record.path),
        held.device == record.device, held.inode == record.inode
      else { throw RelatedFailure.changedItem }
      for app in applications {
        let package = app.linkTarget ?? app.path
        guard package != excludingPackage, record.executable.hasPrefix(package + "/"),
          !RelatedDataService.isCachedApplication(package, homeDirectory: home)
        else { continue }
        let metadata = try ApplicationPackagePlanning.metadata(at: package)
        guard metadata.observation.bundleIdentifier == app.bundleID,
          (try DescriptorFileSystem.identity(at: record.executable)).kind == .regular
        else { throw RelatedFailure.changedItem }
        owners.insert(package)
      }
    }
    return owners.sorted()
  }

  static func discover(
    app: InstalledApplication, homeDirectory: String,
    receipts: ApplicationInstallerReceipts? = nil, live: ApplicationLiveDataObservation? = nil
  ) -> ApplicationAuxiliaryDiscovery {
    var result = ApplicationAuxiliaryDiscovery()
    guard RelatedDataService.validBundleID(app.bundleID),
      !RelatedDataService.isCachedApplication(app.linkTarget ?? app.path, homeDirectory: homeDirectory),
      let metadata = try? ApplicationPackagePlanning.metadata(at: app.linkTarget ?? app.path),
      metadata.observation.bundleIdentifier == app.bundleID
    else { return result }
    let package = app.linkTarget ?? app.path
    let info = package + "/" + metadata.observation.infoRelativePath
    func add(_ path: String, kind: RelatedDataProvenanceKind, source: String? = nil, references: [String] = []) {
      do {
        var nodes = try [
          AuxiliaryNode.observe(package), AuxiliaryNode.observe(info, contents: true),
          AuxiliaryNode.observe(path),
        ]
        if let source { nodes.append(try AuxiliaryNode.observe(source, contents: true)) }
        for reference in references { nodes.append(try AuxiliaryNode.observe(reference)) }
        guard let packageVolume = try DescriptorFileSystem.volumeID(at: package),
          let dataVolume = try DescriptorFileSystem.volumeID(at: path)
        else { throw RelatedFailure.incompleteInventory }
        let evidence = ApplicationAuxiliaryEvidence(
          packagePath: package, bundleID: app.bundleID, dataPath: path,
          provenance: RelatedDataProvenance(kind: kind, sourcePath: source ?? info),
          nodes: nodes, volumeID: packageVolume, dataVolumeID: dataVolume)
        try evidence.validate()
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
    if let vendor, vendor.count > 1 {
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
          // Directory receipts need an exclusive cross-package census. Until
          // that proof exists, retain the observation without any authority.
          if identity.kind == .directory {
            result.issues.append(
              ApplicationAuxiliaryIssue(
                path: path, detail: "receipt-directory-ownership-unproven", bundleID: app.bundleID,
                provenanceKind: .installerReceipt))
            continue
          }
          guard identity.kind == .regular else { continue }
          add(path, kind: .installerReceipt, source: receipt.plistPath, references: [receipt.bomPath])
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
          let dataPath = liveDirectory(record.path, isCWD: record.isCWD, home: homeDirectory),
          dataPath != package, !dataPath.hasPrefix(package + "/"),
          (try? DescriptorFileSystem.identity(at: record.executable))?.kind == .regular
        else { continue }
        if live.complete {
          add(dataPath, kind: .liveProcess, references: [record.executable, record.path])
        } else {
          result.issues.append(ApplicationAuxiliaryIssue(path: dataPath, detail: "live-process-census-incomplete"))
        }
      }
    }
    return result
  }

  private static func liveDirectory(_ path: String, isCWD: Bool, home: String) -> String? {
    guard (try? DescriptorFileSystem.validatedComponents(path)) != nil else { return nil }
    var candidate = isCWD ? path : (path as NSString).deletingLastPathComponent
    for directory in ["Application Support", "Caches", "Logs", "WebKit", "HTTPStorages"] {
      let parent = home + "/Library/" + directory
      if path.hasPrefix(parent + "/") {
        let name = path.dropFirst(parent.count + 1).split(separator: "/").first.map(String.init)
        if let name { candidate = parent + "/" + name }
      }
    }
    guard (try? DescriptorFileSystem.identity(at: candidate))?.kind == .directory,
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

  static func observe() -> Self {
    var values = [LightenApplicationDataPath](repeating: LightenApplicationDataPath(), count: 4096)
    var count: Int32 = 0
    let status = values.withUnsafeMutableBufferPointer {
      lighten_read_application_data_paths($0.baseAddress, Int32($0.count), &count)
    }
    let records = values.prefix(max(0, min(Int(count), values.count))).compactMap { value -> Record? in
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
    return Self(records: records, complete: status == 0)
  }
}

/// The allowed pkgutil queries return leads. Each entry additionally requires
/// a native receipt with its exact ID and absolute installation prefix.
final class ApplicationInstallerReceipts: Sendable {
  struct Entry: Sendable {
    let paths: [String]
    let plistPath: String
    let bomPath: String
  }
  private struct Result: Sendable {
    let entries: [Entry]
    let issues: [ApplicationAuxiliaryIssue]
  }
  private let identifiers: [String]
  private let complete: Bool
  private let cache = Mutex<[String: Result]>([:])

  private init(identifiers: [String], complete: Bool) {
    self.identifiers = identifiers
    self.complete = complete
  }

  static func observe() -> ApplicationInstallerReceipts {
    guard let output = ApplicationReceiptQuery.run(["--pkgs"]),
      let text = String(data: output, encoding: .utf8)
    else { return ApplicationInstallerReceipts(identifiers: [], complete: false) }
    let ids = text.split(separator: "\n").map(String.init)
    return ApplicationInstallerReceipts(identifiers: ids, complete: ids.count <= 100_000)
  }

  func entries(bundleID: String) -> [Entry] { result(bundleID).entries }
  func issues(bundleID: String) -> [ApplicationAuxiliaryIssue] { result(bundleID).issues }

  private func result(_ bundleID: String) -> Result {
    if let cached = cache.withLock({ $0[bundleID] }) { return cached }
    var entries: [Entry] = []
    var issues: [ApplicationAuxiliaryIssue] = []
    if !complete {
      issues.append(ApplicationAuxiliaryIssue(path: "/var/db/receipts", detail: "receipt-enumeration-unavailable"))
    }
    for identifier in identifiers where identifier == bundleID || identifier.hasPrefix(bundleID + ".") {
      let plist = "/private/var/db/receipts/" + identifier + ".plist"
      let bom = "/private/var/db/receipts/" + identifier + ".bom"
      do {
        guard !identifier.contains("/"),
          let bytes = try SecureMetadataFile.read(path: plist, limit: 1024 * 1024, ownerOnly: false),
          let dictionary = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
          dictionary["PackageIdentifier"] as? String == identifier,
          let prefix = dictionary["InstallPrefixPath"] as? String,
          prefix.hasPrefix("/"), (try? DescriptorFileSystem.validatedComponents(prefix)) != nil,
          (try DescriptorFileSystem.identity(at: bom)).kind == .regular,
          let output = ApplicationReceiptQuery.run(["--files", identifier]),
          let text = String(data: output, encoding: .utf8)
        else { throw RelatedFailure.incompleteInventory }
        let paths = try text.split(separator: "\n").compactMap { line -> String? in
          let relative = String(line)
          guard relative != "." else { return nil }
          guard !relative.hasPrefix("/"), !relative.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw RelatedFailure.incompleteInventory
          }
          let stripped = relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative
          let path = (prefix == "/" ? "" : prefix) + "/" + stripped
          _ = try DescriptorFileSystem.validatedComponents(path)
          return path
        }
        entries.append(Entry(paths: paths, plistPath: plist, bomPath: bom))
      } catch {
        issues.append(
          ApplicationAuxiliaryIssue(
            path: plist, detail: "receipt-install-prefix-or-files-unproven: " + String(describing: error)))
      }
    }
    let result = Result(entries: entries, issues: issues)
    cache.withLock { $0[bundleID] = result }
    return result
  }
}

private enum ApplicationReceiptQuery {
  static func run(_ arguments: [String]) -> Data? {
    guard arguments == ["--pkgs"] || arguments.count == 2 && arguments[0] == "--files" else { return nil }
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
      process.waitUntilExit()
      try? pipe.fileHandleForReading.close()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
      let count = read(fd, &buffer, buffer.count)
      if count > 0 {
        guard output.count + count <= 16 * 1024 * 1024 else { return nil }
        output.append(contentsOf: buffer.prefix(count))
      } else if count == 0 {
        guard !process.isRunning else { continue }
        process.waitUntilExit()
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
