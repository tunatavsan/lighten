import CLightenPlatform
import Foundation
import Testing

@testable import LightenKit

private func censusObservation(flags: UInt32, path: String) -> ApplicationLiveDataObservation {
  let record = ApplicationLiveDataObservation.Record(
    pid: 123, executable: "/Applications/LightenQA.app/Contents/MacOS/fixture", path: path,
    isCWD: false, device: 1, inode: 2)
  return ApplicationLiveDataObservation(
    records: [record], complete: flags == 0,
    report: ApplicationLiveDataCensusReport(
      complete: flags == 0, recordCount: 1, processesInspected: 1, applicationProcesses: 1,
      descriptorsInspected: 1, failureFlags: flags, elapsedMilliseconds: 30))
}

@Suite("Bounded application data observations")
struct ApplicationLiveDataCensusTests {
  @Test("A fresh complete census replaces process-race records within one deadline")
  func processRaceRetriesWithoutMerging() {
    var now: UInt64 = 1000
    var budgets: [UInt32] = []
    let observed = ApplicationLiveDataObservation.observe(
      maximumBytes: 4096, timeoutMilliseconds: 100,
      read: { maximum, timeout in
        #expect(maximum == 4096)
        budgets.append(timeout)
        now += 30
        return censusObservation(flags: budgets.count == 1 ? 8 : 0, path: budgets.count == 1 ? "/partial" : "/fresh")
      }, uptime: { now })
    #expect(budgets == [100, 70])
    #expect(observed.complete && observed.records.map(\.path) == ["/fresh"])
    #expect(observed.report?.failureFlags == 0 && observed.report?.recordCount == 1)
    #expect(observed.report?.elapsedMilliseconds == 60)
  }

  @Test(
    "Unavailable, memory and timeout observations remain incomplete without retry", arguments: [UInt32(1), 2, 4, 9])
  func genuineFailureNeverRetries(_ flags: UInt32) {
    var calls = 0
    let observed = ApplicationLiveDataObservation.observe(
      timeoutMilliseconds: 100,
      read: { _, _ in
        calls += 1
        return censusObservation(flags: flags, path: "/uncertain")
      }, uptime: { 1000 })
    #expect(calls == 1 && !observed.complete)
    #expect(observed.report?.failureFlags == flags)
    #expect(observed.records.map(\.path) == ["/uncertain"])
  }

  @Test("Continuing process races stop after three whole censuses")
  func processRaceAttemptsAreBounded() {
    var calls = 0
    let observed = ApplicationLiveDataObservation.observe(
      timeoutMilliseconds: 100,
      read: { _, _ in
        calls += 1
        return censusObservation(flags: 8, path: "/partial-" + String(calls))
      }, uptime: { 1000 })
    #expect(calls == 3 && !observed.complete)
    #expect(observed.records.map(\.path) == ["/partial-3"])
    #expect(observed.report?.failureFlags == 8)
  }

  @Test("A late completion cannot establish sharing absence after the original deadline")
  func deadlineCannotRestartOrAuthorizeLateRead() {
    var now: UInt64 = 1000
    var budgets: [UInt32] = []
    let observed = ApplicationLiveDataObservation.observe(
      timeoutMilliseconds: 100,
      read: { _, timeout in
        budgets.append(timeout)
        now += 60
        return censusObservation(flags: budgets.count == 1 ? 8 : 0, path: "/late")
      }, uptime: { now })
    #expect(budgets == [100, 40])
    #expect(!observed.complete && observed.report?.timedOut == true)
    #expect(observed.report?.elapsedMilliseconds == 120)
  }

  @Test("Cancellation never starts a fresh census after a process race")
  func cancellationStopsRetry() async {
    let task = Task { () -> ApplicationLiveDataObservation in
      withUnsafeCurrentTask { $0?.cancel() }
      return ApplicationLiveDataObservation.observe(
        read: { _, _ in
          Issue.record("Cancelled observation started native work")
          return censusObservation(flags: 0, path: "/unexpected")
        }, uptime: { 1000 })
    }
    let observed = await task.value
    #expect(!observed.complete && observed.records.isEmpty)
  }
}
