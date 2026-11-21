// Shared Metal helpers: a line-for-line port of app/src/engine/glsl/common.ts (GLSL_COMMON) plus the
// tone shoulder from app/src/engine/post.ts. Hosts compile this file first, then every other .metal file
// under native/shaders (subfolders included) sorted by relative path, as one source (runtime compilation
// cannot resolve #include), with
//   preprocessor macro PDOOM_SCALE = output scale (1..4: physical px per logical 1920x1080 px)
//   math mode safe (MTLCompileOptions.mathMode = .safe): the hashes need IEEE float behaviour.
//
// Orientation: every texture keeps WebGL's memory order, row 0 = the BOTTOM of the image, so
// position.y in a fragment or gid.y in a kernel equals WebGL's gl_FragCoord.y - 0.5 and uv (0,0) is
// the bottom-left. Vertex shaders negate clip-space y to get there (see fs_vertex). Only the output
// pass flips rows for the encoder.
//
// GLSL -> MSL porting rules for scene shaders:
//   mod(x, y) -> gmod(x, y) (MSL fmod truncates; GLSL mod floors)   atan(y, x) -> atan2(y, x)
//   inversesqrt -> rsqrt   texture(s, uv) -> s.sample(lin, uv)   texelFetch(s, p, 0) -> s.read(uint2(p))
//   textureGrad(s, uv, dx, dy) -> s.sample(lin, uv, gradient2d(dx, dy))
//   gl_FragCoord.xy -> in.position.xy   FRAG_PX -> FRAG_PX(in.position)
//   smoothstep with edge0 > edge1 -> sstep (MSL leaves reversed edges undefined)
//   pow stays pow: Chrome's ANGLE emits Metal's pow, so negative bases agree (measured on this GPU:
//   pow(-2, 2) = 4, pow(-2, 3) = -8, pow(-2, 1.2) = NaN in WebGL and in Metal, safe or fast math)
// Chrome's shader compiler rounds differently in places (measured: smoothstep differs by up to 2.4e-7,
// 1-2 ulp, on 56-103 of 256 inputs, the same against Metal's built-in and sstep), so ports match Chrome
// to about +-2 output levels, not bit for bit.
//   fwidth/dFdx/dFdy exist only in fragment functions: pxLine, rampLine, aaFill, aaStroke, hatch
//   and engrave must not be called from kernels.
#include <metal_stdlib>
using namespace metal;

#ifndef PDOOM_SCALE
#error "compile with the PDOOM_SCALE preprocessor macro (1..4)"
#endif

#define PI 3.14159265359
#define TAU 6.28318530718
constant float PX_SCALE = float(PDOOM_SCALE);
#define FRAG_PX(pos) ((pos).xy / PX_SCALE)

constant float3 C_INK = float3(0.00304, 0.00304, 0.00335);
constant float3 C_INK2 = float3(0.00750, 0.00750, 0.00857);
constant float3 C_GRAPHITE = float3(0.11193, 0.10462, 0.09531);
constant float3 C_ASH = float3(0.33245, 0.30947, 0.27468);
constant float3 C_BONE = float3(0.85499, 0.81485, 0.73791);
constant float3 C_SIGNAL = float3(1.00000, 0.07421, 0.00605);
constant float3 C_EMBER = float3(1.00000, 0.25415, 0.04667);
constant float3 C_BLOOD = float3(0.53948, 0.01229, 0.00335);
constant float3 C_ACID = float3(0.68669, 1.00000, 0.04519);

/** Linear filtering, clamped at the edges: three.js render-target and canvas textures. */
constexpr sampler lin(filter::linear, address::clamp_to_edge, coord::normalized);

// ---- fullscreen pass ----
struct FSOut {
  float4 position [[position]];
  float2 vUv;
};
/** One triangle over the whole target (draw 3 vertices). vUv = WebGL's vUv: (0,0) bottom-left. */
vertex FSOut fs_vertex(uint vid [[vertex_id]]) {
  const float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
  FSOut o;
  o.vUv = p[vid] * 0.5 + 0.5;
  o.position = float4(p[vid].x, -p[vid].y, 0.0, 1.0); // -y: memory row 0 = image bottom, as in WebGL
  return o;
}

