import CryptoKit
import Darwin
import Foundation

struct ApplicationReferenceDiscovery: Sendable {
  var claims: [ApplicationReferenceClaim] = []
  var issues: [ApplicationAuxiliaryIssue] = []
  var sources: [ApplicationPathObservation] = []
  /// Exact directory generations refresh discovery, without revoking an
  /// existing leaf's ownership merely because an unrelated sibling appears.
  var censusSources: [ApplicationPathObservation] = []
}

/// A native leaf observation, never a public grant of action authority.
/// Executable-name observations remain weak even when the package is verified.
struct ApplicationReferenceClaim: Sendable {
  let dataPath: String
  let sourcePath: String
  let references: [String]
  let ownerBundleID: String
  let matchStrength: RelatedMatchStrength
  var kind: RelatedDataProvenanceKind { matchStrength == .weak ? .executableName : .bundleIdentifier }
  private let packagePath: String
  private let packageBundleID: String
  private let nodes: [ReferenceNode]
  private let signatures: [ApplicationSignatureIdentity]
  private let nativeDirectories: ApplicationReferenceDirectories?

  fileprivate init(
    dataPath: String, sourcePath: String, ownerBundleID: String, matchStrength: RelatedMatchStrength,
    packagePath: String, packageBundleID: String, nodes: [ReferenceNode],
    signatures: [ApplicationSignatureIdentity],
    nativeDirectories: ApplicationReferenceDirectories?
  ) {
    self.dataPath = dataPath
    self.sourcePath = sourcePath
    self.ownerBundleID = ownerBundleID
    self.matchStrength = matchStrength
    self.packagePath = packagePath
    self.packageBundleID = packageBundleID
    self.nodes = nodes
    self.signatures = signatures
    self.nativeDirectories = nativeDirectories
    references = Array(Set(nodes.map(\.path).filter { $0 != dataPath && $0 != sourcePath })).sorted()
  }

  var sourceObservations: [ApplicationPathObservation] {
    nodes.filter { $0.path != dataPath }.map {
      ApplicationPathObservation(
        path: $0.path, identity: $0.identity, namespaceOwnerID: $0.namespaceOwnerID,
        nativeReferenceDirectories: $0.namespaceOwnerID == nil ? nil : nativeDirectories)
    }
      + signatures.flatMap { $0.entries.map { ApplicationPathObservation(path: $0.path, identity: $0.identity) } }
  }

  func validateBinding(to app: InstalledApplication) throws {
    guard packagePath == (app.linkTarget ?? app.path), packageBundleID == app.bundleID else {
      throw RelatedFailure.changedItem
    }
    try validate()
  }

  func validate(relocatedPackagePath: String? = nil) throws {
    try Task.checkCancellation()
    guard RelatedDataService.validBundleID(packageBundleID), RelatedDataService.validBundleID(ownerBundleID) else {
      throw RelatedFailure.changedItem
    }
    if let nativeDirectories { try nativeDirectories.validate() }
    for node in nodes {
      let path: String
      if let relocatedPackagePath, node.path == packagePath || node.path.hasPrefix(packagePath + "/") {
        path = relocatedPackagePath + node.path.dropFirst(packagePath.count)
      } else {
        path = node.path
      }
      try node.validate(
        at: path, movedPackageRoot: relocatedPackagePath != nil && node.path == packagePath)
    }
    let movedRoot = try relocatedPackagePath.map { try DescriptorFileSystem.identity(at: $0) }
    for signature in signatures {
      try signature.validate(
        mappedFrom: relocatedPackagePath == nil ? nil : packagePath, to: relocatedPackagePath,
        movedRoot: movedRoot)
    }
  }
}

/// Darwin gives the calling user's namespaces. We never enumerate /var/folders
/// or infer another user's cache location from a captured reference path.
struct ApplicationReferenceDirectories: Sendable, Equatable {
  let cache: String?
  let temporary: String?
  private let derivedFromCurrentUser: Bool
  private let userID: uid_t

