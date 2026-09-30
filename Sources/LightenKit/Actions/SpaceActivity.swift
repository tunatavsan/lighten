import AppKit
import CLightenPlatform
import Foundation
import IOKit

public protocol SpaceActivitySource: Sendable {
  func activity(rootPath: String) async -> ProcessActivity
}

/// Observes only current-user vnode descriptors and working directories.
public struct NativeSpaceActivitySource: SpaceActivitySource {
  public init() {}
  public func activity(rootPath: String) async -> ProcessActivity {
    await Task.detached(priority: .utility) {
      var name = [CChar](repeating: 0, count: 256)
      let state = rootPath.withCString { root in
        name.withUnsafeMutableBufferPointer { lighten_process_activity(root, $0.baseAddress, $0.count) }
      }
      let description = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      return ProcessActivity(
        state: state == 0 ? .clearObservedCurrentUID : state == 1 ? .active : .unknown,
        processNames: description.isEmpty ? [] : [description])
    }.value
  }
}

public struct NativeRunningApplicationSource: RunningApplicationSource {
  public init() {}
  public func isRunning(bundleID: String) async -> Bool? {
    await MainActor.run {
      NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
      }
    }
  }
}

public enum MountedImageState: Sendable, Equatable { case attached, detached, unknown }

public protocol MountedImageSource: Sendable {
  func state(imagePath: String) async -> MountedImageState
}

/// Reads the disk-image device registry directly. Attached images are refused,
/// including attachments without a mounted filesystem. Missing registry facts
/// never count as an observation that an image is detached.
public struct NativeMountedImageSource: MountedImageSource {
  public init() {}
  public func state(imagePath: String) async -> MountedImageState {
    await Task.detached(priority: .utility) { Self.observe(imagePath: imagePath) }.value
  }

  private static func observe(imagePath: String) -> MountedImageState {
    guard let selected = try? DescriptorFileSystem.identity(at: imagePath) else { return .unknown }
    var unknown = false
    for (className, property) in [("AppleDiskImageDevice", "DiskImageURL"), ("IOHDIXHDDrive", "image-path")] {
      guard let matching = IOServiceMatching(className) else { return .unknown }
      var iterator: io_iterator_t = 0
      guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return .unknown
      }
      guard iterator != 0 else { continue }
      defer { IOObjectRelease(iterator) }
      while true {
        let device = IOIteratorNext(iterator)
        guard device != 0 else { break }
        defer { IOObjectRelease(device) }
        guard let value = IORegistryEntryCreateCFProperty(device, property as CFString, kCFAllocatorDefault, 0),
          let path = imagePathValue(value.takeRetainedValue(), urlProperty: property == "DiskImageURL")
        else {
          unknown = true
          continue
        }
        if path.caseInsensitiveCompare(imagePath) == .orderedSame { return .attached }
        var details = stat()
        if stat(path, &details) == 0 {
          if UInt64(details.st_dev) == selected.device && details.st_ino == selected.inode { return .attached }
        } else {
          unknown = true
        }
      }
      if IOIteratorIsValid(iterator) == 0 { unknown = true }
    }
    return unknown ? .unknown : .detached
  }

  static func imagePathValue(_ value: Any, urlProperty: Bool) -> String? {
    if urlProperty {
      guard let text = value as? String, let url = URL(string: text), url.isFileURL,
        url.host == nil || url.host == "" || url.host == "localhost", url.path.hasPrefix("/")
      else { return nil }
      return url.path
    }
    guard let data = value as? Data, !data.isEmpty,
      let text = String(data: data.prefix { $0 != 0 }, encoding: .utf8), text.hasPrefix("/")
    else { return nil }
    return text
  }
}

extension ProtectionPolicy {
  static func relatedApplicationIDs(for entries: [ScanEntry], homeDirectory: String) -> [String] {
    let identities: [String: [String]] = [
      "utm-images": ["com.utmapp.UTM"],
      "parallels-images": ["com.parallels.desktop.console"],
      "vmware-images": ["com.vmware.fusion"],
      "docker-disk-image": ["com.docker.docker"],
      "orbstack-disk-image": ["dev.kdrag0n.OrbStack"],
    ]
    return Array(
      Set(
        entries.flatMap { entry in
          rules(for: entry.path, homeDirectory: homeDirectory).flatMap { identities[$0.id] ?? [] }
        })
    ).sorted()
  }

  static func sparseImageRoots(in entries: [ScanEntry], homeDirectory: String) -> [String] {
    let paths = entries.filter {
      rules(for: $0.path, homeDirectory: homeDirectory).contains {
        $0.id == "sparse-bundles" || $0.id == "sparse-images"
      }
    }.map(\.path).sorted()
    var roots: [String] = []
    for path in paths where !roots.contains(where: { path.hasPrefix($0 + "/") }) { roots.append(path) }
    return roots
  }
}
