import Foundation
import Testing

@testable import LightenKit

@Suite("Lighten version")
struct VersionTests {
  @Test("Marketing version is a semantic version")
  func marketingVersion() {
    #expect(LightenVersion.marketing.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil)
  }

  @Test("Build number is positive")
  func buildNumber() {
    #expect(LightenVersion.build > 0)
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
