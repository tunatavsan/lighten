import Darwin
import Foundation
import Synchronization

/// Extensions treated as packages without a per-item LaunchServices query.
/// Planning performs the full package check again before any action.
enum PackageNames {
  static let suffixes: [String] = [
    ".app", ".bundle", ".framework", ".photoslibrary", ".pkg", ".pvm", ".vmwarevm", ".sparsebundle", ".rtfd",
    ".playground", ".xcworkspace", ".xcodeproj", ".pages", ".numbers", ".key", ".xcarchive", ".plugin", ".appex",
    ".kext", ".qlgenerator", ".mdimporter", ".prefpane", ".saver", ".dsym", ".imovielibrary", ".fcpbundle",
    ".logicx", ".band", ".musiclibrary", ".tvlibrary", ".aplibrary", ".scptd", ".utm", ".docset", ".lpdf",
  ]

  static func isPackage(_ name: String) -> Bool {
    let folded = name.lowercased()
    return suffixes.contains { folded.hasSuffix($0) && folded.count > $0.count }
  }
}

struct WalkJob: Sendable {
  enum Mode: Sendable {
    /// Read a tree node and create child nodes.
    case node
    /// Sum the interior of an opaque package or protected area into `owner`.
    case interior
  }
  let owner: Int32
  let path: String
  let device: UInt64
  let inode: UInt64
  let mode: Mode
  let depth: Int
  let protection: ProtectionAutomaton.State?
}

/// Work queue: focus stack, then shallow FIFO (the first screen), then a DFS stack.
final class WalkQueue: @unchecked Sendable {
  private let condition = NSCondition()
  private var focus: [WalkJob] = []
  private var shallow: [WalkJob] = []
  private var shallowHead = 0
  private var deep: [WalkJob] = []
  private var active = 0
  private var stopped = false
  private var focusNode: Int32?
  let cancelled = Atomic<Bool>(false)

  func push(_ jobs: [WalkJob], tree: ScanTree) {
    condition.lock()
    for job in jobs {
      if let focusNode, tree.isDescendant(job.owner, of: focusNode) {
        focus.append(job)
      } else if job.depth <= 1 {
        shallow.append(job)
      } else {
        deep.append(job)
      }
    }
    condition.broadcast()
    condition.unlock()
  }

  /// Blocks until a job is available; nil when the walk has finished or stopped.
  func next() -> WalkJob? {
    condition.lock()
    defer { condition.unlock() }
    while true {
      if stopped || cancelled.load(ordering: .relaxed) {
        stopped = true
        condition.broadcast()
        return nil
      }
      if let job = focus.popLast() ?? popShallow() ?? deep.popLast() {
        active += 1
        return job
      }
      if active == 0 {
        stopped = true
        condition.broadcast()
        return nil
      }
      condition.wait()
    }
  }

  func finished(_ children: [WalkJob], tree: ScanTree) {
    if !children.isEmpty { push(children, tree: tree) }
    condition.lock()
    active -= 1
    condition.broadcast()
    condition.unlock()
  }

  func cancel() {
    cancelled.store(true, ordering: .relaxed)
    condition.lock()
    condition.broadcast()
    condition.unlock()
  }

  /// Moves queued work beneath `node` ahead of everything else.
  func prioritize(_ node: Int32?, tree: ScanTree) {
    condition.lock()
    defer { condition.unlock() }
    focusNode = node
    guard let node else { return }
    var keep: [WalkJob] = []
    for job in deep {
      if tree.isDescendant(job.owner, of: node) { focus.append(job) } else { keep.append(job) }
    }
    deep = keep
  }

  private func popShallow() -> WalkJob? {
    guard shallowHead < shallow.count else {
      if !shallow.isEmpty {
        shallow.removeAll(keepingCapacity: true)
        shallowHead = 0
      }
      return nil
    }
    let job = shallow[shallowHead]
    shallowHead += 1
    return job
  }
}

struct HardLinkKey: Hashable {
  let device: UInt64
  let inode: UInt64
}

