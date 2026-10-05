import CoreFoundation
import Foundation
import LightenKit
import Observation

@MainActor @Observable
final class DuplicatePreferences {
  static let shared = DuplicatePreferences()
  static let minimumBytesKey = "duplicates.minimumFileBytes"

  @ObservationIgnored private let defaults: UserDefaults
  private var storedMinimumBytes: Int64

  var minimumBytes: Int64 {
    get { storedMinimumBytes }
    set {
      guard newValue > 0 else { return }
      storedMinimumBytes = newValue
      defaults.set(newValue, forKey: Self.minimumBytesKey)
    }
  }

  var minimumMegabytes: Double {
    get { Double(minimumBytes) / Double(DuplicateScanScope.defaultMinimumBytes) }
    set {
      let bytes = (newValue * Double(DuplicateScanScope.defaultMinimumBytes)).rounded(.up)
      guard newValue.isFinite, newValue > 0, bytes >= 1, bytes < Double(Int64.max) else { return }
      minimumBytes = Int64(bytes)
    }
  }

  init(defaults: UserDefaults = .standard, persistentDomainName: String? = nil) {
    self.defaults = defaults
    let stored: Any?
    if let persistentDomainName {
      stored = defaults.persistentDomain(forName: persistentDomainName)?[Self.minimumBytesKey]
    } else {
      stored = defaults.object(forKey: Self.minimumBytesKey)
    }
    if let number = stored as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.int64Value > 0, number.doubleValue == Double(number.int64Value)
    {
      storedMinimumBytes = number.int64Value
    } else {
      storedMinimumBytes = DuplicateScanScope.defaultMinimumBytes
    }
  }

  func scope(homeDirectory: String = NSHomeDirectory()) -> DuplicateScanScope {
    DuplicateScanScope(minimumBytes: minimumBytes, homeDirectory: homeDirectory)
  }
}
