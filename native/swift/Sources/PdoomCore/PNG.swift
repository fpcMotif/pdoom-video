// Writes a raw RGBA8 buffer as a PNG by piping it through ffmpeg (same approach as
// native/verify/verify.ts's writePng), so the file it produces is exactly what that verifier decodes.
import Foundation

public func writePNG(rgba: [UInt8], width: Int, height: Int, to out: URL) throws {
  try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  p.arguments = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)", "-i", "-", out.path]
  let inPipe = Pipe()
  p.standardInput = inPipe
  p.standardError = FileHandle.standardError
  try p.run()
  try rgba.withUnsafeBytes { buf in
    try inPipe.fileHandleForWriting.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buf.baseAddress!), count: buf.count, deallocator: .none))
  }
  try inPipe.fileHandleForWriting.close()
  p.waitUntilExit()
  if p.terminationStatus != 0 { throw EncoderError.failed("ffmpeg could not write \(out.path)") }
}
