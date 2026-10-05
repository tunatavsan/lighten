import Foundation
import LightenKit
import Testing

@testable import Lighten

@MainActor @Test func cleanProgressDoesNotInventBytesBeforeDiscovery() {
  let progress = CleanScanDisplayProgress()
  #expect(progress.count == 0)
  #expect(progress.bytes == nil)
}

@MainActor @Test func cleanProgressCountsObservedItemsIncludingUnknownMetadata() {
  var progress = CleanScanDisplayProgress()
  progress.include(
    progressSnapshot([
      progressEntry("/cache", kind: .directory, bytes: 4096),
      progressEntry("/cache/one", kind: .regular, bytes: 120),
      progressEntry("/cache/two", kind: .regular, bytes: 80),
      ScanEntry(parentID: nil, path: "/cache/unreadable", identity: nil, issues: [.unreadable], readable: false),
    ]))
  #expect(progress.count == 4)
  #expect(progress.bytes == 200)
  #expect(progress.unreadablePaths == ["/cache/unreadable"])
}

@MainActor @Test func cleanProgressDoesNotCountOverlappingCatalogLocationsTwice() {
  var progress = CleanScanDisplayProgress()
  let shared = progressEntry("/cache/pip/package", kind: .regular, bytes: 120)
  progress.include(progressSnapshot([progressEntry("/cache", kind: .directory, bytes: 4096), shared]))
  progress.include(progressSnapshot([progressEntry("/cache/pip", kind: .directory, bytes: 4096), shared]))
  #expect(progress.count == 3)
  #expect(progress.bytes == 120)
}

@MainActor @Test func cleanProgressCanMeasureKnownZeroWithoutInventingUnknownSize() {
  var progress = CleanScanDisplayProgress()
  progress.include(
    progressSnapshot([
      ScanEntry(parentID: nil, path: "/cache/unknown", identity: nil, issues: [.unknownMetadata], readable: true)
    ]))
  #expect(progress.bytes == nil)
  progress.include(progressSnapshot([progressEntry("/cache/empty", kind: .regular, bytes: 0)]))
  #expect(progress.bytes == 0)
  #expect(progress.count == 2)
}

private func progressSnapshot(_ entries: [ScanEntry]) -> ScanSnapshot {
  ScanSnapshot(rootPath: "/cache", volumeDevice: 1, entries: entries, nodes: [])
}

private func progressEntry(_ path: String, kind: EntryKind, bytes: Int64) -> ScanEntry {
  ScanEntry(
    parentID: nil, path: path,
    identity: FileIdentity(
      device: 1, inode: 1, changeSeconds: 0, changeNanoseconds: 0,
      logicalBytes: bytes, allocatedBytes: bytes, linkCount: 1, flags: 0, kind: kind),
    issues: [], readable: true)
}
