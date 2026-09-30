import CLightenPlatform
import Darwin
import Foundation
import Synchronization

public struct ScanConfiguration: Sendable {
  public var workers: Int
  public var homeDirectory: String
  public var publishInterval: Duration

  public init(
    workers: Int = ScanConfiguration.defaultWorkers, homeDirectory: String = NSHomeDirectory(),
    publishInterval: Duration = .milliseconds(125)
  ) {
    self.workers = workers
    self.homeDirectory = homeDirectory
    self.publishInterval = publishInterval
  }

  /// Knee of the measured worker sweep on this class of hardware.
  public static let defaultWorkers = 8
}

public struct ScanProgress: Sendable, Equatable {
  public let runID: UUID
  public let version: UInt64
  public let directoriesRead: Int
  public let itemsSeen: Int
  public let rootLogicalLowerBound: Int64
  public let finished: Bool
  public let cancelled: Bool
}

public enum ScanStartFailure: Error, Sendable, Equatable {
  case notDirectory
  case unavailable(Int32)
}

/// Records the last worker's completion before resuming its asynchronous waiters.
final class FinishSignal: Sendable {
  private let state = Mutex<
    (done: Bool, completionInstant: ContinuousClock.Instant?, list: [CheckedContinuation<Void, Never>])
  >((false, nil, []))

  var isDone: Bool { state.withLock { $0.done } }
  var completionInstant: ContinuousClock.Instant? { state.withLock { $0.completionInstant } }

  func wait() async {
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { state -> Bool in
        if state.done { return true }
        state.list.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func signal() {
    let list = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      if state.completionInstant == nil { state.completionInstant = .now }
      state.done = true
      defer { state.list.removeAll() }
      return state.list
    }
    for continuation in list { continuation.resume() }
  }
}

/// One scan: a live tree, a throttled progress stream, cancellation and focus.
public final class ScanRun: Sendable {
  public let tree: ScanTree
  public let counters: ScanCounters
  public let progress: AsyncStream<ScanProgress>
  let walker: ParallelWalker
  let finish: FinishSignal

  init(
    tree: ScanTree, counters: ScanCounters, walker: ParallelWalker, progress: AsyncStream<ScanProgress>,
    finish: FinishSignal
  ) {
    self.tree = tree
    self.counters = counters
    self.walker = walker
    self.progress = progress
    self.finish = finish
  }

  public var runID: UUID { tree.runID }
  var completionInstant: ContinuousClock.Instant? { finish.completionInstant }

  public func cancel() { walker.queue.cancel() }

  /// Moves pending work beneath `id` ahead of other queued directories.
  public func prioritize(_ id: ScanItemID?) {
    walker.queue.prioritize(id.map(\.node), tree: tree)
  }

  /// Returns after every worker thread has stopped.
  public func waitUntilFinished() async { await finish.wait() }
}

public struct ScanEngine: Sendable {
  public let configuration: ScanConfiguration

  public init(configuration: ScanConfiguration = ScanConfiguration()) {
    self.configuration = configuration
  }

  public func start(root requestedRoot: String) throws(ScanStartFailure) -> ScanRun {
    let root =
      requestedRoot.count > 1 && requestedRoot.hasSuffix("/") ? String(requestedRoot.dropLast()) : requestedRoot
    // "/" walks the Data volume once through its firmlinked names; the sealed
    // system volume becomes one measured block.
    let physical = root == "/" ? "/System/Volumes/Data" : root
    var details = stat()
    guard lstat(physical, &details) == 0 else { throw .unavailable(errno) }
    guard details.st_mode & S_IFMT == S_IFDIR else { throw .notDirectory }
    let device = UInt64(details.st_dev)
    let firmlinks = root == "/" ? Self.firmlinkNames() : nil
    let tree = ScanTree(
      runID: UUID(), rootPath: root,
      root: ScanTree.rootNode(name: root, device: device, inode: details.st_ino), firmlinks: firmlinks)
    if root == "/" {
      var used: Int64 = 0
      if lighten_volume_space_used("/", &used) == 0 {
        tree.addMeasuredChild(
          name: String(localized: "macOS system volume"), pathOverride: "/System", kind: .systemVolume, logical: used)
      }
    }
    let counters = ScanCounters()
    let automaton = ProtectionAutomaton(homeDirectory: configuration.homeDirectory)
    let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
    let finish = FinishSignal()
    let walker = ParallelWalker(
      tree: tree, counters: counters, automaton: automaton, boundaryDevice: device,
      homeDirectory: configuration.homeDirectory, firmlinks: firmlinks, workers: configuration.workers,
      onFinish: { finish.signal() })
    let run = ScanRun(tree: tree, counters: counters, walker: walker, progress: stream, finish: finish)
    let interval = configuration.publishInterval
    // The publisher lives exactly as long as the walk; yields after the consumer
    // stops listening are dropped by the stream.
    Task.detached(priority: .userInitiated) {
      var lastVersion: UInt64 = .max
      var published = false
      while true {
        let done = finish.isDone
        let version = tree.version
        if version != lastVersion || done {
          lastVersion = version
          let root = tree.item(tree.rootID)
          continuation.yield(
            ScanProgress(
              runID: tree.runID, version: version,
              directoriesRead: counters.directories.load(ordering: .relaxed),
              itemsSeen: Int(root?.itemCount ?? 0),
              rootLogicalLowerBound: root?.logical.knownLowerBound ?? 0,
              finished: done, cancelled: done && tree.wasCancelled))
          if (root?.childCount ?? 0) > 0 { published = true }
        }
        if done {
          continuation.finish()
          return
        }
        // Poll quickly until the first screen exists, then throttle.
        try? await Task.sleep(for: published ? interval : .milliseconds(5))
      }
    }
    let protection: ProtectionAutomaton.State? = automaton.state(forPath: root)
    walker.start(
      root: WalkJob(
        owner: 0, path: physical, device: device, inode: details.st_ino, mode: .node, depth: 0,
        protection: protection),
      workers: configuration.workers)
    return run
  }

  /// Top-level Data volume names that appear at "/" through a firmlink.
  static func firmlinkNames() -> Set<String> {
    guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else { return [] }
    var names = Set<String>()
    for line in text.split(separator: "\n") {
      let fields = line.split(separator: "\t")
      guard let visible = fields.first, visible.hasPrefix("/"), !visible.dropFirst().contains("/") else { continue }
      names.insert(String(visible.dropFirst()))
    }
    return names
  }
}
