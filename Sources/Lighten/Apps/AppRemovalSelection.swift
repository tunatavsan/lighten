import Foundation
import LightenKit

enum AppSelectionIntent: Equatable, Sendable {
  case single, toggle, range
}

enum AppEvidenceReviewStatus: Equatable, Sendable {
  case checking, complete, unavailable
}

struct AppRemovalSelection: Sendable {
  var rootIdentity: FileIdentity?
  var bundleID: String?
  var packageSelected = false
  var dataPaths: Set<String> = []
  var automaticDataPaths: Set<String> = []
  var lateAutomaticDataPaths: Set<String> = []
  var hasReceivedRelatedRows = false
  var hasPresentedRemovalReview = false
  var deselectedDataPaths: Set<String> = []
  var manualData: [String: RelatedDataCandidate] = [:]
  var refusalEvidence: [RelatedOwnershipRefusalEvidence] = []

  var hasChoice: Bool { packageSelected || !dataPaths.isEmpty }
}
