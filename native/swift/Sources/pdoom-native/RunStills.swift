// `pdoom-native stills --t a,b,c [--only id1,id2] [--samples N|auto] [--shutter 0.5] [--scale 1] --out DIR`:
// one PNG per time, named like render.ts's stills mode (M3).
import Foundation
import Metal
import PdoomCore

func runStills(args: Args, root: URL) async throws {
  let scale = max(1, args.int("scale", 1))
  let times = try requireOpt(args, "t").split(separator: ",").map { s -> Double in
    guard let v = Double(s) else { throw EncoderError.failed("bad --t value '\(s)'") }
    return v
  }
  let only = args.opt("only").map { Set($0.split(separator: ",").map(String.init)) }
  let shutter = args.double("shutter", 0.5)
  let samples: SamplesMode
  if args.opt("samples") == "auto" {
    samples = .adaptive(AdaptiveSampling(min: args.int("min-samples", 4), max: args.int("max-samples", 324), tol: args.double("tol", 3)))
  } else {
    samples = .fixed(args.int("samples", 1))
  }
  let outDir = URL(fileURLWithPath: try requireOpt(args, "out"))
  try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

  let engine = try Engine(root: root, scale: scale, only: only)
  engine.threads = args.int("threads", 8)
  let w = 1920 * scale, h = 1080 * scale
  let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
  desc.usage = [.shaderWrite, .shaderRead]
  desc.storageMode = .shared
  guard let outTex = engine.device.makeTexture(descriptor: desc) else { throw EncoderError.failed("could not allocate output texture") }

  let isAuto = args.opt("samples") == "auto"
  for t in times {
    let k = try engine.render(t, samples: samples, shutter: shutter, into: outTex)
    if isAuto { print("t=\(t): \(k) sub-frames") }
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    rgba.withUnsafeMutableBytes { buf in
      outTex.getBytes(buf.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    }
    let name = "f_\(padStart(String(format: "%.2f", t), 7))"
    let out = outDir.appendingPathComponent("\(name).png")
    try writePNG(rgba: rgba, width: w, height: h, to: out)
    print(out.path)
  }
  Profiler.shared.report()
}

private func padStart(_ s: String, _ len: Int) -> String {
  s.count >= len ? s : String(repeating: "0", count: len - s.count) + s
}
