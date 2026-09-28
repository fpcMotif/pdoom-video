// Shared motifs (app/src/scenes/_motifs.ts). Only sparkHead2D: hook.ts's only use of this file.
import Foundation

/// Canvas2D version of the spark head: a white-hot core and an orange halo.
public func sparkHead2D(_ c: Canvas2D, _ x: Double, _ y: Double, _ t: Double, _ scale: Double = 1) {
  c.fillRadialGradient(x, y, 22 * scale, stops: [
    (0.0, RGBA(1, 250.0 / 255, 240.0 / 255, 1)),
    (0.18, RGBA(1, 170.0 / 255, 90.0 / 255, 0.95)),
    (0.45, rgba(.signal, 0.45)),
    (1.0, rgba(.signal, 0)),
  ])
}
