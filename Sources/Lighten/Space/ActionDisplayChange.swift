import Foundation
import LightenKit

/// UI observations from an exact completed item. They never authorize another action.
struct ActionDisplayItem: Sendable {
  let planID: UUID
  let itemID: UUID
  let path: String
  let identity: FileIdentity?
  let size: ObservedPlanSize
  let label: String
  let returnedTrashPath: String?

  nonisolated func matches(path: String, identity: FileIdentity?) -> Bool {
    guard self.path == path, let expected = self.identity, let identity else { return false }
    return expected.device == identity.device && expected.inode == identity.inode
      && expected.kind == identity.kind && expected.birthSeconds == identity.birthSeconds
      && expected.birthNanoseconds == identity.birthNanoseconds
  }

  nonisolated func matches(_ item: SpaceItem) -> Bool {
    guard let identity else { return false }
    return path == item.path && identity.device == item.device && identity.inode == item.inode
  }
}

struct ActionDisplayChange: Sendable {
  nonisolated enum Kind: Sendable, Equatable { case applied, restored }
  let kind: Kind
  let items: [ActionDisplayItem]
}

struct ActionDisplayFailure: Sendable {
  let itemID: UUID
  let path: String
  let outcome: ActionOutcome
  let detail: String
}
