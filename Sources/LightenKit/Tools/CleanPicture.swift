import Foundation

/// Previous Clean results for presentation only; these rows cannot authorize an action.
public struct CleanPicture: Codable, Sendable, Equatable {
  public struct Row: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let categoryID: String
    public let logicalBytes: Int64
    public let sizeComplete: Bool
    public let detail: String?
    public var id: String { categoryID + ":" + path }

    public init(path: String, categoryID: String, logicalBytes: Int64, sizeComplete: Bool, detail: String? = nil) {
      self.path = path
      self.categoryID = categoryID
      self.logicalBytes = logicalBytes
      self.sizeComplete = sizeComplete
      self.detail = detail
    }
  }

  public struct RelatedRow: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let logicalBytes: Int64?
    public let detail: String
    public var id: String { path }

    public init(path: String, logicalBytes: Int64?, detail: String) {
      self.path = path
      self.logicalBytes = logicalBytes
      self.detail = detail
    }
  }

  public let rows: [Row]
  public let relatedRows: [RelatedRow]
  public let partial: Bool

  public init(rows: [Row], relatedRows: [RelatedRow] = [], partial: Bool = false) {
    self.rows = rows
    self.relatedRows = relatedRows
    self.partial = partial
  }
}
