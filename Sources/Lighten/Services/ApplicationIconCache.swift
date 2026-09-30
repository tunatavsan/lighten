import AppKit
import Foundation

/// Encoded icons cross the actor boundary; AppKit images stay on their caller's actor.
actor ApplicationIconCache {
  static let shared = ApplicationIconCache()
  private let load: @Sendable (String) async -> Data?
  private var cached: [String: Data] = [:]
  private var pending: [String: Task<Data?, Never>] = [:]
  private let capacity: Int

  init(
    capacity: Int = 256,
    load: @escaping @Sendable (String) async -> Data? = { path in
      await Task.detached(priority: .utility) {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        return image.tiffRepresentation
      }.value
    }
  ) {
    self.capacity = max(1, capacity)
    self.load = load
  }

  func iconData(for path: String) async -> Data? {
    if let data = cached[path] { return data }
    if let task = pending[path] { return await task.value }
    let load = self.load
    let task = Task { await load(path) }
    pending[path] = task
    let data = await task.value
    pending[path] = nil
    if let data {
      if cached.count >= capacity, let key = cached.keys.first { cached[key] = nil }
      cached[path] = data
    }
    return data
  }
}
