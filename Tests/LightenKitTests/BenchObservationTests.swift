import Darwin
import Foundation
import Testing

@testable import LightenKit

@Test("Read-only discovery neither creates nor updates verified receipts", arguments: [false, true])
func readOnlyDiscoveryPreservesReceiptStore(existingReceipt: Bool) async throws {
  let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
  defer { free(temporary) }
  let root = String(cString: temporary) + "/LightenQA-" + UUID().uuidString
  defer { try? FileManager.default.removeItem(atPath: root) }
  let bundleID = "qa.lighten.observation"
  let appRoot = root + "/Applications"
  let appPath = appRoot + "/LightenQA.app"
  let cachePath = root + "/Library/Caches/" + bundleID
  let receiptPath = root + "/Library/Application Support/com.tavsn.lighten/related-receipts.json"
  try FileManager.default.createDirectory(atPath: appPath + "/Contents", withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: cachePath, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: root + "/Library/Preferences", withIntermediateDirectories: true)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0
  ).write(to: URL(fileURLWithPath: appPath + "/Contents/Info.plist"))
  try Data("cached bytes".utf8).write(to: URL(fileURLWithPath: cachePath + "/entry"))

  let writer = RelatedDataService(homeDirectory: root, applicationRoots: [appRoot])
  if existingReceipt {
    _ = await writer.discover()
    #expect(FileManager.default.fileExists(atPath: receiptPath))
  }
  let beforeData = try? Data(contentsOf: URL(fileURLWithPath: receiptPath))
  let beforeIdentity = try? DescriptorFileSystem.identity(at: receiptPath)
  let observer = RelatedDataService(
    homeDirectory: root, applicationRoots: [appRoot], writeVerifiedReceipts: false)
  let candidates = await observer.discover()
  let candidate = try #require(candidates.first { $0.path == cachePath })
  #expect(candidate.classification == .installed)
  #expect(candidate.observation?.logical.completeTotal == Int64("cached bytes".utf8.count))
  #expect(candidate.snapshot?.entries.count == 1)
  #expect(!candidates.contains { $0.id == "receipt-write" })
  #expect((try? Data(contentsOf: URL(fileURLWithPath: receiptPath))) == beforeData)
  #expect((try? DescriptorFileSystem.identity(at: receiptPath)) == beforeIdentity)
  if !existingReceipt {
    #expect(!FileManager.default.fileExists(atPath: root + "/Library/Application Support"))
  }

  let app = try #require(observer.inventory().applications.first { $0.path == appPath })
  let plan = try observer.planInstalled(app: app, candidate: candidate)
  #expect(plan.items.first?.installedRelatedProof?.bundleID == bundleID)
  try FileManager.default.removeItem(atPath: appPath)
  let absent = try #require((await observer.discover()).first { $0.path == cachePath })
  #expect(absent.classification == (existingReceipt ? .historicallyVerifiedAbsent : .orphanVerified))
  #expect(!absent.defaultSelected)
}
