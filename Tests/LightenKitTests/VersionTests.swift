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
}
