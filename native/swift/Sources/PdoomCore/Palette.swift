// The restrained palette: ink, bone, one signal colour. Port of app/src/engine/palette.ts.
import CoreGraphics

public enum PaletteKey: String, Sendable { case ink, ink2, graphite, ash, bone, signal, ember, blood, acid }

public let HEX: [PaletteKey: UInt32] = [
  .ink: 0x0A0A0B, .ink2: 0x15_1517, .graphite: 0x5E5B57, .ash: 0x9C978F,
  .bone: 0xEEE9DF, .signal: 0xFF4D12, .ember: 0xFF8A3D, .blood: 0xC21D0B, .acid: 0xD8FF3C,
]

private func srgbToLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

/// Linear RGB triplet for a palette key (post.ts/util.ts hexToLinear, applied to palette.ts's LIN).
public func lin(_ key: PaletteKey) -> (r: Double, g: Double, b: Double) {
  let n = HEX[key]!
  let r = Double((n >> 16) & 255) / 255, g = Double((n >> 8) & 255) / 255, b = Double(n & 255) / 255
  return (srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
}

/// CSS-rgba-equivalent colour for the Canvas2D shim: sRGB byte values, straight alpha.
public struct RGBA: Sendable {
  public var r: Double, g: Double, b: Double, a: Double
  public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
  public var cgColor: CGColor { CGColor(colorSpace: srgbColorSpace, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])! }
}

/// palette.ts `rgba(key, a)`.
public func rgba(_ key: PaletteKey, _ a: Double = 1) -> RGBA {
  let n = HEX[key]!
  return RGBA(Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255, a)
}
/// rgba() overload for an explicit "rgb(r,g,b)" string built at draw time (hook.ts's burn() colours).
public func rgbaRGB(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> RGBA {
  RGBA(Double(r) / 255, Double(g) / 255, Double(b) / 255, a)
}
