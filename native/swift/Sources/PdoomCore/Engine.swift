// The engine: renders any song time as a pure function, compositing overlapping timeline entries.
// Port of app/src/engine/engine.ts's Engine.composite (and the samples==1 path of Engine.render; fixed/
// adaptive motion blur is not wired in yet, see native/swift/README.md).
import Metal
import Foundation

/// Maps a timeline entry's `sceneFile` to a constructor. Entries whose file isn't registered render as
/// engine.ts's fallback does when a scene fails to load: a dim red clear, not a crash.
public typealias SceneFactory = (SceneCtx) throws -> Scene
public let sceneRegistry: [String: SceneFactory] = [
  "hook": { try HookScene(ctx: $0) },
]

public final class Engine {
  public let audio: AudioData
  public let lyrics: Lyrics
  public let registry: FontRegistry
  public let device: MTLDevice
  public let library: MTLLibrary
  public let scale: Int
  public let timeline: [TimelineEntry]
  public let hud: Hud
  private var loaded: [String: Scene] = [:]
  private var unloadable: Set<String> = [] // scene file not registered (engine.ts's failed-load fallback)
  private let commandQueue: MTLCommandQueue
  private let post: PostRenderer
  private var rts: [MTLTexture] = []
  private var mixRT: MTLTexture!
  private var xfade: XfadeRenderer

