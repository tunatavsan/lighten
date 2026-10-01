import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum ApplicationFrameworkKind: String, Sendable {
  case electron, mozilla
}

enum ApplicationFrameworkFailure: String, Error, Sendable {
  case unsupportedFramework, invalidPackage, missingArtifact, unsafeArtifact, artifactTooLarge
  case invalidMetadata, invalidArchive, missingDataShape, invalidProfile, changed, cancelled
}

struct ApplicationFrameworkIssue: Sendable {
  let path: String
  let reason: ApplicationFrameworkFailure
  let detail: String
}

struct ApplicationFrameworkDiscovery: Sendable {
  let evidence: [ApplicationFrameworkEvidence]
  let issues: [ApplicationFrameworkIssue]
  var complete: Bool { issues.isEmpty }
}

/// Package-derived evidence is private to the native ownership context. It is
/// neither a public candidate nor a serialized grant of deletion authority.
struct ApplicationFrameworkEvidence: Sendable {
  let packagePath: String
  let bundleIdentifier: String
  let dataPath: String
  let framework: ApplicationFrameworkKind
  let productName: String
  fileprivate let package: FrameworkObservation
  fileprivate let data: FrameworkObservation

  var sourceObservations: [ApplicationPathObservation] {
    [ApplicationPathObservation(path: package.rootPath, identity: package.rootIdentity)]
      + package.nodes.map {
        ApplicationPathObservation(path: package.rootPath + "/" + $0.relativePath, identity: $0.identity)
      }
  }

  fileprivate init(
    packagePath: String, bundleIdentifier: String, dataPath: String,
    framework: ApplicationFrameworkKind, productName: String,
    package: FrameworkObservation, data: FrameworkObservation
  ) {
    self.packagePath = packagePath
    self.bundleIdentifier = bundleIdentifier
    self.dataPath = dataPath
    self.framework = framework
    self.productName = productName
    self.package = package
    self.data = data
  }

  func validate() throws {
    try package.validate()
    try data.validate()
  }

  /// The caller must first authenticate the moved package with its private
  /// moved-owner proof. Moving the package cannot change its resource proof.
  func validate(relocatedPackagePath: String) throws {
    try package.validate(relocatedRoot: relocatedPackagePath)
    try data.validate()
  }
}

