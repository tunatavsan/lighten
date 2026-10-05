import AppKit
import Foundation
import LightenKit
import Testing

@testable import Lighten

@Test("Related-list drawing rejects partial row waves and counts only the clipped detail viewport")
func relatedViewportRequiresCompleteGeometry() {
  let paths: Set<String> = ["first", "second", "third"]
  let viewport = CGRect(x: 0, y: 0, width: 300, height: 400)
  let first = CGRect(x: 0, y: 300, width: 280, height: 60)
  let second = CGRect(x: 0, y: 370, width: 280, height: 60)
  let third = CGRect(x: 0, y: 440, width: 280, height: 60)
  let partial = RelatedListViewportSnapshot(frames: ["first": first], candidatePaths: paths, viewport: viewport)
  #expect(!partial.isComplete)
  let complete = RelatedListViewportSnapshot(
    frames: ["first": first, "second": second, "third": third], candidatePaths: paths, viewport: viewport)
  #expect(complete.isComplete && complete.visibleCount == 2)
  let offscreen = RelatedListViewportSnapshot(
    frames: ["first": first, "second": second, "third": third], candidatePaths: paths,
    viewport: CGRect(x: 0, y: 0, width: 300, height: 200))
  #expect(!offscreen.isComplete && offscreen.visibleCount == 0)
}

private actor IconLoads {
  var count = 0
  func load(_ path: String) -> Data {
    count += 1
    return Data(path.utf8)
  }
}

@Test("Visible application icons share cached asynchronous loads")
func applicationIconCacheReusesLoad() async {
  let loads = IconLoads()
  let cache = ApplicationIconCache(load: { await loads.load($0) })
  async let first = cache.iconData(for: "/Applications/LightenQA-fixture.app")
  async let second = cache.iconData(for: "/Applications/LightenQA-fixture.app")
  let pair = await (first, second)
  #expect(pair.0 == pair.1)
  #expect(await cache.iconData(for: "/Applications/LightenQA-fixture.app") == pair.0)
  #expect(await loads.count == 1)
}

private actor ConcurrentIconLoads {
  var active = 0
  var maximumActive = 0
  var count = 0
  func load(_ path: String) async -> Data {
    active += 1
    count += 1
    maximumActive = max(maximumActive, active)
    try? await Task.sleep(for: .milliseconds(20))
    active -= 1
    return Data(path.utf8)
  }
}

@Test("Cold icon requests keep raster work bounded while delivering every requested icon")
func applicationIconLoadsAreBounded() async {
  let loads = ConcurrentIconLoads()
  let cache = ApplicationIconCache(maximumConcurrentLoads: 2, load: { await loads.load($0) })
  let paths = (0..<12).map { "/Applications/LightenQA-\($0).app" }
  let delivered = await withTaskGroup(of: Bool.self) { group in
    for path in paths {
      group.addTask { await cache.iconData(for: path) == Data(path.utf8) }
    }
    var count = 0
    for await matches in group { if matches { count += 1 } }
    return count
  }
  #expect(delivered == paths.count)
  #expect(await loads.count == paths.count)
  #expect(await loads.maximumActive <= 2)
}

@Test("Icon cache evicts older rasters by byte cost and remembers an unavailable icon")
func applicationIconCacheBoundsBytesAndMisses() async {
  let loads = IconLoads()
  let cache = ApplicationIconCache(capacity: 8, byteCapacity: 5, load: { await loads.load($0) })
  #expect(await cache.iconData(for: "aa") == Data("aa".utf8))
  #expect(await cache.iconData(for: "bb") == Data("bb".utf8))
  _ = await cache.iconData(for: "aa")
  _ = await cache.iconData(for: "ccc")
  _ = await cache.iconData(for: "aa")
  #expect(await loads.count == 3)
  _ = await cache.iconData(for: "bb")
  #expect(await loads.count == 4)
  let misses = IconLoads()
  let missingCache = ApplicationIconCache(load: { path in
    _ = await misses.load(path)
    return nil
  })
  #expect(await missingCache.iconData(for: "missing") == nil)
  #expect(await missingCache.iconData(for: "missing") == nil)
  #expect(await misses.count == 1)
}

@Test("A large multi-representation application image becomes one Retina row raster")
@MainActor func applicationIconRasterHasBoundedDimensions() throws {
  let image = NSImage(size: NSSize(width: 1024, height: 1024))
  for pixels in [32, 1024] {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: pixels * 4, bitsPerPixel: 32))
    image.addRepresentation(bitmap)
  }
  let data = try #require(ApplicationIconCache.rasterData(from: image))
  let bitmap = try #require(NSBitmapImageRep(data: data))
  #expect(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 64)
  #expect(bitmap.samplesPerPixel == 4)
  #expect(data.count < 64 * 64 * 4 + 1024)
}

