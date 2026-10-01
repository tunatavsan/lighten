import AppKit
import Foundation
import LightenKit
import Observation

enum ScanPhase: Equatable {
  case idle, scanning, cancelled, partial, complete
  case error(String)
}

@MainActor @Observable
final class SpaceStore {
  @ObservationIgnored private let engine: ScanEngine
  @ObservationIgnored private let cache: ScanCache?
  @ObservationIgnored private let pictures: ResultPictureStore?
  @ObservationIgnored private let beforeFullRefresh: (@MainActor () async -> Void)?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var openingGeneration: UUID?
  @ObservationIgnored private var picture: ResultPicture<SpacePicture>?
  @ObservationIgnored private var appearedAt: ContinuousClock.Instant?
  @ObservationIgnored private var scanBaseline: ScanReplayBaseline?
  private(set) var rootSummary: SpaceItem?
  private(set) var firstLayoutMilliseconds: Double?
  private(set) var appearanceToken: UUID?
  private(set) var cacheUsageBytes: Int64 = 0
  private(set) var cacheMessage: String?

  func loadCacheUsage() {
    let cache = self.cache
    Task {
      cacheUsageBytes = await Task.detached { cache?.usageBytes() ?? 0 }.value
    }
  }

  func clearScanCache() async {
    let cache = self.cache
    let pictures = self.pictures
    do {
      try await Task.detached {
        try cache?.clear()
        try pictures?.clearSpacePictures()
      }.value
      cacheMessage = nil
      loadCacheUsage()
    } catch { cacheMessage = FailureText.describe(error) }
  }

  func spaceDidAppear() {
    appearedAt = .now
    firstLayoutMilliseconds = nil
    appearanceToken = UUID()
  }

  func spaceDidLayout(appearance: UUID?, width: Double, height: Double) {
    guard width.isFinite, height.isFinite, width > 0, height > 0,
      appearance == appearanceToken, appearance != nil, current != nil, layout != nil,
      firstLayoutMilliseconds == nil, let appearedAt
    else { return }
    let duration = appearedAt.duration(to: .now).components
    firstLayoutMilliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
  }

  init(
    engine: ScanEngine = ScanEngine(), cache: ScanCache? = ScanCache(),
    pictures: ResultPictureStore? = nil, beforeFullRefresh: (@MainActor () async -> Void)? = nil
  ) {
    self.engine = engine
    self.cache = cache
    self.beforeFullRefresh = beforeFullRefresh
    self.pictures =
      pictures
      ?? cache.map {
        ResultPictureStore(
          directory: $0.directory == ScanCache.defaultDirectory
            ? ResultPictureStore.defaultDirectory : $0.directory + "-pictures")
      }
  }

  var selectedRoot = URL(fileURLWithPath: NSHomeDirectory())
  var volumes: [URL] = []
  var volumeMeasure: VolumeMeasure?
  var phase: ScanPhase = .idle
  private(set) var tree: ScanTree?
  private(set) var progress: ScanProgress?
  /// Set while a cached tree is on screen; cleared when a fresh scan replaces it.
  private(set) var cachedAt: Date?
  private(set) var currentID: ScanItemID?
  var selectedID: ScanItemID? {
    didSet { refreshSelection() }
  }
  private(set) var showingOther = false
  var metric: SpaceMetric = .logical {
    didSet { if metric != oldValue { refreshView(forceLayout: true) } }
  }
  var layout: TreemapLayout?
  private(set) var current: SpaceItem?
  private(set) var selected: SpaceItem?
  private(set) var group: SpaceGroup?
  private(set) var crumbs: [SpaceItem] = []
  private(set) var visibleByID: [ScanItemID: SpaceItem] = [:]
  @ObservationIgnored private var run: ScanRun?
  @ObservationIgnored private var liveTree: ScanTree?
  @ObservationIgnored private var progressTask: Task<Void, Never>?
  @ObservationIgnored private var layoutTask: Task<Void, Never>?
  @ObservationIgnored private var layoutKey: LayoutKey?
  @ObservationIgnored private var layoutSize: (width: Double, height: Double)?
  @ObservationIgnored private var lastLayoutAt = ContinuousClock.now - .seconds(10)
  @ObservationIgnored private var pendingLayout = false

  var currentScanRunID: UUID? { run?.runID }
  var isShowingCache: Bool { cachedAt != nil }

  private struct LayoutKey: Equatable {
    let run: UUID
    let node: ScanItemID
    let metric: SpaceMetric
    let showingOther: Bool
    let width: Int
    let height: Int
    let values: [Int64]
  }