  init(cache: String?, temporary: String?) {
    self.cache = cache
    self.temporary = temporary
    derivedFromCurrentUser = false
    userID = geteuid()
  }

  private init(cache: String?, temporary: String?, native: Bool) {
    self.cache = cache
    self.temporary = temporary
    derivedFromCurrentUser = native
    userID = geteuid()
  }

  static func currentUser() -> Self {
    Self(
      cache: directory(_CS_DARWIN_USER_CACHE_DIR), temporary: directory(_CS_DARWIN_USER_TEMP_DIR), native: true)
  }

  func validate() throws {
    guard userID == geteuid() else { throw RelatedFailure.changedItem }
    if derivedFromCurrentUser {
      guard self == Self.currentUser() else { throw RelatedFailure.changedItem }
    }
  }

  private static func directory(_ key: Int32) -> String? {
    let count = confstr(key, nil, 0)
    guard count > 1, count <= Int(PATH_MAX) else { return nil }
    var bytes = [CChar](repeating: 0, count: count)
    guard confstr(key, &bytes, count) == count, bytes.last == 0 else { return nil }
    var path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    while path.hasSuffix("/") { path.removeLast() }
    // /var is macOS's fixed alias. Avoid following that alias in the secure
    // descriptor walk; every component below /private is still no-follow.
    if path.hasPrefix("/var/") { path = "/private" + path }
    guard (try? DescriptorFileSystem.validatedComponents(path)) != nil else { return nil }
    return path
  }
}

