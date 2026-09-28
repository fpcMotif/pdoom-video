// HEVC output through AVAssetWriter, fed from an IOSurface-backed CVPixelBufferPool (BGRA) whose
// buffers are wrapped as Metal textures through CVMetalTextureCache.
//
// Uses the deprecated AVAssetWriterInputPixelBufferAdaptor, not the macOS 26
// AVAssetWriterInput.PixelBufferReceiver the brief asks for: the async `append` on that new API
// reproducibly deadlocked partway through a real (non-trivial) render — a 90-frame hook1 clip stalled
// forever at the same frame (70) on every attempt, `sample`'d main thread idle in
// swift_task_asyncMainDrainQueue with nothing runnable, and both the videocompression and
// formatwriter.qtmovie threads idle in pthread_cond_wait waiting on a signal that never came. This held
// after unifying every GPU write for a frame onto the writer's own command queue (in case cross-queue
// synchronization was the cause), so it looks like a real limitation of that very new API (introduced
// this OS cycle) rather than a bug in how it was driven here. The M1 diagnostic path (frames of
// diag_pattern only, ~1 GPU dispatch each) never hit this in the runs recorded in this port's README;
// the difference is real scenes doing many GPU round-trips per frame, or simply more than ~70 frames.
// The adaptor's synchronous isReadyForMoreMediaData + append is the long-established, production-hardened
// pattern this replaces, and does not reproduce the hang.
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

public final class HEVCWriter {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
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

    let pbAttrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: pbAttrs)

    guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess else {
      throw EncoderError.failed("CVMetalTextureCacheCreate failed")
    }
    guard writer.startWriting() else {
      throw EncoderError.failed("AVAssetWriter.startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
    }
    writer.startSession(atSourceTime: .zero)
  }

  /// Renders and appends frame `frame` (0-based); presentation time is frame / fps as an exact rational.
  public func writeFrame(_ frame: Int, render: FrameRenderer) throws {
    while !input.isReadyForMoreMediaData {
      if writer.status != .writing { break } // fail fast below instead of spinning forever
      usleep(500)
    }
    guard let pool = adaptor.pixelBufferPool else { throw EncoderError.failed("adaptor has no pixel buffer pool") }
    var pb: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess, let pixelBuffer = pb else {
      throw EncoderError.failed("CVPixelBufferPoolCreatePixelBuffer failed")
    }
    var cvTexture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
    guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
      throw EncoderError.failed("CVMetalTextureCacheCreateTextureFromImage failed (\(status))")
    }
    try render(texture, frame, commandQueue)
    withExtendedLifetime(cvTexture) {}

    guard writer.status == .writing else {
      throw EncoderError.failed("AVAssetWriter not writing (status \(writer.status.rawValue)): \(writer.error?.localizedDescription ?? "unknown")")
    }
    let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
    guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
      throw EncoderError.failed("adaptor append failed for frame \(frame): \(writer.error?.localizedDescription ?? "unknown")")
    }
  }

  public func finish() async throws {
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
