import Foundation
import LightenKit
import Testing

@testable import Lighten

@Test("Duplicate settings use the shared decimal MB default without writing on initialization")
@MainActor func duplicatePreferenceInitialDefaultIsReadOnly() throws {
  let name = "LightenQA-duplicate-preferences." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = DuplicatePreferences(defaults: defaults, persistentDomainName: name)
  #expect(preferences.minimumBytes == DuplicateScanScope.defaultMinimumBytes)
  #expect(preferences.minimumMegabytes == 1)
  #expect(defaults.object(forKey: DuplicatePreferences.minimumBytesKey) == nil)
  #expect(preferences.scope(homeDirectory: "/fixture/home").homeDirectory == "/fixture/home")
  #expect(preferences.scope().minimumBytes == preferences.minimumBytes)
}

@Test("Duplicate size preferences persist in bytes", arguments: [Int64(1), 1_250_000, 10_000_000, Int64.max])
@MainActor func duplicatePreferencePersistsPositiveSizes(bytes: Int64) throws {
  let name = "LightenQA-duplicate-preferences." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let original = DuplicatePreferences(defaults: defaults, persistentDomainName: name)
  original.minimumBytes = bytes
  let restored = DuplicatePreferences(defaults: defaults, persistentDomainName: name)
  #expect(restored.minimumBytes == bytes)
  #expect(DuplicatePreferences(defaults: defaults).minimumBytes == bytes)
  #expect(restored.scope().minimumBytes == bytes)
}

@Test(
  "Invalid stored duplicate thresholds fall back without overwriting them",
  arguments: ["zero", "negative", "boolean", "fractional", "text"])
@MainActor func duplicatePreferenceRejectsInvalidStoredValue(kind: String) throws {
  let name = "LightenQA-duplicate-preferences." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let value: Any
  switch kind {
  case "zero": value = 0
  case "negative": value = -1
  case "boolean": value = true
  case "fractional": value = 12.5
  default: value = "invalid"
  }
  defaults.set(value, forKey: DuplicatePreferences.minimumBytesKey)
  let before = defaults.object(forKey: DuplicatePreferences.minimumBytesKey) as? NSObject
  let preferences = DuplicatePreferences(defaults: defaults, persistentDomainName: name)
  #expect(preferences.minimumBytes == DuplicateScanScope.defaultMinimumBytes)
  #expect((defaults.object(forKey: DuplicatePreferences.minimumBytesKey) as? NSObject) == before)
}

@Test("An absent own-domain duplicate preference ignores values in a fallback suite")
@MainActor func duplicatePreferenceOwnDomainDefault() throws {
  let name = "LightenQA-duplicate-preferences." + UUID().uuidString
  let fallbackName = name + ".fallback"
  let defaults = try #require(UserDefaults(suiteName: name))
  let fallback = try #require(UserDefaults(suiteName: fallbackName))
  fallback.set(12_000_000, forKey: DuplicatePreferences.minimumBytesKey)
  defaults.addSuite(named: fallbackName)
  defer {
    defaults.removeSuite(named: fallbackName)
    defaults.removePersistentDomain(forName: name)
    fallback.removePersistentDomain(forName: fallbackName)
  }
  #expect(defaults.integer(forKey: DuplicatePreferences.minimumBytesKey) == 12_000_000)
  #expect(
    DuplicatePreferences(defaults: defaults, persistentDomainName: name).minimumBytes
      == DuplicateScanScope.defaultMinimumBytes)
  #expect(defaults.persistentDomain(forName: name)?[DuplicatePreferences.minimumBytesKey] == nil)
}

@Test(
  "Decimal MB settings convert to bytes without admitting empty files",
  arguments: [(1.25, Int64(1_250_000)), (0.5, 500_000), (0.000001, 1)])
@MainActor func duplicatePreferenceDecimalConversion(megabytes: Double, expectedBytes: Int64) throws {
  let name = "LightenQA-duplicate-preferences." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = DuplicatePreferences(defaults: defaults, persistentDomainName: name)
  preferences.minimumMegabytes = megabytes
  #expect(preferences.minimumBytes == expectedBytes)
  #expect(preferences.minimumMegabytes == megabytes)
  #expect(!preferences.scope().includesFile(path: "/fixture/empty", logicalBytes: 0, scanRoot: "/fixture"))
}

@Test(
  "Invalid decimal MB edits preserve the current duplicate threshold",
  arguments: [0.0, -1.0, Double.nan, Double.infinity, Double.greatestFiniteMagnitude])
@MainActor func duplicatePreferenceInvalidEditDoesNotPersist(value: Double) throws {
  let name = "LightenQA-duplicate-preferences." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = DuplicatePreferences(defaults: defaults, persistentDomainName: name)
  preferences.minimumBytes = 2_500_000
  preferences.minimumMegabytes = value
  preferences.minimumBytes = 0
  #expect(preferences.minimumBytes == 2_500_000)
  #expect(DuplicatePreferences(defaults: defaults, persistentDomainName: name).minimumBytes == 2_500_000)
}
