import CLightenPlatform
import Foundation
import LightenKit

struct NativeSystemMetricsProvider: SystemMetricsProvider {
  @concurrent nonisolated func sample() async -> SystemObservation {
    guard !Task.isCancelled else { return Self.unavailable() }
    let result = Self.read()
    return Task.isCancelled ? Self.unavailable() : result
  }

  private nonisolated static func unavailable() -> SystemObservation {
    SystemObservation(observedAt: Date(), pressure: .unknown, swap: nil, census: nil)
  }

  private nonisolated static func read() -> SystemObservation {
    var rawPressure: Int32 = 0
    var pressureSize: UInt64 = 0
    let pressureResult = lighten_read_pressure(&rawPressure, &pressureSize)
    let pressure = MemoryPressure.decode(
      raw: pressureResult == 0 ? rawPressure : nil,
      size: pressureResult == 0 ? Int(pressureSize) : nil)

    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    let swap: SwapMeasure? =
      lighten_read_swap(&swapUsed, &swapTotal) == 0
      ? SwapMeasure(usedBytes: swapUsed, totalBytes: swapTotal) : nil

    var native = [LightenProcessSample](
      repeating: LightenProcessSample(), count: 4096)
    var count: Int32 = 0
    var unreadable: Int32 = 0
    var truncated: Int32 = 0
    var ticks: UInt64 = 0
    var numer: UInt32 = 0
    var denom: UInt32 = 0
    let status = native.withUnsafeMutableBufferPointer { buffer in
      lighten_read_processes(
        buffer.baseAddress, Int32(buffer.count), &count, &unreadable,
        &truncated, &ticks, &numer, &denom)
    }
    var census: ProcessCensus?
    if status == 0, count >= 0, count <= native.count {
      let processes = native.prefix(Int(count)).map { row in
        var row = row
        let name = withUnsafePointer(to: &row) { pointer in
          String(cString: lighten_process_name(pointer))
        }
        return ProcessMeasure(
          identity: ProcessIdentity(
            pid: row.pid, startSeconds: row.start_seconds,
            startMicroseconds: row.start_microseconds),
          name: name, residentBytes: row.resident_bytes,
          userTicks: row.user_ticks, systemTicks: row.system_ticks)
      }
      census = ProcessCensus(
        processes: processes, unreadableCount: Int(unreadable),
        truncated: truncated != 0, ticks: ticks,
        timebaseNumer: numer, timebaseDenom: denom)
    }
    return SystemObservation(observedAt: Date(), pressure: pressure, swap: swap, census: census)
  }
}
