import Foundation
import Testing

@testable import LightenKit

@Test(
  "Pressure recognizes only the exact native category and Int32 size",
  arguments: [
    (Int32(1), MemoryPressure.normal),
    (Int32(2), MemoryPressure.warning),
    (Int32(4), MemoryPressure.critical),
    (Int32(74), MemoryPressure.unknown),
  ])
func pressureCategory(value: Int32, expected: MemoryPressure) {
  #expect(MemoryPressure.decode(raw: value, size: 4) == expected)
  #expect(MemoryPressure.decode(raw: value, size: 8) == .unknown)
  #expect(MemoryPressure.decode(raw: nil, size: 4) == .unknown)
}

@Test("Swap zero allocation has no ratio")
func zeroSwapRatio() {
  #expect(SwapMeasure(usedBytes: 0, totalBytes: 0).fraction == nil)
  #expect(SwapMeasure(usedBytes: 25, totalBytes: 100).fraction == 0.25)
  #expect(SwapMeasure(usedBytes: 101, totalBytes: 100).fraction == nil)
}

private func process(
  pid: Int32 = 42, start: UInt64 = 100, rss: UInt64 = 1_000,
  user: UInt64 = 0, system: UInt64 = 0
) -> ProcessMeasure {
  ProcessMeasure(
    identity: ProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 0),
    name: "fixture", residentBytes: rss, userTicks: user, systemTicks: system)
}

private func census(
  _ processes: [ProcessMeasure], ticks: UInt64,
  unreadable: Int = 0, truncated: Bool = false
) -> ProcessCensus {
  ProcessCensus(
    processes: processes, unreadableCount: unreadable, truncated: truncated,
    ticks: ticks, timebaseNumer: 125, timebaseDenom: 3)
}

@Test("CPU is unknown for first, invalid and reused samples; two valid deltas use one core")
func processCPUDelta() {
  let before = process(user: 100, system: 100)
  let after = process(user: 200, system: 200)
  let first = census([before], ticks: 1_000)
  let second = census([after], ticks: 1_200)
  #expect(SystemProjection.topProcesses(current: first, prior: nil)[0].corePercent == nil)
  #expect(SystemProjection.topProcesses(current: second, prior: first)[0].corePercent == 100)
  #expect(
    SystemProjection.corePercent(
      current: after, prior: before, currentCensus: second,
      priorCensus: census([before], ticks: 1_200)) == nil)
  #expect(
    SystemProjection.corePercent(
      current: process(start: 101, user: 200, system: 200), prior: before,
      currentCensus: second, priorCensus: first) == nil)
  #expect(
    SystemProjection.corePercent(
      current: process(user: 99, system: 200), prior: before,
      currentCensus: second, priorCensus: first) == nil)
  #expect(
    SystemProjection.corePercent(
      current: process(user: .max, system: .max), prior: before,
      currentCensus: second, priorCensus: first) == nil)
}

@Test("Top processes are RSS ranked and coverage remains partial")
func processCoverage() {
  let rows = (1...12).map { process(pid: Int32($0), rss: UInt64($0)) }
  let current = census(rows, ticks: 2_000, unreadable: 1, truncated: true)
  #expect(current.partial)
  #expect(SystemProjection.topProcesses(current: current, prior: nil).count == 10)
  #expect(SystemProjection.topProcesses(current: current, prior: nil)[0].id.pid == 12)
}
