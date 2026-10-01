import CLightenPlatform
import Darwin
import Foundation
import LightenKit
import Synchronization
import Testing

@testable import Lighten

@Test("Process paths match the selected root on component boundaries")
func processRootBoundaries() {
  #expect(lighten_path_is_under_root("/private/tmp/cache/file", "/private/tmp/cache") == 1)
  #expect(lighten_path_is_under_root("/private/tmp/cache", "/private/tmp/cache") == 1)
  #expect(lighten_path_is_under_root("/private/tmp/cache-sibling/file", "/private/tmp/cache") == 0)
  #expect(lighten_path_is_under_root("/private/tmp/cache", "relative") == 0)
  var name = [CChar](repeating: 0, count: 256)
  #expect(lighten_process_activity("relative", &name, name.count) == -1)
}

private func activityFixture() throws -> String {
  let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
  defer { free(resolved) }
  let home = String(cString: resolved) + "/LightenQA-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
  return home
}

private final class ShellExit: Sendable {
  let observed = Mutex(false)
}

private enum ShellFixtureFailure: Error { case notReady }
private enum ExecutableFixtureFailure: Error {
  case exitedBeforeObservation(status: Int32, diagnostic: String)
}

/// The shell holds its descriptor or cwd until the test sends its finish line.
private func withShell<Result>(
  at directory: String, command: String, arguments: [String] = [],
  operation: (pid_t) async throws -> Result
) async throws -> Result {
  let process = Process()
  let input = Pipe()
  let output = Pipe()
  let exit = ShellExit()
  process.executableURL = URL(fileURLWithPath: "/bin/zsh")
  process.arguments = ["-c", command, "fixture"] + arguments
  process.currentDirectoryURL = URL(fileURLWithPath: directory)
  process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"]
  process.standardInput = input
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  process.terminationHandler = { _ in exit.observed.withLock { $0 = true } }
  try process.run()
  do {
    try await requireReady(output.fileHandleForReading)
    let result = try await operation(process.processIdentifier)
    await finish(process, input, exit)
    return result
  } catch {
    await finish(process, input, exit)
    throw error
  }
}

@Test("A selected folder observes a native helper inside nested opaque packages")
func applicationActivityUsesSelectedRootForNestedHelper() async throws {
  let home = try activityFixture()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let root = home + "/DeviceSupport"
  let helper = root + "/LightenQA-framework.framework/Helpers/LightenQA-nested.app/Contents/MacOS/LightenQA-helper"
  try FileManager.default.createDirectory(
    atPath: (helper as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: helper)
  let process = Process()
  let input = Pipe()
  let errors = Pipe()
  let exit = ShellExit()
  process.executableURL = URL(fileURLWithPath: helper)
  process.arguments = ["30"]
  process.currentDirectoryURL = URL(fileURLWithPath: home)
  process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"]
  process.standardInput = input
  process.standardOutput = FileHandle.nullDevice
  process.standardError = errors
  process.terminationHandler = { _ in exit.observed.withLock { $0 = true } }
  try process.run()
  do {
    let source = NativeApplicationActivitySource()
    var observed = ApplicationActivity(state: .unknown)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    repeat {
      observed = await source.activity(applicationPath: root)
      if observed.state == .active { break }
      if !process.isRunning {
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        throw ExecutableFixtureFailure.exitedBeforeObservation(
          status: process.terminationStatus, diagnostic: String(decoding: data, as: UTF8.self))
      }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    #expect(observed.state == .active)
    #expect(observed.processNames == ["LightenQA-helper"])
    #expect(await source.activity(applicationPath: root + "-sibling").state != .active)
  } catch {
    await finish(process, input, exit)
    throw error
  }
  await finish(process, input, exit)
}

private func requireReady(_ output: FileHandle) async throws {
  let descriptorFD = output.fileDescriptor
  let ready = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
    DispatchQueue.global(qos: .userInitiated).async {
      let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
      var ready = Data()
      do {
        while ready.count < 6 {
          let now = DispatchTime.now().uptimeNanoseconds
          guard now < deadline else { break }
          let remainingMilliseconds = min(2_000, (deadline - now + 999_999) / 1_000_000)
          var descriptor = pollfd(fd: descriptorFD, events: Int16(POLLIN), revents: 0)
          let available = Darwin.poll(&descriptor, 1, Int32(remainingMilliseconds))
          if available < 0 && errno == EINTR { continue }
          if available == 0 { break }
          guard available > 0 else { throw ShellFixtureFailure.notReady }
          var bytes = [UInt8](repeating: 0, count: 6 - ready.count)
          let count = Darwin.read(descriptorFD, &bytes, bytes.count)
          guard count > 0 else { throw ShellFixtureFailure.notReady }
          ready.append(contentsOf: bytes.prefix(count))
        }
        continuation.resume(returning: ready)
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
  try #require(String(decoding: ready, as: UTF8.self) == "ready\n")
}

private func shellHasExited(_ process: Process, _ exit: ShellExit) -> Bool {
  if exit.observed.withLock({ $0 }) { return true }
  // Foundation may fail to deliver its reaper notification after the child exits.
  return Darwin.kill(process.processIdentifier, 0) == -1 && errno == ESRCH
}

private func awaitExit(_ process: Process, _ exit: ShellExit, within duration: Duration) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: duration)
  while !shellHasExited(process, exit), ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(10))
  }
  return shellHasExited(process, exit)
}

