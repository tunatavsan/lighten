import Foundation

public enum SafetyDocument {
  public static func markdown(rules: [NeverRule] = NeverRule.all) -> String {
    func rows(_ scope: NeverRule.Scope) -> String {
      rules.filter { $0.scope == scope }.map { rule in
        let evidence = rule.evidence.map(escapeTableCell) ?? "—"
        return "| `\(escapeCode(rule.pattern))` | \(escapeTableCell(rule.reason)) | \(evidence) |"
      }.joined(separator: "\n")
    }

    return
      """
      # Safety

      Lighten requires evidence for its cleanup suggestions. Name similarity alone is not evidence, shared installed data is not suggested, and incomplete ownership observations remain visible without automatic selection. The patterns below filter recommendations and explain valuable content.

      A user's explicit selection follows the Finder model. Confirmation shows the chosen roots and observed sizes, with one warning example when valuable content is known. Moving to the Trash checks that the same roots remain present, protects base locations and Lighten itself, and requires running applications and executable-location-proven helpers to close. Descendant protection patterns, application metadata and a complete subtree inventory do not block the user's choice. Symbolic links move as links; their targets are never removed through the link.

      Base locations are `/`, `/System`, `/Library`, `/Users`, `/Applications`, the home directory and its `Library` directory, including physical aliases. Root or other-user ownership requires macOS authorization; an unavailable authorization path remains an explicit permission requirement.

      Permanent removal requires a separate irreversible confirmation. It traverses pinned directory descriptors, never follows symbolic links, and records actual irreversible progress. The same base protections apply. History records the actual returned Trash path; Undo restores that item without replacing an occupied name and reports changed or missing Trash items honestly.

      This file is generated from `NeverRule.all`. Edit the rules, then regenerate this document with `LIGHTEN_UPDATE_SAFETY_DOC=1 swift test`.

      ## Recommendation protections

      | Protected pattern | Reason | Evidence |
      | --- | --- | --- |
      \(rows(.never))

      ## Explicit selection warnings

      | Protected pattern | Reason | Evidence |
      | --- | --- | --- |
      \(rows(.explicitTrashOnly))

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
