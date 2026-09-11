import Foundation
import Testing

@testable import LightenKit

@Suite("Safety document")
struct SafetyDocumentTests {
  @Test("Checked-in safety document matches NeverRule.all")
  func checkedInDocumentMatchesRules() throws {
    let generated = SafetyDocument.markdown()

    let documentURL =
      repositoryRoot
      .appending(path: "docs")
      .appending(path: "SAFETY.md")

    if ProcessInfo.processInfo.environment["LIGHTEN_UPDATE_SAFETY_DOC"] == "1" {
      try generated.write(to: documentURL, atomically: true, encoding: .utf8)
    }

    let checkedIn = try String(contentsOf: documentURL, encoding: .utf8)
    #expect(checkedIn == generated)
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
