import Foundation
import LightenKit

/// Display sizing stays separate from the exact inventory that authorizes the action.
enum PlanItemSize {
  nonisolated static func observation(_ item: PlanItem) -> ObservedPlanSize { item.displaySize }

  /// Compatibility for callers using inventory totals. Use observation for presentation.
  nonisolated static func measure(_ item: PlanItem) -> (logical: Int64, allocated: Int64) {
    let size = ObservedPlanSize.inventory(item.inventory)
    return (size.logical?.completeTotal ?? -1, size.allocated?.completeTotal ?? -1)
  }

  static func text(_ value: ByteAggregate?) -> String {
    guard let value, value.knownLowerBound >= 0 else { return String(localized: "Size unknown") }
    if let exact = value.completeTotal { return format(exact) }
    return "\(String(localized: "At least")) \(format(value.knownLowerBound))"
  }
}
