import Darwin
import Foundation
import Synchronization

/// Ownership walks and native registration can block. A serial dispatch lane
/// keeps that work outside Swift's cooperative executor without unbounded fan-out.
final class ApplicationOwnershipWork: Sendable {
  static let shared = ApplicationOwnershipWork(label: "com.tavsn.lighten.application-ownership")
  private let queue: DispatchQueue

  init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }

  private final class Pending<Value: Sendable>: Sendable {
    private struct State {
      var cancelled = false
      var continuation: CheckedContinuation<Value, any Error>?
    }
    private let state = Mutex(State())
    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func start(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
      state.withLock {
        guard !$0.cancelled else { return false }
        $0.continuation = continuation
        return true
      }
    }

    func cancel() {
      let continuation = state.withLock {
        $0.cancelled = true
        let continuation = $0.continuation
        $0.continuation = nil
        return continuation
      }
      continuation?.resume(throwing: CancellationError())
    }

    func finish(_ value: Value) {
      let continuation = state.withLock {
        let continuation = $0.continuation
        $0.continuation = nil
        return continuation
      }
      continuation?.resume(returning: value)
    }
  }

  func perform<Value: Sendable>(
    _ work: @escaping @Sendable (@escaping @Sendable () -> Bool) -> Value
  ) async throws -> Value {
    let pending = Pending<Value>()
    let result = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard pending.start(continuation) else {
          continuation.resume(throwing: CancellationError())
          return
        }
        queue.async {
          guard !pending.isCancelled else { return }
          pending.finish(work { pending.isCancelled })
        }
      }
    } onCancel: {
      pending.cancel()
    }
    try Task.checkCancellation()
    return result
  }
}

