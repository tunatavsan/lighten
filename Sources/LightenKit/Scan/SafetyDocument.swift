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

      These rules protect sensitive locations and prevent changes to application contents.

      Moving a whole candidate or application package to the Trash is not architecture thinning or language removal: its contents move together and can be restored together. Catalog Trash plans may include descendants covered by the architecture-slice and localization rules; only regenerable build-output candidates may also include debug symbols. These exceptions do not authorize permanent deletion, which retains the strict protected-content rules.

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
