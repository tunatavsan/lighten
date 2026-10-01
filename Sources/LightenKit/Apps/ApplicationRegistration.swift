import CoreServices
import Darwin
import Foundation

/// Registry paths are discovery leads. A current no-follow bundle read is
/// required before any lead becomes an installed application observation.
struct ApplicationRegistrationObservation: Sendable {
  let paths: [String]
  let complete: Bool
}

enum ApplicationRegistration {
  static let executable =
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  static func isInstalled(bundleID: String) -> Bool {
    registeredPaths(bundleID: bundleID)?.contains { path in
      !isTrash(path) && FileManager.default.fileExists(atPath: RelatedDataService.infoPlistPath(ofBundleAt: path))
    } ?? true
  }

  static func registeredPaths(bundleID: String) -> [String]? {
    var error: Unmanaged<CFError>?
    guard let result = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, &error) else {
      guard let error = error?.takeRetainedValue() else { return [] }
      return CFErrorGetCode(error) == Int(kLSApplicationNotFoundErr) ? [] : nil
    }
    guard let urls = result.takeRetainedValue() as? [URL] else { return nil }
    return urls.map(\.path).filter { !isTrash($0) }.sorted()
  }

  static func isTrash(_ path: String) -> Bool {
    let home = NSHomeDirectory()
    let aliases = [home, "/System/Volumes/Data" + home]
    return aliases.contains { path == $0 + "/.Trash" || path.hasPrefix($0 + "/.Trash/") }
      || path.contains("/.Trashes/")
  }

  /// Path-name syntax only; metadata and action eligibility are checked later.
  static func hasApplicationSuffix(_ path: String) -> Bool {
    (path as NSString).lastPathComponent.lowercased(with: Locale(identifier: "en_US_POSIX")).hasSuffix(".app")
  }

  static func parseDump(_ output: String) -> ApplicationRegistrationObservation {
    var paths: Set<String> = []
    var sawPath = false
    var complete = true
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = line.trimmingCharacters(in: .whitespaces)
      guard text.hasPrefix("path:") else { continue }
      sawPath = true
      var path = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
      if let annotation = path.range(of: " (0x", options: .backwards), !hasApplicationSuffix(path) {
        guard path.hasSuffix(")") else {
          complete = false
          continue
        }
        let hex = path[annotation.upperBound..<path.index(before: path.endIndex)]
        guard !hex.isEmpty, hex.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else {
          complete = false
          continue
        }
        path = String(path[..<annotation.lowerBound])
      }
      guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 }),
        (try? DescriptorFileSystem.validatedComponents(path)) != nil
      else {
        complete = false
        continue
      }
      if hasApplicationSuffix(path), !isTrash(path) {
        // Registered nested helpers are code owned by their outer package,
        // rather than additional installed rows or independent group owners.
        let components = path.split(separator: "/")
        if let outer = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
          paths.insert("/" + components[...outer].joined(separator: "/"))
        }
      }
    }
    return ApplicationRegistrationObservation(paths: paths.sorted(), complete: complete && sawPath)
  }

  /// Read-only enumeration with bounded output and runtime. No shell, launch,
  /// registration or unregistration command is used.
  static func observe(timeout: TimeInterval = 10, maximumBytes: Int = 64 * 1024 * 1024)
    -> ApplicationRegistrationObservation
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-dump"]
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let fd = pipe.fileHandleForReading.fileDescriptor
    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
      return ApplicationRegistrationObservation(paths: [], complete: false)
    }
    do { try process.run() } catch { return ApplicationRegistrationObservation(paths: [], complete: false) }
    try? pipe.fileHandleForWriting.close()
    defer {
      if process.isRunning {
        process.terminate()
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      }
      process.waitUntilExit()
      try? pipe.fileHandleForReading.close()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var output = Data()
    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
    while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
      let count = read(fd, &bytes, bytes.count)
      if count > 0 {
        guard output.count + count <= maximumBytes else {
          return ApplicationRegistrationObservation(paths: [], complete: false)
        }
        output.append(contentsOf: bytes.prefix(count))
      } else if count == 0 {
        guard !process.isRunning else { continue }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else {
          return ApplicationRegistrationObservation(paths: [], complete: false)
        }
        return parseDump(text)
      } else if errno != EAGAIN && errno != EINTR {
        return ApplicationRegistrationObservation(paths: [], complete: false)
      } else {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        _ = poll(&descriptor, 1, 25)
      }
    }
    return ApplicationRegistrationObservation(paths: [], complete: false)
  }
}
