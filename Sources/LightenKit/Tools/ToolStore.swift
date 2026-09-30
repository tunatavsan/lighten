import Foundation
import Observation

public enum ToolPhase: Sendable, Equatable {
  case idle, scanning, ready, partial, preparing, failed
}

public struct ToolSummary: Sendable, Equatable {
  public let count: Int
  public let logicalBytes: Int64
  public let observedAt: Date?
  public let partial: Bool

  public init(count: Int = 0, logicalBytes: Int64 = 0, observedAt: Date? = nil, partial: Bool = false) {
    self.count = count
    self.logicalBytes = logicalBytes
    self.observedAt = observedAt
    self.partial = partial
  }
}

@MainActor public protocol ToolSummaryProviding: AnyObject {
  var toolSummary: ToolSummary { get }
  func refresh()
}

/// A generation is valid only until the selection, scan, or screen changes.
@MainActor @Observable public final class PreparationGate {
  public private(set) var preparing = false
  private var generation = UUID()

  public init() {}

  public func begin() -> UUID? {
    guard !preparing else { return nil }
    generation = UUID()
    preparing = true
    return generation
  }

  public func accepts(_ token: UUID) -> Bool { preparing && token == generation }

  public func finish(_ token: UUID) {
    if token == generation { preparing = false }
  }

  public func invalidatePreparation() {
    generation = UUID()
    preparing = false
  }
}

/// Shared lifecycle state; each tool retains its scanner and domain-specific selection.
@MainActor @Observable public final class ToolStore {
  public var phase: ToolPhase = .idle
  public let preparation = PreparationGate()

  public init() {}

  public var allowsPreparation: Bool { phase == .ready && !preparation.preparing }
}
