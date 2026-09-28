// Word-timed lyrics (data/lyrics.json) with queries for karaoke rendering.
// Port of app/src/engine/lyrics.ts (Lyrics).
import Foundation

public struct Word: Sendable {
  public var w: String
  public var start: Double
  public var end: Double
  public var conf: Double?
  public var syl: [(Double, Double)]?
  public var line: Int
  public var index: Int
  public var gi: Int
}

public struct Line: Sendable {
  public var i: Int
  public var text: String
  public var start: Double
  public var end: Double
  public var words: [Word]
}

private struct WordJSON: Codable {
  let w: String
  let start: Double
  let end: Double
  let conf: Double?
  let syl: [[Double]]?
}
private struct LineJSON: Codable {
  let i: Int?
  let text: String
  let start: Double
  let end: Double
  let words: [WordJSON]
}
private struct LyricsJSON: Codable { let lines: [LineJSON] }

public final class Lyrics: Sendable {
  public let lines: [Line]
  public let words: [Word]

  public init(jsonData: Data) throws {
    let j = try JSONDecoder().decode(LyricsJSON.self, from: jsonData)
    var gi = 0
    var ls: [Line] = []
    var ws: [Word] = []
    for (li, l) in j.lines.enumerated() {
      var lineWords: [Word] = []
      for (wi, w) in l.words.enumerated() {
        let word = Word(w: smart(w.w), start: w.start, end: w.end, conf: w.conf,
                         syl: w.syl?.map { ($0[0], $0[1]) }, line: li, index: wi, gi: gi)
        lineWords.append(word)
        ws.append(word)
        gi += 1
      }
      ls.append(Line(i: li, text: smart(l.text), start: l.start, end: l.end, words: lineWords))
    }
    lines = ls
    words = ws
  }

  public convenience init(path: String) throws {
    try self.init(jsonData: Data(contentsOf: URL(fileURLWithPath: path)))
  }

  /// The line being sung at t (or nil in gaps).
  public func lineAt(_ t: Double) -> Line? { lines.first { t >= $0.start && t < $0.end } }
  /// Index of lineAt(t) in `lines`, or -1 (matches reference.ts's `lines.indexOf(lineAt(t))`).
  public func lineIndexAt(_ t: Double) -> Int { lineAt(t)?.i ?? -1 }

  public func lastLine(_ t: Double) -> Line? {
    var best: Line?
    for l in lines where l.start <= t { best = l }
    return best
  }
  public func nextLine(_ t: Double) -> Line? { lines.first { $0.start > t } }
  public func linesIn(_ t0: Double, _ t1: Double) -> [Line] { lines.filter { $0.end > t0 && $0.start < t1 } }

  public func wordAt(_ t: Double) -> Word? { words.first { t >= $0.start && t < $0.end } }
  public func lastWord(_ t: Double) -> Word? {
    var best: Word?
    for w in words where w.start <= t { best = w }
    return best
  }
  public func findWords(_ s: String) -> [Word] {
    let q = norm(s)
    return words.filter { norm($0.w) == q }
  }

  /// Lines whose text includes `s` (case-insensitive, straight or curly quotes).
  public func find(_ s: String) -> [Line] {
    let q = fold(s)
    return lines.filter { fold($0.text).contains(q) }
  }
  /// First line containing `s`; a fatal error if missing (timeline.ts's `ly.get` throws while authoring).
  public func get(_ s: String, _ nth: Int = 0) -> Line {
    let hits = find(s)
    precondition(nth < hits.count, "lyric not found: \(s)")
    return hits[nth]
  }

  /// Sung progress of a word at time t: 0 before start, 1 after end, linear inside (or piecewise
  /// across syllables when available).
  public static func wordProgress(_ w: Word, _ t: Double) -> Double {
    if t <= w.start { return 0 }
    if t >= w.end { return 1 }
    if let syl = w.syl, syl.count > 1 {
      let n = syl.count
      for i in 0..<n {
        let (a, b) = syl[i]
        if t < a { return Double(i) / Double(n) }
        if t < b { return (Double(i) + (t - a) / max(1e-3, b - a)) / Double(n) }
      }
      return 1
    }
    return (t - w.start) / max(1e-3, w.end - w.start)
  }

  /// Progress through a whole line in characters (0..text.length), for per-glyph wipes.
  public static func lineCharProgress(_ l: Line, _ t: Double) -> Double {
    var chars = 0.0
    for w in l.words {
      let p = wordProgress(w, t)
      chars += p * Double(w.w.count)
      if p < 1 { break }
      chars += 1 // the space
    }
    return min(chars, Double(l.text.count))
  }
}

public func norm(_ s: String) -> String {
  let lowered = s.lowercased()
  return String(lowered.unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789()").contains($0) })
}
private func fold(_ s: String) -> String {
  var out = s.lowercased()
  out = out.replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
  out = out.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
  return out
}
