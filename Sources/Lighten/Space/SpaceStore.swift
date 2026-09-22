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
  @ObservationIgnored private let scanService: ScanService

  init(scanService: ScanService = ScanService()) {
    self.scanService = scanService
  }

  var selectedRoot = URL(fileURLWithPath: NSHomeDirectory())
  var volumes: [URL] = []
  var volumeMeasure: VolumeMeasure?
  var phase: ScanPhase = .idle
  var progressCount = 0
  var progressPath = ""
  var snapshot: ScanSnapshot?
  var index: SpaceIndex?
  var currentID: UUID?
  var selectedID: UUID?
  private(set) var showingOther = false
  var metric: SpaceMetric = .logical
  var layout: TreemapLayout?
  private var scanTask: Task<Void, Never>?
  private var scanRunID: UUID?
  var currentScanRunID: UUID? { scanRunID }
  private var layoutTask: Task<Void, Never>?
  private var layoutKey: LayoutKey?

  private struct LayoutKey: Equatable {
    let run: UUID
    let node: UUID
    let metric: SpaceMetric
    let showingOther: Bool
    let width: Int
    let height: Int
  }

  var current: SpaceItem? { currentID.flatMap { index?.items[$0] } }
  var selected: SpaceItem? { selectedID.flatMap { index?.items[$0] } }
  var group: SpaceGroup? {
    guard let index, let currentID else { return nil }
    return index.group(at: currentID, metric: metric)
  }

  func loadVolumes() {
    volumes =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]
      ) ?? []
    measureVolume()
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
    snapshot = nil
    index = nil
    currentID = nil
    selectedID = nil
    layout = nil
    showingOther = false
    measureVolume()
  }

  private func measureVolume() {
    let path = selectedRoot.path
    Task {
      let measured = await VolumeMeasurer.measure(path: path)
      if selectedRoot.path == path { volumeMeasure = measured }
    }
  }

  func startScan() {
    cancel()
    phase = .scanning
    progressCount = 0
    progressPath = ""
    snapshot = nil
    index = nil
    currentID = nil
    selectedID = nil
    layout = nil
    let path = selectedRoot.path
    let runID = UUID()
    scanRunID = runID
    let service = scanService
    scanTask = Task.detached { [weak self] in
      do {
        let stream = service.events(rootPath: path)
        for try await event in stream {
          if Task.isCancelled { return }
          switch event {
          case .progress(let count, let current):
            if count == 1 || count.isMultiple(of: 128) {
              await self?.applyProgress(count, path: current, root: path, runID: runID)
            }
          case .completed(let result):
            let projected = try SpaceIndex(snapshot: result)
            if Task.isCancelled { return }
            await self?.applySnapshot(result, index: projected, root: path, runID: runID)
          }
        }
      } catch is CancellationError {
        await self?.applyCancellation(root: path, runID: runID)
      } catch {
        await self?.applyError(String(describing: error), root: path, runID: runID)
      }
    }
  }

  func applyProgress(_ count: Int, path: String, root: String, runID: UUID) {
    guard selectedRoot.path == root, scanRunID == runID, phase == .scanning else { return }
    progressCount = count
    progressPath = path
  }

  private func applySnapshot(
    _ result: ScanSnapshot, index projected: SpaceIndex, root: String, runID: UUID
  ) {
    guard selectedRoot.path == root, scanRunID == runID, phase == .scanning else { return }
    progressCount = result.entries.count
    snapshot = result
    index = projected
    currentID = projected.rootID
    phase =
      result.nodes.first(where: { $0.id == projected.rootID })?.partial == true
      ? .partial : .complete
  }

  func applyCancellation(root: String, runID: UUID) {
    if selectedRoot.path == root, scanRunID == runID, phase == .scanning { phase = .cancelled }
  }

  func applyError(_ error: String, root: String, runID: UUID) {
    if selectedRoot.path == root, scanRunID == runID, phase == .scanning { phase = .error(error) }
  }

  func cancel() {
    if phase == .scanning { phase = .cancelled }
    scanTask?.cancel()
    scanTask = nil
    scanRunID = nil
    layoutTask?.cancel()
    layoutTask = nil
  }

  func navigate(to id: UUID) {
    guard index?.items[id]?.canInspect == true || index?.rootID == id else { return }
    currentID = id
    selectedID = nil
    showingOther = false
    layout = nil
    layoutKey = nil
    layoutTask?.cancel()
  }

  func showOther() {
    guard group?.other.isEmpty == false else { return }
    showingOther = true
    selectedID = nil
    layout = nil
    layoutKey = nil
    layoutTask?.cancel()
  }

  func back() {
    if showingOther {
      showingOther = false
      selectedID = nil
      layout = nil
      layoutKey = nil
      layoutTask?.cancel()
      return
    }
    guard let parent = current?.parentID else { return }
    navigate(to: parent)
  }

  func updateLayout(width: Double, height: Double) {
    guard let index, let currentID else { return }
    let key = LayoutKey(
      run: index.runID, node: currentID, metric: metric, showingOther: showingOther,
      width: Int(width.rounded()), height: Int(height.rounded()))
    guard key != layoutKey else { return }
    layoutKey = key
    layout = nil
    layoutTask?.cancel()
    let group = index.group(at: currentID, metric: metric)
    var values = (showingOther ? group.other : group.items).map {
      ($0.id, $0.bytes(metric).knownLowerBound)
    }
    if !showingOther, !group.other.isEmpty {
      values.append((SpaceView.otherID, group.otherBytes.knownLowerBound))
    }
    let layoutValues = values
    layoutTask = Task {
      let result = await Task.detached {
        Treemap.layout(values: layoutValues, width: width, height: height)
      }.value
      guard !Task.isCancelled, layoutKey == key else { return }
      layout = result
    }
  }
}
