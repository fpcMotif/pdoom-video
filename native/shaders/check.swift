// Compiles the shared shaders the way the native hosts do (common.metal first, then every other .metal
// file under the directory, subfolders included, sorted by relative path; one source, safe math) at output
// scales 1 and 2, and lists the functions.
// Usage: swift native/shaders/check.swift [shader dir]
import Foundation
import Metal

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "native/shaders")
let files = (FileManager.default.subpaths(atPath: dir.path) ?? [])
  .filter { $0.hasSuffix(".metal") }
  .sorted { a, b in a == "common.metal" ? b != "common.metal" : b == "common.metal" ? false : a < b }
let source = try files.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
print("\(device.name): \(files.joined(separator: " "))")
var failed = false
for scale in [1, 2] {
  let options = MTLCompileOptions()
  options.mathMode = .safe
  options.preprocessorMacros = ["PDOOM_SCALE": NSNumber(value: scale)]
  do {
    let library = try device.makeLibrary(source: source, options: options)
    print("scale \(scale): ok: \(library.functionNames.sorted().joined(separator: " "))")
  } catch {
    print("scale \(scale): FAILED\n\(error)")
    failed = true
  }
}
exit(failed ? 1 : 0)
