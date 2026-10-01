import Foundation
import Testing

@testable import Lighten
@testable import LightenKit

@Test(
  "Unverified removal copy distinguishes retained sources, possible Trash moves and permanent changes",
  arguments: [
    (ActionMutationStage?.none, true), (.notStarted, false), (.sourceRetained, false),
    (.trashCallUnverified, true), (.trashMoveObserved, true), (.permanentMutation, true),
  ])
@MainActor func actionOutcomeCopyStage(stage: ActionMutationStage?, unverified: Bool) {
  let item = ItemActionResult(itemID: UUID(), outcome: .uncertain, mutationStage: stage)
  #expect(FailureText.executionIsUnverified(item) == unverified)
  let english = FailureText.execution(item, turkish: false)
  let turkish = FailureText.execution(item, turkish: true)
  #expect(english != turkish)
  #expect(!english.contains("uncertain") && !english.contains("mutationStage"))
  if !unverified {
    #expect(english == "This item was not removed.")
    #expect(turkish == "Bu öğe kaldırılmadı.")
  } else {
    #expect(!english.contains("was not removed"))
    #expect(english.contains("History") && turkish.contains("Geçmiş"))
    if stage == .permanentMutation {
      #expect(english.contains("cannot be undone") && turkish.contains("geri alınamaz"))
    } else {
      #expect(english.contains("Finder") && turkish.contains("Finder"))
    }
  }
}

@Test("Unverified outcomes never announce that no items were removed", arguments: [false, true])
@MainActor func actionOutcomeSummaryKeepsUncertainty(withAppliedItem: Bool) {
  let uncertain = PlanItem(id: UUID(), sourcePath: "/fixture/unknown", inventory: [], ancestors: [])
  let applied = PlanItem(id: UUID(), sourcePath: "/fixture/applied", inventory: [], ancestors: [])
  let plan = ActionPlan(
    snapshotRunID: UUID(), kind: .trash, items: withAppliedItem ? [uncertain, applied] : [uncertain])
  let result = ActionResult(
    planID: plan.id,
    items: [ItemActionResult(itemID: uncertain.id, outcome: .uncertain, mutationStage: .trashCallUnverified)]
      + (withAppliedItem ? [ItemActionResult(itemID: applied.id, outcome: .applied)] : []))
  let actions = ActionStore()
  actions.publishExecution(
    plan: plan, result: result,
    summaries: plan.items.map {
      ActionItemSummary(
        id: $0.id, label: "Fixture", path: $0.sourcePath, reason: "Fixture", logicalBytes: nil, allocatedBytes: nil)
    })
  #expect(actions.unverifiedResultCount == 1)
  #expect(actions.completedSummary?.contains("1 item outcomes could not be verified") == true)
  #expect(actions.completedSummary?.contains("No items were removed") == false)
  #expect(actions.resultFailures.first?.detail.contains("may be in Trash") == true)
}

@Test("Personal library warnings are human, translated and preserve actual library paths")
@MainActor func personalLibraryWarningCopy() {
  let path = "/fixture/Project.logicx"
  let english = SpaceText.warning(.personalLibrary, paths: [path], turkish: false)
  let turkish = SpaceText.warning(.personalLibrary, paths: [path], turkish: true)
  #expect(english.contains("projects, recordings or edits") && english.contains("another copy is not known"))
  #expect(turkish.contains("projelerinizi") && turkish.contains("başka bir kopyası bilinmiyor"))
  #expect(english.contains(path) && turkish.contains(path))
  #expect(!english.contains("only copy") && !turkish.contains("tek kopya"))
}
