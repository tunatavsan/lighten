import Foundation
import LightenKit
import Observation

@MainActor @Observable
final class RemovalPreferences {
  static let shared = RemovalPreferences()
  static let deletionKey = "removal.defaultMethod"
  static let relatedKey = "removal.automaticallySelectRelatedData"

  enum DefaultMethod: String, CaseIterable, Identifiable {
    case trash, permanent
    var id: Self { self }
    var kind: ActionKind { self == .trash ? .trash : .catalogDelete }
    var title: String {
      switch self {
      case .trash: String(localized: "Move to Trash")
      case .permanent: String(localized: "Permanently delete")
      }
    }
  }

  @ObservationIgnored private let defaults: UserDefaults
  var deletionDefault: DefaultMethod {
    didSet { defaults.set(deletionDefault.rawValue, forKey: Self.deletionKey) }
  }
  var automaticallySelectRelatedData: Bool {
    didSet { defaults.set(automaticallySelectRelatedData, forKey: Self.relatedKey) }
  }

  init(defaults: UserDefaults = .standard, persistentDomainName: String? = nil) {
    self.defaults = defaults
    if let persistentDomainName {
      let stored = defaults.persistentDomain(forName: persistentDomainName) ?? [:]
      deletionDefault = DefaultMethod(rawValue: stored[Self.deletionKey] as? String ?? "") ?? .trash
      automaticallySelectRelatedData = stored[Self.relatedKey] as? Bool ?? false
    } else {
      deletionDefault = DefaultMethod(rawValue: defaults.string(forKey: Self.deletionKey) ?? "") ?? .trash
      automaticallySelectRelatedData = defaults.bool(forKey: Self.relatedKey)
    }
  }
}
