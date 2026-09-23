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
}