/** Rotated-grid supersample offset k (0..3) within one pixel, in pixels. See SS_TAP (gl.ts). */
inline float2 rgss(int k) { return k == 0 ? float2(0.125, -0.375) : k == 1 ? float2(0.375, 0.125) : k == 2 ? float2(-0.125, 0.375) : float2(-0.375, -0.125); }
/** The SS_TAP_GLSL loop bounds and weight for tap `ssTap` (-1 = all four). */
inline int ssK0(int ssTap) { return ssTap < 0 ? 0 : ssTap; }
inline int ssK1(int ssTap) { return ssTap < 0 ? 4 : ssTap + 1; }
inline float ssWeight(int ssTap) { return ssTap < 0 ? 0.25 : 1.0; }

inline float sat(float x) { return clamp(x, 0.0, 1.0); }
inline float3 sat(float3 x) { return clamp(x, 0.0, 1.0); }
inline float4 sat(float4 x) { return clamp(x, 0.0, 1.0); }
inline float gmod(float x, float y) { return x - y * floor(x / y); }
inline float2 gmod(float2 x, float y) { return x - y * floor(x / y); }
inline float3 gmod(float3 x, float y) { return x - y * floor(x / y); }
/** GLSL smoothstep, defined for either edge order. */
inline float sstep(float e0, float e1, float x) { float t = sat((x - e0) / (e1 - e0)); return t * t * (3.0 - 2.0 * t); }
inline float remap(float x, float a, float b, float c, float d) { return c + (d - c) * sat((x - a) / (b - a)); }
inline float2x2 rot2(float a) { float c = cos(a), s = sin(a); return float2x2(float2(c, -s), float2(s, c)); } // GLSL mat2(c, -s, s, c): column-major
inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// ---- hashes ----
inline float hash11(float p) { p = fract(p * .1031); p *= p + 33.33; p *= p + p; return fract(p); }
inline float hash12(float2 p) { float3 p3 = fract(float3(p.xyx) * .1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
inline float2 hash22(float2 p) { float3 p3 = fract(float3(p.xyx) * float3(.1031, .1030, .0973)); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.xx + p3.yz) * p3.zy); }
inline float hash13(float3 p3) { p3 = fract(p3 * .1031); p3 += dot(p3, p3.zyx + 31.32); return fract((p3.x + p3.y) * p3.z); }
inline float3 hash33(float3 p3) { p3 = fract(p3 * float3(.1031, .1030, .0973)); p3 += dot(p3, p3.yxz + 33.33); return fract((p3.xxy + p3.yxx) * p3.zyx); }

