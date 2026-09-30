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
  let logical: ByteAggregate
}

struct ActionPresentation: Identifiable, Sendable {
  let plan: ActionPlan
  let items: [ActionItemSummary]
  let permanentPlanBuilder: (@MainActor @Sendable () async -> Void)?

  init(
    plan: ActionPlan, items: [ActionItemSummary],
    permanentPlanBuilder: (@MainActor @Sendable () async -> Void)? = nil
  ) {
    self.plan = plan
    self.items = items
    self.permanentPlanBuilder = permanentPlanBuilder
  }

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
  @ObservationIgnored private var alternatePlanID: UUID?

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
  private(set) var preparingAlternate = false
  var message: String?

  func add(_ item: SpaceItem) {
    guard item.canSelect else { return }
    basket[item.path] = BasketEntry(
      path: item.path, label: item.name, device: item.device, inode: item.inode, logical: item.logical)
  }

  func remove(_ path: String) { basket.removeValue(forKey: path) }
  func clearBasket() { basket = [:] }

  /// Items inside another basket item are counted once, through their ancestor;
  /// any incomplete size makes the total a known minimum.
  var basketLogical: ByteAggregate {
    let entries = basket.values
    var total: Int64 = 0
    var complete = true
    for entry in entries where !entries.contains(where: { entry.path.hasPrefix($0.path + "/") }) {
      total &+= entry.logical.completeTotal ?? entry.logical.knownLowerBound
      complete = complete && entry.logical.completeTotal != nil
    }
    return ByteAggregate(knownLowerBound: total, completeTotal: complete ? total : nil)
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
    guard !basket.isEmpty, !busy, !preparingAlternate else { return }
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
          let (logical, allocated) = PlanItemSize.measure(item)
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
        for id in [bundleID] + (item.nestedApplicationIDs ?? [])
        where await MacOSRunningApplicationSource().isRunning(bundleID: id) != false {
          running.append(PlanRejection(.applicationRunning, path: item.sourcePath))
          break
        }
      }
      guard running.isEmpty else {
        pending = nil
        message = running.map { SpaceText.rejection($0) }.joined(separator: "\n")
        return
      }
      // Planning is complete before publishing the confirmation synchronously.
      busy = false
      present(plan: plan, items: summary)
      message = nil
    case .failure(let refused):
      pending = nil
      message = refused.rejections.map { SpaceText.rejection($0) }.joined(separator: "\n")
    }
  }

  /// Other modules supply their own guarded plan and reason summary.
  func present(
    plan: ActionPlan, items: [ActionItemSummary],
    permanentPlanBuilder: (@MainActor @Sendable () async -> Void)? = nil
  ) {
    guard !busy, Set(plan.items.map(\.id)) == Set(items.map(\.id)),
      !preparingAlternate || pending?.plan.id == alternatePlanID
    else { return }
    pending = ActionPresentation(
      plan: plan, items: items,
      permanentPlanBuilder: plan.kind == .trash ? permanentPlanBuilder : nil)
  }

  func requestPermanent(_ presentation: ActionPresentation) async {
    guard !busy, !preparingAlternate, pending?.plan == presentation.plan,
      let builder = presentation.permanentPlanBuilder
    else { return }
    preparingAlternate = true
    alternatePlanID = presentation.plan.id
    defer {
      preparingAlternate = false
      alternatePlanID = nil
    }
    await builder()
  }

  func invalidatePending(expectedPlanID: UUID?) {
    guard pending?.plan.id == expectedPlanID else { return }
    pending = nil
  }

  /// Claim synchronously while the confirmation sheet still owns its presentation.
  /// SwiftUI may clear `pending` as soon as the sheet begins dismissing.
  func takeConfirmedPlan(_ presentation: ActionPresentation) -> ActionPlan? {
    guard !busy, !preparingAlternate, claimedPlan == nil,
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
      message = FailureText.describe(error)
    }
    await reloadHistory()
  }

  func reloadHistory() async {
    do {
      let readout = try await historyService.reconcile()
      var metadata: [UUID: HistoryMetadata] = [:]
      for plan in readout.plans {
        for item in plan.metadata {
          metadata[item.id] = HistoryMetadata(
            path: item.sourcePath, logicalBytes: item.logicalBytes, allocatedBytes: item.allocatedBytes)
        }
      }
      history = readout
      historyMetadata = metadata
    } catch {
      message = FailureText.describe(error)
    }
  }

  func repairHistory() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      _ = try await journal.archiveAndRestart()
      message = String(localized: "History was repaired. Items still in Trash can be restored.")
    } catch {
      message = FailureText.describe(error)
    }
    await reloadHistory()
  }

  func undo(_ plan: HistoryPlan) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await historyService.undo(planID: plan.id)
      message = nil
    } catch {
      message = FailureText.describe(error)
    }
    await reloadHistory()
  }

  func undo(_ item: HistoryItem) async {
    busy = true
    defer { busy = false }
    do {
      try await historyService.undo(planID: item.planID, itemID: item.itemID)
      message = nil
    } catch {
      message = FailureText.describe(error)
    }
    await reloadHistory()
  }
}
