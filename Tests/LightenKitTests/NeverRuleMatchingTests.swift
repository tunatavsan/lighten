import Testing

@testable import LightenKit

@Suite("Protected path matching")
struct NeverRuleMatchingTests {
  private let home = "/Users/fixture"

  private let cases: [(String, String, String, String)] = [
    ("system", "/System", "/System/Library/a", "/Systems"),
    ("dyld-cache", "/System/Library/dyld", "/System/Library/dyld/a", "/System/Library/dyld-old"),
    (
      "localization-bundles", "/Applications/A.app/Contents/Resources/en.lproj",
      "/Applications/A.app/Contents/Resources/en.lproj/a", "/Applications/A.app/Contents/Resources/en.lproj-old"
    ),
    (
      "universal-thinning", "/Applications/A.app/Contents/MacOS", "/Applications/A.app/Contents/MacOS/A",
      "/Applications/A.app/Contents/MacOS-old"
    ),
    (
      "photos-library", "/Users/fixture/Moved/Family.photoslibrary",
      "/Users/fixture/Moved/Family.photoslibrary/Masters/a", "/Users/fixture/Moved/Family.photoslibrary.bak"
    ),
    (
      "external-photos-library", "/Volumes/Drive/Family.photoslibrary", "/Volumes/Drive/Family.photoslibrary/Masters/a",
      "/Volumes/Drive/Family.photoslibrary.bak"
    ),
    (
      "xcode-archives", "/Users/fixture/Library/Developer/Xcode/Archives",
      "/Users/fixture/Library/Developer/Xcode/Archives/a", "/Users/fixture/Library/Developer/Xcode/Archives-old"
    ),
    (
      "xcode-debug-symbols", "/Users/fixture/Build/A.dSYM", "/Users/fixture/Build/A.dSYM/a",
      "/Users/fixture/Build/A.dSYM.bak"
    ),
    (
      "docker-disk-image", "/Users/fixture/Library/Containers/com.docker.docker/Data/vms/Docker.raw",
      "/Users/fixture/Library/Containers/com.docker.docker/Data/vms/0/Docker.raw",
      "/Users/fixture/Library/Containers/com.docker.docker/Data/vms/0/Docker.raw.bak"
    ),
    (
      "orbstack-disk-image", "/Users/fixture/Library/Group Containers/a.orbstack/data.img",
      "/Users/fixture/Library/Group Containers/long.orbstack/data.img",
      "/Users/fixture/Library/Group Containers/a.orbstack/data.img.bak"
    ),
    ("parallels-images", "/Users/fixture/VMs/A.pvm", "/Users/fixture/VMs/A.pvm/a", "/Users/fixture/VMs/A.pvm.bak"),
    ("utm-images", "/Users/fixture/VMs/A.utm", "/Users/fixture/VMs/A.utm/a", "/Users/fixture/VMs/A.utm.bak"),
    (
      "vmware-images", "/Users/fixture/VMs/A.vmwarevm", "/Users/fixture/VMs/A.vmwarevm/a",
      "/Users/fixture/VMs/A.vmwarevm.bak"
    ),
    (
      "sparse-bundles", "/Users/fixture/Images/A.sparsebundle", "/Users/fixture/Images/A.sparsebundle/a",
      "/Users/fixture/Images/A.sparsebundle.bak"
    ),
    (
      "sparse-images", "/Users/fixture/Images/A.sparseimage", "/Users/fixture/Images/B.sparseimage",
      "/Users/fixture/Images/A.sparseimage.bak"
    ),
    (
      "maven-repository", "/Users/fixture/.m2/repository", "/Users/fixture/.m2/repository/a",
      "/Users/fixture/.m2/repository-old"
    ),
    ("mail", "/Users/fixture/Library/Mail", "/Users/fixture/Library/Mail/a", "/Users/fixture/Library/Mail-old"),
    (
      "messages", "/Users/fixture/Library/Messages", "/Users/fixture/Library/Messages/a",
      "/Users/fixture/Library/Messages-old"
    ),
    (
      "mobile-documents", "/Users/fixture/Library/Mobile Documents", "/Users/fixture/Library/Mobile Documents/a",
      "/Users/fixture/Library/Mobile Documents-old"
    ),
    (
      "cloud-storage", "/Users/fixture/Library/CloudStorage", "/Users/fixture/Library/CloudStorage/a",
      "/Users/fixture/Library/CloudStorage-old"
    ),
    (
      "mobile-sync", "/Users/fixture/Library/Application Support/MobileSync",
      "/Users/fixture/Library/Application Support/MobileSync/a",
      "/Users/fixture/Library/Application Support/MobileSync-old"
    ),
    (
      "container-documents", "/Users/fixture/Library/Containers/com.example.app/Data/Documents",
      "/Users/fixture/Library/Containers/com.example.app/Data/Documents/a",
      "/Users/fixture/Library/Containers/com.example.app/Data/Documents-old"
    ),
    (
      "group-containers", "/Users/fixture/Library/Group Containers", "/Users/fixture/Library/Group Containers/a",
      "/Users/fixture/Library/Group Containers-old"
    ),
    (
      "keychains", "/Users/fixture/Library/Keychains", "/Users/fixture/Library/Keychains/a",
      "/Users/fixture/Library/Keychains-old"
    ),
    ("ssh", "/Users/fixture/.ssh", "/Users/fixture/.ssh/id_ed25519", "/Users/fixture/.ssh-old"),
    (
      "core-simulator-volumes", "/Users/fixture/Library/Developer/CoreSimulator/Volumes",
      "/Users/fixture/Library/Developer/CoreSimulator/Volumes/a",
      "/Users/fixture/Library/Developer/CoreSimulator/Volumes-old"
    ),
  ]

