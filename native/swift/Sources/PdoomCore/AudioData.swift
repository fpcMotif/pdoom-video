// Music analysis (data/audio.json) sampled at arbitrary song time.
// Port of app/src/engine/audio.ts (AudioData). Envelopes are stored as Float32 (the JSON encodes
// Float32Array-derived data in JS), but every lookup computes in Double, matching JS's doubles.
import Foundation

public struct AudioSection: Codable, Sendable {
  public let name: String
  public let start: Double
  public let end: Double
}

public struct AudioSample: Sendable {
  public var rms = 0.0, low = 0.0, mid = 0.0, high = 0.0
  public var vocal = 0.0, drums = 0.0, bass = 0.0, other = 0.0
  public var kick = 0.0, snare = 0.0, hat = 0.0, vonset = 0.0
}

/// Raw JSON shape of data/audio.json: features may be nested under `features` or as top-level arrays.
private struct AudioJSON: Codable {
  let duration: Double
  let bpm: Double
  let fps: Double?
  let beats: [Double]
  let downbeats: [Double]
  let sections: [AudioSection]
  let features: [String: [Float]]?
  let onsets: [String: [[Double]]]?
  let rms: [Float]?, low: [Float]?, mid: [Float]?, high: [Float]?
  let vocal: [Float]?, drums: [Float]?, bass: [Float]?, other: [Float]?
}

private let FEATURES = ["rms", "low", "mid", "high", "vocal", "drums", "bass", "other"]

public final class AudioData: Sendable {
  public let duration: Double
  public let bpm: Double
  public let beats: [Double]
  public let downbeats: [Double]
  public let sections: [AudioSection]
  public let onsets: [String: [(t: Double, s: Double)]]
  private let fps: Double
  private let feat: [String: [Float]]

  public init(jsonData: Data) throws {
    let j = try JSONDecoder().decode(AudioJSON.self, from: jsonData)
    duration = j.duration
    bpm = j.bpm
    beats = j.beats
    downbeats = j.downbeats
    sections = j.sections
    fps = (j.fps ?? 0) != 0 ? j.fps! : 100
    let top: [String: [Float]?] = ["rms": j.rms, "low": j.low, "mid": j.mid, "high": j.high,
                                    "vocal": j.vocal, "drums": j.drums, "bass": j.bass, "other": j.other]
    var f: [String: [Float]] = [:]
    for k in FEATURES { f[k] = j.features?[k] ?? top[k]! ?? [] }
    feat = f
    var on: [String: [(t: Double, s: Double)]] = [:]
    for (k, v) in j.onsets ?? [:] { on[k] = v.map { (t: $0[0], s: $0.count > 1 ? $0[1] : 0) } }
    onsets = on
  }

  public convenience init(path: String) throws {
    try self.init(jsonData: Data(contentsOf: URL(fileURLWithPath: path)))
  }

  /// Linear-interpolated envelope value at time t (audio.ts AudioData.env).
  public func env(_ name: String, _ t: Double) -> Double {
    guard let a = feat[name], !a.isEmpty else { return 0 }
    let x = t * fps
    let i = Int(x.rounded(.down))
    if i < 0 { return Double(a[0]) }
    if i >= a.count - 1 { return Double(a[a.count - 1]) }
    let f = x - Double(i)
    return Double(a[i]) * (1 - f) + Double(a[i + 1]) * f
  }

  /// Max over [t - w, t]: a peak-hold for punchy reactions.
  public func envPeak(_ name: String, _ t: Double, _ w: Double = 0.08) -> Double {
    var m = 0.0
    var s = t - w
    while s <= t { m = max(m, env(name, s)); s += 1 / fps }
    return m
  }

  /// Sum of decaying pulses from onsets of a kind (kick/snare/hat/vocal) before t.
  public func hit(_ kind: String, _ t: Double, _ halfLife: Double = 0.11) -> Double {
    guard let list = onsets[kind], !list.isEmpty else { return 0 }
    var lo = 0, hi = list.count
    while lo < hi { let m = (lo + hi) >> 1; if list[m].t <= t { lo = m + 1 } else { hi = m } }
    var v = 0.0
    var i = lo - 1
    while i >= 0 && i >= lo - 6 {
      let (ot, s) = list[i]
      let dt = t - ot
      if dt > halfLife * 8 { break }
      v = max(v, s * pow(0.5, dt / halfLife))
      i -= 1
    }
    return v
  }

  /// Onset events of a kind in [t0, t1).
  public func events(_ kind: String, _ t0: Double, _ t1: Double) -> [(t: Double, s: Double)] {
    (onsets[kind] ?? []).filter { $0.t >= t0 && $0.t < t1 }
  }

  public func sample(_ t: Double) -> AudioSample {
    var s = AudioSample()
    s.rms = env("rms", t); s.low = env("low", t); s.mid = env("mid", t); s.high = env("high", t)
    s.vocal = env("vocal", t); s.drums = env("drums", t); s.bass = env("bass", t); s.other = env("other", t)
    s.kick = hit("kick", t, 0.12); s.snare = hit("snare", t, 0.14); s.hat = hit("hat", t, 0.06); s.vonset = hit("vocal", t, 0.15)
    return s
  }

  /// Continuous beat index: 0 at first beat, fractional in between (extrapolated outside).
  public func beatAt(_ t: Double) -> Double {
    let b = beats
    if b.count < 2 { return t * (bpm / 60) }
    if t <= b[0] { return (t - b[0]) / (b[1] - b[0]) }
    if t >= b[b.count - 1] {
      let p = b[b.count - 1] - b[b.count - 2]
      return Double(b.count - 1) + (t - b[b.count - 1]) / p
    }
    var lo = 0, hi = b.count - 1
    while hi - lo > 1 { let m = (lo + hi) >> 1; if b[m] <= t { lo = m } else { hi = m } }
    return Double(lo) + (t - b[lo]) / (b[hi] - b[lo])
  }

  /// Time of (fractional) beat index.
  public func timeOfBeat(_ i: Double) -> Double {
    let b = beats
    let n = b.count
    let period = n > 1 ? (b[n - 1] - b[0]) / Double(n - 1) : 60 / bpm
    if i <= 0 { return (b.first ?? 0) + i * period }
    if i >= Double(n - 1) { return b[n - 1] + (i - Double(n - 1)) * period }
    let k = Int(i.rounded(.down))
    return b[k] + (b[k + 1] - b[k]) * (i - Double(k))
  }

  /// Continuous bar index from downbeats (0 at first downbeat).
  public func barAt(_ t: Double) -> Double {
    let d = downbeats
    if d.count < 2 { return beatAt(t) / 4 }
    if t <= d[0] { return (t - d[0]) / (d[1] - d[0]) }
    if t >= d[d.count - 1] {
      let p = d[d.count - 1] - d[d.count - 2]
      return Double(d.count - 1) + (t - d[d.count - 1]) / p
    }
    var lo = 0, hi = d.count - 1
    while hi - lo > 1 { let m = (lo + hi) >> 1; if d[m] <= t { lo = m } else { hi = m } }
    return Double(lo) + (t - d[lo]) / (d[hi] - d[lo])
  }

  /// Nearest beat time to t.
  public func nearestBeat(_ t: Double) -> Double { timeOfBeat(beatAt(t).rounded()) }

  public func section(_ t: Double) -> AudioSection? {
    sections.first { t >= $0.start && t < $0.end } ?? sections.last
  }
}
