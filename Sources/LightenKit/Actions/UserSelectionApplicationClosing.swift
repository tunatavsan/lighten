import AppKit
import CLightenPlatform
import Darwin
import Foundation

public protocol UserSelectionApplicationClosing: Sendable {
  /// Graceful application quit includes executable-location-proven helpers.
  /// A force step is permitted only after the user's close-and-remove choice.
  func closeApplications(rootPath: String, forceAfterGraceful: Bool) async throws
}

public struct NativeUserSelectionApplicationClosing: UserSelectionApplicationClosing {
  public init() {}

  public func closeApplications(rootPath: String, forceAfterGraceful: Bool) async throws {
    try UserSelectionSafety.validateBase(rootPath, homeDirectory: NSHomeDirectory())
    if try UserSelectionFileSystem.identity(at: rootPath).kind == .symbolicLink { return }
    guard let resolved = realpath(rootPath, nil) else { throw ProcessActivityFailure.unavailable }
    let physicalRoot = String(cString: resolved)
    free(resolved)
    let records = try await Task.detached(priority: .utility) {
      var pointer: UnsafeMutablePointer<LightenApplicationProcess>?
      var count: UInt32 = 0
      let result = physicalRoot.withCString { lighten_copy_application_processes($0, &pointer, &count) }
      defer { lighten_free_application_processes(pointer) }
      guard result == 0 else { throw ProcessActivityFailure.unavailable }
      return Array(UnsafeBufferPointer(start: pointer, count: Int(count)))
    }.value
    for record in records {
      var observed = record
      let quit = await MainActor.run {
        var nativeRecord = record
        // A PID alone or a bundle identifier cannot authorize application quit.
        guard lighten_validate_application_process(&nativeRecord) == 0 else { return false }
        return NSRunningApplication(processIdentifier: record.pid)?.terminate() ?? false
      }
      if !quit {
        guard lighten_signal_application_process(&observed, SIGTERM) == 0 else {
          throw ProcessActivityFailure.unavailable
        }
      }
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      let live = records.contains { kill($0.pid, 0) == 0 || errno == EPERM }
      if !live { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard forceAfterGraceful else { throw ProcessActivityFailure.active(processNames: []) }
    for var record in records {
      guard lighten_signal_application_process(&record, SIGKILL) == 0 else {
        throw ProcessActivityFailure.unavailable
      }
    }
    let forcedDeadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < forcedDeadline {
      let activity = await NativeApplicationActivitySource().activity(applicationPath: physicalRoot)
      switch activity.state {
      case .clearObservedProcesses: return
      case .unknown: throw ProcessActivityFailure.unavailable
      case .active: try await Task.sleep(for: .milliseconds(50))
      }
    }
    throw ProcessActivityFailure.active(processNames: [])
  }
}
