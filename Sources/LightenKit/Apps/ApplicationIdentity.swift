import Darwin
import Foundation

public enum ApplicationIdentity {
  static func metadata(ofBundleAt path: String) throws -> [String: Any] {
    let infoPath = RelatedDataService.infoPlistPath(ofBundleAt: path)
    guard let data = try SecureMetadataFile.read(path: infoPath, limit: 1024 * 1024, ownerOnly: false) else {
      throw ApplicationMetadataFailure.missingInfoPlist
    }
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = plist as? [String: Any]
    else { throw ApplicationMetadataFailure.invalidInfoPlist }
    return dictionary
  }

  /// CFBundleIdentifier from the bundle's own Info.plist, read without following links.
  public static func bundleIdentifier(ofApplicationAt path: String) -> String? {
    try? ApplicationPackagePlanning.metadata(at: path).observation.bundleIdentifier
  }

  static func executablePath(ofBundleAt path: String) -> String? {
    let infoPath = RelatedDataService.infoPlistPath(ofBundleAt: path)
    guard let data = try? SecureMetadataFile.read(path: infoPath, limit: 1024 * 1024, ownerOnly: false),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = plist as? [String: Any], let name = dictionary["CFBundleExecutable"] as? String,
      !name.isEmpty, name != ".", name != "..", !name.contains("/")
    else { return nil }
    if infoPath.hasSuffix("/Contents/Info.plist") { return path + "/Contents/MacOS/" + name }
    return (infoPath as NSString).deletingLastPathComponent + "/" + name
  }

}

enum ApplicationMetadataFailure: Error, Sendable {
  case missingInfoPlist, invalidInfoPlist, invalidBundleIdentifier, ambiguousMetadataLayout
}

/// Native observations used only inside an authenticated discovery lifetime.
/// A declared literal identifier does not authorize a package or related-data action.
struct ApplicationMetadataObservation: Sendable {
  enum State: Sendable {
    case declaredID(String)
    case identifierless, absentInfo
    case unknown(String)
  }
  let path: String
  let physicalPath: String
  let root: FileIdentity?
  let volumeID: UUID?
  let paths: [ApplicationPathObservation]
  let executableName: String?
  let state: State

  static func read(at path: String) -> Self {
    var physical = path
    var root: FileIdentity?
    var volumeID: UUID?
    var observations: [ApplicationPathObservation] = []
    var executableName: String?
    do {
      let original = try DescriptorFileSystem.identity(at: path)
      observations.append(ApplicationPathObservation(path: path, identity: original))
      if original.kind == .symbolicLink {
        guard let resolved = realpath(path, nil) else { throw FileSystemFailure.systemCall("realpath", errno) }
        physical = String(cString: resolved)
        free(resolved)
      }
      let identity = try DescriptorFileSystem.identity(at: physical)
      guard identity.kind == .directory, identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0 else {
        throw SecureMetadataFailure.unsafe
      }
      root = identity
      volumeID = try DescriptorFileSystem.volumeID(at: physical)
      if physical != path { observations.append(ApplicationPathObservation(path: physical, identity: identity)) }
      func observe(_ candidate: String) throws -> FileIdentity? {
        let value: FileIdentity?
        do { value = try DescriptorFileSystem.identity(at: candidate) } catch FileSystemFailure.systemCall(_, let code)
          where code == ENOENT
        { value = nil }
        if let value {
          guard value.device == identity.device, value.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0 else {
            throw SecureMetadataFailure.unsafe
          }
        }
        observations.append(ApplicationPathObservation(path: candidate, identity: value))
        return value
      }
      func directory(_ candidate: String) throws -> FileIdentity? {
        let value = try observe(candidate)
        guard value == nil || value?.kind == .directory else { throw SecureMetadataFailure.unsafe }
        return value
      }
      _ = try directory(physical + "/Contents")
      _ = try directory(physical + "/Resources")
      var infoPaths = [
        physical + "/Contents/Info.plist", physical + "/Info.plist",
        physical + "/Resources/Info.plist",
      ]
      if let wrapper = try directory(physical + "/Wrapper") {
        let names = try DescriptorFileSystem.children(at: physical + "/Wrapper", expected: wrapper)
        let apps = names.filter { ApplicationRegistration.hasApplicationSuffix($0) }
        guard apps.count == 1 else { throw ApplicationMetadataFailure.ambiguousMetadataLayout }
        let child = physical + "/Wrapper/" + apps[0]
        guard try directory(child) != nil else { throw FileSystemFailure.changedDuringInspection }
        _ = try directory(child + "/Contents")
        infoPaths += [child + "/Info.plist", child + "/Contents/Info.plist"]
      }
      var declared: Set<String> = []
      var hasInfo = false
      for info in infoPaths {
        guard let infoIdentity = try observe(info) else { continue }
        guard infoIdentity.kind == .regular else { throw SecureMetadataFailure.unsafe }
        hasInfo = true
        guard let data = try SecureMetadataFile.read(path: info, limit: 1024 * 1024, ownerOnly: false),
          let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw ApplicationMetadataFailure.invalidInfoPlist }
        if let value = value["CFBundleExecutable"] as? String,
          !value.isEmpty, value.utf8.count <= 1024, value != ".", value != "..", !value.contains("/"),
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        {
          executableName = value
        }
        if let value = value["CFBundleIdentifier"] {
          guard let id = value as? String, Self.safeLiteral(id) else {
            throw ApplicationMetadataFailure.invalidBundleIdentifier
          }
          declared.insert(id)
        }
      }
      guard declared.count <= 1 else { throw ApplicationMetadataFailure.ambiguousMetadataLayout }
      for observation in observations { try observation.validate() }
      guard try DescriptorFileSystem.volumeID(at: physical) == volumeID else {
        throw FileSystemFailure.changedDuringInspection
      }
      let state: State = declared.first.map(State.declaredID) ?? (hasInfo ? .identifierless : .absentInfo)
      return Self(
        path: path, physicalPath: physical, root: root, volumeID: volumeID,
        paths: observations, executableName: executableName, state: state)
    } catch {
      return Self(
        path: path, physicalPath: physical, root: root, volumeID: volumeID,
        paths: observations, executableName: executableName, state: .unknown(String(describing: error)))
    }
  }

  static func safeLiteral(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1024 && value != "." && value != ".."
      && !value.contains("/") && !value.contains("\\")
      && value.unicodeScalars.allSatisfy {
        !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
      }
  }

  func validateAbsence() throws {
    guard case .absentInfo = state, let root, let volumeID,
      try DescriptorFileSystem.identity(at: physicalPath) == root,
      try DescriptorFileSystem.volumeID(at: physicalPath) == volumeID
    else { throw RelatedFailure.changedItem }
    for observation in paths { try observation.validate() }
    guard case .absentInfo = Self.read(at: path).state else { throw RelatedFailure.changedItem }
  }
}

/// Metadata that could not establish an application ID is separate from a
/// failed filesystem syscall. A readable identifierless launcher is not an I/O error.
public struct ApplicationMetadataIssue: Sendable, Equatable {
  public let path: String
  public let reason: String

  init(path: String, error: any Error) {
    self.path = path
    self.reason = String(describing: error)
  }
}
