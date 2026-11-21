# pdoom-native (Swift port)

Native Swift + Metal renderer for the P(doom) music video, replacing headless-Chrome/three.js in the
render path. See `docs/NATIVE_METAL_PIPELINE.md` (repo root) for the design this follows; this file
tracks build/run instructions and this port's actual, measured status.

## Build

```sh
swift build -c release --package-path native/swift
```

Requires macOS 26+, Swift 6.4+/Xcode. Shaders under `native/shaders/` are compiled at process start
with `MTLDevice.makeLibrary(source:)` (no offline `.metal` compiler is used or required).

The package is a `PdoomCore` library (data layer, shader compilation, encoders, post chain — everything
reusable and unit-testable) plus a thin `pdoom-native` executable (CLI parsing and dispatch only).

```sh
swift test --package-path native/swift    # PdoomCoreTests: data layer vs reference.json (see M2 below)
```

## Run

```sh
BIN=native/swift/.build/out/Products/Release/pdoom-native   # swift build --show-bin-path prints the exact path
$BIN diagnostic --frames 120 --fps 60 --scale 1 --encoder x264 --out out.mp4
$BIN diagnostic --frames 120 --fps 60 --scale 1 --encoder hevc --out out.mp4
$BIN post-fixture --fixtures out/native-ref/post-1x --out out/native-swift/post-1x
$BIN stills --only hook1 --t 22.6,23.4 --out out/native-swift/hook1-stills
$BIN video --from 22.509 --to 24.328 --only hook1 --samples auto --shutter 0.2 --encoder hevc --out out.mp4
```

All four subcommands (`diagnostic`, `post-fixture`, `stills`, `video`) work; `video`'s HEVC path muxes no
audio yet (x264 does) — see Known gaps.

## What works (M1: output path)

Both encoders render `diag_pattern` (`native/shaders/diagnostic.metal`) per frame and pass
`bun native/verify/verify.ts`:

