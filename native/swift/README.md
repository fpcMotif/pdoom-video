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

## Run

```sh
BIN=native/swift/.build/out/Products/Release/pdoom-native   # swift build --show-bin-path prints the exact path
$BIN diagnostic --frames 120 --fps 60 --scale 1 --encoder x264 --out out.mp4
$BIN diagnostic --frames 120 --fps 60 --scale 1 --encoder hevc --out out.mp4
```

`post-fixture`, `stills` and `video` are accepted on the command line (same shape as the brief/CLI) but
are not implemented yet — see Known gaps.

## What works (M1: output path)

Both encoders render `diag_pattern` (`native/shaders/diagnostic.metal`) per frame and pass
`bun native/verify/verify.ts`:

- **x264**: spawns `ffmpeg` and pipes tightly-packed top-down BGRA frames to `-f rawvideo -pix_fmt bgra`,
  with render.ts's exact output args (`-c:v libx264 -preset slow -crf 16 -tune grain -x264-params
  aq-mode=3 -pix_fmt yuv420p -movflags +faststart`). No audio path yet (added with `video` in M3).
- **hevc**: `AVAssetWriter` fed via the macOS 26 `AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)`
  / `AVAssetWriterInput.PixelBufferReceiver` API (its `async append` backpressures instead of the
  deprecated `AVAssetWriterInputPixelBufferAdaptor`'s poll loop). The receiver's IOSurface-backed,
  IOSurface + Metal-compatible `CVPixelBufferPool` (`CVMutablePixelBuffer.Pool`) hands out
  `CVMutablePixelBuffer`s; `withUnsafeBuffer` exposes the legacy `CVPixelBufferRef` to
  `CVMetalTextureCacheCreateTextureFromImage`, which wraps it as an `MTLTexture` for the compute kernel.
  `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true` is set in
  `AVVideoEncoderSpecificationKey`; bitrate 150 Mbit/s; codec tag `hvc1` (confirmed by `ffprobe`).
- Both paths are correct-but-serial for now: each frame's GPU work is committed and
  `waitUntilCompleted()` before the frame is hand off to the encoder (HEVC) or read back (x264). Bounded
  in-flight comes from the pixel-buffer pool (HEVC) or the ffmpeg pipe (x264), not an index modulo N.
  Overlapping GPU work with encoder drain is M4's job.
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

## Known gaps

- **M2** (data/timeline/engine/post/motion blur/HUD) and **M3** (`hook` scene, CoreText 2D layers) are not
  implemented: `post-fixture`, `stills` and `video` exit with a clear "not implemented yet" error rather
  than silently producing wrong output.
- **M4** (multi-threaded pipeline) is not implemented — there is no scene/engine code yet to parallelize.
  `FrameRenderer` (the per-frame GPU callback) is already the seam M4 will parallelize CPU prep behind:
  it is a plain closure `(MTLTexture, Int, MTLCommandQueue) throws -> Void` with no shared mutable state
  captured, so a future scene-aware renderer can prepare sub-frame CPU work (Sendable value types) off
  the GPU-submission thread without changing this seam.
- HEVC audio muxing (`-c:a aac ... -shortest`) is not wired up for x264 either yet; both are silent,
  video-only outputs until the `video` subcommand is built in M3.
- `AVAssetWriterInput.PixelBufferReceiver` requires its `pixelBufferPool` to be read only after
  `writer.startWriting()`/`startSession(atSourceTime:)`; reading it right after
  `inputPixelBufferReceiver(for:pixelBufferAttributes:)` returns `nil` (undocumented — found by testing).