// ---- simplex noise (Ashima / Stefan Gustavson, MIT) ----
inline float3 _mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
inline float4 _mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
inline float2 _mod289(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
inline float3 _permute(float3 x) { return _mod289(((x * 34.0) + 10.0) * x); }
inline float4 _permute(float4 x) { return _mod289(((x * 34.0) + 10.0) * x); }
inline float4 _taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }
inline float snoise(float2 v) {
  const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
  float2 i = floor(v + dot(v, C.yy)); float2 x0 = v - i + dot(i, C.xx);
  float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
  float4 x12 = x0.xyxy + C.xxzz; x12.xy -= i1; i = _mod289(i);
  float3 p = _permute(_permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
  float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
  m = m * m; m = m * m;
  float3 x = 2.0 * fract(p * C.www) - 1.0; float3 h = abs(x) - 0.5; float3 ox = floor(x + 0.5); float3 a0 = x - ox;
  m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
  float3 g; g.x = a0.x * x0.x + h.x * x0.y; g.yz = a0.yz * x12.xz + h.yz * x12.yw;
  return 130.0 * dot(m, g);
}
inline float snoise(float3 v) {
  const float2 C = float2(1.0 / 6.0, 1.0 / 3.0); const float4 D = float4(0.0, 0.5, 1.0, 2.0);
  float3 i = floor(v + dot(v, C.yyy)); float3 x0 = v - i + dot(i, C.xxx);
  float3 g = step(x0.yzx, x0.xyz); float3 l = 1.0 - g; float3 i1 = min(g.xyz, l.zxy); float3 i2 = max(g.xyz, l.zxy);
  float3 x1 = x0 - i1 + C.xxx; float3 x2 = x0 - i2 + C.yyy; float3 x3 = x0 - D.yyy;
  i = _mod289(i);
  float4 p = _permute(_permute(_permute(i.z + float4(0.0, i1.z, i2.z, 1.0)) + i.y + float4(0.0, i1.y, i2.y, 1.0)) + i.x + float4(0.0, i1.x, i2.x, 1.0));
  float n_ = 0.142857142857; float3 ns = n_ * D.wyz - D.xzx;
  float4 j = p - 49.0 * floor(p * ns.z * ns.z); float4 x_ = floor(j * ns.z); float4 y_ = floor(j - 7.0 * x_);
  float4 x = x_ * ns.x + ns.yyyy; float4 y = y_ * ns.x + ns.yyyy; float4 h = 1.0 - abs(x) - abs(y);
  float4 b0 = float4(x.xy, y.xy); float4 b1 = float4(x.zw, y.zw);
  float4 s0 = floor(b0) * 2.0 + 1.0; float4 s1 = floor(b1) * 2.0 + 1.0; float4 sh = -step(h, float4(0.0));
  float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy; float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
  float3 p0 = float3(a0.xy, h.x); float3 p1 = float3(a0.zw, h.y); float3 p2 = float3(a1.xy, h.z); float3 p3 = float3(a1.zw, h.w);
  float4 norm = _taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
  p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
  float4 m = max(0.5 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0); m = m * m;
  return 105.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}
inline float fbm(float2 p, int oct) { float s = 0.0, a = 0.5; for (int i = 0; i < 8; i++) { if (i >= oct) break; s += a * snoise(p); p = rot2(0.6) * p * 2.03 + 11.7; a *= 0.5; } return s; }
inline float fbm(float3 p, int oct) { float s = 0.0, a = 0.5; for (int i = 0; i < 8; i++) { if (i >= oct) break; s += a * snoise(p); p = p * 2.03 + 11.7; a *= 0.5; } return s; }
// curl of 2D noise (divergence-free flow field)
inline float2 curl2(float2 p, float t) {
  float e = 0.01;
  float n1 = snoise(float3(p + float2(0.0, e), t)), n2 = snoise(float3(p - float2(0.0, e), t));
  float n3 = snoise(float3(p + float2(e, 0.0), t)), n4 = snoise(float3(p - float2(e, 0.0), t));
  return float2(n1 - n2, -(n3 - n4)) / (2.0 * e);
}

// ---- 2D SDFs ----
inline float sdCircle(float2 p, float r) { return length(p) - r; }
inline float sdBox(float2 p, float2 b) { float2 d = abs(p) - b; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0); }
inline float sdSegment(float2 p, float2 a, float2 b) { float2 pa = p - a, ba = b - a; float h = sat(dot(pa, ba) / dot(ba, ba)); return length(pa - ba * h); }
// ---- 3D SDFs ----
inline float sdSphere(float3 p, float r) { return length(p) - r; }
inline float sdBox3(float3 p, float3 b) { float3 q = abs(p) - b; return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0); }
inline float sdCapsule(float3 p, float3 a, float3 b, float r) { float3 pa = p - a, ba = b - a; float h = sat(dot(pa, ba) / dot(ba, ba)); return length(pa - ba * h) - r; }
inline float sdTorus(float3 p, float2 t) { float2 q = float2(length(p.xz) - t.x, p.y); return length(q) - t.y; }
inline float smin(float a, float b, float k) { float h = sat(0.5 + 0.5 * (b - a) / k); return mix(b, a, h) - k * h * (1.0 - h); }
inline float smax(float a, float b, float k) { return -smin(-a, -b, k); }

