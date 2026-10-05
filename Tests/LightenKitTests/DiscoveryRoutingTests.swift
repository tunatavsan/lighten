import Foundation
import Testing

@Test("Tool discovery has no legacy scanner routes; static helpers and fresh action evidence remain allowed")
func discoveryUsesNativeMotorOnly() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }
  let clean = try source("Sources/Lighten/Clean/CleanStore.swift")
  #expect(!clean.contains("ScanService("))
  #expect(clean.contains("catalog.discover(rowID:"))
  #expect(clean.contains("catalog.discovery(snapshot:"))
  let related = try source("Sources/LightenKit/Apps/RelatedData.swift")
  #expect(!related.contains("ScanService("))
  let duplicate = try source("Sources/LightenKit/Duplicates/DuplicateService.swift")
  let start = try #require(duplicate.range(of: "public func events("))
  let end = try #require(duplicate.range(of: "public func makePlan(", range: start.upperBound..<duplicate.endIndex))
  let discovery = String(duplicate[start.lowerBound..<end.lowerBound])
  #expect(!discovery.contains("ScanService(") && !discovery.contains("scan.scan"))
  #expect(discovery.contains("ScanEngine("))
  #expect(duplicate.contains("scan.scanImmediateChild("))
}
