// The edit: which scene plays when. Boundaries are anchored to lyric lines and snapped to the beat
// grid. Port of app/src/timeline.ts (makeTimeline).
import Foundation

public struct TimelineParams: Sendable, Equatable {
  public var variant: String?
  public var n: Int?
}

public struct TimelineEntry: Sendable {
  public var id: String
  public var sceneFile: String
  public var start: Double
  public var end: Double
  public var params = TimelineParams()
  public var maxSamples: Int?
}

public func makeTimeline(_ ly: Lyrics, _ au: AudioData) -> [TimelineEntry] {
  // Cut on the last beat at/before the first word of the matching line (never after the word).
  func cut(_ q: String, _ nth: Int = 0, _ tol: Double = 0.02) -> Double {
    let s = ly.get(q, nth).words[0].start
    return au.timeOfBeat(au.beatAt(s + tol).rounded(.down))
  }
  // Nearest downbeat to the end of a line.
  func after(_ q: String, _ nth: Int = 0) -> Double {
    let e = ly.get(q, nth).end
    return au.downbeats.reduce(au.downbeats.first ?? e) { abs($1 - e) < abs($0 - e) ? $1 : $0 }
  }

  let loss = cut("There was a sudden drop")
  let pre1 = cut("ChatGPT, please")
  let hook1 = cut("I'm upping", 0)
  let room = cut("'cause the future goes FOOM")
  let shog = cut("See through the shoggoth")
  let space = cut("We had a stable")
  let pre2 = cut("Sydney")
  let hook2 = cut("I'm upping", 1)
  let ascent = cut("I hear the basilisk")
  let bureau = cut("That was safe enough")
  let left = cut("Sharp left turn")
  let pre3 = cut("Gato")
  let hook3 = cut("I'm upping", 2)
  let clips = cut("as paperclips")
  let fuse = cut("Too late now")
  let stack = cut("transformers all the way")
  let dense = cut("Post-Chinchilla", 0, 0.05) // 'Post' starts 32 ms before its beat; don't cut 'disobey' in half
  let hook4 = cut("I'm upping", 3)
  let loom = cut("Just as foretold")
  let ilya = cut("What did Ilya")
  let outro = au.sections.first { $0.name == "outro" }?.start ?? after("Was it all for show")
  let end = au.duration

  func e(_ id: String, _ file: String, _ start: Double, _ end: Double, params: TimelineParams = .init(), maxSamples: Int? = nil) -> TimelineEntry {
    TimelineEntry(id: id, sceneFile: file, start: start, end: end, params: params, maxSamples: maxSamples)
  }

  return [
    e("open", "open", 0, loss),
    e("loss", "loss", loss, pre1),
    e("prompt1", "prompt", pre1, hook1, params: .init(variant: "chatgpt")),
    e("hook1", "hook", hook1, room, params: .init(n: 1)),
    e("room", "room", room, shog),
    e("shoggoth", "shoggoth", shog, space, maxSamples: 108),
    e("spacetime", "spacetime", space, pre2),
    e("prompt2", "prompt", pre2, hook2, params: .init(variant: "sydney")),
    e("hook2", "hook", hook2, ascent, params: .init(n: 2)),
    e("ascent", "ascent", ascent, bureau),
    e("bureau", "bureau", bureau, left),
    e("leftturn", "leftturn", left, pre3),
    e("prompt3", "prompt", pre3, hook3, params: .init(variant: "gato")),
    e("hook3", "hook", hook3, clips, params: .init(n: 3)),
    e("paperclips", "paperclips", clips, fuse),
    e("fuse", "fuse", fuse, stack),
    e("stack", "stack", stack, dense),
    e("dense", "dense", dense, hook4),
    e("hook4", "hook", hook4, loom, params: .init(n: 4)),
    e("loom", "loom", loom, ilya),
    e("ilya", "ilya", ilya, outro),
    e("outro", "outro", outro, end),
  ]
}
