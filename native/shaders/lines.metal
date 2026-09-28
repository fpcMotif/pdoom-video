// LineBatch (app/src/engine/lines.ts): instanced anti-aliased capsule segments, in 2D logical px (x right,
// y down) or 3D through a camera. Render pipeline lines_vertex + lines_fragment; draw 6 vertices per
// instance (two triangles of the quad), instanceCount = segment count.
// Per-segment data in four float buffers laid out as LineBatch's Float32Arrays: a (3 per segment),
// b (3), color (4: linear rgb * intensity, alpha), width (1).
// Blending (colour and alpha alike): add = one/one; max = operation max; normal = one/oneMinusSourceAlpha.
// Depth: write off; test off unless the batch was made with depthTest (three.js LessEqual).

struct LineParams {
  float4x4 projection;   // camera.projectionMatrix.elements (column-major, as three.js stores them)
  float4x4 modelView;    // camera.matrixWorldInverse.elements (the batch mesh has an identity transform)
  float resX, resY;      // target size in logical px
  float screen2D, worldWidth, widthScale;
  float pxScale;         // physical px per logical px of the target
  float premultiply;     // 1 (LineBatch never turns it off)
  float pad;
};

inline float4 lineToClip(float3 p, constant LineParams& u) {
  if (u.screen2D > 0.5) return float4(p.x / u.resX * 2.0 - 1.0, 1.0 - p.y / u.resY * 2.0, p.z, 1.0);
  return u.projection * u.modelView * float4(p, 1.0);
}

struct LineOut {
  float4 position [[position]];
  float2 vLocal;
  float vLen, vHalfW;
  float4 vColor;
};

vertex LineOut lines_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device float* a [[buffer(0)]], const device float* b [[buffer(1)]],
                            const device float* color [[buffer(2)]], const device float* width [[buffer(3)]],
                            constant LineParams& u [[buffer(4)]]) {
  // quad corners (x along the segment in {0,1}, y across in {-1,1}), indexed 0 1 2 0 2 3 as in lines.ts
  const float2 quad[4] = { float2(0, -1), float2(1, -1), float2(1, 1), float2(0, 1) };
  const uint index[6] = { 0, 1, 2, 0, 2, 3 };
  float2 position = quad[index[vid]];
  float3 iA = float3(a[iid * 3], a[iid * 3 + 1], a[iid * 3 + 2]);
  float3 iB = float3(b[iid * 3], b[iid * 3 + 1], b[iid * 3 + 2]);
  float4 iColor = float4(color[iid * 4], color[iid * 4 + 1], color[iid * 4 + 2], color[iid * 4 + 3]);
  float iWidth = width[iid];
  float2 res = float2(u.resX, u.resY);
  bool screen2D = u.screen2D > 0.5, worldWidth = u.worldWidth > 0.5;
  LineOut o;
  float4 ca = lineToClip(iA, u), cb = lineToClip(iB, u);
  // clip against near plane crudely: skip segments behind camera
  if (ca.w <= 0.0 || cb.w <= 0.0) { o.position = float4(2.0, 2.0, 2.0, 1.0); o.vLocal = 0; o.vLen = 0; o.vHalfW = 0; o.vColor = 0; return o; }
  float2 sa = ca.xy / ca.w * 0.5 * res * u.pxScale, sb = cb.xy / cb.w * 0.5 * res * u.pxScale; // physical px, centred
  float w = iWidth * u.widthScale * u.pxScale;
  if (worldWidth && !screen2D) {
    // approximate world width -> pixels using projection scale at each end
    float pa = u.projection[1][1] * 0.5 * res.y * u.pxScale / ca.w, pb = u.projection[1][1] * 0.5 * res.y * u.pxScale / cb.w;
    w = iWidth * u.widthScale * mix(pa, pb, position.x);
  }
  float hw = max(w * 0.5, 0.35) + 1.0; // +1px for AA
  float2 d = sb - sa; float len = length(d);
  float2 dir = len > 1e-4 ? d / len : float2(1.0, 0.0);
  float2 nrm = float2(-dir.y, dir.x);
  float along = mix(-hw, len + hw, position.x);
  float2 p = sa + dir * along + nrm * position.y * hw;
  float z = mix(ca.z / ca.w, cb.z / cb.w, position.x);
  float2 ndc = p / (0.5 * res * u.pxScale);
  // -y: memory row 0 = image bottom (see common.metal); WebGL depth [-1, 1] -> Metal [0, 1]
  o.position = float4(ndc.x, -ndc.y, z * 0.5 + 0.5, 1.0);
  o.vLocal = float2(along, position.y * hw);
  o.vLen = len; o.vHalfW = max(w * 0.5, 0.35);
  // thin lines fade instead of shrinking below 0.7px (keeps hairlines smooth)
  o.vColor = iColor * float4(1.0, 1.0, 1.0, min(1.0, w / 0.7));
  return o;
}

fragment float4 lines_fragment(LineOut in [[stage_in]], constant LineParams& u [[buffer(0)]]) {
  float x = clamp(in.vLocal.x, 0.0, in.vLen);
  float d = length(float2(in.vLocal.x - x, in.vLocal.y)) - in.vHalfW; // capsule SDF in px
  float a = clamp(0.5 - d, 0.0, 1.0) * in.vColor.a;
  if (a <= 0.0) discard_fragment();
  return u.premultiply > 0.5 ? float4(in.vColor.rgb * a, a) : float4(in.vColor.rgb, a);
}
