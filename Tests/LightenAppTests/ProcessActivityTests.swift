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

private func requireReady(_ output: FileHandle) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  var ready = Data()
  while ready.count < 6 && ContinuousClock.now < deadline {
    var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
    let available = Darwin.poll(&descriptor, 1, 0)
    if available > 0 {
      var bytes = [UInt8](repeating: 0, count: 6 - ready.count)
      let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
      guard count > 0 else { throw ShellFixtureFailure.notReady }
      ready.append(contentsOf: bytes.prefix(count))
    } else if available < 0 && errno != EINTR {
      throw ShellFixtureFailure.notReady
    } else {
      try await Task.sleep(for: .milliseconds(5))
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
    at: home, command: "trap '' TERM; print ready; read -r line; while true; do :; done"
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
