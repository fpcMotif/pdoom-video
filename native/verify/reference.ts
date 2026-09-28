#!/usr/bin/env bun
// Dumps the TS engine's data-layer values (timeline, captions, audio features, lyric lookups) as JSON,
// so a native port can check its numbers against the original: bun native/verify/reference.ts > ref.json
// Runs the app's own modules in Bun (no browser). Numbers are JS doubles; compare with ~1e-9 tolerance.
import path from 'node:path';

const APP = path.resolve(import.meta.dir, '../../app');

// timeline.ts discovers scene modules with Vite's import.meta.glob; the scene loaders are never called here
Bun.plugin({
  name: 'vite-glob-stub',
  setup(b) {
    b.onLoad({ filter: /src\/timeline\.ts$/ }, async (a) => ({
      contents: (await Bun.file(a.path).text()).replace(/import\.meta\.glob<[^>]*>\([^)]*\)/, '({} as Record<string, () => Promise<any>>)'),
      loader: 'ts',
    }));
  },
});

const { AudioData } = await import(path.join(APP, 'src/engine/audio.ts'));
const { Lyrics } = await import(path.join(APP, 'src/engine/lyrics.ts'));
const { makeTimeline } = await import(path.join(APP, 'src/timeline.ts'));

const audio = new AudioData(await Bun.file(path.join(APP, '../data/audio.json')).json());
const lyrics = new Lyrics(await Bun.file(path.join(APP, '../data/lyrics.json')).json());
const timeline = makeTimeline(lyrics, audio) as any[];

// captions as Engine.init builds them
const captions = timeline.filter((e) => e.caption).map((e) => {
  const d = e.caption.delay ?? 0.3;
  return { start: e.start + d, end: e.start + d + (e.caption.dur ?? 4.5), fig: e.caption.fig, text: e.caption.text };
});

// sample times: a 0.05 s grid plus every timeline boundary and its neighbours
const times = new Set<number>();
for (let i = 0; i * 0.05 < audio.duration; i++) times.add(+(i * 0.05).toFixed(2));
for (const e of timeline) for (const d of [-1 / 60, 0, 1 / 60]) times.add(e.start + d);
const ts = [...times].filter((t) => t >= 0 && t < audio.duration).sort((a, b) => a - b);

const ENVS = ['rms', 'low', 'mid', 'high', 'vocal', 'drums', 'bass', 'other'];
const out = {
  source: { audio: 'data/audio.json', lyrics: 'data/lyrics.json' },
  duration: audio.duration,
  timeline: timeline.map(({ load: _, ...e }) => e),
  captions,
  lyrics: {
    lines: lyrics.lines.length,
    words: lyrics.lines.reduce((n: number, l: any) => n + l.words.length, 0),
  },
  samples: ts.map((t) => ({
    t,
    beat: audio.beatAt(t),
    bar: audio.barAt(t),
    a: audio.sample(t),
    env: Object.fromEntries(ENVS.map((k) => [k, audio.env(k, t)])),
    line: lyrics.lineAt(t) ? lyrics.lines.indexOf(lyrics.lineAt(t)) : -1,
    word: lyrics.wordAt(t)?.gi ?? -1,
  })),
  beats: Array.from({ length: 40 }, (_, i) => i * 8 - 4).map((i) => ({ i, t: audio.timeOfBeat(i) })),
};
console.log(JSON.stringify(out));
