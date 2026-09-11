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

      Lighten never offers the following locations or operations for cleanup. These protections are built into the app and apply before any cleanup choice is shown.

      This file is generated from `NeverRule.all`. Edit the rules, then regenerate this document through the safety document test.

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
