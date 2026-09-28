// `pdoom-native video [--from 0] [--to duration] [--fps 60] [--only ids] [--samples N|auto]
//  [--shutter 0.5] [--scale 1] --encoder hevc|x264 [--crf 16] [--preset slow] [--x264 aq-mode=3]
//  [--bitrate 150M] [--noaudio] --out FILE.mp4` (M3). HEVC audio muxing is not wired up yet (video-only
// AVAssetWriter output) — see README.
import Foundation
import Metal
import PdoomCore

func runVideo(args: Args, root: URL) async throws {
  let scale = max(1, args.int("scale", 1))
  let fps = args.int("fps", 60)
  let only = args.opt("only").map { Set($0.split(separator: ",").map(String.init)) }
  let shutter = args.double("shutter", 0.5)
  let samples: SamplesMode = args.opt("samples") == "auto"
    ? .adaptive(AdaptiveSampling(min: args.int("min-samples", 4), max: args.int("max-samples", 324), tol: args.double("tol", 3)))
    : .fixed(args.int("samples", 1))
  let encoderName = try requireOpt(args, "encoder")
  let out = URL(fileURLWithPath: try requireOpt(args, "out"))
  let noAudio = args.flag("noaudio")

  let engine = try Engine(root: root, scale: scale, only: only)
  engine.threads = args.int("threads", 8)
  let from = args.double("from", 0)
  let to = args.opt("to").flatMap(Double.init) ?? engine.audio.duration
  let w = 1920 * scale, h = 1080 * scale
  let totalFrames = Int((to * Double(fps)).rounded()) - Int((from * Double(fps)).rounded())
  guard totalFrames > 0 else { throw EncoderError.failed("--to must be after --from") }

  func frameTime(_ f: Int) -> Double { from + Double(f) / Double(fps) }

  let debugProgress = ProcessInfo.processInfo.environment["PDOOM_DEBUG_PROGRESS"] != nil
  switch encoderName {
  case "hevc":
    let writer = try HEVCWriter(out: out, width: w, height: h, fps: fps, bitrate: 150_000_000, device: engine.device)
    do {
      for f in 0..<totalFrames {
        if debugProgress { FileHandle.standardError.write("frame \(f)/\(totalFrames)\n".data(using: .utf8)!) }
        try writer.writeFrame(f) { texture, _, queue in
          try engine.render(frameTime(f), dt: 1.0 / Double(fps), samples: samples, shutter: shutter, into: texture, commandQueue: queue)
        }
      }
      try await writer.finish()
    } catch {
      writer.cancel(out: out)
      throw error
    }
  case "x264":
    guard let commandQueue = engine.device.makeCommandQueue() else { throw EncoderError.failed("no Metal command queue") }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.shaderWrite, .shaderRead]; desc.storageMode = .shared
    guard let texture = engine.device.makeTexture(descriptor: desc) else { throw EncoderError.failed("could not allocate output texture") }
    let writer = try X264Writer(out: out, width: w, height: h, fps: fps, crf: args.opt("crf", "16")!, preset: args.opt("preset", "slow")!,
                                 x264Params: args.opt("x264", "aq-mode=3")!, audioFrom: from, audioTo: to,
                                 audioFile: noAudio ? nil : root.appendingPathComponent("audio/pdoom.mp3"), noAudio: noAudio)
    do {
      for f in 0..<totalFrames {
        try writer.writeFrame(f, render: { t, _, _ in try engine.render(frameTime(f), dt: 1.0 / Double(fps), samples: samples, shutter: shutter, into: t) },
                               texture: texture, commandQueue: commandQueue)
      }
      try writer.finish(out: out)
    } catch {
      writer.cancel(out: out)
      throw error
    }
  default:
    throw EncoderError.failed("--encoder must be hevc or x264")
  }
  print("wrote \(out.path) (\(totalFrames) frames, \(w)x\(h) @ \(fps)fps, \(encoderName))")
  Profiler.shared.report()
}
