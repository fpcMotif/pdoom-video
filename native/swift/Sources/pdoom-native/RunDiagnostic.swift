// `pdoom-native diagnostic`: M1's output-path check (see docs/NATIVE_METAL_PIPELINE.md).
import Foundation
import Metal
import PdoomCore

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
