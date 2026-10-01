import CLightenPlatform
import Foundation

public enum ApplicationActivityState: Sendable, Equatable {
  case active, clearObservedProcesses, unknown
}

public enum ApplicationActivityScope: Sendable, Equatable {
  case allUsers, currentUser
}

public struct ApplicationActivity: Sendable, Equatable {
  public let state: ApplicationActivityState
  public let observedAt: Date
  public let processNames: [String]
  public let scope: ApplicationActivityScope
  public let requiresAdministrator: Bool

  public init(
    state: ApplicationActivityState, observedAt: Date = Date(), processNames: [String] = [],
    scope: ApplicationActivityScope = .allUsers, requiresAdministrator: Bool = false
  ) {
    self.state = state
    self.observedAt = observedAt
    self.processNames = processNames
    self.scope = scope
    self.requiresAdministrator = requiresAdministrator
  }
}

public protocol ApplicationActivitySource: Sendable {
  /// Observes executable paths under this root, including nested packages and helpers.
  func activity(applicationPath: String) async -> ApplicationActivity
}

/// Includes helpers, extensions and login items by their executable locations.
public struct NativeApplicationActivitySource: ApplicationActivitySource {
  public let scope: ApplicationActivityScope

  public init(scope: ApplicationActivityScope = .allUsers) { self.scope = scope }

  public func activity(applicationPath: String) async -> ApplicationActivity {
    await Task.detached(priority: .utility) { Self.observe(applicationPath: applicationPath, scope: scope) }.value
  }

  static func observe(applicationPath: String) -> ApplicationActivity {
    observe(applicationPath: applicationPath, scope: .allUsers)
  }

  private static func observe(applicationPath: String, scope: ApplicationActivityScope) -> ApplicationActivity {
    var name = [CChar](repeating: 0, count: 256)
    var administrator: Int32 = 0
    let state = applicationPath.withCString { root in
      name.withUnsafeMutableBufferPointer {
        if scope == .currentUser {
          return lighten_current_user_application_activity(root, $0.baseAddress, $0.count, &administrator)
        }
        return lighten_application_activity(root, $0.baseAddress, $0.count)
      }
    }
    let description = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return ApplicationActivity(
      state: state == 0 ? .clearObservedProcesses : state == 1 ? .active : .unknown,
      processNames: description.isEmpty ? [] : [description], scope: scope,
      requiresAdministrator: administrator != 0)
  }
}
