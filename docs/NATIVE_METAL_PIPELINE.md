# Native renderer (Metal): Rust and Swift ports

## At a glance

The offline export renders every frame in headless Chrome (WebGL through ANGLE on Metal) and ships the pixels over a WebSocket and a pipe to ffmpeg: three memory copies per frame, one of them a GPU readback, and a 9–10 GB process footprint at 4K. The native renderer replaces the browser, three.js and TypeScript in the render path with one program that draws with Metal and hands frames to the encoder in shared memory. The song data (`data/*.json`), the fonts, the look (shaders, post, motion blur) and the two output formats stay the same, and the browser renderer stays as the pixel reference until every scene matches it.

## Two competing ports

The same renderer is written twice and measured against the same references:

| Branch | Checkout | Host language | Metal bindings |
|---|---|---|---|
| `native-rust` | this repository (`native/rust/`) | Rust | `objc2-metal` (the older `metal` crate is deprecated) |
| `native-swift` | worktree `../pdoom-video.native-swift` (`native/swift/`) | Swift | Metal, Core Video, AVFoundation |
| `native-base` | shared base of both | — | shaders, checks, this document |

Both ports load the same shaders from `native/shaders/`, so a speed difference measures the host code, not two shader translations. Changes to shared files land on `native-base` and are merged into both branches.

## What each port contains

A headless command-line renderer with:

1. **Data**: `data/audio.json` (beats, bars, envelopes stored as 32-bit floats, onset pulses) and `data/lyrics.json` (lines, words, smart quotes) with the same lookups as `app/src/engine/audio.ts` and `lyrics.ts`, in 64-bit arithmetic like JavaScript.
2. **Timeline**: the cuts of `app/src/timeline.ts`, computed from the data (not hard-coded times).
3. **Engine**: render any song time `t` as a pure function (all scenes are stateless); composite overlapping entries; motion blur with a fixed sub-frame count or the adaptive 4·3^k schedule (`ternaryOffsets`, the error estimate, `POST_U`, SS_TAP cycling), exactly as `Engine.render`.
4. **Post**: bloom pyramid, halation, chromatic aberration, shoulder, invert, flash, vignette, fade, grain and dither (`native/shaders/post.metal`).
5. **2D layers**: what the scenes draw with Canvas2D (text, stroke fonts, shapes), rendered natively and uploaded as the three.js `Layer2D` textures are: straight alpha, sRGB-decoded on sampling, row 0 at the bottom.
6. **Scenes**: one port per plate in `app/src/scenes/`, starting with `hook` (four timeline entries, typography-heavy, no meshes).
7. **Output**: HEVC through AVFoundation from IOSurface-backed pixel buffers (hardware encoder required), or x264 through ffmpeg with the browser path's settings (`-c:v libx264 -preset slow -crf 16 -tune grain -x264-params aq-mode=3 -pix_fmt yuv420p`), plus the song's audio.

## Porting order

Every scene draws text on a Canvas2D layer, and nearly every shader needs screen derivatives (`fwidth`), so the 2D layer and fragment passes come first. No scene is stateful or handles its own transition, and the timeline entries touch without overlapping, so the engine's crossfade never runs. The scenes are grouped by what they need beyond that core:

| Order | Scenes | What they add |
|---|---|---|
| 0 | engine | Canvas2D equivalent (text with letter spacing, stroke text, clip incl. even-odd, dashes, gradients, shadow blur, `lighter`/`difference`/`destination-out`), font layout, `LineBatch`, Compositor `normal`/`replace`/`add`, post, HUD |
| 1 | hook, prompt, dense | text-heavy 2D with one or two fullscreen shaders; dense adds a mask built from `getImageData` |
| 2 | open, room, fuse | 2D line art (100k–340k `LineBatch` segments), stroke fonts, glyph outlines, sparks; fuse adds a ribbon mesh and a half-resolution glow layer |
| 3 | bureau, leftturn, ascent | large canvases (up to 4096²) sampled through camera shaders, channel-coded layers, intermediate render targets, multi-tap motion blur |
| 4 | loss, stack, spacetime | three.js cameras with depth: a vertex-displaced plane, instanced boxes with fog, 3D lines depth-tested against meshes, a mipmapped canvas sampled with derivatives |
| 5 | paperclips, shoggoth, ilya | fullscreen ray marching (128–160 steps), supersample-tap cycling; shoggoth adds a two-target float G-buffer |
| 6 | loom, outro | built from other scenes: loom renders the ilya room, outro plays open backwards over the plate JPEGs |

Shared shaders on `native-base`: engine (`common`, `post`, `engine`, `diagnostic`, `lines`) and scenes hook, prompt and dense. All compile at scales 1 and 2; each is verified only when a port renders it against Chrome.

