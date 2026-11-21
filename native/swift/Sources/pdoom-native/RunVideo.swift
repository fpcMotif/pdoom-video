// `pdoom-native video [--from 0] [--to duration] [--fps 60] [--only ids] [--samples N|auto]
//  [--shutter 0.5] [--scale 1] --encoder hevc|x264 [--crf 16] [--preset slow] [--x264 aq-mode=3]
//  [--bitrate 150M] [--noaudio] --out FILE.mp4` (M3). HEVC audio muxing is not wired up yet (video-only
// AVAssetWriter output) — see README.
import Foundation
import Metal
import PdoomCore

func runVideo(args: Args, root: URL) async throws {
  let jobs = args.int("jobs", 1)
  if jobs > 1 {
    try await runVideoJobs(args: args, root: root, jobs: jobs)
  } else {
    try await runVideoSingle(args: args, root: root)
  }
}

func runVideoSingle(args: Args, root: URL) async throws {
  let scale = max(1, args.int("scale", 1))
  let fps = args.int("fps", 60)
  let only = args.opt("only").map { Set($0.split(separator: ",").map(String.init)) }
  let shutter = args.double("shutter", 0.5)
  let samples: SamplesMode = args.opt("samples") == "auto"
    ? .adaptive(AdaptiveSampling(min: args.int("min-samples", 4), max: args.int("max-samples", 324), tol: args.double("tol", 3)))
    : .fixed(args.int("samples", 1))
  let encoderName = try requireOpt(args, "encoder")
  let out = URL(fileURLWithPath: try requireOpt(args, "out"))
  let noAudio = args.flag("noaudio")

  let engine = try Engine(root: root, scale: scale, only: only)
  engine.threads = args.int("threads", 8)
  let from = args.double("from", 0)
  let to = args.opt("to").flatMap(Double.init) ?? engine.audio.duration
  let w = 1920 * scale, h = 1080 * scale
  let globalTotal = Int((to * Double(fps)).rounded()) - Int((from * Double(fps)).rounded())
  guard globalTotal > 0 else { throw EncoderError.failed("--to must be after --from") }
  let frameOffset = args.int("frame-start", 0)
  let frameEnd = args.int("frame-end", globalTotal)
  let totalFrames = frameEnd - frameOffset
  guard totalFrames > 0 else { throw EncoderError.failed("--frame-start/--frame-end produced an empty range") }

  func frameTime(_ f: Int) -> Double { from + Double(frameOffset + f) / Double(fps) }

  let debugProgress = ProcessInfo.processInfo.environment["PDOOM_DEBUG_PROGRESS"] != nil
  switch encoderName {
  case "hevc":
    let writer = try HEVCWriter(out: out, width: w, height: h, fps: fps, bitrate: 150_000_000, device: engine.device)
    do {
      for f in 0..<totalFrames {
        if debugProgress { FileHandle.standardError.write("frame \(f)/\(totalFrames)\n".data(using: .utf8)!) }
        try writer.writeFrame(f) { texture, _, queue in
          try engine.render(frameTime(f), dt: 1.0 / Double(fps), samples: samples, shutter: shutter, into: texture, commandQueue: queue)
        }
      }
      try await writer.finish()
    } catch {
      writer.cancel(out: out)
      throw error
    }
  case "x264":
    guard let commandQueue = engine.device.makeCommandQueue() else { throw EncoderError.failed("no Metal command queue") }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.shaderWrite, .shaderRead]; desc.storageMode = .shared
    guard let texture = engine.device.makeTexture(descriptor: desc) else { throw EncoderError.failed("could not allocate output texture") }
    let writer = try X264Writer(out: out, width: w, height: h, fps: fps, crf: args.opt("crf", "16")!, preset: args.opt("preset", "slow")!,
                                 x264Params: args.opt("x264", "aq-mode=3")!, audioFrom: from, audioTo: to,
                                 audioFile: noAudio ? nil : root.appendingPathComponent("audio/pdoom.mp3"), noAudio: noAudio)
    do {
      for f in 0..<totalFrames {
        try writer.writeFrame(f, render: { t, _, _ in try engine.render(frameTime(f), dt: 1.0 / Double(fps), samples: samples, shutter: shutter, into: t) },
                               texture: texture, commandQueue: commandQueue)
      }
      try writer.finish(out: out)
    } catch {
      writer.cancel(out: out)
      throw error
    }
  default:
    throw EncoderError.failed("--encoder must be hevc or x264")
  }
  print("wrote \(out.path) (\(totalFrames) frames, \(w)x\(h) @ \(fps)fps, \(encoderName))")
  Profiler.shared.report()
}

