#!/usr/bin/env bun
// Independent checks for the native renderers: decodes their output with ffmpeg and compares it with
// what it should be. It shares no code with the renderers it checks.
//   diagnostic: bun native/verify/verify.ts diagnostic VIDEO [--frames N] [--first 0] [--fps 60] [--scale 1]
//               checks size, frame count, timestamps and every decoded frame against the diagnostic
//               pattern (corners, ramp, lines, moving bar, frame id)
//   compare:    bun native/verify/verify.ts compare A B [--tol 2] [--diff out.png] [--side out.png]
//               [--max-mean X] [--min-psnr X]   images (anything ffmpeg decodes), same size
//   selftest:   bun native/verify/verify.ts selftest   encodes the pattern with ffmpeg, plus flipped,
//               channel-swapped and frame-dropped variants, and checks that only the good one passes
// Exit status 0 = pass, 1 = fail.
import { mkdirSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const argv = process.argv.slice(2);
const opt = (k: string, d?: string) => { const i = argv.indexOf(`--${k}`); return i >= 0 ? argv[i + 1] : d; };
const positional = argv.filter((a, i) => !a.startsWith('--') && !(i > 0 && argv[i - 1]!.startsWith('--')));

// ------------------------------------------------------------------ the diagnostic pattern
// Same definition as native/shaders/diagnostic.metal: 8-bit sRGB codes packed 0xRRGGBB, (x, y) physical
// px, y down.
export function diagColor(x: number, y: number, frame: number, S: number): number {
  const u = x / S, v = y / S, grey = (g: number) => g * 0x010101;
  if (u < 192 && v < 192) return 0xff0000;
  if (u >= 1728 && v < 192) return 0x00ff00;
  if (u < 192 && v >= 888) return 0x0000ff;
  if (u >= 1728 && v >= 888) return 0xffff00;
  const band = u >= 256 && u < 1664;
  if (band && v >= 440 && v < 520) return grey(Math.min(255, Math.floor(((x - 256 * S) * 256) / (1408 * S))));
  if (band && v >= 560 && v < 640) return grey(x % 8 === 0 ? 255 : 0);
  if (band && v >= 680 && v < 760) { const bx = 256 + ((8 * frame) % 1392); return grey(u >= bx && u < bx + 16 ? 255 : 0); }
  if (v >= 800 && v < 864) {
    if (u >= 384 && u < 448) return 0xffffff;
    if (u >= 1472 && u < 1536) return 0;
    if (u >= 448 && u < 1472) return grey((frame >> (15 - Math.floor((u - 448) / 64))) & 1 ? 255 : 0);
  }
  return 0x808080;
}

function diagFrame(frame: number, S: number, bgr = false, flip = false) {
  const W = 1920 * S, H = 1080 * S, out = new Uint8Array(W * H * 3);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const c = diagColor(x, flip ? H - 1 - y : y, frame, S), i = (y * W + x) * 3, r = c >> 16, b = c & 255;
    out[i] = bgr ? b : r; out[i + 1] = (c >> 8) & 255; out[i + 2] = bgr ? r : b;
  }
  return out;
}

// ------------------------------------------------------------------ ffmpeg helpers
async function probe(file: string) {
  const p = Bun.spawn(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
    'stream=codec_name,profile,width,height,pix_fmt,r_frame_rate,color_space,color_primaries,color_transfer,color_range:frame=pts_time',
    '-of', 'json', file], { stdout: 'pipe', stderr: 'pipe' });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  if (code !== 0) throw new Error(`ffprobe failed on ${file}: ${err.trim()}`);
  const j = JSON.parse(out);
  const s = j.streams?.[0];
  if (!s) throw new Error(`${file}: no video stream`);
  const [num, den] = String(s.r_frame_rate).split('/').map(Number);
  return { stream: s, fps: num! / (den || 1), pts: (j.frames ?? []).map((f: any) => +f.pts_time) as number[] };
}

/** Decodes a file to rgb24 frames of w x h, one callback per frame. Returns the frame count. */
async function decodeFrames(file: string, w: number, h: number, each: (px: Uint8Array, i: number) => void) {
  const p = Bun.spawn(['ffmpeg', '-v', 'error', '-i', file, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], { stdout: 'pipe', stderr: 'pipe' });
  const size = w * h * 3;
  let buf = new Uint8Array(size), fill = 0, n = 0;
  for await (const chunk of p.stdout as ReadableStream<Uint8Array>) {
    let off = 0;
    while (off < chunk.length) {
      const k = Math.min(size - fill, chunk.length - off);
      buf.set(chunk.subarray(off, off + k), fill);
      fill += k; off += k;
      if (fill === size) { each(buf, n++); buf = new Uint8Array(size); fill = 0; }
    }
  }
  const err = await new Response(p.stderr).text();
  if ((await p.exited) !== 0) throw new Error(`ffmpeg decode failed: ${err.trim()}`);
  if (fill) throw new Error(`${file}: trailing partial frame (${fill} of ${size} bytes)`);
  return n;
}

