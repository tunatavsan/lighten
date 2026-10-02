import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

@Suite("Layered application listing")
struct ApplicationListingTests {
  private struct Fixture {
    let home: String
    let roots: String

    init() throws {
      home = "/private/tmp/LightenQA-" + UUID().uuidString
      roots = home + "/Applications"
      try FileManager.default.createDirectory(atPath: roots, withIntermediateDirectories: true)
    }

    func app(_ name: String, id: String) throws -> String {
      let path = roots + "/" + name + ".app"
      try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(
        fromPropertyList: [
          "CFBundleIdentifier": id, "CFBundleDisplayName": name + " display", "CFBundleShortVersionString": "2.3",
        ],
        format: .xml, options: 0)
      try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
      return path
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: home) }
  }

  @Test("Info-only rows include nested applications without following package or metadata links")
  func noFollowRows() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let first = try fixture.app("Nested/first", id: "qa.lighten.first")
    let linkedInfo = try fixture.app("second", id: "qa.lighten.second")
    try FileManager.default.removeItem(atPath: linkedInfo + "/Contents/Info.plist")
    try FileManager.default.createSymbolicLink(
      atPath: linkedInfo + "/Contents/Info.plist", withDestinationPath: first + "/Contents/Info.plist")
    let linkedPackage = fixture.roots + "/third.app"
    try FileManager.default.createSymbolicLink(atPath: linkedPackage, withDestinationPath: first)
    let rows = ApplicationListing.observe(roots: [fixture.roots])
    #expect(rows.count == 3)
    let row = try #require(rows.first { $0.path == first })
    #expect(row.name == "Nested/first display" && row.version == "2.3" && row.bundleID == "qa.lighten.first")
    #expect(row.displayRootIdentity?.kind == .directory)
    #expect(rows.first { $0.path == linkedInfo }?.bundleID == nil)
    #expect(rows.first { $0.path == linkedPackage }?.bundleID == nil)
    #expect(rows.first { $0.path == linkedPackage }?.displayRootIdentity?.kind == .symbolicLink)
  }

  @Test("Metadata progress delivers an early nonempty row and retains every final row")
  func progressiveRowsPreserveListing() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let paths = try (0..<40).map { try fixture.app("app-\($0)", id: "qa.lighten.app\($0)") }
    let batches = Mutex<[[ApplicationListEntry]]>([])
    let rows = ApplicationListing.observe(roots: [fixture.roots]) { batch in
      batches.withLock { $0.append(batch) }
    }
    let progress = batches.withLock { $0 }
    let first = try #require(progress.first)
    #expect(first.count == 1)
    #expect(Set(rows.map(\.path)) == Set(paths))
    #expect(progress.count >= 3)
    for batch in progress {
      #expect(!batch.isEmpty)
      #expect(Set(batch.map(\.path)).isSubset(of: Set(rows.map(\.path))))
      #expect(batch.allSatisfy { $0.bundleID != nil && $0.version == "2.3" })
    }
  }

  @Test("The first listed rows arrive while the expensive registration provider is blocked")
  func listingPrecedesHeavyProviders() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let path = try fixture.app("first", id: "qa.lighten.first")
    let providerGate = DispatchSemaphore(value: 0)
    let providerStarted = AsyncStream<Void>.makeStream()
    let calls = Mutex(0)
    let observedAtListing = Mutex(-1)
    let timedOut = Mutex(false)
    let service = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.roots], writeVerifiedReceipts: false,
      registration: {
        calls.withLock { $0 += 1 }
        providerStarted.continuation.yield(())
        if providerGate.wait(timeout: .now() + 10) == .timedOut { timedOut.withLock { $0 = true } }
        return ApplicationRegistrationObservation(paths: [], complete: true)
      })
    let discovery = ApplicationDiscovery(
      related: service,
      lightweightListing: {
        observedAtListing.withLock { $0 = calls.withLock { $0 } }
        return ApplicationListing.observe(roots: [fixture.roots])
      },
      measurement: { _, _ in
        (
          ByteAggregate(knownLowerBound: 0, completeTotal: 0), ByteAggregate(knownLowerBound: 0, completeTotal: 0), 0,
          false
        )
      })
    let session = discovery.scanSession()
    var iterator = await session.events().makeAsyncIterator()
    _ = await iterator.next()
    let first = await iterator.next()
    _ = await providerStarted.stream.first { _ in true }
    providerGate.signal()
    await session.cancel()
    guard case .listed(let rows, _) = first else {
      Issue.record("Info-only listing was not the first published data")
      return
    }
    #expect(rows.contains { $0.path == path })
    #expect(observedAtListing.withLock { $0 } == 0)
    #expect(!timedOut.withLock { $0 })
  }

  @Test("Default discovery skips all-app related work and review returns only the chosen application")
  func selectedRelatedOnly() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let first = try fixture.app("first", id: "qa.lighten.first")
    _ = try fixture.app("second", id: "qa.lighten.second")
    for id in ["qa.lighten.first", "qa.lighten.second"] {
      try FileManager.default.createDirectory(
        atPath: fixture.home + "/Library/Caches/" + id, withIntermediateDirectories: true)
    }
    let censusCalls = Mutex(0)
    let service = RelatedDataService(
      homeDirectory: fixture.home, applicationRoots: [fixture.roots], writeVerifiedReceipts: false,
      packageActivity: { _ in ApplicationActivity(state: .clearObservedProcesses) },
      liveData: {
        censusCalls.withLock { $0 += 1 }
        return ApplicationLiveDataObservation(records: [], complete: true)
      })
    let session = ApplicationDiscovery(related: service).scanSession()
    var final: [ApplicationReport] = []
    var relatedEvents = 0
    for await event in await session.events() {
      if case .completed(_, let reports) = event { final = reports }
      if case .related = event { relatedEvents += 1 }
    }
    #expect(final.count == 2 && final.allSatisfy { $0.related.isEmpty })
    #expect(relatedEvents == 0 && censusCalls.withLock { $0 } == 0)
    let review = try #require(try await session.relatedReview(path: first))
    #expect(review.application.path == first)
    #expect(review.candidates.contains { $0.path == fixture.home + "/Library/Caches/qa.lighten.first" })
    #expect(!review.candidates.contains { $0.path == fixture.home + "/Library/Caches/qa.lighten.second" })
    await session.cancel()
  }

  @Test("Visible package priority reorders pending work and cancellation clears that work")
  func visiblePriorityAndCancellation() async {
    let service = RelatedDataService(homeDirectory: "/private/tmp", applicationRoots: [])
    let session = ApplicationDiscovery(related: service).scanSession()
    func report(_ path: String) -> ApplicationReport {
      ApplicationReport(
        path: path, bundleID: nil, version: nil, signerTeamID: nil,
        logical: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        allocated: ByteAggregate(knownLowerBound: 0, completeTotal: nil),
        knownItemCount: 0, partial: true, related: [], manualUninstallerSuggested: false)
    }
    await session.enqueueMeasurements([report("/hidden.app"), report("/visible.app"), report("/later.app")])
    await session.prioritizeVisibleApplications(paths: ["/visible.app"])
    #expect(await session.nextMeasurement()?.path == "/visible.app")
    await session.cancel()
    #expect(await session.nextMeasurement()?.path == nil)
  }
}
