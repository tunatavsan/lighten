import Foundation
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

  @Test("Compiled glob matching agrees with the original dynamic program")
  func compiledGlobMatchesLegacy() {
    let patterns =
      NeverRule.all.map(\.pattern) + [
        "/", "/**", "/**/**", "/***", "/a/**/b/**", "/a/*/b", "/a/a**b/**", "/a/**b/**",
        "/a/./b/../**", "/a/../../**", "~", "~/../*", "~/**/../b", "~/./**/**",
        "relative/**", "//host/**", "/Cafe\u{301}/*", "/é*/*", "/👩‍💻*/**", "/a/*?/**", "/a/*\\**/**",
        "/a/e*\u{301}/**", "/a/**\u{301}/**",
      ]
    let paths =
      cases.flatMap { [$0.1, $0.2, $0.3] } + [
        "", "/", "relative", "//host/a", "/../a", "/a/../../b", "/a/./b", "/a///b/",
        "/a", "/a/b", "/a/x/b", "/a/x/y/b", "/a/b/x", "/a/ab/c", "/a/aééb/c", "/a/axxb",
        "/a/x?/b", "/a/x\\y/b", "/a/xx/b/c", "/a/**/b", "/Café/é", "/Cafe\u{301}/e\u{301}",
        "/école/👩‍💻", "/👩‍💻name/文", "/Users/fixture/./Library/Mail/../Mail/V10",
      ]
    for injectedHome in [home, "/Users/Cafe\u{301}/./", "/", "relative", "//host", "/../bad"] {
      for pattern in patterns {
        let compiled = PathPattern(pattern, homeDirectory: injectedHome)
        let original = LegacyPathPattern(pattern, homeDirectory: injectedHome)
        for path in paths {
          #expect(
            compiled.matches(path) == original.matches(path),
            "pattern=\(pattern) path=\(path) home=\(injectedHome)")
        }
      }
    }
    let long = String(repeating: "h", count: 5000)
    let deep = Array(repeating: "deep", count: 160).joined(separator: "/")
    for (pattern, path) in [("/" + long + "/**", "/" + long + "/a"), ("/a/**/b", "/a/" + deep + "/b")] {
      #expect(PathPattern(pattern, homeDirectory: home).matches(path))
      #expect(
        PathPattern(pattern, homeDirectory: home).matches(path)
          == LegacyPathPattern(pattern, homeDirectory: home).matches(path))
    }
  }

  @Test("Compiled rule lookup preserves exact priority, aliases, overlap and long uncached homes")
  func compiledPolicyPreservesOrderAndUncachedInputs() {
    let homes = [
      home, "/system", "/Users/Café", "/" + String(repeating: "h", count: 5000),
      "/" + Array(repeating: "deep", count: 160).joined(separator: "/"), "//host", "/../bad",
    ]
    let locale = Locale(identifier: "en_US_POSIX")
    for injectedHome in homes {
      for path in cases.flatMap({ [$0.1, $0.2, $0.3] }) + [
        injectedHome + "/Library/Mail/V10", injectedHome + "/Library/Group Containers/a.orbstack/data.img",
        injectedHome + "/Build/Café.dSYM/a", "/system/Family.photoslibrary", "/SYSTEM/Library/dyld/a",
        "/Applications/A.app/Contents/Resources/Base.lproj/Family.photoslibrary", "/a/../../System",
      ] {
        let exact = NeverRule.all.first { LegacyPathPattern($0.pattern, homeDirectory: injectedHome).matches(path) }
        let aliases = NeverRule.all.filter {
          LegacyPathPattern($0.pattern.lowercased(with: locale), homeDirectory: injectedHome.lowercased(with: locale))
            .matches(path.lowercased(with: locale))
        }
        #expect(ProtectionPolicy.rule(for: path, homeDirectory: injectedHome)?.id == (exact ?? aliases.first)?.id)
        #expect(ProtectionPolicy.rules(for: path, homeDirectory: injectedHome).map(\.id) == aliases.map(\.id))
      }
    }
    #expect(
      ProtectionPolicy.rule(for: "/system/Family.photoslibrary", homeDirectory: "/system")?.id == "photos-library")
    #expect(
      ProtectionPolicy.rules(for: "/system/Family.photoslibrary", homeDirectory: "/system").map(\.id)
        == ["system", "photos-library"])
  }

  @Test("Shared compiled homes remain isolated through concurrent cache replacement")
  func compiledHomeIsolation() async {
    let checks = await withTaskGroup(of: Bool.self) { group in
      for index in 0..<64 {
        group.addTask {
          let home = "/Users/fixture-\(index)/Café"
          let other = "/Users/fixture-\(index + 1)/Café"
          let matcher = ProtectionPolicy.matcher(homeDirectory: home)
          return matcher.rules(for: home + "/Library/Mail/V10").map(\.id) == ["mail"]
            && matcher.rules(for: other + "/Library/Mail/V10").isEmpty
            && ProtectionPolicy.rule(for: home + "/Library/Mail/V10", homeDirectory: home)?.id == "mail"
        }
      }
      var passed = true
      for await result in group { passed = passed && result }
      return passed
    }
    #expect(checks)
    #expect(ProtectionPolicy.rule(for: home + "/Library/Mail/V10", homeDirectory: home)?.id == "mail")
  }

  @Test("Activity rule projection keeps the complete lookup's identity set and sorting")
  func activityProjectionMatchesCompleteRules() {
    let paths =
      cases.flatMap { [$0.1, $0.2, $0.3] } + [
        home + "/Library/Group Containers/a.orbstack/data.img",
        home + "/Library/Group Containers/a.orbstack/data.img",
        home + "/Library/Caches/qa.lighten.fixture/file", "/users/FIXTURE/VMs/A.UTM/disk",
      ]
    let identities: [String: [String]] = [
      "utm-images": ["com.utmapp.UTM"], "parallels-images": ["com.parallels.desktop.console"],
      "vmware-images": ["com.vmware.fusion"], "docker-disk-image": ["com.docker.docker"],
      "orbstack-disk-image": ["dev.kdrag0n.OrbStack"],
    ]
    let locale = Locale(identifier: "en_US_POSIX")
    let expected = Array(
      Set(
        paths.flatMap { path in
          NeverRule.all.filter {
            LegacyPathPattern($0.pattern.lowercased(with: locale), homeDirectory: home.lowercased(with: locale))
              .matches(path.lowercased(with: locale))
          }.flatMap { identities[$0.id] ?? [] }
        })
    ).sorted()
    let entries = paths.map { ScanEntry(parentID: nil, path: $0, identity: nil, issues: [], readable: true) }
    #expect(ProtectionPolicy.relatedApplicationIDs(for: entries, homeDirectory: home) == expected)
    #expect(expected.count == 5)
  }
}

