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
    let bilingualCopyPaths = Set([
      root.appending(path: "Lighten/Apps/AppsView.swift").path,
      root.appending(path: "Lighten/Services/FailureText.swift").path,
      root.appending(path: "Lighten/Space/SpaceText.swift").path,
    ])

    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let source = try String(contentsOf: url, encoding: .utf8)
      let range = NSRange(source.startIndex..., in: source)
      for match in expression.matches(in: source, range: range) {
        guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
        keys.insert(String(source[keyRange]))
      }
      if bilingualCopyPaths.contains(url.path) { keys.formUnion(try bilingualCopyKeys(in: source)) }
    }
    return keys
  }

  @Test("Bilingual copy extraction decodes actual literals and excludes code identifiers")
  func bilingualCopyLiteralsArePrecise() throws {
    let source = #"""
      let copy = ("Keep \"quoted\" \u{1F4C1}\nfiles.", "Alıntılı dosyaları saklayın.")
      case "machine-id", "internal-code": break
      let identifiers = ["implementation-id", "another-id"]
      helper("not a bilingual copy", "internal value")
      helper ("not a spaced call copy", "internal value")
      let identifiersTuple = ("implementation-id", "another-id")
      Other.text("not the local copy helper", "internal value")
      return FailureText.text("A direct reason. Choose another item.", "Doğrudan neden. Başka bir öğe seçin.", turkish: true)
      """#
    #expect(
      try Self.bilingualCopyKeys(in: source) == [
        "Keep \"quoted\" 📁\nfiles.", "A direct reason. Choose another item.",
      ])
    #expect(throws: CopyLiteralFailure.interpolation) {
      try Self.bilingualCopyKeys(in: #"text("Current \(path)", "Güncel konum", turkish: true)"#)
    }
  }

  private enum CopyLiteralFailure: Error, Equatable { case invalidEscape, invalidUnicode, interpolation }

  /// Only these two files define literal (English, Turkish) display-copy pairs.
  private static func bilingualCopyKeys(in source: String) throws -> Set<String> {
    let literal = #""((?:\\.|[^"\\])*)""#
    let opening = #"(?:(?<![A-Za-z0-9_.])(?:FailureText\.)?text\s*\(|\bcopy\s*=\s*\(|(?m:^\s*\())"#
    let pattern = opening + #"\s*"# + literal + #"\s*,\s*"# + literal + #"\s*(?:\)|,\s*turkish:)"#
    let expression = try NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..., in: source)
    var keys = Set<String>()
    for match in expression.matches(in: source, range: range) {
      let english = try #require(Range(match.range(at: 1), in: source))
      let translation = try #require(Range(match.range(at: 2), in: source))
      let key = try decodedCopyLiteral(String(source[english]))
      let translated = try decodedCopyLiteral(String(source[translation]))
      #expect(!key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(!translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      keys.insert(key)
    }
    return keys
  }

  private static func decodedCopyLiteral(_ source: String) throws -> String {
    let scalars = Array(source.unicodeScalars)
    var result = ""
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      index += 1
      guard scalar == "\\" else {
        result.unicodeScalars.append(scalar)
        continue
      }
      guard index < scalars.count else { throw CopyLiteralFailure.invalidEscape }
      let escaped = scalars[index]
      index += 1
      switch escaped {
      case "0": result.append("\0")
      case "t": result.append("\t")
      case "n": result.append("\n")
      case "r": result.append("\r")
      case "\\", "\"", "'": result.unicodeScalars.append(escaped)
      case "(": throw CopyLiteralFailure.interpolation
      case "u":
        guard index < scalars.count, scalars[index] == "{" else { throw CopyLiteralFailure.invalidUnicode }
        index += 1
        let start = index
        while index < scalars.count, scalars[index] != "}" { index += 1 }
        guard index < scalars.count, index > start, index - start <= 8 else { throw CopyLiteralFailure.invalidUnicode }
        let digits = String(String.UnicodeScalarView(scalars[start..<index]))
        guard let number = UInt32(digits, radix: 16), let value = UnicodeScalar(number) else {
          throw CopyLiteralFailure.invalidUnicode
        }
        result.unicodeScalars.append(value)
        index += 1
      default: throw CopyLiteralFailure.invalidEscape
      }
    }
    return result
  }

}
