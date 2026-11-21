// Global post-processing, ported from app/src/engine/post.ts (Post.render). Compute kernels, one thread
// per destination pixel; uv = (gid + 0.5) / destination size, which is WebGL's vUv at that pixel.
//
// Host sequence per frame (sizes in px; W, H = 1920, 1080 logical; PW, PH = physical output):
//   mips[i], ups[i] for i = 0..6: RGBA16Float, mips[0] = (W>>1, H>>1), each next = (w>>1, h>>1),
//     every side at least 2 (the pyramid is logical-sized at every output scale).
//   post_prefilter  src (PW x PH)  -> mips[0]   texel = (1/W, 1/H)
//   post_down       mips[i-1]      -> mips[i]   texel = 1 / size(mips[i-1])          for i = 1..6
//   post_up         src = mips[6] (i = 5) or ups[i+1], prev = mips[i] -> ups[i],
//                   texel = 1 / size(src), radius = 0.5 + bloomRadius             for i = 5..0
//   post_final      src, bloom = ups[0], halo = ups[3], hud -> output (PW x PH)
// Parameter blocks are flat float arrays in the order of the struct fields (all floats, no padding).

struct PrefilterParams { float texelX, texelY, threshold, knee; };
struct DownParams { float texelX, texelY; };
struct UpParams { float texelX, texelY, radius; };
struct FinalParams {
  float exposure;   // PostParams.exposure
  float bloom;      // PostParams.bloom / 3 (the pyramid sums ~MIPS levels)
  float halation, ca, grain, vignette, hud, fade, flash;
  float time;       // song time t of the frame
  float zoom, invert;
  float shakeX, shakeY;   // PostParams.shake, logical px
  float resX, resY;       // logical size: 1920, 1080
  float flipRows;         // 1: write row PH-1-y (top-down for an encoder), 0: keep WebGL order
};

inline float2 dstUv(uint2 gid, uint2 size) { return (float2(gid) + 0.5) / float2(size); }

kernel void post_prefilter(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant PrefilterParams& p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
  uint2 size = uint2(dst.get_width(), dst.get_height());
  if (gid.x >= size.x || gid.y >= size.y) return;
  float2 vUv = dstUv(gid, size), texel = float2(p.texelX, p.texelY);
  // 4-tap box downsample + soft threshold on luminance
  float3 c = float3(0.0);
#if PDOOM_SCALE == 1
  c += src.sample(lin, vUv + texel * float2(-1, -1)).rgb; c += src.sample(lin, vUv + texel * float2(1, -1)).rgb;
  c += src.sample(lin, vUv + texel * float2(-1, 1)).rgb;  c += src.sample(lin, vUv + texel * float2(1, 1)).rgb;
  c *= 0.25;
#else
  // output scale > 1: the same 4x4-logical-px box from a SCALE x larger source, as 2x2-texel bilinear taps
  const int N = PDOOM_SCALE * 2;
  for (int j = 0; j < N; j++) for (int i = 0; i < N; i++)
    c += src.sample(lin, vUv + texel * (float2(float(i), float(j)) * 2.0 - float(N - 1)) / PX_SCALE).rgb;
  c /= float(N * N);
#endif
  c = min(c, float3(40.0));
  float l = max(c.r, max(c.g, c.b));
  float rq = clamp(l - p.threshold + p.knee, 0.0, 2.0 * p.knee);
  rq = rq * rq / (4.0 * p.knee + 1e-5);
  float w = max(rq, l - p.threshold) / max(l, 1e-5);
  dst.write(float4(c * w, 1.0), gid);
}

kernel void post_down(texture2d<float, access::sample> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant DownParams& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
  uint2 size = uint2(dst.get_width(), dst.get_height());
  if (gid.x >= size.x || gid.y >= size.y) return;
  float2 vUv = dstUv(gid, size), texel = float2(p.texelX, p.texelY);
  // 13-tap downsample (Jimenez 2014)
  float3 a = src.sample(lin, vUv + texel * float2(-2, -2)).rgb, b = src.sample(lin, vUv + texel * float2(0, -2)).rgb, c = src.sample(lin, vUv + texel * float2(2, -2)).rgb;
  float3 d = src.sample(lin, vUv + texel * float2(-1, -1)).rgb, e = src.sample(lin, vUv + texel * float2(1, -1)).rgb;
  float3 f = src.sample(lin, vUv + texel * float2(-2, 0)).rgb, g = src.sample(lin, vUv).rgb, h = src.sample(lin, vUv + texel * float2(2, 0)).rgb;
  float3 i = src.sample(lin, vUv + texel * float2(-1, 1)).rgb, j = src.sample(lin, vUv + texel * float2(1, 1)).rgb;
  float3 k = src.sample(lin, vUv + texel * float2(-2, 2)).rgb, l = src.sample(lin, vUv + texel * float2(0, 2)).rgb, m = src.sample(lin, vUv + texel * float2(2, 2)).rgb;
  float3 o = (d + e + i + j) * 0.125 + (a + b + g + f) * 0.03125 + (b + c + h + g) * 0.03125 + (f + g + l + k) * 0.03125 + (g + h + m + l) * 0.03125;
  dst.write(float4(o, 1.0), gid);
}

