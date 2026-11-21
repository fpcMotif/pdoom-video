// HOOK x4 -- port of app/src/scenes/hook.ts. Method names/order/comments mirror the TS file so a diff
// against it is easy; see that file for the narrative comments this omits for brevity.
import Metal
import Foundation

private let CAP = 0.686
private let PCAP = 0.698
private let PADV = 0.6
private let P_GAP = 0.05

private struct BigLayout { var numSize: Double; var numX: Double; var numC: Double; var labX: Double; var labY: Double; var labSize: Double; var barX: Double; var barY: Double; var barW: Double }
private let BIG = BigLayout(numSize: 720, numX: 92, numC: 585, labX: 118, labY: 214, labSize: 168, barX: 118, barY: 906, barW: 1920 - 236)
private let HAIR = BigLayout(numSize: 740, numX: 88, numC: 542, labX: 118, labY: 190, labSize: 84, barX: 118, barY: 890, barW: 1920 - 236)

private struct RoomLayout { var size: Double; var rootX: Double; var rootY: Double }
private let ROOM = RoomLayout(size: 300, rootX: 1920 * 0.5, rootY: 1080 * 0.53)
private struct EyeLayout { var zoom: Double; var rot: Double; var cx: Double; var cy: Double; var A: Double; var HU: Double; var HL: Double; var TILT: Double }
private let EYE = EyeLayout(zoom: 0.68, rot: -0.07, cx: 0.12, cy: -0.06, A: 1, HU: 0.6, HL: 0.5, TILT: 0.06)
private struct ThreadLayout { var y: Double; var sparkX: Double }
private let THREAD = ThreadLayout(y: 629, sparkX: 300)

private let NOTES: [Int: String] = [
  1: "posterior \u{b7} updated on one (1) chatbot",
  2: "posterior \u{b7} updated on Sydney",
  3: "posterior \u{b7} updated on a cat",
  4: "posterior \u{b7} rounded up",
]

private struct Fonts { var im, up, my, doom, P, paren, hair, hairW, mono, monoM, monoL: String }
private struct Style { var col: RGBA?; var a: Double }

public final class HookScene: Scene {
  private let ctx: SceneCtx
  private var n = 1
  private let pd: PDoom
  private let layer: Canvas2D
  private let hookComp: HookCompRenderer
  private var words: [Word] = []
  private var ws: [Double] = []
  private var tP = 0.0, tDoom = 0.0, tNum = 0.0, tRoll0 = 0.0, tRoll1 = 0.0, tX0 = 0.0, tX1 = 0.0, tSlam = 0.0
  private var dPrev = 0.0, dNew = 0.0
  private var prevWord = ""
  private var lw = 1.0
  private let f: Fonts
  private var upLay = TextLayout(text: "", width: 0, glyphs: [], family: "", size: 0)
  private var finLay = TextLayout(text: "", width: 0, glyphs: [], family: "", size: 0)
  private var registry: FontRegistry { ctx.registry }

  public var handlesTransition: Bool { false }

  public init(ctx: SceneCtx) throws {
    self.ctx = ctx
    self.n = ctx.params.n ?? 1
    self.pd = PDoom(ctx.lyrics)
    self.layer = try Canvas2D(logicalW: 1920, logicalH: 1080, scale: ctx.scale, registry: ctx.registry)
    self.hookComp = try HookCompRenderer(device: ctx.device, library: ctx.library)
    self.f = Fonts(im: F.archivo(100, 900), up: F.archivo(125, 900), my: F.archivo(62, 900), doom: F.archivo(100, 900),
                   P: F.archivoItalic(100, 800), paren: F.archivo(62, 300), hair: F.archivo(100, 300), hairW: F.archivo(125, 300),
                   mono: F.mono(400), monoM: F.mono(500), monoL: F.mono(300))

    let lyrics = ctx.lyrics, au = ctx.audio, start = ctx.start, end = ctx.end
    let line = lyrics.linesIn(start - 0.3, end).first { $0.text.range(of: "upping", options: .caseInsensitive) != nil } ?? lyrics.linesIn(start, end)[0]
    words = Array(line.words.prefix(4))
    let prev: Line? = line.i > 0 ? lyrics.lines[line.i - 1] : nil
    prevWord = prev.map { plainQuotes($0.words.last!.w) } ?? ""
    ws = words.map { $0.start }
    let wP = words.count > 3 ? words[3] : words[words.count - 1]
    tP = wP.start
    tDoom = min((wP.syl?.count ?? 0) > 1 ? wP.syl![1].0 : wP.start + 0.4 * (wP.end - wP.start), end - 0.03)
    var stepIndex: Int
    if let idx = pd.steps.firstIndex(where: { $0.t >= tP - 0.01 && $0.t < end + 0.2 }) {
      stepIndex = idx
    } else {
      stepIndex = 0
      for (k, s) in pd.steps.enumerated() where s.t <= end { stepIndex = k }
    }
    dPrev = pd.steps[max(0, stepIndex - 1)].v; dNew = pd.steps[stepIndex].v

    let early = n == 2 || n == 3
    tNum = early ? tP : tDoom
    tRoll0 = tNum + 0.015
    tRoll1 = n == 1 ? tDoom + 0.13 : n == 4 ? tDoom + 0.08 : max(tRoll0 + 0.08, n == 3 ? tP + 0.11 : tDoom - 0.015)
    if n == 1 {
      let hat = au.timeOfBeat((au.beatAt(tDoom)).rounded() + 0.5)
      tSlam = (hat > tDoom + 0.15 && hat < end - 0.12) ? hat : lerp(tDoom, end, 0.5)
      tX0 = tSlam - 0.066; tX1 = tSlam - 0.004
    } else if n == 2 {
      tX0 = min(tDoom, end - 0.05); tX1 = end - 0.002
    } else if n == 3 {
      tX0 = max(tRoll1 + 0.01, end - 0.16); tX1 = end - 0.004
    } else {
      tX0 = end - 0.1; tX1 = end - 0.008
    }
    upLay = try layout(registry, "UPPING", f.up, 100)
    finLay = try layout(registry, "P(DOOM)", f.doom, ROOM.size)
  }

