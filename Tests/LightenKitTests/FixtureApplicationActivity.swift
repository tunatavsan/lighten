import Foundation

@testable import LightenKit

struct FixtureClearApplicationActivity: ApplicationActivitySource {
  func activity(applicationPath: String) async -> ApplicationActivity {
    ApplicationActivity(state: .clearObservedProcesses)
  }
}

struct FixtureUnknownApplicationActivity: ApplicationActivitySource {
  func activity(applicationPath: String) async -> ApplicationActivity {
    ApplicationActivity(state: .unknown)
  }
}
