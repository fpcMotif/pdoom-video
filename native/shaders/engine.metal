// Engine passes, ported from app/src/engine/engine.ts and gl.ts: motion-blur accumulation, the adaptive
// sampler's error estimate, the default crossfade, and the Compositor's textured draw.
//
// Motion blur (Engine.render with samples > 1), per frame:
//   sum (RGBA32Float, PW x PH) = 0, alpha 0
//   for each sub-frame: render the composite (RGBA16Float) and run accum_add_sample into sum
//   adaptive steps: new (RGBA32Float) = 0; add the 2n new sub-frames with accum_add_sample into new;
//     accum_error(a = sum, b = new, invA = 1/n, invB = 1/(2n)) -> err; accum_max(err) -> host max / 2
//     is the step's error; accum_merge(new) into sum; n *= 3; stop when the error < tol
//   accum_average(sum, 1/n) -> avg (RGBA16Float): the input to post
// Sub-frame times, the POST_U choice of post parameters and the SS_TAP cycling are host logic: see
// Engine.render and ternaryOffsets in engine.ts.

struct ScaleParams { float k; };
struct ErrorParams { float invA, invB; };
struct XfadeParams { float k; };

/** sum.rgb += sample.rgb; a non-finite or huge pixel (a stray NaN in one sub-frame) is dropped. Alpha stays. */
kernel void accum_add_sample(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::read_write> sum [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= sum.get_width() || gid.y >= sum.get_height()) return;
  float4 c = src.read(gid);
  bool ok = abs(c.r) <= 6e4 && abs(c.g) <= 6e4 && abs(c.b) <= 6e4 && abs(c.a) <= 6e4;
  float4 s = sum.read(gid);
  sum.write(float4(s.rgb + (ok ? c.rgb : float3(0.0)), s.a), gid);
}

/** sum.rgb += add.rgb (an adaptive step's new sub-frames joining the sum; no filtering: sums may exceed 6e4). */
kernel void accum_merge(texture2d<float, access::read> add [[texture(0)]],
                        texture2d<float, access::read_write> sum [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= sum.get_width() || gid.y >= sum.get_height()) return;
  float4 s = sum.read(gid);
  sum.write(float4(s.rgb + add.read(gid).rgb, s.a), gid);
}

/** avg = sum * k (k = 1/n), stored at half precision as the WebGL avgRT is. */
kernel void accum_average(texture2d<float, access::read> sum [[texture(0)]],
                          texture2d<float, access::write> avg [[texture(1)]],
                          constant ScaleParams& p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= avg.get_width() || gid.y >= avg.get_height()) return;
  avg.write(sum.read(gid) * p.k, gid);
}

inline float3 disp(float3 x) { return toSRGB(sat(shoulder(max(x, 0.0)))); }

/**
 * Sampling error per block of B x B physical px (B = 2 * PDOOM_SCALE, 2x2 logical px): 170 x the largest
 * channel gap between the displayed averages of a (sum of n) and b (sum of 2n). err is
 * ceil(PW/B) x ceil(PH/B), R32Float.
 */
kernel void accum_error(texture2d<float, access::read> a [[texture(0)]],
                        texture2d<float, access::read> b [[texture(1)]],
                        texture2d<float, access::write> err [[texture(2)]],
                        constant ErrorParams& p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= err.get_width() || gid.y >= err.get_height()) return;
  const int B = 2 * PDOOM_SCALE;
  int2 p0 = int2(gid) * B, lim = int2(a.get_width() - 1, a.get_height() - 1);
  float3 sa = float3(0.0), sb = float3(0.0);
  for (int y = 0; y < B; y++) for (int x = 0; x < B; x++) {
    uint2 q = uint2(min(p0 + int2(x, y), lim));
    sa += a.read(q).rgb; sb += b.read(q).rgb;
  }
  float3 e = abs(disp(sa * (p.invA / float(B * B))) - disp(sb * (p.invB / float(B * B))));
  err.write(float4(170.0 * max(e.r, max(e.g, e.b)), 0.0, 0.0, 1.0), gid);
}

/** Max of err over 16 x 16 blocks into out[gid.y * ceil(w/16) + gid.x]; the host takes the max of out. */
kernel void accum_max(texture2d<float, access::read> err [[texture(0)]],
                      device float* out [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
  const uint R = 16;
  uint w = err.get_width(), h = err.get_height(), ow = (w + R - 1) / R, oh = (h + R - 1) / R;
  if (gid.x >= ow || gid.y >= oh) return;
  float m = 0.0;
  for (uint y = 0; y < R; y++) for (uint x = 0; x < R; x++) {
    uint2 q = gid * R + uint2(x, y);
    if (q.x < w && q.y < h) m = max(m, err.read(q).r);
  }
  out[gid.y * ow + gid.x] = m;
}

/** The engine's default transition: mix(a, b, k) over the overlap of two timeline entries. */
kernel void comp_xfade(texture2d<float, access::read> a [[texture(0)]],
                       texture2d<float, access::read> b [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]],
                       constant XfadeParams& p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
  out.write(mix(a.read(gid), b.read(gid), p.k), gid);
}

/**
 * Compositor.draw (gl.ts): a texture over a target with a blend mode. Render pipeline: fs_vertex +
 * comp_draw, blending per mode (source factor / destination factor, RGB then alpha, operation add):
 *   normal   one / oneMinusSourceAlpha,  one / oneMinusSourceAlpha
 *   add      one / one,                  zero / one
 *   screen   one / oneMinusSourceColor,  zero / one
 *   multiply destinationColor / oneMinusSourceAlpha, zero / one
 *   max      operation max, one / one (both)
 *   replace  blending off
 * premult defaults to true except for multiply.
 */
struct CompParams {
  float opacity;
  float tintR, tintG, tintB;
  float scaleX, scaleY, offsetX, offsetY; // uvXform: (uv - 0.5) * scale + 0.5 + offset
  float premult;
};
fragment float4 comp_draw(FSOut in [[stage_in]],
                          texture2d<float, access::sample> tex [[texture(0)]],
                          constant CompParams& p [[buffer(0)]]) {
  float2 uv = (in.vUv - 0.5) * float2(p.scaleX, p.scaleY) + 0.5 + float2(p.offsetX, p.offsetY);
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) discard_fragment();
  float4 c = tex.sample(lin, uv);
  c.rgb *= float3(p.tintR, p.tintG, p.tintB);
  if (p.premult > 0.5) c.rgb *= c.a;
  return float4(c.rgb, c.a) * p.opacity;
}
