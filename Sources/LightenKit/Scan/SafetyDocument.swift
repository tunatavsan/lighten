import Foundation

public enum SafetyDocument {
  public static func markdown(rules: [NeverRule] = NeverRule.all) -> String {
    let rows = rules.map { rule in
      let evidence = rule.evidence.map(escapeTableCell) ?? "—"
      return "| `\(escapeCode(rule.pattern))` | \(escapeTableCell(rule.reason)) | \(evidence) |"
    }

    return
      """
      # Safety

      Lighten will never offer these locations or operations for cleanup.

      This file is generated from `NeverRule.all`. Edit the rules, then regenerate this document with `LIGHTEN_UPDATE_SAFETY_DOC=1 swift test`.

      | Protected pattern | Reason | Evidence |
      | --- | --- | --- |
      \(rows.joined(separator: "\n"))

      """
  }

  private static func escapeTableCell(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "|", with: "\\|")
      .replacingOccurrences(of: "\n", with: " ")
  }

  private static func escapeCode(_ value: String) -> String {
    escapeTableCell(value).replacingOccurrences(of: "`", with: "\\`")
  }
}
