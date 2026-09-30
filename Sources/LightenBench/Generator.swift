import Darwin
import Foundation
import Synchronization

/// Builds a deterministic tree: root/tNNN/mNN/lNN/fNNNN, 32 names per leaf folder.
/// Every 997th name is a relative symlink and every 4999th name is a hard link to
/// the previous regular file, so hard-link deduplication and leaf symlinks are exercised.
struct TreeGenerator {
  let root: String
  let files: Int
  let seed: UInt64

  static let namesPerLeaf = 32

  struct Totals {
    var regularFiles = 0
    var hardLinks = 0
    var symlinks = 0
    var directories = 0
    var logicalBytes: Int64 = 0
  }

  static func mix(_ value: UInt64) -> UInt64 {
    var z = value &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  func run() throws -> [String: Any] {
    var details = stat()
    guard lstat(root, &details) == 0, details.st_mode & S_IFMT == S_IFDIR else {
      throw FileSystemFailureDescription("fixture directory unavailable")
    }
    let leaves = (files + Self.namesPerLeaf - 1) / Self.namesPerLeaf
    let tops = (leaves + 255) / 256
    let shared = Mutex<(Totals, String?)>((Totals(), nil))
    let payload = [UInt8](repeating: 0x6C, count: 4096)
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

    DispatchQueue.concurrentPerform(iterations: tops) { top in
      var local = Totals()
      var localFailure: String?
      let topPath = root + String(format: "/t%03d", top)
      if mkdir(topPath, 0o755) == 0 { local.directories += 1 } else { localFailure = "mkdir \(topPath)" }
      var createdMid = Set<Int>()
      for leaf in (top * 256)..<min((top + 1) * 256, leaves) where localFailure == nil {
        let mid = (leaf / 16) % 16
        let midPath = topPath + String(format: "/m%02d", mid)
        if !createdMid.contains(mid) {
          if mkdir(midPath, 0o755) == 0 { local.directories += 1 } else { localFailure = "mkdir \(midPath)" }
          createdMid.insert(mid)
        }
        let leafPath = midPath + String(format: "/l%02d", leaf % 16)
        guard mkdir(leafPath, 0o755) == 0 else {
          localFailure = "mkdir \(leafPath)"
          break
        }
        local.directories += 1
        var previousRegular: String?
        for slot in 0..<Self.namesPerLeaf {
          let index = leaf * Self.namesPerLeaf + slot
          guard index < files else { break }
          let path = leafPath + String(format: "/f%04d", slot)
          if index > 0 && index % 997 == 0 {
            guard symlink("f0000", path) == 0 else {
              localFailure = "symlink \(path)"
              break
            }
            local.symlinks += 1
            local.logicalBytes += 5
            continue
          }
          if index > 0 && index % 4999 == 0, let previousRegular {
            guard link(previousRegular, path) == 0 else {
              localFailure = "link \(path)"
              break
            }
            local.hardLinks += 1
            continue
          }
          let random = Self.mix(seed ^ UInt64(index))
          let size = random % 10 < 4 ? 0 : Int(1 + (random >> 8) % 4096)
          let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
          guard fd >= 0 else {
            localFailure = "open \(path)"
            break
          }
          let written = size == 0 ? 0 : payload.withUnsafeBytes { write(fd, $0.baseAddress, size) }
          close(fd)
          guard written == size else {
            localFailure = "write \(path)"
            break
          }
          local.regularFiles += 1
          local.logicalBytes += Int64(size)
          previousRegular = path
        }
      }
      shared.withLock { state in
        state.0.regularFiles += local.regularFiles
        state.0.hardLinks += local.hardLinks
        state.0.symlinks += local.symlinks
        state.0.directories += local.directories
        state.0.logicalBytes += local.logicalBytes
        if state.1 == nil { state.1 = localFailure }
      }
    }
    let (totals, failure) = shared.withLock { $0 }
    if let failure { throw FileSystemFailureDescription(failure) }
    return [
      "root": root, "requestedNames": files, "seed": seed,
      "regularFiles": totals.regularFiles, "hardLinks": totals.hardLinks,
      "symlinks": totals.symlinks, "directories": totals.directories,
      "entriesBelowRoot": totals.regularFiles + totals.hardLinks + totals.symlinks + totals.directories,
      "expectedLogicalBytes": totals.logicalBytes,
      "generationSeconds": seconds(from: start, to: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)),
    ]
  }
}

struct FileSystemFailureDescription: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
