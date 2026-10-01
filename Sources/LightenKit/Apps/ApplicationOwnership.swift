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

public struct ApplicationOwnershipIssue: Sendable, Equatable {
  public let path: String
  public let code: Int32
  public let systemScope: Bool

  public init(path: String, code: Int32) {
    self.path = path
    self.code = code
    self.systemScope = path == "/System" || path.hasPrefix("/System/")
  }
}

struct ApplicationOwnershipInventory {
  let candidates: [ApplicationOwnerCandidate]
  let complete: Bool
  let issues: [ApplicationOwnershipIssue]
  let roots: [String: FileIdentity]
  let directories: [String: FileIdentity]
  var thirdPartyComplete: Bool { issues.allSatisfy(\.systemScope) }

  static func collect(
    roots: [String], applications: [InstalledApplication],
    onNativeRead: (@Sendable (String) -> Void)? = nil
  ) -> Self {
    var candidates: [ApplicationOwnerCandidate] = []
    var seen: Set<String> = []
    var visitedDirectories: Set<String> = []
    var complete = true
    var issues: [ApplicationOwnershipIssue] = []
    var rootIdentities: [String: FileIdentity] = [:]
    var directoryIdentities: [String: FileIdentity] = [:]
    func unavailable(_ path: String, _ code: Int32 = EIO) {
      complete = false
      let issue = ApplicationOwnershipIssue(path: path, code: code)
      if !issues.contains(issue) { issues.append(issue) }
    }
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
      guard !Task.isCancelled else {
        unavailable(path, ECANCELED)
        return
      }
      guard depth <= 128, visited < limit else {
        unavailable(path, EOVERFLOW)
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
          unavailable(path, errno == 0 ? EIO : errno)
          return
        }
      } else {
        guard let opened = try? DescriptorFileSystem.openParent(of: path) else {
          unavailable(path, errno == 0 ? EIO : errno)
          return
        }
        (parent, entryName) = opened
        ownsParent = true
      }
      defer { if ownsParent { close(parent) } }
      let directoryFD = openat(parent, entryName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      guard directoryFD >= 0 else {
        unavailable(path, errno == 0 ? EIO : errno)
        return
      }
      defer { close(directoryFD) }
      var opened = stat()
      guard fstat(directoryFD, &opened) == 0 else {
        unavailable(path, errno == 0 ? EIO : errno)
        return
      }
      let identity = DescriptorFileSystem.identity(from: opened)
      guard identity.kind == .directory, expected == nil || expected == identity,
        identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
        (try? DescriptorFileSystem.identity(name: entryName, relativeTo: parent)) == identity
      else {
        unavailable(path, ESTALE)
        return
      }
      let children: [String]
      do { children = try names(relativeTo: directoryFD) } catch FileSystemFailure.systemCall(_, let code) {
        unavailable(path, code)
        return
      } catch {
        unavailable(path, EIO)
        return
      }
      directoryIdentities[path] = identity
      visited += children.count
      guard visited <= limit else {
        unavailable(path, EOVERFLOW)
        return
      }
      let folded = (path as NSString).lastPathComponent.lowercased(with: Locale(identifier: "en_US_POSIX"))
      let isCodeBundle = codeSuffixes.contains { folded.hasSuffix($0) }
      let owningPackage = package ?? (isCodeBundle ? path : nil)
      var executable = mainExecutable
      if isCodeBundle, let owner = owningPackage {
        add(path, package: owner)
        executable = ApplicationIdentity.executablePath(ofBundleAt: path)
      }
      for name in children {
        if Task.isCancelled {
          unavailable(path, ECANCELED)
          break
        }
        let childPath = path + "/" + name
        var childDetails = stat()
        guard fstatat(directoryFD, name, &childDetails, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
          unavailable(childPath, errno)
          continue
        }
        let child = DescriptorFileSystem.identity(from: childDetails)
        guard child.device == identity.device,
          child.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0
        else {
          unavailable(childPath, child.device != identity.device ? EXDEV : EACCES)
          continue
        }
        switch child.kind {
        case .directory:
          visit(
            childPath, package: owningPackage, mainExecutable: executable, depth: depth + 1,
            parentFD: directoryFD, name: name, expected: child)
        case .symbolicLink:
          guard let resolved = realpath(childPath, nil) else {
            // A dangling link contains no code or entitlement owner.
            if errno != ENOENT { unavailable(childPath, errno) }
            continue
          }
          let target = String(cString: resolved)
          free(resolved)
          guard let targetIdentity = try? DescriptorFileSystem.identity(at: target) else {
            unavailable(childPath, errno == 0 ? EIO : errno)
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
              unavailable(target, errno == 0 ? EIO : errno)
              continue
            }
            let native = isNativeExecutable(
              name: targetName, relativeTo: targetParent, expected: targetIdentity,
              onRead: { onNativeRead?(target) })
            close(targetParent)
            if let native {
              if native {
                let owner = target.hasPrefix((owningPackage ?? "") + "/") ? owningPackage : nil
                add(target, package: owner ?? target)
              }
            } else {
              unavailable(childPath, errno == 0 ? EIO : errno)
            }
          }
          if (try? DescriptorFileSystem.identity(name: name, relativeTo: directoryFD)) != child {
            unavailable(childPath, errno == 0 ? EIO : errno)
          }
        case .regular:
          if name.hasSuffix(".plist"), path.hasSuffix("/LaunchAgents") || path.hasSuffix("/LaunchDaemons") {
            do {
              guard let data = try SecureMetadataFile.read(path: childPath, limit: 1024 * 1024, ownerOnly: false),
                let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
              else {
                unavailable(childPath, EIO)
                continue
              }
              if let program = (value["Program"] as? String) ?? (value["ProgramArguments"] as? [String])?.first {
                guard program.hasPrefix("/"), (try? DescriptorFileSystem.validatedComponents(program)) != nil else {
                  unavailable(childPath, EINVAL)
                  continue
                }
                let target = try DescriptorFileSystem.identity(at: program)
                guard target.kind == .regular else {
                  unavailable(program, EINVAL)
                  continue
                }
                let (targetParent, targetName) = try DescriptorFileSystem.openParent(of: program)
                let native = isNativeExecutable(
                  name: targetName, relativeTo: targetParent, expected: target,
                  onRead: { onNativeRead?(program) })
                close(targetParent)
                if native == true {
                  let app = applications.first { program.hasPrefix(($0.linkTarget ?? $0.path) + "/") }
                  add(program, package: app?.path ?? program)
                } else if native == nil {
                  unavailable(program, errno == 0 ? EIO : errno)
                }
              }
              if (try? DescriptorFileSystem.identity(name: name, relativeTo: directoryFD)) != child {
                unavailable(childPath, ESTALE)
              }
            } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
              // A removed executable cannot own a current application group.
              continue
            } catch FileSystemFailure.systemCall(_, let code) { unavailable(childPath, code) } catch {
              unavailable(childPath, EIO)
            }
          }
          if childPath != executable {
            if let native = isNativeExecutable(
              name: name, relativeTo: directoryFD, expected: child, mode: childDetails.st_mode,
              onRead: { onNativeRead?(childPath) })
            {
              if native { add(childPath, package: owningPackage ?? childPath) }
            } else {
              unavailable(childPath, errno == 0 ? EIO : errno)
            }
          }
        case .other: break
        }
      }
      var finished = stat()
      if fstat(directoryFD, &finished) != 0 || DescriptorFileSystem.identity(from: finished) != identity
        || (try? DescriptorFileSystem.identity(name: entryName, relativeTo: parent)) != identity
      {
        unavailable(path, errno == 0 ? EIO : errno)
      }
    }
    for root in roots {
      do {
        let identity = try DescriptorFileSystem.identity(at: root)
        guard identity.kind == .directory else {
          unavailable(root, ENOTDIR)
          continue
        }
        rootIdentities[root] = identity
        visit(root, package: nil, mainExecutable: nil, depth: 0, expected: identity)
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
        continue
      } catch FileSystemFailure.systemCall(_, let code) { unavailable(root, code) } catch { unavailable(root) }
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
    return Self(
      candidates: candidates.sorted { $0.path < $1.path }, complete: complete,
      issues: issues, roots: rootIdentities, directories: directoryIdentities)
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

  private static func isNativeExecutable(
    name: String, relativeTo parent: Int32, expected: FileIdentity, mode suppliedMode: mode_t? = nil,
    onRead: () -> Void
  ) -> Bool? {
    let mode: mode_t
    if let suppliedMode {
      mode = suppliedMode
    } else {
      var details = stat()
      guard fstatat(parent, name, &details, AT_SYMLINK_NOFOLLOW_ANY) == 0,
        DescriptorFileSystem.identity(from: details) == expected
      else { return nil }
      mode = details.st_mode
    }
    guard mode & S_IFMT == S_IFREG else { return nil }
    guard mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else { return false }
    let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0, DescriptorFileSystem.identity(from: details) == expected,
      details.st_mode & S_IFMT == S_IFREG
    else { return nil }
    onRead()
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