enum ApplicationFrameworkEvidenceProducer {
  static func discover(packagePath: String, homeDirectory: String) -> ApplicationFrameworkDiscovery {
    var evidence: [ApplicationFrameworkEvidence] = []
    var issues: [ApplicationFrameworkIssue] = []
    func report(_ path: String, _ error: any Error) {
      let reason: ApplicationFrameworkFailure
      if error is CancellationError {
        reason = .cancelled
      } else {
        reason = error as? ApplicationFrameworkFailure ?? .unsafeArtifact
      }
      issues.append(
        ApplicationFrameworkIssue(
          path: path, reason: reason,
          detail: String(describing: error)))
    }
    do {
      try Task.checkCancellation()
      _ = try DescriptorFileSystem.validatedComponents(homeDirectory)
      let package = try FrameworkReader(root: packagePath)
      let info = try package.read("Contents/Info.plist", limit: 1024 * 1024)
      guard let plist = try? PropertyListSerialization.propertyList(from: info, format: nil),
        let dictionary = plist as? [String: Any], let id = dictionary["CFBundleIdentifier"] as? String,
        ApplicationMetadataObservation.safeLiteral(id)
      else { throw ApplicationFrameworkFailure.invalidPackage }
      let electron = try package.observe("Contents/Frameworks/Electron Framework.framework")
      let mozilla = try package.observe("Contents/Resources/application.ini")
      guard electron != nil || mozilla != nil else { throw ApplicationFrameworkFailure.unsupportedFramework }
      if electron != nil {
        do {
          guard electron?.kind == .directory else { throw ApplicationFrameworkFailure.unsafeArtifact }
          let loose = try package.observe("Contents/Resources/app/package.json")
          let archive = try package.observe("Contents/Resources/app.asar")
          // Electron prefers app.asar when both exist. Ambiguous source layouts
          // remain visible rather than guessing which metadata was executed.
          guard loose == nil || archive == nil else { throw ApplicationFrameworkFailure.invalidMetadata }
          let json: Data
          if loose != nil {
            json = try package.read("Contents/Resources/app/package.json", limit: 1024 * 1024)
          } else if archive != nil {
            json = try package.readASARPackage("Contents/Resources/app.asar")
          } else {
            throw ApplicationFrameworkFailure.missingArtifact
          }
          let metadata = try FrameworkJSON.object(json)
          let value = metadata["productName"] ?? metadata["name"]
          guard let name = value as? String, safeComponent(name) else {
            throw ApplicationFrameworkFailure.invalidMetadata
          }
          if let path = try existingDataPath(parent: homeDirectory + "/Library/Application Support", name: name) {
            do {
              let data = try chromiumShape(path)
              evidence.append(
                ApplicationFrameworkEvidence(
                  packagePath: packagePath, bundleIdentifier: id, dataPath: path,
                  framework: .electron, productName: name, package: try package.finish(), data: data))
            } catch { report(path, error) }
          }
        } catch { report(packagePath, error) }
      }
      if mozilla != nil {
        do {
          let ini = try FrameworkINI.parse(try package.read("Contents/Resources/application.ini", limit: 64 * 1024))
          guard let name = ini["App"]?["Name"], safeComponent(name),
            let vendor = ini["App"]?["Vendor"], safeComponent(vendor)
          else { throw ApplicationFrameworkFailure.invalidMetadata }
          // Vendor is corroborating package metadata, not authority for a
          // broader vendor directory or another product's profiles.
          for parent in [homeDirectory + "/Library", homeDirectory + "/Library/Application Support"] {
            if let path = try existingDataPath(parent: parent, name: name) {
              do {
                let data = try mozillaShape(path)
                evidence.append(
                  ApplicationFrameworkEvidence(
                    packagePath: packagePath, bundleIdentifier: id, dataPath: path,
                    framework: .mozilla, productName: name, package: try package.finish(), data: data))
              } catch { report(path, error) }
            }
          }
        } catch { report(packagePath, error) }
      }
      // Recheck even branches with no existing data. A changing package cannot
      // mint evidence collected earlier in this discovery call.
      _ = try package.finish()
    } catch {
      evidence = []
      report(packagePath, error)
    }
    return ApplicationFrameworkDiscovery(evidence: evidence, issues: issues)
  }

