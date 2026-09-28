// HEVC output through AVAssetWriter, fed from an IOSurface-backed CVPixelBufferPool (BGRA) whose
// buffers are wrapped as Metal textures through CVMetalTextureCache. Uses the macOS 26
// AVAssetWriterInput.PixelBufferReceiver (AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:))
// rather than the deprecated AVAssetWriterInputPixelBufferAdaptor: its async `append` gives backpressure,
// and the pool it owns bounds in-flight frames (docs/NATIVE_METAL_PIPELINE.md, M1).
import AVFoundation
import CoreVideo
import CoreMedia
import Metal
import VideoToolbox
import Foundation

public enum EncoderError: Error, CustomStringConvertible {
  case failed(String)
  public var description: String { if case .failed(let s) = self { return s }; return "encoder error" }
}

/// Renders one frame (index `frame`, `w` x `h` physical px) into `texture` (bgra8Unorm, write access).
/// Called on the GPU-submission thread; the command buffer must be committed and complete before return.
public typealias FrameRenderer = (_ texture: MTLTexture, _ frame: Int, _ commandQueue: MTLCommandQueue) throws -> Void

@available(macOS 26.0, *)
public final class HEVCWriter {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let receiver: AVAssetWriterInput.PixelBufferReceiver
  private let pool: CVMutablePixelBuffer.Pool
  private var textureCache: CVMetalTextureCache!
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let width: Int
  private let height: Int
  private let fps: Int

  public init(out: URL, width: Int, height: Int, fps: Int, bitrate: Int, device: MTLDevice) throws {
    self.width = width; self.height = height; self.fps = fps
    self.device = device
    guard let q = device.makeCommandQueue() else { throw EncoderError.failed("could not make Metal command queue") }
    self.commandQueue = q
    if FileManager.default.fileExists(atPath: out.path) { try? FileManager.default.removeItem(at: out) }
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    writer = try AVAssetWriter(outputURL: out, fileType: .mp4)

    let hwSpec: [String: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoEncoderSpecificationKey: hwSpec,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
      ] as [String: Any],
    ]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
      throw EncoderError.failed("hardware HEVC encoder unavailable for \(width)x\(height) (canApply(outputSettings:forMediaType:) returned false)")
    }
    input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw EncoderError.failed("writer cannot add video input") }
    writer.add(input)

    var attrs = CVPixelBufferCreationAttributes(
      pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
      size: CVImageSize(width: width, height: height),
      compatibility: [.metalTexture]
    )
    attrs.backing = .ioSurfaceWithProperties([:])
    receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attrs)

    guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess else {
      throw EncoderError.failed("CVMetalTextureCacheCreate failed")
    }
    guard writer.startWriting() else {
      throw EncoderError.failed("AVAssetWriter.startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
    }
    writer.startSession(atSourceTime: .zero)
    guard let p = receiver.pixelBufferPool else { throw EncoderError.failed("receiver has no pixel buffer pool") }
    pool = p
  }

  /// Renders and appends frame `frame` (0-based); presentation time is frame / fps as an exact rational.
  public func writeFrame(_ frame: Int, render: FrameRenderer) async throws {
    let buffer = try pool.makeMutablePixelBuffer()
    try buffer.withUnsafeBuffer { legacyPB throws in
      var cvTexture: CVMetalTexture?
      let status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, textureCache, legacyPB, nil, .bgra8Unorm, width, height, 0, &cvTexture)
      guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
        throw EncoderError.failed("CVMetalTextureCacheCreateTextureFromImage failed (\(status))")
      }
      try render(texture, frame, commandQueue)
      withExtendedLifetime(cvTexture) {}
    }
    let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
    let readOnly = CVReadOnlyPixelBuffer(buffer)
    try await receiver.append(readOnly, with: pts)
  }

  public func finish() async throws {
    receiver.finish()
    input.markAsFinished()
    await writer.finishWriting()
    CVMetalTextureCacheFlush(textureCache, 0)
    if writer.status != .completed {
      throw EncoderError.failed("AVAssetWriter finished with status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "unknown")")
    }
  }

  /// Aborts the writer and removes any partial output file (a forced-failure path must leave nothing behind).
  public func cancel(out: URL) {
    writer.cancelWriting()
    try? FileManager.default.removeItem(at: out)
  }
}
