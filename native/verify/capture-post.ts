#!/usr/bin/env bun
// Captures post-processing fixtures from the browser renderer, so a native post chain can be checked in
// isolation: the same HDR input, HUD layer and parameters must give the same final frame.
//   bun native/verify/capture-post.ts [--scale 1] [--t 12.5,40] [--mids 6] [--scan] [--out DIR]
// For each time t (rendered with 4 sub-frames over a 0.2 shutter, like an export) it writes to DIR
// (default out/native-ref/post-<scale>x):
//   t<t>.hdr.f16   the averaged HDR frame post reads (RGBA16Float, PW x PH, row 0 = image BOTTOM)
//   t<t>.hud.f16   the HUD layer as the final pass samples it (RGBA16Float, straight alpha, linear, row 0 = bottom)
//   t<t>.final.png the browser's final frame (RGBA8 through post, top-down)
//   t<t>.json      { t, width, height, scale, samples, post }  (post = the PostParams used)
// and index.json listing them. --scan adds up to 6 times where post parameters leave their defaults
// (flash, invert, zoom, shake, fade, exposure); --mids N adds the midpoints of N timeline entries.
// It reads the engine's internals through the existing export page (?export=1); the app is not modified.
import { chromium } from '../../app/node_modules/playwright-core';
import { mkdirSync } from 'node:fs';
import path from 'node:path';

const argv = process.argv.slice(2);
const opt = (k: string, d?: string) => { const i = argv.indexOf(`--${k}`); return i >= 0 ? argv[i + 1] : d; };
const flag = (k: string) => argv.includes(`--${k}`);
const ROOT = path.resolve(import.meta.dir, '../..');
const APP = path.join(ROOT, 'app');
const SCALE = +opt('scale', '1')!;
const OUT = path.resolve(opt('out', path.join(ROOT, `out/native-ref/post-${SCALE}x`))!);

// (the same boot as app/scripts/render.ts: a private Vite server without live reload, headless Chrome on Metal)
const port = 5300 + Math.floor(Math.random() * 500);
const vite = Bun.spawn(['bunx', 'vite', '--port', String(port), '--strictPort'], { cwd: APP, stdout: 'ignore', stderr: 'ignore', env: { ...process.env, PDOOM_NO_HMR: '1' } });
const url = `http://localhost:${port}`;
for (let i = 0; i < 150; i++) { try { if ((await fetch(url)).ok) break; } catch {} await Bun.sleep(100); }
const browser = await chromium.launch({ channel: 'chrome', headless: true, args: ['--use-angle=metal', '--enable-gpu-rasterization', '--ignore-gpu-blocklist'] });