  // ------------------------------------------------------------------ helpers
  private func wordIdx(_ t: Double) -> Int {
    var i = -1
    for k in 0..<ws.count where t >= ws[k] - 1e-4 { i = k }
    return i
  }
  private func slam(_ t: Double, _ t0: Double, _ amt: Double = 0.14, _ dur: Double = 0.16) -> Double {
    let r = retrig(t, t0)
    let hold = 1 + 0.035 * max(0, t - t0)
    return hold * (1 + amt * (r == t0 ? 1.0 : 0.5) * (1 - ease.outExpo(clamp((t - r) / dur))))
  }
  private func retrig(_ t: Double, _ t0: Double) -> Double {
    guard n == 4 else { return t0 }
    let au = ctx.audio
    let bt = au.timeOfBeat((au.beatAt(t) + 1e-4).rounded(.down))
    return bt > t0 + 0.12 ? bt : t0
  }

  // ------------------------------------------------------------------ render
  public struct Prep: Sendable {
    public var bgR, bgG, bgB, echo, hot, gain: Double
    public var overrides: PostOverrides
    public var raw: (pointer: Data, bytesPerRow: Int, width: Int, height: Int)
  }

  public func prepare(_ frame: Frame, scratch c: Canvas2D) throws -> Prep {
    let t = frame.t
    c.clear()
    let wi = wordIdx(t)
    var o = PostOverrides()
    o.bloomThreshold = 1.0; o.bloomKnee = 0.2; o.bloom = 0.6; o.bloomRadius = 0.55
    o.ca = n == 3 ? 0.5 : 1.2; o.vignette = n == 2 ? 0.55 : 0.4; o.grain = n == 3 ? 0.07 : 0.055

    var bgK: PaletteKey = n == 2 ? .signal : .ink
    var inkK: PaletteKey = n == 2 ? .ink : .bone
    if n == 4 && t >= ws[0] - 0.01 && t < tDoom {
      let e = Int((frame.beat * 2).rounded(.down))
      let m = ((e % 3) + 3) % 3
      bgK = m == 0 ? .ink : m == 1 ? .signal : .bone
      inkK = m == 0 ? .bone : .ink
    }
    if n == 1 && t < ws[0] { bgK = .bone; inkK = .ink }
    let punchT = [ws[0], ws[1], ws[2], n == 3 ? -9 : tP, (n == 2 || n == 3) ? -9 : tDoom]
    let punch = n != 3 && punchT.contains { t >= $0 && t < $0 + 2.0 / 60 }
    if punch { swap(&bgK, &inkK) }

    var shake = 0.0
    let inNum = t >= tNum
    try Profiler.shared.time("cpu_raster") {
      if n == 4 && t < ws[0] { try drawAskew(c, t) }
      if n == 3 && wi >= 0 { try drawGhost(c, t) }
      if !inNum {
        if wi < 0 { try drawPre(c, t, inkK) }
        else if n == 3 { try drawTiny(c, t, wi) }
        else if wi == 0 { try drawIM(c, t, inkK) }
        else if wi == 1 { try drawUP(c, t, inkK) }
        else if wi == 2 { try drawMY(c, t, inkK) }
        else { try drawPDFull(c, t, inkK) }
        if wi >= 0 && n != 3 {
          let arr = [0.0, 7, 13, 0, 20]; shake = arr[n] * pulse(t, retrig(t, ws[wi]), 0.05)
        }
        if n != 3 { try drawAnnotations(c, t, wi, inkK) }
      } else {
        if n == 3 { try drawTiny(c, t, 3, 1 - smoothstep(tNum, tNum + 0.06, t), 3) }
        try drawNumberPhase(c, t, inkK)
      }
    }

    let echo = n == 4 ? (((wi == 3 && !inNum) ? 0.02 : 0.06) * pulse(t, ws[max(0, wi)], 0.1) + ((inNum && t < tX0) ? 0.025 : 0)) : 0.0
    let hot = bgK == .signal ? ((n == 2 && t >= tX0) ? 1.4 : 0.0) : (n == 3 ? 0.9 : 0.95)
    let gain = n == 1 ? 1 + 0.9 * smoothstep(ctx.end - 0.09, ctx.end - 0.02, t)
      : n == 2 ? 1 + 0.7 * smoothstep(tX0 + 0.02, tX1, t)
      : n == 4 ? 1 + 1.2 * smoothstep(tX0 + 0.03, tX1, t) : 1.0
    let bg = lin(bgK)

    if n == 4 && t < ws[0] { o.zoom = 1.08 }
    let hit = pulse(t, tDoom, 0.06)
    if n != 3 && n != 2 {
      let arr2 = [0.0, 10, 16, 0, 26]
      shake += arr2[n] * hit
      o.zoom = (o.zoom ?? 1) * (1 + 0.04 * hit)
    }
    if n == 1 { shake += 9 * pulse(t, tSlam, 0.05); o.bloom = 0.6 + 0.5 * pulse(t, tSlam, 0.08) }
    if shake > 0.05 { o.shake = [noise1(t * 60, 1) * shake, noise1(t * 60, 2) * shake] }
    let still = n == 1 ? ctx.end - 0.1 : tX0
    if t >= still { o.shake = [0, 0]; o.zoom = 1; o.ca = 0.5 }

    guard let rawBuf = c.rawPremultipliedRGBA() else { throw EncoderError.failed("hook layer has no backing buffer") }
    let owned = Profiler.shared.time("owned_copy") { Data(bytes: rawBuf.pointer, count: rawBuf.bytesPerRow * rawBuf.height) }
    return Prep(bgR: bg.r, bgG: bg.g, bgB: bg.b, echo: echo, hot: hot, gain: gain, overrides: o,
                raw: (owned, rawBuf.bytesPerRow, rawBuf.width, rawBuf.height))
  }