func runVideoJobs(args: Args, root: URL, jobs: Int) async throws {
  let fps = args.int("fps", 60)
  let encoderName = try requireOpt(args, "encoder")
  let out = URL(fileURLWithPath: try requireOpt(args, "out"))
  let noAudio = args.flag("noaudio")
  let from = args.double("from", 0)
  let to: Double
  if let v = args.opt("to").flatMap(Double.init) {
    to = v
  } else {
    to = try AudioData(path: root.appendingPathComponent("data/audio.json").path).duration
  }
  let totalFrames = Int((to * Double(fps)).rounded()) - Int((from * Double(fps)).rounded())
  guard totalFrames > 0 else { throw EncoderError.failed("--to must be after --from") }

  let selfExe = resolvedSelfExecutable()
  let tmpDir = out.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent)-jobs-\(ProcessInfo.processInfo.processIdentifier)")
  try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tmpDir) }

  var ranges: [(Int, Int)] = []
  let base = totalFrames / jobs, rem = totalFrames % jobs
  var s = 0
  for j in 0..<jobs {
    let count = base + (j < rem ? 1 : 0)
    let e = s + count
    if count > 0 { ranges.append((s, e)) }
    s = e
  }

  let strip: Set<String> = ["--jobs", "--out", "--frame-start", "--frame-end", "--root"]
  var baseChildArgs: [String] = []
  var i = 0
  let raw = args.raw
  while i < raw.count {
    let a = raw[i]
    if a == "--noaudio" { i += 1; continue }
    if strip.contains(a) { i += 2; continue }
    baseChildArgs.append(a); i += 1
  }

  var procs: [Process] = []
  var segURLs: [URL] = []
  var errLogs: [URL] = []
  for (idx, r) in ranges.enumerated() {
    let seg = tmpDir.appendingPathComponent("seg\(idx).mp4")
    segURLs.append(seg)
    let childArgs = baseChildArgs + ["--out", seg.path, "--noaudio", "--frame-start", "\(r.0)", "--frame-end", "\(r.1)", "--root", root.path]
    let errURL = tmpDir.appendingPathComponent("job\(idx).log")
    errLogs.append(errURL)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    let errHandle = try FileHandle(forWritingTo: errURL)
    let p = Process()
    p.executableURL = selfExe
    p.arguments = ["video"] + childArgs
    p.standardOutput = errHandle
    p.standardError = errHandle
    try p.run()
    procs.append(p)
  }

  for p in procs { p.waitUntilExit() }
  let failedIdx = procs.enumerated().filter { $0.element.terminationStatus != 0 }.map { $0.offset }
  if !failedIdx.isEmpty {
    let logs = failedIdx.map { i -> String in
      let s = (try? String(contentsOf: errLogs[i], encoding: .utf8)) ?? ""
      return "job\(i) (exit \(procs[i].terminationStatus)): \(s)"
    }.joined(separator: "\n")
    throw EncoderError.failed("--jobs \(jobs): \(failedIdx.count) child process(es) failed:\n\(logs)")
  }

  let listFile = tmpDir.appendingPathComponent("concat.txt")
  let listContent = segURLs.map { "file '\($0.path)'" }.joined(separator: "\n")
  try listContent.write(to: listFile, atomically: true, encoding: .utf8)

  let tmpFinal = out.deletingLastPathComponent().appendingPathComponent(out.lastPathComponent + ".tmp")
  if encoderName == "x264" && !noAudio {
    let concatOut = tmpDir.appendingPathComponent("concat.mp4")
    try runFFmpeg(["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listFile.path, "-c", "copy", concatOut.path])
    let audioFile = root.appendingPathComponent("audio/pdoom.mp3")
    try runFFmpeg(["-y", "-loglevel", "error", "-i", concatOut.path, "-ss", String(from), "-t", String(to - from), "-i", audioFile.path,
                   "-c:v", "copy", "-c:a", "aac", "-b:a", "320k", "-shortest", "-movflags", "+faststart", "-f", "mp4", tmpFinal.path])
  } else {
    try runFFmpeg(["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listFile.path, "-c", "copy", "-movflags", "+faststart", "-f", "mp4", tmpFinal.path])
  }

  try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
  if FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
  try FileManager.default.moveItem(at: tmpFinal, to: out)
  print("wrote \(out.path) (\(totalFrames) frames, \(jobs) jobs, \(encoderName))")
}

func resolvedSelfExecutable() -> URL {
  let arg0 = CommandLine.arguments[0]
  if arg0.hasPrefix("/") { return URL(fileURLWithPath: arg0) }
  return URL(fileURLWithPath: arg0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
}

func runFFmpeg(_ ffmpegArgs: [String]) throws {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  p.arguments = ["ffmpeg"] + ffmpegArgs
  p.standardOutput = FileHandle.standardError
  p.standardError = FileHandle.standardError
  try p.run()
  p.waitUntilExit()
  if p.terminationStatus != 0 { throw EncoderError.failed("ffmpeg exited \(p.terminationStatus) for args \(ffmpegArgs)") }
}
