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

struct BasketEntry: Sendable, Equatable {
  let path: String
  let label: String
  let device: UInt64
  let inode: UInt64
  let logicalBytes: Int64
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
      activity: MacOSProcessActivitySource(), related: .system,
      runningApplications: MacOSRunningApplicationSource())
    self.historyService = ActionHistory(journal: journal)
  }

  var basket: [String: BasketEntry] = [:]
  var pending: ActionPresentation?
  var result: ActionResult?
  var resultKind: ActionKind?
  var history: HistoryReadout?
  var historyMetadata: [UUID: HistoryMetadata] = [:]
  var busy = false
  var message: String?

  func add(_ item: SpaceItem) {
    guard item.canSelect else { return }
    basket[item.path] = BasketEntry(
      path: item.path, label: item.name, device: item.device, inode: item.inode,
      logicalBytes: item.logical.completeTotal ?? item.logical.knownLowerBound)
  }

  func remove(_ path: String) { basket.removeValue(forKey: path) }
  func clearBasket() { basket = [:] }

  var basketLogicalBytes: Int64 {
    basket.values.reduce(0) { $0 + $1.logicalBytes }
  }

  var pendingTrashLogicalBytes: Int64 {
    (history?.items ?? []).filter { $0.state == .inTrash }.reduce(0) {
      $0 + (historyMetadata[$1.itemID]?.logicalBytes ?? 0)
    }
  }

  var pendingTrashCount: Int { history?.items.filter { $0.state == .inTrash }.count ?? 0 }

  /// Builds the plan from a fresh exact inventory of each basket item. The scan
  /// tree only told us where to look.
  func prepare(scanRoot: String, runID: UUID?) async {
    guard !basket.isEmpty else { return }
    busy = true
    defer { busy = false }
    let selections = basket.values.map {
      PlanService.Selection(path: $0.path, device: $0.device, inode: $0.inode)
    }
    let reason = String(localized: "Selected in Space")
    let outcome = await Task.detached { () -> Result<(ActionPlan, [ActionItemSummary]), PlanRejections> in
      do throws(PlanRejections) {
        let plan = try PlanService().makeSpacePlan(
          selections: selections, scanRootPath: scanRoot, runID: runID ?? UUID())
        let summary = plan.items.map { item in
          var logical: Int64 = 0
          var allocated: Int64 = 0
          for entry in item.inventory where entry.identity?.kind != .directory {
            logical &+= entry.identity?.logicalBytes ?? 0
            allocated &+= entry.identity?.allocatedBytes ?? 0
          }
          return ActionItemSummary(
            id: item.id, label: URL(fileURLWithPath: item.sourcePath).lastPathComponent,
            path: item.sourcePath, reason: reason, logicalBytes: logical, allocatedBytes: allocated)
        }
        return .success((plan, summary))
      } catch {
        return .failure(error)
      }
    }.value
    switch outcome {
    case .success(let (plan, summary)):
      var running: [PlanRejection] = []
      for item in plan.items {
        guard let bundleID = item.applicationBundleID else { continue }
        if await MacOSRunningApplicationSource().isRunning(bundleID: bundleID) != false {
          running.append(PlanRejection(.applicationRunning, path: item.sourcePath))
        }
      }
      guard running.isEmpty else {
        pending = nil
        message = running.map(SpaceText.rejection).joined(separator: "\n")
        return
      }
      present(plan: plan, items: summary)
      message = nil
    case .failure(let refused):
      pending = nil
      message = refused.rejections.map(SpaceText.rejection).joined(separator: "\n")
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