// Output scale > 1: lines whose width comes from the pixel footprint (fwidth, "N-px hairlines") would get
// thinner and lighter. The helpers below keep the ink (mean coverage) of the 1x look and draw it with
// the sharper physical footprint (see glsl/common.ts).
inline float _ss3(float t) { return t * t * t * (1.0 - 0.5 * t); } // integral of smoothstep's cubic
inline float _inkHalfWidth(float L, float R, float X) {
  float k = max(R - L, 1e-6), x = min(X, R);
  return x - k * (_ss3(sat((x - L) / k)) - _ss3(sat(-L / k)));
}
inline float _boxLine(float x, float m, float r) { r = max(r, 1e-6); return sat((min(x + r, m) - max(x - r, -m)) / (2.0 * r)); }
#if PDOOM_SCALE == 1
inline float pxLine(float d, float a, float b) { return 1.0 - sstep(a, b, d); }
inline float rampLine(float d, float hw, float aa) { return sat((hw - d) / aa + 0.5); }
#else
inline float pxLine(float d, float a, float b) { return _boxLine(d, _inkHalfWidth(a, b, 1e9) * PX_SCALE, 0.5 * (b - a)); }
inline float rampLine(float d, float hw, float aa) {
  float aL = aa * PX_SCALE, e = max(hw + 0.5 * aL, 0.0);
  return _boxLine(d, hw >= 0.5 * aL ? hw : e * e / (2.0 * aL), 0.5 * aa);
}
#endif
/** Anti-aliased coverage of a distance field (d<0 inside) using screen derivatives. Fragment only. */
inline float aaFill(float d) { float w = fwidth(d); return 1.0 - sstep(-w, w, d); }
/** Anti-aliased stroke of width wd around the zero set of d. Fragment only. */
#if PDOOM_SCALE == 1
inline float aaStroke(float d, float wd) { float w = fwidth(d); return 1.0 - sstep(wd * 0.5 - w, wd * 0.5 + w, abs(d)); }
#else
inline float aaStroke(float d, float wd) { float w = fwidth(d); return _boxLine(abs(d), _inkHalfWidth(wd * 0.5 - w * PX_SCALE, wd * 0.5 + w * PX_SCALE, 1e9), w); }
#endif
/** Engraving hatch along u (lines at integer u), width growing with darkness. Fragment only. */
inline float hatch(float u, float darkness) {
  float f = abs(fract(u) - 0.5);
  float half_w = 0.5 * sat(darkness);
  float aa = max(fwidth(u), 1e-4);
#if PDOOM_SCALE == 1
  return 1.0 - sstep(half_w - aa, half_w + aa, 0.5 - f);
#else
  float aaL = aa * PX_SCALE, x = 0.5 - f, m = _inkHalfWidth(half_w - aaL, half_w + aaL, 0.5);
  return min(_boxLine(x, m, aa) + _boxLine(1.0 - x, m, aa), 1.0);
#endif
}
/** Engraving with a thin always-on hairline + crosshatch in deep shadows. Fragment only. */
inline float engrave(float2 uv, float darkness, float freq, float angle) {
  float2 r = rot2(angle) * uv * freq;
  float a = hatch(r.y, darkness * 1.1);
  float b = hatch((rot2(1.1) * uv * freq).y, sat(darkness * 2.0 - 1.1));
  return max(a, b);
}

// ---- colour ----
inline float3 toSRGB(float3 c) { return mix(12.92 * c, 1.055 * pow(max(c, 0.0), float3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
inline float3 toLinear(float3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(0.04045, c)); }
/** Signal-orange heat ramp: 0 = ink, 0.5 = signal, 1 = white-hot. */
inline float3 heat(float x) {
  x = sat(x);
  float3 c = mix(C_INK, C_BLOOD, sstep(0.0, 0.3, x));
  c = mix(c, C_SIGNAL, sstep(0.25, 0.55, x));
  c = mix(c, C_EMBER, sstep(0.55, 0.8, x));
  return mix(c, float3(1.0, 0.93, 0.85), sstep(0.8, 1.0, x));
}
/** The tone shoulder (post.ts SHOULDER_GLSL): linear HDR -> 0..1 linear. */
inline float3 shoulder(float3 x) {
  const float k = 0.72;
  float3 y = mix(x, k + (1.0 - k) * (1.0 - exp(-(x - k) / (1.0 - k))), step(k, x));
  float over = max(max(x.r, x.g), x.b);
  return mix(y, float3(1.0), sstep(2.0, 12.0, over) * 0.85);
}
