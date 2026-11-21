// FIG. dense: two fullscreen fragment shaders (render pipeline with fs_vertex, no blending).
//   dense_gpu    app/src/scenes/dense-gpu.ts (GpuFloor): the 400 x 250 cell datacenter floor, the lyric spelled
//                by a mask texture (RGBA8 unorm, not sRGB, nearest filtered, uploaded in the TS row order:
//                row 0 = mask bottom). The TS source's heat3(a) is replaced by heat(clamp(a * 0.62, 0, 0.9)).
//   dense_askew  app/src/scenes/dense-askew.ts (Thing): ink, the leaning grid and the engraved tube mass.

constexpr sampler denseNearest(filter::nearest, address::clamp_to_edge, coord::normalized);

struct DenseGpuParams {
  float camCX, camCY, camZ, camRot, t;
  float prog0, prog1, prog2, prog3;     // prog
  float ghost0, ghost1, ghost2;         // ghost
  float beatT0, beatT1, beatT2, beatT3; // beatT
  float detail, heatK, lit;
};

fragment float4 dense_gpu(FSOut in [[stage_in]], texture2d<float> mask [[texture(0)]], constant DenseGpuParams& P [[buffer(0)]]) {
  const float2 G = float2(400.0, 250.0);
  const float2 WSIZE = float2(400.0 + 19.0 * 1.2, 250.0 + 24.0 * 2.0);
  float4 prog = float4(P.prog0, P.prog1, P.prog2, P.prog3);
  float3 ghost = float3(P.ghost0, P.ghost1, P.ghost2);
  float4 beatT = float4(P.beatT0, P.beatT1, P.beatT2, P.beatT3);
  float t = P.t;
  float2 px = (in.vUv - 0.5) * float2(1920.0, 1080.0);
  float2 w = rot2(P.camRot) * px / P.camZ + float2(P.camCX, P.camCY) + WSIZE * 0.5; // world units (1 = cell pitch)
  // invert layout: find pod/rack (pods of 20 columns, gap 1.2; rack rows of 10, aisle 2.0)
  float podW = 20.0 + 1.2, rackH = 10.0 + 2.0;
  float pod = floor(w.x / podW), rack = floor(w.y / rackH);
  float2 inPod = float2(w.x - pod * podW, w.y - rack * rackH);
  float2 cell = float2(pod * 20.0 + floor(inPod.x), rack * 10.0 + floor(inPod.y));
  float2 f = fract(inPod);
  bool valid = inPod.x < 20.0 && inPod.y < 10.0 && cell.x >= 0.0 && cell.y >= 0.0 && cell.x < G.x && cell.y < G.y;
  float3 col = C_INK * 0.9;
  // floor: faint tile grid in aisles
  float2 tile = fract(w / 3.0);
  float fw = fwidth(w.x) / 3.0;
  col += C_GRAPHITE * 0.05 * pxLine(min(tile.x, tile.y), 0.0, fw * 1.5);
  if (valid) {
    float4 m = mask.sample(denseNearest, (cell + 0.5) / G);
    float wi = floor(m.b * 4.0 + 0.5);
    float pr = wi < 0.5 ? prog.x : (wi < 1.5 ? prog.y : prog.z);
    float isTxt = step(0.5, m.r) * step(m.g, pr) * step(0.0001, pr);
    float ghostTxt = step(0.5, m.r) * (1.0 - isTxt) * (wi < 0.5 ? ghost.x : (wi < 1.5 ? ghost.y : ghost.z));
    // activity: travelling waves + beat rings + hashed flicker
    float h = hash12(cell);
    float2 cc = cell - G * 0.5;
    float a = 0.5 + 0.5 * sin(dot(cc, float2(0.035, 0.021)) - t * 5.0 + h * 0.8);
    a *= 0.5 + 0.5 * sin(dot(cc, float2(-0.012, 0.041)) + t * 3.3);
    for (int i = 0; i < 4; i++) {
      float dt = t - beatT[i];
      if (dt > 0.0 && dt < 1.2) {
        float r = dt * 260.0;
        float d = length(cc * float2(1.0, 1.25));
        float fr = d - r;
        a += (exp(-pow(fr / 3.5, 2.0)) * 1.4 + step(fr, 0.0) * exp(fr / 30.0) * 0.35) * exp(-dt * 2.2);
      }
    }
    float flick = step(0.975, hash12(cell + floor(t * 24.0)));
    a = clamp(a * (0.7 + 0.45 * h) + flick * 0.3, 0.0, 1.4) * P.heatK;
    // cell body (square with a 12% gap), die + HBM detail at close range
    float2 q = f - 0.5;
    float aa = fwidth(q.x) * 1.2;
    // the cell edge keeps its 1x softness in logical px (the colour is ~body^2, so a sharper edge brightens the floor)
    float aaB = aa * PX_SCALE;
    float body = 1.0 - sstep(0.41 - aaB, 0.41 + aaB, max(abs(q.x), abs(q.y)));
    float die = 1.0 - sstep(0.16 - aa, 0.16 + aa, max(abs(q.x), abs(q.y)));
    float2 hq = abs(q) - float2(0.27, 0.27);
    float hbm = (1.0 - sstep(0.05 - aa, 0.05 + aa, max(abs(hq.x), abs(hq.y) - 0.04))) * P.detail;
    float led = (1.0 - sstep(0.03 - aa, 0.03 + aa, length(q - float2(0.32, -0.32)))) * P.detail;
    float3 idle = C_INK2 * 1.6 + C_GRAPHITE * 0.12;
    float3 hot = heat(clamp(a * 0.62, 0.0, 0.9));
    float3 c = idle * body;
    c = mix(c, hot * 0.9 + idle * 0.3, body * (1.0 - P.detail * 0.55) * sstep(0.05, 0.9, a));
    c += hot * die * P.detail * (0.6 + a);
    c += C_GRAPHITE * 0.5 * hbm;
    c += C_EMBER * 2.0 * led * step(0.5, fract(h * 13.0 + t * 2.0));
    // lyric cells: solid bone, slightly glowing edge
    c = mix(c, C_BONE * (0.92 + 0.08 * die) * P.lit, isTxt * body);
    c = mix(c, C_BONE * 0.22, ghostTxt * body);
    col = mix(col, c, body) + c * (1.0 - body) * 0.0;
  }
  return float4(col, 1.0);
}