enum ApplicationReferenceEvidenceProducer {
  static func discover(
    app: InstalledApplication, homeDirectory: String,
    directories: ApplicationReferenceDirectories = .currentUser(),
    signingMetadata: @Sendable (String) -> ApplicationSigningMetadata? = ApplicationSigningMetadata.read
  ) -> ApplicationReferenceDiscovery {
    var result = ApplicationReferenceDiscovery()
    let package = app.linkTarget ?? app.path
    func report(_ path: String, _ error: any Error) {
      result.issues.append(
        ApplicationAuxiliaryIssue(
          path: path, detail: "reference-data-" + String(describing: error), bundleID: app.bundleID,
          provenanceKind: .bundleIdentifier))
    }
    do {
      try Task.checkCancellation()
      _ = try DescriptorFileSystem.validatedComponents(homeDirectory)
      guard RelatedDataService.validBundleID(app.bundleID),
        !RelatedDataService.isCachedApplication(package, homeDirectory: homeDirectory)
      else { return result }
      let metadata = try ApplicationPackagePlanning.metadata(at: package)
      guard metadata.observation.bundleIdentifier == app.bundleID else { throw RelatedFailure.changedItem }
      let main = try owner(at: package, package: package, expectedID: app.bundleID)
      var owners = [main]
      var helperSources: [ApplicationPathObservation] = []
      let helperParents = [
        package + "/Contents/Frameworks", package + "/Contents/Library/LoginItems",
        package + "/Contents/PlugIns", package + "/Contents/XPCServices", package + "/Contents/MacOS",
      ]
      var mainSignature: ApplicationSignatureIdentity?
      var mainTeam: String?
      var readMainSignature = false
      for parent in helperParents {
        do {
          let root = try optionalNode(parent, owned: false)
          helperSources.append(ApplicationPathObservation(path: parent, identity: root?.identity))
          guard let root else { continue }
          guard root.identity.kind == .directory else { throw RelatedFailure.unsupportedInstalledData }
          let names = try children(parent, expected: root.identity, limit: 512)
          for name in names where isHelperPackage(name) {
            let helperPath = parent + "/" + name
            do {
              let helper = try owner(at: helperPath, package: package, expectedID: nil)
              // A generic framework identity is not ownership of every app's
              // data. The literal child ID and the signed team both bind it.
              guard helper.bundleID.hasPrefix(app.bundleID + ".") || helper.bundleID.hasPrefix(app.bundleID + "-"),
                helper.bundleID != app.bundleID,
                !helper.bundleID.lowercased().hasPrefix("com.github.electron.")
              else { continue }
              if !readMainSignature {
                readMainSignature = true
                mainSignature = try ApplicationSignatureIdentity.capture(package)
                mainTeam = signingMetadata(package)?.teamID
              }
              guard let mainTeam, !mainTeam.isEmpty, let mainSignature else { continue }
              let helperSignature = try ApplicationSignatureIdentity.capture(helperPath)
              guard signingMetadata(helperPath)?.teamID == mainTeam else { continue }
              try mainSignature.validate()
              try helperSignature.validate()
              let signatureNodes = try (mainSignature.entries + helperSignature.entries).compactMap { entry in
                entry.identity == nil ? nil : try ReferenceNode.observe(entry.path, owned: false)
              }
              owners.append(
                ReferenceOwner(
                  bundleID: helper.bundleID, source: helper.source, executable: helper.executable,
                  nodes: main.nodes + [root] + helper.nodes + signatureNodes,
                  signatures: [mainSignature, helperSignature]))
            } catch { report(helperPath, error) }
          }
        } catch { report(parent, error) }
      }
      result.sources += helperSources
      let crashParent = homeDirectory + "/Library/Application Support/CrashReporter"
      let recentParent =
        homeDirectory
        + "/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
      func namespace(_ path: String, native: Bool = false) -> ReferenceNode? {
        do {
          let node = try optionalNode(path, owned: true, namespace: true)
          result.sources.append(
            ApplicationPathObservation(
              path: path, identity: node?.identity, namespaceOwnerID: node?.namespaceOwnerID,
              nativeReferenceDirectories: native ? directories : nil))
          result.censusSources.append(ApplicationPathObservation(path: path, identity: node?.identity))
          guard node == nil || node?.identity.kind == .directory else {
            throw RelatedFailure.unsupportedInstalledData
          }
          return node
        } catch {
          report(path, error)
          return nil
        }
      }
      let crashRoot = namespace(crashParent)
      let recentRoot = namespace(recentParent)
      let nativeRoots = Set([directories.cache, directories.temporary].compactMap { $0 }).sorted().compactMap {
        namespace($0, native: true)
      }
      var physicalLeaves: Set<String> = []
      func add(
        _ path: String, owner: ReferenceOwner, root: ReferenceNode, native: Bool = false,
        strength: RelatedMatchStrength = .strong
      ) {
        do {
          guard let data = try optionalNode(path, owned: true) else { return }
          guard data.identity.device == root.identity.device,
            native ? data.identity.kind == .directory : data.identity.kind == .regular
          else { throw RelatedFailure.unsupportedInstalledData }
          let physical = String(data.identity.device) + ":" + String(data.identity.inode)
          guard !physicalLeaves.contains(physical) else { return }
          let claim = ApplicationReferenceClaim(
            dataPath: path, sourcePath: owner.source, ownerBundleID: owner.bundleID, matchStrength: strength,
            packagePath: package, packageBundleID: app.bundleID,
            nodes: owner.nodes + [root, data], signatures: owner.signatures,
            nativeDirectories: native ? directories : nil)
          try claim.validate()
          if physicalLeaves.insert(physical).inserted { result.claims.append(claim) }
        } catch { report(path, error) }
      }
      var crashNames: [String] = []
      if let crashRoot {
        do { crashNames = try children(crashParent, expected: crashRoot.identity, limit: 8192) } catch {
          report(crashParent, error)
        }
      }
      var recentNames: [String] = []
      if let recentRoot {
        do { recentNames = try children(recentParent, expected: recentRoot.identity, limit: 8192) } catch {
          report(recentParent, error)
        }
      }
      for owner in owners {
        try Task.checkCancellation()
        if let crashRoot, let executable = owner.executable {
          for name in crashNames where crashLeaf(name, executable: executable) {
            add(crashParent + "/" + name, owner: owner, root: crashRoot, strength: .weak)
          }
        }
        if let recentRoot {
          // LaunchServices writes the canonical lowercased identifier on some
          // releases. Both forms are exact spellings of the verified ID.
          let names = Set([owner.bundleID + ".sfl4", owner.bundleID.lowercased() + ".sfl4"])
          for name in recentNames where names.contains(name) {
            add(recentParent + "/" + name, owner: owner, root: recentRoot)
          }
        }
        for root in nativeRoots {
          add(root.path + "/" + owner.bundleID, owner: owner, root: root, native: true)
        }
      }
      result.sources += result.claims.flatMap(\.sourceObservations)
      for source in result.sources { try source.validate() }
      for claim in result.claims { try claim.validate() }
    } catch {
      result.claims = []
      report(package, error)
    }
    return result
  }

