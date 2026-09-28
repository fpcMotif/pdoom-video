// Compiles native/shaders/*.metal at runtime, exactly as docs/NATIVE_METAL_PIPELINE.md and
// native/shaders/check.swift do: common.metal first, then every other .metal file under the shader
// directory (subfolders included) sorted by relative path, as one source, mathMode = .safe, with the
// PDOOM_SCALE preprocessor macro.
import Foundation
import Metal

enum ShaderError: Error, CustomStringConvertible {
  case compile(String)
  var description: String {
    switch self { case .compile(let s): return s }
  }
}

func loadShaderSource(dir: URL) throws -> String {
  let fm = FileManager.default
  guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
    throw ShaderError.compile("cannot list shader directory \(dir.path)")
  }
  var files: [String] = []
  for case let url as URL in en where url.pathExtension == "metal" {
    files.append(url.path.replacingOccurrences(of: dir.path + "/", with: ""))
  }
  files.sort { a, b in
    if a == "common.metal" { return b != "common.metal" }
    if b == "common.metal" { return false }
    return a < b
  }
  guard !files.isEmpty else { throw ShaderError.compile("no .metal files under \(dir.path)") }
  var source = ""
  for f in files {
    source += try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    source += "\n"
  }
  return source
}

func makeShaderLibrary(device: MTLDevice, shaderDir: URL, scale: Int) throws -> MTLLibrary {
  let source = try loadShaderSource(dir: shaderDir)
  let options = MTLCompileOptions()
  options.mathMode = .safe
  options.preprocessorMacros = ["PDOOM_SCALE": NSNumber(value: scale)]
  do {
    return try device.makeLibrary(source: source, options: options)
  } catch {
    throw ShaderError.compile("shader compile failed (scale \(scale)): \(error)")
  }
}
