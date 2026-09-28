// Minimal --flag / --key value argument parsing, matching the CLI in docs and the brief exactly
// (same shape as app/scripts/render.ts's `opt`/`flag` helpers).
import Foundation

struct Args {
  let positional: [String]
  private let raw: [String]

  init(_ argv: [String]) {
    raw = argv
    var pos: [String] = []
    var i = 0
    while i < argv.count {
      let a = argv[i]
      if a.hasPrefix("--") { i += 2 } else { pos.append(a); i += 1 }
    }
    positional = pos
  }

  func opt(_ key: String, _ def: String? = nil) -> String? {
    if let i = raw.firstIndex(of: "--\(key)"), i + 1 < raw.count { return raw[i + 1] }
    return def
  }
  func flag(_ key: String) -> Bool { raw.contains("--\(key)") }
  func double(_ key: String, _ def: Double) -> Double { opt(key).flatMap(Double.init) ?? def }
  func int(_ key: String, _ def: Int) -> Int { opt(key).flatMap(Int.init) ?? def }
}