try {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  await page.goto(`${url}/?export=1${SCALE !== 1 ? `&scale=${SCALE}` : ''}`);
  await page.waitForFunction(() => (window as any).__pdoom?.ready || (window as any).__pdoom?.error, null, { timeout: 120000 });
  const err = await page.evaluate(() => (window as any).__pdoom.error);
  if (err) throw new Error(err);

  const timeline: { id: string; start: number; end: number }[] = await page.evaluate(() => (window as any).__pdoom.timeline);
  const times = new Set<number>((opt('t') ?? '').split(',').filter(Boolean).map(Number));
  const mids = +opt('mids', '0')!;
  for (let i = 0; i < mids; i++) {
    const e = timeline[Math.round((i * (timeline.length - 1)) / Math.max(1, mids - 1))]!;
    times.add(+((e.start + e.end) / 2).toFixed(3));
  }
  if (flag('scan')) {
    // one sub-frame per 0.1 s is enough to see which post parameters a scene drives
    const hits: Record<string, number> = await page.evaluate((dur: number) => {
      const P = (window as any).__pdoom, found: Record<string, number> = {};
      const tests: Record<string, (p: any) => boolean> = {
        flash: (p) => p.flash > 0.2, invert: (p) => p.invert > 0.5, zoom: (p) => Math.abs(p.zoom - 1) > 0.02,
        shake: (p) => Math.hypot(p.shake[0], p.shake[1]) > 2, fade: (p) => p.fade > 0.3 && p.fade < 0.9, exposure: (p) => Math.abs(p.exposure - 1) > 0.1,
      };
      for (let t = 0.05; t < dur; t += 0.1) {
        P.still(t);
        for (const [k, f] of Object.entries(tests)) if (!(k in found) && f(P.engine.lastPost)) found[k] = +t.toFixed(3);
      }
      return found;
    }, timeline[timeline.length - 1]!.end);
    console.log('scan:', JSON.stringify(hits));
    for (const t of Object.values(hits)) times.add(t);
  }
  if (!times.size) throw new Error('no times: pass --t, --mids or --scan');

  mkdirSync(OUT, { recursive: true });
  const index: string[] = [];
  for (const t of [...times].sort((a, b) => a - b)) {
    const r: { w: number; h: number; samples: number; post: any; hdr: string; hud: string; final: string } = await page.evaluate(async (t: number) => {
      const P = (window as any).__pdoom, E = P.engine;
      const samples = P.still(t, 4, 0.2);
      const r = E.renderer, w = P.width, h = P.height;
      const b64 = (u8: Uint8Array) => { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(s); };
      // copy a texture texel-for-texel into a float target and read it back as half floats (three.js
      // classes and constants taken from the engine's own float, nearest-filtered error target)
      const rt = new E.errRT.constructor(w, h, { type: E.errRT.texture.type, depthBuffer: false, minFilter: E.errRT.texture.minFilter, magFilter: E.errRT.texture.magFilter });
      const half = (tex: any) => {
        E.comp.draw(r, tex, rt, { mode: 'replace', opacity: 1, premult: false });
        const f = new Float32Array(w * h * 4);
        r.readRenderTargetPixels(rt, 0, 0, w, h, f);
        return b64(new Uint8Array(new Float16Array(f).buffer));
      };
      const hdr = half(E.avgRT.texture), hud = half(E.hud.layer.texture);
      rt.dispose();
      const fin = new Uint8Array(w * h * 4);
      r.readRenderTargetPixels(E.finalRT, 0, 0, w, h, fin);
      return { w, h, samples, post: E.lastPost, hdr, hud, final: b64(fin) };
    }, t);
    const name = `t${t.toFixed(3).padStart(7, '0')}`;
    await Bun.write(path.join(OUT, `${name}.hdr.f16`), Buffer.from(r.hdr, 'base64'));
    await Bun.write(path.join(OUT, `${name}.hud.f16`), Buffer.from(r.hud, 'base64'));
    // final: bottom-up RGBA8 from WebGL -> top-down PNG
    const png = Bun.spawn(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', `${r.w}x${r.h}`, '-i', '-', '-vf', 'vflip', path.join(OUT, `${name}.final.png`)], { stdin: 'pipe' });
    png.stdin.write(Buffer.from(r.final, 'base64'));
    await png.stdin.flush(); // (end() alone can close the pipe before a large write is through)
    await png.stdin.end();
    if ((await png.exited) !== 0) throw new Error(`ffmpeg failed writing ${name}.final.png`);
    await Bun.write(path.join(OUT, `${name}.json`), JSON.stringify({ t, width: r.w, height: r.h, scale: SCALE, samples: r.samples, post: r.post }, null, 1));
    const nonDefault = Object.entries(r.post).filter(([k, v]) => ['flash', 'invert', 'fade'].includes(k) ? v !== 0 : k === 'zoom' || k === 'exposure' ? v !== 1 : k === 'shake' ? (v as number[]).some(Boolean) : false);
    console.log(`${name}: ${r.samples} sub-frames${nonDefault.length ? `, ${nonDefault.map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(' ')}` : ''}`);
    index.push(name);
  }
  await Bun.write(path.join(OUT, 'index.json'), JSON.stringify({ scale: SCALE, frames: index }, null, 1));
  console.log(`wrote ${index.length} fixtures to ${OUT}`);
} finally {
  await browser.close();
  vite.kill();
}
