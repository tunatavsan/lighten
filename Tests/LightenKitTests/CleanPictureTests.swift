import Foundation
import Testing

@testable import LightenKit

@Test("Clean pictures encode only presentation fields and retain empty partial results")
func cleanPictureContainsDisplayFieldsOnly() throws {
  let content = CleanPicture(
    rows: [
      .init(path: "/fixture/cache", categoryID: "cache", logicalBytes: 123, sizeComplete: false, detail: "Unavailable")
    ],
    relatedRows: [.init(path: "/fixture/old-data", logicalBytes: 4, detail: "Previous result")], partial: true)
  let data = try JSONEncoder().encode(content)
  #expect(try JSONDecoder().decode(CleanPicture.self, from: data) == content)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(Set(object.keys) == ["rows", "relatedRows", "partial"])
  let rows = try #require(object["rows"] as? [[String: Any]])
  #expect(Set(rows[0].keys) == ["path", "categoryID", "logicalBytes", "sizeComplete", "detail"])
  let related = try #require(object["relatedRows"] as? [[String: Any]])
  #expect(Set(related[0].keys) == ["path", "logicalBytes", "detail"])
  let empty = CleanPicture(rows: [], partial: true)
  #expect(try JSONDecoder().decode(CleanPicture.self, from: JSONEncoder().encode(empty)) == empty)
}
