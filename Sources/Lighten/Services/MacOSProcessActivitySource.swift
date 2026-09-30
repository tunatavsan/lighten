import AppKit
import CLightenPlatform
import Foundation
import LightenKit

struct MacOSProcessActivitySource: ProcessActivitySource {
  nonisolated func activity(for rowID: String) async -> ProcessActivity {
    guard let catalog = try? CleanCatalog(), let row = catalog.row(id: rowID) else {
      return ProcessActivity(state: .unknown)
    }
    return await activity(for: row, rootPath: catalog.root(for: row))
  }

  nonisolated func activity(for row: CatalogRow, rootPath: String) async -> ProcessActivity {
    let native = await Task.detached(priority: .utility) {
      var name = [CChar](repeating: 0, count: 256)
      let state = rootPath.withCString { root in
        name.withUnsafeMutableBufferPointer { buffer in
          lighten_process_activity(root, buffer.baseAddress, buffer.count)
        }
      }
      let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      return (state, String(decoding: bytes, as: UTF8.self))
    }.value
    if native.0 == 1 {
      return ProcessActivity(state: .active, processNames: native.1.isEmpty ? [] : [native.1])
    }
    if native.0 != 0 { return ProcessActivity(state: .unknown) }
    // A generic app-cache child is paused for its own running app. Interpreters
    // and shell names alone never pause another application's cache.
    if row.relativeRoot == "Library/Caches" {
      let matches = await MainActor.run {
        NSWorkspace.shared.runningApplications.compactMap { app -> String? in
          guard let bundleID = app.bundleIdentifier,
            (rootPath as NSString).lastPathComponent.caseInsensitiveCompare(bundleID) == .orderedSame
          else { return nil }
          return app.localizedName ?? bundleID
        }
      }
      if !matches.isEmpty { return ProcessActivity(state: .active, processNames: matches.sorted()) }
    }
    return ProcessActivity(state: .clearObservedCurrentUID)
  }
}
