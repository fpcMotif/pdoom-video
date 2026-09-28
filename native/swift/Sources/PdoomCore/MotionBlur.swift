// Host side of the motion-blur accumulation kernels in native/shaders/engine.metal, driving Engine's
// composite() over sub-frame times exactly as Engine.render's samples > 1 branch does (ternaryOffsets,
// the error estimate, the 4*3^k ladder, t clamped at 0). SS_TAP cycling is wired to -1 (no scene here
// supersamples internally yet), and POST_U's nearest-sub-frame post pick is implemented as engine.ts's is.
import Metal
import Foundation

public enum SamplesMode { case fixed(Int); case adaptive(AdaptiveSampling) }

private struct ScaleParams { var k: Float }
private struct ErrorParams { var invA: Float; var invB: Float }

final class MotionBlurAccumulator {
  private let addPipeline, mergePipeline, averagePipeline, errorPipeline, maxPipeline: MTLComputePipelineState
  let sumTex, newTex, avgTex, errTex: MTLTexture
  let maxBuf: MTLBuffer
  let errW: Int, errH: Int, maxW: Int, maxH: Int
  private let device: MTLDevice

  init(device: MTLDevice, library: MTLLibrary, pw: Int, ph: Int, scale: Int) throws {
    self.device = device
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
      guard let fn = library.makeFunction(name: name) else { throw EncoderError.failed("\(name) missing from shader library") }
      return try device.makeComputePipelineState(function: fn)
    }
    addPipeline = try pipeline("accum_add_sample")
    mergePipeline = try pipeline("accum_merge")
    averagePipeline = try pipeline("accum_average")
    errorPipeline = try pipeline("accum_error")
    maxPipeline = try pipeline("accum_max")

    func makeTex(_ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
      guard let t = device.makeTexture(descriptor: d) else { throw EncoderError.failed("could not allocate \(w)x\(h) motion-blur texture") }
      return t
    }
    sumTex = try makeTex(.rgba32Float, pw, ph)
    newTex = try makeTex(.rgba32Float, pw, ph)
    avgTex = try makeTex(.rgba16Float, pw, ph)
    let b = 2 * scale
    errW = (pw + b - 1) / b; errH = (ph + b - 1) / b
    errTex = try makeTex(.r32Float, errW, errH)
    maxW = (errW + 15) / 16; maxH = (errH + 15) / 16
    guard let buf = device.makeBuffer(length: maxW * maxH * MemoryLayout<Float>.stride, options: .storageModeShared) else {
      throw EncoderError.failed("could not allocate accum_max buffer")
    }
    maxBuf = buf
  }

  private func dispatch1(_ enc: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ w: Int, _ h: Int) {
    enc.setComputePipelineState(p)
    let tw = p.threadExecutionWidth, th = max(1, p.maxTotalThreadsPerThreadgroup / tw)
    enc.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
  }

  func clear(_ tex: MTLTexture, _ commandQueue: MTLCommandQueue) {
    let desc = MTLRenderPassDescriptor()
    desc.colorAttachments[0].texture = tex; desc.colorAttachments[0].loadAction = .clear
    desc.colorAttachments[0].storeAction = .store; desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: desc) else { return }
    enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
  }

  func addSample(_ src: MTLTexture, into sum: MTLTexture, _ commandQueue: MTLCommandQueue) throws {
    guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { throw EncoderError.failed("no command encoder") }
    enc.setComputePipelineState(addPipeline); enc.setTexture(src, index: 0); enc.setTexture(sum, index: 1)
    dispatch1(enc, addPipeline, sum.width, sum.height)
    enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
  }

  func merge(_ add: MTLTexture, into sum: MTLTexture, _ commandQueue: MTLCommandQueue) throws {
    guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { throw EncoderError.failed("no command encoder") }
    enc.setComputePipelineState(mergePipeline); enc.setTexture(add, index: 0); enc.setTexture(sum, index: 1)
    dispatch1(enc, mergePipeline, sum.width, sum.height)
    enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
  }

  func average(_ sum: MTLTexture, into avg: MTLTexture, k: Double, _ commandQueue: MTLCommandQueue) throws {
    guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { throw EncoderError.failed("no command encoder") }
    var p = ScaleParams(k: Float(k))
    enc.setComputePipelineState(averagePipeline); enc.setTexture(sum, index: 0); enc.setTexture(avg, index: 1)
    enc.setBytes(&p, length: MemoryLayout<ScaleParams>.stride, index: 0)
    dispatch1(enc, averagePipeline, avg.width, avg.height)
    enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
  }

  /// engine.ts's sampleError(n): how far the displayed average moves when newTex's 2n sub-frames merge
  /// with sumTex's n. Returns the max error (0..~255 levels).
  func sampleError(n: Int, _ commandQueue: MTLCommandQueue) throws -> Double {
    guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { throw EncoderError.failed("no command encoder") }
    var ep = ErrorParams(invA: Float(1.0 / Double(n)), invB: Float(1.0 / Double(2 * n)))
    enc.setComputePipelineState(errorPipeline); enc.setTexture(sumTex, index: 0); enc.setTexture(newTex, index: 1); enc.setTexture(errTex, index: 2)
    enc.setBytes(&ep, length: MemoryLayout<ErrorParams>.stride, index: 0)
    dispatch1(enc, errorPipeline, errW, errH)
    enc.setComputePipelineState(maxPipeline); enc.setTexture(errTex, index: 0); enc.setBuffer(maxBuf, offset: 0, index: 0)
    dispatch1(enc, maxPipeline, maxW, maxH)
    enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
    if let err = cmd.error { throw EncoderError.failed("Metal command buffer failed: \(err)") }
    let ptr = maxBuf.contents().bindMemory(to: Float.self, capacity: maxW * maxH)
    var m: Float = 0
    for i in 0..<(maxW * maxH) { m = max(m, ptr[i]) }
    return Double(m)
  }
}
