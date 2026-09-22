import Foundation

public enum MemoryPressure: String, Sendable, Equatable {
  case normal, warning, critical, unknown

  public static func decode(raw: Int32?, size: Int?) -> Self {
    guard size == MemoryLayout<Int32>.size else { return .unknown }
    switch raw {
    case 1: return .normal
    case 2: return .warning
    case 4: return .critical
    default: return .unknown
    }
  }
}

public struct SwapMeasure: Sendable, Equatable {
  public let usedBytes: UInt64
  public let totalBytes: UInt64

  public init(usedBytes: UInt64, totalBytes: UInt64) {
    self.usedBytes = usedBytes
    self.totalBytes = totalBytes
  }

  public var fraction: Double? {
    guard totalBytes > 0, usedBytes <= totalBytes else { return nil }
    return Double(usedBytes) / Double(totalBytes)
  }
}

public struct ProcessIdentity: Hashable, Sendable {
  public let pid: Int32
  public let startSeconds: UInt64
  public let startMicroseconds: UInt64

  public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
    self.pid = pid
    self.startSeconds = startSeconds
    self.startMicroseconds = startMicroseconds
  }
}

public struct ProcessMeasure: Sendable {
  public let identity: ProcessIdentity
  public let name: String
  public let residentBytes: UInt64
  public let userTicks: UInt64
  public let systemTicks: UInt64

  public init(
    identity: ProcessIdentity, name: String, residentBytes: UInt64,
    userTicks: UInt64, systemTicks: UInt64
  ) {
    self.identity = identity
    self.name = name
    self.residentBytes = residentBytes
    self.userTicks = userTicks
    self.systemTicks = systemTicks
  }
}

public struct ProcessCensus: Sendable {
  public let processes: [ProcessMeasure]
  public let unreadableCount: Int
  public let truncated: Bool
  public let ticks: UInt64
  public let timebaseNumer: UInt32
  public let timebaseDenom: UInt32

  public init(
    processes: [ProcessMeasure], unreadableCount: Int, truncated: Bool,
    ticks: UInt64, timebaseNumer: UInt32, timebaseDenom: UInt32
  ) {
    self.processes = processes
    self.unreadableCount = unreadableCount
    self.truncated = truncated
    self.ticks = ticks
    self.timebaseNumer = timebaseNumer
    self.timebaseDenom = timebaseDenom
  }

  public var partial: Bool { unreadableCount > 0 || truncated }
}

public struct SystemObservation: Sendable {
  public let observedAt: Date
  public let pressure: MemoryPressure
  public let swap: SwapMeasure?
  public let census: ProcessCensus?

  public init(observedAt: Date, pressure: MemoryPressure, swap: SwapMeasure?, census: ProcessCensus?) {
    self.observedAt = observedAt
    self.pressure = pressure
    self.swap = swap
    self.census = census
  }
}

public typealias SystemSnapshot = SystemObservation

public protocol SystemMetricsProvider: Sendable {
  func sample() async -> SystemObservation
}

public struct ProcessDisplay: Sendable, Identifiable {
  public let process: ProcessMeasure
  public let corePercent: Double?
  public var id: ProcessIdentity { process.identity }
}

public enum SystemProjection {
  /// CPU percentage is the process's share of one logical core, not the host.
  public static func corePercent(
    current: ProcessMeasure, prior: ProcessMeasure?,
    currentCensus: ProcessCensus, priorCensus: ProcessCensus?
  ) -> Double? {
    guard let prior, let priorCensus, prior.identity == current.identity,
      currentCensus.ticks > priorCensus.ticks,
      currentCensus.timebaseNumer == priorCensus.timebaseNumer,
      currentCensus.timebaseDenom == priorCensus.timebaseDenom,
      currentCensus.timebaseNumer > 0, currentCensus.timebaseDenom > 0,
      current.userTicks >= prior.userTicks,
      current.systemTicks >= prior.systemTicks
    else { return nil }
    let (deltaCPU, overflow) = (current.userTicks - prior.userTicks)
      .addingReportingOverflow(current.systemTicks - prior.systemTicks)
    guard !overflow else { return nil }
    let elapsed = Double(currentCensus.ticks - priorCensus.ticks)
    let percent = Double(deltaCPU) / elapsed * 100
    return percent.isFinite && percent >= 0 ? percent : nil
  }

  public static func topProcesses(current: ProcessCensus, prior: ProcessCensus?) -> [ProcessDisplay] {
    var previous: [ProcessIdentity: ProcessMeasure] = [:]
    for process in prior?.processes ?? [] { previous[process.identity] = process }
    return current.processes.sorted {
      if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
      return $0.identity.pid < $1.identity.pid
    }.prefix(10).map { process in
      ProcessDisplay(
        process: process,
        corePercent: corePercent(
          current: process, prior: previous[process.identity],
          currentCensus: current, priorCensus: prior))
    }
  }
}
