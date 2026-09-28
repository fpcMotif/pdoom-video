// A CGContext-backed stand-in for the Canvas2D layers app/src/scenes/*.ts draw into (three.js Layer2D,
// app/src/engine/gl.ts). Supports exactly the operations app/src/scenes/hook.ts and _motifs.ts use.
// Drawing calls take logical (1920x1080) coordinates, canvas-style: y down, origin top-left, matching
// scaleContext2D's effect on the real Layer2D. The backing store is `scale` times larger; row 0 of its
// raw memory is the canvas's TOP (verified empirically), so `flippedRGBA()` reverses rows before upload,
// giving the "row 0 = image bottom" convention the shaders expect (same as three.js's flipY=true).
import CoreGraphics
import CoreText
import Foundation

public enum TextAlign { case left, right }

/// One sRGB colour space reused everywhere, so no colour ever goes through an implicit/ambiguous
/// conversion between a "generic" or DeviceRGB space and the context's own (also explicit sRGB).
let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private struct CanvasState {
  var fill = RGBA(1, 1, 1, 1)
  var stroke = RGBA(1, 1, 1, 1)
  var globalAlpha = 1.0
  var lineWidth = 1.0
  var lineCap: CGLineCap = .butt
  var lineJoin: CGLineJoin = .miter
  var family = ""
  var size = 16.0
  var letterSpacing = 0.0
  var textAlign: TextAlign = .left
}

public final class Canvas2D {
  public let ctx: CGContext
  public let registry: FontRegistry
  public let logicalW: Double
  public let logicalH: Double
  public let scale: Int
  private var state = CanvasState()
  private var stack: [CanvasState] = []

