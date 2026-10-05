import Darwin
import Foundation
import LightenKit
import Observation
import SwiftUI

struct ActionApplicationGroup: Sendable, Equatable {
  let path: String
  let name: String
}

struct ActionItemSummary: Sendable {
  let id: UUID
  let label: String
  let path: String
  let reason: String
  let logicalBytes: Int64?
  let allocatedBytes: Int64?
  let warning: ProtectiveWarning?
  let observedSize: ObservedPlanSize
  let warningPaths: [String]
  let applicationGroup: ActionApplicationGroup?

  nonisolated init(
    id: UUID, label: String, path: String, reason: String, logicalBytes: Int64?, allocatedBytes: Int64?,
    warning: ProtectiveWarning? = nil, observedSize: ObservedPlanSize? = nil, warningPaths: [String] = [],
    applicationGroup: ActionApplicationGroup? = nil
  ) {
    self.id = id
    self.label = label
    self.path = path
    self.reason = reason
    self.logicalBytes = logicalBytes
    self.allocatedBytes = allocatedBytes
    self.warning = warning
    self.warningPaths = Array(warningPaths.prefix(3))
    self.applicationGroup = applicationGroup
    self.observedSize =
      observedSize?.validated
      ?? ObservedPlanSize(
        logical: logicalBytes.map { ByteAggregate(knownLowerBound: $0, completeTotal: $0) },
        allocated: allocatedBytes.map { ByteAggregate(knownLowerBound: $0, completeTotal: $0) })
  }
}

struct BasketEntry: Sendable, Equatable {
  let path: String
  let label: String
  let device: UInt64
  let inode: UInt64
  let logical: ByteAggregate
  var allocated: ByteAggregate? = nil
  var identity: FileIdentity? = nil
  var warning: ProtectiveWarning? = nil
  var warningPaths: [String] = []
  var applicationPackagePaths: [String] = []
}

struct ActionPresentation: Identifiable, Sendable {
  let plan: ActionPlan
  let items: [ActionItemSummary]
  let permanentPlanBuilder: (@MainActor @Sendable () async -> Void)?
  let rejectedItems: [PlanRejection]
  let hasRunningApplications: Bool

  init(
    plan: ActionPlan, items: [ActionItemSummary],
    permanentPlanBuilder: (@MainActor @Sendable () async -> Void)? = nil,
    rejectedItems: [PlanRejection] = [], hasRunningApplications: Bool = false
  ) {
    self.plan = plan
    self.items = items
    self.permanentPlanBuilder = permanentPlanBuilder
    self.rejectedItems = rejectedItems
    self.hasRunningApplications = hasRunningApplications
  }

  var id: UUID { plan.id }
}

struct HistoryMetadata: Sendable {
  let path: String
  let logicalBytes: Int64
  let allocatedBytes: Int64
  let observedSize: ObservedPlanSize
}

