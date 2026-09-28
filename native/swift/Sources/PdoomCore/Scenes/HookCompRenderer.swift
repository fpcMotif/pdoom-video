// Host side of hook_comp (native/shaders/scenes/hook.metal): composites a scene's Canvas2D layer over
// its background colour into the HDR target, with the maximal hook's radial echo and signal-orange glow.
import Metal
import Foundation

private struct HookCompParams { var bgR: Float, bgG: Float, bgB: Float, echo: Float, hot: Float, gain: Float }

public final class HookCompRenderer {
  private let device: MTLDevice
  private let pipeline: MTLComputePipelineState
  private var layerTexture: MTLTexture?

  public init(device: MTLDevice, library: MTLLibrary) throws {
    self.device = device
    guard let fn = library.makeFunction(name: "hook_comp") else { throw EncoderError.failed("hook_comp missing from shader library") }
    pipeline = try device.makeComputePipelineState(function: fn)
  }

  /// Uploads `layer`'s rasterized Canvas2D (straight alpha, row 0 = bottom) as an sRGB texture (so the
  /// shader's linear sampling decodes it, matching three.js's SRGBColorSpace CanvasTexture), then
  /// dispatches hook_comp into `out`.
  public func render(commandQueue: MTLCommandQueue, layer: Canvas2D, out: MTLTexture, bgR: Double, bgG: Double, bgB: Double, echo: Double, hot: Double, gain: Double) throws {
    let w = Int((layer.logicalW * Double(layer.scale)).rounded()), h = Int((layer.logicalH * Double(layer.scale)).rounded())
    if layerTexture == nil || layerTexture!.width != w || layerTexture!.height != h {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
      d.usage = [.shaderRead]
      d.storageMode = .shared
      layerTexture = device.makeTexture(descriptor: d)
    }
    guard let tex = layerTexture else { throw EncoderError.failed("could not allocate hook layer texture") }
    var rgba = layer.flippedRGBA()
    rgba.withUnsafeMutableBytes { buf in
      tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: w * 4)
    }

    guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
      throw EncoderError.failed("could not make Metal command buffer/encoder")
    }
    var params = HookCompParams(bgR: Float(bgR), bgG: Float(bgG), bgB: Float(bgB), echo: Float(echo), hot: Float(hot), gain: Float(gain))
    enc.setComputePipelineState(pipeline)
    enc.setTexture(tex, index: 0)
    enc.setTexture(out, index: 1)
    enc.setBytes(&params, length: MemoryLayout<HookCompParams>.stride, index: 0)
    let tw = pipeline.threadExecutionWidth
    let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
    enc.dispatchThreadgroups(MTLSize(width: (out.width + tw - 1) / tw, height: (out.height + th - 1) / th, depth: 1),
                              threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    if let err = cmd.error { throw EncoderError.failed("Metal command buffer failed: \(err)") }
  }
}
