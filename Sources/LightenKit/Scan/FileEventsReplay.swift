import CoreServices
import Darwin
import Foundation
import Synchronization

/// The journal position belongs to the start of a scan, so changes during the
/// scan are replayed on the next visit as well.
public struct ScanReplayBaseline: Sendable, Equatable {
  public let eventID: UInt64
  public let volumeUUID: UUID
  /// The FSEvents history store can change independently of the volume.
  public let storeUUID: UUID?

  public init(eventID: UInt64, volumeUUID: UUID, storeUUID: UUID? = nil) {
    self.eventID = eventID
    self.volumeUUID = volumeUUID
    self.storeUUID = storeUUID
  }

  public static func capture(root: String) -> Self? {
    capture(root: root, storeUUIDForDevice: eventStoreUUID)
  }

  static func capture(root: String, storeUUIDForDevice: (dev_t) -> UUID?) -> Self? {
    let path = root == "/" ? "/System/Volumes/Data" : root
    var details = stat()
    guard lstat(path, &details) == 0, details.st_mode & S_IFMT == S_IFDIR,
      let uuid = try? DescriptorFileSystem.volumeID(at: path),
      let storeUUID = storeUUIDForDevice(details.st_dev)
    else { return nil }
    return Self(eventID: FSEventsGetCurrentEventId(), volumeUUID: uuid, storeUUID: storeUUID)
  }

  private static func eventStoreUUID(device: dev_t) -> UUID? {
    guard let value = FSEventsCopyUUIDForDevice(device) else { return nil }
    return UUID(uuidString: CFUUIDCreateString(nil, value) as String)
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

/// Accumulates the native callback protocol before exposing a replay. Callback
/// delivery order need not follow the IDs of the reported per-path events.
struct NativeReplayCollection: Sendable {
  private var events: [FileEvent] = []
  private var historyComplete = false
  private var overflow = false
  private var malformedPath = false
  private var invalidHistoryMarker = false

  mutating func record(path: String?, flags: UInt32, id: UInt64) {
    if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
      historyComplete = true
      // The sentinel's path is unspecified. Only a pure sentinel can be
      // discarded: additional flags must never hide a history refusal.
      if flags == UInt32(kFSEventStreamEventFlagHistoryDone) { return }
      invalidHistoryMarker = true
    }
    guard let path else {
      malformedPath = true
      return
    }
    if events.count < 50_001 {
      events.append(FileEvent(path: path, flags: flags, id: id))
    } else {
      overflow = true
    }
  }

  var shouldStopWaiting: Bool { historyComplete || overflow }

  func replay(latestID: UInt64) -> FileEventReplay {
    let complete = historyComplete && !overflow && !malformedPath && !invalidHistoryMarker
    // Keep every decoded record, including duplicate IDs and unsafe flags.
    // Incomplete observations retain their original delivery order.
    return FileEventReplay(
      events: complete ? events.sorted { $0.id < $1.id } : events, latestID: latestID, complete: complete)
  }
}

private final class ReplayObservation: Sendable {
  let state = Mutex(NativeReplayCollection())
  let finished = DispatchSemaphore(value: 0)
  func waitForHistory() { _ = finished.wait(timeout: .now() + 5) }
}

private let replayCallback: FSEventStreamCallback = { _, context, count, paths, flags, ids in
  guard let context else { return }
  let observation = Unmanaged<ReplayObservation>.fromOpaque(context).takeUnretainedValue()
  let names = unsafeBitCast(paths, to: NSArray.self)
  let done = observation.state.withLock { state -> Bool in
    for index in 0..<count {
      state.record(path: names[index] as? String, flags: flags[index], id: ids[index])
    }
    return state.shouldStopWaiting
  }
  if done { observation.finished.signal() }
}

/// Historical replay only. The stream is stopped before returning and never
/// observes the app's open lifetime.
public enum FileEventsReplay {
  private static let queue = DispatchQueue(label: "com.tavsn.lighten.native-replay", qos: .userInitiated)

  public static func replay(root: String, since eventID: UInt64) async -> FileEventReplay {
    let cancellation = ReplayCancellation()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        queue.async {
          continuation.resume(returning: read(root: root, since: eventID, cancellation: cancellation))
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private static func read(root: String, since eventID: UInt64, cancellation: ReplayCancellation) -> FileEventReplay {
    guard !cancellation.cancelled else {
      return FileEventReplay(events: [], latestID: eventID, complete: false)
    }
    let latest = FSEventsGetCurrentEventId()
    guard latest >= eventID else { return FileEventReplay(events: [], latestID: latest, complete: false) }
    if latest == eventID {
      return FileEventReplay(events: [], latestID: latest, complete: !cancellation.cancelled)
    }
    let observation = ReplayObservation()
    cancellation.observe(observation)
    defer { cancellation.stopObserving() }
    let retained = Unmanaged.passRetained(observation)
    defer { retained.release() }
    var context = FSEventStreamContext(
      version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let options = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
    let physical = root == "/" ? "/System/Volumes/Data" : root
    guard !cancellation.cancelled,
      let stream = FSEventStreamCreate(
        nil, replayCallback, &context, [physical] as CFArray, eventID, 0.01, options)
    else { return FileEventReplay(events: [], latestID: latest, complete: false) }
    let callbacks = DispatchQueue(label: "com.tavsn.lighten.replay-callbacks")
    FSEventStreamSetDispatchQueue(stream, callbacks)
    defer {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      callbacks.sync {}
      FSEventStreamRelease(stream)
    }
    guard !cancellation.cancelled, FSEventStreamStart(stream) else {
      return FileEventReplay(events: [], latestID: latest, complete: false)
    }
    observation.waitForHistory()
    if !cancellation.cancelled { FSEventStreamFlushSync(stream) }
    callbacks.sync {}
    let result = observation.state.withLock { $0.replay(latestID: latest) }
    return FileEventReplay(
      events: result.events, latestID: result.latestID, complete: result.complete && !cancellation.cancelled)
  }
}

/// Cancelling wakes the native wait; stream cleanup stays with the owning queue.
private final class ReplayCancellation: Sendable {
  private struct State: Sendable {
    var cancelled = false
    var observation: ReplayObservation?
  }
  private let state = Mutex(State())
  var cancelled: Bool { state.withLock { $0.cancelled } }

  func cancel() {
    let observation = state.withLock {
      $0.cancelled = true
      return $0.observation
    }
    observation?.finished.signal()
  }

  func observe(_ observation: ReplayObservation) {
    let cancelled = state.withLock {
      $0.observation = observation
      return $0.cancelled
    }
    if cancelled { observation.finished.signal() }
  }

  func stopObserving() { state.withLock { $0.observation = nil } }
}
