import CryptoKit
import Darwin
import Foundation

/// Presentation fields for the first map. Device and inode proofs are deliberately
/// absent; this result cannot be used to plan an action.
public struct SpacePicture: Codable, Sendable {
  public let root: Row
  public let children: [Row]

  public init(tree: ScanTree) {
    root = Row(tree.item(tree.rootID)!)
    children = tree.children(of: tree.rootID, metric: .logical).map(Row.init)
  }

  public struct Row: Codable, Sendable {
    public let id: ScanItemID
    public let parentID: ScanItemID?
    public let name: String
    public let path: String
    public let kind: NodeKind
    public let logical: ByteAggregate
    public let allocated: ByteAggregate
    public let itemCount: Int64
    public let childCount: Int
    public let partialReason: PartialReason?
    public let protectedRule: String?
    public let summarizedFiles: Int64

    public init(_ item: SpaceItem) {
      id = item.id
      parentID = item.parentID
      name = item.name
      path = item.path
      kind = item.kind
      logical = item.logical
      allocated = item.allocated
      itemCount = item.itemCount
      childCount = item.childCount
      if case .partial(let reason) = item.state { partialReason = reason } else { partialReason = nil }
      if case .protectedMetadataOnly(let rule) = item.state { protectedRule = rule } else { protectedRule = nil }
      summarizedFiles = item.summarizedFiles
    }

    public var item: SpaceItem {
      SpaceItem(
        id: id, parentID: parentID, name: name, path: path, kind: kind, logical: logical, allocated: allocated,
        itemCount: itemCount,
        state: protectedRule.map { .protectedMetadataOnly(ruleID: $0) }
          ?? partialReason.map { .partial($0) } ?? .complete,
        childCount: childCount, device: 0, inode: 0, summarizedFiles: summarizedFiles)
    }
  }
}

extension ResultPictureStore {
  private static func spaceName(_ root: String) -> String {
    let digest = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
    return "space-" + String(digest.prefix(58))
  }

  public func loadSpace(root: String) -> ResultPicture<SpacePicture>? {
    guard let picture = load(SpacePicture.self, named: Self.spaceName(root)), picture.content.root.path == root else {
      return nil
    }
    return picture
  }

  public func clearSpacePictures() throws {
    let fd = DirectoryReader.openDirectory(directory)
    if fd < 0 && errno == ENOENT { return }
    guard fd >= 0 else { throw ResultPictureFailure.unsafe }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0, details.st_uid == geteuid(), details.st_mode & 0o777 == 0o700 else {
      throw ResultPictureFailure.unsafe
    }
    for name in try ExactInventory.names(fd: fd) where name.hasPrefix("space-") && name.hasSuffix(".json") {
      guard unlinkat(fd, name, 0) == 0 else { throw FileSystemFailure.systemCall("clear Space picture", errno) }
    }
  }

  public func saveSpace(tree: ScanTree, observedAt: Date = Date()) throws {
    guard tree.isFinished, !tree.wasCancelled else { return }
    try save(
      ResultPicture(observedAt: observedAt, content: SpacePicture(tree: tree)), named: Self.spaceName(tree.rootPath))
  }
}