  public init(logicalW: Double, logicalH: Double, scale: Int, registry: FontRegistry) throws {
    self.logicalW = logicalW; self.logicalH = logicalH; self.scale = scale; self.registry = registry
    let pw = Int((logicalW * Double(scale)).rounded()), ph = Int((logicalH * Double(scale)).rounded())
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let c = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                             space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw FontError.load("could not create \(pw)x\(ph) CGContext")
    }
    ctx = c
    // baseline CTM: canvas-style y-down top-left, in LOGICAL units (see file header)
    ctx.translateBy(x: 0, y: CGFloat(ph))
    ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.saveGState() // the "baseline" clear() restores to
  }

  // ---- state ----
  public func save() { stack.append(state); ctx.saveGState() }
  public func restore() { if let s = stack.popLast() { state = s }; ctx.restoreGState() }
  public func translate(_ x: Double, _ y: Double) { ctx.translateBy(x: CGFloat(x), y: CGFloat(y)) }
  public func scaleXY(_ sx: Double, _ sy: Double) { ctx.scaleBy(x: CGFloat(sx), y: CGFloat(sy)) }
  public func rotate(_ a: Double) { ctx.rotate(by: CGFloat(a)) }

  public var fillStyle: RGBA { get { state.fill } set { state.fill = newValue } }
  public var strokeStyle: RGBA { get { state.stroke } set { state.stroke = newValue } }
  public var globalAlpha: Double { get { state.globalAlpha } set { state.globalAlpha = newValue } }
  public var lineWidth: Double { get { state.lineWidth } set { state.lineWidth = newValue } }
  public var lineCap: CGLineCap { get { state.lineCap } set { state.lineCap = newValue } }
  public var lineJoin: CGLineJoin { get { state.lineJoin } set { state.lineJoin = newValue } }
  public var letterSpacing: Double { get { state.letterSpacing } set { state.letterSpacing = newValue } }
  public var textAlign: TextAlign { get { state.textAlign } set { state.textAlign = newValue } }
  public func setFont(_ family: String, _ size: Double) { state.family = family; state.size = size }

  private func withAlpha(_ c: RGBA) -> CGColor {
    CGColor(colorSpace: srgbColorSpace, components: [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), CGFloat(c.a * state.globalAlpha)])!
  }

  // ---- clear (Layer2D.clear(); resets the frame to the baseline CTM and default state) ----
  public func clear(_ color: RGBA? = nil) {
    ctx.restoreGState() // undo everything since the baseline save
    ctx.saveGState() // and re-establish it for this frame
    state = CanvasState()
    stack.removeAll()
    guard let color else {
      // clearRect: zero the whole physical buffer directly (CTM-independent, exact)
      if let data = ctx.data {
        memset(data, 0, ctx.bytesPerRow * ctx.height)
      }
      return
    }
    ctx.setFillColor(withAlpha(color))
    ctx.fill(CGRect(x: 0, y: 0, width: logicalW, height: logicalH))
  }

  // ---- rects, clipping ----
  public func fillRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
    ctx.setFillColor(withAlpha(state.fill))
    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
  }
  public func clipRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
    ctx.clip(to: CGRect(x: x, y: y, width: w, height: h))
  }

  // ---- arbitrary paths (drawLids: filled/stroked polylines) ----
  private var path = CGMutablePath()
  public func beginPath() { path = CGMutablePath() }
  public func moveTo(_ x: Double, _ y: Double) { path.move(to: CGPoint(x: x, y: y)) }
  public func lineTo(_ x: Double, _ y: Double) { path.addLine(to: CGPoint(x: x, y: y)) }
  public func closePath() { path.closeSubpath() }
  public func arc(_ x: Double, _ y: Double, _ r: Double, _ a0: Double, _ a1: Double) {
    path.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: a0, endAngle: a1, clockwise: false)
  }
  public func fill() {
    ctx.setFillColor(withAlpha(state.fill))
    ctx.addPath(path); ctx.fillPath()
  }
  public func stroke() {
    ctx.setStrokeColor(withAlpha(state.stroke))
    ctx.setLineWidth(state.lineWidth); ctx.setLineCap(state.lineCap); ctx.setLineJoin(state.lineJoin)
    ctx.addPath(path); ctx.strokePath()
  }

  /// A circular radial gradient fill (sparkHead2D's `createRadialGradient` + `arc` + `fill`), stops as
  /// (offset 0..1, colour); each stop's alpha is scaled by globalAlpha, matching Canvas2D.
  public func fillRadialGradient(_ x: Double, _ y: Double, _ r: Double, stops: [(Double, RGBA)]) {
    let locations = stops.map { CGFloat($0.0) }
    let components = stops.flatMap { [$0.1.r, $0.1.g, $0.1.b, $0.1.a * state.globalAlpha] }.map { CGFloat($0) }
    guard let gradient = CGGradient(colorSpace: srgbColorSpace, colorComponents: components, locations: locations, count: stops.count) else { return }
    ctx.saveGState()
    let clip = CGMutablePath(); clip.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.addPath(clip); ctx.clip()
    ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
  }

  // ---- text ----
  public func measureText(_ text: String) throws -> Double {
    try layout(registry, text, state.family, state.size, state.letterSpacing).width
  }
  public func fillText(_ text: String, _ x: Double, _ y: Double) throws { try drawText(text, x, y, stroke: false) }
  public func strokeText(_ text: String, _ x: Double, _ y: Double) throws { try drawText(text, x, y, stroke: true) }

  private func drawText(_ text: String, _ x: Double, _ y: Double, stroke: Bool) throws {
    let lay = try layout(registry, text, state.family, state.size, state.letterSpacing)
    let originX = state.textAlign == .right ? x - lay.width : x
    let font = try registry.ctFont(state.family, state.size)
    if stroke {
      ctx.setStrokeColor(withAlpha(state.stroke))
      ctx.setLineWidth(state.lineWidth); ctx.setLineCap(state.lineCap); ctx.setLineJoin(state.lineJoin)
    } else {
      ctx.setFillColor(withAlpha(state.fill))
    }
    for g in lay.glyphs {
      // CTFontCreatePathForGlyph returns a y-up glyph outline (baseline at 0, ascenders positive); our
      // context is y-flipped to canvas (y-down) semantics, so the glyph transform must flip it back
      // (d: -1) as well as translate it, or every glyph renders upside down.
      var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: CGFloat(originX + g.x), ty: CGFloat(y))
      guard let glyphPath = CTFontCreatePathForGlyph(font, g.glyphId, &t) else { continue }
      ctx.addPath(glyphPath)
      if stroke { ctx.strokePath() } else { ctx.fillPath() }
    }
  }

  // ---- output ----
  /// RGBA8, straight (unpremultiplied) alpha, row 0 = image bottom (see file header).
  public func flippedRGBA() -> [UInt8] {
    let w = ctx.width, h = ctx.height, stride = ctx.bytesPerRow
    guard let data = ctx.data else { return [] }
    let src = data.bindMemory(to: UInt8.self, capacity: stride * h)
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for row in 0..<h {
      let srcRow = row * stride
      let dstRow = (h - 1 - row) * w * 4
      for x in 0..<w {
        let si = srcRow + x * 4, di = dstRow + x * 4
        let a = src[si + 3]
        if a == 0 { out[di] = 0; out[di + 1] = 0; out[di + 2] = 0; out[di + 3] = 0; continue }
        // premultiplied -> straight
        out[di] = UInt8(clamping: (Int(src[si]) * 255) / Int(a))
        out[di + 1] = UInt8(clamping: (Int(src[si + 1]) * 255) / Int(a))
        out[di + 2] = UInt8(clamping: (Int(src[si + 2]) * 255) / Int(a))
        out[di + 3] = a
      }
    }
    return out
  }
}
