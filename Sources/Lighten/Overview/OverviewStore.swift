import Foundation
import LightenKit
import Observation

@MainActor @Observable
final class OverviewStore {
  @ObservationIgnored private let provider: any SystemMetricsProvider
  @ObservationIgnored private var generation = UUID()
  var system: SystemSnapshot?
  var topProcesses: [ProcessDisplay] = []
  var volume: VolumeMeasure?
  var volumeObservedAt: Date?
  var sampling = false

  init(provider: any SystemMetricsProvider = NativeSystemMetricsProvider()) {
    self.provider = provider
  }

  func stop() {
    generation = UUID()
    sampling = false
  }

  func run(rootPath: String) async {
    let id = UUID()
    generation = id
    sampling = true
    let measured = await VolumeMeasurer.measure(path: rootPath)
    guard generation == id, !Task.isCancelled else { return }
    volume = measured
    volumeObservedAt = Date()
    var prior: SystemSnapshot?
    var sampleCount = 0
    while generation == id, !Task.isCancelled {
      if sampleCount > 0 && sampleCount.isMultiple(of: 5) {
        let updatedVolume = await VolumeMeasurer.measure(path: rootPath)
        guard generation == id, !Task.isCancelled else { return }
        volume = updatedVolume
        volumeObservedAt = Date()
      }
      let sampled = await provider.sample()
      guard generation == id, !Task.isCancelled else { return }
      topProcesses =
        sampled.census.map {
          SystemProjection.topProcesses(current: $0, prior: prior?.census)
        } ?? []
      system = sampled
      prior = sampled
      sampleCount += 1
      sampling = false
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
  }
}
