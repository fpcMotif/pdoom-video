// Scene API, port of app/src/engine/scene.ts. A scene renders HDR linear colour for a song time, as a
// pure function of Frame (M4 note: Hook's own 2D layer + uniform prep is exactly this pure-function
// shape already — see PdoomCore/Scenes/Hook.swift's header).
import Metal
import Foundation

public struct Frame: Sendable {
  public var t: Double
  public var dt: Double
  public var lt: Double
  public var p: Double
  public var start: Double
  public var end: Double
  public var seeked: Bool
  public var preroll: Bool
  public var beat: Double
  public var bar: Double
  public var beatPhase: Double
  public var barPhase: Double
  public var a: AudioSample
  public var tin: Double
  public var tout: Double
}

/// Partial<PostParams> (scene.ts's PostOverrides): only the fields a scene actually sets are non-nil.
public struct PostOverrides: Sendable {
  public var exposure, bloom, bloomThreshold, bloomKnee, bloomRadius, halation, ca, grain, vignette, hud: Double?
  public var frame, pdoom, paper, fade, flash: Double?
  public var shake: [Double]?
  public var zoom, invert: Double?
  public var pdoomText: String?
  public var hudCorruption: Double?
  public init() {}
}

public extension PostParams {
  /// `{ ...post, ...overrides }` (engine.ts composite()).
  func applying(_ o: PostOverrides) -> PostParams {
    var p = self
    if let v = o.exposure { p.exposure = v }
    if let v = o.bloom { p.bloom = v }
    if let v = o.bloomThreshold { p.bloomThreshold = v }
    if let v = o.bloomKnee { p.bloomKnee = v }
    if let v = o.bloomRadius { p.bloomRadius = v }
    if let v = o.halation { p.halation = v }
    if let v = o.ca { p.ca = v }
    if let v = o.grain { p.grain = v }
    if let v = o.vignette { p.vignette = v }
    if let v = o.hud { p.hud = v }
    if let v = o.frame { p.frame = v }
    if let v = o.pdoom { p.pdoom = v }
    if let v = o.paper { p.paper = v }
    if let v = o.fade { p.fade = v }
    if let v = o.flash { p.flash = v }
    if let v = o.shake { p.shake = v }
    if let v = o.zoom { p.zoom = v }
    if let v = o.invert { p.invert = v }
    if let v = o.pdoomText { p.pdoomText = v }
    if let v = o.hudCorruption { p.hudCorruption = v }
    return p
  }
}

public struct SceneCtx {
  public var audio: AudioData
  public var lyrics: Lyrics
  public var registry: FontRegistry
  public var device: MTLDevice
  public var library: MTLLibrary
  public var scale: Int
  public var id: String
  public var params: TimelineParams
  public var start: Double
  public var end: Double
  public init(audio: AudioData, lyrics: Lyrics, registry: FontRegistry, device: MTLDevice, library: MTLLibrary, scale: Int, id: String, params: TimelineParams, start: Double, end: Double) {
    self.audio = audio; self.lyrics = lyrics; self.registry = registry; self.device = device; self.library = library
    self.scale = scale; self.id = id; self.params = params; self.start = start; self.end = end
  }
}

/// Scene.ts's abstract Scene class trimmed to what the ported scenes need: init once, render per Frame.
public protocol Scene: AnyObject {
  init(ctx: SceneCtx) throws
  /// True if this scene composites `under` itself during its incoming transition (scene.ts `handlesTransition`).
  var handlesTransition: Bool { get }
  /// Renders `f` into `out` (rgba16Float, linear HDR, PW x PH); returns post-processing overrides.
  func render(_ f: Frame, into out: MTLTexture, commandQueue: MTLCommandQueue) throws -> PostOverrides
}

public extension Scene {
  var handlesTransition: Bool { false }
}