  func loadVolumes() {
    volumes =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]
      ) ?? []
    measureVolume()
    if tree == nil {
      showCachedAndRefresh()
    } else if cachedAt != nil, phase != .scanning {
      showCachedAndRefresh()
    }
  }

  /// Overview needs only the small, shared presentation result.
  func showCachedSummary() {
    guard rootSummary == nil, let pictures else { return }
    let root = selectedRoot.path
    let token = generation
    Task {
      let loaded = await Task.detached { pictures.loadSpace(root: root) }.value
      guard generation == token, selectedRoot.path == root, rootSummary == nil, let loaded else { return }
      picture = loaded
      rootSummary = loaded.content.root.item
      cachedAt = loaded.observedAt
    }
  }

  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Choose")
    if panel.runModal() == .OK, let url = panel.url { selectRoot(url) }
  }

  func selectRoot(_ url: URL) {
    cancel()
    selectedRoot = url
    phase = .idle
    install(tree: nil)
    cachedAt = nil
    measureVolume()
    showCachedAndRefresh()
  }

  /// The picture is decoded first; the full tree and historical replay stay
  /// off the main actor. Cached rows remain unselectable until refresh succeeds.
  private func showCachedAndRefresh() {
    guard let cache else { return }
    let root = selectedRoot.path
    let token = generation
    guard openingGeneration != token else { return }
    openingGeneration = token
    let pictures = self.pictures
    let engine = self.engine
    phase = .scanning
    Task {
      if let loaded = await Task.detached(operation: { pictures?.loadSpace(root: root) }).value {
        guard generation == token, selectedRoot.path == root else { return }
        picture = loaded
        cachedAt = loaded.observedAt
        rootSummary = loaded.content.root.item
        refreshView(forceLayout: true)
      }
      let loaded = await Task.detached { cache.loadEntry(root: root) }.value
      guard generation == token, selectedRoot.path == root else { return }
      guard let loaded else {
        startScan(keepingCache: cachedAt != nil)
        return
      }
      cachedAt = loaded.savedAt
      guard let baseline = loaded.baseline, baseline.storeUUID != nil else {
        await showCachedTreeAndRefresh(loaded.tree, token: token, root: root)
        return
      }
      let replay = await FileEventsReplay.replay(root: root, since: baseline.eventID)
      let current = await Task.detached { ScanReplayBaseline.capture(root: root) }.value
      guard generation == token, selectedRoot.path == root else { return }
      let outcome = await Task.detached {
        engine.reconcile(tree: loaded.tree, replay: replay, baseline: baseline, currentBaseline: current)
      }.value
      guard generation == token, selectedRoot.path == root else { return }
      if case .refreshed = outcome {
        picture = nil
        cachedAt = nil
        install(tree: loaded.tree)
        phase = rootSummary?.partial == true ? .partial : .complete
        let nextBaseline = current.map {
          ScanReplayBaseline(eventID: replay.latestID, volumeUUID: $0.volumeUUID, storeUUID: $0.storeUUID)
        }
        Task.detached(priority: .utility) {
          try? cache.save(loaded.tree, baseline: nextBaseline)
          try? pictures?.saveSpace(tree: loaded.tree)
        }
      } else {
        await showCachedTreeAndRefresh(loaded.tree, token: token, root: root)
      }
    }
  }

  private func showCachedTreeAndRefresh(_ loaded: ScanTree, token: UUID, root: String) async {
    // The small picture supplies the first frame; the full cached tree supplies
    // navigation while a fresh scan runs and remains available after cancellation.
    picture = nil
    install(tree: loaded, keepingPath: current?.path)
    await beforeFullRefresh?()
    guard generation == token, selectedRoot.path == root else { return }
    startScan(keepingCache: true)
  }

  private func measureVolume() {
    let path = selectedRoot.path
    Task {
      let measured = await VolumeMeasurer.measure(path: path)
      if selectedRoot.path == path { volumeMeasure = measured }
    }
  }

  func startScan() { startScan(keepingCache: false) }

  private func startScan(keepingCache: Bool) {
    cancelRun()
    let root = selectedRoot.path
    let started: ScanRun
    do { started = try engine.start(root: root) } catch {
      phase = .error(FailureText.describe(error))
      return
    }
    run = started
    scanBaseline = started.replayBaseline
    liveTree = started.tree
    phase = .scanning
    progress = nil
    if !keepingCache {
      cachedAt = nil
      picture = nil
      install(tree: started.tree)
    }
    let cache = self.cache
    let pictures = self.pictures
    let baseline = scanBaseline
    progressTask = Task { [weak self] in
      for await update in started.progress {
        guard let self, self.run === started else { return }
        self.apply(update, from: started)
      }
      guard let self, self.run === started else { return }
      if !started.tree.wasCancelled, let cache {
        let tree = started.tree
        Task.detached(priority: .utility) {
          try? cache.save(tree, baseline: baseline)
          try? pictures?.saveSpace(tree: tree)
        }
      }
    }
  }

  private func apply(_ update: ScanProgress, from started: ScanRun) {
    progress = update
    if cachedAt == nil {
      refreshView(forceLayout: false)
    }
    guard update.finished else { return }
    if update.cancelled {
      phase = .cancelled
      return
    }
    if cachedAt != nil {
      // Swap the finished fresh tree in, keeping the place the person was looking at.
      let path = current?.path
      cachedAt = nil
      picture = nil
      install(tree: started.tree, keepingPath: path)
    }
    phase = started.tree.item(started.tree.rootID)?.partial == true ? .partial : .complete
  }

  private func install(tree newTree: ScanTree?, keepingPath: String? = nil) {
    tree = newTree
    rootSummary = newTree.flatMap { $0.item($0.rootID) }
    if newTree == nil { picture = nil }
    currentID = newTree.map { tree in keepingPath.flatMap { tree.find(path: $0) } ?? tree.rootID }
    selectedID = nil
    showingOther = false
    layout = nil
    layoutKey = nil
    refreshView(forceLayout: true)
  }

  func cancel() {
    cancelRun()
    if phase == .scanning { phase = .cancelled }
    layoutTask?.cancel()
    layoutTask = nil
  }

  private func cancelRun() {
    generation = UUID()
    run?.cancel()
    run = nil
    progressTask?.cancel()
    progressTask = nil
  }

  func navigate(to id: ScanItemID) {
    guard let tree, id == tree.rootID || tree.item(id)?.canInspect == true else { return }
    currentID = id
    selectedID = nil
    showingOther = false
    layout = nil
    layoutKey = nil
    if tree === liveTree { run?.prioritize(id) }
    refreshView(forceLayout: true)
  }

  func showOther() {
    guard group?.other.isEmpty == false else { return }
    showingOther = true
    selectedID = nil
    layout = nil
    layoutKey = nil
    refreshView(forceLayout: true)
  }

  func back() {
    if showingOther {
      showingOther = false
      selectedID = nil
      layout = nil
      layoutKey = nil
      refreshView(forceLayout: true)
      return
    }
    guard let parent = current?.parentID else { return }
    navigate(to: parent)
  }

  /// O(children of the open folder); called at most at the publication rate.
  private func refreshView(forceLayout: Bool) {
    guard let tree, let currentID else {
      if let picture {
        let root = picture.content.root.item
        current = root
        currentID = root.id
        rootSummary = root
        crumbs = [root]
        let sorted = picture.content.children.map(\.item).sorted {
          $0.bytes(metric).knownLowerBound > $1.bytes(metric).knownLowerBound
        }
        let front = Array(sorted.prefix(24))
        let rest = Array(sorted.dropFirst(24))
        let bytes = rest.reduce(Int64(0)) { $0 + $1.bytes(metric).knownLowerBound }
        group = SpaceGroup(
          items: front, other: rest, otherBytes: ByteAggregate(knownLowerBound: bytes, completeTotal: nil))
        visibleByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        refreshSelection()
        scheduleLayout(force: forceLayout)
        return
      }
      current = nil
      group = nil
      crumbs = []
      visibleByID = [:]
      selected = nil
      return
    }
    rootSummary = tree.item(tree.rootID)
    current = tree.item(currentID)
    let newGroup = tree.group(at: currentID, metric: metric)
    group = newGroup
    crumbs = tree.breadcrumb(to: currentID)
    var byID: [ScanItemID: SpaceItem] = [:]
    for item in newGroup.items { byID[item.id] = item }
    for item in newGroup.other { byID[item.id] = item }
    visibleByID = byID
    refreshSelection()
    scheduleLayout(force: forceLayout)
  }

  private func refreshSelection() {
    let item = selectedID.flatMap { visibleByID[$0] ?? tree?.item($0) }
    if selected != item { selected = item }
  }

  func updateLayout(width: Double, height: Double) {
    layoutSize = (width, height)
    scheduleLayout(force: true)
  }

  /// Relayout at most ~3 times a second while numbers move; immediately on navigation.
  private func scheduleLayout(force: Bool) {
    guard let size = layoutSize, let currentID, let group else { return }
    var values = (showingOther ? group.other : group.items).map { ($0.id, $0.bytes(metric).knownLowerBound) }
    if !showingOther, !group.other.isEmpty {
      values.append((SpaceView.otherID, group.otherBytes.knownLowerBound))
    }
    let key = LayoutKey(
      run: tree?.runID ?? generation, node: currentID, metric: metric, showingOther: showingOther,
      width: Int(size.width.rounded()), height: Int(size.height.rounded()), values: values.map(\.1))
    guard key != layoutKey else { return }
    let now = ContinuousClock.now
    if !force, layout != nil, now - lastLayoutAt < .milliseconds(350) {
      guard !pendingLayout else { return }
      pendingLayout = true
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(350))
        guard let self else { return }
        self.pendingLayout = false
        self.scheduleLayout(force: true)
      }
      return
    }
    layoutKey = key
    lastLayoutAt = now
    layoutTask?.cancel()
    let layoutValues = values
    layoutTask = Task {
      let result = await Task.detached {
        Treemap.layout(values: layoutValues, width: size.width, height: size.height)
      }.value
      guard !Task.isCancelled, layoutKey == key else { return }
      layout = result
    }
  }
}