/// Runs N dedicated threads over a WalkQueue; each thread owns one DirectoryReader.
final class ParallelWalker: Sendable {
  let tree: ScanTree
  let queue = WalkQueue()
  let counters: ScanCounters
  let automaton: ProtectionAutomaton
  let boundaryDevice: UInt64
  let homeDirectory: String
  let firmlinks: Set<String>?
  let fileRuleSuffixes: [String]
  let fileSink: FileSink?
  let sinkRootAllowed: Bool
  let directEntries: (@Sendable (RawEntry) -> Void)?
  let directoryFilter: (@Sendable (String) -> Bool)?
  private let hardLinks = Mutex(Set<HardLinkKey>())
  private let remainingWorkers: Atomic<Int>
  private let onFinish: @Sendable () -> Void

  init(
    tree: ScanTree, counters: ScanCounters, automaton: ProtectionAutomaton, boundaryDevice: UInt64,
    homeDirectory: String, firmlinks: Set<String>?, workers: Int, fileSink: FileSink? = nil,
    directoryFilter: (@Sendable (String) -> Bool)? = nil,
    sinkRootAllowed: Bool = true, directEntries: (@Sendable (RawEntry) -> Void)? = nil,
    onFinish: @escaping @Sendable () -> Void
  ) {
    self.firmlinks = firmlinks
    self.fileSink = fileSink
    self.sinkRootAllowed = sinkRootAllowed
    self.directEntries = directEntries
    self.directoryFilter = directoryFilter
    self.tree = tree
    self.counters = counters
    self.automaton = automaton
    self.boundaryDevice = boundaryDevice
    self.homeDirectory = homeDirectory
    self.remainingWorkers = Atomic(max(1, workers))
    self.onFinish = onFinish
    // Rules that can match a file (not a whole subtree): check only names with these endings.
    self.fileRuleSuffixes = NeverRule.all.compactMap { rule in
      guard !rule.pattern.hasSuffix("/**"), let last = rule.pattern.split(separator: "/").last else { return nil }
      return last.replacingOccurrences(of: "*", with: "").lowercased()
    }
  }