  public func render(_ frame: Frame, into out: MTLTexture, commandQueue: MTLCommandQueue) throws -> PostOverrides {
    let prep = try prepare(frame, scratch: layer)
    try hookComp.render(commandQueue: commandQueue, prep: prep, out: out)
    return prep.overrides
  }

  public func compose(_ prep: Prep, into out: MTLTexture, commandQueue: MTLCommandQueue) throws {
    try hookComp.render(commandQueue: commandQueue, prep: prep, out: out)
  }

  // ------------------------------------------------------------------ words
  private func drawPre(_ c: Canvas2D, _ t: Double, _ ink: PaletteKey) throws {
    if n == 3 {
      let a = 1 - smoothstep(ws[0] - 0.12, ws[0], t)
      let size = 40.0, adv = size * PADV
      let w = Double(prevWord.count) * adv
      c.setFont(f.mono, size)
      c.fillStyle = rgba(.bone, 0.8 * a)
      try c.fillText(prevWord, 1920 / 2 - w / 2, 1080 / 2 + size * 0.35)
      c.fillStyle = rgba(.signal, a)
      c.fillRect(1920 / 2 + w / 2 + 3, 1080 / 2 + size * 0.35 - size * 0.78, 3, size * 0.9)
      return
    }
    let k = ease.outExpo(prog(t, ctx.start, ws[0]))
    c.fillStyle = rgba(ink, 0.3)
    c.fillRect(1920 / 2 - 400 * k, 1080 / 2, 800 * k, 1)
  }

  private func drawAskew(_ c: Canvas2D, _ t: Double) throws {
    let t0 = ws[0]
    let k = prog(t, ctx.start, t0)
    let fam = f.im, size = 1150.0
    let w = try measure(registry, "I\u{2019}M", fam, size)
    c.save()
    c.translate(1920 / 2, 1080 / 2)
    c.rotate(-0.12 * (1 - k * k))
    c.setFont(fam, size)
    for j in 0..<5 {
      let sc = 0.2 + 0.8 * (k * 2 + Double(j) / 5).truncatingRemainder(dividingBy: 1)
      c.save(); c.scaleXY(sc, sc)
      c.strokeStyle = rgba(j % 2 != 0 ? .signal : .bone, 0.5 * sc)
      c.lineWidth = 2 / sc
      try c.strokeText("I\u{2019}M", -w / 2, (size * CAP) / 2)
      c.restore()
    }
    c.restore()
  }

  private func guides(_ c: Canvas2D, _ base: Double, _ capH: Double, _ ink: PaletteKey, _ a: Double = 1) throws {
    if n == 3 { return }
    c.save()
    c.fillStyle = rgba(ink, 0.22 * a)
    c.fillRect(0, base.rounded(), 1920, 1)
    c.fillRect(0, (base - capH).rounded(), 1920, 1)
    c.setFont(f.mono, 11)
    c.fillStyle = rgba(ink, 0.5 * a)
    try c.fillText("baseline", 96, base.rounded() + 16)
    try c.fillText("cap-height \u{b7} \(String(format: "%.3f", CAP)) em", 96, (base - capH).rounded() - 8)
    c.restore()
  }

  private func drawIM(_ c: Canvas2D, _ t: Double, _ ink: PaletteKey) throws {
    let t0 = ws[0]
    let fam = f.im
    let w1 = try measure(registry, "I\u{2019}M", fam, 100) / 100
    let size = min(n == 1 ? 980.0 : 1200.0, (1920.0 - 150) / w1)
    let s = slam(t, t0, n == 4 ? 0.3 : 0.16)
    let w = w1 * size
    let base = 1080 / 2 + (size * CAP) / 2
    try guides(c, base, size * CAP, ink)
    c.save()
    c.translate(1920 / 2, base)
    c.scaleXY(s, s)
    if n == 4 { try echoes(c, "I\u{2019}M", fam, size, -w / 2, 0, t, t0) }
    c.setFont(fam, size)
    c.fillStyle = rgba(ink)
    try c.fillText("I\u{2019}M", -w / 2, 0)
    c.restore()
  }

