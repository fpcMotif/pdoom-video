// FIG. prompt (app/src/scenes/prompt.ts, SHADERS + UI_OVER): one fullscreen fragment shader per variant
// (prompt_chatgpt, prompt_sydney, prompt_gato; render pipeline with fs_vertex, no blending), each drawing
// its background and compositing the scene's UI layer (`ui`: the Canvas2D layer as three.js samples it:
// straight alpha, colour decoded to linear, row 0 = image bottom).
// Every variant takes the same parameter block (the FSPass uniforms of prompt.ts, in this order).

struct PromptParams {
  float t, lt, aspect, camZ, glow;
  float vpX, vpY;             // vp
  float rot, rush, swallow, beat, hotBoost, spacing, barW, barCx, shut, zoomBlur;
  float zbCenterX, zbCenterY; // zbCenter
  float uiAlpha, light;
};

inline float3 promptOverUI(float3 col, float2 uv, texture2d<float> ui, constant PromptParams& P) {
  float4 u = ui.sample(lin, uv);
  if (P.zoomBlur > 0.0) {
    float4 acc = u; float wsum = 1.0;
    for (int i = 1; i < 8; i++) { float k = float(i) / 7.0; float4 s = ui.sample(lin, mix(uv, float2(P.zbCenterX, P.zbCenterY), k * P.zoomBlur)); acc += s * (1.0 - k * 0.6); wsum += 1.0 - k * 0.6; }
    u = acc / wsum;
    u.rgb /= max(u.a, 1e-3);
  }
  float hot = sstep(0.25, 0.7, u.r - u.g * 1.3);
  float3 c = u.rgb * (1.0 + P.hotBoost * hot);
  return mix(col, c, u.a * P.uiAlpha);
}

// hairlines at integer v with a constant pixel width; fade to average tone when dense
inline float promptHairlines(float v, float wpx, float tone) {
  float fw = max(fwidth(v), 1e-5) * PX_SCALE;
  float sp = 1.0 / fw;                                  // logical px per period
  float d = abs(fract(v + 0.5) - 0.5) * sp * PX_SCALE;  // physical px
  float l = pxLine(d, wpx * 0.5 - 0.6, wpx * 0.5 + 0.6);
  float avg = min(1.0, wpx / sp) * 0.8;
  return mix(avg, l, sstep(2.2, 4.5, sp));
}

// An engraved throat: rings (cartilage) and longitudinal folds, seen down its length.
fragment float4 prompt_chatgpt(FSOut in [[stage_in]], texture2d<float> ui [[texture(0)]], constant PromptParams& P [[buffer(0)]]) {
  float2 vUv = in.vUv;
  float2 p = (vUv - 0.5) * float2(P.aspect, 1.0);
  float2 q = rot2(P.rot) * (p - float2(P.vpX, P.vpY));
  float r = length(q);
  float a = atan2(q.y, q.x);
  float2 dir = float2(cos(a), sin(a));
  // organic cross-section (gentle, slowly turning)
  float wob = 1.0 + 0.045 * snoise(dir * 0.9 + float2(P.t * 0.05, 3.1)) + 0.02 * snoise(dir * 2.1 + float2(1.7, P.t * 0.08));
  float R = r / wob;
  float z = 0.5 / max(R, 1e-4);            // depth of the wall seen at this radius
  // swallow: a contraction wave travelling toward the camera
  float wz = mix(14.0, 0.2, sat(P.swallow / 1.1));
  float wave = exp(-pow(z - wz, 2.0) * 0.5) * (1.0 - sstep(1.1, 1.6, P.swallow));
  z *= 1.0 - 0.18 * wave;
  float u = z * 2.3 + P.camZ;               // along-throat coordinate: one ring per unit
  float fu = fract(u);
  // cartilage rings: narrow ridges, wide soft grooves; lit by a headlamp at the camera
  float ridge = pow(0.5 + 0.5 * cos(TAU * (fu - 0.5)), 4.0);
  float face = sstep(0.25, 0.5, fu) * (1.0 - sstep(0.5, 0.75, fu));
  float fog = exp(-z * 0.2);
  float shade = (0.08 + 0.92 * max(ridge, face * 0.7)) * fog;
  shade *= 1.0 + 0.5 * P.beat + 1.4 * wave;
  // engraving: hairlines along the rings (perspective-spaced, constant pixel width)
  float lines = promptHairlines(u * 11.0, 0.5 + 1.7 * sat(shade), shade);
  // longitudinal folds in the grooves: short broken radial strokes
  float ang = a / TAU * 220.0 + 1.5 * snoise(float2(u * 0.3, a * 1.5));
  float brk = sstep(0.1, 0.4, snoise(float2(u * 1.3, floor(ang) * 0.37)));
  float folds = promptHairlines(ang, 0.9, 1.0) * brk * (1.0 - ridge) * fog * sstep(0.05, 0.3, r);
  float3 col = C_INK;
  col += C_BONE * 0.34 * lines * (0.25 + 0.75 * sat(shade)) + C_ASH * 0.10 * folds;
  // speed streaks on the rush
  col += C_BONE * 0.3 * P.rush * P.rush * hatch(ang * 0.5, 0.18) * sstep(0.06, 0.5, r);
  // the pit: a deep ember glow at the vanishing point
  float g = exp(-r * mix(11.0, 1.4, sat(P.rush * P.rush))) * P.glow;
  col = mix(col, col * 0.3, sstep(0.25, 0.0, r) * 0.7);
  col += heat(0.3 + 0.45 * sat(g)) * g * 0.8;
  col = promptOverUI(col, vUv, ui, P);
  return float4(col, 1.0);
}