private enum ApplicationOwnershipFailure: Error {
  case traversalLimitExceeded
}

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
  var metadataIssues: [ApplicationMetadataIssue] = []
  var thirdPartyComplete: Bool {
    issues.allSatisfy(\.systemScope) && metadataIssues.allSatisfy { $0.path.hasPrefix("/System/") }
  }

  static func collect(
    roots: [String], applications: [InstalledApplication], additionalCodePaths: [String] = [],
    onNativeRead: (@Sendable (String) -> Void)? = nil,
    cancelled: @Sendable () -> Bool = { false }
  ) -> Self {
    var candidates: [ApplicationOwnerCandidate] = []
    var seen: Set<String> = []
    var visitedDirectories: Set<String> = []
    var complete = true
    var issues: [ApplicationOwnershipIssue] = []
    var metadataIssues: [ApplicationMetadataIssue] = []
    var rootIdentities: [String: FileIdentity] = [:]
    var directoryIdentities: [String: FileIdentity] = [:]
    func unavailable(_ path: String, _ code: Int32) {
      complete = false
      let issue = ApplicationOwnershipIssue(path: path, code: code)
      if !issues.contains(issue) { issues.append(issue) }
    }
    func uncertain(_ path: String, _ error: any Error) {
      complete = false
      let issue = ApplicationMetadataIssue(path: path, error: error)
      if !metadataIssues.contains(issue) { metadataIssues.append(issue) }
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
      guard !Task.isCancelled, !cancelled() else {
        uncertain(path, CancellationError())
        return
      }
      guard depth <= 128, visited < limit else {
        uncertain(path, ApplicationOwnershipFailure.traversalLimitExceeded)
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
          unavailable(path, errno)
          return
        }
      } else {
        let opened: (Int32, String)
        do { opened = try DescriptorFileSystem.openParent(of: path) } catch FileSystemFailure.systemCall(_, let code) {
          unavailable(path, code)
          return
        } catch {
          uncertain(path, error)
          return
        }
        (parent, entryName) = opened
        ownsParent = true
      }
      defer { if ownsParent { close(parent) } }
      let directoryFD = openat(parent, entryName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
      guard directoryFD >= 0 else {
        unavailable(path, errno)
        return
      }
      defer { close(directoryFD) }
      var opened = stat()
      guard fstat(directoryFD, &opened) == 0 else {
        unavailable(path, errno)
        return
      }
      let identity = DescriptorFileSystem.identity(from: opened)
      guard identity.kind == .directory, expected == nil || expected == identity,
        identity.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
        (try? DescriptorFileSystem.identity(name: entryName, relativeTo: parent)) == identity
      else {
        uncertain(path, FileSystemFailure.changedDuringInspection)
        return
      }
      let children: [String]
      do { children = try names(relativeTo: directoryFD) } catch FileSystemFailure.systemCall(_, let code) {
        unavailable(path, code)
        return
      } catch {
        uncertain(path, error)
        return
      }
      directoryIdentities[path] = identity
      visited += children.count
      guard visited <= limit else {
        uncertain(path, ApplicationOwnershipFailure.traversalLimitExceeded)
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
        if Task.isCancelled || cancelled() {
          uncertain(path, CancellationError())
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
          uncertain(childPath, RelatedFailure.unsupportedInstalledData)
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
          let targetIdentity: FileIdentity
          do { targetIdentity = try DescriptorFileSystem.identity(at: target) } catch FileSystemFailure.systemCall(
            _, let code)
          {
            unavailable(childPath, code)
            continue
          } catch {
            uncertain(childPath, error)
            continue
          }
          if targetIdentity.kind == .directory {
            // Follow code hidden behind helper-directory links read-only. A
            // physical directory is visited once, including framework versions.
            visit(
              target, package: target.hasPrefix((owningPackage ?? "") + "/") ? owningPackage : target,
              mainExecutable: nil, depth: depth + 1, expected: targetIdentity)
          } else if targetIdentity.kind == .regular {
            do {
              let (targetParent, targetName) = try DescriptorFileSystem.openParent(of: target)
              defer { close(targetParent) }
              let native = try isNativeExecutable(
                name: targetName, relativeTo: targetParent, expected: targetIdentity,
                onRead: { onNativeRead?(target) })
              if native {
                let owner = target.hasPrefix((owningPackage ?? "") + "/") ? owningPackage : nil
                add(target, package: owner ?? target)
              }
            } catch FileSystemFailure.systemCall(_, let code) { unavailable(childPath, code) } catch {
              uncertain(childPath, error)
            }
          }
          if (try? DescriptorFileSystem.identity(name: name, relativeTo: directoryFD)) != child {
            uncertain(childPath, FileSystemFailure.changedDuringInspection)
          }
        case .regular:
          if name.hasSuffix(".plist"), path.hasSuffix("/LaunchAgents") || path.hasSuffix("/LaunchDaemons") {
            do {
              guard let data = try SecureMetadataFile.read(path: childPath, limit: 1024 * 1024, ownerOnly: false),
                let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
              else {
                uncertain(childPath, ApplicationMetadataFailure.invalidInfoPlist)
                continue
              }
              if let program = (value["Program"] as? String) ?? (value["ProgramArguments"] as? [String])?.first {
                guard program.hasPrefix("/"), (try? DescriptorFileSystem.validatedComponents(program)) != nil else {
                  uncertain(childPath, FileSystemFailure.invalidPath)
                  continue
                }
                // A launch record is a read-only lead. Inspect the physical
                // code behind executable links; action paths never follow it.
                guard let resolved = realpath(program, nil) else {
                  if errno != ENOENT { unavailable(program, errno) }
                  continue
                }
                let physical = String(cString: resolved)
                free(resolved)
                let target = try DescriptorFileSystem.identity(at: physical)
                guard target.kind == .regular else { continue }
                let (targetParent, targetName) = try DescriptorFileSystem.openParent(of: physical)
                defer { close(targetParent) }
                let native = try isNativeExecutable(
                  name: targetName, relativeTo: targetParent, expected: target,
                  onRead: { onNativeRead?(physical) })
                guard let checked = realpath(program, nil) else {
                  unavailable(program, errno)
                  continue
                }
                let currentPhysical = String(cString: checked)
                free(checked)
                guard currentPhysical == physical else { throw FileSystemFailure.changedDuringInspection }
                if native {
                  let app = applications.first { physical.hasPrefix(($0.linkTarget ?? $0.path) + "/") }
                  add(physical, package: app?.path ?? physical)
                }
              }
              if (try? DescriptorFileSystem.identity(name: name, relativeTo: directoryFD)) != child {
                uncertain(childPath, FileSystemFailure.changedDuringInspection)
              }
            } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
              // A removed executable cannot own a current application group.
              continue
            } catch FileSystemFailure.systemCall(_, let code) { unavailable(childPath, code) } catch {
              uncertain(childPath, error)
            }
          }
          if childPath != executable {
            do {
              let native = try isNativeExecutable(
                name: name, relativeTo: directoryFD, expected: child, mode: childDetails.st_mode,
                onRead: { onNativeRead?(childPath) })
              if native { add(childPath, package: owningPackage ?? childPath) }
            } catch FileSystemFailure.systemCall(_, let code) { unavailable(childPath, code) } catch {
              uncertain(childPath, error)
            }
          }
        case .other: break
        }
      }
      var finished = stat()
      if fstat(directoryFD, &finished) != 0 {
        unavailable(path, errno)
      } else if DescriptorFileSystem.identity(from: finished) != identity
        || (try? DescriptorFileSystem.identity(name: entryName, relativeTo: parent)) != identity
      {
        uncertain(path, FileSystemFailure.changedDuringInspection)
      }
    }
    for root in roots {
      if Task.isCancelled || cancelled() {
        uncertain(root, CancellationError())
        break
      }
      do {
        let identity = try DescriptorFileSystem.identity(at: root)
        guard identity.kind == .directory else {
          uncertain(root, RelatedFailure.unsupportedInstalledData)
          continue
        }
        rootIdentities[root] = identity
        visit(root, package: nil, mainExecutable: nil, depth: 0, expected: identity)
      } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
        continue
      } catch FileSystemFailure.systemCall(_, let code) { unavailable(root, code) } catch { uncertain(root, error) }
    }
    for app in applications {
      if Task.isCancelled || cancelled() {
        uncertain(app.path, CancellationError())
        break
      }
      let physical = app.linkTarget ?? app.path
      if !seen.contains(physical) { visit(physical, package: app.path, mainExecutable: nil, depth: 0) }
      if physical != app.path {
        candidates = candidates.map {
          $0.packagePath == physical ? ApplicationOwnerCandidate(path: $0.path, packagePath: app.path) : $0
        }
      }
    }
    for path in additionalCodePaths where !seen.contains(path) {
      if Task.isCancelled || cancelled() {
        uncertain(path, CancellationError())
        break
      }
      visit(path, package: path, mainExecutable: nil, depth: 0)
    }
    return Self(
      candidates: candidates.sorted { $0.path < $1.path }, complete: complete,
      issues: issues, roots: rootIdentities, directories: directoryIdentities, metadataIssues: metadataIssues)
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
  ) throws -> Bool {
    let mode: mode_t
    if let suppliedMode {
      mode = suppliedMode
    } else {
      var details = stat()
      guard fstatat(parent, name, &details, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
        throw FileSystemFailure.systemCall("fstatat", errno)
      }
      guard DescriptorFileSystem.identity(from: details) == expected else {
        throw FileSystemFailure.changedDuringInspection
      }
      mode = details.st_mode
    }
    guard mode & S_IFMT == S_IFREG else { throw FileSystemFailure.changedDuringInspection }
    guard mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else { return false }
    let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
    guard fd >= 0 else { throw FileSystemFailure.systemCall("openat", errno) }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0 else { throw FileSystemFailure.systemCall("fstat", errno) }
    guard DescriptorFileSystem.identity(from: details) == expected,
      details.st_mode & S_IFMT == S_IFREG
    else { throw FileSystemFailure.changedDuringInspection }
    onRead()
    var magic: UInt32 = 0
    let count = read(fd, &magic, MemoryLayout<UInt32>.size)
    guard count >= 0 else { throw FileSystemFailure.systemCall("read", errno) }
    var finished = stat()
    guard fstat(fd, &finished) == 0 else { throw FileSystemFailure.systemCall("fstat", errno) }
    guard DescriptorFileSystem.identity(from: finished) == expected,
      (try? DescriptorFileSystem.identity(name: name, relativeTo: parent)) == expected
    else { throw FileSystemFailure.changedDuringInspection }
    return details.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
      && count == MemoryLayout<UInt32>.size
      && [0xfeed_face, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe, 0xcafe_babe, 0xbeba_feca, 0xcafe_babf, 0xbfba_feca]
        .contains(magic)
  }
}
