// Per-glyph horizontal layout (kerning from CoreText's shaper) plus manual tracking, matching
// app/src/engine/type.ts's layout()/measure(): x = kerned base position + i*tracking (tracking is never
// seen by the underlying shaper — type.ts's own measurement context never has letterSpacing set either).
import CoreText
import CoreGraphics
import Foundation

public struct Glyph: Sendable { public var ch: String; public var i: Int; public var x: Double; public var w: Double; public var glyphId: CGGlyph }
public struct TextLayout: Sendable { public var text: String; public var width: Double; public var glyphs: [Glyph]; public var family: String; public var size: Double }

/// One resolved CTLine's glyphs, in visual (string) order, with positions relative to the line origin.
private func lineGlyphPositions(_ font: CTFont, _ text: String) -> (glyphs: [CGGlyph], positions: [CGPoint], advances: [Double], font: CTFont) {
  let attrString = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)!
  let line = CTLineCreateWithAttributedString(attrString)
  var glyphs: [CGGlyph] = []
  var positions: [CGPoint] = []
  var advances: [Double] = []
  for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
    let n = CTRunGetGlyphCount(run)
    var gs = [CGGlyph](repeating: 0, count: n)
    var ps = [CGPoint](repeating: .zero, count: n)
    var ws = [CGSize](repeating: .zero, count: n)
    CTRunGetGlyphs(run, CFRangeMake(0, n), &gs)
    CTRunGetPositions(run, CFRangeMake(0, n), &ps)
    CTRunGetAdvances(run, CFRangeMake(0, n), &ws)
    glyphs += gs; positions += ps; advances += ws.map { Double($0.width) }
  }
  return (glyphs, positions, advances, font)
}

/// app/src/engine/type.ts `layout(text, family, size, tracking)`.
public func layout(_ registry: FontRegistry, _ text: String, _ family: String, _ size: Double, _ tracking: Double = 0) throws -> TextLayout {
  let font = try registry.ctFont(family, size)
  let chars = Array(text).map(String.init)
  guard !chars.isEmpty else { return TextLayout(text: text, width: 0, glyphs: [], family: family, size: size) }
  let (glyphIds, positions, advances, _) = lineGlyphPositions(font, text)
  guard glyphIds.count == chars.count else {
    throw FontError.load("layout(\(family)): \(glyphIds.count) glyphs for \(chars.count) characters in \(String(reflecting: text)) (ligature or fallback substitution)")
  }
  var glyphs: [Glyph] = []
  for i in 0..<chars.count {
    glyphs.append(Glyph(ch: chars[i], i: i, x: Double(positions[i].x) + Double(i) * tracking, w: advances[i], glyphId: glyphIds[i]))
  }
  let baseWidth = Double(positions.last!.x) + advances.last!
  let width = baseWidth + Double(max(0, chars.count - 1)) * tracking
  return TextLayout(text: text, width: width, glyphs: glyphs, family: family, size: size)
}

/// app/src/engine/type.ts `measure(text, family, size, tracking)`.
public func measure(_ registry: FontRegistry, _ text: String, _ family: String, _ size: Double, _ tracking: Double = 0) throws -> Double {
  try layout(registry, text, family, size, tracking).width
}
