import Foundation

public enum ProcessActivityState: Sendable, Equatable {
  case active, clearObservedCurrentUID, unknown
}

public struct ProcessActivity: Sendable, Equatable {
  public let state: ProcessActivityState
  public let observedAt: Date
  public let processNames: [String]

  public init(state: ProcessActivityState, observedAt: Date = Date(), processNames: [String] = []) {
    self.state = state
    self.observedAt = observedAt
    self.processNames = processNames
  }
}

public enum ProcessActivityFailure: Error, Sendable, CustomStringConvertible {
  case active(processNames: [String])
  case unavailable

  public var description: String {
    switch self {
    case .active(let names): "processActive:" + names.joined(separator: ", ")
    case .unavailable: "processActivityUnavailable"
    }
  }
}

public protocol ProcessActivitySource: Sendable {
  func activity(for rowID: String) async -> ProcessActivity
  /// The root is the catalog row's scope, never an individual descendant.
  func activity(for row: CatalogRow, rootPath: String) async -> ProcessActivity
}

extension ProcessActivitySource {
  public func activity(for row: CatalogRow, rootPath: String) async -> ProcessActivity {
    await activity(for: row.id)
  }
}

/// The library has no authority to assume that an unavailable process source is clear.
public struct UnknownProcessActivitySource: ProcessActivitySource {
  public init() {}
  public func activity(for rowID: String) async -> ProcessActivity {
    ProcessActivity(state: .unknown)
  }
}
