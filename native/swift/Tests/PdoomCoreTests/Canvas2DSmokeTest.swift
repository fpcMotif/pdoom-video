// A quick, human-inspectable smoke test for the font/Canvas2D infra (not a pixel-exact check): renders
// a couple of hook.ts-style strings and writes them as a PNG under the scratch dir so they can be looked
// at directly, before wiring the whole Hook scene together.
import Testing
import Foundation
@testable import PdoomCore

@Test func canvas2DRendersText() throws {
  let root = findRepoRootForTests()
  let registry = try FontRegistry(fontsDir: root.appendingPathComponent("app/public/fonts"))
  let c = try Canvas2D(logicalW: 1920, logicalH: 1080, scale: 1, registry: registry)
  c.clear(rgba(.ink))
  c.setFont(F.archivo(100, 900), 980)
  c.fillStyle = rgba(.bone)
  let w = try measure(registry, "I’M", F.archivo(100, 900), 100) / 100 * 980
  try c.fillText("I’M", 1920 / 2 - w / 2, 1080 / 2 + 980 * 0.686 / 2)

  c.setFont(F.mono(400), 40)
  c.fillStyle = rgba(.signal)
  try c.fillText("0.15", 64, 1080 - 66)

  let flipped = c.flippedRGBA() // row 0 = bottom
  var topDown = [UInt8](repeating: 0, count: flipped.count)
  let w4 = 1920 * 4
  for row in 0..<1080 { topDown[row * w4..<(row + 1) * w4] = flipped[(1079 - row) * w4..<(1080 - row) * w4] }
  let out = root.appendingPathComponent("out/native-swift/canvas2d-smoke.png")
  try writePNG(rgba: topDown, width: 1920, height: 1080, to: out)
  #expect(FileManager.default.fileExists(atPath: out.path))
}

func findRepoRootForTests() -> URL {
  var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  let fm = FileManager.default
  while true {
    let marker = dir.appendingPathComponent("native/shaders", isDirectory: true)
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: marker.path, isDirectory: &isDir), isDir.boolValue { return dir }
    dir = dir.deletingLastPathComponent()
  }
}
