import Foundation
import Testing

@testable import LightenKit

@Suite("Bundle identity")
struct IdentityTests {
  @Test("Source plist identity matches the application constant")
  func sourcePlistMatchesIdentity() throws {
    let plist = try #require(NSDictionary(contentsOf: Self.infoPlistURL))
    #expect(plist["CFBundleIdentifier"] as? String == LightenIdentity.bundleIdentifier)
  }

  private static var infoPlistURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Resources/Info.plist")
  }
}