inline float promptBars(float x, constant PromptParams& P) {
  float d = x - P.barCx;
  return gmod(d, P.spacing) - P.spacing * 0.5;
}

// Vertical bars in front of the prompt, closing in on the beat.
fragment float4 prompt_sydney(FSOut in [[stage_in]], texture2d<float> ui [[texture(0)]], constant PromptParams& P [[buffer(0)]]) {
  float2 vUv = in.vUv;
  float2 px = vUv * float2(1920.0, 1080.0);
  float2 p = (vUv - 0.5) * float2(P.aspect, 1.0);
  // background: deep ink with a faint cold wall texture (engraved horizontal lines)
  float wall = hatch(px.y / 7.0, 0.08 + 0.1 * sat(snoise(p * 3.0 + 4.0)));
  float3 col = C_INK + C_GRAPHITE * 0.05 * wall;
  col += C_ASH * 0.04 * exp(-dot(p, p) * 3.0);
  col = promptOverUI(col, vUv, ui, P);
  // shadows of the bars on the prompt plane (offset, soft)
  float m = promptBars(px.x - 26.0, P);
  float sh = 1.0 - sstep(P.barW * 0.5 - 6.0, P.barW * 0.5 + 10.0, abs(m));
  col *= 1.0 - 0.72 * sh;
  // the bars: engraved iron cylinders, lit from the left
  float mb = promptBars(px.x, P);
  float cov = aaFill(abs(mb) - P.barW * 0.5);
  float shutCov = aaFill(abs(mb) - mix(P.barW * 0.5, P.spacing * 0.5 + 2.0, P.shut));
  float s = clamp(mb / (P.barW * 0.5), -1.0, 1.0);
  float3 n = float3(s, 0.0, sqrt(max(0.0, 1.0 - s * s)));
  float3 L = normalize(float3(-0.7, 0.2, 0.7));
  float diff = max(0.0, dot(n, L));
  float spec = pow(max(0.0, dot(n, normalize(L + float3(0, 0, 1)))), 30.0);
  float grain = snoise(float2(px.x * 0.05, px.y * 0.004)) * 0.5 + 0.5;
  float eng = hatch(s * 4.0 + px.y * 0.002, diff * (0.55 + 0.3 * grain));
  float3 bar = C_INK * 0.4 + C_BONE * (0.16 * eng + 0.55 * spec) * (1.0 + 0.6 * P.light);
  col = mix(col, bar, cov);
  col = mix(col, C_INK * 0.25, shutCov * (1.0 - cov) * step(0.001, P.shut));
  return float4(col, 1.0);
}

// Alone in the dark: a faint pool of light and a few slow motes.
fragment float4 prompt_gato(FSOut in [[stage_in]], texture2d<float> ui [[texture(0)]], constant PromptParams& P [[buffer(0)]]) {
  float2 vUv = in.vUv;
  float2 p = (vUv - 0.5) * float2(P.aspect, 1.0);
  float3 col = C_INK;
  col += C_ASH * 0.035 * P.glow * exp(-dot(p * float2(0.8, 1.6), p * float2(0.8, 1.6)) * 4.0);
  // motes: sparse points drifting upward very slowly
  float2 g = p * 18.0 + float2(0.0, -P.t * 0.12);
  float2 id = floor(g);
  float2 f = fract(g) - 0.5;
  float2 h = hash22(id);
  float2 o = (h - 0.5) * 0.7 + 0.08 * float2(sin(P.t * 0.3 + h.x * 6.0), cos(P.t * 0.23 + h.y * 6.0));
  float d = length(f - o);
  float on = step(0.86, hash12(id + 7.0));
  col += C_BONE * on * 0.18 * sstep(0.035, 0.0, d) * P.glow;
  col = promptOverUI(col, vUv, ui, P);
  return float4(col, 1.0);
}
