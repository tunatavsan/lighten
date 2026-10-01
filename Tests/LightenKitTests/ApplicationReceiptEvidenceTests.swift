import Darwin
import Foundation
import Synchronization
import Testing

@testable import LightenKit

private struct ReceiptFixture: Sendable {
  let home: String
  let receipts: String
  let prefix: String
  let identifier = "qa.lighten.receipt"
  var app: String { home + "/Applications/LightenQA-receipt.app" }

  init() throws {
    let temporary = try #require(realpath("/tmp", nil))
    defer { free(temporary) }
    home = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
    receipts = home + "/Receipts"
    prefix = home + "/Payload"
    try directory(receipts)
    try directory(prefix)
    try directory(app + "/Contents")
    try plist(["CFBundleIdentifier": identifier], at: app + "/Contents/Info.plist")
  }

  func directory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }
  func plist(_ dictionary: [String: Any], at path: String) throws {
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
      .write(to: URL(fileURLWithPath: path))
  }
  func receipt(_ id: String, prefix: String? = nil, declaredID: String? = nil) throws {
    try plist(
      ["PackageIdentifier": declaredID ?? id, "InstallPrefixPath": prefix ?? self.prefix],
      at: receipts + "/" + id + ".plist")
    try Data("Disposable BOM identity fixture".utf8).write(to: URL(fileURLWithPath: receipts + "/" + id + ".bom"))
  }
  func bom(_ id: String) throws {
    try Data("Disposable BOM identity fixture".utf8).write(to: URL(fileURLWithPath: receipts + "/" + id + ".bom"))
  }
  func discover(_ observed: ApplicationInstallerReceipts) -> ApplicationAuxiliaryDiscovery {
    ApplicationAuxiliaryEvidenceProducer.discover(
      app: InstalledApplication(bundleID: identifier, path: app, version: nil),
      homeDirectory: home, receipts: observed)
  }
  func cleanup() { try? FileManager.default.removeItem(atPath: home) }
}

@Suite("Exact installer receipt evidence")
struct ApplicationReceiptEvidenceTests {
  @Test("Local exact receipt resolves an exclusive directory and package-specific file without a metadata subprocess")
  func localPrefixAndExclusiveDirectory() throws {
    let fixture = try ReceiptFixture()
    defer { fixture.cleanup() }
    try fixture.receipt(fixture.identifier)
    try fixture.directory(fixture.prefix + "/Owned")
    try Data("leaf".utf8).write(to: URL(fileURLWithPath: fixture.prefix + "/Owned/file"))
    let calls = Mutex<[[String]]>([])
    let observed = ApplicationInstallerReceipts(
      identifiers: [fixture.identifier], complete: true, receiptDirectory: fixture.receipts,
      query: { args, _, _ in
        calls.withLock { $0.append(args) }
        return args == ["--files", fixture.identifier] ? Data("Owned\nOwned/file\n".utf8) : nil
      })
    let result = fixture.discover(observed)
    #expect(Set(result.evidence.map(\.dataPath)) == Set([fixture.prefix + "/Owned", fixture.prefix + "/Owned/file"]))
    #expect(result.issues.isEmpty)
    #expect(calls.withLock { $0 } == [["--files", fixture.identifier]])
    _ = fixture.discover(observed)
    #expect(calls.withLock { $0.count } == 1)
  }

