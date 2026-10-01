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
    guard
      let data = try? SecureMetadataFile.read(
        path: path + "/Contents/Info.plist", limit: 1024 * 1024, ownerOnly: false),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = plist as? [String: Any],
      let bundleID = dictionary["CFBundleIdentifier"] as? String,
      RelatedDataService.validBundleID(bundleID)
    else { return nil }
    return bundleID
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
  case missingInfoPlist, invalidInfoPlist, invalidBundleIdentifier
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