  private static func owner(at path: String, package: String, expectedID: String?) throws -> ReferenceOwner {
    guard path == package || path.hasPrefix(package + "/") else { throw RelatedFailure.unsupportedInstalledData }
    let metadata =
      (path as NSString).pathExtension.lowercased() == "app"
      ? try ApplicationPackagePlanning.metadata(at: path) : nil
    guard metadata != nil || (path != package && isHelperPackage((path as NSString).lastPathComponent)) else {
      throw RelatedFailure.unsupportedInstalledData
    }
    let source = path + "/" + (metadata?.observation.infoRelativePath ?? "Contents/Info.plist")
    let root = try ReferenceNode.observe(path, owned: false)
    let info = try ReferenceNode.observe(source, owned: false, contents: true)
    guard root.identity.kind == .directory, info.identity.kind == .regular,
      metadata == nil || metadata?.rootIdentity == root.identity,
      metadata == nil || metadata?.observation.infoIdentity == info.identity,
      let bytes = try SecureMetadataFile.read(path: source, limit: 1024 * 1024, ownerOnly: false),
      let dictionary = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
      let id = dictionary["CFBundleIdentifier"] as? String, RelatedDataService.validBundleID(id),
      expectedID == nil || id == expectedID,
      metadata == nil || metadata?.observation.bundleIdentifier == id
    else { throw RelatedFailure.unsupportedInstalledData }
    var nodes = [root, info]
    var executable: String?
    if let name = dictionary["CFBundleExecutable"] as? String, safeExecutable(name) {
      let candidate =
        source.hasSuffix("/Contents/Info.plist")
        ? path + "/Contents/MacOS/" + name : (source as NSString).deletingLastPathComponent + "/" + name
      let code = try ReferenceNode.observe(candidate, owned: false)
      guard code.identity.kind == .regular else { throw RelatedFailure.unsupportedInstalledData }
      nodes.append(code)
      executable = name
    }
    for node in nodes { try node.validate(at: node.path) }
    return ReferenceOwner(bundleID: id, source: source, executable: executable, nodes: nodes, signatures: [])
  }