  public init(root: URL, scale: Int, only: Set<String>?) throws {
    self.scale = scale
    audio = try AudioData(path: root.appendingPathComponent("data/audio.json").path)
    lyrics = try Lyrics(path: root.appendingPathComponent("data/lyrics.json").path)
    registry = try FontRegistry(fontsDir: root.appendingPathComponent("app/public/fonts"))
    guard let d = MTLCreateSystemDefaultDevice() else { throw EncoderError.failed("no Metal device") }
    device = d
    guard let q = d.makeCommandQueue() else { throw EncoderError.failed("no Metal command queue") }
    commandQueue = q
    library = try makeShaderLibrary(device: d, shaderDir: root.appendingPathComponent("native/shaders"), scale: scale)
    var tl = makeTimeline(lyrics, audio)
    if let only { tl = tl.filter { only.contains($0.id) } }
    timeline = tl
    post = try PostRenderer(device: d, library: library)
    xfade = try XfadeRenderer(device: d, library: library)
    let pdoom = PDoom(lyrics)
    hud = try Hud(pdoom: pdoom, captions: [], scale: scale, registry: registry) // no timeline entry sets `caption:` today

    let pw = 1920 * scale, ph = 1080 * scale
    func makeHDR() throws -> MTLTexture {
      let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: pw, height: ph, mipmapped: false)
      desc.usage = [.shaderRead, .shaderWrite]
      desc.storageMode = .private
      guard let t = d.makeTexture(descriptor: desc) else { throw EncoderError.failed("could not allocate \(pw)x\(ph) HDR texture") }
      return t
    }
    for _ in 0..<3 { rts.append(try makeHDR()) }
    mixRT = try makeHDR()
  }

  private func sceneFor(_ e: TimelineEntry) throws -> Scene? {
    if let cached = loaded[e.id] { return cached }
    if unloadable.contains(e.id) { return nil }
    guard let factory = sceneRegistry[e.sceneFile] else { unloadable.insert(e.id); return nil }
    let ctx = SceneCtx(audio: audio, lyrics: lyrics, registry: registry, device: device, library: library, scale: scale,
                        id: e.id, params: e.params, start: e.start, end: e.end)
    let scene = try factory(ctx)
    loaded[e.id] = scene
    return scene
  }

  private func frameFor(_ e: TimelineEntry, _ t: Double, _ dt: Double, _ seeked: Bool, _ tin: Double, _ tout: Double) -> Frame {
    let beat = audio.beatAt(t), bar = audio.barAt(t)
    return Frame(t: t, dt: dt, lt: t - e.start, p: (t - e.start) / (e.end - e.start), start: e.start, end: e.end,
                 seeked: seeked, preroll: false, beat: beat, bar: bar, beatPhase: beat - floor(beat), barPhase: bar - floor(bar),
                 a: audio.sample(t), tin: tin, tout: tout)
  }

  /// Render and composite all scenes active at t into an HDR texture (no post). Port of Engine.composite.
  public func composite(_ t: Double, _ dt: Double, _ seeked: Bool, commandQueue: MTLCommandQueue) throws -> (out: MTLTexture, post: PostParams) {
    let active = timeline.filter { t >= $0.start && t < $0.end }.sorted { $0.start < $1.start }
    var post = PostParams()
    var under: MTLTexture?
    var outTex: MTLTexture?

    for (idx, e) in active.enumerated() {
      let rt = rts[idx % rts.count]
      let prev = idx > 0 ? active[idx - 1] : nil
      let next = idx + 1 < active.count ? active[idx + 1] : nil
      let tin = prev != nil ? min(1, (t - e.start) / max(1e-3, prev!.end - e.start)) : 1
      let tout = next != nil ? max(0, (t - next!.start) / max(1e-3, e.end - next!.start)) : 0
      guard let scene = try sceneFor(e) else {
        clearRed(rt, commandQueue)
        under = rt; outTex = rt
        continue
      }
      let ov = try scene.render(frameFor(e, t, dt, seeked, tin, tout), into: rt, commandQueue: commandQueue)
      post = post.applying(ov)
      if idx > 0, !scene.handlesTransition, let under {
        try xfade.render(commandQueue: commandQueue, a: under, b: rt, out: mixRT, k: tin)
        outTex = mixRT
      } else {
        outTex = rt
      }
      under = outTex
    }
    if outTex == nil {
      clearRed(rts[0], commandQueue) // (engine.ts clears to black when nothing is active; red marks a load failure)
      outTex = rts[0]
    }
    return (outTex!, post)
  }

  /// engine.ts's fallback when a scene isn't loaded: a dim red clear (a visible "this scene is missing"
  /// marker), via a render-pass clear (Metal has no direct clear-texture-to-a-colour call).
  private func clearRed(_ tex: MTLTexture, _ commandQueue: MTLCommandQueue) {
    let desc = MTLRenderPassDescriptor()
    desc.colorAttachments[0].texture = tex
    desc.colorAttachments[0].loadAction = .clear
    desc.colorAttachments[0].storeAction = .store
    desc.colorAttachments[0].clearColor = MTLClearColor(red: 0.25, green: 0, blue: 0, alpha: 1)
    guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: desc) else { return }
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
  }

  private lazy var blur: MotionBlurAccumulator? = try? MotionBlurAccumulator(device: device, library: library, pw: 1920 * scale, ph: 1080 * scale, scale: scale)
  public private(set) var lastSamples = 1
  public private(set) var lastErrors: [Double] = []

  /// Renders song time t (1 sub-frame, or `samples` of them averaged over `shutter` x dt: fixed or
  /// adaptive motion blur, engine.ts's Engine.render), then the post chain. Returns the sub-frame count
  /// used (matches Engine.render's return value).
  @discardableResult
  public func render(_ t: Double, dt: Double = 1.0 / 60, samples: SamplesMode = .fixed(1), shutter: Double = 0.5,
                     into out: MTLTexture, commandQueue externalQueue: MTLCommandQueue? = nil) throws -> Int {
    // An encoder that hands us a pixel buffer (HEVCWriter) may need every GPU write to that buffer's
    // frame to go through *its own* command queue for its readiness/backpressure tracking to see them;
    // using the engine's own separate queue instead reproduced a hang partway through a real (non-trivial)
    // render (found by testing: a 90-frame HEVC clip stalled forever around frame 70, main thread idle
    // with nothing runnable, the encoder and file-writer threads both idle waiting on a condition that
    // never signalled — `sample` while it hung showed no other work in flight). `video`'s HEVC path now
    // passes its writer's queue in here; `stills`/`post-fixture`/the x264 path (which reads the texture
    // back on the CPU instead) keep using the engine's own queue.
    let q = externalQueue ?? commandQueue
    var post = PostParams()
    let outHDR: MTLTexture
    var n = 1
    if case .fixed(1) = samples {
      let (hdr, p) = try composite(t, dt, true, commandQueue: q)
      outHDR = hdr; post = p
    } else {
      guard let blur else { throw EncoderError.failed("motion-blur accumulator unavailable") }
      let POST_U = 0.125
      var nearest = Double.infinity
      func sub(_ k: Int, _ u: Double, _ into: MTLTexture, _ step: Double) throws {
        let (hdr, p) = try composite(max(0, t + dt * shutter * u), step, k == 0, commandQueue: q)
        try blur.addSample(hdr, into: into, q)
        let d = abs(u - POST_U)
        if d < nearest - 1e-9 || (d < nearest + 1e-9 && u > POST_U) { nearest = d; post = p }
      }
      blur.clear(blur.sumTex, q)
      lastErrors = []
      switch samples {
      case .fixed(let s):
        n = s
        for k in 0..<n { try sub(k, (Double(k) + 0.5) / Double(n) - 0.5, blur.sumTex, dt / Double(n)) }
      case .adaptive(let a):
        let ladder = adaptiveLadder(a, maxAdaptive: a.max)
        let u = ternaryOffsets(ladder.hi)
        n = ladder.nStart
        for k in 0..<n { try sub(k, u[k], blur.sumTex, dt / Double(n)) }
        for _ in ladder.lo..<ladder.hi {
          blur.clear(blur.newTex, q)
          for k in n..<(3 * n) { try sub(k, u[k], blur.newTex, dt / Double(3 * n)) }
          let err = try blur.sampleError(n: n, q) / 2
          lastErrors.append(err)
          try blur.merge(blur.newTex, into: blur.sumTex, q)
          n *= 3
          if err < a.tol { break }
        }
      }
      try blur.average(blur.sumTex, into: blur.avgTex, k: 1.0 / Double(n), q)
      outHDR = blur.avgTex
    }
    lastSamples = n
    try hud.draw(t, HudState(opacity: post.hud, frame: post.frame, readout: post.pdoom, paper: post.paper, pdoomOverride: post.pdoomText, corruption: post.hudCorruption))
    let hudTex = try uploadHud()
    try self.post.render(commandQueue: q, src: outHDR, hud: hudTex, out: out, params: post, time: t, flipRows: true)
    return n
  }

  private var hudTexture: MTLTexture?
  private func uploadHud() throws -> MTLTexture {
    let w = Int((hud.layer.logicalW * Double(hud.layer.scale)).rounded()), h = Int((hud.layer.logicalH * Double(hud.layer.scale)).rounded())
    if hudTexture == nil || hudTexture!.width != w || hudTexture!.height != h {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
      d.usage = [.shaderRead]; d.storageMode = .shared
      hudTexture = device.makeTexture(descriptor: d)
    }
    guard let tex = hudTexture else { throw EncoderError.failed("could not allocate HUD texture") }
    var rgba = hud.layer.flippedRGBA()
    rgba.withUnsafeMutableBytes { buf in
      tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: w * 4)
    }
    return tex
  }
}

/// Host side of engine.metal's comp_xfade: mix(a, b, k).
final class XfadeRenderer {
  private struct XfadeParams { var k: Float }
  private let pipeline: MTLComputePipelineState
  init(device: MTLDevice, library: MTLLibrary) throws {
    guard let fn = library.makeFunction(name: "comp_xfade") else { throw EncoderError.failed("comp_xfade missing from shader library") }
    pipeline = try device.makeComputePipelineState(function: fn)
  }
  func render(commandQueue: MTLCommandQueue, a: MTLTexture, b: MTLTexture, out: MTLTexture, k: Double) throws {
    guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
      throw EncoderError.failed("could not make Metal command buffer/encoder")
    }
    var p = XfadeParams(k: Float(k))
    enc.setComputePipelineState(pipeline)
    enc.setTexture(a, index: 0); enc.setTexture(b, index: 1); enc.setTexture(out, index: 2)
    enc.setBytes(&p, length: MemoryLayout<XfadeParams>.stride, index: 0)
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
