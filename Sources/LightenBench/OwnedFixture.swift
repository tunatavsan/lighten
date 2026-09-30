import Darwin
import Foundation

/// Bench writes are confined to a newly reserved temporary directory.
struct OwnedFixture {
  let directory: String

  init(path: String? = nil) throws {
    guard let temporaryRoot = realpath(NSTemporaryDirectory(), nil) else {
      throw FileSystemFailureDescription("temporary directory unavailable")
    }
    defer { free(temporaryRoot) }
    let temporary = String(cString: temporaryRoot)
    let requested = path ?? temporary + "/LightenQA-" + UUID().uuidString
    let parent = (requested as NSString).deletingLastPathComponent
    let name = (requested as NSString).lastPathComponent
    guard requested.hasPrefix("/"), name.hasPrefix("LightenQA-"),
      UUID(uuidString: String(name.dropFirst("LightenQA-".count))) != nil,
      let resolved = realpath(parent, nil)
    else { throw FileSystemFailureDescription("output must be a fresh temporary LightenQA-UUID directory") }
    defer { free(resolved) }
    let canonicalParent = String(cString: resolved)
    guard canonicalParent == temporary || canonicalParent == "/private/tmp" else {
      throw FileSystemFailureDescription("output must be directly inside the system temporary directory")
    }
    directory = canonicalParent + "/" + name
    guard mkdir(directory, 0o700) == 0 else {
      throw FileSystemFailureDescription("reserve fixture: \(String(cString: strerror(errno)))")
    }
  }

  func remove() throws { try FileManager.default.removeItem(atPath: directory) }
}
