// FIG. hook (app/src/scenes/hook.ts, COMP): composites the scene's type layer over its background colour,
// with the radial echo of the maximal hook and the signal-orange glow. `tex` is the Canvas2D layer as
// three.js samples it: straight alpha, colour decoded to linear, row 0 = image bottom.

struct HookCompParams {
  float bgR, bgG, bgB; // bgCol (linear)
  float echo, hot, gain;
};

kernel void hook_comp(texture2d<float, access::sample> tex [[texture(0)]],
                      texture2d<float, access::write> out [[texture(1)]],
                      constant HookCompParams& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
  uint2 size = uint2(out.get_width(), out.get_height());
  if (gid.x >= size.x || gid.y >= size.y) return;
  float2 vUv = (float2(gid) + 0.5) / float2(size);
  float4 s = tex.sample(lin, vUv);
  if (p.echo > 0.0) {
    // radial echo (zoom trails) for the maximal hook
    float4 acc = float4(0.0); float wsum = 0.0;
    for (int i = 0; i < 6; i++) {
      float k = float(i) / 5.0;
      float4 e = tex.sample(lin, mix(vUv, float2(0.5), k * p.echo));
      float w = 1.0 - k * 0.8;
      acc += float4(e.rgb * e.a, e.a) * w; wsum += w;
    }
    acc /= wsum;
    s = float4(acc.rgb / max(acc.a, 1e-3), max(s.a, acc.a));
  }
  // signal-orange type glows (only the signal colour exceeds the bloom threshold); gain = white-hot
  float h = sstep(0.25, 0.7, s.r - s.g * 1.3);
  float3 col = mix(float3(p.bgR, p.bgG, p.bgB), s.rgb * (1.0 + p.hot * h) * p.gain, s.a);
  out.write(float4(col, 1.0), gid);
}