  fileprivate static func safeComponent(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".."
      && !value.contains("/") && !value.contains("\\")
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  private static func existingDataPath(parent: String, name: String) throws -> String? {
    let requested = parent + "/" + name
    guard try FrameworkReader.exists(requested) else { return nil }
    let identity = try DescriptorFileSystem.identity(at: requested)
    let parentIdentity = try DescriptorFileSystem.identity(at: parent)
    let names = try DescriptorFileSystem.children(at: parent, expected: parentIdentity)
    // A case-insensitive volume may resolve a package's lowercase name to an
    // existing uppercase entry. Emit that native entry once, never a lexical
    // alias or a case-only guess on a case-sensitive volume.
    let matches = names.filter {
      $0.caseInsensitiveCompare(name) == .orderedSame
        && (try? DescriptorFileSystem.identity(at: parent + "/" + $0)) == identity
    }
    guard matches.count == 1, try DescriptorFileSystem.identity(at: parent) == parentIdentity else {
      throw ApplicationFrameworkFailure.changed
    }
    return parent + "/" + matches[0]
  }

  private static func chromiumShape(_ path: String) throws -> FrameworkObservation {
    let reader = try FrameworkReader(root: path)
    _ = try FrameworkJSON.object(reader.read("Preferences", limit: 1024 * 1024))
    var caches = 0
    for name in ["Cache", "Code Cache", "GPUCache"] {
      if let node = try reader.observe(name) {
        guard node.kind == .directory else { throw ApplicationFrameworkFailure.missingDataShape }
        caches += 1
      }
    }
    let state = try reader.observe("Local State")
    let storage = try reader.observe("Local Storage")
    if state != nil { _ = try FrameworkJSON.object(reader.read("Local State", limit: 1024 * 1024)) }
    guard storage == nil || storage?.kind == .directory,
      caches > 0, state != nil || storage != nil
    else { throw ApplicationFrameworkFailure.missingDataShape }
    return try reader.finish()
  }

  private static func mozillaShape(_ path: String) throws -> FrameworkObservation {
    let reader = try FrameworkReader(root: path)
    if try reader.observe("profiles.ini") != nil {
      let ini = try FrameworkINI.parse(reader.read("profiles.ini", limit: 1024 * 1024))
      let profiles = ini.filter { $0.key.hasPrefix("Profile") }
      guard !profiles.isEmpty, profiles.count <= 128 else { throw ApplicationFrameworkFailure.invalidProfile }
      var shaped = 0
      for (_, profile) in profiles {
        guard profile["IsRelative"] == "1", let relative = profile["Path"],
          safeRelativePath(relative), relative.hasPrefix("Profiles/")
        else { throw ApplicationFrameworkFailure.invalidProfile }
        if try profileShape(reader, relative) { shaped += 1 }
      }
      guard shaped > 0 else { throw ApplicationFrameworkFailure.missingDataShape }
    } else {
      guard try reader.observe("Profiles")?.kind == .directory else {
        throw ApplicationFrameworkFailure.missingDataShape
      }
      let profiles = try reader.children("Profiles", limit: 128)
      guard !profiles.isEmpty else { throw ApplicationFrameworkFailure.missingDataShape }
      var shaped = 0
      for profile in profiles {
        guard safeComponent(profile) else { throw ApplicationFrameworkFailure.invalidProfile }
        if try profileShape(reader, "Profiles/" + profile) { shaped += 1 }
      }
      guard shaped > 0 else { throw ApplicationFrameworkFailure.missingDataShape }
    }
    return try reader.finish()
  }

  private static func profileShape(_ reader: FrameworkReader, _ relative: String) throws -> Bool {
    guard try reader.observe(relative)?.kind == .directory else { return false }
    let prefs = try reader.observe(relative + "/prefs.js")
    let compatibility = try reader.observe(relative + "/compatibility.ini")
    guard prefs == nil || prefs?.kind == .regular, compatibility == nil || compatibility?.kind == .regular else {
      throw ApplicationFrameworkFailure.invalidProfile
    }
    // Profile contents can be large and contain private account settings. Their
    // exact native identities establish shape; no JavaScript is read or run.
    return prefs != nil && compatibility != nil
  }

  fileprivate static func safeRelativePath(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/")
      && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        safeComponent(String($0))
      }
  }
}

private struct FrameworkReadRange: Sendable {
  let offset: Int64
  let count: Int
  let digest: String
}

private struct FrameworkNode: Sendable {
  let relativePath: String
  let identity: FileIdentity?
  let ranges: [FrameworkReadRange]
}

private struct FrameworkObservation: Sendable {
  let rootPath: String
  let rootIdentity: FileIdentity
  let volumeID: UUID
  let nodes: [FrameworkNode]

