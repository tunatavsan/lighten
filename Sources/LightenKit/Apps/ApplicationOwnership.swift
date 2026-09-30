import Darwin
import Foundation

/// A signed code location and the installed package to which it belongs.
/// Nested helpers belong to their containing package, rather than becoming a
/// second independent owner of that package's application-group data.
public struct ApplicationOwnerCandidate: Sendable, Equatable {
  public let path: String
  public let packagePath: String

  public init(path: String, packagePath: String) {
    self.path = path
    self.packagePath = packagePath
  }
}

struct ApplicationOwnershipInventory {
  let candidates: [ApplicationOwnerCandidate]
  let complete: Bool

  static func collect(roots: [String], applications: [InstalledApplication]) -> Self {
    var candidates: [ApplicationOwnerCandidate] = []
    var seen: Set<String> = []
    var visitedDirectories: Set<String> = []
    var complete = true
    var visited = 0
    let limit = 2_000_000
    let codeSuffixes = [".app", ".appex", ".xpc", ".bundle", ".plugin", ".framework"]

    func add(_ path: String, package: String) {
      if seen.insert(path).inserted { candidates.append(ApplicationOwnerCandidate(path: path, packagePath: package)) }
    }

    func visit(_ path: String, package: String?, mainExecutable: String?, depth: Int) {
      guard visitedDirectories.insert(path).inserted else { return }
      guard !Task.isCancelled, depth <= 128, visited < limit,
        let identity = try? DescriptorFileSystem.identity(at: path), identity.kind == .directory,
        identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
        let children = try? DescriptorFileSystem.children(at: path, expected: identity)
      else {
        complete = false
        return
      }
      visited += children.count
      let folded = (path as NSString).lastPathComponent.lowercased(with: Locale(identifier: "en_US_POSIX"))
      let isCodeBundle = codeSuffixes.contains { folded.hasSuffix($0) }
      let owningPackage = package ?? (isCodeBundle ? path : nil)
      var executable = mainExecutable
      if isCodeBundle, let owner = owningPackage {
        add(path, package: owner)
        executable = ApplicationIdentity.executablePath(ofBundleAt: path)
      }
      for name in children {
        let childPath = path + "/" + name
        guard let child = try? DescriptorFileSystem.identity(at: childPath), child.device == identity.device,
          child.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
        else {
          complete = false
          continue
        }
        switch child.kind {
        case .directory:
          visit(childPath, package: owningPackage, mainExecutable: executable, depth: depth + 1)
        case .symbolicLink:
          guard let resolved = realpath(childPath, nil) else {
            complete = false
            continue
          }
          let target = String(cString: resolved)
          free(resolved)
          guard let targetIdentity = try? DescriptorFileSystem.identity(at: target) else {
            complete = false
            continue
          }
          if targetIdentity.kind == .directory {
            // Follow code hidden behind helper-directory links read-only. A
            // physical directory is visited once, including framework versions.
            visit(
              target, package: target.hasPrefix((owningPackage ?? "") + "/") ? owningPackage : target,
              mainExecutable: nil, depth: depth + 1)
          } else if targetIdentity.kind == .regular, isNativeExecutable(target) {
            let owner = target.hasPrefix((owningPackage ?? "") + "/") ? owningPackage : nil
            add(target, package: owner ?? target)
          }
        case .regular:
          if childPath != executable, isNativeExecutable(childPath) {
            add(childPath, package: owningPackage ?? childPath)
          }
        case .other: break
        }
      }
    }
    for root in roots {
      do {
        let identity = try DescriptorFileSystem.identity(at: root)
        guard identity.kind == .directory else {
          complete = false
          continue
        }
        visit(root, package: nil, mainExecutable: nil, depth: 0)
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
        continue
      } catch { complete = false }
    }
    for app in applications {
      let physical = app.linkTarget ?? app.path
      if !seen.contains(physical) { visit(physical, package: app.path, mainExecutable: nil, depth: 0) }
      if physical != app.path {
        candidates = candidates.map {
          $0.packagePath == physical ? ApplicationOwnerCandidate(path: $0.path, packagePath: app.path) : $0
        }
      }
    }
    return Self(candidates: candidates.sorted { $0.path < $1.path }, complete: complete)
  }

  private static func isNativeExecutable(_ path: String) -> Bool {
    guard let (parent, name) = try? DescriptorFileSystem.openParent(of: path) else { return false }
    defer { close(parent) }
    let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
      details.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
    else { return false }
    var magic: UInt32 = 0
    guard read(fd, &magic, MemoryLayout<UInt32>.size) == MemoryLayout<UInt32>.size else { return false }
    return [0xfeed_face, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe, 0xcafe_babe, 0xbeba_feca, 0xcafe_babf, 0xbfba_feca]
      .contains(magic)
  }
}
