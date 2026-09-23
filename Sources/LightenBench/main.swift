import Darwin
import Foundation
import LightenKit

// lighten-bench: measurement tool for scan engines. It never mutates anything
// except a tree it creates itself with `generate`.
//
//   lighten-bench generate --out DIR --files N [--seed S]
//   lighten-bench scan --engine old|new --root PATH [--timeout SECONDS] [--workers N]
//   lighten-bench cancel --engine old|new --root PATH [--trials N] [--workers N]

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
      usage: lighten-bench generate --out DIR --files N [--seed S]
             lighten-bench scan --engine old|new --root PATH [--timeout SECONDS] [--workers N]
             lighten-bench cancel --engine old|new --root PATH [--trials N] [--workers N]

      """.utf8))
  exit(64)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }
let options = Options(arguments.dropFirst(2))

switch arguments[1] {
case "generate":
  guard let out = options.string("out") else { usage() }
  do {
    let manifest = try TreeGenerator(
      root: out, files: options.int("files", 100_000), seed: UInt64(options.int("seed", 1))
    ).run()
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
    try data.write(to: URL(fileURLWithPath: out + ".manifest.json"))
    emit(manifest)
  } catch {
    FileHandle.standardError.write(Data("generate failed: \(error)\n".utf8))
    exit(1)
  }
case "scan":
  guard let root = options.string("root"), let engine = options.string("engine") else { usage() }
  let result = await Bench.scan(
    engine: engine, root: root, timeout: options.double("timeout", 600),
    workers: options.int("workers", 0))
  emit(result)
case "cancel":
  guard let root = options.string("root"), let engine = options.string("engine") else { usage() }
  let result = await Bench.cancellation(
    engine: engine, root: root, trials: options.int("trials", 20), workers: options.int("workers", 0))
  emit(result)
default:
  usage()
}
