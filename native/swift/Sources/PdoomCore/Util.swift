// Small math/animation helpers shared by every scene. Port of app/src/engine/util.ts.
import Foundation

public let TAU = Double.pi * 2

public func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { x < a ? a : x > b ? b : x }
public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
public func invLerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a == b ? 0 : (x - a) / (b - a) }
public func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
  let t = clamp((x - a) / (b - a)); return t * t * (3 - 2 * t)
}

public enum ease {
  public static func linear(_ t: Double) -> Double { t }
  public static func inQuad(_ t: Double) -> Double { t * t }
  public static func outQuad(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }
  public static func inOutQuad(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
  public static func inCubic(_ t: Double) -> Double { t * t * t }
  public static func outCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
  public static func inOutCubic(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
  public static func inQuart(_ t: Double) -> Double { t * t * t * t }
  public static func outQuart(_ t: Double) -> Double { 1 - pow(1 - t, 4) }
  public static func inOutQuart(_ t: Double) -> Double { t < 0.5 ? 8 * t * t * t * t : 1 - pow(-2 * t + 2, 4) / 2 }
  public static func outQuint(_ t: Double) -> Double { 1 - pow(1 - t, 5) }
  public static func inExpo(_ t: Double) -> Double { t <= 0 ? 0 : pow(2, 10 * t - 10) }
  public static func outExpo(_ t: Double) -> Double { t >= 1 ? 1 : 1 - pow(2, -10 * t) }
  public static func inOutExpo(_ t: Double) -> Double {
    t <= 0 ? 0 : t >= 1 ? 1 : t < 0.5 ? pow(2, 20 * t - 10) / 2 : (2 - pow(2, -20 * t + 10)) / 2
  }
  public static func outBack(_ t: Double, _ s: Double = 1.70158) -> Double { 1 + (s + 1) * pow(t - 1, 3) + s * pow(t - 1, 2) }
  public static func inBack(_ t: Double, _ s: Double = 1.70158) -> Double { (s + 1) * t * t * t - s * t * t }
  public static func outElastic(_ t: Double) -> Double {
    t <= 0 ? 0 : t >= 1 ? 1 : pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * Double.pi / 3)) + 1
  }
}

/// Clamped eased progress of x through [a, b].
public func prog(_ x: Double, _ a: Double, _ b: Double, _ fn: (Double) -> Double = ease.linear) -> Double {
  fn(clamp((x - a) / (b - a)))
}

/// Exponential decay pulse after an event at time t0 (1 at t0, fades with half-life hl).
public func pulse(_ t: Double, _ t0: Double, _ hl: Double = 0.12) -> Double { t < t0 ? 0 : pow(0.5, (t - t0) / hl) }

/// Index of the 60 fps output frame nearest t, for per-frame jitter/flicker.
public func frameIdx(_ t: Double) -> Double { (t * 60).rounded() }

/// Stateless hash of doubles to [0,1) (util.ts `hash`).
public func hash(_ xs: Double...) -> Double {
  var h: UInt32 = 2166136261
  for x in xs {
    // JS: h ^= Math.floor(x * 1000003) | 0 (ToInt32: the floored double mod 2^32, sign-extended)
    let floored = (x * 1000003).rounded(.down)
    h ^= UInt32(bitPattern: Int32(truncatingIfNeeded: Int64(floored)))
    h = h &* 16777619
    h ^= h >> 13
    h = h &* 0x5bd1e995
    h ^= h >> 15
  }
  return Double(h) / 4294967296
}

private func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
public func noise1(_ x: Double, _ seed: Double = 0) -> Double {
  let i = x.rounded(.down)
  let f = x - i
  return lerp(hash(i, seed) * 2 - 1, hash(i + 1, seed) * 2 - 1, fade(f))
}