  private func drawUP(_ c: Canvas2D, _ t: Double, _ ink: PaletteKey) throws {
    let t0 = ws[1], t1 = ws.count > 2 ? ws[2] : t0 + 0.4
    let fam = f.up
    let size = min(900.0, (1920.0 - 150) / (upLay.width / 100))
    let lay = try layout(registry, "UPPING", fam, size)
    let x0 = (1920 - lay.width) / 2
    let capH = size * CAP
    let endY = 1080 / 2 + capH / 2 - 30
    let hold = t1 - t0
    let dur = min(0.3, hold * 0.8)
    let stagger = min(0.035, hold * 0.08)
    let period = n == 4 ? ctx.audio.timeOfBeat(ctx.audio.beatAt(t0) + 0.5) - t0 : 99.0
    let reps = n == 4 ? min(8, 1 + Int(max(0, t - t0) / max(0.12, period))) : 1
    try guides(c, endY, capH, ink, 0.6)
    c.save()
    c.setFont(fam, size)
    func posAt(_ i: Int, _ tt: Double, _ rep: Int) -> (y: Double, ts: Double) {
      let ts = t0 + Double(i) * stagger + Double(rep) * period
      let k = clamp((tt - ts) / dur)
      let e = ease.outExpo(k)
      let drift = max(0, tt - ts - dur) * (n == 4 ? 900.0 : 70.0)
      return (lerp(1080 + capH * 1.3, endY, e) - drift, ts)
    }
    for rep in stride(from: reps - 1, through: 0, by: -1) {
      for i in 0..<lay.glyphs.count {
        let g = lay.glyphs[i]
        let p = posAt(i, t, rep)
        if t < p.ts || p.y < -80 { continue }
        let pPrev = posAt(i, t - 1.0 / 60, rep)
        let vel = abs(pPrev.y - p.y) * 60
        let stretch = 1 + clamp(vel / 5000, 0, 1.3)
        let x = x0 + g.x
        let trail = clamp(vel / 3000)
        if trail > 0.02 {
          c.strokeStyle = rgba(ink, 0.55 * trail)
          c.lineWidth = 1.5
          for j in 1...4 {
            c.save(); c.translate(x, p.y + Double(j) * vel * 0.012); c.scaleXY(1, stretch)
            try c.strokeText(g.ch, 0, 0); c.restore()
          }
        }
        c.save()
        c.translate(x, p.y)
        c.scaleXY(1, stretch)
        c.fillStyle = rgba(ink)
        if n == 4 && rep < reps - 1 { c.strokeStyle = rgba(ink, 0.9); c.lineWidth = 3; try c.strokeText(g.ch, 0, 0) }
        else { try c.fillText(g.ch, 0, 0) }
        c.restore()
      }
    }
    c.restore()
  }

  private func drawMY(_ c: Canvas2D, _ t: Double, _ ink: PaletteKey) throws {
    let t0 = ws[2]
    let fam = f.my
    let size = n == 1 ? 1300.0 : 1420.0
    let s = slam(t, t0, n == 4 ? 0.3 : 0.12)
    let w = try measure(registry, "MY", fam, size)
    let base = 1080 / 2 + (size * CAP) / 2
    try guides(c, base, size * CAP, ink)
    c.save()
    c.translate(1920 / 2, base)
    c.scaleXY(s, s)
    if n == 4 { try echoes(c, "MY", fam, size, -w / 2, 0, t, t0) }
    c.setFont(fam, size)
    c.fillStyle = rgba(ink)
    try c.fillText("MY", -w / 2, 0)
    c.restore()
  }

  private func pdWidth(_ size: Double, _ hair: Bool = false) throws -> Double {
    try measure(registry, "P", pFam(hair), size) + size * P_GAP + measure(registry, "(", f.paren, size * 1.25) * 2
      + measure(registry, "DOOM", hair ? f.hairW : f.doom, size) + size * 0.03
  }
  private func pFam(_ hair: Bool) -> String { hair ? F.archivoItalic(100, 400) : f.P }

  private func drawPD(_ c: Canvas2D, _ x0: Double, _ base: Double, _ size: Double, _ ink: PaletteKey, _ lit: Double, _ hair: Bool = false, _ doomCol: RGBA? = nil) throws {
    var x = x0
    c.fillStyle = rgba(ink)
    c.setFont(pFam(hair), size)
    try c.fillText("P", x, base)
    x += try measure(registry, "P", pFam(hair), size) + size * P_GAP
    let psz = size * 1.25
    c.setFont(f.paren, psz)
    try c.fillText("(", x, base + psz * 0.12)
    x += try measure(registry, "(", f.paren, psz)
    c.fillStyle = rgba(ink, lerp(n == 2 ? 0.3 : 0.2, 1, lit))
    c.setFont(hair ? f.hairW : f.doom, size)
    let pc = c.fillStyle
    if let doomCol { c.fillStyle = doomCol }
    try c.fillText("DOOM", x, base)
    c.fillStyle = pc
    x += try measure(registry, "DOOM", hair ? f.hairW : f.doom, size) + size * 0.03
    c.setFont(f.paren, psz)
    try c.fillText(")", x, base + psz * 0.12)
  }

  private func drawPDFull(_ c: Canvas2D, _ t: Double, _ ink: PaletteKey) throws {
    let t0 = tP
    let size = (1920.0 - 190) / (try pdWidth(100) / 100)
    let s = slam(t, t0, n == 4 ? 0.25 : 0.12)
    let w = try pdWidth(size)
    let base = 1080 / 2 + (size * CAP) / 2
    try guides(c, base, size * CAP, ink)
    c.save()
    c.translate(1920 / 2, base)
    c.scaleXY(s, s)
    if n == 4 {
      c.save()
      for j in stride(from: 3, through: 1, by: -1) {
        let sc = 1 + Double(j) * 0.07 * (1 + (t - t0) * 3)
        c.save(); c.scaleXY(sc, sc); c.globalAlpha = 0.28 - Double(j) * 0.07
        try drawPD(c, -w / 2, 0, size, j % 2 != 0 ? .signal : .bone, 1)
        c.restore()
      }
      c.restore()
    }
    try drawPD(c, -w / 2, 0, size, ink, t >= tDoom ? 1 : 0)
    c.restore()
  }

