import Foundation
import Testing

@testable import LightenKit

@Suite("Lighten version")
struct VersionTests {
  @Test("Initial marketing version")
  func marketingVersion() {
    #expect(LightenVersion.marketing == "0.0.1")
  }

  @Test("Initial build number")
  func buildNumber() {
    #expect(LightenVersion.build == 1)
  }

  @Test("Source plist leaves both versions for packaging")
  func sourcePlistUsesPlaceholders() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Resources/Info.plist")
    let plist = try #require(NSDictionary(contentsOf: url))
    #expect(plist["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
    #expect(plist["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
  }
}
