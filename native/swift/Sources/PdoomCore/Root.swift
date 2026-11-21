// Locates the repository root (the directory holding `data/`, `app/public/fonts/`, `native/shaders/`)
// from the current directory, or from an explicit --root.
import Foundation

public enum RootError: Error, CustomStringConvertible {
  case notFound(String)
  public var description: String {
    switch self {
    case .notFound(let cwd): return "could not find repo root (looked for native/shaders above \(cwd)); pass --root"
    }
  }
}

public func findRepoRoot(explicit: String?) throws -> URL {
  if let explicit {
    return URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL
  }
  var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  let fm = FileManager.default
  while true {
    let marker = dir.appendingPathComponent("native/shaders", isDirectory: true)
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: marker.path, isDirectory: &isDir), isDir.boolValue {
      return dir.standardizedFileURL
    }
    let parent = dir.deletingLastPathComponent()
    if parent.path == dir.path { throw RootError.notFound(FileManager.default.currentDirectoryPath) }
    dir = parent
  }
}