  func validate(relocatedRoot: String? = nil) throws {
    try Task.checkCancellation()
    let path = relocatedRoot ?? rootPath
    let reader = try FrameworkReader(root: path)
    guard reader.volumeID == volumeID,
      relocatedRoot == nil
        ? reader.rootIdentity == rootIdentity
        : reader.rootIdentity.matchesStableTrashIdentity(rootIdentity)
    else { throw ApplicationFrameworkFailure.changed }
    for node in nodes {
      let current = try reader.observe(node.relativePath)
      guard current == node.identity else { throw ApplicationFrameworkFailure.changed }
      if let identity = node.identity, !node.ranges.isEmpty {
        try reader.withFile(node.relativePath, expected: identity) { fd, _ in
          for range in node.ranges {
            let bytes = try FrameworkReader.readRange(fd: fd, offset: range.offset, count: range.count)
            guard FrameworkReader.digest(bytes) == range.digest else { throw ApplicationFrameworkFailure.changed }
          }
        }
      }
    }
    _ = try reader.finish()
  }
}

/// One bounded native reader owns its root descriptor for the complete read.
/// Every intermediate directory and artifact is recorded and rechecked.
private final class FrameworkReader {
  let rootPath: String
  let rootIdentity: FileIdentity
  let volumeID: UUID
  private let rootFD: Int32
  private var observed: [String: FrameworkNode] = [:]

  init(root: String) throws {
    let (parent, name) = try DescriptorFileSystem.openParent(of: root)
    defer { close(parent) }
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open framework root", errno) }
    do {
      var details = stat()
      guard fstat(fd, &details) == 0 else { throw FileSystemFailure.systemCall("fstat framework root", errno) }
      let identity = DescriptorFileSystem.identity(from: details)
      guard identity.kind == .directory, identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
        try DescriptorFileSystem.identity(name: name, relativeTo: parent) == identity,
        let volume = try DescriptorFileSystem.volumeID(at: root)
      else { throw ApplicationFrameworkFailure.unsafeArtifact }
      rootPath = root
      rootFD = fd
      rootIdentity = identity
      volumeID = volume
    } catch {
      close(fd)
      throw error
    }
  }

  deinit { close(rootFD) }

  static func exists(_ path: String) throws -> Bool {
    do {
      _ = try DescriptorFileSystem.identity(at: path)
      return true
    } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT { return false }
  }

  func observe(_ relative: String) throws -> FileIdentity? {
    guard ApplicationFrameworkEvidenceProducer.safeRelativePath(relative) else {
      throw ApplicationFrameworkFailure.unsafeArtifact
    }
    var identity: FileIdentity?
    do {
      let (parent, name) = try openParent(relative)
      defer { close(parent) }
      identity = try DescriptorFileSystem.identity(name: name, relativeTo: parent)
      guard let identity, identity.device == rootIdentity.device,
        identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
        identity.kind == .directory || identity.kind == .regular,
        identity.kind != .regular || identity.linkCount == 1
      else { throw ApplicationFrameworkFailure.unsafeArtifact }
    } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT { identity = nil }
    try record(relative, identity: identity)
    return identity
  }

  func read(_ relative: String, limit: Int) throws -> Data {
    guard let identity = try observe(relative) else { throw ApplicationFrameworkFailure.missingArtifact }
    guard identity.kind == .regular else { throw ApplicationFrameworkFailure.unsafeArtifact }
    guard identity.logicalBytes >= 0, identity.logicalBytes <= Int64(limit) else {
      throw ApplicationFrameworkFailure.artifactTooLarge
    }
    var bytes = Data()
    try withFile(relative, expected: identity) { fd, _ in
      bytes = try Self.readRange(fd: fd, offset: 0, count: Int(identity.logicalBytes))
    }
    try record(
      relative, identity: identity, range: FrameworkReadRange(offset: 0, count: bytes.count, digest: Self.digest(bytes))
    )
    return bytes
  }