struct DenseAskewParams {
  float homeX, homeY, R, t, reach;
  float camRoll, camZoom, camPanX, camPanY, camShakeX, camShakeY;
  float eyeOpen, eyeLook, glow, throb;
  float gridShear, gridA, horizonY;
};

constant int ASKEW_NT = 16; // tentacles
constant int ASKEW_NP = 12; // polyline points per tentacle

// tentacle centre line point (mask units, y down), s in 0..1
inline float2 askewPt(int i, float s, constant DenseAskewParams& P) {
  float fi = float(i);
  float th = fi / 16.0 * TAU + hash11(fi * 3.1) * 1.2;
  float curl = (hash11(fi * 7.7) - 0.5) * 4.0;
  float r0 = 0.05 + 0.45 * hash11(fi * 2.3);
  float ext = (0.88 - r0) + P.reach * (0.22 + 0.4 * hash11(fi * 1.9)) * step(0.22, hash11(fi * 4.1));
  float r = r0 + ext * s;
  float ph = th + curl * s + (0.25 + 0.12 * P.reach) * sin(P.t * (1.3 + hash11(fi) * 0.9) + fi * 1.7 + s * 4.0) * s * (0.4 + P.reach);
  return float2(cos(ph), sin(ph)) * r;
}
inline float askewWidth(int i, float s, constant DenseAskewParams& P) { return (0.22 + 0.13 * hash11(float(i) * 5.3)) * (1.0 + 0.1 * P.throb) * mix(1.0, 0.16, pow(s, 1.2)); }
/** Anti-aliased hairline at integer u (about 1 px wide on screen). Fragment only. */
inline float askewHair(float u) { float d = abs(fract(u + 0.5) - 0.5) / max(fwidth(u), 1e-5); return pxLine(d, 0.35, 1.2); }

