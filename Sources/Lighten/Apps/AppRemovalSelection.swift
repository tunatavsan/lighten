import Foundation
import LightenKit

enum AppSelectionIntent: Equatable, Sendable {
  case single, toggle, range
}

struct AppRemovalSelection: Sendable {
  var rootIdentity: FileIdentity?
  var bundleID: String?
  var packageSelected = false
  var dataPaths: Set<String> = []
  var deselectedDataPaths: Set<String> = []
  var manualData: [String: RelatedDataCandidate] = [:]
  var refusalEvidence: [RelatedOwnershipRefusalEvidence] = []

  var hasChoice: Bool { packageSelected || !dataPaths.isEmpty }
}