async function decodeImage(file: string) {
  const { stream } = await probe(file);
  let img: Uint8Array | null = null;
  await decodeFrames(file, stream.width, stream.height, (px) => { img ??= px; });
  if (!img) throw new Error(`${file}: no image`);
  return { w: stream.width as number, h: stream.height as number, px: img as Uint8Array };
}

async function writePng(file: string, w: number, h: number, rgb: Uint8Array) {
  mkdirSync(path.dirname(path.resolve(file)), { recursive: true });
  const p = Bun.spawn(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', `${w}x${h}`, '-i', '-', file], { stdin: 'pipe', stderr: 'pipe' });
  p.stdin.write(rgb);
  await p.stdin.flush(); // (end() alone can close the pipe before a large write is through)
  await p.stdin.end();
  if ((await p.exited) !== 0) throw new Error(`ffmpeg could not write ${file}: ${await new Response(p.stderr).text()}`);
}

// ------------------------------------------------------------------ diagnostic check
/** Mean RGB of the logical-px rectangle [u0, u1) x [v0, v1). */
function mean(px: Uint8Array, W: number, S: number, u0: number, v0: number, u1: number, v1: number) {
  const s = [0, 0, 0];
  let n = 0;
  for (let y = Math.round(v0 * S); y < Math.round(v1 * S); y++) for (let x = Math.round(u0 * S); x < Math.round(u1 * S); x++) {
    const i = (y * W + x) * 3;
    s[0] += px[i]!; s[1] += px[i + 1]!; s[2] += px[i + 2]!; n++;
  }
  return s.map((v) => v / n) as [number, number, number];
}
const near = (a: number[], b: number[], tol: number) => a.every((v, i) => Math.abs(v - b[i]!) <= tol);
const lum = (c: number[]) => 0.2126 * c[0]! + 0.7152 * c[1]! + 0.0722 * c[2]!;

/** Problems with one decoded frame that should show frame id `id`, or [] when it matches. */
function checkDiagFrame(px: Uint8Array, S: number, id: number): string[] {
  const W = 1920 * S, errs: string[] = [];
  const TL = mean(px, W, S, 48, 48, 144, 144), TR = mean(px, W, S, 1776, 48, 1872, 144);
  const BL = mean(px, W, S, 48, 936, 144, 1032), BR = mean(px, W, S, 1776, 936, 1872, 1032);
  const R = [255, 0, 0], G = [0, 255, 0], B = [0, 0, 255], Y = [255, 255, 0], C = [0, 255, 255], T = 40;
  // corners TL, TR, BL, BR as each transform leaves them
  const layouts: [string, number[][]][] = [
    ['ok', [R, G, B, Y]], ['vertical flip', [B, Y, R, G]], ['horizontal flip', [G, R, Y, B]],
    ['red/blue channel swap', [B, G, R, C]], ['vertical flip + red/blue channel swap', [R, C, B, G]], ['rotated 180', [Y, B, G, R]],
  ];
  const got = [TL, TR, BL, BR];
  const match = layouts.find(([, want]) => want.every((c, i) => near(got[i]!, c, T)));
  if (match?.[0] !== 'ok') {
    const r = (c: number[]) => c.map((v) => v.toFixed(0)).join(',');
    errs.push(`${match?.[0] ?? 'corner colours wrong'}: TL ${r(TL)} TR ${r(TR)} BL ${r(BL)} BR ${r(BR)}`);
  }
  // ramp: 16 steps across the band, each within 14 levels and increasing
  let prev = -1;
  for (let k = 0; k < 16; k++) {
    const u = 256 + ((k + 0.5) * 1408) / 16, got = lum(mean(px, W, S, u - 8, 460, u + 8, 500)), want = (k + 0.5) * 16;
    if (Math.abs(got - want) > 14 || got <= prev) { errs.push(`ramp step ${k}: ${got.toFixed(1)}, expected ${want.toFixed(1)}`); break; }
    prev = got;
  }
  // lines: brighter on columns x % 8 == 0 than between them, on two rows (a stride error shears them)
  for (const v of [570, 630]) {
    const y = Math.round(v * S);
    let on = 0, off = 0, nOn = 0, nOff = 0;
    for (let x = Math.round(300 * S); x < Math.round(1600 * S); x++) {
      const l = lum([px[(y * W + x) * 3]!, px[(y * W + x) * 3 + 1]!, px[(y * W + x) * 3 + 2]!]);
      if (x % 8 === 0) { on += l; nOn++; } else if (x % 8 === 4) { off += l; nOff++; }
    }
    if (on / nOn - off / nOff < 60) errs.push(`fine lines at v=${v}: on ${(on / nOn).toFixed(0)} vs off ${(off / nOff).toFixed(0)}`);
  }
  // moving bar
  const bx = 256 + ((8 * id) % 1392), bar = lum(mean(px, W, S, bx + 4, 700, bx + 12, 740));
  if (bar < 180) errs.push(`moving bar missing at u=${bx} (${bar.toFixed(0)})`);
  // frame id
  const guardOn = lum(mean(px, W, S, 400, 816, 432, 848)), guardOff = lum(mean(px, W, S, 1488, 816, 1520, 848));
  if (guardOn < 180 || guardOff > 75) errs.push(`frame id guard cells unreadable (${guardOn.toFixed(0)}, ${guardOff.toFixed(0)})`);
  else {
    let got = 0;
    for (let i = 0; i < 16; i++) got = (got << 1) | (lum(mean(px, W, S, 464 + 64 * i, 816, 496 + 64 * i, 848)) > 128 ? 1 : 0);
    if (got !== id) errs.push(`frame id ${got}, expected ${id}`);
  }
  return errs;
}

async function verifyDiagnostic(file: string, o: { frames?: number; first: number; fps?: number; scale: number }) {
  const S = o.scale, W = 1920 * S, H = 1080 * S, problems: string[] = [];
  const { stream, fps, pts } = await probe(file);
  console.log(`${file}: ${stream.codec_name} ${stream.profile ?? ''} ${stream.width}x${stream.height} ${stream.pix_fmt} ${stream.r_frame_rate} fps, colour ${stream.color_space ?? '?'}/${stream.color_primaries ?? '?'}/${stream.color_transfer ?? '?'} ${stream.color_range ?? '?'}`);
  if (stream.width !== W || stream.height !== H) return [`size ${stream.width}x${stream.height}, expected ${W}x${H}`];
  if (o.fps && Math.abs(fps - o.fps) > 1e-6) problems.push(`frame rate ${fps}, expected ${o.fps}`);
  if (o.frames !== undefined && pts.length !== o.frames) problems.push(`${pts.length} frames, expected ${o.frames}`);
  const step = 1 / (o.fps ?? fps);
  const badPts = pts.findIndex((t, i) => Math.abs(t - pts[0]! - i * step) > 1e-3);
  if (badPts >= 0) problems.push(`frame ${badPts} at ${(pts[badPts]! - pts[0]!).toFixed(4)} s, expected ${(badPts * step).toFixed(4)} s`);
  let firstBad = -1;
  const n = await decodeFrames(file, W, H, (px, i) => {
    if (firstBad >= 0) return;
    const e = checkDiagFrame(px, S, o.first + i);
    if (e.length) { firstBad = i; problems.push(`frame ${i}: ${e.join('; ')}`); }
  });
  if (n !== pts.length) problems.push(`decoded ${n} frames but ffprobe lists ${pts.length}`);
  console.log(`${n} frames decoded and checked${firstBad >= 0 ? ` (stopped at frame ${firstBad})` : ''}`);
  return problems;
}

// ------------------------------------------------------------------ image comparison
async function compare(a: string, b: string, o: { tol: number; diff?: string; side?: string; maxMean?: number; minPsnr?: number }) {
  const A = await decodeImage(a), B = await decodeImage(b);
  if (A.w !== B.w || A.h !== B.h) return { problems: [`sizes differ: ${A.w}x${A.h} vs ${B.w}x${B.h}`] };
  let max = 0, sum = 0, sq = 0, over = 0;
  const n = A.w * A.h, d = new Uint8Array(n * 3);
  for (let p = 0; p < n; p++) {
    let m = 0;
    for (let c = 0; c < 3; c++) {
      const e = Math.abs(A.px[p * 3 + c]! - B.px[p * 3 + c]!);
      sum += e; sq += e * e; m = Math.max(m, e);
      d[p * 3 + c] = Math.min(255, e * 8);
    }
    max = Math.max(max, m);
    if (m > o.tol) over++;
  }
  const meanAbs = sum / (n * 3), mse = sq / (n * 3), psnr = mse === 0 ? Infinity : 10 * Math.log10((255 * 255) / mse);
  console.log(`${path.basename(a)} vs ${path.basename(b)}: max ${max}  mean ${meanAbs.toFixed(3)}  PSNR ${psnr.toFixed(2)} dB  ${((100 * over) / n).toFixed(3)}% px over ${o.tol}`);
  if (o.diff) await writePng(o.diff, A.w, A.h, d);
  if (o.side) {
    const sw = A.w * 3, side = new Uint8Array(sw * A.h * 3);
    for (let y = 0; y < A.h; y++) [A.px, B.px, d].forEach((src, k) => side.set(src.subarray(y * A.w * 3, (y + 1) * A.w * 3), (y * sw + k * A.w) * 3));
    await writePng(o.side, sw, A.h, side);
  }
  const problems: string[] = [];
  if (o.maxMean !== undefined && meanAbs > o.maxMean) problems.push(`mean abs ${meanAbs.toFixed(3)} > ${o.maxMean}`);
  if (o.minPsnr !== undefined && psnr < o.minPsnr) problems.push(`PSNR ${psnr.toFixed(2)} < ${o.minPsnr}`);
  return { problems, max, meanAbs, psnr };
}

// ------------------------------------------------------------------ self-test
async function encode(file: string, frames: Uint8Array[], S: number) {
  const p = Bun.spawn(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', `${1920 * S}x${1080 * S}`, '-r', '60', '-i', '-',
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '16', '-pix_fmt', 'yuv420p', file], { stdin: 'pipe', stderr: 'pipe' });
  for (const f of frames) { p.stdin.write(f); await p.stdin.flush(); }
  await p.stdin.end();
  if ((await p.exited) !== 0) throw new Error(`ffmpeg encode failed: ${await new Response(p.stderr).text()}`);
}

