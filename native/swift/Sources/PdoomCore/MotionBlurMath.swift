// The pure scheduling math behind Engine.render's adaptive motion blur (app/src/engine/engine.ts):
// sub-frame shutter offsets and the 4*3^k sample-count ladder. No GPU/scene dependency, so it is tested
// directly against the TS function's own output (see PdoomCoreTests/MotionBlurMathTests.swift).
import Foundation

public struct AdaptiveSampling: Sendable { public var min: Int; public var max: Int; public var tol: Double
  public init(min: Int, max: Int, tol: Double) { self.min = min; self.max = max; self.tol = tol }
}

/// Shutter offsets (-0.5..0.5) of an adaptive run's sub-frames in rendering order (engine.ts ternaryOffsets):
/// 4 evenly spread, then each step splits every interval in three, adding a sub-frame either side of each
/// old one.
public func ternaryOffsets(_ steps: Int) -> [Double] {
  var u = (0..<4).map { (Double($0) + 0.5) / 4 - 0.5 }
  var n = 4
  for _ in 0..<steps {
    for m in 0..<n {
      u.append((3 * Double(m) + 0.5) / (3 * Double(n)) - 0.5)
      u.append((3 * Double(m) + 2.5) / (3 * Double(n)) - 0.5)
    }
    n *= 3
  }
  return u
}

/// The (lo, hi) exponents of the 4*3^k ladder an AdaptiveSampling run starts and may extend to
/// (engine.ts Engine.render's `lo`/`hi`/`n` setup, before the per-step error check that may stop early).
public func adaptiveLadder(_ s: AdaptiveSampling, maxAdaptive: Int) -> (lo: Int, hi: Int, nStart: Int) {
  func lg3(_ x: Double) -> Double { log(x / 4) / log(3) }
  let lo = max(0, Int((lg3(Double(s.min))).rounded()))
  let hi = max(lo, Int(floor(lg3(Double(maxAdaptive)) + 1e-9)))
  return (lo, hi, 4 * Int(pow(3.0, Double(lo))))
}
