// Global overlay: crop-mark frame, corner P(doom) readout, plate captions. Port of app/src/engine/hud.ts.
import Foundation

public struct Caption: Sendable { public var start: Double; public var end: Double; public var fig: String; public var text: String
  public init(start: Double, end: Double, fig: String, text: String) { self.start = start; self.end = end; self.fig = fig; self.text = text }
}

/// P(doom) steps: each sung "P(doom)" raises the estimate. Port of hud.ts's PDoom.
public final class PDoom {
  public struct Step { public var t: Double; public var v: Double }
  public var steps: [Step] = []
  public init(_ lyrics: Lyrics) {
    let hits = lyrics.findWords("P(doom)").map { $0.start + 0.06 }
    let vals = [0.15, 0.42, 0.81, 0.99]
    steps = [Step(t: -1, v: 0.02)] + hits.enumerated().map { i, t in Step(t: t, v: i < vals.count ? vals[i] : 0.99) }
  }
  /// Value at t with the roll animation of each step (~0.9 s) and slow drift between steps.
  public func value(_ t: Double) -> Double {
    var i = 0
    while i + 1 < steps.count && steps[i + 1].t <= t { i += 1 }
    let cur = steps[i], prev = steps[max(0, i - 1)]
    let k = i == 0 ? 1 : prog(t, cur.t, cur.t + 0.9, ease.outExpo)
    let base = prev.v + (cur.v - prev.v) * k
    let next: Step? = i + 1 < steps.count ? steps[i + 1] : nil
    let creep = next.map { ($0.v - cur.v) * 0.2 * smoothstep(cur.t + 1, $0.t, t) } ?? 0
    let jitter = noise1(t * 3.1, 7) * 0.004 * (1 - k * 0.5)
    return clamp(base + creep + jitter, 0, 1)
  }
  /// 0..1 flash envelope right after a step.
  public func flash(_ t: Double) -> Double {
    var f = 0.0
    for s in steps where t >= s.t && s.t > 0 { f = max(f, pow(0.5, (t - s.t) / 0.35)) }
    return f
  }
  public func lastStep(_ t: Double) -> Step {
    var s = steps[0]
    for x in steps where x.t <= t { s = x }
    return s
  }
}

/// Canonical text format of a P(doom) value ('0.15', '0.991').
public func formatPDoom(_ v: Double) -> String { String(format: v >= 0.99 ? "%.3f" : "%.2f", v) }

public struct HudState: Sendable {
  public var opacity: Double
  public var frame: Double
  public var readout: Double
  public var paper: Double
  public var pdoomOverride: String?
  public var corruption: Double?
  public init(opacity: Double, frame: Double, readout: Double, paper: Double, pdoomOverride: String? = nil, corruption: Double? = nil) {
    self.opacity = opacity; self.frame = frame; self.readout = readout; self.paper = paper
    self.pdoomOverride = pdoomOverride; self.corruption = corruption
  }
}

public final class Hud {
  public let layer: Canvas2D
  public let pdoom: PDoom
  public let captions: [Caption]
  private var ink = false

  public init(pdoom: PDoom, captions: [Caption], scale: Int, registry: FontRegistry) throws {
    self.pdoom = pdoom; self.captions = captions
    layer = try Canvas2D(logicalW: 1920, logicalH: 1080, scale: scale, registry: registry)
  }

  public func draw(_ t: Double, _ st: HudState) throws {
    layer.clear()
    if st.opacity <= 0.001 { return }
    layer.globalAlpha = st.opacity
    ink = st.paper > 0.5
    if st.frame > 0.001 { cropMarks(st.frame) }
    if st.readout > 0.001 {
      layer.save(); layer.globalAlpha *= st.readout
      try readout(t, st)
      layer.restore()
    }
    try caption(t)
  }

