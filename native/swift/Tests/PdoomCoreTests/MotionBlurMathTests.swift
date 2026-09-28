// Checks ternaryOffsets against the TS engine's own output (native/verify's method: run the same numbers
// through both and diff), so the adaptive motion-blur schedule is provably identical before any scene
// exercises it end to end.
import Testing
import Foundation
@testable import PdoomCore

@Test func ternaryOffsetsMatchesTS() {
  // bun -e 'ternaryOffsets(0)' etc. (app/src/engine/engine.ts's own function, run standalone)
  let s0: [Double] = [-0.375, -0.125, 0.125, 0.375]
  #expect(ternaryOffsets(0).count == s0.count)
  for (a, b) in zip(ternaryOffsets(0), s0) { #expect(abs(a - b) <= 1e-12) }

  let s1: [Double] = [
    -0.375, -0.125, 0.125, 0.375,
    -0.4583333333333333, -0.29166666666666663, -0.20833333333333331, -0.041666666666666685,
    0.04166666666666663, 0.20833333333333337, 0.29166666666666663, 0.45833333333333337,
  ]
  #expect(ternaryOffsets(1).count == s1.count)
  for (a, b) in zip(ternaryOffsets(1), s1) { #expect(abs(a - b) <= 1e-12) }

  #expect(ternaryOffsets(2).count == 36) // bun: ternaryOffsets(2).length
  #expect(ternaryOffsets(3).count == 108) // bun: ternaryOffsets(3).length
}

@Test func adaptiveLadderMatchesEngine() {
  // engine.ts: lo = round(lg3(min)), hi = max(lo, floor(lg3(maxAdaptive) + 1e-9)), n = 4*3^lo
  let a = adaptiveLadder(AdaptiveSampling(min: 4, max: 324, tol: 3), maxAdaptive: 324)
  #expect(a.lo == 0); #expect(a.hi == 4); #expect(a.nStart == 4) // 4*3^4 = 324, the top of the ladder
  let b = adaptiveLadder(AdaptiveSampling(min: 4, max: 108, tol: 3), maxAdaptive: 108) // shoggoth's maxSamples
  #expect(b.hi == 3); #expect(4 * Int(pow(3.0, Double(b.hi))) == 108)
}
