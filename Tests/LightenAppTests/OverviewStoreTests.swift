import Foundation
import LightenKit
import Testing

@testable import Lighten

private actor MetricsGate: SystemMetricsProvider {
  private var request: CheckedContinuation<SystemObservation, Never>?
  private var waiter: CheckedContinuation<Void, Never>?

  func sample() async -> SystemObservation {
    await withCheckedContinuation { continuation in
      request = continuation
      waiter?.resume()
      waiter = nil
    }
  }

  func waitForRequest() async {
    if request != nil { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func finish(_ observation: SystemObservation) {
    request?.resume(returning: observation)
    request = nil
  }
}

@Test("Overview drops a sample that arrives after leaving the page")
@MainActor func overviewRejectsStaleSample() async {
  let gate = MetricsGate()
  let store = OverviewStore(provider: gate)
  let task = Task { await store.run(rootPath: NSTemporaryDirectory()) }
  await gate.waitForRequest()
  store.stop()
  await gate.finish(
    SystemObservation(
      observedAt: Date(), pressure: .critical,
      swap: SwapMeasure(usedBytes: 1, totalBytes: 2), census: nil))
  await task.value
  #expect(store.system == nil)
  #expect(store.topProcesses.isEmpty)
  #expect(!store.sampling)
}