  private static func safeExecutable(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1024 && value != "." && value != ".."
      && !value.contains("/") && !value.contains("\\")
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  private static func isHelperPackage(_ name: String) -> Bool {
    let suffix = (name as NSString).pathExtension.lowercased()
    return suffix == "app" || suffix == "appex" || suffix == "xpc"
  }

  private static func crashLeaf(_ name: String, executable: String) -> Bool {
    let prefix = executable + "_"
    guard name.hasPrefix(prefix), name.hasSuffix(".plist") else { return false }
    let suffix = String(name.dropFirst(prefix.count).dropLast(6))
    return suffix.count == 36 && UUID(uuidString: suffix) != nil
  }

  private static func optionalNode(_ path: String, owned: Bool, namespace: Bool = false) throws -> ReferenceNode? {
    do {
      return try ReferenceNode.observe(path, owned: owned, namespace: namespace)
    } catch FileSystemFailure.systemCall(_, let code)
      where code == ENOENT || code == ENOTDIR
    { return nil }
  }

  private static func children(_ path: String, expected: FileIdentity, limit: Int) throws -> [String] {
    let (parent, name) = try DescriptorFileSystem.openParent(of: path)
    defer { close(parent) }
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open reference directory", errno) }
    var details = stat()
    guard fstat(fd, &details) == 0, DescriptorFileSystem.identity(from: details) == expected else {
      close(fd)
      throw RelatedFailure.changedItem
    }
    guard let directory = fdopendir(fd) else {
      let code = errno
      close(fd)
      throw FileSystemFailure.systemCall("read reference directory", code)
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
      try Task.checkCancellation()
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else { throw FileSystemFailure.systemCall("read reference entry", errno) }
        break
      }
      let value = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if value != "." && value != ".." {
        guard names.count < limit else { throw RelatedFailure.incompleteInventory }
        names.append(value)
      }
    }
    guard try DescriptorFileSystem.identity(at: path) == expected else { throw RelatedFailure.changedItem }
    return names.sorted()
  }
}

private struct ReferenceOwner {
  let bundleID: String
  let source: String
  let executable: String?
  let nodes: [ReferenceNode]
  let signatures: [ApplicationSignatureIdentity]
}

private struct ReferenceNode: Sendable {
  let path: String
  let identity: FileIdentity
  let userOwned: Bool
  let digest: String?
  let namespaceOwnerID: uid_t?

  static func observe(_ path: String, owned: Bool, contents: Bool = false, namespace: Bool = false) throws -> Self {
    let (parent, name) = try DescriptorFileSystem.openParent(of: path)
    defer { close(parent) }
    let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("open reference artifact", errno) }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0 else { throw FileSystemFailure.systemCall("stat reference artifact", errno) }
    let identity = DescriptorFileSystem.identity(from: details)
    guard identity.kind == .directory || identity.kind == .regular,
      !namespace || (owned && identity.kind == .directory && identity.hasStableTrashProof),
      identity.kind != .regular || identity.linkCount == 1,
      identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
      !owned || details.st_uid == geteuid(),
      namespace
        ? identity.matchesStableTrashIdentity(try DescriptorFileSystem.identity(name: name, relativeTo: parent))
        : try DescriptorFileSystem.identity(name: name, relativeTo: parent) == identity
    else { throw RelatedFailure.unsupportedInstalledData }
    let digest: String?
    if contents {
      guard let bytes = try SecureMetadataFile.read(path: path, limit: 1024 * 1024, ownerOnly: false) else {
        throw RelatedFailure.changedItem
      }
      digest = hash(bytes)
    } else {
      digest = nil
    }
    guard fstat(fd, &details) == 0, !owned || details.st_uid == geteuid(),
      namespace
        ? identity.matchesStableTrashIdentity(DescriptorFileSystem.identity(from: details))
        : DescriptorFileSystem.identity(from: details) == identity,
      namespace
        ? identity.matchesStableTrashIdentity(try DescriptorFileSystem.identity(name: name, relativeTo: parent))
        : try DescriptorFileSystem.identity(name: name, relativeTo: parent) == identity
    else { throw RelatedFailure.changedItem }
    return Self(
      path: path, identity: identity, userOwned: owned, digest: digest,
      namespaceOwnerID: namespace ? details.st_uid : nil)
  }

  func validate(at path: String, movedPackageRoot: Bool = false) throws {
    let current = try Self.observe(
      path, owned: userOwned, contents: digest != nil, namespace: namespaceOwnerID != nil)
    guard
      movedPackageRoot || namespaceOwnerID != nil
        ? identity.matchesStableTrashIdentity(current.identity) : identity == current.identity,
      namespaceOwnerID == current.namespaceOwnerID,
      digest == current.digest
    else { throw RelatedFailure.changedItem }
  }

  private static func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}
