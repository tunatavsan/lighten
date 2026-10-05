import Foundation
import Testing

/// The app target reads colour, font size and animation timing from `Theme` only. This scans
/// its sources for literals; `Design/Theme.swift` and `Design/Glass.swift` are where they live.
@Suite("Design token literals")
struct DesignTokenLiteralTests {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  static let enforced = "Sources/Lighten"
  static let definitions: Set<String> = [
    "Sources/Lighten/Design/Theme.swift",
    "Sources/Lighten/Design/Glass.swift",
  ]
  /// Screens still being moved to tokens.
  static let pending: Set<String> = [
    "Sources/Lighten/Actions/ActionViews.swift",
    "Sources/Lighten/Apps/AppsBasketView.swift",
    "Sources/Lighten/Apps/AppsView.swift",
    "Sources/Lighten/Apps/ApplicationIconView.swift",
    "Sources/Lighten/Clean/CleanView.swift",
    "Sources/Lighten/Duplicates/DuplicateView.swift",
    "Sources/Lighten/Interface/ActionFeedback.swift",
    "Sources/Lighten/Interface/FileAccessViews.swift",
    "Sources/Lighten/Interface/LegacyToolScreen.swift",
    "Sources/Lighten/Overview/LightenSettingsView.swift",
    "Sources/Lighten/Services/FailureReasonView.swift",
    "Sources/Lighten/Space/SpaceStore.swift",
    "Sources/Lighten/Space/SpaceView.swift",
    "Sources/Lighten/Actions/ActionStore.swift",
  ]

  /// (what, pattern). A hit on a code line, with comments and string contents removed, fails.
  static let rules: [(String, String)] = [
    (
      "literal colour",
      #"(?:Color|NSColor)\s*\(\s*(?:red|white|hue|srgbRed|calibratedRed|calibratedWhite|deviceRed|deviceWhite|displayP3Red|\.sRGB)"#
    ),
    ("literal colour", #"#colorLiteral"#),
    (
      "literal colour",
      #"(?:Color|NSColor)\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|white|black|gray|system[A-Z]\w*)\b"#
    ),
    (
      "literal colour",
      #"(?:foregroundStyle|foregroundColor|fill|stroke|tint|background)\(\s*\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|white|black|gray)\b"#
    ),
    ("literal font size", #"\.system\(\s*size:"#),
    (
      "literal font size",
      #"NSFont\.(?:systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont)\(\s*ofSize:"#
    ),
    ("literal font size", #"\.custom\("#),
    (
      "literal duration",
      #"\.(?:spring|easeOut|easeIn|easeInOut|linear|smooth|snappy|bouncy|interactiveSpring|interpolatingSpring|timingCurve)\("#
    ),
    ("literal duration", #"\.animation\(\.default"#),
    ("old style name", #"\bLightenStyle\b"#),
  ]

  static func swiftFiles() throws -> [(path: String, url: URL)] {
    let base = root.appendingPathComponent(enforced)
    let urls =
      FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    return urls.map { (String($0.path.dropFirst(root.path.count + 1)), $0) }
      .filter { !definitions.contains($0.path) && !pending.contains($0.path) }
      .filter { !$0.path.hasSuffix("Interface/LightenStyle.swift") }
  }

  /// `line` without a trailing comment and with string literal contents blanked.
  static func code(_ line: String) -> String {
    var inString = false
    var previous: Character = " "
    var result = ""
    for character in line {
      if character == "\"" && previous != "\\" {
        inString.toggle()
        result.append(character)
      } else if inString {
        result.append(" ")
      } else if character == "/" && previous == "/" {
        result.removeLast()
        break
      } else {
        result.append(character)
      }
      previous = character
    }
    return result
  }

  static func violations(in text: String, file: String) throws -> [String] {
    let patterns = try rules.map { ($0.0, try NSRegularExpression(pattern: $0.1)) }
    var found: [String] = []
    for (number, line) in text.components(separatedBy: "\n").enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
      let code = Self.code(line)
      for (what, regex) in patterns
      where regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
        found.append("\(file):\(number + 1) \(what): \(trimmed)")
      }
    }
    return found
  }

  @Test("App sources carry no literal colour, font size or animation timing")
  func noLiterals() throws {
    let files = try Self.swiftFiles()
    #expect(files.count >= 10)
    var all: [String] = []
    for file in files {
      all += try Self.violations(in: String(contentsOf: file.url, encoding: .utf8), file: file.path)
    }
    #expect(all.isEmpty, "\(all.joined(separator: "\n"))")
  }

  @Test("Every pending file still exists")
  func pendingFilesExist() {
    for path in Self.pending {
      #expect(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(path).path), "\(path)")
    }
  }

  @Test("The rules catch literals and let token use through")
  func rulesWork() throws {
    let bad = [
      #".foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.4))"#,
      #".fill(.blue)"#,
      #"let c = NSColor.systemOrange"#,
      #".font(.system(size: 13))"#,
      #"label.font = NSFont.systemFont(ofSize: 12)"#,
      #"withAnimation(.spring(duration: 0.3)) { }"#,
      #".animation(.easeOut(duration: 0.12), value: x)"#,
      #".foregroundStyle(LightenStyle.muted)"#,
    ]
    for line in bad {
      #expect(try !Self.violations(in: line, file: "x").isEmpty, "\(line)")
    }
    let good = [
      #".foregroundStyle(Theme.Palette.ink)"#,
      #".font(Theme.Font.body)"#,
      #"withAnimation(Theme.Motion.quick) { }"#,
      #".animation(Theme.Motion.resolve(Theme.Motion.standard, reduceMotion: rm), value: x)"#,
      #"Text("fill(.blue) in a string is fine") // .font(.system(size: 9)) in a comment"#,
    ]
    for line in good {
      #expect(try Self.violations(in: line, file: "x").isEmpty, "\(line)")
    }
  }
}