  func readASARPackage(_ relative: String) throws -> Data {
    guard let identity = try observe(relative), identity.kind == .regular, identity.logicalBytes >= 16 else {
      throw ApplicationFrameworkFailure.invalidArchive
    }
    var result = Data()
    var ranges: [FrameworkReadRange] = []
    try withFile(relative, expected: identity) { fd, size in
      func read(_ offset: Int64, _ count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= size, Int64(count) <= size - offset else {
          throw ApplicationFrameworkFailure.invalidArchive
        }
        let bytes = try Self.readRange(fd: fd, offset: offset, count: count)
        ranges.append(FrameworkReadRange(offset: offset, count: count, digest: Self.digest(bytes)))
        return bytes
      }
      let prefix = try read(0, 8)
      let headerSize = Int(Self.uint32(prefix, 4))
      guard Self.uint32(prefix, 0) == 4, headerSize >= 8, headerSize <= 4 * 1024 * 1024,
        headerSize % 4 == 0, Int64(headerSize) <= size - 8
      else { throw ApplicationFrameworkFailure.invalidArchive }
      let header = try read(8, headerSize)
      let jsonSize = Int(Self.uint32(header, 4))
      guard Self.uint32(header, 0) == UInt32(headerSize - 4), jsonSize > 0,
        jsonSize <= headerSize - 8, headerSize - 8 - jsonSize < 4,
        header[(8 + jsonSize)..<headerSize].allSatisfy({ $0 == 0 })
      else { throw ApplicationFrameworkFailure.invalidArchive }
      let object = try FrameworkJSON.object(Data(header[8..<(8 + jsonSize)]))
      guard let files = object["files"] as? [String: Any] else { throw ApplicationFrameworkFailure.invalidArchive }
      try Self.validateArchiveNames(files, depth: 0)
      guard let entry = files["package.json"] as? [String: Any], entry["link"] == nil,
        entry["unpacked"] == nil || FrameworkJSON.isFalse(entry["unpacked"]),
        entry["files"] == nil, let offsetText = entry["offset"] as? String,
        !offsetText.isEmpty, offsetText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
        let offset = Int64(offsetText), let count = FrameworkJSON.integer(entry["size"]),
        count > 0, count <= 1024 * 1024
      else { throw ApplicationFrameworkFailure.invalidArchive }
      let base = Int64(headerSize) + 8
      guard offset <= size - base, Int64(count) <= size - base - offset else {
        throw ApplicationFrameworkFailure.invalidArchive
      }
      result = try read(base + offset, count)
    }
    for range in ranges { try record(relative, identity: identity, range: range) }
    return result
  }

  private static func validateArchiveNames(_ files: [String: Any], depth: Int) throws {
    guard depth <= 64 else { throw ApplicationFrameworkFailure.invalidArchive }
    for (name, value) in files {
      guard ApplicationFrameworkEvidenceProducer.safeComponent(name), let entry = value as? [String: Any] else {
        throw ApplicationFrameworkFailure.invalidArchive
      }
      if let nested = entry["files"] {
        guard let nested = nested as? [String: Any] else { throw ApplicationFrameworkFailure.invalidArchive }
        try validateArchiveNames(nested, depth: depth + 1)
      }
    }
  }

  func children(_ relative: String, limit: Int) throws -> [String] {
    let (parent, name) = try openParent(relative)
    defer { close(parent) }
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open framework directory", errno) }
    guard let directory = fdopendir(fd) else {
      let code = errno
      close(fd)
      throw FileSystemFailure.systemCall("fdopendir", code)
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
      try Task.checkCancellation()
      errno = 0
      guard let entry = readdir(directory) else {
        if errno != 0 { throw FileSystemFailure.systemCall("readdir", errno) }
        break
      }
      let value = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if value != "." && value != ".." {
        guard names.count < limit else { throw ApplicationFrameworkFailure.artifactTooLarge }
        names.append(value)
      }
    }
    return names.sorted()
  }

  func withFile(_ relative: String, expected: FileIdentity, body: (Int32, Int64) throws -> Void) throws {
    let (parent, name) = try openParent(relative)
    defer { close(parent) }
    let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open framework artifact", errno) }
    defer { close(fd) }
    func validate() throws {
      var details = stat()
      guard fstat(fd, &details) == 0 else { throw FileSystemFailure.systemCall("fstat framework artifact", errno) }
      guard DescriptorFileSystem.identity(from: details) == expected,
        try DescriptorFileSystem.identity(name: name, relativeTo: parent) == expected,
        expected.kind == .regular, expected.linkCount == 1
      else { throw ApplicationFrameworkFailure.changed }
    }
    try validate()
    try body(fd, expected.logicalBytes)
    try validate()
  }

