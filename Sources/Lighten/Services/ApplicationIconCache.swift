import AppKit
import Foundation

/// Encoded, bounded rasters cross the actor boundary; AppKit objects remain local to their worker.
actor ApplicationIconCache {
  static let shared = ApplicationIconCache()
  private struct Cached {
    let data: Data?
    var accessed: UInt64
  }
  private let load: @Sendable (String) async -> Data?
  private var cached: [String: Cached] = [:]
  private var pending: [String: [CheckedContinuation<Data?, Never>]] = [:]
  private var queue: [String] = []
  private var activeLoads = 0
  private var cachedBytes = 0
  private var access: UInt64 = 0
  private let capacity: Int
  private let byteCapacity: Int
  private let maximumConcurrentLoads: Int

  init(
    capacity: Int = 256, byteCapacity: Int = 8 * 1024 * 1024, maximumConcurrentLoads: Int = 4,
    load: @escaping @Sendable (String) async -> Data? = { path in
      await Task.detached(priority: .userInitiated) {
        autoreleasepool {
          ApplicationIconCache.rasterData(from: NSWorkspace.shared.icon(forFile: path))
        }
      }.value
    }
  ) {
    self.capacity = max(1, capacity)
    self.byteCapacity = max(1, byteCapacity)
    self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
    self.load = load
  }

  /// Draw only the representation needed for a 32-point Retina row. Setting an
  /// NSImage's logical size and serializing it would still generate every representation.
  nonisolated static func rasterData(from image: NSImage) -> Data? {
    let pixels = 64
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: pixels * 4, bitsPerPixel: 32),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(
      in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
      operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
    return bitmap.representation(using: .png, properties: [:])
  }

  func iconData(for path: String) async -> Data? {
    access &+= 1
    if var value = cached[path] {
      value.accessed = access
      cached[path] = value
      return value.data
    }
    return await withCheckedContinuation { continuation in
      if pending[path] != nil {
        pending[path]?.append(continuation)
      } else {
        pending[path] = [continuation]
        queue.append(path)
        startLoads()
      }
    }
  }

  /// A changed viewport promotes pending visible icons without widening the worker limit.
  func prioritize(paths: [String]) {
    let visible = Set(paths)
    queue = queue.filter { visible.contains($0) } + queue.filter { !visible.contains($0) }
  }

  private func startLoads() {
    while activeLoads < maximumConcurrentLoads, !queue.isEmpty {
      let path = queue.removeFirst()
      activeLoads += 1
      let load = self.load
      Task {
        let data = await load(path)
        finishLoad(path: path, data: data)
      }
    }
  }

  private func finishLoad(path: String, data: Data?) {
    activeLoads -= 1
    access &+= 1
    if (data?.count ?? 0) <= byteCapacity {
      cached[path] = Cached(data: data, accessed: access)
      cachedBytes += data?.count ?? 0
      while cached.count > capacity || cachedBytes > byteCapacity {
        guard let oldest = cached.min(by: { $0.value.accessed < $1.value.accessed }) else { break }
        cachedBytes -= oldest.value.data?.count ?? 0
        cached[oldest.key] = nil
      }
    }
    let waiters = pending.removeValue(forKey: path) ?? []
    for waiter in waiters { waiter.resume(returning: data) }
    startLoads()
  }
}