// Retains the original two-level dynamic program as a parity oracle.
private struct LegacyPathPattern: Sendable {
  let pattern: String
  let homeDirectory: String

  init(_ pattern: String, homeDirectory: String) {
    self.pattern = pattern
    self.homeDirectory = homeDirectory
  }

  func matches(_ path: String) -> Bool {
    guard let target = Self.components(path), let home = Self.components(homeDirectory) else {
      return false
    }

    let expanded: String
    if pattern == "~" {
      expanded = homeDirectory
    } else if pattern.hasPrefix("~/") {
      expanded = "/" + (home + pattern.dropFirst(2).split(separator: "/").map(String.init)).joined(separator: "/")
    } else {
      expanded = pattern
    }

    guard let rule = Self.components(expanded) else { return false }
    var states = Array(repeating: false, count: target.count + 1)
    states[0] = true

    for component in rule {
      var next = Array(repeating: false, count: target.count + 1)
      if component == "**" {
        next[0] = states[0]
        if !target.isEmpty {
          for index in 1...target.count {
            next[index] = states[index] || next[index - 1]
          }
        }
      } else {
        for index in target.indices where states[index] {
          if Self.matchesComponent(component, target[index]) {
            next[index + 1] = true
          }
        }
      }
      states = next
    }
    return states[target.count]
  }

  private static func components(_ path: String) -> [String]? {
    guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
    var components: [String] = []
    for component in path.split(separator: "/") {
      if component == "." { continue }
      if component == ".." {
        guard !components.isEmpty else { return nil }
        components.removeLast()
      } else {
        components.append(String(component))
      }
    }
    return components
  }

  private static func matchesComponent(_ pattern: String, _ component: String) -> Bool {
    if !pattern.contains("*") { return pattern == component }
    let tokens = Array(pattern)
    let characters = Array(component)
    var states = Array(repeating: false, count: characters.count + 1)
    states[0] = true
    for token in tokens {
      var next = Array(repeating: false, count: characters.count + 1)
      if token == "*" {
        next[0] = states[0]
        if !characters.isEmpty {
          for index in 1...characters.count {
            next[index] = states[index] || next[index - 1]
          }
        }
      } else {
        for index in characters.indices where states[index] && characters[index] == token {
          next[index + 1] = true
        }
      }
      states = next
    }
    return states[characters.count]
  }
}
