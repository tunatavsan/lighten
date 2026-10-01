import CLightenPlatform
import Darwin
import Foundation
import Testing

@testable import LightenKit

@Suite("Scoped application activity")
struct ScopedApplicationActivityTests {
  @Test("Legacy observations preserve all-user scope and never imply administration by default")
  func legacyDefaults() {
    let observation = ApplicationActivity(state: .unknown)
    #expect(observation.scope == .allUsers && !observation.requiresAdministrator)
    #expect(NativeApplicationActivitySource().scope == .allUsers)
    #expect(NativeApplicationActivitySource(scope: .currentUser).scope == .currentUser)
  }

  @Test("An unavailable current-user executable always keeps the scoped census unavailable")
  func currentUserUnknownRemainsUnavailable() {
    #expect(lighten_current_user_application_evidence(geteuid(), -1) == -1)
    #expect(lighten_current_user_application_evidence(geteuid(), 0) == 0)
    #expect(lighten_current_user_application_evidence(geteuid(), 1) == 1)
    #expect(lighten_current_user_application_evidence(geteuid(), 2) == -1)
  }

  @Test(
    "Unavailable foreign executables do not veto current-user scope, while observed foreign activity needs administration"
  )
  func foreignEvidenceRemainsScoped() {
    let foreign: UInt32 = geteuid() == 0 ? 1 : 0
    #expect(lighten_current_user_application_evidence(foreign, -1) == 0)
    #expect(lighten_current_user_application_evidence(foreign, 0) == 0)
    #expect(lighten_current_user_application_evidence(foreign, 1) == 2)
    #expect(lighten_current_user_application_evidence(foreign, 2) == -1)
    let observation = ApplicationActivity(state: .active, scope: .currentUser, requiresAdministrator: true)
    #expect(observation.requiresAdministrator && observation.scope == .currentUser)
  }

  @Test("Invalid native scoped roots are unknown and cannot return signal records")
  func invalidScopedRootIsUnknown() async {
    let observed = await NativeApplicationActivitySource(scope: .currentUser).activity(applicationPath: "relative")
    #expect(observed.state == .unknown && observed.scope == .currentUser && !observed.requiresAdministrator)
    var records: UnsafeMutablePointer<LightenApplicationProcess>?
    var count: UInt32 = 0
    var administrator: Int32 = 0
    #expect(lighten_copy_current_user_application_processes("relative", &records, &count, &administrator) == -1)
    #expect(records == nil && count == 0 && administrator == 0)
  }

  @Test("A real owned empty root requires a complete current-user observation")
  func completeCurrentUserEmptyRoot() async throws {
    let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(temporary) }
    let root = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let observed = await NativeApplicationActivitySource(scope: .currentUser).activity(applicationPath: root)
    #expect(observed.state == .clearObservedProcesses && observed.scope == .currentUser)
    #expect(!observed.requiresAdministrator && observed.processNames.isEmpty)
    var records: UnsafeMutablePointer<LightenApplicationProcess>?
    var count: UInt32 = 0
    var administrator: Int32 = 0
    #expect(
      root.withCString { lighten_copy_current_user_application_processes($0, &records, &count, &administrator) } == 0)
    defer { lighten_free_application_processes(records) }
    #expect(records == nil && count == 0 && administrator == 0)
  }
}
