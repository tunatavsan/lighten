import Foundation
import LightenKit
import Observation

struct ActionItemSummary: Sendable {
  let id: UUID
  let label: String
  let path: String
  let reason: String
  let logicalBytes: Int64?
  let allocatedBytes: Int64?
}

struct ActionPresentation: Identifiable, Sendable {
  let plan: ActionPlan
  let items: [ActionItemSummary]
  var id: UUID { plan.id }
}

struct HistoryMetadata: Sendable {
  let path: String
  let logicalBytes: Int64
  let allocatedBytes: Int64
}

@MainActor @Observable
final class ActionStore {
  @ObservationIgnored private let journal: JSONLActionJournal
  @ObservationIgnored private let executor: ActionExecutor
  @ObservationIgnored private let historyService: ActionHistory
  @ObservationIgnored private var claimedPlan: ActionPlan?

  init(
    journal: JSONLActionJournal = JSONLActionJournal(),
    trash: any TrashMoving = MacOSTrashService()
  ) {
    self.journal = journal
    self.executor = ActionExecutor(
      journal: journal, trash: trash,
      activity: MacOSProcessActivitySource(),
      runningApplications: MacOSRunningApplicationSource())
    self.historyService = ActionHistory(journal: journal)
  }

  var basket: [UUID: ActionItemSummary] = [:]
  var basketRunID: UUID?
  var pending: ActionPresentation?
  var result: ActionResult?
  var resultKind: ActionKind?
  var history: HistoryReadout?
  var historyMetadata: [UUID: HistoryMetadata] = [:]
  var busy = false
  var message: String?

  func add(_ item: SpaceItem, snapshot: ScanSnapshot) {
    guard item.canSelect, item.path != snapshot.rootPath else { return }
    if basketRunID != snapshot.runID { basket = [:] }
    basketRunID = snapshot.runID
    basket[item.id] = ActionItemSummary(
      id: item.id, label: item.name, path: item.path,
      reason: String(localized: "Selected in Space"),
      logicalBytes: item.logical.completeTotal,
      allocatedBytes: item.allocated.completeTotal)
  }

  func remove(_ id: UUID) { basket.removeValue(forKey: id) }
  func clearBasket() {
    basket = [:]
    basketRunID = nil
  }

  var basketLogicalBytes: Int64 {
    basket.values.reduce(0) { $0 + ($1.logicalBytes ?? 0) }
  }

  var pendingTrashLogicalBytes: Int64 {
    (history?.items ?? []).filter { $0.state == .inTrash }.reduce(0) {
      $0 + (historyMetadata[$1.itemID]?.logicalBytes ?? 0)
    }
  }

  var pendingTrashCount: Int { history?.items.filter { $0.state == .inTrash }.count ?? 0 }

  func prepare(snapshot: ScanSnapshot?) async {
    guard let snapshot, basketRunID == snapshot.runID else {
      message = String(localized: "Selection is from an earlier scan")
      return
    }
    busy = true
    defer { busy = false }
    do {
      let plan = try await PlanService().makePlanAsync(
        snapshot: snapshot, selectedIDs: Set(basket.keys))
      let reason = String(localized: "Selected in Space")
      let summary = await Task.detached {
        let nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        return plan.items.map { item in
          let node = nodes[item.id]
          return ActionItemSummary(
            id: item.id, label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
            path: item.sourcePath, reason: reason,
            logicalBytes: node?.logical.completeTotal,
            allocatedBytes: node?.allocated.completeTotal)
        }
      }.value
      present(plan: plan, items: summary)
      message = nil
    } catch {
      pending = nil
      message = String(describing: error)
    }
  }

  /// Other modules supply their own guarded plan and reason summary.
  func present(plan: ActionPlan, items: [ActionItemSummary]) {
    guard Set(plan.items.map(\.id)) == Set(items.map(\.id)) else { return }
    pending = ActionPresentation(plan: plan, items: items)
  }

  /// Claim synchronously while the confirmation sheet still owns its presentation.
  /// SwiftUI may clear `pending` as soon as the sheet begins dismissing.
  func takeConfirmedPlan(_ presentation: ActionPresentation) -> ActionPlan? {
    guard !busy, claimedPlan == nil,
      pending?.plan == presentation.plan,
      presentation.plan.kind == .trash || presentation.plan.kind == .catalogDelete
    else { return nil }
    claimedPlan = presentation.plan
    pending = nil
    busy = true
    result = nil
    resultKind = nil
    return presentation.plan
  }

  func executeConfirmed(_ plan: ActionPlan) async {
    guard claimedPlan == plan else { return }
    claimedPlan = nil
    defer { busy = false }
    do {
      let confirmation =
        plan.kind == .catalogDelete
        ? IrreversibleConfirmation(planID: plan.id, method: .catalogDelete) : nil
      result = try await executor.execute(plan, confirmation: confirmation)
      resultKind = plan.kind
      basket = [:]
      basketRunID = nil
      message = nil
    } catch {
      message = String(describing: error)
    }
    await reloadHistory()
  }

  func reloadHistory() async {
    do {
      let readout = try await historyService.reconcile()
      let journalReadout = try await journal.read()
      let metadata = await Task.detached {
        var result: [UUID: HistoryMetadata] = [:]
        for record in journalReadout.records where record.kind == .intent {
          guard let plan = record.plan else { continue }
          for item in plan.items {
            let logical = item.inventory.reduce(Int64(0)) { sum, entry in
              let (value, overflow) = sum.addingReportingOverflow(entry.identity?.logicalBytes ?? 0)
              return overflow ? Int64.max : value
            }
            let allocated = item.inventory.reduce(Int64(0)) { sum, entry in
              let (value, overflow) = sum.addingReportingOverflow(entry.identity?.allocatedBytes ?? 0)
              return overflow ? Int64.max : value
            }
            result[item.id] = HistoryMetadata(
              path: item.sourcePath, logicalBytes: logical, allocatedBytes: allocated)
          }
        }
        return result
      }.value
      history = readout
      historyMetadata = metadata
    } catch {
      message = String(describing: error)
    }
  }

  func undo(_ item: HistoryItem) async {
    busy = true
    defer { busy = false }
    do {
      try await historyService.undo(planID: item.planID, itemID: item.itemID)
      message = nil
    } catch {
      message = String(describing: error)
    }
    await reloadHistory()
  }
}