async function selftest() {
  const dir = path.join(os.tmpdir(), `pdoom-verify-${process.pid}`);
  mkdirSync(dir, { recursive: true });
  const S = 1, N = 24;
  const cases: { name: string; frames: () => Uint8Array[]; expect: RegExp | null }[] = [
    { name: 'good', frames: () => Array.from({ length: N }, (_, i) => diagFrame(i, S)), expect: null },
    { name: 'vflip', frames: () => Array.from({ length: N }, (_, i) => diagFrame(i, S, false, true)), expect: /vertical flip/ },
    { name: 'bgr', frames: () => Array.from({ length: N }, (_, i) => diagFrame(i, S, true)), expect: /channel swap/ },
    { name: 'dropped', frames: () => Array.from({ length: N }, (_, i) => diagFrame(i < 10 ? i : i + 1, S)), expect: /frame id 11, expected 10/ },
  ];
  let ok = true;
  try {
    for (const c of cases) {
      const f = path.join(dir, `${c.name}.mp4`);
      await encode(f, c.frames(), S);
      const problems = await verifyDiagnostic(f, { frames: N, first: 0, fps: 60, scale: S });
      const pass = c.expect ? problems.some((p) => c.expect!.test(p)) : problems.length === 0;
      console.log(`selftest ${c.name}: ${pass ? 'ok' : 'UNEXPECTED'}${problems.length ? ` (${problems.join(' | ')})` : ''}`);
      ok &&= pass;
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  return ok ? [] : ['self-test failed'];
}

// ------------------------------------------------------------------ main
const mode = positional[0];
let problems: string[];
if (mode === 'diagnostic' && positional[1]) {
  problems = await verifyDiagnostic(positional[1], {
    frames: opt('frames') ? +opt('frames')! : undefined, first: +opt('first', '0')!, fps: opt('fps') ? +opt('fps')! : undefined, scale: +opt('scale', '1')!,
  });
} else if (mode === 'compare' && positional[1] && positional[2]) {
  ({ problems } = await compare(positional[1], positional[2], {
    tol: +opt('tol', '2')!, diff: opt('diff'), side: opt('side'),
    maxMean: opt('max-mean') ? +opt('max-mean')! : undefined, minPsnr: opt('min-psnr') ? +opt('min-psnr')! : undefined,
  }));
} else if (mode === 'selftest') {
  problems = await selftest();
} else {
  console.error('usage: verify.ts diagnostic VIDEO [--frames N] [--first 0] [--fps 60] [--scale 1] | compare A B [--tol 2] [--diff f] [--side f] [--max-mean x] [--min-psnr x] | selftest');
  process.exit(2);
}
for (const p of problems) console.log(`FAIL: ${p}`);
console.log(problems.length ? 'FAIL' : 'PASS');
process.exit(problems.length ? 1 : 0);
