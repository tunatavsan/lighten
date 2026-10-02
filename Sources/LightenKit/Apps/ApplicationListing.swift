import Darwin
import Foundation

/// A lightweight display row. It is not an installed-owner inventory or action proof.
public struct ApplicationListEntry: Sendable, Identifiable {
  public let path: String
  public let name: String
  public let bundleID: String?
  public let version: String?
  public let displayRootIdentity: FileIdentity?
  public var id: String { path }

  public init(
    path: String, name: String, bundleID: String?, version: String?, displayRootIdentity: FileIdentity?
  ) {
    self.path = path
    self.name = name
    self.bundleID = bundleID
    self.version = version
    self.displayRootIdentity = displayRootIdentity
  }
}

enum ApplicationListing {
  typealias Progress = @Sendable ([ApplicationListEntry]) -> Void
  typealias Collector = @Sendable (Progress?) -> [ApplicationListEntry]

  /// Only directory entry metadata and bounded Info.plist files are read.
  /// Unreadable or delayed rows can be filled by subsequent inventory events.
  static func observe(
    roots: [String], maximumEntries: Int = 50_000, timeBudget: Duration = .milliseconds(750),
    progress: Progress? = nil
  ) -> [ApplicationListEntry] {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeBudget)
    var rows: [String: ApplicationListEntry] = [:]
    var visited = 0
    var publishedCount = 0
    var lastPublishedAt = clock.now
    func publishProgress() {
      guard let progress,
        publishedCount == 0 || rows.count - publishedCount >= 16
          || lastPublishedAt.duration(to: clock.now) >= .milliseconds(50)
      else { return }
      progress(rows.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
      publishedCount = rows.count
      lastPublishedAt = clock.now
    }
    func entry(path: String, identity: FileIdentity) -> ApplicationListEntry {
      let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
      var info: [String: Any] = [:]
      if identity.kind == .directory {
        for relative in ["Contents/Info.plist", "Info.plist"] where clock.now < deadline && !Task.isCancelled {
          if let data = try? SecureMetadataFile.read(path: path + "/" + relative, limit: 1024 * 1024, ownerOnly: false),
            let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
              as? [String: Any]
          {
            info = value
            break
          }
        }
      }
      func text(_ key: String) -> String? {
        guard let value = info[key] as? String, !value.isEmpty else { return nil }
        return value
      }
      return ApplicationListEntry(
        path: path, name: text("CFBundleDisplayName") ?? text("CFBundleName") ?? fallback,
        bundleID: text("CFBundleIdentifier"), version: text("CFBundleShortVersionString") ?? text("CFBundleVersion"),
        displayRootIdentity: identity)
    }
    func walk(_ path: String, fd: Int32, depth: Int) {
      guard depth <= 16, visited < maximumEntries, clock.now < deadline, !Task.isCancelled else { return }
      let duplicate = dup(fd)
      guard duplicate >= 0 else { return }
      guard let directory = fdopendir(duplicate) else {
        close(duplicate)
        return
      }
      defer { closedir(directory) }
      while let pointer = readdir(directory), visited < maximumEntries, clock.now < deadline, !Task.isCancelled {
        var value = pointer.pointee
        let name = withUnsafePointer(to: &value.d_name) {
          $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
        }
        if name == "." || name == ".." || name.hasPrefix(".") { continue }
        visited += 1
        guard let identity = try? DescriptorFileSystem.identity(name: name, relativeTo: fd) else { continue }
        let child = path + "/" + name
        if name.lowercased().hasSuffix(".app"), identity.kind == .directory || identity.kind == .symbolicLink {
          rows[child] = entry(path: child, identity: identity)
          publishProgress()
        } else if identity.kind == .directory && !ScanService.isPackage(child) {
          let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
          guard next >= 0 else { continue }
          walk(child, fd: next, depth: depth + 1)
          close(next)
        }
      }
    }
    for root in Set(roots).sorted() where !Task.isCancelled && clock.now < deadline && visited < maximumEntries {
      guard let (fd, _) = try? DescriptorFileSystem.openParent(of: root + "/.listing") else { continue }
      walk(root, fd: fd, depth: 0)
      close(fd)
    }
    return rows.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
