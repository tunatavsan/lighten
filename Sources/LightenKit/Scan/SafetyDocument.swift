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

      These rules protect sensitive locations and prevent changes to application contents. Generic cleanup suggestions, app-related cleanup, and AI recommendations continue to refuse every protected rule.

      Space permits explicitly selected Trash-only items after checking their complete current inventory. Device backups are selectable only as a whole `MobileSync/Backup/<device identifier>` folder. Virtual machines and container images require their related apps to be closed and no observed current-user process to hold a file or working directory beneath the selected root. Sparse images must be detached; an unavailable attachment check refuses the item. These permissions do not authorize permanent deletion.

      Moving a whole candidate or application package to the Trash is not architecture thinning or language removal: its contents move together and can be restored together. Space Trash plans may include intact nested application packages, localization resources, and application executables; every included application must be closed. Selecting part of a package remains forbidden. Descendant sockets and FIFOs move only as leaves; device nodes and special-file operation roots remain forbidden.

      Catalog Trash plans may include descendants covered by the architecture-slice and localization rules; only regenerable build-output candidates may also include debug symbols. These exceptions do not authorize permanent deletion, which retains the strict protected-content rules.

      This file is generated from `NeverRule.all`. Edit the rules, then regenerate this document with `LIGHTEN_UPDATE_SAFETY_DOC=1 swift test`.

      ## Always protected

      | Protected pattern | Reason | Evidence |
      | --- | --- | --- |
      \(rows(.never))

      ## Explicit selection, Trash only

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
