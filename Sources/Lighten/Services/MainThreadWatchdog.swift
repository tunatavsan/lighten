import Foundation
import OSLog
import Synchronization

/// Development aid: pings the main thread every 50 ms from a background thread
/// and logs the longest wait. On in debug builds, or with LIGHTEN_WATCHDOG=1.
enum MainThreadWatchdog {
  #if DEBUG
    nonisolated static let onByDefault = true
  #else
    nonisolated static let onByDefault = false
  #endif

  nonisolated static func startIfEnabled() {
    guard onByDefault || ProcessInfo.processInfo.environment["LIGHTEN_WATCHDOG"] == "1" else { return }
    let thread = Thread { run() }
    thread.name = "Lighten watchdog"
    thread.qualityOfService = .utility
    thread.start()
  }

  nonisolated private static func run() {
    let logger = Logger(subsystem: "com.tavsn.lighten", category: "watchdog")
    let longest = Atomic<UInt64>(0)
    var windowLongest: UInt64 = 0
    var lastReport = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    while true {
      let sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      let answered = DispatchSemaphore(value: 0)
      DispatchQueue.main.async { answered.signal() }
      answered.wait()
      let stall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - sent
      windowLongest = max(windowLongest, stall)
      if stall > longest.load(ordering: .relaxed) { longest.store(stall, ordering: .relaxed) }
      let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      if now - lastReport >= 5_000_000_000 {
        logger.log(
          "main thread longest stall \(windowLongest / 1_000_000, privacy: .public) ms in 5 s; session longest \(longest.load(ordering: .relaxed) / 1_000_000, privacy: .public) ms"
        )
        windowLongest = 0
        lastReport = now
      }
      usleep(50_000)
    }
  }
}
