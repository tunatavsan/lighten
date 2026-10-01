import CLightenPlatform
import Foundation

public enum ApplicationActivityState: Sendable, Equatable {
  case active, clearObservedProcesses, unknown
}

public struct ApplicationActivity: Sendable, Equatable {
  public let state: ApplicationActivityState
  public let observedAt: Date
  public let processNames: [String]

  public init(state: ApplicationActivityState, observedAt: Date = Date(), processNames: [String] = []) {
    self.state = state
    self.observedAt = observedAt
    self.processNames = processNames
  }
}

public protocol ApplicationActivitySource: Sendable {
  /// Observes executable paths under this root, including nested packages and helpers.
  func activity(applicationPath: String) async -> ApplicationActivity
}

/// Includes helpers, extensions and login items by their executable locations.
public struct NativeApplicationActivitySource: ApplicationActivitySource {
  public init() {}

  public func activity(applicationPath: String) async -> ApplicationActivity {
    await Task.detached(priority: .utility) { Self.observe(applicationPath: applicationPath) }.value
  }

  static func observe(applicationPath: String) -> ApplicationActivity {
    var name = [CChar](repeating: 0, count: 256)
    let state = applicationPath.withCString { root in
      name.withUnsafeMutableBufferPointer { lighten_application_activity(root, $0.baseAddress, $0.count) }
    }
    let description = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return ApplicationActivity(
      state: state == 0 ? .clearObservedProcesses : state == 1 ? .active : .unknown,
      processNames: description.isEmpty ? [] : [description])
  }
}
