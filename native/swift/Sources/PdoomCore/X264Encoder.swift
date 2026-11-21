// x264 output: spawns ffmpeg reading raw top-down BGRA frames from a pipe, with render.ts's exact
// output args (app/scripts/render.ts `video`): -c:v libx264 -preset slow -crf 16 -tune grain
// -x264-params aq-mode=3 -pix_fmt yuv420p, plus audio when requested, -movflags +faststart.
import Foundation
import Metal

public final class X264Writer {
  private let process: Process
  private let stdin: FileHandle
  private let width: Int
  private let height: Int
  private var scratch: [UInt8]

  public init(out: URL, width: Int, height: Int, fps: Int, crf: String, preset: String, x264Params: String,
              audioFrom: Double?, audioTo: Double?, audioFile: URL?, noAudio: Bool) throws {
    self.width = width; self.height = height
    self.scratch = [UInt8](repeating: 0, count: width * height * 4)
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: out.path) { try? FileManager.default.removeItem(at: out) }

    var args = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)",
                "-r", String(fps), "-i", "pipe:0"]
    if !noAudio, let audioFile {
      if let from = audioFrom, let to = audioTo { args += ["-ss", String(from), "-t", String(to - from)] }
      args += ["-i", audioFile.path]
    }
    args += ["-c:v", "libx264", "-preset", preset, "-crf", crf, "-pix_fmt", "yuv420p", "-tune", "grain", "-x264-params", x264Params]
    if !noAudio && audioFile != nil { args += ["-c:a", "aac", "-b:a", "320k", "-shortest"] }
    args += ["-movflags", "+faststart", out.path]

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["ffmpeg"] + args
    let inPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = FileHandle.standardError
    p.standardError = FileHandle.standardError
    try p.run()
    process = p
    stdin = inPipe.fileHandleForWriting
  }

  /// Renders frame `frame` into a scratch Metal texture, waits for the GPU, reads back tightly-packed
  /// BGRA (ignoring any internal bytesPerRow padding Metal chose for the texture), and pipes it to ffmpeg.
  public func writeFrame(_ frame: Int, render: FrameRenderer, texture: MTLTexture, commandQueue: MTLCommandQueue) throws {
    try render(texture, frame, commandQueue)
    let bytesPerRow = width * 4
    Profiler.shared.time("texture_readback") {
      scratch.withUnsafeMutableBytes { buf in
        texture.getBytes(buf.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
      }
    }
    // the throwing overload (write(contentsOf:)) reports a dead pipe as a Swift error; the legacy
    // write(_:) raises an uncatchable NSException instead, which would crash past our cleanup path
    try Profiler.shared.time("encoder_wait") {
      try scratch.withUnsafeBytes { buf in
        try stdin.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buf.baseAddress!), count: buf.count, deallocator: .none))
      }
    }
  }

  /// Closes the pipe and waits for ffmpeg to exit; throws (nonzero exit, no partial file) on failure.
  public func finish(out: URL) throws {
    try stdin.close()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      try? FileManager.default.removeItem(at: out)
      throw EncoderError.failed("ffmpeg exited \(process.terminationStatus)")
    }
  }

  /// Forced-failure path: kill ffmpeg and remove any partial output.
  public func cancel(out: URL) {
    process.terminate()
    process.waitUntilExit()
    try? FileManager.default.removeItem(at: out)
  }
}
