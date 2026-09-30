import Foundation

/// A previous result for presentation. It carries no scan or action authority.
public struct ResultPicture<Content: Codable & Sendable>: Codable, Sendable {
  public let observedAt: Date
  public let content: Content

  public init(observedAt: Date, content: Content) {
    self.observedAt = observedAt
    self.content = content
  }
}

/// Bounded, private storage shared by tools that show their previous results.
public struct ResultPictureStore: Sendable {
  public static var defaultDirectory: String {
    FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Lighten/results"
  }

  public let directory: String
  public let maximumBytes: Int

  /// Tests and benchmarks must supply a directory inside their own fixture.
  public init(directory: String = Self.defaultDirectory, maximumBytes: Int = 4 * 1024 * 1024) {
    self.directory = directory
    self.maximumBytes = maximumBytes
  }

  /// Invalid, future, unreadable, or unsafe pictures are ignored without repair.
  public func load<Content: Codable & Sendable>(
    _ type: Content.Type, named name: String
  ) -> ResultPicture<Content>? {
    guard let filename = Self.filename(name), maximumBytes > 0,
      let data = try? ResultPictureFile.read(directory: directory, name: filename, limit: maximumBytes),
      let stored = try? JSONDecoder().decode(StoredPicture<Content>.self, from: data),
      stored.schema == 1, Self.valid(stored.picture.observedAt)
    else { return nil }
    return stored.picture
  }

  public func save<Content: Codable & Sendable>(
    _ picture: ResultPicture<Content>, named name: String
  ) throws {
    guard let filename = Self.filename(name), maximumBytes > 0, Self.valid(picture.observedAt) else {
      throw ResultPictureFailure.invalidPicture
    }
    let data = try JSONEncoder().encode(StoredPicture(schema: 1, picture: picture))
    guard data.count <= maximumBytes else { throw ResultPictureFailure.tooLarge }
    try ResultPictureFile.write(directory: directory, name: filename, data: data, limit: maximumBytes)
  }

  private static func filename(_ name: String) -> String? {
    guard !name.isEmpty, name.utf8.count <= 64,
      name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
    else { return nil }
    return name + ".json"
  }

  private static func valid(_ date: Date) -> Bool {
    date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 >= 0 && date <= Date()
  }
}

public enum ResultPictureFailure: Error, Sendable {
  case invalidPicture, tooLarge, unsafe, changed
}

private struct StoredPicture<Content: Codable & Sendable>: Codable {
  let schema: Int
  let picture: ResultPicture<Content>
}

/// Display fields only. Receipts, identities, related proofs, and plans are absent.
public struct AppsPicture: Codable, Sendable, Equatable {
  public let rows: [Row]
  public let inventoryComplete: Bool

  public init(rows: [Row], inventoryComplete: Bool) {
    self.rows = rows
    self.inventoryComplete = inventoryComplete
  }

  public init(reports: [ApplicationReport], inventoryComplete: Bool) {
    self.init(rows: reports.map(Row.init), inventoryComplete: inventoryComplete)
  }

  public struct Row: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let bundleID: String?
    public let version: String?
    public let signerTeamID: String?
    public let linkTarget: String?
    public let logical: ByteAggregate
    public let allocated: ByteAggregate
    public let knownItemCount: Int
    public let partial: Bool
    public let manualUninstallerSuggested: Bool

    public var id: String { path }

    public init(_ report: ApplicationReport) {
      path = report.path
      bundleID = report.bundleID
      version = report.version
      signerTeamID = report.signerTeamID
      linkTarget = report.linkTarget
      logical = report.logical
      allocated = report.allocated
      knownItemCount = report.knownItemCount
      partial = report.partial
      manualUninstallerSuggested = report.manualUninstallerSuggested
    }
  }
}
