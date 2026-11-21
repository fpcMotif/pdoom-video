// Post-processing parameters, ported from app/src/engine/post.ts's PostParams / DEFAULT_POST.
import Foundation

public struct PostParams: Codable, Sendable {
  public var exposure = 1.0
  public var bloom = 0.55
  public var bloomThreshold = 0.85
  public var bloomKnee = 0.5
  public var bloomRadius = 0.75
  public var halation = 0.25
  public var ca = 1.2
  public var grain = 0.055
  public var vignette = 0.35
  public var hud = 1.0
  public var frame = 0.0
  public var pdoom = 0.0
  public var paper = 0.0
  public var fade = 0.0
  public var flash = 0.0
  public var shake: [Double] = [0, 0]
  public var zoom = 1.0
  public var invert = 0.0
  public var pdoomText: String?
  public var hudCorruption: Double?

  public init() {}
}