@MainActor @Observable
final class ActionStore {
  @ObservationIgnored private let journal: JSONLActionJournal
  @ObservationIgnored private let executor: ActionExecutor
  @ObservationIgnored private let planService: PlanService
  @ObservationIgnored private let preferences: RemovalPreferences
  @ObservationIgnored private let applicationActivity: any ApplicationActivitySource
  @ObservationIgnored private let userSelectionApplicationActivity: any ApplicationActivitySource
  @ObservationIgnored private var claimedCloseRunningApplications = false
  @ObservationIgnored private let historyService: ActionHistory
  @ObservationIgnored private var claimedPlan: ActionPlan?
  @ObservationIgnored private var alternatePlanID: UUID?
  @ObservationIgnored private var claimedSummaries: [ActionItemSummary] = []
  @ObservationIgnored private var claimedRejections: [PlanRejection] = []
  @ObservationIgnored private var basketRevision = 0
  @ObservationIgnored var onDisplayChange: (@MainActor (ActionDisplayChange) -> Void)?
  @ObservationIgnored var onDisplayDiscrepancy: (@MainActor (ActionDisplayChange) -> Void)?
  @ObservationIgnored private var verificationTask: Task<Void, Never>?
  @ObservationIgnored private var appliedDisplayItems: [UUID: ActionDisplayItem] = [:]
  private(set) var displayRevision = 0
  private(set) var resultSummaries: [ActionItemSummary] = []
  private(set) var resultFailures: [ActionDisplayFailure] = []
  private(set) var resultRejections: [PlanRejection] = []
  private(set) var restoredItemIDs: Set<UUID> = []
  var reduceMotion = false
  var displayAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.24) }

  init(
    journal: JSONLActionJournal = JSONLActionJournal(),
    trash: any TrashMoving = MacOSTrashService(),
    historyService: ActionHistory? = nil, planService: PlanService = PlanService(),
    runningApplications: any RunningApplicationSource = NativeRunningApplicationSource(),
    preferences: RemovalPreferences = .shared,
    applicationActivity: (any ApplicationActivitySource)? = nil,
    userSelectionApplicationActivity: (any ApplicationActivitySource)? = nil,
    applicationClosing: any UserSelectionApplicationClosing = NativeUserSelectionApplicationClosing()
  ) {
    self.journal = journal
    self.preferences = preferences
    self.applicationActivity = applicationActivity ?? NativeApplicationActivitySource()
    let userActivity =
      userSelectionApplicationActivity ?? applicationActivity ?? NativeApplicationActivitySource(scope: .currentUser)
    self.userSelectionApplicationActivity = userActivity
    self.planService = planService
    self.executor = ActionExecutor(
      journal: journal, trash: trash, guardService: ActionGuard(homeDirectory: planService.homeDirectory),
      activity: MacOSProcessActivitySource(), related: .system,
      runningApplications: runningApplications, applicationActivity: applicationActivity,
      userSelectionApplicationActivity: userActivity, applicationClosing: applicationClosing)
    self.historyService = historyService ?? ActionHistory(journal: journal)
  }

  var basket: [String: BasketEntry] = [:] {
    didSet {
      guard basket != oldValue else { return }
      basketRevision += 1
      pending = nil
      clearKeptItems()
    }
  }
  var pending: ActionPresentation?
  var result: ActionResult?
  var resultKind: ActionKind?
  var history: HistoryReadout?
  var historyMetadata: [UUID: HistoryMetadata] = [:]
  private(set) var expandedHistoryGroups: Set<UUID> = []
  private(set) var loadingHistoryGroups: Set<UUID> = []
  var undoResults: [UUID: UndoPlanResult] = [:]
  var busy = false
  private(set) var preparingAlternate = false
  var message: String?

  func add(_ item: SpaceItem, warningPath: String? = nil, tree: ScanTree? = nil) {
    guard !busy, Self.canManuallySelect(item), item.inode != 0 else { return }
    let identity = try? DescriptorFileSystem.identity(at: item.path)
    basket[item.path] = BasketEntry(
      path: item.path, label: item.name, device: item.device, inode: item.inode, logical: item.logical,
      allocated: item.allocated, identity: identity,
      warningPaths: warningPath.map { [$0] } ?? [],
      applicationPackagePaths: Self.observedApplicationPackagePaths(in: tree, under: item))
  }

  private nonisolated static func observedApplicationPackagePaths(in tree: ScanTree?, under item: SpaceItem) -> [String]
  {
    guard let tree else { return [] }
    var pending = [item]
    var packages: [String] = []
    while let current = pending.popLast() {
      guard current.path == item.path || current.path.hasPrefix(item.path + "/") else { continue }
      if (current.kind == .package || current.kind == .directory) && current.path.lowercased().hasSuffix(".app") {
        packages.append(current.path)
      } else if current.kind == .directory {
        pending.append(
          contentsOf: tree.children(of: current.id, metric: .logical).filter {
            $0.kind == .directory || $0.kind == .package
          })
      }
    }
    return packages.sorted()
  }

  /// Uses paths already present in the scan; the planner validates packages without following links.
  nonisolated static func observedApplicationPackagePaths(in paths: [String], under root: String) -> [String] {
    Array(
      Set(
        paths.filter {
          ($0 == root || $0.hasPrefix(root + "/")) && $0.lowercased().hasSuffix(".app")
        })
    ).sorted()
  }

  static func canManuallySelect(_ item: SpaceItem) -> Bool {
    item.kind != .smallFiles && item.kind != .systemVolume && item.kind != .other
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

  var pendingTrashSize: ObservedPlanSize {
    ObservedPlanSize.total(
      (history?.items ?? []).filter { $0.applied && $0.state == .inTrash && !restoredItemIDs.contains($0.itemID) }.map {
        historyMetadata[$0.itemID]?.observedSize ?? .unknown
      })
  }

  /// Compatibility for consumers requesting only the known amount.
  var pendingTrashLogicalBytes: Int64 { pendingTrashSize.logical?.knownLowerBound ?? 0 }

  func historySize(_ plan: HistoryPlan) -> ObservedPlanSize {
    let applied = Set(plan.items.filter(\.applied).map(\.itemID))
    return ObservedPlanSize.total(plan.metadata.filter { applied.contains($0.id) }.map(\.displaySize))
  }

  var pendingTrashCount: Int {
    history?.items.filter { $0.applied && $0.state == .inTrash && !restoredItemIDs.contains($0.itemID) }.count ?? 0
  }

  /// Captures chosen roots without walking their descendants.
  func prepare(scanRoot: String, runID: UUID?) async {
    guard !basket.isEmpty, !busy, !preparingAlternate else { return }
    clearKeptItems()
    busy = true
    defer { busy = false }
    let revision = basketRevision
    let chosen = Array(basket.values)
    let outcome = await planService.makeAvailableUserSelectionPlan(
      selections: chosen.map {
        UserSelection(
          path: $0.path, expectedIdentity: $0.identity,
          observedSize: ObservedPlanSize(logical: $0.logical, allocated: $0.allocated),
          warnings: $0.warningPaths.map { UserSelectionWarning(examplePath: $0) },
          applicationPackagePaths: $0.applicationPackagePaths)
      }, kind: preferences.deletionDefault.kind, runID: runID ?? UUID())
    guard revision == basketRevision, !Task.isCancelled else { return }
    guard let plan = outcome.plan else {
      publishKeptItems(outcome.rejections)
      return
    }
    let summary = plan.items.map { item in
      let entry = chosen.first { $0.path == item.sourcePath }
      return ActionItemSummary(
        id: item.id, label: entry?.label ?? URL(fileURLWithPath: item.sourcePath).lastPathComponent,
        path: item.sourcePath, reason: String(localized: "Selected in Space"),
        logicalBytes: nil, allocatedBytes: nil, warning: entry?.warning,
        observedSize: item.observedSize,
        warningPaths: item.userSelectionWarnings?.map(\.examplePath) ?? [])
    }
    let running = await containsRunningApplications(plan)
    guard revision == basketRevision, !Task.isCancelled else { return }
    busy = false
    present(plan: plan, items: summary, rejectedItems: outcome.rejections, hasRunningApplications: running)
    message = nil
  }

  func containsRunningApplications(_ plan: ActionPlan) async -> Bool {
    for item in plan.items {
      for path in planService.applicationPackagePaths(for: item, in: plan) {
        let activity = await userSelectionApplicationActivity.activity(applicationPath: path)
        if !activity.requiresAdministrator && activity.state == .active { return true }
      }
    }
    return false
  }

  /// A refusal is a kept-item outcome, without claiming an execution or writing History.
  func publishKeptItems(_ rejections: [PlanRejection]) {
    guard !rejections.isEmpty else { return }
    verificationTask?.cancel()
    verificationTask = nil
    pending = nil
    result = nil
    resultKind = nil
    resultSummaries = []
    resultFailures = []
    resultRejections = rejections
    message = nil
  }

  /// Selection changes expire preflight feedback while preserving completed actions and History.
  func clearKeptItems() {
    guard result == nil else { return }
    resultKind = nil
    resultSummaries = []
    resultFailures = []
    resultRejections = []
  }

  /// Other modules supply their own guarded plan and reason summary.
  func present(
    plan: ActionPlan, items: [ActionItemSummary],
    permanentPlanBuilder: (@MainActor @Sendable () async -> Void)? = nil,
    rejectedItems: [PlanRejection] = [], hasRunningApplications: Bool = false
  ) {
    guard !busy, Set(plan.items.map(\.id)) == Set(items.map(\.id)),
      !preparingAlternate || pending?.plan.id == alternatePlanID
    else { return }
    clearKeptItems()
    let plannedItems = Dictionary(plan.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    pending = ActionPresentation(
      plan: plan,
      items: items.map { summary in
        guard let item = plannedItems[summary.id] else { return summary }
        let size = PlanItemSize.observation(item)
        return ActionItemSummary(
          id: summary.id, label: summary.label, path: summary.path, reason: summary.reason,
          logicalBytes: size.logical?.completeTotal ?? size.logical?.knownLowerBound,
          allocatedBytes: size.allocated?.completeTotal ?? size.allocated?.knownLowerBound,
          warning: summary.warning ?? ProtectiveWarning.evaluate(item, homeDirectory: planService.homeDirectory),
          observedSize: size,
          warningPaths: !summary.warningPaths.isEmpty
            ? summary.warningPaths
            : item.userSelectionWarnings?.map(\.examplePath)
              ?? (summary.warning ?? ProtectiveWarning.evaluate(item, homeDirectory: planService.homeDirectory))?
              .examplePaths(item, homeDirectory: planService.homeDirectory) ?? [],
          applicationGroup: summary.applicationGroup)
      },
      permanentPlanBuilder: plan.kind == .trash ? { @MainActor in } : nil,
      rejectedItems: rejectedItems, hasRunningApplications: hasRunningApplications)
  }

  func requestPermanent(_ presentation: ActionPresentation) async {
    await changePendingMethod(presentation, kind: .catalogDelete)
  }

  func requestTrash(_ presentation: ActionPresentation) async {
    await changePendingMethod(presentation, kind: .trash)
  }

  private func changePendingMethod(_ presentation: ActionPresentation, kind: ActionKind) async {
    guard !busy, !preparingAlternate, pending?.plan == presentation.plan else { return }
    preparingAlternate = true
    alternatePlanID = presentation.plan.id
    defer {
      preparingAlternate = false
      alternatePlanID = nil
    }
    let outcome = await planService.finalizeUserSelection(plan: presentation.plan, kind: kind)
    guard pending?.plan == presentation.plan else { return }
    guard let plan = outcome.plan else {
      message = outcome.rejections.map(SpaceText.rejection).joined(separator: "\n")
      return
    }
    let paths = Set(plan.items.map(\.sourcePath))
    present(
      plan: plan, items: presentation.items.filter { paths.contains($0.path) },
      rejectedItems: presentation.rejectedItems + outcome.rejections,
      hasRunningApplications: presentation.hasRunningApplications)
  }

  func invalidatePending(expectedPlanID: UUID?) {
    guard pending?.plan.id == expectedPlanID else { return }
    pending = nil
  }

  /// Claim synchronously while the confirmation sheet still owns its presentation.
  /// SwiftUI may clear `pending` as soon as the sheet begins dismissing.
  func takeConfirmedPlan(
    _ presentation: ActionPresentation, permanentConfirmed: Bool = false, closeRunningApplications: Bool = false
  ) -> ActionPlan? {
    guard !busy, !preparingAlternate, claimedPlan == nil,
      pending?.plan == presentation.plan,
      presentation.plan.kind == .trash || (presentation.plan.kind == .catalogDelete && permanentConfirmed)
    else { return nil }
    claimedPlan = presentation.plan
    claimedCloseRunningApplications = closeRunningApplications
    claimedSummaries = presentation.items
    claimedRejections = presentation.rejectedItems
    pending = nil
    busy = true
    result = nil
    resultKind = nil
    resultSummaries = []
    resultFailures = []
    resultRejections = []
    return presentation.plan
  }

  func executeConfirmed(_ plan: ActionPlan) async {
    guard claimedPlan == plan else { return }
    claimedPlan = nil
    defer {
      busy = false
      claimedCloseRunningApplications = false
      claimedSummaries = []
      claimedRejections = []
    }
    do {
      let outcome = await planService.finalizeUserSelection(plan: plan)
      guard let freshPlan = outcome.plan else {
        resultKind = plan.kind
        resultRejections = claimedRejections + outcome.rejections
        resultSummaries = claimedSummaries
        message = nil
        return
      }
      let confirmation =
        freshPlan.kind == .catalogDelete
        ? IrreversibleConfirmation(planID: freshPlan.id, method: .catalogDelete) : nil
      let completed = try await executor.execute(
        freshPlan, confirmation: confirmation, closeRunningApplications: claimedCloseRunningApplications)
      publishExecution(
        plan: freshPlan, result: completed, summaries: claimedSummaries,
        rejections: claimedRejections + outcome.rejections)
      claimedSummaries = []
      claimedRejections = []
      message = nil
    } catch {
      message = FailureText.describe(error)
    }
    await reloadHistory()
  }

  /// Publish only exact completed IDs. Failed, skipped and uncertain paths stay visible.
  func publishExecution(
    plan: ActionPlan, result completed: ActionResult, summaries: [ActionItemSummary], rejections: [PlanRejection] = []
  ) {
    guard completed.planID == plan.id else { return }
    let outcomes = Dictionary(completed.items.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
    let summariesByID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let applied = plan.items.compactMap { item -> ActionDisplayItem? in
      guard let outcome = outcomes[item.id], outcome.outcome == .applied else { return nil }
      let summary = summariesByID[item.id]
      return ActionDisplayItem(
        planID: plan.id, itemID: item.id, path: item.sourcePath,
        identity: item.inventory.first { $0.path == item.sourcePath }?.identity,
        size: summary?.observedSize ?? item.displaySize,
        label: summary?.label ?? URL(fileURLWithPath: item.sourcePath).lastPathComponent,
        returnedTrashPath: nil)
    }
    withAnimation(displayAnimation) {
      result = completed
      resultKind = plan.kind
      resultRejections = rejections
      resultSummaries = plan.items.compactMap { summariesByID[$0.id] }
      resultFailures = plan.items.compactMap { item in
        guard let outcome = outcomes[item.id], outcome.outcome != .applied else { return nil }
        return ActionDisplayFailure(
          itemID: item.id, path: item.sourcePath, outcome: outcome.outcome,
          detail: FailureText.execution(outcome), presentation: FailureText.executionPresentation(outcome))
      }
      for item in applied {
        appliedDisplayItems[item.itemID] = item
        restoredItemIDs.remove(item.itemID)
      }
      let roots = applied.filter { item in !applied.contains { item.path.hasPrefix($0.path + "/") } }
      func subtract(_ value: ByteAggregate?, amounts: [ByteAggregate?]) -> ByteAggregate? {
        guard let value else { return nil }
        var remaining = value.knownLowerBound
        var complete = value.completeTotal != nil
        for amount in amounts {
          guard let amount else { return ByteAggregate(knownLowerBound: 0, completeTotal: nil) }
          remaining = max(0, remaining - min(remaining, amount.knownLowerBound))
          complete = complete && amount.completeTotal != nil
        }
        return ByteAggregate(knownLowerBound: remaining, completeTotal: complete ? remaining : nil)
      }
      for (path, entry) in basket {
        if let root = roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
          let identity = plan.items.first { $0.id == root.itemID }?.inventory.first { $0.path == path }?.identity
          if identity?.device == entry.device, identity?.inode == entry.inode { basket.removeValue(forKey: path) }
        } else {
          let descendants = roots.filter { $0.path.hasPrefix(path + "/") }
          guard !descendants.isEmpty else { continue }
          basket[path] = BasketEntry(
            path: entry.path, label: entry.label, device: entry.device, inode: entry.inode,
            logical: subtract(entry.logical, amounts: descendants.map { $0.size.logical })
              ?? ByteAggregate(knownLowerBound: 0, completeTotal: nil),
            allocated: subtract(entry.allocated, amounts: descendants.map { $0.size.allocated }),
            identity: entry.identity, warning: entry.warning, warningPaths: entry.warningPaths,
            applicationPackagePaths: entry.applicationPackagePaths)
        }
      }
      displayRevision += 1
      onDisplayChange?(ActionDisplayChange(kind: .applied, items: applied))
    }
    verifyInBackground(ActionDisplayChange(kind: .applied, items: applied))
  }

  func failure(at path: String) -> String? {
    resultFailures.first { $0.path == path }?.detail
      ?? resultRejections.first { $0.path == path }.map(SpaceText.rejection)
  }

  var unverifiedResultCount: Int {
    result?.items.filter { FailureText.executionIsUnverified($0) }.count ?? 0
  }

  var completedSummary: String? {
    guard let appliedSummary else {
      return resultRejections.isEmpty ? nil : String(localized: "No items were removed.")
    }
    guard unverifiedResultCount > 0 else { return appliedSummary }
    let unverified = String.localizedStringWithFormat(
      String(localized: "%lld item outcomes could not be verified. Check History and Finder."), unverifiedResultCount)
    return result?.items.contains { $0.outcome == .applied } == true
      ? appliedSummary + " " + unverified : unverified
  }

  private var appliedSummary: String? {
    guard let result else { return nil }
    let appliedIDs = Set(result.items.filter { $0.outcome == .applied }.map(\.itemID))
    let applied = resultSummaries.filter { appliedIDs.contains($0.id) }
    let remaining = applied.filter { !restoredItemIDs.contains($0.id) }
    let showing = remaining.isEmpty ? applied : remaining
    guard let first = showing.first else { return String(localized: "No items were removed.") }
    let name =
      showing.count == 1
      ? first.label
      : String.localizedStringWithFormat(
        String(localized: "%@ and %lld more items"), first.label, showing.count - 1)
    let size = PlanItemSize.text(ObservedPlanSize.total(showing.map(\.observedSize)).logical)
    if remaining.isEmpty {
      return showing.count == 1
        ? String.localizedStringWithFormat(String(localized: "%@ (%@) was restored."), name, size)
        : String.localizedStringWithFormat(String(localized: "%@ (%@) were restored."), name, size)
    }
    if remaining.count != applied.count {
      return String.localizedStringWithFormat(
        String(localized: "%@ (%@) remains in Trash; the other items were restored."), name, size)
    }
    if resultKind == .catalogDelete {
      return showing.count == 1
        ? String.localizedStringWithFormat(String(localized: "%@ (%@) was permanently cleaned."), name, size)
        : String.localizedStringWithFormat(String(localized: "%@ (%@) were permanently cleaned."), name, size)
    }
    return showing.count == 1
      ? String.localizedStringWithFormat(String(localized: "%@ (%@) was moved to Trash."), name, size)
      : String.localizedStringWithFormat(String(localized: "%@ (%@) were moved to Trash."), name, size)
  }

  var latestTrashPaths: [String] {
    guard resultKind == .trash, let result else { return [] }
    let ids = Set(result.items.filter { $0.outcome == .applied && !restoredItemIDs.contains($0.itemID) }.map(\.itemID))
    return (history?.items ?? []).filter { $0.planID == result.planID && ids.contains($0.itemID) }
      .compactMap(\.returnedTrashPath)
  }

  var canUndoLatest: Bool {
    guard resultKind == .trash, let result else { return false }
    return result.items.contains { $0.outcome == .applied && !restoredItemIDs.contains($0.itemID) }
  }

  func undoLatest() async {
    guard !busy, canUndoLatest, let planID = result?.planID else { return }
    busy = true
    defer { busy = false }
    do {
      let restored = try await historyService.undo(planID: planID)
      undoResults[planID] = restored
      publishRestored(planID: planID, itemIDs: Set(restored.items.filter { $0.outcome == .restored }.map(\.itemID)))
      message =
        restored.remainingCount == 0
        ? nil : String(localized: "Some items could not be restored. Review History for the reason.")
    } catch { message = FailureText.describe(error) }
    await reloadHistory()
  }

  func publishRestored(planID: UUID, itemIDs: Set<UUID>) {
    let restored = itemIDs.compactMap { id -> ActionDisplayItem? in
      guard let item = appliedDisplayItems[id], item.planID == planID else { return nil }
      return item
    }
    withAnimation(displayAnimation) {
      restoredItemIDs.formUnion(itemIDs)
      displayRevision += 1
      onDisplayChange?(ActionDisplayChange(kind: .restored, items: restored))
    }
    verifyInBackground(ActionDisplayChange(kind: .restored, items: restored))
  }

  private func verifyInBackground(_ change: ActionDisplayChange) {
    guard !change.items.isEmpty else { return }
    // No cached observation grants authority: this read only checks the result display.
    verificationTask?.cancel()
    verificationTask = Task(priority: .utility) { @concurrent [weak self] in
      var mismatches: [String] = []
      var unknown: [String] = []
      for item in change.items {
        do {
          let current = try DescriptorFileSystem.identity(at: item.path)
          if change.kind == .applied || !item.matches(path: item.path, identity: current) {
            mismatches.append(item.path)
          }
        } catch FileSystemFailure.systemCall(_, let code) where code == ENOENT {
          if change.kind == .restored { mismatches.append(item.path) }
        } catch { unknown.append(item.path) }
      }
      guard !Task.isCancelled else { return }
      let changed = mismatches
      let unreadable = unknown
      await self?.finishVerification(change, mismatches: changed, unknown: unreadable)
    }
  }

  private func finishVerification(_ change: ActionDisplayChange, mismatches: [String], unknown: [String]) {
    guard !Task.isCancelled else { return }
    if !mismatches.isEmpty {
      message =
        String(localized: "The files changed after the action. Refreshing the displayed results.")
        + "\n" + mismatches.joined(separator: "\n")
      onDisplayDiscrepancy?(change)
    } else if !unknown.isEmpty {
      message =
        String(localized: "The result could not be checked again for these paths. Review them in Finder.")
        + "\n" + unknown.joined(separator: "\n")
    }
  }

  func reloadHistory() async {
    do {
      let readout = try await historyService.reconcile()
      var metadata: [UUID: HistoryMetadata] = [:]
      for plan in readout.plans {
        for item in plan.metadata {
          metadata[item.id] = HistoryMetadata(
            path: item.sourcePath, logicalBytes: item.logicalBytes, allocatedBytes: item.allocatedBytes,
            observedSize: item.displaySize)
        }
      }
      history = readout
      historyMetadata = metadata
      expandedHistoryGroups.formIntersection(readout.plans.map(\.id))
      for id in expandedHistoryGroups.sorted(by: { $0.uuidString < $1.uuidString }) {
        await loadHistoryGroup(planID: id)
      }
    } catch {
      message = FailureText.describe(error)
    }
  }

  func setHistoryGroupExpanded(_ planID: UUID, expanded: Bool) async {
    if expanded {
      expandedHistoryGroups.insert(planID)
      await loadHistoryGroup(planID: planID)
    } else {
      expandedHistoryGroups.remove(planID)
    }
  }

  private func loadHistoryGroup(planID: UUID) async {
    guard expandedHistoryGroups.contains(planID), !loadingHistoryGroups.contains(planID) else { return }
    loadingHistoryGroups.insert(planID)
    defer { loadingHistoryGroups.remove(planID) }
    do {
      let group = try await historyService.loadGroup(planID: planID)
      guard expandedHistoryGroups.contains(planID) else { return }
      history = history?.replacingGroup(group)
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
    guard !busy, plan.canUndo else { return }
    busy = true
    defer { busy = false }
    do {
      let result = try await historyService.undo(planID: plan.id)
      undoResults[plan.id] = result
      publishRestored(planID: plan.id, itemIDs: Set(result.items.filter { $0.outcome == .restored }.map(\.itemID)))
      message =
        "\(result.restoredCount) \(String(localized: "Restored")) · \(result.remainingCount) \(String(localized: "Not restored"))"
    } catch {
      message = FailureText.describe(error)
    }
    await reloadHistory()
  }

  func undo(_ item: HistoryItem) async {
    guard !busy, item.canUndo else { return }
    busy = true
    defer { busy = false }
    do {
      try await historyService.undo(planID: item.planID, itemID: item.itemID)
      publishRestored(planID: item.planID, itemIDs: [item.itemID])
      message = nil
    } catch {
      message = FailureText.describe(error)
    }
    await reloadHistory()
  }
}