  private func echoes(_ c: Canvas2D, _ s: String, _ fam: String, _ size: Double, _ x: Double, _ y: Double, _ t: Double, _ t0: Double) throws {
    c.save()
    c.setFont(fam, size)
    let age = t - retrig(t, t0)
    for j in stride(from: 6, through: 1, by: -1) {
      let sc = 1 + Double(j) * 0.07 * (1 + age * 2.5)
      c.save()
      c.scaleXY(sc, sc)
      c.strokeStyle = rgba(j % 2 != 0 ? .signal : .bone, 0.6 - Double(j) * 0.07)
      c.lineWidth = 2 / sc
      try c.strokeText(s, x, y)
      c.restore()
    }
    c.restore()
  }

  private func drawTiny(_ c: Canvas2D, _ t: Double, _ wi: Int, _ fade: Double = 1, _ skip: Int = -1) throws {
    let labels = ["I\u{2019}M", "UPPING", "MY", "P(DOOM)"]
    let fam = f.hair, size = 54.0, track = 16.0, gap = 84.0
    let cy = 1080 / 2 + (size * CAP) / 2
    for i in 0...max(0, wi) where i <= wi {
      if i == skip { continue }
      let since = t - ws[i]
      var slot = 0.0
      if i + 1 <= wi { for j in (i + 1)...wi { slot += ease.outExpo(clamp((t - ws[j]) / 0.3)) } }
      let rise = -(1 - ease.outExpo(clamp(since / 0.3))) * (i == 1 ? gap : gap * 0.5)
      let y = cy - slot * gap - rise - since * 8
      let a = (i == wi ? 0.95 : 0.22 / slot) * fade
      c.save()
      c.fillStyle = rgba(.bone, a)
      let s = labels[i]
      if s == "P(DOOM)" {
        c.globalAlpha = fade
        try drawPD(c, 1920 / 2 - (try pdWidth(size, true)) / 2, y, size, .bone, t >= tDoom ? 1 : 0, true)
      } else {
        c.setFont(fam, size)
        c.letterSpacing = track
        let w = try measure(registry, s, fam, size, track) - track
        try c.fillText(s, 1920 / 2 - w / 2, y)
      }
      c.restore()
    }
    c.fillStyle = rgba(.bone, 0.1 * fade)
    c.fillRect(1920 / 2 - 360, cy + 26, 720, 1)
  }

  private func drawAnnotations(_ c: Canvas2D, _ t: Double, _ wi: Int, _ ink: PaletteKey) throws {
    c.save()
    c.setFont(f.monoM, 13)
    c.letterSpacing = 3
    let labels = ["I'M", "UPPING", "MY", "P(DOOM)"]
    var x = 96.0
    for (i, l) in labels.enumerated() {
      let s = "\(String(format: "%02d", i + 1)) \(l)"
      c.fillStyle = i == wi ? rgba(ink == .ink ? .ink : .signal, 1) : rgba(ink, 0.4)
      try c.fillText(s, x, 84)
      x += try measure(registry, s, f.monoM, 13, 3) + 36
    }
    c.textAlign = .right
    c.fillStyle = rgba(ink, 0.5)
    try c.fillText("HOOK \(n) / 4", 1920 - 96, 84)
    c.restore()
  }

  // ------------------------------------------------------------------ the number
  private func shown(_ t: Double) -> Double {
    let k = prog(t, tRoll0, tRoll1, n == 3 ? ease.inOutCubic : ease.outCubic)
    let v = lerp(dPrev, dNew, k)
    if n != 4 { return v }
    return lerp(v, max(v, 0.999), prog(t, tRoll1 + 0.005, tRoll1 + 0.05, ease.outCubic))
  }
  private func extra9(_ t: Double) -> Int {
    guard n == 4 else { return 0 }
    let t9 = tRoll1 + 0.06
    return t >= t9 ? min(30, 1 + Int((t - t9) / 0.018)) : 0
  }
  private func labelFrom(_ t: Double) throws -> (x: Double, base: Double, size: Double) {
    if n == 3 {
      let size = 54.0
      let rise = (1 - ease.outExpo(clamp((t - tP) / 0.3))) * 42
      return (1920 / 2 - (try pdWidth(size, true)) / 2, 1080 / 2 + (size * CAP) / 2 - (t - tP) * 8 + rise, size)
    }
    if n == 1 || n == 4 {
      let size = (1920.0 - 190) / (try pdWidth(100) / 100)
      return (1920 / 2 - (try pdWidth(size)) / 2, 1080 / 2 + (size * CAP) / 2, size)
    }
    return (BIG.labX, BIG.labY, BIG.labSize)
  }

