// `pdoom-native post-fixture --fixtures DIR --out DIR`: runs PostRenderer over each fixture captured by
// native/verify/capture-post.ts and writes DIR/<name>.final.png, for comparison with the fixture's own
// <name>.final.png (Chrome's output) via `bun native/verify/verify.ts compare` (M2 acceptance).
import Foundation
import Metal
import PdoomCore

private struct FixtureIndex: Codable { let scale: Int; let frames: [String] }
private struct FixtureJSON: Codable { let t: Double; let width: Int; let height: Int; let scale: Int; let samples: Int; let post: PostParams }

private func loadF16Texture(device: MTLDevice, path: URL, width: Int, height: Int) throws -> MTLTexture {
  let data = try Data(contentsOf: path)
  let expected = width * height * 4 * 2 // RGBA, 2 bytes/channel (Float16)
  guard data.count == expected else {
    throw EncoderError.failed("\(path.lastPathComponent): \(data.count) bytes, expected \(expected) (\(width)x\(height) RGBA16Float)")
  }
  let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
  desc.usage = [.shaderRead]
  desc.storageMode = .shared
  guard let tex = device.makeTexture(descriptor: desc) else { throw EncoderError.failed("could not allocate \(width)x\(height) texture for \(path.lastPathComponent)") }
  data.withUnsafeBytes { buf in
    tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: width * 4 * 2)
  }
  return tex
}

func runPostFixture(args: Args, root: URL) throws {
  let fixturesDir = URL(fileURLWithPath: try requireOpt(args, "fixtures"))
  let outDir = URL(fileURLWithPath: try requireOpt(args, "out"))
  try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

  let index = try JSONDecoder().decode(FixtureIndex.self, from: Data(contentsOf: fixturesDir.appendingPathComponent("index.json")))
  guard let device = MTLCreateSystemDefaultDevice() else { throw EncoderError.failed("no Metal device") }
  guard let commandQueue = device.makeCommandQueue() else { throw EncoderError.failed("no Metal command queue") }
  let library = try makeShaderLibrary(device: device, shaderDir: root.appendingPathComponent("native/shaders"), scale: index.scale)
  let post = try PostRenderer(device: device, library: library)

  for name in index.frames {
    let j = try JSONDecoder().decode(FixtureJSON.self, from: Data(contentsOf: fixturesDir.appendingPathComponent("\(name).json")))
    let src = try loadF16Texture(device: device, path: fixturesDir.appendingPathComponent("\(name).hdr.f16"), width: j.width, height: j.height)
    let hud = try loadF16Texture(device: device, path: fixturesDir.appendingPathComponent("\(name).hud.f16"), width: j.width, height: j.height)
    let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: j.width, height: j.height, mipmapped: false)
    outDesc.usage = [.shaderWrite, .shaderRead]
    outDesc.storageMode = .shared
    guard let outTex = device.makeTexture(descriptor: outDesc) else { throw EncoderError.failed("could not allocate output texture") }

    try post.render(commandQueue: commandQueue, src: src, hud: hud, out: outTex, params: j.post, time: j.t, flipRows: true)

    var rgba = [UInt8](repeating: 0, count: j.width * j.height * 4)
    rgba.withUnsafeMutableBytes { buf in
      outTex.getBytes(buf.baseAddress!, bytesPerRow: j.width * 4, from: MTLRegionMake2D(0, 0, j.width, j.height), mipmapLevel: 0)
    }
    let outFile = outDir.appendingPathComponent("\(name).final.png")
    try writePNG(rgba: rgba, width: j.width, height: j.height, to: outFile)
    print("\(name): wrote \(outFile.path)")
  }
}
