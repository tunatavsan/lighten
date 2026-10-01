import Darwin
import Foundation
import LightenKit

// Read-only observations. Writes are limited to fresh temporary fixtures.
//
//   lighten-bench generate --out DIR --files N [--seed S]
//   lighten-bench scan --engine old|new --root PATH [--timeout SECONDS] [--workers N] [--sink min=1MB]
//   lighten-bench apps [--app PATH]
//   lighten-bench cancel --engine old|new --root PATH [--trials N] [--workers N]
//   lighten-bench dup --root PATH [--timeout SECONDS]
//   lighten-bench clean [--home PATH] [--row ID] [--timeout SECONDS]
//   lighten-bench cache-load|space-open --root PATH [--timeout SECONDS]
//   lighten-bench fsevents [--root PATH] [--seconds N]
//   lighten-bench survey [--home PATH] [--scope all|space|apps] [--folder-limit N] [--timeout SECONDS]

struct Options {
  var values: [String: String] = [:]

  init(_ arguments: ArraySlice<String>) {
    var iterator = arguments.makeIterator()
    while let key = iterator.next() {
      guard key.hasPrefix("--") else { continue }
      values[String(key.dropFirst(2))] = iterator.next() ?? ""
    }
  }

  func string(_ key: String) -> String? { values[key] }
  func int(_ key: String, _ fallback: Int) -> Int { values[key].flatMap(Int.init) ?? fallback }
  func double(_ key: String, _ fallback: Double) -> Double { values[key].flatMap(Double.init) ?? fallback }
}

func usage() -> Never {
  FileHandle.standardError.write(
    Data(
      """
      usage: lighten-bench generate [--out TEMP/LightenQA-UUID] --files N [--seed S]
             lighten-bench scan --engine old|new --root PATH [--timeout SECONDS] [--workers N] [--sink min=1MB]
             lighten-bench apps [--app PATH]
             lighten-bench cancel --engine old|new --root PATH [--trials N] [--workers N]
             lighten-bench dup --root PATH [--timeout SECONDS]
             lighten-bench clean [--home PATH] [--row ID] [--timeout SECONDS]
             lighten-bench cache-load|space-open --root PATH [--timeout SECONDS] [--workers N]
             lighten-bench fsevents [--root PATH] [--seconds N]
             lighten-bench survey [--home PATH] [--scope all|space|apps] [--folder-limit N] [--timeout SECONDS] [--workers N]

      """.utf8))
  exit(64)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }
let options = Options(arguments.dropFirst(2))
let environment = BenchEnvironment.now()
let command = arguments[1]

func output(_ values: [String: Any]) {
  emit(values, command: command, before: environment)
}

switch command {
case "generate":
  var fixture: OwnedFixture?
  do {
    let owned = try OwnedFixture(path: options.string("out"))
    fixture = owned
    var manifest = try TreeGenerator(
      root: owned.directory, files: max(0, options.int("files", 100_000)),
      seed: UInt64(max(0, options.int("seed", 1)))
    ).run()
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
    let manifestPath = owned.directory + "/manifest.json"
    try data.write(to: URL(fileURLWithPath: manifestPath))
    manifest["fixtureDirectory"] = owned.directory
    manifest["manifestPath"] = manifestPath
    let persistent = options.string("out") != nil
    if !persistent { try owned.remove() }
    manifest["fixtureRemoved"] = !persistent
    manifest["cleanupRequired"] = persistent
    output(manifest)
  } catch {
    var result: [String: Any] = ["error": String(describing: error)]
    if let fixture {
      result["fixtureDirectory"] = fixture.directory
      do {
        try fixture.remove()
        result["fixtureRemoved"] = true
      } catch {
        result["cleanupError"] = String(describing: error)
      }
    }
    output(result)
    exit(1)
  }
case "scan":
  guard let root = options.string("root"), let engine = options.string("engine") else { usage() }
  let sinkMinimumBytes: Int64?
  if let sink = options.string("sink") {
    guard sink == "min=1MB" else {
      output(["error": "unsupported sink filter; use --sink min=1MB"])
      exit(64)
    }
    sinkMinimumBytes = 1_000_000
  } else {
    sinkMinimumBytes = nil
  }
  let result = await Bench.scan(
    engine: engine, root: root, timeout: options.double("timeout", 600),
    workers: options.int("workers", 0), sinkMinimumBytes: sinkMinimumBytes)
  output(result)
case "apps":
  output(await Bench.apps(focus: options.string("app") ?? "/Applications/Xcode.app"))
case "cancel":
  guard let root = options.string("root"), let engine = options.string("engine") else { usage() }
  let result = await Bench.cancellation(
    engine: engine, root: root, trials: max(1, options.int("trials", 20)), workers: options.int("workers", 0))
  output(result)
case "dup":
  guard let root = options.string("root") else { usage() }
  output(await Bench.duplicates(root: root, timeout: options.double("timeout", 600)))
case "clean":
  output(
    await Bench.clean(
      home: options.string("home") ?? NSHomeDirectory(), rowID: options.string("row"),
      timeout: options.double("timeout", 600)))
case "cache-load", "space-open":
  guard let root = options.string("root") else { usage() }
  output(
    await Bench.cachedSpace(
      root: root, layout: command == "space-open", timeout: options.double("timeout", 600),
      workers: options.int("workers", 0)))
case "fsevents":
  output(await Bench.fileEvents(root: options.string("root"), duration: options.double("seconds", 2)))
case "survey":
  exit(await RealUseSurvey.run(options: options, environment: environment))
default:
  usage()
}