  private func cropMarks(_ k: Double) {
    let c = layer
    let e = ease.inOutCubic(clamp(k)) // computed for parity; the port doesn't need its value directly
    _ = e
    c.save()
    c.globalAlpha *= clamp(k * 3)
    c.strokeStyle = ink ? rgba(.ink, 0.45) : rgba(.bone, 0.34)
    c.lineWidth = 1.25
    let m = lerp(-40, 36, ease.inOutCubic(clamp(k))), l = 22.0
    c.beginPath()
    for (x, y, sx, sy) in [(m, m, 1.0, 1.0), (1920 - m, m, -1.0, 1.0), (m, 1080 - m, 1.0, -1.0), (1920 - m, 1080 - m, -1.0, -1.0)] {
      c.moveTo(x + sx * l, y + 0.5 * sy); c.lineTo(x, y + 0.5 * sy); c.lineTo(x, y + sy * l)
    }
    c.stroke()
    c.restore()
  }

  private func readout(_ t: Double, _ st: HudState) throws {
    let c = layer
    let v = pdoom.value(t)
    let fl = pdoom.flash(t)
    let x = 64.0, y = 1080.0 - 66
    c.save()
    c.setFont(F.mono(500), 13)
    c.letterSpacing = 3
    c.fillStyle = rgba(.bone, 0.6)
    try c.fillText("P(DOOM)", x, y - 44)
    c.letterSpacing = 0
    var s = st.pdoomOverride ?? formatPDoom(v)
    if let corr = st.corruption, corr > 0 {
      let glyphs = Array("01#%?!\u{d8}\u{221e}")
      s = String(Array(s).enumerated().map { i, ch -> Character in
        hash(Double(i), Double(Int(t * 20))) < corr * 0.7 ? glyphs[Int(hash(Double(i), t) * Double(glyphs.count))] : ch
      })
    }
    c.setFont(F.mono(400), 40)
    c.fillStyle = fl > 0.02 ? mix(.bone, .signal, min(1, fl * 1.5)) : rgba(.bone, 0.92)
    try c.fillText(s, x - 2, y)
    let bw = 220.0, by = y + 16
    c.fillStyle = rgba(.bone, 0.18)
    c.fillRect(x, by, bw, 1)
    for i in 0...10 { c.fillRect(x + bw * Double(i) / 10, by - Double(i % 5 == 0 ? 5 : 3), 1, Double(i % 5 == 0 ? 5 : 3)) }
    c.fillStyle = rgba(.signal, 1)
    c.fillRect(x, by - 1, bw * clamp(v), 3)
    c.restore()
  }

  private func caption(_ t: Double) throws {
    guard let cap = captions.first(where: { t >= $0.start && t < $0.end }) else { return }
    let a = min(smoothstep(cap.start, cap.start + 0.5, t), 1 - smoothstep(cap.end - 0.6, cap.end, t))
    guard a > 0 else { return }
    let c = layer
    c.save()
    c.globalAlpha *= a
    let x = 1920.0 - 64, y = 1080.0 - 66
    c.textAlign = .right
    c.setFont(F.serif(400, true), 26)
    c.fillStyle = ink ? rgba(.ink, 0.9) : rgba(.bone, 0.85)
    let n = Int(Double(cap.text.count) * prog(t, cap.start, cap.start + 0.8))
    let shown = String(cap.text.prefix(n))
    let full = try c.measureText(cap.text)
    c.textAlign = .left
    try c.fillText(shown, x - full, y)
    c.setFont(F.mono(500), 13)
    c.letterSpacing = 3
    c.fillStyle = ink ? rgba(.blood, 1) : rgba(.signal, 1)
    try c.fillText(cap.fig, x - full, y - 34)
    c.restore()
  }
}

private func mix(_ a: PaletteKey, _ b: PaletteKey, _ k: Double) -> RGBA {
  let pa = rgba(a), pb = rgba(b)
  return RGBA(pa.r + (pb.r - pa.r) * k, pa.g + (pb.g - pa.g) * k, pa.b + (pb.b - pa.b) * k, 1)
}
