import Foundation

public enum ApplicationIdentity {
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
