import CoreServices
import Darwin
import Foundation
import Synchronization

private final class EventObservation: Sendable {
  struct Event: Sendable {
    let path: String
    let flags: UInt32
    let id: UInt64
    let receivedAt: UInt64
  }
  let events = Mutex<[Event]>([])
}

private let benchEventCallback: FSEventStreamCallback = { _, context, count, paths, flags, ids in
  guard let context else { return }
  let observation = Unmanaged<EventObservation>.fromOpaque(context).takeUnretainedValue()
  let names = unsafeBitCast(paths, to: NSArray.self)
  let receivedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  observation.events.withLock { events in
    for index in 0..<count {
      guard let path = names[index] as? String else { continue }
      events.append(EventObservation.Event(path: path, flags: flags[index], id: ids[index], receivedAt: receivedAt))
    }
  }
}

extension Bench {
  /// With no root, creates one owned change and waits for the real event stream.
  /// A supplied root is observed without writing to it.
  static func fileEvents(root: String?, duration: Double) async -> [String: Any] {
    let before = ProcessSample.now()
    var result: [String: Any] = ["completed": false, "suppliedRootReadOnly": root != nil]
    var fixture: OwnedFixture?
    do {
      let watched: String
      if let root {
        guard root.hasPrefix("/") else { throw FileSystemFailureDescription("event root must be an absolute path") }
        var details = stat()
        guard lstat(root, &details) == 0 else {
          throw FileSystemFailureDescription(
            "event root lstat failed (errno \(errno)): \(String(cString: strerror(errno)))")
        }
        guard details.st_mode & S_IFMT == S_IFDIR else {
          throw FileSystemFailureDescription("event root is not a directory")
        }
        watched = root
      } else {
        let owned = try OwnedFixture()
        fixture = owned
        watched = owned.directory
        result["fixtureDirectory"] = owned.directory
      }
      result["root"] = watched
      let observation = EventObservation()
      let retained = Unmanaged.passRetained(observation)
      defer { retained.release() }
      var context = FSEventStreamContext(
        version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil)
      let flags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
          | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
      guard
        let stream = FSEventStreamCreate(
          nil, benchEventCallback, &context, [watched] as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
      else { throw FileSystemFailureDescription("FSEventStreamCreate failed") }
      let queue = DispatchQueue(label: "app.lighten.bench.events")
      FSEventStreamSetDispatchQueue(stream, queue)
      defer {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {}
        FSEventStreamRelease(stream)
      }
      guard FSEventStreamStart(stream) else { throw FileSystemFailureDescription("FSEventStreamStart failed") }
      let changedAt: UInt64?
      let probePath: String?
      if fixture != nil {
        let path = watched + "/event-probe.txt"
        probePath = path
        changedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try Data("owned event probe".utf8).write(to: URL(fileURLWithPath: path))
      } else {
        probePath = nil
        changedAt = nil
      }
      let interval = duration.isFinite ? max(0.1, min(duration, 60)) : 2
      try await Task.sleep(for: .seconds(interval))
      FSEventStreamFlushSync(stream)
      queue.sync {}
      let events = observation.events.withLock { $0 }
      let probeEvent = probePath.flatMap { path in events.first { $0.path == path } }
      result["eventCount"] = events.count
      result["events"] = events.map { ["path": $0.path, "flags": $0.flags, "eventID": $0.id] as [String: Any] }
      result["ownedChangeObserved"] = probePath == nil ? NSNull() : probeEvent != nil
      if let changedAt, let probeEvent {
        result["deliverySeconds"] = seconds(from: changedAt, to: probeEvent.receivedAt)
      }
      result["completed"] = probePath == nil || probeEvent != nil
      if probePath != nil && probeEvent == nil {
        result["error"] = "owned change was not delivered before observation ended"
      }
      result["streamLastEventID"] = FSEventStreamGetLatestEventId(stream)
    } catch {
      result["error"] = String(describing: error)
    }
    if let fixture {
      do {
        try fixture.remove()
        result["fixtureRemoved"] = true
      } catch {
        result["fixtureRemoved"] = false
        result["cleanupError"] = String(describing: error)
        result["completed"] = false
      }
    }
    result["observationSeconds"] = seconds(from: before.wall, to: ProcessSample.now().wall)
    return result
  }
}
