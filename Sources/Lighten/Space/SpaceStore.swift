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

  init(engine: ScanEngine = ScanEngine(), cache: ScanCache? = ScanCache()) {
    self.engine = engine
    self.cache = cache
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
    if tree == nil { showCachedAndRefresh() }
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

  /// A cached picture appears at once and a fresh scan starts behind it.
  private func showCachedAndRefresh() {
    guard let cache else { return }
    let root = selectedRoot.path
    Task {
      let loaded = await Task.detached { cache.load(root: root) }.value
      guard selectedRoot.path == root, tree == nil, let loaded else { return }
      install(tree: loaded.tree)
      cachedAt = loaded.savedAt
      phase = .complete
      startScan(keepingCache: true)
    }
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
      phase = .error(String(describing: error))
      return
    }
    run = started
    liveTree = started.tree
    phase = .scanning
    progress = nil
    if !keepingCache {
      cachedAt = nil
      install(tree: started.tree)
    }
    let cache = self.cache
    progressTask = Task { [weak self] in
      for await update in started.progress {
        guard let self, self.run === started else { return }
        self.apply(update, from: started)
      }
      guard let self, self.run === started else { return }
      if !started.tree.wasCancelled, let cache {
        let tree = started.tree
        Task.detached(priority: .utility) { try? cache.save(tree) }
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
      install(tree: started.tree, keepingPath: path)
    }
    phase = started.tree.item(started.tree.rootID)?.partial == true ? .partial : .complete
  }

  private func install(tree newTree: ScanTree?, keepingPath: String? = nil) {
    tree = newTree
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
      current = nil
      group = nil
      crumbs = []
      visibleByID = [:]
      selected = nil
      return
    }
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
    guard let size = layoutSize, let tree, let currentID, let group else { return }
    var values = (showingOther ? group.other : group.items).map { ($0.id, $0.bytes(metric).knownLowerBound) }
    if !showingOther, !group.other.isEmpty {
      values.append((SpaceView.otherID, group.otherBytes.knownLowerBound))
    }
    let key = LayoutKey(
      run: tree.runID, node: currentID, metric: metric, showingOther: showingOther,
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
