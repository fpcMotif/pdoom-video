// pdoom-native: CLI entry point. Subcommands: diagnostic, post-fixture, stills, video (see README / the
// coordinator's brief for the exact shape). M1 implements `diagnostic` for both encoders end to end.
import Foundation
import Metal

@main
struct Main {
  static func main() async {
    // A dead ffmpeg child closes its stdin pipe; without this, writing to it delivers SIGPIPE and kills
    // us before our own error handling (partial-file cleanup, a clean nonzero exit) can run.
    signal(SIGPIPE, SIG_IGN)
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let mode = argv.first else {
      FileHandle.standardError.write("usage: pdoom-native diagnostic|post-fixture|stills|video ... [--root DIR]\n".data(using: .utf8)!)
      exit(2)
    }
    let args = Args(Array(argv.dropFirst()))
    do {
      let root = try findRepoRoot(explicit: args.opt("root"))
      switch mode {
      case "diagnostic": try await runDiagnostic(args: args, root: root)
      case "post-fixture": try runPostFixture(args: args, root: root)
      case "stills": try await runStills(args: args, root: root)
      case "video": try await runVideo(args: args, root: root)
      default:
        FileHandle.standardError.write("unknown subcommand '\(mode)'\n".data(using: .utf8)!)
        exit(2)
      }
    } catch {
      FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
      exit(1)
    }
  }
}

func requireOpt(_ args: Args, _ key: String) throws -> String {
  guard let v = args.opt(key) else { throw EncoderError.failed("--\(key) is required") }
  return v
}

// -------------------------------------------------------------------------------------------- diagnostic
func runDiagnostic(args: Args, root: URL) async throws {
  let frames = args.int("frames", -1)
  guard frames > 0 else { throw EncoderError.failed("--frames N is required") }
  let fps = args.int("fps", 60)
  let scale = max(1, args.int("scale", 1))
  let encoderName = try requireOpt(args, "encoder")
  let outPath = try requireOpt(args, "out")
  let out = URL(fileURLWithPath: outPath)
  let w = 1920 * scale, h = 1080 * scale

  guard let device = MTLCreateSystemDefaultDevice() else { throw EncoderError.failed("no Metal device") }
  let library = try makeShaderLibrary(device: device, shaderDir: root.appendingPathComponent("native/shaders"), scale: scale)
  let diag = try DiagnosticRenderer(device: device, library: library)

  switch encoderName {
  case "hevc":
    guard #available(macOS 26.0, *) else { throw EncoderError.failed("HEVC path needs macOS 26+ (AVAssetWriter.inputPixelBufferReceiver)") }
    let writer = try HEVCWriter(out: out, width: w, height: h, fps: fps, bitrate: 150_000_000, device: device)
    do {
      for f in 0..<frames {
        try await writer.writeFrame(f) { texture, frame, queue in try diag.render(into: texture, frame: frame, commandQueue: queue) }
      }
      try await writer.finish()
    } catch {
      writer.cancel(out: out)
      throw error
    }
  case "x264":
    guard let commandQueue = device.makeCommandQueue() else { throw EncoderError.failed("no Metal command queue") }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.shaderWrite, .shaderRead]
    desc.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: desc) else { throw EncoderError.failed("could not allocate output texture") }
    let writer = try X264Writer(out: out, width: w, height: h, fps: fps, crf: "16", preset: "slow", x264Params: "aq-mode=3",
                                 audioFrom: nil, audioTo: nil, audioFile: nil, noAudio: true)
    do {
      for f in 0..<frames {
        try writer.writeFrame(f, render: { t, fr, q in try diag.render(into: t, frame: fr, commandQueue: q) }, texture: texture, commandQueue: commandQueue)
      }
      try writer.finish(out: out)
    } catch {
      writer.cancel(out: out)
      throw error
    }
  default:
    throw EncoderError.failed("--encoder must be hevc or x264")
  }
  print("wrote \(out.path) (\(frames) frames, \(w)x\(h) @ \(fps)fps, \(encoderName))")
}

// -------------------------------------------------------------------------------------------- stubs (M2/M3)
func runPostFixture(args: Args, root: URL) throws {
  throw EncoderError.failed("post-fixture: not implemented yet (M2)")
}
func runStills(args: Args, root: URL) async throws {
  throw EncoderError.failed("stills: not implemented yet (M3)")
}
func runVideo(args: Args, root: URL) async throws {
  throw EncoderError.failed("video: not implemented yet (M3)")
}
