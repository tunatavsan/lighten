import Foundation

public struct NeverRule: Sendable {
  public let id: String
  public let pattern: String
  public let reason: String
  public let evidence: String?

  public init(id: String, pattern: String, reason: String, evidence: String? = nil) {
    self.id = id
    self.pattern = pattern
    self.reason = reason
    self.evidence = evidence
  }

  public static func protects(
    _ path: String,
    homeDirectory: String = NSHomeDirectory()
  ) -> NeverRule? {
    all.first { PathPattern($0.pattern, homeDirectory: homeDirectory).matches(path) }
  }

  public static let all: [NeverRule] = [
    NeverRule(
      id: "system",
      pattern: "/System/**",
      reason: "System files are required by macOS and must never be offered for cleanup.",
      evidence: "macOS protects this tree with System Integrity Protection."
    ),
    NeverRule(
      id: "dyld-cache",
      pattern: "/System/Library/dyld/**",
      reason: "The dynamic linker cache is required to launch macOS and its applications.",
      evidence: "The cache is managed by macOS."
    ),
    NeverRule(
      id: "localization-bundles",
      pattern: "/**/*.lproj/**",
      reason: "Localization bundles contain the language resources shipped with applications."
    ),
    NeverRule(
      id: "universal-thinning",
      pattern: "/**/*.app/Contents/MacOS/**",
      reason: "Removing architecture slices can invalidate signatures and make universal applications unusable."
    ),
    NeverRule(
      id: "photos-library",
      pattern: "~/**/*.photoslibrary/**",
      reason: "A Photos library contains irreplaceable originals, edits, and database state."
    ),
    NeverRule(
      id: "external-photos-library",
      pattern: "/Volumes/**/*.photoslibrary/**",
      reason: "A Photos library contains irreplaceable originals, edits, and database state."
    ),
    NeverRule(
      id: "xcode-archives",
      pattern: "~/Library/Developer/Xcode/Archives/**",
      reason: "Xcode archives and their debug symbols may be required for distribution and crash analysis."
    ),
    NeverRule(
      id: "xcode-debug-symbols",
      pattern: "~/**/*.dSYM/**",
      reason: "Debug symbol bundles may be required to symbolicate crash reports."
    ),
    NeverRule(
      id: "docker-disk-image",
      pattern: "~/Library/Containers/com.docker.docker/Data/vms/**/Docker.raw",
      reason: "Docker disk images contain container volumes, images, and other user data."
    ),
    NeverRule(
      id: "orbstack-disk-image",
      pattern: "~/Library/Group Containers/*.orbstack/data.img",
      reason: "OrbStack disk images contain virtual machines, containers, and volumes."
    ),
    NeverRule(
      id: "parallels-images",
      pattern: "~/**/*.pvm/**",
      reason: "Parallels virtual machine bundles contain complete guest systems and user data."
    ),
    NeverRule(
      id: "utm-images",
      pattern: "~/**/*.utm/**",
      reason: "UTM virtual machine bundles contain complete guest systems and user data."
    ),
    NeverRule(
      id: "vmware-images",
      pattern: "~/**/*.vmwarevm/**",
      reason: "VMware virtual machine bundles contain complete guest systems and user data."
    ),
    NeverRule(
      id: "sparse-bundles",
      pattern: "~/**/*.sparsebundle/**",
      reason: "Sparse bundles may contain encrypted disks, backups, virtual machines, or other user data."
    ),
    NeverRule(
      id: "sparse-images",
      pattern: "~/**/*.sparseimage",
      reason: "Sparse disk images may contain encrypted disks, backups, virtual machines, or other user data."
    ),
    NeverRule(
      id: "maven-repository",
      pattern: "~/.m2/repository/**",
      reason: "The Maven local repository may contain locally built artifacts that cannot be downloaded again."
    ),
    NeverRule(
      id: "mail",
      pattern: "~/Library/Mail/**",
      reason: "Mail data and attachments may be the only local copies of user content."
    ),
    NeverRule(
      id: "messages",
      pattern: "~/Library/Messages/**",
      reason: "Messages data and attachments may be the only local copies of user content."
    ),
    NeverRule(
      id: "mobile-documents",
      pattern: "~/Library/Mobile Documents/**",
      reason: "Deleting iCloud Drive content locally can also delete its cloud copy."
    ),
    NeverRule(
      id: "cloud-storage",
      pattern: "~/Library/CloudStorage/**",
      reason: "Deleting File Provider content locally can also delete its cloud copy."
    ),
    NeverRule(
      id: "mobile-sync",
      pattern: "~/Library/Application Support/MobileSync/**",
      reason: "iPhone and iPad backups may be the only available copies of device data.",
      evidence: "Manage these backups in Finder."
    ),
    NeverRule(
      id: "container-documents",
      pattern: "~/Library/Containers/*/Data/Documents/**",
      reason: "Application container Documents folders contain user-created data."
    ),
    NeverRule(
      id: "group-containers",
      pattern: "~/Library/Group Containers/**",
      reason: "Group containers hold shared application state and user data."
    ),
    NeverRule(
      id: "keychains",
      pattern: "~/Library/Keychains/**",
      reason: "Keychains contain credentials, certificates, and encryption keys."
    ),
    NeverRule(
      id: "ssh",
      pattern: "~/.ssh/**",
      reason: "SSH configuration and private keys are security credentials that may be irreplaceable."
    ),
    NeverRule(
      id: "core-simulator-volumes",
      pattern: "~/Library/Developer/CoreSimulator/Volumes/**",
      reason: "Mounted simulator runtime volumes are managed by CoreSimulator and must not be edited directly."
    ),
  ]
}
