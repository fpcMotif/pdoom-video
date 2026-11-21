// Host side of hook_comp (native/shaders/scenes/hook.metal): composites a scene's Canvas2D layer over
// its background colour into the HDR target, with the maximal hook's radial echo and signal-orange glow.
import Metal
import Foundation

private struct HookCompParams { var bgR: Float, bgG: Float, bgB: Float, echo: Float, hot: Float, gain: Float }

public final class HookCompRenderer {
  private let device: MTLDevice
  private let pipeline: MTLComputePipelineState
  private let uploader: LayerUploader

  public init(device: MTLDevice, library: MTLLibrary) throws {
    self.device = device
    guard let fn = library.makeFunction(name: "hook_comp") else { throw EncoderError.failed("hook_comp missing from shader library") }
    pipeline = try device.makeComputePipelineState(function: fn)
    uploader = try LayerUploader(device: device, library: library)
  }

  public func render(commandQueue: MTLCommandQueue, layer: Canvas2D, out: MTLTexture, bgR: Double, bgG: Double, bgB: Double, echo: Double, hot: Double, gain: Double) throws {
    let tex = try uploader.upload(commandQueue: commandQueue, layer: layer)
    try dispatch(commandQueue: commandQueue, tex: tex, out: out, bgR: bgR, bgG: bgG, bgB: bgB, echo: echo, hot: hot, gain: gain)
  }

  public func render(commandQueue: MTLCommandQueue, prep: HookScene.Prep, out: MTLTexture) throws {
    let tex = try uploader.upload(commandQueue: commandQueue, data: prep.raw.pointer, bytesPerRow: prep.raw.bytesPerRow, width: prep.raw.width, height: prep.raw.height)
    try dispatch(commandQueue: commandQueue, tex: tex, out: out, bgR: prep.bgR, bgG: prep.bgG, bgB: prep.bgB, echo: prep.echo, hot: prep.hot, gain: prep.gain)
  }

  private func dispatch(commandQueue: MTLCommandQueue, tex: MTLTexture, out: MTLTexture, bgR: Double, bgG: Double, bgB: Double, echo: Double, hot: Double, gain: Double) throws {
    try Profiler.shared.time("gpu_hook_comp") {
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
      GPUErrorTracker.shared.commitTracked(cmd)
    }
  }
}
