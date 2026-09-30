import Darwin
import Foundation

/// Process-wide counters sampled before and after a measured run.
struct ProcessSample {
  let wall: UInt64
  let userMicros: Int64
  let systemMicros: Int64
  let unixSyscalls: Int64
  let machSyscalls: Int64

  static func now() -> ProcessSample {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    var events = task_events_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_events_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &events) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
      }
    }
    return ProcessSample(
      wall: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
      userMicros: Int64(usage.ru_utime.tv_sec) * 1_000_000 + Int64(usage.ru_utime.tv_usec),
      systemMicros: Int64(usage.ru_stime.tv_sec) * 1_000_000 + Int64(usage.ru_stime.tv_usec),
      unixSyscalls: status == KERN_SUCCESS ? Int64(events.syscalls_unix) : -1,
      machSyscalls: status == KERN_SUCCESS ? Int64(events.syscalls_mach) : -1)
  }

  static var peakResidentBytes: Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
  }

  static var peakFootprintBytes: Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? Int64(info.ledger_phys_footprint_peak) : -1
  }
}

func seconds(from start: UInt64, to end: UInt64) -> Double {
  Double(end &- start) / 1_000_000_000
}

struct BenchEnvironment {
  let uptime: TimeInterval
  let load: [Double]?

  static func now() -> BenchEnvironment {
    var values = [Double](repeating: 0, count: 3)
    let count = values.withUnsafeMutableBufferPointer { getloadavg($0.baseAddress, 3) }
    return BenchEnvironment(
      uptime: ProcessInfo.processInfo.systemUptime, load: count == 3 ? values : nil)
  }

  var quiet: Bool { load.map { $0[0] < 4 } ?? false }
  var json: [String: Any] {
    ["uptimeSeconds": uptime, "loadAverage": load as Any? ?? NSNull(), "loadSource": "getloadavg"]
  }
}

func emit(_ values: [String: Any], command: String, before: BenchEnvironment) {
  let after = BenchEnvironment.now()
  let measured = before.quiet && after.quiet
  var result = values
  result["command"] = command
  result["environmentStart"] = before.json
  result["environmentEnd"] = after.json
  result["performanceMeasured"] = measured
  if !measured {
    result["performanceUnmeasuredReason"] =
      before.load == nil || after.load == nil ? "load unavailable" : "one-minute load is at least 4"
  }
  // JSON has no NaN. Empty cancellation samples and unknown values remain null,
  // and busy-machine observations never produce a performance claim.
  func sanitized(_ value: Any, keepTiming: Bool) -> Any {
    if let dictionary = value as? [String: Any] {
      return dictionary.reduce(into: [String: Any]()) { result, pair in
        let timing = pair.key.hasSuffix("Seconds") || pair.key.hasSuffix("Ms")
        result[pair.key] = timing && !keepTiming ? NSNull() : sanitized(pair.value, keepTiming: keepTiming)
      }
    }
    if let array = value as? [Any] { return array.map { sanitized($0, keepTiming: keepTiming) } }
    if let number = value as? Double, !number.isFinite { return NSNull() }
    return value
  }
  var output = sanitized(result, keepTiming: measured) as! [String: Any]
  output["environmentStart"] = before.json
  output["environmentEnd"] = after.json
  do {
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  } catch {
    FileHandle.standardError.write(Data("JSON output failed: \(error)\n".utf8))
    exit(1)
  }
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
  guard !values.isEmpty else { return .nan }
  let sorted = values.sorted()
  let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
  return sorted[min(max(rank, 0), sorted.count - 1)]
}
