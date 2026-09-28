// Dispatches native/shaders/diagnostic.metal's diag_pattern kernel: a synthetic frame used to check the
// output path end to end (docs/NATIVE_METAL_PIPELINE.md, "Diagnostic pattern"). Row 0 = top; no flip.
import Metal

struct DiagParams { var frame: Float }

final class DiagnosticRenderer {
  private let pipeline: MTLComputePipelineState

  init(device: MTLDevice, library: MTLLibrary) throws {
    guard let fn = library.makeFunction(name: "diag_pattern") else {
      throw EncoderError.failed("diag_pattern function missing from shader library")
    }
    pipeline = try device.makeComputePipelineState(function: fn)
  }

  /// Encodes and commits a compute pass writing the diagnostic pattern for `frame` into `texture`, then
  /// blocks until the GPU finishes (M1's simple, verifiably-correct baseline; M4 pipelines this).
  func render(into texture: MTLTexture, frame: Int, commandQueue: MTLCommandQueue) throws {
    guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
      throw EncoderError.failed("could not make Metal command buffer/encoder")
    }
    var params = DiagParams(frame: Float(frame))
    enc.setComputePipelineState(pipeline)
    enc.setTexture(texture, index: 0)
    enc.setBytes(&params, length: MemoryLayout<DiagParams>.stride, index: 0)
    let tw = pipeline.threadExecutionWidth
    let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
    let tg = MTLSize(width: tw, height: th, depth: 1)
    let grid = MTLSize(width: (texture.width + tw - 1) / tw, height: (texture.height + th - 1) / th, depth: 1)
    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    if let err = cmd.error { throw EncoderError.failed("Metal command buffer failed: \(err)") }
  }
}