private func finish(_ process: Process, _ input: Pipe, _ exit: ShellExit) async {
  if !shellHasExited(process, exit) {
    try? input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
  }
  try? input.fileHandleForWriting.close()
  if await awaitExit(process, exit, within: .milliseconds(500)) { return }
  _ = Darwin.kill(process.processIdentifier, SIGTERM)
  if await awaitExit(process, exit, within: .milliseconds(500)) { return }
  _ = Darwin.kill(process.processIdentifier, SIGKILL)
  #expect(await awaitExit(process, exit, within: .seconds(1)), "Owned shell fixture did not exit after SIGKILL")
}

@Test("Shell fixture cleanup escalates when a child ignores its finish line and TERM")
func processFixtureCleanupKillsUnresponsiveShell() async throws {
  let home = try activityFixture()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let pid = try await withShell(
    at: home,
    command: "zmodload zsh/zselect; trap '' TERM; print ready; read -r line; while true; do zselect -t 100; done"
  ) { pid in pid }
  #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
}

@Test("A shell outside the cache never vetoes it; its cwd inside the cache does")
func processActivityUsesRealCwd() async throws {
  let home = try activityFixture()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let catalog = try CleanCatalog(homeDirectory: home)
  let row = try #require(catalog.row(id: "pip-http-v2"))
  let root = catalog.root(for: row)
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  let source = await MainActor.run { MacOSProcessActivitySource() }
  try await withShell(at: home, command: "print ready; read -r line") { _ in
    #expect(await source.activity(for: row, rootPath: root).state == .clearObservedCurrentUID)
    try await withShell(at: root, command: "print ready; read -r line") { _ in
      let evidence = await source.activity(for: row, rootPath: root)
      #expect(evidence.state == .active)
      #expect(evidence.processNames.contains("zsh"))
      let other = try #require(catalog.row(id: "homebrew-downloads"))
      #expect(await source.activity(for: other, rootPath: catalog.root(for: other)).state == .clearObservedCurrentUID)
    }
  }
}

@Test("A shell holding a cache file pauses that root even with an unrelated cwd")
func processActivityUsesRealOpenDescriptor() async throws {
  let home = try activityFixture()
  defer { try? FileManager.default.removeItem(atPath: home) }
  let catalog = try CleanCatalog(homeDirectory: home)
  let row = try #require(catalog.row(id: "homebrew-downloads"))
  let root = catalog.root(for: row)
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  let path = root + "/LightenQA-" + UUID().uuidString
  try Data("cache".utf8).write(to: URL(fileURLWithPath: path))
  let source = await MainActor.run { MacOSProcessActivitySource() }
  try await withShell(
    at: home, command: "exec 3< \"$1\"; print ready; read -r line", arguments: [path]
  ) { _ in
    let evidence = await source.activity(for: row, rootPath: root)
    #expect(evidence.state == .active)
    #expect(evidence.processNames == ["zsh"])
    #expect(await source.activity(for: row, rootPath: root + "-sibling").state == .clearObservedCurrentUID)
  }
}