  func start(root: WalkJob, workers: Int) {
    queue.push([root], tree: tree)
    for index in 0..<max(1, workers) {
      let thread = Thread { [self] in
        let reader = DirectoryReader(
          counters: counters, includeFileMetadata: fileSink != nil)
        while let job = queue.next() {
          let children = process(job, reader: reader)
          queue.finished(children, tree: tree)
        }
        if remainingWorkers.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
          tree.finish(cancelled: queue.cancelled.load(ordering: .relaxed))
          onFinish()
        }
      }
      thread.name = "Lighten scan \(index)"
      thread.qualityOfService = .userInitiated
      thread.start()
    }
  }

  // MARK: One directory

  struct Child {
    var name: String
    var device: UInt64
    var inode: UInt64
    var kind: NodeKind
    var reason: PartialReason?
    var protectedRule: String?
    var traverse: Bool
    var protection: ProtectionAutomaton.State?
  }

  func process(_ job: WalkJob, reader: DirectoryReader) -> [WalkJob] {
    if directoryFilter?(visiblePath(job.path)) == false {
      counters.skippedDirectories.add(1, ordering: .relaxed)
      tree.fail(job, reason: .entryError)
      return []
    }
    var childDirectories: [Child] = []
    var interiorJobs: [WalkJob] = []
    var files: [ScanTree.FileRecord] = []
    var smallCount: Int64 = 0
    var smallLogical: Int64 = 0
    var smallAllocated: Int64 = 0
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var items: Int64 = 0
    var entryErrors = false
    let limit = ScanTree.filesPerDirectory
    let isCancelled = { [queue] in queue.cancelled.load(ordering: .relaxed) }

    do {
      try reader.read(
        path: job.path, expected: (job.device, job.inode),
        includeFileMetadata: fileSink != nil || (job.depth == 0 && directEntries != nil),
        isCancelled: isCancelled
      ) { entry in
        if job.depth == 0 { directEntries?(entry) }
        if entry.error != 0 {
          entryErrors = true
          return
        }
        if entry.kind == .directory {
          items += 1
          allocated &+= entry.allocated
          let childPath = job.path == "/" ? "/" + entry.name : job.path + "/" + entry.name
          if job.mode == .interior {
            if directoryFilter?(visiblePath(childPath)) == false {
              counters.skippedDirectories.add(1, ordering: .relaxed)
              entryErrors = true
            } else if entry.device != job.device || entry.flags & UInt32(SF_DATALESS) != 0 {
              // Another volume or cloud-only contents: the owner's total is a lower bound.
              entryErrors = true
            } else {
              interiorJobs.append(
                WalkJob(
                  owner: job.owner, path: childPath, device: entry.device, inode: entry.inode, mode: .interior,
                  depth: job.depth + 1, protection: nil))
            }
            return
          }
          childDirectories.append(classify(entry, parent: job))
          return
        }
        emit(entry, in: job)
        // Regular files, symlinks (never followed) and special files are leaves.
        if entry.linkCount > 1 && entry.kind == .regular {
          let first = hardLinks.withLock { $0.insert(HardLinkKey(device: entry.device, inode: entry.inode)).inserted }
          if !first { return }
        }
        items += 1
        logical &+= entry.logical
        allocated &+= entry.allocated
        guard job.mode == .node else { return }
        var protectedRule: String?
        do {
          if fileRuleSuffixes.contains(where: { Self.hasASCIISuffix(entry.name, $0) }),
            let state = job.protection,
            let rule = automaton.scanMatch(
              automaton.step(state, entry.name), path: job.path + "/" + entry.name, homeDirectory: homeDirectory)
          {
            protectedRule = rule.id
          }
        }
        let record = ScanTree.FileRecord(
          name: entry.name, logical: entry.logical, allocated: entry.allocated,
          kind: entry.kind == .regular ? .file : entry.kind == .symbolicLink ? .symlink : .other,
          protectedRule: protectedRule, inode: entry.inode, error: false)
        if files.count < limit {
          files.append(record)
        } else if let smallest = files.indices.min(by: { files[$0].logical < files[$1].logical }),
          files[smallest].logical < record.logical
        {
          let evicted = files[smallest]
          smallCount += 1
          smallLogical &+= evicted.logical
          smallAllocated &+= evicted.allocated
          files[smallest] = record
        } else {
          smallCount += 1
          smallLogical &+= record.logical
          smallAllocated &+= record.allocated
        }
      }
    } catch {
      let reason: PartialReason =
        switch error {
        case .changed: .changedDuringScan
        case .cancelled: .cancelled
        case .open, .read: .unreadable
        }
      tree.fail(job, reason: reason)
      return []
    }

    if job.mode == .interior {
      tree.applyInterior(
        job, logical: logical, allocated: allocated, items: items, newJobs: interiorJobs.count, entryErrors: entryErrors
      )
      return interiorJobs
    }
    files.sort { $0.logical != $1.logical ? $0.logical > $1.logical : $0.name < $1.name }
    let created = tree.applyNode(
      job,
      children: childDirectories.map {
        ScanTree.ChildSpec(
          name: $0.name, device: $0.device, inode: $0.inode, kind: $0.kind, reason: $0.reason,
          protectedRule: $0.protectedRule, traverse: $0.traverse)
      }, files: files, small: (smallCount, smallLogical, smallAllocated), logical: logical, allocated: allocated,
      items: items, entryErrors: entryErrors)
    var jobs: [WalkJob] = []
    jobs.reserveCapacity(created.count)
    for (index, child) in zip(created, childDirectories) where child.traverse {
      let childPath = job.path == "/" ? "/" + child.name : job.path + "/" + child.name
      jobs.append(
        WalkJob(
          owner: index, path: childPath, device: child.device, inode: child.inode,
          mode: child.kind == .directory && child.protectedRule == nil ? .node : .interior,
          depth: job.depth + 1, protection: child.protection))
    }
    return jobs
  }

  func emit(_ entry: RawEntry, in job: WalkJob) {
    guard let fileSink, sinkRootAllowed, job.mode == .node, entry.kind == .regular, entry.error == 0,
      entry.device == boundaryDevice, entry.flags & UInt32(SF_DATALESS | UF_DATAVAULT) == 0,
      !PackageNames.isPackage(entry.name),
      !queue.cancelled.load(ordering: .relaxed)
    else { return }
    let path = job.path == "/" ? "/" + entry.name : job.path + "/" + entry.name
    if let state = job.protection,
      !automaton.matches(automaton.step(state, entry.name), path: path, homeDirectory: homeDirectory).isEmpty
    {
      return
    }
    guard let logical = entry.identityLogicalBytes else {
      counters.sinkMetadataUnavailable.add(1, ordering: .relaxed)
      counters.sinkOmittedFiles.add(1, ordering: .relaxed)
      return
    }
    guard logical >= fileSink.minLogicalBytes else { return }
    if let cutoff = fileSink.olderThan {
      guard let modified = entry.modificationTime?.date else {
        counters.sinkMetadataUnavailable.add(1, ordering: .relaxed)
        counters.sinkOmittedFiles.add(1, ordering: .relaxed)
        return
      }
      guard modified < cutoff else { return }
    }
    guard let identity = entry.identity else {
      counters.sinkMetadataUnavailable.add(1, ordering: .relaxed)
      counters.sinkOmittedFiles.add(1, ordering: .relaxed)
      return
    }
    // Added time is optional. Birth and modification time are required by
    // duplicate identity checks; retain their absence and expose uncertainty.
    if entry.birthTime == nil || entry.modificationTime == nil {
      counters.sinkMetadataUnavailable.add(1, ordering: .relaxed)
    }
    // At the disk root and below it, expose the same visible paths as the tree.
    let visiblePath: String
    if firmlinks != nil, job.path.hasPrefix("/System/Volumes/Data/") {
      let relative = String(path.dropFirst("/System/Volumes/Data/".count))
      let first = relative.split(separator: "/").first.map(String.init)
      visiblePath = first.map { firmlinks?.contains($0) == true } == true ? "/" + relative : path
    } else if firmlinks != nil, job.depth == 0 {
      visiblePath = firmlinks?.contains(entry.name) == true ? "/" + entry.name : path
    } else {
      visiblePath = path
    }
    fileSink.receive(
      FileFact(
        path: visiblePath, identity: identity, modTime: entry.modificationTime?.date,
        addedTime: entry.addedTime?.date))
  }

  /// Case-insensitive ASCII suffix test without allocating a folded copy.
  static func hasASCIISuffix(_ name: String, _ suffix: String) -> Bool {
    let nameBytes = name.utf8
    let suffixBytes = suffix.utf8
    guard nameBytes.count >= suffixBytes.count else { return false }
    for (left, right) in zip(nameBytes.suffix(suffixBytes.count), suffixBytes) {
      let folded = left >= 65 && left <= 90 ? left + 32 : left
      if folded != right { return false }
    }
    return true
  }

  func classify(_ entry: RawEntry, parent: WalkJob) -> Child {
    var child = Child(
      name: entry.name, device: entry.device, inode: entry.inode,
      kind: PackageNames.isPackage(entry.name) ? .package : .directory,
      reason: nil, protectedRule: nil, traverse: true, protection: nil)
    let childPath = parent.path == "/" ? "/" + entry.name : parent.path + "/" + entry.name
    if directoryFilter?(visiblePath(childPath)) == false {
      child.reason = .entryError
      child.traverse = false
      counters.skippedDirectories.add(1, ordering: .relaxed)
      return child
    }
    if entry.device != boundaryDevice {
      child.reason = .mountBoundary
      child.traverse = false
      return child
    }
    if entry.flags & UInt32(SF_DATALESS) != 0 {
      child.reason = .cloudNotMeasured
      child.traverse = false
      return child
    }
    if let state = parent.protection {
      // At "/" the physical Data volume path is not the visible path.
      let next =
        parent.depth == 0 && firmlinks != nil && firmlinks?.contains(entry.name) == false
        ? automaton.state(forPath: "/System/Volumes/Data/" + entry.name)
        : automaton.step(state, entry.name)
      let visiblePath =
        parent.depth == 0 && firmlinks != nil
        ? (firmlinks?.contains(entry.name) == true ? "/" + entry.name : "/System/Volumes/Data/" + entry.name)
        : parent.path + "/" + entry.name
      if let rule = automaton.scanMatch(next, path: visiblePath, homeDirectory: homeDirectory) {
        switch rule.id {
        case "ssh", "keychains":
          child.reason = .protectedNotTraversed
          child.traverse = false
        case "mobile-documents", "cloud-storage":
          child.reason = .cloudNotMeasured
          child.traverse = false
        default:
          child.protectedRule = rule.id
        }
        return child
      }
      child.protection = automaton.isInert(next) ? nil : next
    }
    return child
  }

  private func visiblePath(_ path: String) -> String {
    guard let firmlinks, path.hasPrefix("/System/Volumes/Data/") else { return path }
    let relative = String(path.dropFirst("/System/Volumes/Data/".count))
    guard let first = relative.split(separator: "/").first, firmlinks.contains(String(first)) else { return path }
    return "/" + relative
  }
}