fragment float4 dense_askew(FSOut in [[stage_in]], constant DenseAskewParams& P [[buffer(0)]]) {
  float t = P.t;
  float2 px = in.vUv * float2(1920.0, 1080.0);
  px.y = 1080.0 - px.y; // y down like Canvas2D
  float2 c = float2(960.0, 540.0);
  float2 q = c + float2(P.camPanX, P.camPanY) + rot2(P.camRoll) * (px - c - float2(P.camShakeX, P.camShakeY)) / P.camZoom; // screen -> world
  float2 p = (q - float2(P.homeX, P.homeY)) / P.R;          // mask units
  // background: ink with a leaning registration grid (sheared about the horizon)
  float3 col = C_INK;
  float2 g = float2(q.x - P.gridShear * (q.y - P.horizonY), q.y - P.horizonY) / 120.0;
  float gl = max(askewHair(g.x), askewHair(g.y));
  float gm = max(askewHair(g.x / 4.0), askewHair(g.y / 4.0));
  col += C_GRAPHITE * (gl * 0.05 + gm * 0.07) * P.gridA;
  float rr = length(p);
  if (rr < 2.8) {
    // the mass: a dark body (radius ~1.02) + tubes
    float bang = atan2(p.y, p.x);
    float bodyD = rr - (0.97 + 0.05 * sin(bang * 6.0 + 1.3) + 0.03 * sin(bang * 11.0 - t * 0.7));
    // nearest point on each tube (min over its segments); higher-index tubes lie on top
    float bc = 1.0; float bs = 0.0; float bi = -1.0; float bside = 0.0; float bu = 0.0; float bw = 0.1; float under = 0.0; float2 bn = float2(0.0);
    for (int i = 0; i < ASKEW_NT; i++) {
      float2 a = askewPt(i, 0.0, P);
      float acc = 0.0;
      float ci = 1e9, cs = 0.0, cside = 0.0, cu = 0.0, cw = 0.1; float2 cn = float2(0.0);
      for (int k = 1; k < ASKEW_NP; k++) {
        float s1 = float(k) / 11.0;
        float2 b = askewPt(i, s1, P);
        float2 pa = p - a, ba = b - a;
        float L = length(ba);
        float h = clamp(dot(pa, ba) / (L * L), 0.0, 1.0);
        float2 d = pa - ba * h;
        float s = s1 - (1.0 - h) / 11.0;
        float w = askewWidth(i, s, P);
        float cc = length(d) / w;
        if (cc < ci) { ci = cc; cs = s; cside = sign(ba.x * d.y - ba.y * d.x); cu = acc + h * L; cw = w; cn = d / w; }
        acc += L;
        a = b;
      }
      if (ci < 1.0) { if (bi >= 0.0) under = 1.0; bc = ci; bs = cs; bi = float(i); bside = cside; bu = cu; bw = cw; bn = cn; }
    }
    float inBody = 1.0 - sstep(-0.01, 0.01, bodyD);
    float inTube = step(0.0, bi);
    if (inBody > 0.0 || inTube > 0.0) {
      float3 m = C_INK * 0.55;
      if (inTube > 0.0) {
        // scratchboard engraving: bone lines cut into black, rings around the tube that bow with its
        // curvature, wider where lit; a second set along the tube in the highlights; the back-lit edge
        // turns ember; an ink contour where tubes overlap
        float ac = bside * bc;                 // -1..1 across the tube
        float z = sqrt(max(0.0, 1.0 - bc * bc));
        // one key light from the upper left (mask space, y down)
        float3 nrm = float3(bn, z);
        float light = sat(dot(nrm, normalize(float3(-0.6, -0.7, 0.5))) * 1.15);
        float sp = 0.026;
        float u = (bu - 0.55 * bw * z) / sp;
        u += 0.22 * sin(bu * 7.0 + bi * 1.7) + 0.08 * sin(asin(clamp(ac, -1.0, 1.0)) * 3.0 + bi); // hand-cut wobble
        float wA = pow(light, 1.3) * 0.46;
        float la = hatch(u, wA);
        float lb = hatch(asin(clamp(ac, -1.0, 1.0)) * 5.0 + bi * 0.37, sat(light * 2.5 - 2.2) * 0.45);
        float lines = max(la, lb);
        float3 cc3 = C_BONE * lines * (0.3 + 0.5 * light);
        float rim = sstep(0.7, 0.98, bc) * sstep(0.1, 0.6, dot(normalize(bn + 1e-5), normalize(float2(0.6, 0.7))));
        float rl = hatch(u, rim * 0.8);
        cc3 = mix(cc3, C_EMBER * 1.2 * max(rl, lines), sstep(0.08, 0.6, rim) * P.glow);
        cc3 += C_SIGNAL * 0.9 * pow(rim, 3.0) * P.glow;
        // the tip fades into the dark (tentacles taper away from the light)
        cc3 *= 1.0 - 0.5 * sstep(0.6, 1.0, bs);
        // silhouette contour (strong where this tube crosses another)
        cc3 *= 1.0 - (0.55 + 0.4 * under) * sstep(0.9, 0.995, bc);
        m = C_INK * 0.12 + cc3;
      } else {
        // body between tubes: contour lines around the core, lit from upper left
        float2 bp = p;
        float lb2 = sat(0.35 - 0.45 * (bp.x + bp.y) / max(0.2, length(bp)) * sstep(0.1, 0.9, rr));
        float e = hatch(rr / 0.028 + 0.8 * sin(bang * 5.0 + rr * 6.0) + 0.3 * sin(bang * 13.0), lb2 * 0.35);
        m = C_INK * 0.1 + C_BONE * 0.13 * e * lb2;
      }
      // the eye (upper left of the mass)
      float2 ep = p - float2(-0.5, -0.62);
      float er = 0.25;
      float lid = abs(ep.y) - er * P.eyeOpen * sqrt(max(0.0, 1.0 - pow(ep.x / er, 2.0)));
      if (length(ep / float2(1.0, 0.75)) < er * 1.05 && P.eyeOpen > 0.01 && lid < 0.0) {
        float2 ip = ep - float2(P.eyeLook * 0.06, 0.0);
        float ir = length(ip);
        float ang = atan2(ip.y, ip.x);
        float fib = 0.5 + 0.5 * sin(ang * 60.0 + hash11(floor(ang * 9.0)) * 6.0);
        ip /= 1.25;
        ir = length(ip);
        // sclera: engraved rings around the iris, dim bone, lit from the upper left
        float sl = sat(0.55 - 2.2 * (ip.x + ip.y));
        float3 sclera = C_INK * 0.15 + C_BONE * 0.45 * hatch(ir / 0.017, sl * 0.7) * sl;
        float3 iris = mix(C_BLOOD, C_EMBER * 1.8, fib * sstep(0.13, 0.03, ir)) * 1.3 * (0.8 + 0.4 * P.glow);
        float pupil = step(abs(ip.x), 0.018 + 0.012 * P.eyeOpen) * step(ir, 0.12);
        float3 ec = mix(sclera, iris, sstep(0.125, 0.115, ir));
        ec = mix(ec, C_INK * 0.1, pupil);
        ec += C_BONE * 2.0 * sstep(0.022, 0.0, length(ip - float2(-0.04, -0.045)));
        m = ec;
      } else if (P.eyeOpen > 0.01 && abs(lid) < 0.012 && length(ep) < er * 1.1) {
        m = C_SIGNAL * 1.2 * P.glow;
      }
      col = m;
    }
  }
  return float4(col, 1.0);
}