  @Test("A directory shared by two packages is unproven while its exclusive leaf remains an observation")
  func sharedDirectoryAndExclusiveLeaf() throws {
    let fixture = try ReceiptFixture()
    defer { fixture.cleanup() }
    let other = "qa.lighten.other"
    try fixture.receipt(fixture.identifier)
    try fixture.receipt(other)
    try fixture.directory(fixture.prefix + "/Shared")
    try Data("leaf".utf8).write(to: URL(fileURLWithPath: fixture.prefix + "/Shared/own"))
    let calls = Mutex<[[String]]>([])
    let observed = ApplicationInstallerReceipts(
      identifiers: [fixture.identifier, other], complete: true, receiptDirectory: fixture.receipts,
      query: { args, _, _ in
        calls.withLock { $0.append(args) }
        if args == ["--files", fixture.identifier] { return Data("Shared\nShared/own\n".utf8) }
        if args == ["--files", other] { return Data("Shared\nShared/other\n".utf8) }
        return nil
      })
    let result = fixture.discover(observed)
    #expect(result.evidence.map(\.dataPath) == [fixture.prefix + "/Shared/own"])
    #expect(
      result.issues.contains {
        $0.path == fixture.prefix + "/Shared" && $0.detail == "receipt-directory-shared-packages"
      })
    _ = fixture.discover(observed)
    #expect(calls.withLock { $0.count } == 2)
  }

  @Test("An unreadable local receipt uses only matching native pkgid, volume and install-location fields")
  func nativeFallbackAndUnknownPrefix() throws {
    let fixture = try ReceiptFixture()
    defer { fixture.cleanup() }
    try fixture.bom(fixture.identifier)
    try fixture.directory(fixture.prefix + "/Owned")
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["pkgid": fixture.identifier, "volume": "/", "install-location": fixture.prefix],
      format: .xml, options: 0)
    let calls = Mutex<[[String]]>([])
    let observed = ApplicationInstallerReceipts(
      identifiers: [fixture.identifier], complete: true, receiptDirectory: fixture.receipts,
      query: { args, _, _ in
        calls.withLock { $0.append(args) }
        if args == ["--pkg-info-plist", fixture.identifier] { return info }
        if args == ["--files", fixture.identifier] { return Data("Owned\n".utf8) }
        return nil
      })
    #expect(fixture.discover(observed).evidence.map(\.dataPath) == [fixture.prefix + "/Owned"])
    #expect(calls.withLock { $0 } == [["--pkg-info-plist", fixture.identifier], ["--files", fixture.identifier]])
    let unknown = ApplicationInstallerReceipts(
      identifiers: [fixture.identifier], complete: true, receiptDirectory: fixture.receipts,
      query: { _, _, _ in nil })
    let result = fixture.discover(unknown)
    #expect(result.evidence.isEmpty)
    #expect(
      result.issues.contains {
        $0.path == fixture.receipts + "/" + fixture.identifier + ".plist"
          && $0.detail.hasPrefix("receipt-install-prefix-or-files-unproven")
      })
  }

  @Test("Conflicting, missing and traversal metadata never supplies an installation prefix")
  func malformedNativeFallback() throws {
    let id = "qa.lighten.receipt"
    let invalid: [[String: Any]] = [
      ["pkgid": "qa.lighten.other", "volume": "/", "install-location": "/"],
      ["volume": "/", "install-location": "/"],
      ["pkgid": id, "volume": "/"],
      ["pkgid": id, "volume": "relative", "install-location": "/"],
      ["pkgid": id, "volume": "/", "install-location": "../Library"],
      ["pkgid": id, "volume": "/", "install-location": "/", "PackageIdentifier": "qa.lighten.other"],
      ["pkgid": id, "volume": "/", "install-location": "/", "InstallPrefixPath": "/Applications"],
    ]
    for value in invalid {
      let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
      #expect(throws: RelatedFailure.self) { try ApplicationInstallerReceipts.fallbackPrefix(data, identifier: id) }
    }
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["pkgid": id, "volume": "/Volumes/Example", "install-location": "Library/Owned"],
      format: .xml, options: 0)
    #expect(try ApplicationInstallerReceipts.fallbackPrefix(data, identifier: id) == "/Volumes/Example/Library/Owned")
  }

  @Test("A readable conflicting local identity cannot be replaced with a successful fallback")
  func conflictingLocalIdentity() throws {
    let fixture = try ReceiptFixture()
    defer { fixture.cleanup() }
    try fixture.receipt(fixture.identifier, declaredID: "qa.lighten.other")
    let calls = Mutex(0)
    let observed = ApplicationInstallerReceipts(
      identifiers: [fixture.identifier], complete: true, receiptDirectory: fixture.receipts,
      query: { _, _, _ in
        calls.withLock { $0 += 1 }
        return nil
      })
    #expect(observed.entries(bundleID: fixture.identifier).isEmpty)
    #expect(!observed.issues(bundleID: fixture.identifier).isEmpty)
    #expect(calls.withLock { $0 } == 0)
  }

  @Test("Receipt directory aliases cannot relax descriptor-relative no-follow reads")
  func receiptNamespaceAliasRefused() throws {
    let fixture = try ReceiptFixture()
    defer { fixture.cleanup() }
    try fixture.receipt(fixture.identifier)
    let alias = fixture.home + "/ReceiptAlias"
    try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.receipts)
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["pkgid": fixture.identifier, "volume": "/", "install-location": fixture.prefix],
      format: .xml, options: 0)
    let observed = ApplicationInstallerReceipts(
      identifiers: [fixture.identifier], complete: true, receiptDirectory: alias,
      query: { args, _, _ in args == ["--pkg-info-plist", fixture.identifier] ? info : Data("Owned\n".utf8) })
    #expect(observed.entries(bundleID: fixture.identifier).isEmpty)
    #expect(!observed.issues(bundleID: fixture.identifier).isEmpty)
  }

  @Test("A changed cached receipt cannot bind old leaf paths to replacement metadata")
  func changedCachedPrefix() throws {
    let fixture = try ReceiptFixture()
    defer { fixture.cleanup() }
    try fixture.receipt(fixture.identifier)
    let leaf = fixture.prefix + "/own"
    try Data("leaf".utf8).write(to: URL(fileURLWithPath: leaf))
    let calls = Mutex(0)
    let observed = ApplicationInstallerReceipts(
      identifiers: [fixture.identifier], complete: true, receiptDirectory: fixture.receipts,
      query: { args, _, _ in
        calls.withLock { $0 += 1 }
        return args == ["--files", fixture.identifier] ? Data("own\n".utf8) : nil
      })
    #expect(fixture.discover(observed).evidence.map(\.dataPath) == [leaf])
    let movedPrefix = fixture.home + "/ReplacementPayload"
    try fixture.directory(movedPrefix)
    try fixture.plist(
      ["PackageIdentifier": fixture.identifier, "InstallPrefixPath": movedPrefix],
      at: fixture.receipts + "/" + fixture.identifier + ".plist")
    let result = fixture.discover(observed)
    #expect(result.evidence.isEmpty)
    #expect(!result.issues.isEmpty)
    #expect(calls.withLock { $0 } == 1)
  }

  @Test("Fallback metadata cannot be bound to a BOM replaced during its query")
  func changedFallbackBOM() throws {
    let fixture = try ReceiptFixture()
    defer { fixture.cleanup() }
    try fixture.bom(fixture.identifier)
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["pkgid": fixture.identifier, "volume": "/", "install-location": fixture.prefix],
      format: .xml, options: 0)
    let calls = Mutex<[[String]]>([])
    let observed = ApplicationInstallerReceipts(
      identifiers: [fixture.identifier], complete: true, receiptDirectory: fixture.receipts,
      query: { args, _, _ in
        calls.withLock { $0.append(args) }
        guard args == ["--pkg-info-plist", fixture.identifier] else { return Data("own\n".utf8) }
        do {
          try Data("Replacement BOM from a different observation".utf8)
            .write(to: URL(fileURLWithPath: fixture.receipts + "/" + fixture.identifier + ".bom"))
        } catch { Issue.record(error) }
        return info
      })
    #expect(observed.entries(bundleID: fixture.identifier).isEmpty)
    #expect(!observed.issues(bundleID: fixture.identifier).isEmpty)
    #expect(calls.withLock { $0 } == [["--pkg-info-plist", fixture.identifier]])
  }

  @Test("Incomplete and expired cross-package censuses keep directories visible without claiming exclusivity")
  func incompleteCensusAndStandardRoots() throws {
    let fixture = try ReceiptFixture()
    defer { fixture.cleanup() }
    try fixture.receipt(fixture.identifier)
    try fixture.directory(fixture.prefix + "/Owned")
    let observed = ApplicationInstallerReceipts(
      identifiers: [fixture.identifier, "qa.lighten.missing"], complete: true, receiptDirectory: fixture.receipts,
      query: { args, _, _ in args == ["--files", fixture.identifier] ? Data("Owned\n".utf8) : nil })
    let result = fixture.discover(observed)
    #expect(result.evidence.isEmpty)
    #expect(
      result.issues.contains {
        $0.path == fixture.prefix + "/Owned" && $0.detail == "receipt-cross-package-census-incomplete"
      })
    #expect(
      observed.directoryIssue(
        path: "/Library/Application Support", identifier: fixture.identifier, homeDirectory: fixture.home)
        == "receipt-shared-standard-directory")
    let expired = ApplicationInstallerReceipts(
      identifiers: [fixture.identifier], complete: true, receiptDirectory: fixture.receipts, timeout: 0,
      query: { _, _, _ in
        Issue.record("Expired query budget must not invoke pkgutil")
        return nil
      })
    #expect(
      expired.directoryIssue(
        path: fixture.prefix + "/Owned", identifier: fixture.identifier, homeDirectory: fixture.home)
        == "receipt-cross-package-census-incomplete")
  }
}
