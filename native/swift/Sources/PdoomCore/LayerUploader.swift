import Metal
import Foundation

public final class LayerUploader {
  private let device: MTLDevice
  private let pipeline: MTLComputePipelineState
  private var rawTex: MTLTexture?
  private var linearTex: MTLTexture?

  public init(device: MTLDevice, library: MTLLibrary) throws {
    self.device = device
    guard let fn = library.makeFunction(name: "layer_unpremultiply") else {
      throw EncoderError.failed("layer_unpremultiply missing from shader library")
    }
    pipeline = try device.makeComputePipelineState(function: fn)
  }

  public func upload(commandQueue: MTLCommandQueue, layer: Canvas2D) throws -> MTLTexture {
    guard let raw = layer.rawPremultipliedRGBA() else { throw EncoderError.failed("layer has no backing buffer") }
    return try upload(commandQueue: commandQueue, pointer: raw.pointer, bytesPerRow: raw.bytesPerRow, width: raw.width, height: raw.height)
  }

  public func upload(commandQueue: MTLCommandQueue, data: Data, bytesPerRow: Int, width: Int, height: Int) throws -> MTLTexture {
    try data.withUnsafeBytes { buf in
      try upload(commandQueue: commandQueue, pointer: buf.baseAddress!, bytesPerRow: bytesPerRow, width: width, height: height)
    }
  }

  public func upload(commandQueue: MTLCommandQueue, pointer: UnsafeRawPointer, bytesPerRow: Int, width w: Int, height h: Int) throws -> MTLTexture {
    if rawTex == nil || rawTex!.width != w || rawTex!.height != h {
      let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
      rd.usage = [.shaderRead]; rd.storageMode = .shared
      rawTex = device.makeTexture(descriptor: rd)
      let ld = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
      ld.usage = [.shaderRead, .shaderWrite]; ld.storageMode = .private
      linearTex = device.makeTexture(descriptor: ld)
    }
    guard let rawTex, let linearTex else { throw EncoderError.failed("could not allocate layer upload textures") }
    Profiler.shared.time("texture_upload") {
      rawTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pointer, bytesPerRow: bytesPerRow)
    }
    try Profiler.shared.time("gpu_unpremultiply") {
      guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
        throw EncoderError.failed("could not make Metal command buffer/encoder")
      }
      enc.setComputePipelineState(pipeline)
      enc.setTexture(rawTex, index: 0)
      enc.setTexture(linearTex, index: 1)
      let tw = pipeline.threadExecutionWidth
      let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
      enc.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
      enc.endEncoding()
      cmd.commit()
      cmd.waitUntilCompleted()
      if let err = cmd.error { throw EncoderError.failed("Metal command buffer failed: \(err)") }
    }
    return linearTex
  }
}
