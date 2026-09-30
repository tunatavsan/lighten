import CoreServices
import Foundation
import Synchronization

/// The journal position belongs to the start of a scan, so changes during the
/// scan are replayed on the next visit as well.
public struct ScanReplayBaseline: Sendable, Equatable {
  public let eventID: UInt64
  public let volumeUUID: UUID

  public init(eventID: UInt64, volumeUUID: UUID) {
    self.eventID = eventID
    self.volumeUUID = volumeUUID
  }

  public static func capture(root: String) -> Self? {
    let path = root == "/" ? "/System/Volumes/Data" : root
    guard let uuid = try? DescriptorFileSystem.volumeID(at: path) else { return nil }
    return Self(eventID: FSEventsGetCurrentEventId(), volumeUUID: uuid)
  }
}

public struct FileEvent: Sendable, Equatable {
  public let path: String
  public let flags: UInt32
  public let id: UInt64

  public init(path: String, flags: UInt32, id: UInt64) {
    self.path = path
    self.flags = flags
    self.id = id
  }
}

public struct FileEventReplay: Sendable {
  public let events: [FileEvent]
  public let latestID: UInt64
  public let complete: Bool

  public init(events: [FileEvent], latestID: UInt64, complete: Bool = true) {
    self.events = events
    self.latestID = latestID
    self.complete = complete
  }
}

private final class ReplayObservation: Sendable {
  struct State {
    var events: [FileEvent] = []
    var complete = false
    var overflow = false
  }
  let state = Mutex(State())
  let finished = DispatchSemaphore(value: 0)
  func waitForHistory() { _ = finished.wait(timeout: .now() + 5) }
}

private let replayCallback: FSEventStreamCallback = { _, context, count, paths, flags, ids in
  guard let context else { return }
  let observation = Unmanaged<ReplayObservation>.fromOpaque(context).takeUnretainedValue()
  let names = unsafeBitCast(paths, to: NSArray.self)
  let done = observation.state.withLock { state -> Bool in
    for index in 0..<count {
      if flags[index] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
        state.complete = true
        continue
      }
      guard let path = names[index] as? String else { continue }
      if state.events.count < 50_001 {
        state.events.append(FileEvent(path: path, flags: flags[index], id: ids[index]))
      } else {
        state.overflow = true
      }
    }
    return state.complete || state.overflow
  }
  if done { observation.finished.signal() }
}

/// Historical replay only. The stream is stopped before returning and never
/// observes the app's open lifetime.
public enum FileEventsReplay {
  public static func replay(root: String, since eventID: UInt64) async -> FileEventReplay {
    await Task.detached(priority: .userInitiated) {
      let latest = FSEventsGetCurrentEventId()
      guard latest >= eventID else { return FileEventReplay(events: [], latestID: latest, complete: false) }
      if latest == eventID { return FileEventReplay(events: [], latestID: latest) }
      let observation = ReplayObservation()
      let retained = Unmanaged.passRetained(observation)
      defer { retained.release() }
      var context = FSEventStreamContext(
        version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil)
      let options = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
          | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
      let physical = root == "/" ? "/System/Volumes/Data" : root
      guard
        let stream = FSEventStreamCreate(
          nil, replayCallback, &context, [physical] as CFArray, eventID, 0.01, options)
      else { return FileEventReplay(events: [], latestID: latest, complete: false) }
      let queue = DispatchQueue(label: "app.lighten.events.replay")
      FSEventStreamSetDispatchQueue(stream, queue)
      defer {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {}
        FSEventStreamRelease(stream)
      }
      guard FSEventStreamStart(stream) else {
        return FileEventReplay(events: [], latestID: latest, complete: false)
      }
      observation.waitForHistory()
      FSEventStreamFlushSync(stream)
      queue.sync {}
      return observation.state.withLock {
        FileEventReplay(events: $0.events, latestID: latest, complete: $0.complete && !$0.overflow)
      }
    }.value
  }
}
