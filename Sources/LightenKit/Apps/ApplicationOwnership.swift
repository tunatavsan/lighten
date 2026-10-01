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

    func visit(
      _ path: String, package: String?, mainExecutable: String?, depth: Int,
      parentFD: Int32? = nil, name: String? = nil, expected: FileIdentity? = nil
    ) {
      guard visitedDirectories.insert(path).inserted else { return }
      guard !Task.isCancelled, depth <= 128, visited < limit else {
        complete = false
        return
      }
      let parent: Int32
      let entryName: String
      let ownsParent: Bool
      if let parentFD, let name {
        parent = parentFD
        entryName = name
        ownsParent = false
      } else if path == "/" {
        parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        entryName = "."
        ownsParent = true
        guard parent >= 0 else {
          complete = false
          return
        }
      } else {
        guard let opened = try? DescriptorFileSystem.openParent(of: path) else {
          complete = false
          return
        }
        (parent, entryName) = opened
        ownsParent = true
      }
      defer { if ownsParent { close(parent) } }
      let directoryFD = openat(parent, entryName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      guard directoryFD >= 0 else {
        complete = false
        return
      }
      defer { close(directoryFD) }
      var opened = stat()
      guard fstat(directoryFD, &opened) == 0 else {
        complete = false
        return
      }
      let identity = DescriptorFileSystem.identity(from: opened)
      guard identity.kind == .directory, expected == nil || expected == identity,
        identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
        (try? DescriptorFileSystem.identity(name: entryName, relativeTo: parent)) == identity,
        let children = try? names(relativeTo: directoryFD)
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
        guard let child = try? DescriptorFileSystem.identity(name: name, relativeTo: directoryFD),
          child.device == identity.device,
          child.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
        else {
          complete = false
          continue
        }
        switch child.kind {
        case .directory:
          visit(
            childPath, package: owningPackage, mainExecutable: executable, depth: depth + 1,
            parentFD: directoryFD, name: name, expected: child)
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
              mainExecutable: nil, depth: depth + 1, expected: targetIdentity)
          } else if targetIdentity.kind == .regular {
            guard let (targetParent, targetName) = try? DescriptorFileSystem.openParent(of: target) else {
              complete = false
              continue
            }
            let native = isNativeExecutable(name: targetName, relativeTo: targetParent, expected: targetIdentity)
            close(targetParent)
            if let native {
              if native {
                let owner = target.hasPrefix((owningPackage ?? "") + "/") ? owningPackage : nil
                add(target, package: owner ?? target)
              }
            } else {
              complete = false
            }
          }
          if (try? DescriptorFileSystem.identity(name: name, relativeTo: directoryFD)) != child {
            complete = false
          }
        case .regular:
          if childPath != executable {
            if let native = isNativeExecutable(name: name, relativeTo: directoryFD, expected: child) {
              if native { add(childPath, package: owningPackage ?? childPath) }
            } else {
              complete = false
            }
          }
        case .other: break
        }
      }
      var finished = stat()
      if fstat(directoryFD, &finished) != 0 || DescriptorFileSystem.identity(from: finished) != identity
        || (try? DescriptorFileSystem.identity(name: entryName, relativeTo: parent)) != identity
      {
        complete = false
      }
    }
    for root in roots {
      do {
        let identity = try DescriptorFileSystem.identity(at: root)
        guard identity.kind == .directory else {
          complete = false
          continue
        }
        visit(root, package: nil, mainExecutable: nil, depth: 0, expected: identity)
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

  private static func names(relativeTo fd: Int32) throws -> [String] {
    let copy = dup(fd)
    guard copy >= 0 else { throw FileSystemFailure.systemCall("dup", errno) }
    guard let directory = fdopendir(copy) else {
      let error = errno
      close(copy)
      throw FileSystemFailure.systemCall("fdopendir", error)
    }
    defer { closedir(directory) }
    var result: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        if errno != 0 { throw FileSystemFailure.systemCall("readdir", errno) }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name != "." && name != ".." { result.append(name) }
    }
    return result.sorted()
  }

  private static func isNativeExecutable(name: String, relativeTo parent: Int32, expected: FileIdentity) -> Bool? {
    let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0, DescriptorFileSystem.identity(from: details) == expected,
      details.st_mode & S_IFMT == S_IFREG
    else { return nil }
    var magic: UInt32 = 0
    let count = read(fd, &magic, MemoryLayout<UInt32>.size)
    guard count >= 0 else { return nil }
    var finished = stat()
    guard fstat(fd, &finished) == 0, DescriptorFileSystem.identity(from: finished) == expected,
      (try? DescriptorFileSystem.identity(name: name, relativeTo: parent)) == expected
    else { return nil }
    return details.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
      && count == MemoryLayout<UInt32>.size
      && [0xfeed_face, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe, 0xcafe_babe, 0xbeba_feca, 0xcafe_babf, 0xbfba_feca]
        .contains(magic)
  }
}
