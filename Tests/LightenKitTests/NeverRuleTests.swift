import Testing

@testable import LightenKit

@Suite("NeverRule")
struct NeverRuleTests {
  @Test("Rule identifiers are unique")
  func identifiersAreUnique() {
    let ids = NeverRule.all.map(\.id)

    #expect(Set(ids).count == ids.count)
  }

  @Test("Every rule has a user-facing reason")
  func reasonsAreNotEmpty() {
    let emptyReasonIDs = NeverRule.all
      .filter { $0.reason.isEmpty || $0.reason.allSatisfy(\.isWhitespace) }
      .map(\.id)

    #expect(emptyReasonIDs.isEmpty)
  }

  @Test("The initial safety policy has at least fifteen rules")
  func includesMinimumRuleCount() {
    #expect(NeverRule.all.count >= 15)
  }

  @Test("The complete initial protection set is present")
  func includesCompleteProtectionSet() {
    let expectedIDs: Set<String> = [
      "system",
      "dyld-cache",
      "localization-bundles",
      "universal-thinning",
      "photos-library",
      "xcode-archives",
      "xcode-debug-symbols",
      "docker-disk-image",
      "orbstack-disk-image",
      "parallels-images",
      "utm-images",
      "vmware-images",
      "sparse-bundles",
      "sparse-images",
      "maven-repository",
      "mail",
      "messages",
      "mobile-documents",
      "cloud-storage",
      "mobile-sync",
      "container-documents",
      "group-containers",
      "keychains",
      "ssh",
      "core-simulator-volumes",
    ]

    #expect(Set(NeverRule.all.map(\.id)) == expectedIDs)
  }

  @Test("Every pattern is absolute or home-relative")
  func patternsHaveSupportedRoots() {
    let unsupportedPatternIDs = NeverRule.all
      .filter { !$0.pattern.hasPrefix("/") && !$0.pattern.hasPrefix("~/") }
      .map(\.id)

    #expect(unsupportedPatternIDs.isEmpty)
  }
}