  func finish() throws -> FrameworkObservation {
    guard try DescriptorFileSystem.identity(at: rootPath) == rootIdentity,
      try DescriptorFileSystem.volumeID(at: rootPath) == volumeID
    else { throw ApplicationFrameworkFailure.changed }
    for node in Array(observed.values) {
      guard try observe(node.relativePath) == node.identity else { throw ApplicationFrameworkFailure.changed }
    }
    return FrameworkObservation(
      rootPath: rootPath, rootIdentity: rootIdentity, volumeID: volumeID,
      nodes: observed.values.sorted { $0.relativePath < $1.relativePath })
  }

  private func openParent(_ relative: String) throws -> (Int32, String) {
    guard ApplicationFrameworkEvidenceProducer.safeRelativePath(relative) else {
      throw ApplicationFrameworkFailure.unsafeArtifact
    }
    let parts = relative.split(separator: "/").map(String.init)
    var fd = dup(rootFD)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("dup framework root", errno) }
    var prefix = ""
    do {
      for part in parts.dropLast() {
        prefix += (prefix.isEmpty ? "" : "/") + part
        let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard next >= 0 else {
          let code = errno
          if code == ENOENT { try record(prefix, identity: nil) }
          throw FileSystemFailure.systemCall("open framework parent", code)
        }
        var details = stat()
        guard fstat(next, &details) == 0 else {
          let code = errno
          close(next)
          throw FileSystemFailure.systemCall("fstat framework parent", code)
        }
        let identity = DescriptorFileSystem.identity(from: details)
        guard identity.device == rootIdentity.device, identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
          try DescriptorFileSystem.identity(name: part, relativeTo: fd) == identity
        else {
          close(next)
          throw ApplicationFrameworkFailure.changed
        }
        do { try record(prefix, identity: identity) } catch {
          close(next)
          throw error
        }
        close(fd)
        fd = next
      }
      return (fd, parts[parts.count - 1])
    } catch {
      close(fd)
      throw error
    }
  }

  private func record(_ relative: String, identity: FileIdentity?, range: FrameworkReadRange? = nil) throws {
    if let previous = observed[relative], previous.identity != identity { throw ApplicationFrameworkFailure.changed }
    var ranges = observed[relative]?.ranges ?? []
    if let range { ranges.append(range) }
    observed[relative] = FrameworkNode(relativePath: relative, identity: identity, ranges: ranges)
  }

  static func readRange(fd: Int32, offset: Int64, count: Int) throws -> Data {
    guard count >= 0, count <= 4 * 1024 * 1024, offset >= 0 else {
      throw ApplicationFrameworkFailure.artifactTooLarge
    }
    var bytes = [UInt8](repeating: 0, count: count)
    var done = 0
    while done < count {
      try Task.checkCancellation()
      let amount = bytes.withUnsafeMutableBytes {
        pread(fd, $0.baseAddress?.advanced(by: done), count - done, off_t(offset + Int64(done)))
      }
      if amount < 0 && errno == EINTR { continue }
      guard amount > 0 else { throw ApplicationFrameworkFailure.changed }
      done += amount
    }
    return Data(bytes)
  }

  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3])
      << 24
  }
}

private enum FrameworkINI {
  static func parse(_ bytes: Data) throws -> [String: [String: String]] {
    guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
      throw ApplicationFrameworkFailure.invalidMetadata
    }
    var sections: [String: [String: String]] = [:]
    var section: String?
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
      if line.hasPrefix("[") && line.hasSuffix("]") {
        let name = String(line.dropFirst().dropLast())
        guard !name.isEmpty, sections[name] == nil else { throw ApplicationFrameworkFailure.invalidMetadata }
        sections[name] = [:]
        section = name
      } else {
        guard let section, let separator = line.firstIndex(of: "=") else {
          throw ApplicationFrameworkFailure.invalidMetadata
        }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, sections[section]?[key] == nil else { throw ApplicationFrameworkFailure.invalidMetadata }
        sections[section]?[key] = value
      }
    }
    return sections
  }
}

