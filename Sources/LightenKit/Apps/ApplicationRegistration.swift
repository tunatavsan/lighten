import CoreServices
import Darwin
import Foundation
import Synchronization

/// Registry paths are discovery leads. A current no-follow bundle read is
/// required before any lead becomes an installed application observation.
struct ApplicationRegistrationObservation: Sendable {
  let paths: [String]
  let complete: Bool
  var report: ApplicationRegistrationReport? = nil
}

public struct ApplicationRegistrationReport: Codable, Sendable {
  public let source: String
  public let leadCount: Int
  public let complete: Bool
  public let gatheringCompleted: Bool
  public let bootIndexingStatus: String
  public let externalVolumesUnchecked: Bool
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
      // LaunchServices also registers volumes and directories. The root has
      // no application namespace to authenticate and is an irrelevant record.
      if path == "/" { continue }
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

  static func indexingStatus() -> String {
    guard
      let bytes = query(
        executable: "/usr/bin/mdutil", arguments: ["-s", "/"], timeout: 3, maximumBytes: 64 * 1024),
      let text = String(data: bytes, encoding: .utf8)
    else { return "unavailable" }
    let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines.first == "/:", lines.count == 2 else { return "unavailable" }
    if lines[1] == "Indexing enabled." { return "enabled" }
    if lines[1] == "Indexing disabled." { return "disabled" }
    return "unavailable"
  }

  /// A bounded background-thread query. Metadata results remain path leads;
  /// the caller authenticates every package through native no-follow reads.
  private static func spotlight(timeout: TimeInterval = 5, maximumResults: Int = 50_000)
    -> ApplicationRegistrationObservation
  {
    guard !Thread.isMainThread else { return ApplicationRegistrationObservation(paths: [], complete: false) }
    let query = NSMetadataQuery()
    query.predicate = NSPredicate(format: "kMDItemContentTypeTree == %@", "com.apple.application-bundle")
    query.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
    let gathered = Mutex(false)
    let token = NotificationCenter.default.addObserver(
      forName: Notification.Name.NSMetadataQueryDidFinishGathering, object: query, queue: nil
    ) { _ in gathered.withLock { $0 = true } }
    defer {
      query.stop()
      NotificationCenter.default.removeObserver(token)
    }
    guard query.start() else { return ApplicationRegistrationObservation(paths: [], complete: false) }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !gathered.withLock({ $0 }), !Task.isCancelled,
      ProcessInfo.processInfo.systemUptime < deadline, query.resultCount <= maximumResults
    {
      _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.025))
    }
    query.disableUpdates()
    guard gathered.withLock({ $0 }), query.resultCount <= maximumResults else {
      return ApplicationRegistrationObservation(paths: [], complete: false)
    }
    var paths: Set<String> = []
    var complete = true
    for index in 0..<query.resultCount {
      guard let item = query.result(at: index) as? NSMetadataItem,
        let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
        (try? DescriptorFileSystem.validatedComponents(path)) != nil, hasApplicationSuffix(path)
      else {
        complete = false
        continue
      }
      if !isTrash(path) { paths.insert(path) }
    }
    return ApplicationRegistrationObservation(paths: paths.sorted(), complete: complete)
  }

  static func observe(
    readIndexingStatus: () -> String = indexingStatus,
    readSpotlight: () -> ApplicationRegistrationObservation = { spotlight() },
    readDump: () -> ApplicationRegistrationObservation = {
      guard
        let bytes = query(executable: executable, arguments: ["-dump"], timeout: 15, maximumBytes: 128 * 1024 * 1024),
        let text = String(data: bytes, encoding: .utf8)
      else { return ApplicationRegistrationObservation(paths: [], complete: false) }
      return parseDump(text)
    },
    byIdentifier: (String) -> [String]? = registeredPaths
  ) -> ApplicationRegistrationObservation {
    let status = readIndexingStatus()
    let indexed = status == "enabled" ? readSpotlight() : ApplicationRegistrationObservation(paths: [], complete: false)
    let source: String
    let observed: ApplicationRegistrationObservation
    if status == "enabled", indexed.complete {
      source = "public-spotlight"
      observed = indexed
    } else {
      let fallback = readDump()
      source = fallback.complete ? "launch-services-dump" : "unavailable"
      observed = fallback
    }
    var paths = Set(observed.paths)
    var complete = observed.complete
    var identifiers: Set<String> = []
    for path in observed.paths {
      let metadata = ApplicationMetadataObservation.read(at: path)
      if case .declaredID(let identifier) = metadata.state, RelatedDataService.validBundleID(identifier) {
        identifiers.insert(identifier)
      }
    }
    for identifier in identifiers {
      guard let registered = byIdentifier(identifier) else {
        complete = false
        continue
      }
      for path in registered {
        guard (try? DescriptorFileSystem.validatedComponents(path)) != nil, hasApplicationSuffix(path) else {
          complete = false
          continue
        }
        if !isTrash(path) { paths.insert(path) }
      }
    }
    return ApplicationRegistrationObservation(
      paths: paths.sorted(), complete: complete,
      report: ApplicationRegistrationReport(
        source: complete ? source : "unavailable", leadCount: paths.count, complete: complete,
        gatheringCompleted: status == "enabled" && indexed.complete, bootIndexingStatus: status,
        externalVolumesUnchecked: true))
  }

  /// Executes only fixed read-only registry/status queries with bounded output.
  private static func query(executable: String, arguments: [String], timeout: TimeInterval, maximumBytes: Int) -> Data?
  {
    guard !Thread.isMainThread,
      executable == "/usr/bin/mdutil" && arguments == ["-s", "/"]
        || executable == Self.executable && arguments == ["-dump"]
    else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let fd = pipe.fileHandleForReading.fileDescriptor
    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { return nil }
    do { try process.run() } catch { return nil }
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
        guard output.count + count <= maximumBytes else { return nil }
        output.append(contentsOf: bytes.prefix(count))
      } else if count == 0 {
        guard !process.isRunning else { continue }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? output : nil
      } else if errno != EAGAIN && errno != EINTR {
        return nil
      } else {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        _ = poll(&descriptor, 1, 25)
      }
    }
    return nil
  }
}