kernel void post_up(texture2d<float, access::sample> src [[texture(0)]],
                    texture2d<float, access::sample> prev [[texture(1)]],
                    texture2d<float, access::write> dst [[texture(2)]],
                    constant UpParams& p [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
  uint2 size = uint2(dst.get_width(), dst.get_height());
  if (gid.x >= size.x || gid.y >= size.y) return;
  float2 vUv = dstUv(gid, size);
  // 9-tap tent upsample of the smaller level, added to this level
  float2 o = float2(p.texelX, p.texelY) * p.radius;
  float3 s = src.sample(lin, vUv - o).rgb + 2.0 * src.sample(lin, vUv + float2(0, -o.y)).rgb + src.sample(lin, vUv + float2(o.x, -o.y)).rgb
    + 2.0 * src.sample(lin, vUv + float2(-o.x, 0)).rgb + 4.0 * src.sample(lin, vUv).rgb + 2.0 * src.sample(lin, vUv + float2(o.x, 0)).rgb
    + src.sample(lin, vUv + float2(-o.x, o.y)).rgb + 2.0 * src.sample(lin, vUv + float2(0, o.y)).rgb + src.sample(lin, vUv + o).rgb;
  dst.write(float4(prev.sample(lin, vUv).rgb + s / 16.0, 1.0), gid);
}

/**
 * The final composite: CA, bloom, halation, exposure, HUD, shoulder, invert, flash, vignette, fade,
 * sRGB encode, grain and dither. `out` is RGBA8Unorm or BGRA8Unorm (the write converts and swizzles).
 * `hud` holds the HUD layer as three.js samples it: straight alpha, colour decoded to linear.
 */
kernel void post_final(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::sample> bloomTex [[texture(1)]],
                       texture2d<float, access::sample> haloTex [[texture(2)]],
                       texture2d<float, access::sample> hudTex [[texture(3)]],
                       texture2d<float, access::write> out [[texture(4)]],
                       constant FinalParams& p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
  uint2 size = uint2(out.get_width(), out.get_height());
  if (gid.x >= size.x || gid.y >= size.y) return;
  float2 vUv = dstUv(gid, size), fragCoord = float2(gid) + 0.5, res = float2(p.resX, p.resY);
  float2 uv = (vUv - 0.5) / p.zoom + 0.5 - float2(p.shakeX, p.shakeY) / res;
  float2 dc = uv - 0.5;
  float r2 = dot(dc * float2(res.x / res.y, 1.0), dc * float2(res.x / res.y, 1.0));
  float2 off = dc * r2 * p.ca / res.x * 4.0;
  float3 col;
  col.r = src.sample(lin, uv + off).r;
  col.g = src.sample(lin, uv).g;
  col.b = src.sample(lin, uv - off).b;
  float3 bl = bloomTex.sample(lin, uv).rgb;
  float3 ha = haloTex.sample(lin, uv).rgb;
  col += bl * p.bloom;
  col += float3(1.0, 0.18, 0.04) * luma(ha) * p.halation;
  col *= p.exposure;
  // HUD is composited in linear space before the shoulder so it gets grain & vignette too
  float4 h = hudTex.sample(lin, vUv);
  col = mix(col, h.rgb / max(h.a, 1e-4), h.a * p.hud);
  col = shoulder(col);
  col = mix(col, float3(0.8515) - col * 0.84, p.invert); // ink<->bone in linear-ish space
  col += C_BONE * p.flash;
  // vignette
  float v = sstep(0.95, 0.25, length(dc * float2(1.0, 0.8)));
  col *= mix(1.0, v, p.vignette);
  col *= (1.0 - p.fade);
  float3 s = toSRGB(sat(col));
  // film grain: two scales, stronger in mid-tones
#if PDOOM_SCALE == 1
  float g1 = hash12(fragCoord + fract(p.time * 13.37) * 1000.0) - 0.5;
  float g2 = hash12(floor(fragCoord / 2.0) + fract(p.time * 7.13) * 1000.0) - 0.5;
#else
  // output scale > 1: fine grain per physical px with its amplitude raised by PX_SCALE; coarse grain keeps
  // 2x2-logical-px cells
  float g1 = (hash12(fragCoord + fract(p.time * 13.37) * 1000.0) - 0.5) * PX_SCALE;
  float g2 = hash12(floor(fragCoord / PX_SCALE / 2.0) + fract(p.time * 7.13) * 1000.0) - 0.5;
#endif
  float lm = luma(s);
  float amt = p.grain * (0.55 + 1.2 * lm * (1.0 - lm));
  s += (g1 * 0.6 + g2 * 0.4) * amt;
  s += (hash12(fragCoord * 1.37 + p.time) - 0.5) / 255.0; // dither
  uint2 dst = p.flipRows > 0.5 ? uint2(gid.x, size.y - 1 - gid.y) : gid;
  out.write(float4(sat(s), 1.0), dst);
}