/// Foundation accepts duplicate JSON keys. Validate the bounded input first so
/// ambiguous metadata and duplicate archive paths cannot mint an owner proof.
private enum FrameworkJSON {
  static func object(_ data: Data) throws -> [String: Any] {
    var validator = FrameworkJSONValidator(bytes: Array(data))
    try validator.validate()
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ApplicationFrameworkFailure.invalidMetadata
    }
    return object
  }

  static func integer(_ value: Any?) -> Int? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
      value.doubleValue.isFinite, value.doubleValue.rounded(.towardZero) == value.doubleValue,
      value.doubleValue >= 0, value.doubleValue <= Double(Int32.max)
    else { return nil }
    return value.intValue
  }

  static func isFalse(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
    return !number.boolValue
  }
}

private struct FrameworkJSONValidator {
  let bytes: [UInt8]
  private var position = 0
  private var nodes = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  mutating func validate() throws {
    try value(depth: 0)
    whitespace()
    guard position == bytes.count else { throw ApplicationFrameworkFailure.invalidMetadata }
  }

  private mutating func value(depth: Int) throws {
    whitespace()
    nodes += 1
    guard depth <= 64, nodes <= 200_000, position < bytes.count else {
      throw ApplicationFrameworkFailure.invalidMetadata
    }
    switch bytes[position] {
    case 123:
      position += 1
      whitespace()
      if consume(125) { return }
      var keys: Set<String> = []
      while true {
        whitespace()
        let key = try string()
        guard keys.insert(key).inserted else { throw ApplicationFrameworkFailure.invalidMetadata }
        whitespace()
        guard consume(58) else { throw ApplicationFrameworkFailure.invalidMetadata }
        try value(depth: depth + 1)
        whitespace()
        if consume(125) { return }
        guard consume(44) else { throw ApplicationFrameworkFailure.invalidMetadata }
      }
    case 91:
      position += 1
      whitespace()
      if consume(93) { return }
      while true {
        try value(depth: depth + 1)
        whitespace()
        if consume(93) { return }
        guard consume(44) else { throw ApplicationFrameworkFailure.invalidMetadata }
      }
    case 34: _ = try string()
    default:
      let start = position
      while position < bytes.count, ![UInt8(44), 93, 125, 32, 9, 10, 13].contains(bytes[position]) { position += 1 }
      guard position > start,
        (try? JSONSerialization.jsonObject(with: Data(bytes[start..<position]), options: .fragmentsAllowed)) != nil
      else { throw ApplicationFrameworkFailure.invalidMetadata }
    }
  }

  private mutating func string() throws -> String {
    let start = position
    guard consume(34) else { throw ApplicationFrameworkFailure.invalidMetadata }
    while position < bytes.count {
      let byte = bytes[position]
      position += 1
      if byte == 92 {
        guard position < bytes.count else { throw ApplicationFrameworkFailure.invalidMetadata }
        position += 1
      } else if byte == 34 {
        guard
          let value = try? JSONSerialization.jsonObject(
            with: Data(bytes[start..<position]), options: .fragmentsAllowed) as? String
        else { throw ApplicationFrameworkFailure.invalidMetadata }
        return value
      }
    }
    throw ApplicationFrameworkFailure.invalidMetadata
  }

  private mutating func whitespace() {
    while position < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[position]) { position += 1 }
  }

  private mutating func consume(_ byte: UInt8) -> Bool {
    guard position < bytes.count, bytes[position] == byte else { return false }
    position += 1
    return true
  }
}