  private func drawNumberPhase(_ c: Canvas2D, _ t: Double, _ ink: PaletteKey) throws {
    lw = 1
    if n == 1 {
      let R = (ROOM.rootX, ROOM.rootY)
      if t < tSlam {
        let k = prog(t, tX0, tX1, ease.inCubic)
        c.save()
        if k > 0 { c.translate(R.0, R.1); c.scaleXY(1 - k, 1 - k); c.translate(-R.0, -R.1) }
        try drawInstrument(c, t, ink)
        c.restore()
        if k > 0.02 { sparkHead2D(c, R.0, R.1, t, 0.4 + 1.8 * k) }
      } else {
        try drawFinalPD(c, t)
      }
    } else if n == 2 {
      let e = prog(t, tX0, tX1)
      if e <= 0 { try drawInstrument(c, t, ink); return }
      let S = eyePx(0, 0), P0 = eyePx(-1, -EYE.TILT), P1 = eyePx(1, EYE.TILT)
      let th = atan2(P1.1 - P0.1, P1.0 - P0.0)
      let G = (BIG.numX + (4 * PADV * BIG.numSize) / 2, BIG.numC)
      let eo = ease.outCubic(e)
      c.save()
      c.translate(lerp(G.0, S.0, eo), lerp(G.1, S.1, eo))
      c.rotate(th * eo)
      c.scaleXY(lerp(1, 0.55, eo), max(0.002, (1 - e) * (1 - e)))
      c.translate(-G.0, -G.1)
      try drawInstrument(c, t, ink)
      c.restore()
      try drawLids(c, e)
    } else if n == 3 {
      try drawInstrument(c, t, ink)
    } else {
      let k = prog(t, tX0, tX1)
      if k <= 0 { try drawInstrument(c, t, ink); return }
      let ex = extra9(t)
      let (size, _) = numFit(ex)
      let sw = Double(5 + ex) * size * PADV
      let G = (BIG.numX + sw / 2, BIG.numC)
      let sy = pow(1 - k, 3)
      c.save()
      c.translate(lerp(G.0, 1920 / 2, ease.outCubic(k)), lerp(G.1, THREAD.y, ease.outCubic(k)))
      c.scaleXY(lerp(1, (1920.0 + 40) / sw, ease.inCubic(k)), max(0.003, sy))
      c.translate(-G.0, -G.1)
      try drawInstrument(c, t, ink)
      c.restore()
      let a = smoothstep(0.25, 0.85, k)
      c.fillStyle = rgba(.bone, a)
      c.fillRect(0, THREAD.y - 1, 1920, 2)
      c.fillStyle = rgba(.signal, 0.5 * a)
      c.fillRect(0, THREAD.y - 3, 1920, 1)
      if k > 0.5 { sparkHead2D(c, THREAD.sparkX, THREAD.y - 6, t, smoothstep(0.5, 1, k) * 0.9) }
    }
  }

  private func drawFinalPD(_ c: Canvas2D, _ t: Double) throws {
    let R = (ROOM.rootX, ROOM.rootY), size = ROOM.size, fam = f.doom
    let lay = finLay
    let ox = 1920 / 2 - lay.width / 2, oy = 1080 / 2 + size * 0.36
    let e = prog(t, tSlam, tSlam + 0.14)
    let s = e >= 1 ? 1 : lerp(0.1, 1, ease.outBack(e, 1.3))
    let end = ctx.end
    let drain = smoothstep(end - 0.075, end - 0.012, t)
    c.save()
    c.translate(R.0, R.1); c.scaleXY(s, s); c.translate(-R.0, -R.1)
    c.setFont(fam, size)
    c.fillStyle = rgba(.bone, 0.94 * (1 - drain))
    for g in lay.glyphs { try c.fillText(g.ch, ox + g.x, oy) }
    let lineA = smoothstep(end - 0.11, end - 0.04, t)
    if lineA > 0 {
      c.lineJoin = .round
      c.strokeStyle = rgba(.bone, lineA)
      c.lineWidth = 2.6 / s
      for g in lay.glyphs { try c.strokeText(g.ch, ox + g.x, oy) }
    }
    c.restore()
    sparkHead2D(c, R.0, R.1, t, lerp(2.2, 0.75, prog(t, tSlam, tSlam + 0.16, ease.outCubic)))
  }

  private func drawLids(_ c: Canvas2D, _ e: Double) throws {
    let A = EYE.A * (1 + 2.6 * (1 - e))
    let h = max(0.012, 4.4 * (1 - e) * (1 - e))
    func K(_ x: Double) -> Double { let q = x / A; return abs(q) < 1 ? pow(1 - q * q, 0.62) : 0 }
    var up: [(Double, Double)] = [], dn: [(Double, Double)] = []
    let N = 120
    for i in 0...N {
      let x = lerp(-3.4, 3.6, Double(i) / Double(N))
      up.append(eyePx(x, EYE.TILT * x + h * EYE.HU * K(x)))
      dn.append(eyePx(x, EYE.TILT * x - h * EYE.HL * K(x)))
    }
    c.save()
    c.fillStyle = rgba(.ink, 1)
    c.beginPath()
    for (i, p) in up.enumerated() { i == 0 ? c.moveTo(p.0, p.1) : c.lineTo(p.0, p.1) }
    c.lineTo(1920 + 100, -100); c.lineTo(-100, -100); c.closePath(); c.fill()
    c.beginPath()
    for (i, p) in dn.enumerated() { i == 0 ? c.moveTo(p.0, p.1) : c.lineTo(p.0, p.1) }
    c.lineTo(1920 + 100, 1080 + 100); c.lineTo(-100, 1080 + 100); c.closePath(); c.fill()
    c.strokeStyle = rgba(.bone, 0.3 * (1 - smoothstep(0.6, 0.95, e)))
    c.lineWidth = 1.5
    for (sgn, H0) in [(1.0, EYE.HU), (-1.0, EYE.HL)] {
      c.beginPath()
      for i in 0...N {
        let x = lerp(-A, A, Double(i) / Double(N))
        let p = eyePx(x, EYE.TILT * x + sgn * h * H0 * K(x))
        i == 0 ? c.moveTo(p.0, p.1) : c.lineTo(p.0, p.1)
      }
      c.stroke()
    }
    let a = smoothstep(0.3, 0.9, e)
    if a > 0 {
      let p0 = eyePx(-A, -EYE.TILT * A), p1 = eyePx(A, EYE.TILT * A)
      c.lineCap = .round
      c.strokeStyle = rgba(.signal, 0.35 * a); c.lineWidth = 9
      c.beginPath(); c.moveTo(p0.0, p0.1); c.lineTo(p1.0, p1.1); c.stroke()
      c.strokeStyle = rgba(.signal, a); c.lineWidth = 3
      c.beginPath(); c.moveTo(p0.0, p0.1); c.lineTo(p1.0, p1.1); c.stroke()
    }
    c.restore()
  }

