import Foundation

public enum ProcessActivityState: Sendable, Equatable {
  case active, clearObservedCurrentUID, unknown
}

public struct ProcessActivity: Sendable, Equatable {
  public let state: ProcessActivityState
  public let observedAt: Date

  public init(state: ProcessActivityState, observedAt: Date = Date()) {
    self.state = state
    self.observedAt = observedAt
  }
}

public protocol ProcessActivitySource: Sendable {
  func activity(for rowID: String) async -> ProcessActivity
}

/// The library has no authority to assume that an unavailable process source is clear.
public struct UnknownProcessActivitySource: ProcessActivitySource {
  public init() {}
  public func activity(for rowID: String) async -> ProcessActivity {
    ProcessActivity(state: .unknown)
  }
}