## Conventions every port follows

- **Orientation**: textures keep WebGL's row order (row 0 = image bottom), so `position.y`/`gid.y` equal WebGL's `gl_FragCoord.y − 0.5` and hashes of pixel coordinates match. Vertex shaders negate clip-space y. Only the final pass (`post_final` with `flipRows = 1`) or the diagnostic pattern writes top-down rows for the encoder.
- **Depth**: three.js projection matrices produce WebGL clip z in [−w, w]; Metal wants [0, w]: use z' = (z + w) / 2.
- **Precision**: render targets are RGBA16Float like three.js `HalfFloatType`; the motion-blur sums are RGBA32Float; the averaged frame is stored as RGBA16Float before post, as `avgRT` is.
- **Shader compilation**: runtime (`makeLibrary(source:)`; the offline `metal` tool is not installed), `common.metal` first, then every other `.metal` file under `native/shaders/` sorted by relative path, with `mathMode = .safe` and the macro `PDOOM_SCALE` (1 at 1080p, 2 at 4K). `swift native/shaders/check.swift` compiles them the same way.
- **Porting GLSL**: the rules are at the top of `native/shaders/common.metal` (`mod` → `gmod`, `atan` → `atan2`, `texture` → `sample(lin, …)`, derivatives only in fragment functions).

## Diagnostic pattern

A synthetic image that makes output-path mistakes visible after lossy encoding (`native/shaders/diagnostic.metal`, same definition in `native/verify/verify.ts`). Logical px (1920×1080 layout, scaled by `PDOOM_SCALE`), y down:

| Region | Content | Catches |
|---|---|---|
| 192×192 corners | red top-left, green top-right, blue bottom-left, yellow bottom-right | channel swaps, flips |
| x 256–1664, y 440–520 | grey ramp, level = ⌊(x − 256S)·256 / 1408S⌋ | range and matrix errors, stride |
| x 256–1664, y 560–640 | 1-physical-px white lines every 8 px on black | stride and scaling errors |
| x 256–1664, y 680–760 | 16-px white bar at 256 + (8·frame mod 1392) | frame order (visually) |
| y 800–864 | white guard at 384, 16 id bits from 448 (MSB first, 64 px each), black guard at 1472 | frame order, dropped frames |
| elsewhere | grey 128 | |

## Checks

All from the repository root. The verifier decodes with ffmpeg and shares no code with either port.

```sh
bun native/verify/verify.ts selftest                       # the verifier catches flips, swaps and dropped frames
bun native/verify/verify.ts diagnostic OUT.mp4 --frames 120 --fps 60 --scale 1
bun native/verify/verify.ts compare native.png chrome.png --side side.png --diff diff.png
bun native/verify/reference.ts > out/native-ref/reference.json   # TS values: timeline, audio features, lyric lookups
bun native/verify/capture-post.ts --scale 1 --t 22.45,81.15      # post inputs and Chrome's output for those frames
bun app/scripts/render.ts stills --only hook1 --t 22.6,23.4 --out out/native-ref/hook1   # scene references
swift native/shaders/check.swift                           # shared shaders compile at scales 1 and 2
```

`capture-post.ts` writes, per time, the averaged HDR frame and the HUD layer (RGBA16Float, row 0 = bottom), the post parameters, and Chrome's final frame (PNG, top-down). A port's post chain passes when it turns the first two into the third within ±2 levels (grain and dither included: both run on the same GPU with safe math).

Scene parity is judged on stills rendered by both renderers at the same times and settings: first with one sub-frame (geometry, text, colour), then with motion blur. Exact equality is not expected where Chrome's Canvas2D rasterises text differently from the native 2D renderer; those differences are reported with side-by-side images, not hidden by loose thresholds.

Timings come from `hyperfine` and cover the whole export, including encoder drain and file finalisation.

## Status

| Milestone | Rust | Swift |
|---|---|---|
| Output path: diagnostic pattern → HEVC (hardware) and x264, verified | not started | not started |
| Data, timeline, engine, post, motion blur | not started | not started |
| Scene `hook` against Chrome stills | not started | not started |
| Remaining scenes | not started | not started |
| Full video, both formats, timed against Chrome | not started | not started |

Open questions: the Chrome path converts RGB to YUV with swscale's default BT.601 matrix and writes no colour tags, while AVFoundation writes BT.709 tags; the master's colour handling must be decided before cutover. Canvas2D text on the GPU vs the CPU is decided per port by measurement: at 4K with up to 324 sub-frames per frame, re-rasterising text on the CPU for every sub-frame may dominate.
