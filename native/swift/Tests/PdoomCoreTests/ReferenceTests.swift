// Compares PdoomCore's data layer (audio, lyrics, timeline) with the TS engine's own numbers, dumped by
// native/verify/reference.ts (docs/NATIVE_METAL_PIPELINE.md, M2 acceptance). Regenerate the reference
// with `bun native/verify/reference.ts > out/native-swift/reference.json` if it is missing or stale.
import Testing
import Foundation
@testable import PdoomCore

private struct RefParams: Codable { let variant: String?; let n: Int? }
private struct RefEntry: Codable { let id: String; let start: Double; let end: Double; let params: RefParams?; let maxSamples: Int? }
private struct RefLyrics: Codable { let lines: Int; let words: Int }
private struct RefAudioSample: Codable {
  let rms, low, mid, high, vocal, drums, bass, other, kick, snare, hat, vonset: Double
}
private struct RefEnv: Codable { let rms, low, mid, high, vocal, drums, bass, other: Double }
private struct RefSample: Codable { let t: Double; let beat: Double; let bar: Double; let a: RefAudioSample; let env: RefEnv; let line: Int; let word: Int }
private struct RefBeat: Codable { let i: Double; let t: Double }
private struct Reference: Codable {
  let duration: Double
  let timeline: [RefEntry]
  let lyrics: RefLyrics
  let samples: [RefSample]
  let beats: [RefBeat]
}

private func findRepoRoot() -> URL {
  var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  let fm = FileManager.default
  while true {
    let marker = dir.appendingPathComponent("native/shaders", isDirectory: true)
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: marker.path, isDirectory: &isDir), isDir.boolValue { return dir }
    let parent = dir.deletingLastPathComponent()
    precondition(parent.path != dir.path, "could not find repo root above \(#filePath)")
    dir = parent
  }
}

private func loadReference(_ root: URL) throws -> Reference {
  let path = root.appendingPathComponent("out/native-swift/reference.json")
  guard FileManager.default.fileExists(atPath: path.path) else {
    throw TestFailure("missing \(path.path) — regenerate with: bun native/verify/reference.ts > out/native-swift/reference.json")
  }
  return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: path))
}
private struct TestFailure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

private let tol = 1e-9

@Test func dataLayerMatchesReference() throws {
  let root = findRepoRoot()
  let ref = try loadReference(root)
  let audio = try AudioData(path: root.appendingPathComponent("data/audio.json").path)
  let lyrics = try Lyrics(path: root.appendingPathComponent("data/lyrics.json").path)
  let timeline = makeTimeline(lyrics, audio)

  #expect(abs(audio.duration - ref.duration) <= tol)
  #expect(lyrics.lines.count == ref.lyrics.lines)
  #expect(lyrics.words.count == ref.lyrics.words)

  #expect(timeline.count == ref.timeline.count)
  for (e, r) in zip(timeline, ref.timeline) {
    #expect(e.id == r.id)
    #expect(abs(e.start - r.start) <= tol, "\(e.id) start")
    #expect(abs(e.end - r.end) <= tol, "\(e.id) end")
    #expect(e.params.variant == r.params?.variant, "\(e.id) params.variant")
    #expect(e.params.n == r.params?.n, "\(e.id) params.n")
    #expect(e.maxSamples == r.maxSamples, "\(e.id) maxSamples")
  }

  for r in ref.beats {
    #expect(abs(audio.timeOfBeat(r.i) - r.t) <= tol, "timeOfBeat(\(r.i))")
  }

  for r in ref.samples {
    let t = r.t
    #expect(abs(audio.beatAt(t) - r.beat) <= tol, "beatAt(\(t))")
    #expect(abs(audio.barAt(t) - r.bar) <= tol, "barAt(\(t))")
    let s = audio.sample(t)
    #expect(abs(s.rms - r.a.rms) <= tol, "sample(\(t)).rms")
    #expect(abs(s.low - r.a.low) <= tol, "sample(\(t)).low")
    #expect(abs(s.mid - r.a.mid) <= tol, "sample(\(t)).mid")
    #expect(abs(s.high - r.a.high) <= tol, "sample(\(t)).high")
    #expect(abs(s.vocal - r.a.vocal) <= tol, "sample(\(t)).vocal")
    #expect(abs(s.drums - r.a.drums) <= tol, "sample(\(t)).drums")
    #expect(abs(s.bass - r.a.bass) <= tol, "sample(\(t)).bass")
    #expect(abs(s.other - r.a.other) <= tol, "sample(\(t)).other")
    #expect(abs(s.kick - r.a.kick) <= tol, "sample(\(t)).kick")
    #expect(abs(s.snare - r.a.snare) <= tol, "sample(\(t)).snare")
    #expect(abs(s.hat - r.a.hat) <= tol, "sample(\(t)).hat")
    #expect(abs(s.vonset - r.a.vonset) <= tol, "sample(\(t)).vonset")
    #expect(abs(audio.env("rms", t) - r.env.rms) <= tol, "env(rms,\(t))")
    #expect(abs(audio.env("low", t) - r.env.low) <= tol, "env(low,\(t))")
    #expect(abs(audio.env("mid", t) - r.env.mid) <= tol, "env(mid,\(t))")
    #expect(abs(audio.env("high", t) - r.env.high) <= tol, "env(high,\(t))")
    #expect(abs(audio.env("vocal", t) - r.env.vocal) <= tol, "env(vocal,\(t))")
    #expect(abs(audio.env("drums", t) - r.env.drums) <= tol, "env(drums,\(t))")
    #expect(abs(audio.env("bass", t) - r.env.bass) <= tol, "env(bass,\(t))")
    #expect(abs(audio.env("other", t) - r.env.other) <= tol, "env(other,\(t))")
    #expect(lyrics.lineIndexAt(t) == r.line, "lineAt(\(t))")
    #expect((lyrics.wordAt(t)?.gi ?? -1) == r.word, "wordAt(\(t))")
  }
}
