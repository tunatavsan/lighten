import CoreServices
import Foundation
import Security

/// The user Library domains supported by application removal.
public enum RelatedLocation: String, Codable, CaseIterable, Sendable {
  case caches, preferences, applicationSupport, containers, groupContainers
  case savedState, logs, httpStorages, webKit

  public var directoryName: String {
    switch self {
    case .caches: "Caches"
    case .preferences: "Preferences"
    case .applicationSupport: "Application Support"
    case .containers: "Containers"
    case .groupContainers: "Group Containers"
    case .savedState: "Saved Application State"
    case .logs: "Logs"
    case .httpStorages: "HTTPStorages"
    case .webKit: "WebKit"
    }
  }

  public func parent(homeDirectory: String) -> String { homeDirectory + "/Library/" + directoryName }

  public func path(domain: String, homeDirectory: String) -> String {
    let suffix = self == .preferences ? ".plist" : self == .savedState ? ".savedState" : ""
    return parent(homeDirectory: homeDirectory) + "/" + domain + suffix
  }

  func domain(name: String) -> String? {
    if self == .preferences {
      return name.hasSuffix(".plist") ? String(name.dropLast(6)) : nil
    }
    if self == .savedState {
      return name.hasSuffix(".savedState") ? String(name.dropLast(11)) : nil
    }
    return name
  }

  static func matching(path: String, homeDirectory: String) -> (Self, String)? {
    for location in allCases {
      let parent = location.parent(homeDirectory: homeDirectory)
      guard (path as NSString).deletingLastPathComponent == parent,
        let domain = location.domain(name: (path as NSString).lastPathComponent)
      else { continue }
      return (location, domain)
    }
    return nil
  }
}

public enum RelatedMatchStrength: String, Codable, Sendable {
  case strong, medium, weak
}

public struct RelatedDataObservation: Sendable {
  public let logical: ByteAggregate
  public let allocated: ByteAggregate
  public let knownItemCount: Int
  public let partial: Bool
}

/// Entitlements are read only after the bundle's signature passes validation.
struct ApplicationSigningMetadata: Sendable {
  let teamID: String?
  let groupIdentifiers: Set<String>

  static func read(path: String) -> Self? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
      let code,
      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    else { return nil }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        == errSecSuccess,
      let dictionary = information as? [String: Any]
    else { return nil }
    let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
    return Self(
      teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
      groupIdentifiers: Set(groups.filter(RelatedDataService.validBundleID)))
  }
}

enum ApplicationRegistration {
  static func isInstalled(bundleID: String) -> Bool {
    var error: Unmanaged<CFError>?
    guard let result = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, &error) else {
      guard let error = error?.takeRetainedValue() else { return false }
      return CFErrorGetCode(error) != Int(kLSApplicationNotFoundErr)
    }
    guard let urls = result.takeRetainedValue() as? [URL] else { return true }
    let trash = NSHomeDirectory() + "/.Trash/"
    return urls.contains { url in
      let path = url.resolvingSymlinksInPath().path
      return !path.hasPrefix(trash) && !path.contains("/.Trashes/")
        && FileManager.default.fileExists(atPath: RelatedDataService.infoPlistPath(ofBundleAt: path))
    }
  }
}