  @Test("Every rule protects its exact target and rejects a similar name")
  func everyRule() throws {
    #expect(cases.count == NeverRule.all.count)
    for (id, root, child, nearMiss) in cases {
      let rule = try #require(NeverRule.all.first { $0.id == id })
      let matcher = PathPattern(rule.pattern, homeDirectory: home)
      #expect(matcher.matches(root), "\(id) root")
      #expect(matcher.matches(child), "\(id) child or second matching file")
      #expect(!matcher.matches(nearMiss), "\(id) near miss")
    }
  }

  @Test("Protection lookup uses the injected home and rejects traversal")
  func lookup() {
    #expect(NeverRule.protects("/Users/fixture/.ssh", homeDirectory: home)?.id == "ssh")
    #expect(NeverRule.protects("/Users/other/.ssh", homeDirectory: home) == nil)
    #expect(
      NeverRule.protects("/Volumes/X/Aile.photoslibrary/Masters/a.jpg", homeDirectory: home)?.id
        == "external-photos-library")
    #expect(NeverRule.protects("/Users/fixture/Pictures/Photos Library.photoslibrary.bak", homeDirectory: home) == nil)
    #expect(NeverRule.protects("/Users/fixture/.ssh/../safe", homeDirectory: home) == nil)
    #expect(
      NeverRule.protects("/Users/fixture/Documents/../.ssh", homeDirectory: home)?.id == "ssh"
    )
  }

  @Test("Literal components preserve Unicode, glob, home and case-alias matching")
  func literalComponentEquivalence() {
    let cases: [(pattern: String, path: String, expected: Bool)] = [
      ("/Applications/Cafe\u{301}.app/Contents/MacOS/*", "/Applications/Café.app/Contents/MacOS/Café", true),
      ("/Applications/Cafe\u{301}.app/Contents/MacOS/*", "/Applications/Cafe.app/Contents/MacOS/Cafe", false),
      ("/Applications/*.app/Contents/MacOS/**", "/Applications/A.app/Contents/MacOS/A", true),
      ("/Applications/*.app/Contents/MacOS/**", "/Applications/A.app/Contents/Resources/A", false),
      ("~/Library/Mail/**", "/Users/fixture/Library/Mail/V10/envelope", true),
      ("~/Library/Mail/**", "/Users/other/Library/Mail/V10/envelope", false),
      ("/Users/fixture/.ssh/**", "/Users/fixture/Documents/../.ssh/id", true),
      ("/Users/fixture/.ssh/**", "/Users/fixture/.ssh-old/id", false),
    ]
    for (pattern, path, expected) in cases {
      #expect(PathPattern(pattern, homeDirectory: home).matches(path) == expected)
    }
    #expect(ProtectionPolicy.rule(for: "/users/FIXTURE/Library/mAIL/V10", homeDirectory: home)?.id == "mail")
  }
}
