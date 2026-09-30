import CLightenPlatform
import Darwin
import Foundation
import LightenKit
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

/// The shell waits on stdin after publishing its open descriptor or cwd.
private func shell(at directory: String, command: String, arguments: [String] = []) throws -> (Process, Pipe) {
  let process = Process()
  let input = Pipe()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/zsh")
  process.arguments = ["-c", command, "fixture"] + arguments
  process.currentDirectoryURL = URL(fileURLWithPath: directory)
  process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"]
  process.standardInput = input
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  try process.run()
  let ready = output.fileHandleForReading.readData(ofLength: 6)
  #expect(String(decoding: ready, as: UTF8.self) == "ready\n")
  return (process, input)
}

private func finish(_ process: Process, _ input: Pipe) {
  try? input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
  try? input.fileHandleForWriting.close()
  if process.isRunning { process.terminate() }
  process.waitUntilExit()
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
  let (unrelated, unrelatedInput) = try shell(at: home, command: "print ready; read -r line")
  defer { finish(unrelated, unrelatedInput) }
  #expect(await source.activity(for: row, rootPath: root).state == .clearObservedCurrentUID)
  let (active, activeInput) = try shell(at: root, command: "print ready; read -r line")
  defer { finish(active, activeInput) }
  let evidence = await source.activity(for: row, rootPath: root)
  #expect(evidence.state == .active)
  #expect(evidence.processNames.contains("zsh"))
  let other = try #require(catalog.row(id: "homebrew-downloads"))
  #expect(await source.activity(for: other, rootPath: catalog.root(for: other)).state == .clearObservedCurrentUID)
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
  let (process, input) = try shell(
    at: home, command: "exec 3< \"$1\"; print ready; read -r line", arguments: [path])
  defer { finish(process, input) }
  let source = await MainActor.run { MacOSProcessActivitySource() }
  let evidence = await source.activity(for: row, rootPath: root)
  #expect(evidence.state == .active)
  #expect(evidence.processNames == ["zsh"])
  #expect(await source.activity(for: row, rootPath: root + "-sibling").state == .clearObservedCurrentUID)
}
