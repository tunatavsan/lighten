import Foundation
import Testing

@Suite("Localization catalog")
struct LocalizationTests {
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

    let sourceKeys = try Self.localizedKeysInSources()
    #expect(Set(strings.keys) == sourceKeys, "Catalog keys must match localized source literals")

    for key in sourceKeys {
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
    repositoryRoot
      .appending(path: "Resources/Localizable.xcstrings")
  }

  private static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func localizedKeysInSources() throws -> Set<String> {
    let root = repositoryRoot.appending(path: "Sources")
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    let pattern = #"(?:String\s*\(\s*localized:\s*|Text\s*\(\s*|Label\s*\(\s*)"([^"\\]+)""#
    let expression = try NSRegularExpression(pattern: pattern)
    var keys = Set<String>()

    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let source = try String(contentsOf: url, encoding: .utf8)
      let range = NSRange(source.startIndex..., in: source)
      for match in expression.matches(in: source, range: range) {
        guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
        keys.insert(String(source[keyRange]))
      }
    }
    return keys
  }
}