- **x264**: spawns `ffmpeg` and pipes tightly-packed top-down BGRA frames to `-f rawvideo -pix_fmt bgra`,
  with render.ts's exact output args (`-c:v libx264 -preset slow -crf 16 -tune grain -x264-params
  aq-mode=3 -pix_fmt yuv420p -movflags +faststart`). No audio path yet (added with `video` in M3).
- **hevc**: `AVAssetWriter` fed from an IOSurface-backed, Metal-compatible `CVPixelBufferPool` via
  `AVAssetWriterInputPixelBufferAdaptor`; `CVMetalTextureCacheCreateTextureFromImage` wraps each pooled
  `CVPixelBuffer` as an `MTLTexture` for the compute kernel.
  `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true` is set in
  `AVVideoEncoderSpecificationKey`; bitrate 150 Mbit/s; codec tag `hvc1` (confirmed by `ffprobe`).
  **This is the deprecated adaptor, not the macOS 26 `AVAssetWriterInput.PixelBufferReceiver` the brief
  asks for** — see "M3: the HEVC deadlock" below for why; M1's own diagnostic-pattern acceptance tests
  (below) originally passed against the new API too (it is only real, many-GPU-round-trip scene content
  that reproduces the hang), and still pass unchanged against the adaptor.
- Both paths are correct-but-serial for now: each frame's GPU work is committed and
  `waitUntilCompleted()` before the frame is handed off to the encoder (HEVC) or read back (x264).
  Bounded in-flight comes from the pixel-buffer pool (HEVC) or the ffmpeg pipe (x264), not an index
  modulo N. Overlapping GPU work with encoder drain is M4's job.
- Forced failures exit nonzero and leave no output file: an unwritable output directory (tested for both
  encoders) and ffmpeg killed mid-run (x264; required ignoring `SIGPIPE` and switching
  `FileHandle.write(_:)` → the throwing `write(contentsOf:)`, since the non-throwing call raises an
  uncatchable `NSException` on a dead pipe — see git log for the exact fix).

### Verified commands and results

```
bun native/verify/verify.ts selftest                                                          → PASS
$BIN diagnostic --frames 120 --fps 60 --scale 1 --encoder x264 --out out/native-swift/diag_x264_1x.mp4
bun native/verify/verify.ts diagnostic out/native-swift/diag_x264_1x.mp4 --frames 120 --fps 60 --scale 1   → PASS
$BIN diagnostic --frames 120 --fps 60 --scale 1 --encoder hevc --out out/native-swift/diag_hevc_1x.mp4
bun native/verify/verify.ts diagnostic out/native-swift/diag_hevc_1x.mp4 --frames 120 --fps 60 --scale 1   → PASS
$BIN diagnostic --frames 60  --fps 60 --scale 2 --encoder x264 --out out/native-swift/diag_x264_2x.mp4
bun native/verify/verify.ts diagnostic out/native-swift/diag_x264_2x.mp4 --frames 60 --fps 60 --scale 2    → PASS
$BIN diagnostic --frames 60  --fps 60 --scale 2 --encoder hevc --out out/native-swift/diag_hevc_2x.mp4
bun native/verify/verify.ts diagnostic out/native-swift/diag_hevc_2x.mp4 --frames 60 --fps 60 --scale 2    → PASS
```

`ffprobe` (codec / profile / tag / colour):

| file | codec | profile | tag | pix_fmt | color_range | primaries/transfer/space |
|---|---|---|---|---|---|---|
| diag_x264_1x | h264 | High | avc1 | yuv420p | unknown | unknown/unknown/unknown |
| diag_hevc_1x | hevc | Main | hvc1 | yuv420p | tv | unknown/unknown/unknown |
| diag_x264_2x | h264 | High | avc1 | yuv420p | unknown | unknown/unknown/unknown |
| diag_hevc_2x | hevc | Main | hvc1 | yuv420p | tv | unknown/unknown/unknown |

Neither path writes explicit colour-primaries/transfer tags (we don't set any `AVVideoColorPropertiesKey`
in the HEVC output settings); HEVC does get a `tv` (limited) range tag from AVFoundation's defaults.
This still leaves the doc's "colour handling before cutover" question open — it is not simply "AVFoundation
always writes BT.709 primaries/transfer", at least not with the output settings used here.

`hyperfine --runs 3` (M4 note: no other GPU load was running during these three runs; the coordinator's
brief asks to record `procs --sortd cpu` and call numbers provisional once the Rust port may be using the
GPU concurrently — recorded below for this run only):

| case | mean | min | max |
|---|---|---|---|
| x264, 1080p, 120 frames | 529.6 ms ± 8.9 ms | 521.2 ms | 538.9 ms |
| hevc, 1080p, 120 frames | 676.2 ms ± 2.3 ms | 673.8 ms | 678.3 ms |
| x264, 4K, 60 frames | 1.363 s ± 0.150 s | 1.192 s | 1.472 s |
| hevc, 4K, 60 frames | 1.150 s ± 0.014 s | 1.136 s | 1.163 s |

These are `diag_pattern`-only (no engine/post/scene work), so they measure the output path, not a real
frame's GPU cost; x264's wall time includes libx264's own encode cost (`-preset slow`), which is why it is
slower than HEVC hardware encode per frame at 1080p despite HEVC's async pipeline having more moving parts.

## What works (M2: data layer and post chain)

- **Data layer**: `PdoomCore/AudioData.swift`, `Lyrics.swift`, `Smart.swift`, `Timeline.swift` are
  line-for-line ports of `app/src/engine/audio.ts`, `lyrics.ts`, `type.ts`'s `smart()`, and
  `app/src/timeline.ts`. Envelopes are stored as `Float` (matching the TS `Float32Array`s) but every
  lookup computes in `Double`, matching JS's numbers.
- **Post chain**: `PdoomCore/PostRenderer.swift` dispatches `native/shaders/post.metal`'s
  `post_prefilter` / `post_down` / `post_up` / `post_final` in the sequence documented in that file's
  header (bloom pyramid at fixed logical resolution regardless of output scale, then the final
  composite: CA, bloom, halation, HUD blend, tone shoulder, invert, flash, vignette, fade, sRGB encode,
  grain, dither). `PostParams` mirrors `post.ts`'s `PostParams`/`DEFAULT_POST`.
- **`post-fixture`**: loads a fixture's `.hdr.f16`/`.hud.f16` (raw RGBA16Float, row 0 = bottom) and
  `.json` (`PostParams` + time), runs the chain, and writes `<name>.final.png` (top-down, `flipRows: 1`).

### Verified commands and results

```
swift test --package-path native/swift
  → dataLayerMatchesReference(): PASS — every one of reference.ts's 22 timeline entries (start/end/
    params/maxSamples), both lyrics counts, 40 timeOfBeat samples, and beatAt/barAt/sample()/env()/
    lineAt/wordAt at all 3198 of its sample times, within 1e-9. (lyrics text separately spot-checked:
    all 46 smart()-quoted lines byte-identical to the TS engine's own output.)

$BIN post-fixture --fixtures out/native-ref/post-1x --out out/native-swift/post-1x   (11 frames, 1080p)
$BIN post-fixture --fixtures out/native-ref/post-2x --out out/native-swift/post-2x   (2 frames, 4K)
bun native/verify/verify.ts compare <ref>.final.png <ours>.final.png --tol 2 --diff d.png --side s.png
```

| fixture (1x) | max | mean | PSNR |
|---|---|---|---|
| t004.664 | 3 | 0.000 | 85.3 dB |
| t016.150 | 2 | 0.000 | 81.8 dB |
| t022.450 | 1 | 0.000 | 88.6 dB |
| t025.650 | 2 | 0.000 | 86.2 dB |
| t027.055 | 1 | 0.001 | 79.8 dB |
| t059.553 | 2 | 0.000 | 94.3 dB |
| t081.150 | 1 | 0.000 | 96.0 dB |
| t095.915 | 3 | 0.000 | 96.2 dB |
| t119.777 | 3 | 0.001 | 80.3 dB |
| t140.500 | 2 | 0.001 | 79.5 dB |
| t148.440 | 1 | 0.000 | 98.2 dB |
| 2x t022.450 | 1 | 0.000 | 86.5 dB |
| 2x t081.150 | 1 | 0.000 | 94.9 dB |

Target from the brief is max ≤ 2 levels; 3 of the 11 1080p fixtures reach max 3 (one level over). I
looked at the actual pixels (not just the stat) before accepting this: `t004.664` has 18 pixels total
(out of 2,073,600) at ±2 or ±3, e.g. `(648,470)` ref `[139,59,39]` vs ours `[141,59,39]` — single-channel,
scattered across bloom highlights and HUD-panel edges, mean abs error 0.000-0.001, PSNR 79.5-98.2 dB. This
is the signature of float32 rounding-boundary disagreement between Chrome/ANGLE-Metal's GLSL compiler and
Metal's native compiler evaluating the same grain/dither hash expression, not a structural or algorithmic
difference (a side-by-side of `t081.150` — bloom glow, HUD table text, grid lines — is visually identical).
I did not loosen the target or touch the shared shader for this; both `post-2x` (4K) fixtures are within
target (max 1), which is consistent with a last-bit rounding effect rather than a bug that scale would
also expose.

## What works (M3: engine core + hook scene)

- **Engine**: `PdoomCore/Engine.swift` composites active timeline entries (crossfade via `comp_xfade`
  when overlapping; a dim red clear, matching `engine.ts`'s own fallback, for a scene not yet ported),
  drives the HUD and post chain, and — via `PdoomCore/MotionBlur.swift` — the fixed and adaptive
  motion-blur accumulation (`accum_add_sample`/`merge`/`average`/`error`/`max`), reusing the
  `ternaryOffsets`/ladder math from M2 and clamping sub-frame time at 0, exactly as `Engine.render`.
- **`hook` scene** (`PdoomCore/Scenes/Hook.swift`, `HookCompRenderer.swift`, `Scenes/Motifs.swift`):
  a close line-for-line port of `app/src/scenes/hook.ts` (all 4 variants) and the parts of `hud.ts`
  it touches. 2D drawing goes through `PdoomCore/Canvas2D.swift`, a `CGContext`-backed Canvas2D shim
  (`FontRegistry.swift` loads the app's static TTFs directly as `CGFont`/`CTFont` — no OS font
  registration; `TextLayout.swift` gets per-glyph kerned positions from `CTLine`, then adds tracking
  exactly as `type.ts`'s `layout()` does). `stills` and `video` both work end to end.
- Per M4's shape-now request: `Frame` is a plain `Sendable` struct, `Scene.render` takes a `Frame` and
  writes into a texture with no shared mutable state visible to the caller, and Hook's own per-sub-frame
  work (2D layer draw + `hook_comp` uniform prep) has no dependency on other sub-frames — see Known gaps
  for what M4 itself still needs.

### Verified: stills, single sub-frame

`$BIN stills --only hook1,hook2,hook3,hook4 --t <16 Chrome reference times> --out out/native-swift/hook/s1`,
compared with `bun native/verify/verify.ts compare --tol 2`, against
`/Users/martinfan/devv/pdoom-video/out/native-ref/hook/s1/`:

| t | hook | max | mean | PSNR |
|---|---|---|---|---|
| 22.559 | 1 | 57 | 0.009 | 53.9 dB |
| 23.146 | 1 | 153 | 0.174 | 41.4 dB |
| 23.782 | 1 | 155 | 0.103 | 42.0 dB |
| 24.278 | 1 | 158 | 0.242 | 42.6 dB |
| 58.921 | 2 | 42 | 0.003 | 61.3 dB |
| 59.348 | 2 | 72 | 0.024 | 53.1 dB |
| 59.826 | 2 | 62 | 0.037 | 51.7 dB |
| 60.185 | 2 | 151 | 0.088 | 43.9 dB |
| 95.283 | 3 | 162 | 0.010 | 48.9 dB |
| 95.71 | 3 | 185 | 0.067 | 44.5 dB |
| 96.187 | 3 | 215 | 0.127 | 41.0 dB |
| 96.546 | 3 | 190 | 0.122 | 41.3 dB |
| 124.372 | 4 | 156 | 0.247 | 40.5 dB |
| 124.958 | 4 | 76 | 0.108 | 48.2 dB |
| 125.595 | 4 | 80 | 0.110 | 51.1 dB |
| 126.09 | 4 | 196 | 0.913 | 34.3 dB |

Every side-by-side and diff image was read (not just the stats). All differences are confined to text
glyph edges (AA), never layout, colour, size, or missing elements — this held from the simplest frame
(a single hairline, `t=22.559`) through the most extreme one (`t=126.09`, hook4's number squeezed into a
2160-px-wide, ~3-px-tall thread: max 196 but the two images are visually identical; the extreme vertical
squash means any 1-px AA difference touches a huge fraction of that thin strip's pixels, which is why the
stat looks worse than the picture). Mean error stays under 0.25/255 in every case. This matches the
brief's expectation exactly: "small Canvas2D-vs-CoreText AA differences" are the only difference found.

### Verified: stills, adaptive (`--samples auto --shutter 0.2`)

Sub-frame counts, ours vs Chrome's (`cd app && bun scripts/render.ts stills --only hook1,hook2,hook3,hook4
--t <times> --samples auto --shutter 0.2`):

| t | Chrome | ours | | t | Chrome | ours |
|---|---|---|---|---|---|---|
| 22.559 | 12 | 12 | | 95.71 | 12 | 12 |
| 23.146 | 108 | 108 | | 96.187 | 36 | 12 |
| 23.782 | 36 | 12 | | 96.546 | 12 | 12 |
| 24.278 | 12 | 12 | | 124.372 | 108 | 108 |
| 58.921 | 12 | 12 | | 124.958 | 108 | 108 |
| 59.348 | 36 | 12 | | 125.595 | 36 | 12 |
| 59.826 | 36 | 12 | | 126.09 | 324 | 108 |
| 60.185 | 324 | 324 | | 95.283 | 12 | 12 |

10 of 16 match exactly; the other 6 all stop *earlier* than Chrome (never later). Pixel error at these
times is the same order of magnitude as the s1 table above regardless of whether the count matched
(e.g. `t=126.09`: max 203, mean 0.764 — close to the s1 numbers), so the extra sub-frames Chrome takes
are not fixing a visible problem in ours.

I root-caused this rather than waving at "AA noise": the coordinator asked for the per-step error values
(`engine.lastErrors`/`lastSamples`, same field names, same `err = sampleError(n)/2` formula). At
`t=22.559` (counts match, 12 = 12) the first-step error is 0.252 here vs Chrome's 0.247 — a near-exact
match, confirming `ternaryOffsets`, `POST_U`, the error pass (`B = 2*scale`, 170x max-channel, R=16
max-reduce, /2) and the `t >= 0` clamp are all correct. At `t=23.782` (counts diverge, 12 vs 36) the
*same* first-step check gives 0.988 here vs Chrome's 5.03 — both numbers are within the same order of
magnitude as the tol=3 threshold, but on opposite sides of it. At that instant hook1 is mid-`slam()` on
"P(DOOM)" with the bounce already fully settled (`age` past `dur`), so the true scene motion within the
~3.3 ms shutter window is negligible on both sides; whichever renderer's own residual per-pixel noise
(here: CoreText's glyph rasterization; in Chrome: Skia's) happens to exceed the tol on its first check
decides whether the sampler stops at 12 or keeps going. This is a real, reproducible difference between
the two renderers' own anti-aliasing, not a bug in the ported schedule/math — and it is consistent with
the s1 table finding that AA is the *only* category of difference found anywhere in this scene.

### The HEVC deadlock, and dropping back to the deprecated adaptor

Driving a real, multi-GPU-round-trip scene (not just `diag_pattern`) through
`AVAssetWriterInput.PixelBufferReceiver`'s async `append` reproducibly deadlocked: a 90-frame hook1 clip
(`--samples 1`, no motion blur — the simplest real-content case) stalled forever at the same frame (70)
on every attempt, with progress logging (`PDOOM_DEBUG_PROGRESS=1`, unbuffered `stderr` writes) showing
the exact same stopping point each time. The coordinator's `sample PID 1` while it hung showed:

- the main thread idle in `swift_task_asyncMainDrainQueue` → `CFRunLoopRun` → `mach_msg` (no async task
  runnable — the `await` on `receiver.append` never resumed);
- both `com.apple.coremedia.mediaprocessor.videocompression` threads and the
  `com.apple.coremedia.formatwriter.qtmovie` thread idle in `_pthread_cond_wait` (the hardware encoder
  and the file writer both have nothing queued and are waiting on a signal that never comes).

The coordinator's audio/video-interleaving hypothesis for this shape of hang didn't apply directly (this
writer has no audio input at all), so as a first fix I unified every GPU write for a frame onto the
*receiver's own* command queue (passing `HEVCWriter`'s queue into `Engine.render`, instead of the engine
using a separate one of its own) in case cross-queue synchronization was hiding the frame's completion
from the encoder's readiness tracking. The hang reproduced identically — same frame, same symptom — so
that wasn't it either. Given a full milestone's worth of time already spent on this one API and a
concrete, working alternative, I moved the HEVC path onto `AVAssetWriterInputPixelBufferAdaptor` (still
fully available, only deprecated) and its synchronous `isReadyForMoreMediaData`/`append(_:withPresentationTime:)`:
the *identical* 90-frame case (and the full 109-frame `hook1` clip with `--samples auto`, and M1's own
120-frame/60-frame-at-4K diagnostic acceptance tests) all complete correctly with this change and no
other. This is the brief's explicit "if you cannot, say why" case: the new API is real and I exercised it
correctly for simple content (M1's diagnostic tests passed against it originally), but it has a
reproducible limitation this port hit as soon as real per-frame GPU work was involved, and the deprecated
adaptor does not share it.

### Verified: `video`, hook1 clip

`$BIN video --from 22.509 --to 24.328 --only hook1 --samples auto --shutter 0.2 --encoder x264|hevc --out …`
(109 frames, matching the timeline's own `hook1` window) produced a valid file with both encoders
(`ffprobe`: h264/1920x1080/60fps and hevc/1920x1080/60fps respectively, both exactly 1.8167 s = 109/60 s).
A middle frame, decoded and inspected, shows real accumulated motion blur (trailing streaks on "UPPING",
per-glyph velocity stretch) composited correctly with the guides/annotations HUD-style overlay.

hyperfine (`--runs 1`, this being a long single job per the brief) against
`cd app && bun scripts/render.ts video --from 22.509 --to 24.328 --only hook1 --samples auto --shutter 0.2`.
`procs --sortd cpu` immediately before the x264 run showed the Rust port's own `ffmpeg` (x264) benchmark
running concurrently (`out/native-rust/hyperfine/hf_x264.tmp.mp4`), so **that one number is provisional**;
`procs` showed no contention before the hevc or Chrome runs:

| case | wall time | user | system |
|---|---|---|---|
| native x264 (provisional: Rust port's ffmpeg ran concurrently) | 44.9 s | 71.1 s | 2.5 s |
| native hevc | 42.7 s | 30.8 s | 1.5 s |
| Chrome (`render.ts video`, same clip/args) | 15.3 s | 60.1 s | 9.5 s |

Chrome is close to 3x faster here, even though its `user` time is comparable to (or less than, vs. hevc)
ours — it's spreading the same or more CPU work across more wall-clock-parallel threads (WebGL command
submission, V8, and its own Canvas2D/text rasterization all overlap), while this port renders every
sub-frame's Canvas2D layer, uploads it, and runs the engine/post passes fully serially, one sub-frame at
a time, on a single thread. This is exactly the risk the brief flagged: "if [2D raster cost] dominates,
note it." Two concrete, unoptimized costs in the current code likely explain most of the gap: (1) every
sub-frame re-rasterizes the *entire* 1920x1080 (or 3840x2160) Canvas2D layer with CoreText, even when
only a small region actually changed; (2) `Canvas2D.flippedRGBA()` converts premultiplied-to-straight
alpha with a scalar Swift loop, per pixel, with a division per channel, again once per sub-frame at full
resolution. Neither is fixed here (M3 is functional correctness, not performance), but both are prime
M4/optimization targets, and M4's parallel CPU-prep design (below) attacks exactly this serialization.

### Memory (hardware target: this M4 Pro, ≤6 GB peak RSS at 4K with motion blur)

`/usr/bin/time -l` (`maximum resident set size` / `peak memory footprint`), `stills --scale 2`:

| case | RSS | footprint |
|---|---|---|
| 1 frame, `--samples auto` (108 sub-frames) | 220 MB | 686 MB |
| 2 frames, `--samples auto` (12 + 108 sub-frames) | 284 MB | 840 MB |
| 1 frame, `--samples 324` (forced worst case) | 219 MB | 582 MB |

All well under the 6 GB budget (with a wide margin — around 25x under, even forcing the worst-case 324
sub-frames at 4K), since nothing here is buffering multiple frames at once yet; the ceiling is more
likely to matter once M4 actually pipelines several frames' textures concurrently.

## Known gaps

- **HEVC audio muxing** is not wired up (`AVAssetWriter` has a video track only); x264 has full audio
  support (`--noaudio` to disable, matching render.ts).
- **HEVC uses the deprecated `AVAssetWriterInputPixelBufferAdaptor`, not the macOS 26
  `AVAssetWriterInput.PixelBufferReceiver`** the brief asks for — see "The HEVC deadlock" above for the
  reproduced hang and why this port dropped back.
- **CPU-bound 2D raster cost dominates real scene renders**: native is ~3x *slower* than Chrome on the
  hook1 clip (see the hyperfine table above) despite comparable or less `user` CPU time — Chrome overlaps
  its own text rasterization/WebGL submission/compositing across threads, while every sub-frame here
  runs fully serially on one thread (Canvas2D draw → `flippedRGBA()`'s scalar unpremultiply loop → upload
  → engine/post GPU passes → wait). This is the exact risk the brief flagged ("if [2D raster cost]
  dominates, note it") and is M4's main target, not fixed here.
- **Adaptive sub-frame count**: 6 of 16 checked times pick fewer sub-frames than Chrome (never more) —
  see the root-cause above; not treated as a bug, but flagged for the coordinator's attention since it's
  a genuine, measured difference in the two renderers' own noise floors.
- **`--only` with more than one active scene / a scene not yet ported**: crossfade and the red-clear
  fallback are implemented but only exercised by construction (`--only` normally isolates one scene);
  not separately stress-tested.
- **M4** (multi-threaded pipeline) is not implemented yet — see the coordinator's added milestone.
  `Frame`/`PostOverrides`/`Scene.render` are already Sendable-friendly value types with no captured
  mutable state (see "What works: M3" above), which is the seam M4 needs; the actual TaskGroup-based
  parallel CPU prep, stage overlap, `--threads N`, and GPU-idle measurement are not built. Given the CPU
  raster cost finding above, M4 should help substantially: it is the serialization M4 is meant to remove.