  private func drawGhost(_ c: Canvas2D, _ t: Double) throws {
    if t >= tNum { return }
    let a = 0.1 * smoothstep(ws[0], ws[0] + 0.5, t)
    if a <= 0.003 { return }
    let size = HAIR.numSize
    c.save()
    c.strokeStyle = rgba(.bone, a)
    c.lineWidth = 1.2
    c.setFont(f.monoL, size)
    try c.strokeText(formatPDoom(dPrev), HAIR.numX, HAIR.numC + (size * PCAP) / 2)
    c.restore()
  }

  private func numFit(_ extra: Int) -> (size: Double, base: Double) {
    let B = n == 3 ? HAIR : BIG
    let chars = Double(5 + extra)
    let size = extra > 0 ? min(B.numSize, (1920.0 - 180) / (chars * PADV)) : B.numSize
    return (size, B.numC + (size * PCAP) / 2)
  }

  private func drawInstrument(_ c: Canvas2D, _ t: Double, _ ink: PaletteKey) throws {
    let hair = n == 3
    let B = hair ? HAIR : BIG
    let age = t - tNum
    let v = shown(t), vPrev = shown(t - 1.0 / 60)
    let inkSignal = ink == .ink
    func burn(_ i: Int) -> Style {
      guard hair else { return Style(col: nil, a: 1) }
      let RANK = [3, 1, 0, 2]
      let span = max(0.02, tX1 - 0.05 - (tX0 + 0.025))
      let tb = i == -2 ? tX0 : i == -1 ? tDoom : tX0 + 0.025 + (span * Double(i >= 0 && i < 4 ? RANK[i] : 3)) / 3
      let heat = prog(t, tb - 0.03, tb + 0.01)
      let out = i == -1 ? 0.6 * prog(t, tb + 0.01, ctx.end) : prog(t, tb, tb + 0.05, ease.inQuad)
      let flick = 0.55 + 0.45 * hash(frameIdx(t), Double(i + 3))
      let a = (1 - out) * ((heat > 0 && out > 0) ? flick : 1) * (1 + 0.6 * heat * (1 - out))
      let k = min(1, heat * 1.3)
      let col: RGBA? = k > 0 ? rgbaRGB(Int(lerp(242, 255, k).rounded()), Int(lerp(236, 92, k).rounded()), Int(lerp(228, 36, k).rounded())) : rgba(.bone)
      return Style(col: col, a: min(1, a) * (i < 0 ? 1 : 0.92))
    }
    let appear = hair ? prog(age, 0, 0.1) : 1

    let m = n == 2 ? 1 : hair ? prog(t, tNum + 0.02, tNum + 0.16, ease.inOutCubic) : prog(t, tNum, tNum + 0.14, ease.outExpo)
    let from = try labelFrom(t)
    let ls = exp(lerp(log(from.size), log(B.labSize), m))
    c.save()
    let lb = burn(-1)
    c.globalAlpha = lb.a
    try drawPD(c, lerp(from.x, B.labX, m), lerp(from.base, B.labY, m), ls, ink, t >= tDoom ? 1 : 0, hair, (hair && t >= tDoom) ? lb.col : nil)
    c.restore()
    let bb = burn(-2)

    let d = prog(age, 0, hair ? 0.2 : 0.16, ease.outExpo)
    let bx = B.barX, by = B.barY, bw = B.barW
    let th = hair ? 1.0 : 2.0
    c.save()
    c.globalAlpha = appear * bb.a
    c.fillStyle = rgba(ink, hair ? 0.35 : 0.43)
    c.fillRect(bx, by, bw * d, th)
    var i = 0
    while Double(i) <= 10 * d {
      let hh = Double(i % 5 == 0 ? 5 : 3) * (hair ? 3.0 : 4.0)
      c.fillRect(bx + (bw * Double(i)) / 10, by - hh, th, hh)
      i += 1
    }
    c.setFont(f.mono, 13)
    c.fillStyle = rgba(ink, 0.55 * smoothstep(0.3, 0.9, d))
    for i in [0, 5, 10] {
      try c.fillText(String(format: "%.2f", Double(i) / 10), bx + (bw * Double(i)) / 10 - (i == 10 ? 30 : i == 5 ? 15 : 0), by + 26)
    }
    c.textAlign = .right
    let dd = dNew - dPrev
    try c.fillText("\u{2206} \(dd >= 0 ? "+" : "\u{2212}")\(String(format: "%.2f", abs(dd))) \u{b7} \(NOTES[n] ?? "")", bx + bw, by + 50)
    c.textAlign = .left
    c.fillStyle = hair ? rgba(.bone, 0.9) : inkSignal ? rgba(.ink, 1) : rgba(.signal, 1)
    c.fillRect(bx, by - (hair ? 1 : 3), bw * clamp(v) * d, hair ? 3 : 9)
    c.restore()

    let extra = extra9(t)
    let (size, base) = numFit(extra)
    let numCol = inkSignal ? rgba(.ink, 1) : hair ? rgba(.bone, 0.9) : rgba(.signal, 1)
    let s = hair ? 1 : 1 + 0.1 * (1 - ease.outExpo(clamp(age / 0.16)))
    c.save()
    let cx = B.numX + (4 * PADV * size) / 2, cy = B.numC
    c.translate(cx, cy); c.scaleXY(s, s); c.translate(-cx, -cy)
    c.globalAlpha = appear
    c.fillStyle = numCol; c.strokeStyle = numCol
    try drawDigits(c, B.numX, base, size, v, vPrev, extra, hair, hair ? burn : nil)
    c.restore()
  }

