// Host side of the post chain: bloom pyramid + final composite, dispatching native/shaders/post.metal's
// compute kernels in the sequence documented in that file's header comment. Port of app/src/engine/post.ts
// (Post.render). Parameter blocks are flat float structs in the shader struct's field order.
import Metal
import Foundation

private let MIPS = 7
private let LOGICAL_W = 1920
private let LOGICAL_H = 1080

private struct PrefilterParams { var texelX: Float; var texelY: Float; var threshold: Float; var knee: Float }
private struct DownParams { var texelX: Float; var texelY: Float }
private struct UpParams { var texelX: Float; var texelY: Float; var radius: Float }
private struct FinalParams {
  var exposure: Float
  var bloom: Float
  var halation: Float, ca: Float, grain: Float, vignette: Float, hud: Float, fade: Float, flash: Float
  var time: Float
  var zoom: Float, invert: Float
  var shakeX: Float, shakeY: Float
  var resX: Float, resY: Float
  var flipRows: Float
}

private func mipSizes() -> [(w: Int, h: Int)] {
  var w = LOGICAL_W >> 1, h = LOGICAL_H >> 1
  var sizes: [(Int, Int)] = []
  for _ in 0..<MIPS {
    sizes.append((max(2, w), max(2, h)))
    w >>= 1; h >>= 1
  }
  return sizes
}

public final class PostRenderer {
  private let device: MTLDevice
  private let prefilterPipeline, downPipeline, upPipeline, finalPipeline: MTLComputePipelineState
  private let mips: [MTLTexture]
  private let ups: [MTLTexture]

  public init(device: MTLDevice, library: MTLLibrary) throws {
    self.device = device
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
      guard let fn = library.makeFunction(name: name) else { throw EncoderError.failed("\(name) missing from shader library") }
      return try device.makeComputePipelineState(function: fn)
    }
    prefilterPipeline = try pipeline("post_prefilter")
    downPipeline = try pipeline("post_down")
    upPipeline = try pipeline("post_up")
    finalPipeline = try pipeline("post_final")

    func makeTex(_ w: Int, _ h: Int) throws -> MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]
      d.storageMode = .private
      guard let t = device.makeTexture(descriptor: d) else { throw EncoderError.failed("could not allocate \(w)x\(h) post texture") }
      return t
    }
    let sizes = mipSizes()
    mips = try sizes.map { try makeTex($0.w, $0.h) }
    ups = try sizes.map { try makeTex($0.w, $0.h) }
  }

  private func dispatch(_ enc: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, w: Int, h: Int) {
    enc.setComputePipelineState(pipeline)
    let tw = pipeline.threadExecutionWidth
    let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
    enc.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                              threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
  }

  /// Applies the chain: `src` (HDR linear, PW x PH, rgba16Float) -> `out` (PW x PH, sRGB 8-bit).
  /// `flipRows`: true writes row PH-1-y (top-down, for an encoder or a PNG); false keeps WebGL's order.
  public func render(commandQueue: MTLCommandQueue, src: MTLTexture, hud: MTLTexture, out: MTLTexture,
                      params: PostParams, time: Double, flipRows: Bool) throws {
    guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
      throw EncoderError.failed("could not make Metal command buffer/encoder")
    }

    var pre = PrefilterParams(texelX: 1 / Float(LOGICAL_W), texelY: 1 / Float(LOGICAL_H),
                               threshold: Float(params.bloomThreshold), knee: Float(params.bloomKnee))
    enc.setTexture(src, index: 0); enc.setTexture(mips[0], index: 1)
    enc.setBytes(&pre, length: MemoryLayout<PrefilterParams>.stride, index: 0)
    dispatch(enc, prefilterPipeline, w: mips[0].width, h: mips[0].height)

    for i in 1..<MIPS {
      var p = DownParams(texelX: 1 / Float(mips[i - 1].width), texelY: 1 / Float(mips[i - 1].height))
      enc.setTexture(mips[i - 1], index: 0); enc.setTexture(mips[i], index: 1)
      enc.setBytes(&p, length: MemoryLayout<DownParams>.stride, index: 0)
      dispatch(enc, downPipeline, w: mips[i].width, h: mips[i].height)
    }

    var prevTex = mips[MIPS - 1]
    for i in stride(from: MIPS - 2, through: 0, by: -1) {
      let small = i == MIPS - 2 ? mips[MIPS - 1] : ups[i + 1]
      var p = UpParams(texelX: 1 / Float(small.width), texelY: 1 / Float(small.height), radius: Float(0.5 + params.bloomRadius))
      enc.setTexture(prevTex, index: 0); enc.setTexture(mips[i], index: 1); enc.setTexture(ups[i], index: 2)
      enc.setBytes(&p, length: MemoryLayout<UpParams>.stride, index: 0)
      dispatch(enc, upPipeline, w: ups[i].width, h: ups[i].height)
      prevTex = ups[i]
    }

    var fp = FinalParams(
      exposure: Float(params.exposure), bloom: Float(params.bloom / 3),
      halation: Float(params.halation), ca: Float(params.ca), grain: Float(params.grain),
      vignette: Float(params.vignette), hud: Float(params.hud), fade: Float(params.fade), flash: Float(params.flash),
      time: Float(time), zoom: Float(params.zoom), invert: Float(params.invert),
      shakeX: Float(params.shake.first ?? 0), shakeY: Float(params.shake.count > 1 ? params.shake[1] : 0),
      resX: Float(LOGICAL_W), resY: Float(LOGICAL_H), flipRows: flipRows ? 1 : 0)
    enc.setTexture(src, index: 0); enc.setTexture(ups[0], index: 1); enc.setTexture(ups[3], index: 2)
    enc.setTexture(hud, index: 3); enc.setTexture(out, index: 4)
    enc.setBytes(&fp, length: MemoryLayout<FinalParams>.stride, index: 0)
    dispatch(enc, finalPipeline, w: out.width, h: out.height)

    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    if let err = cmd.error { throw EncoderError.failed("Metal command buffer failed: \(err)") }
  }
}
