import Foundation
import LightenKit
import Testing

@Test("Duplicate picture JSON contains display fields without identities, proof, or selections")
func duplicatePictureJSONIsDisplayOnly() throws {
  let identity = FileIdentity(
    device: 3, inode: 9, changeSeconds: 4, changeNanoseconds: 5,
    logicalBytes: 64, allocatedBytes: 128, linkCount: 1, flags: 0, kind: .regular)
  let entries = ["/fixture/a", "/fixture/b"].map {
    ScanEntry(parentID: nil, path: $0, identity: identity, issues: [], readable: true)
  }
  let report = DuplicateReport(
    snapshot: ScanSnapshot(rootPath: "/fixture", volumeDevice: 3, volumeID: UUID(), entries: entries, nodes: []),
    groups: [
      DuplicateGroup(
        logicalBytes: 64,
        members: entries.map {
          DuplicateMember(entry: $0, eligibility: .eligible, compatibilityID: UUID())
        })
    ], skippedCount: 2, partial: true, comparisonCount: 7)
  let content = DuplicatePicture(report)
  let data = try JSONEncoder().encode(content)
  let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(Set(json.keys) == ["rootPath", "groups", "scannedCount", "comparisonCount", "skippedCount", "partial"])
  let groups = try #require(json["groups"] as? [[String: Any]])
  let group = try #require(groups.first)
  #expect(Set(group.keys) == ["logicalBytes", "members"])
  let members = try #require(group["members"] as? [[String: Any]])
  #expect(members.count == 2)
  #expect(members.allSatisfy { Set($0.keys) == ["path", "eligibility"] })
  #expect(try JSONDecoder().decode(DuplicatePicture.self, from: data) == content)
}

@Test("Bounded duplicate pictures round trip empty and partial results", arguments: [false, true])
func duplicatePictureStorageRoundTrip(empty: Bool) throws {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  defer { try? FileManager.default.removeItem(atPath: root) }
  let content = DuplicatePicture(
    rootPath: "/fixture",
    groups: empty
      ? []
      : [
        DuplicatePicture.Group(
          logicalBytes: 64,
          members: [
            DuplicatePicture.Member(path: "/fixture/a", eligibility: .metadataUnknown),
            DuplicatePicture.Member(path: "/fixture/b", eligibility: .metadataDifferent),
          ])
      ], scannedCount: 4, comparisonCount: 3, skippedCount: 2, partial: true)
  let store = ResultPictureStore(directory: root + "/results")
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  try store.save(ResultPicture(observedAt: date, content: content), named: "duplicates")
  let reopened = try #require(store.load(DuplicatePicture.self, named: "duplicates"))
  #expect(reopened.content == content && reopened.observedAt == date)
  let data = try Data(contentsOf: URL(fileURLWithPath: store.directory + "/duplicates.json"))
  let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(Set(json.keys) == ["schema", "picture"] && json["schema"] as? Int == 1)
}

@Test("An oversized duplicate result preserves its previous picture")
func duplicateOversizedPicturePreservesPrevious() throws {
  let root = "/private/tmp/LightenQA-" + UUID().uuidString
  defer { try? FileManager.default.removeItem(atPath: root) }
  let store = ResultPictureStore(directory: root + "/results", maximumBytes: 1024)
  let content = DuplicatePicture(
    rootPath: "/fixture", groups: [], scannedCount: 0, comparisonCount: 0, skippedCount: 0, partial: false)
  let picture = ResultPicture(observedAt: Date(timeIntervalSince1970: 1_700_000_000), content: content)
  try store.save(picture, named: "duplicates")
  let oversized = DuplicatePicture(
    rootPath: String(repeating: "x", count: 2048), groups: [], scannedCount: 0,
    comparisonCount: 0, skippedCount: 0, partial: false)
  #expect(throws: ResultPictureFailure.self) {
    try store.save(ResultPicture(observedAt: picture.observedAt, content: oversized), named: "duplicates")
  }
  #expect(store.load(DuplicatePicture.self, named: "duplicates")?.content == content)
}
