import Foundation

/// A user-invoked keeper preference. Discovery never applies this automatically.
public enum DuplicateSelectionRule: Sendable, Equatable {
  case smart, newest, oldest
  case folder(String)

  /// Each compatible subset keeps one file; unverified members remain unselected.
  public func selections(groups: [DuplicateGroup], homeDirectory: String) -> [DuplicateGroupSelection] {
    groups.flatMap { group in
      let eligible = group.members.filter { $0.eligibility == .eligible && $0.compatibilityID != nil }
      let subsets = Dictionary(grouping: eligible) { $0.compatibilityID! }
      return subsets.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { key -> DuplicateGroupSelection? in
        guard let members = subsets[key], members.count > 1,
          let keeper = members.sorted(by: { prefers($0, over: $1, homeDirectory: homeDirectory) }).first
        else { return nil }
        let targets = Set(members.filter { $0.id != keeper.id }.map(\.id))
        return DuplicateGroupSelection(groupID: group.id, keeperID: keeper.id, targetIDs: targets)
      }
    }
  }

  private func prefers(_ first: DuplicateMember, over second: DuplicateMember, homeDirectory: String) -> Bool {
    switch self {
    case .smart:
      let firstTransient = Self.isTransient(first.entry.path, homeDirectory: homeDirectory)
      let secondTransient = Self.isTransient(second.entry.path, homeDirectory: homeDirectory)
      if firstTransient != secondTransient { return !firstTransient }
    case .folder(let path):
      let firstInside = Self.isInside(first.entry.path, directory: path)
      let secondInside = Self.isInside(second.entry.path, directory: path)
      if firstInside != secondInside { return firstInside }
    case .newest, .oldest: break
    }
    let firstDate = first.entry.identity.flatMap(Self.modificationTime)
    let secondDate = second.entry.identity.flatMap(Self.modificationTime)
    if let firstDate, let secondDate, firstDate != secondDate {
      return self == .oldest ? firstDate < secondDate : firstDate > secondDate
    }
    if (firstDate != nil) != (secondDate != nil) { return firstDate != nil }
    if first.entry.path != second.entry.path { return first.entry.path < second.entry.path }
    return first.id.uuidString < second.id.uuidString
  }

  private struct Modification: Comparable {
    let seconds: Int64
    let nanoseconds: Int64
    static func < (first: Self, second: Self) -> Bool {
      first.seconds == second.seconds ? first.nanoseconds < second.nanoseconds : first.seconds < second.seconds
    }
  }

  private static func modificationTime(_ identity: FileIdentity) -> Modification? {
    guard let seconds = identity.modificationSeconds, let nanoseconds = identity.modificationNanoseconds else {
      return nil
    }
    return Modification(seconds: seconds, nanoseconds: nanoseconds)
  }

  private static func isInside(_ path: String, directory: String) -> Bool {
    // Native paths already have an absolute spelling. Preserve it: standardizingPath
    // resolves /tmp to /private/tmp on macOS, which breaks lexical alias matching.
    var normalized = directory
    while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized == "/" ? path.hasPrefix("/") : path == normalized || path.hasPrefix(normalized + "/")
  }

  private static func isTransient(_ path: String, homeDirectory: String) -> Bool {
    let folders = [
      homeDirectory + "/Downloads", homeDirectory + "/Desktop", homeDirectory + "/Library/Caches",
      "/Library/Caches", "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders",
    ]
    let components = (path as NSString).pathComponents
    return folders.contains { isInside(path, directory: $0) }
      || components.contains { [".trash", ".trashes"].contains($0.lowercased()) }
  }
}