  private func drawDigits(_ c: Canvas2D, _ x: Double, _ y: Double, _ size: Double, _ v: Double, _ vPrev: Double, _ extra: Int, _ hair: Bool, _ style: ((Int) -> Style)?) throws {
    let dec = formatPDoom(v).count - 2
    let scale = pow(10.0, Double(dec))
    let N = v * scale, Np = vPrev * scale
    let adv = size * PADV
    let rowH = size * 1.05
    let a0 = c.globalAlpha
    func glyph(_ s: String, _ gx: Double, _ gy: Double) throws {
      if hair { c.lineWidth = 1.4 * lw; try c.strokeText(s, gx, gy) } else { try c.fillText(s, gx, gy) }
    }
    func apply(_ i: Int) -> Double {
      guard let style else { return 1 }
      let st = style(i)
      if let col = st.col { c.fillStyle = col; c.strokeStyle = col }
      return st.a
    }
    c.setFont(hair ? f.monoL : f.mono, size)
    var sa = apply(0); c.globalAlpha = a0 * sa; try glyph("0", x, y)
    sa = apply(1); c.globalAlpha = a0 * sa; try glyph(".", x + adv, y)
    for d in 0..<dec {
      let kp = dec - 1 - d
      let pos = drum(N, kp), posP = drum(Np, kp)
      let speed = abs(pos - posP) * 60
      let xx = x + adv * Double(2 + d)
      sa = apply(2 + d)
      c.save()
      c.clipRect(xx - 6, y - size * PCAP - size * 0.3, adv + 12, size * PCAP + size * 0.6)
      let base = floor(pos), fr = pos - base
      let blur = clamp(speed / 25, 0, 1)
      for j in -1...1 {
        let dig = Int((base + Double(j)).truncatingRemainder(dividingBy: 10) + 10) % 10
        let off = (fr - Double(j)) * rowH
        let a = (1 - min(1, abs(off) / (rowH * 0.85))) * ((hair && j != 0) ? 0.5 : 1)
        if a <= 0.01 { continue }
        let copies = (blur > 0.05 && !hair) ? 4 : 1
        for q in 0..<copies {
          c.globalAlpha = a0 * sa * a * (copies > 1 ? 0.4 : 1)
          try glyph(String(dig), xx, y + off + (Double(q) - Double(copies - 1) / 2) * rowH * 0.07 * blur)
        }
      }
      c.restore()
    }
    c.globalAlpha = a0
    for e in 0..<extra { try glyph("9", x + adv * Double(2 + dec + e), y) }
    if extra > 0 {
      let s = "0." + String(repeating: "9", count: dec + extra)
      c.save()
      c.lineWidth = 1.5
      for r in 1...4 {
        c.globalAlpha = a0 * (0.35 - Double(r) * 0.07)
        try c.strokeText(s, x, y - Double(r) * rowH * 0.34)
        try c.strokeText(s, x, y + Double(r) * rowH * 0.34)
      }
      c.restore()
    }
  }
}

/// FIG. 6's eye space -> canvas px (its opening camera).
private func eyePx(_ ex: Double, _ ey: Double) -> (Double, Double) {
  let dx = ex - EYE.cx, dy = ey - EYE.cy
  let cs = cos(EYE.rot), sn = sin(EYE.rot)
  let px = EYE.zoom * (cs * dx + sn * dy), py = EYE.zoom * (-sn * dx + cs * dy)
  return (1920 / 2 + px * (1080 / 2), 1080 / 2 - py * (1080 / 2))
}

/// Odometer drum position for the digit 10^k of a continuous count N.
private func drum(_ N: Double, _ k: Int) -> Double {
  let p = pow(10.0, Double(k))
  if k == 0 {
    let r = N.rounded(), fr = N - r
    return ((r + (fr == 0 ? 0 : (fr > 0 ? 1.0 : -1.0)) * 0.5 * smoothstep(0.38, 0.5, abs(fr))).truncatingRemainder(dividingBy: 10) + 10).truncatingRemainder(dividingBy: 10)
  }
  let q = (N / p).rounded(.down)
  let rem = N - q * p
  let carry = clamp(rem - (p - 0.5), 0, 1)
  return (q.truncatingRemainder(dividingBy: 10) + carry + 10).truncatingRemainder(dividingBy: 10)
}
