// Diagnostic pattern for checking the output path (docs/NATIVE_METAL_PIPELINE.md, "Diagnostic pattern").
// native/verify/verify.ts holds the same definition and checks decoded videos against it.
// Writes 8-bit sRGB codes straight into the encoder-facing image: row 0 = TOP (no post, no flip).
// Coordinates below are logical px (u, v) = physical px / PDOOM_SCALE, v down from the top.

struct DiagParams { float frame; };

inline float3 diagColor(uint2 px, uint frame) {
  const uint S = PDOOM_SCALE;
  float u = float(px.x) / float(S), v = float(px.y) / float(S);
  // corners, 192 x 192: red TL, green TR, blue BL, yellow BR
  if (u < 192.0 && v < 192.0) return float3(255, 0, 0);
  if (u >= 1728.0 && v < 192.0) return float3(0, 255, 0);
  if (u < 192.0 && v >= 888.0) return float3(0, 0, 255);
  if (u >= 1728.0 && v >= 888.0) return float3(255, 255, 0);
  bool band = u >= 256.0 && u < 1664.0;
  // grey ramp: level = floor((x - 256 S) * 256 / (1408 S))
  if (band && v >= 440.0 && v < 520.0) return float3(min(255u, (px.x - 256 * S) * 256 / (1408 * S)));
  // 1-physical-px white lines every 8 physical px on black
  if (band && v >= 560.0 && v < 640.0) return float3(px.x % 8 == 0 ? 255 : 0);
  // moving bar, 16 wide, at u = 256 + (8 frame mod 1392), on black
  if (band && v >= 680.0 && v < 760.0) {
    float bx = 256.0 + float((8 * frame) % 1392);
    return float3(u >= bx && u < bx + 16.0 ? 255 : 0);
  }
  // frame id: guard cells (white 384..448, black 1472..1536), then 16 bits MSB first, 64 wide from u = 448
  if (v >= 800.0 && v < 864.0) {
    if (u >= 384.0 && u < 448.0) return float3(255);
    if (u >= 1472.0 && u < 1536.0) return float3(0);
    if (u >= 448.0 && u < 1472.0) {
      uint bit = 15 - uint((u - 448.0) / 64.0);
      return float3(((frame >> bit) & 1u) != 0 ? 255 : 0);
    }
  }
  return float3(128);
}

kernel void diag_pattern(texture2d<float, access::write> out [[texture(0)]],
                         constant DiagParams& p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
  out.write(float4(diagColor(gid, uint(p.frame)) / 255.0, 1.0), gid);
}
