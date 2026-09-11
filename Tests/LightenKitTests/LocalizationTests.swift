import Foundation
import Testing

@Suite("Localization catalog")
struct LocalizationTests {
  private let requiredKeys = [
    "Overview",
    "Clean",
    "Memory",
    "Health",
    "Settings",
    "Pre-alpha build",
  ]

  private let requiredLanguages = ["en", "tr"]

  @Test("Every required key has translated English and Turkish values")
  func requiredLocalizationsAreComplete() throws {
    let data = try Data(contentsOf: Self.catalogURL)
    let root = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any],
      "The string catalog must contain a JSON object at its root"
    )
    #expect(root["sourceLanguage"] as? String == "en")

    let strings = try #require(
      root["strings"] as? [String: Any],
      "The string catalog must contain a strings object"
    )

    for key in requiredKeys {
      let entry = try #require(
        strings[key] as? [String: Any],
        "Missing required localization key: \(key)"
      )
      let localizations = try #require(
        entry["localizations"] as? [String: Any],
        "Missing localizations for key: \(key)"
      )

      for language in requiredLanguages {
        let localization = try #require(
          localizations[language] as? [String: Any],
          "Missing \(language) localization for key: \(key)"
        )
        let stringUnit = try #require(
          localization["stringUnit"] as? [String: Any],
          "Missing \(language) string unit for key: \(key)"
        )
        #expect(
          stringUnit["state"] as? String == "translated",
          "The \(language) localization for \(key) must be translated"
        )
        let value = try #require(
          stringUnit["value"] as? String,
          "Missing \(language) value for key: \(key)"
        )
        #expect(
          value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
          "The \(language) localization for \(key) must not be empty"
        )
      }
    }
  }

  private static var catalogURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Resources/Localizable.xcstrings")
  }
}
