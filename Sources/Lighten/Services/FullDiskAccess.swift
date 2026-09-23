import Darwin
import Foundation

enum FullDiskAccessState: Equatable {
  case granted, notGranted, unknown
}

/// Detects Full Disk Access without reading anything: it only opens and closes
/// locations macOS protects for apps without that permission.
enum FullDiskAccess {
  nonisolated static func check(homeDirectory: String = NSHomeDirectory()) -> FullDiskAccessState {
    let probes = [
      homeDirectory + "/Library/Application Support/com.apple.TCC/TCC.db",
      homeDirectory + "/Library/Safari",
      homeDirectory + "/Library/Mail",
    ]
    var denied = false
    for path in probes {
      let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      if fd >= 0 {
        close(fd)
        return .granted
      }
      if errno == EPERM || errno == EACCES { denied = true }
    }
    return denied ? .notGranted : .unknown
  }
}
