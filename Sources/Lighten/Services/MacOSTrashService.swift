import Foundation
import LightenKit

/// The only production bridge to Foundation's path-based Trash operation.
/// The returned URL, rather than the requested source name, is journaled.
struct MacOSTrashService: TrashMoving {
  nonisolated func moveToTrash(path: String) async throws -> String {
    try await Task.detached {
      var resultingURL: NSURL?
      try FileManager.default.trashItem(
        at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL
      )
      guard let resultingURL else { throw TrashServiceFailure.missingReturnedURL }
      return (resultingURL as URL).path
    }.value
  }
}

private enum TrashServiceFailure: Error {
  case missingReturnedURL
}
