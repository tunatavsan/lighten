import AppKit
import Foundation
import Testing

@testable import Lighten

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