private func viewportRows(
  count: Int, offset: CGFloat = 0, missing: Set<Int> = [], unready: Set<Int> = []
) -> [String: ApplicationViewportSnapshot.Row] {
  Dictionary(
    uniqueKeysWithValues: (0..<count).filter { !missing.contains($0) }.map { index in
      (
        "app-\(index)",
        .init(
          frame: CGRect(x: 0, y: CGFloat(index) * 55 + offset, width: 300, height: 50),
          iconReady: !unready.contains(index))
      )
    })
}

@Test("The drawn viewport includes all eleven visible rows while excluding lazy prefetch")
func applicationViewportExcludesPrefetch() {
  let ordered = (0..<85).map { "app-\($0)" }
  let snapshot = ApplicationViewportSnapshot(
    rows: viewportRows(count: 22, unready: [15]), orderedPaths: ordered,
    viewport: CGRect(x: 0, y: 0, width: 300, height: 590))
  #expect(snapshot.visiblePaths == Set(ordered.prefix(11)))
  #expect(snapshot.iconsReady)
  let clipped = ApplicationViewportSnapshot(
    rows: viewportRows(count: 22, unready: [10]), orderedPaths: ordered,
    viewport: CGRect(x: 0, y: 0, width: 300, height: 552))
  #expect(clipped.visiblePaths == Set(ordered.prefix(11)))
  #expect(!clipped.iconsReady)
}

@Test("Partial geometry waves and a late eleventh icon cannot claim viewport completion")
func applicationViewportWaitsForEveryRow() {
  let ordered = (0..<85).map { "app-\($0)" }
  let viewport = CGRect(x: 0, y: 0, width: 300, height: 590)
  let early = ApplicationViewportSnapshot(rows: viewportRows(count: 5), orderedPaths: ordered, viewport: viewport)
  #expect(early.visibleRows.count == 5 && !early.iconsReady)
  let hole = ApplicationViewportSnapshot(
    rows: viewportRows(count: 22, missing: [6]), orderedPaths: ordered, viewport: viewport)
  #expect(!hole.iconsReady)
  let late = ApplicationViewportSnapshot(
    rows: viewportRows(count: 22, unready: [10]), orderedPaths: ordered, viewport: viewport)
  #expect(late.visibleRows.count == 11 && !late.iconsReady)
  let finished = ApplicationViewportSnapshot(
    rows: viewportRows(count: 22), orderedPaths: ordered, viewport: viewport)
  #expect(finished.visibleRows.count == 11 && finished.iconsReady)
}

@Test("Scrolling, resizing, and short lists use the current complete clipped snapshot")
func applicationViewportTracksViewportChanges() {
  let ordered = (0..<22).map { "app-\($0)" }
  let scrolled = ApplicationViewportSnapshot(
    rows: viewportRows(count: 22, offset: -275), orderedPaths: ordered,
    viewport: CGRect(x: 0, y: 0, width: 300, height: 590))
  #expect(scrolled.visiblePaths == Set(ordered[5..<16]))
  #expect(scrolled.iconsReady)
  let resized = ApplicationViewportSnapshot(
    rows: viewportRows(count: 22, unready: [15]), orderedPaths: ordered,
    viewport: CGRect(x: 0, y: 0, width: 300, height: 850))
  #expect(resized.visiblePaths == Set(ordered.prefix(16)))
  #expect(!resized.iconsReady)
  let short = ApplicationViewportSnapshot(
    rows: viewportRows(count: 2), orderedPaths: Array(ordered.prefix(2)),
    viewport: CGRect(x: 0, y: 0, width: 300, height: 590))
  #expect(short.visibleRows.count == 2 && short.iconsReady)
  let empty = ApplicationViewportSnapshot(
    rows: viewportRows(count: 22), orderedPaths: ordered, viewport: .zero)
  #expect(empty.visibleRows.isEmpty && !empty.iconsReady)
}

@Test("Review availability follows explicit choices and cancellation while background measurement continues")
@MainActor func appsReviewAvailabilityIgnoresBackgroundProgress() {
  let path = "/Applications/LightenQA-availability.app"
  let store = AppsStore(events: { AsyncStream { $0.finish() } })
  let actions = ActionStore()
  store.reports = [
    ApplicationReport(
      path: path, bundleID: "qa.lighten.availability", version: nil, signerTeamID: nil,
      logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
      allocated: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
      knownItemCount: 0, partial: true, related: [], manualUninstallerSuggested: false)
  ]
  store.busy = true
  store.measuringPaths = [path]
  store.select(path, actions: actions)
  #expect(store.canReviewSelectedData(actions: actions))
  store.togglePackage(actions: actions)
  #expect(!store.canReviewSelectedData(actions: actions))
  store.togglePackage(actions: actions)
  #expect(store.canReviewSelectedData(actions: actions))
  store.preparing = true
  #expect(!store.canReviewSelectedData(actions: actions))
  store.preparing = false
  actions.busy = true
  #expect(!store.canReviewSelectedData(actions: actions))
  actions.busy = false
  store.cancelScan()
  #expect(!store.canReviewSelectedData(actions: actions))
}
