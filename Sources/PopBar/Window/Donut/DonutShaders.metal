#include <metal_stdlib>
using namespace metal;

// The 3D "donut" wheel: a ray-marched torus (the main ring) plus the same tube swept
// along an arc (a group's second ring), lit as glass, casting a soft
// shadow onto the page below. Port of stage B of `docs/wheel-3d-donut.html`, which
// the user approved.
//
// Coordinates: points relative to the wheel's centre, y UP, z toward the viewer. The
// eye sits at (0, 0, P). Angles written "cw" run clockwise from twelve o'clock — the
// app's slice order.
//
// Uniforms arrive as a flat float array (see `DonutUniform` in DonutRenderer.swift),
// which keeps Swift and Metal from disagreeing about struct padding.

#define U_CX       0
#define U_CY       1
#define U_SCALE    2
#define U_R        3
#define U_r        4
#define U_K        5
#define U_M        6    // 9 floats, row-major
#define U_P        15
#define U_UNUSED16 16   // was the material (ceramic was removed)
#define U_DARK     17
#define U_GROOVE   18
#define U_BASE     19   // 3 floats, linear
#define U_BASEA    22
#define U_ACCENT   23   // 3 floats, linear
#define U_GROUND   26
#define U_SUBON    27
#define U_SUBMID   28
#define U_SUBSPAN  29
#define U_SUBR     30
#define U_SUBr     31
#define U_SUBN     32
#define U_SUBFULL  33
#define U_N        34
#define U_SHADOW   35
#define U_REACH    36
#define U_LIFT     37   // signed: + raises the hovered slice, - presses it
#define U_TINT     38   // how strongly the hovered slice takes the accent

constant float PI = 3.14159265;

struct Ctx {
    constant float *u;
    constant float *sel;      // per main slice, 0...1
    constant float *subSel;   // per child, 0...1
    float3x3 M;
};

struct VOut { float4 pos [[position]]; };

vertex VOut donutVertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VOut o; o.pos = float4(p[vid], 0, 1); return o;
}

static float cwAngle(float2 p) { float a = atan2(p.x, p.y); return a < 0 ? a + 2 * PI : a; }
static float wrapPI(float a) { return a - 2 * PI * floor((a + PI) / (2 * PI)); }

// main ring: slice index, the neighbour across the nearest divider, arc distance to it
static void sliceInfo(thread const Ctx &c, float2 p, thread int &idx, thread int &nb, thread float &bd) {
    int n = int(c.u[U_N]);
    float st = 2 * PI / float(n), f = cwAngle(p) / st;
    idx = int(floor(f)) % n; float fr = fract(f), rho = length(p);
    if (fr < 0.5) { bd = fr * st * rho; nb = (idx - 1 + n) % n; }
    else          { bd = (1 - fr) * st * rho; nb = (idx + 1) % n; }
}
static float selBlend(thread const Ctx &c, int i, int nb, float bd) {
    return mix(c.sel[nb], c.sel[i], smoothstep(-2.0, 2.0, bd));
}

// second ring: nearest point on its centre line, child index, neighbour and arc
// distance to the nearest divider (an arc's two ends have none; a full ring wraps)
static void subInfo(thread const Ctx &c, float2 p, thread float2 &cp, thread int &ci, thread int &cn, thread float &cbd) {
    constant float *u = c.u;
    int n = int(u[U_SUBN]);
    bool full = u[U_SUBFULL] > 0.5;
    float span = u[U_SUBSPAN], R = u[U_SUBR], r = u[U_SUBr], mid = u[U_SUBMID];
    float d = wrapPI(cwAngle(p) - mid);
    // the round caps fill the rest of the span
    float hl = full ? 10.0 : max(span * 0.5 - r / max(R, 1.0), 0.0);
    float a = mid + clamp(d, -hl, hl);
    cp = R * float2(sin(a), cos(a));
    float st = span / float(n);
    float f = (d + span * 0.5) / max(st, 1e-4);
    float rho = length(p);
    if (full) {
        f = fmod(f + float(n) * 4, float(n));
        ci = int(floor(f)) % n; float fr = fract(f);
        if (fr < 0.5) { cbd = fr * st * rho; cn = (ci - 1 + n) % n; }
        else          { cbd = (1 - fr) * st * rho; cn = (ci + 1) % n; }
        return;
    }
    ci = clamp(int(floor(f)), 0, n - 1);
    float fr = clamp(f - float(ci), 0.0, 1.0);
    cbd = 1e4; cn = ci;
    if (ci > 0 && fr * st * rho < cbd)         { cbd = fr * st * rho; cn = ci - 1; }
    if (ci < n - 1 && (1 - fr) * st * rho < cbd) { cbd = (1 - fr) * st * rho; cn = ci + 1; }
}
static float subSelBlend(thread const Ctx &c, int ci, int cn, float cbd) {
    return mix(c.subSel[cn], c.subSel[ci], smoothstep(-2.0, 2.0, cbd));
}

// a window-shaped soft box up-left: what every reflective surface shows
static float softbox(float3 R) {
    if (R.z <= 0.05) return 0;
    float2 uv = R.xy / R.z; float2 q = abs(uv - float2(-0.55, 0.62)) - float2(0.34, 0.2);
    return 1 - smoothstep(-0.03, 0.10, max(q.x, q.y));
}
static float3 env(float3 R, float d) {
    float3 top = mix(float3(1.0), float3(0.34), d), hor = mix(float3(0.60, 0.62, 0.67), float3(0.10, 0.105, 0.12), d);
    float3 gnd = mix(float3(0.26, 0.26, 0.28), float3(0.02), d);
    float3 col = R.z > 0 ? mix(hor, top, pow(R.z, 0.6)) : mix(hor, gnd, pow(-R.z, 0.5));
    col += softbox(R) * mix(2.0, 1.5, d);
    col += pow(max(dot(R, normalize(float3(0.7, -0.6, 0.35))), 0.0), 14.0) * mix(0.3, 0.22, d);
    return col;
}

// N, V world; nL local normal; t = position across the tube (-1 inner edge ... +1 outer)
static float4 shade(thread const Ctx &c, float3 N, float3 V, float3 nL, float t, float sel, float seam, float occ) {
    constant float *u = c.u;
    float dark = u[U_DARK];
    float3 L = normalize(float3(-0.45, 0.55, 0.85));
    float NL = dot(N, L), NV = max(dot(N, V), 0.0);
    float3 H = normalize(L + V); float NH = max(dot(N, H), 0.0);
    float3 R = reflect(-V, N);
    float Fr = pow(1 - NV, 5.0);
    float3 amb = mix(mix(float3(0.30, 0.30, 0.32), float3(0.05, 0.05, 0.06), dark),
                     mix(float3(0.62, 0.64, 0.68), float3(0.20, 0.21, 0.24), dark), 0.5 + 0.5 * N.z);
    // the inner wall faces the hole and sees less light
    float ao = 1 - 0.22 * smoothstep(0.0, 1.0, -t) * (1 - nL.z);
    ao *= (1 - 0.38 * seam) * occ;
    float3 base = float3(u[U_BASE], u[U_BASE + 1], u[U_BASE + 2]);
    float3 accent = float3(u[U_ACCENT], u[U_ACCENT + 1], u[U_ACCENT + 2]);
    base = mix(base, accent, sel * u[U_TINT] * 0.55);
    float3 col; float a = 1;
    {                          // glass: the system's glass is underneath; here tint + light
        float edge = smoothstep(0.62, 0.98, abs(t));
        float3 body = base * (0.85 + 0.35 * max(NL, 0.0));
        // The edge only deepens a little: the system glass underneath already
        // draws a rim, and a strong grey band on top read as a grey ring.
        body = mix(body, mix(float3(0.78, 0.80, 0.86), float3(0.62, 0.66, 0.74), dark), edge);
        float aB = u[U_BASEA] + edge * mix(0.12, 0.22, dark) + 0.10 * sel;
        float F = 0.04 + 0.96 * Fr;
        float3 refl = F * env(R, dark) + F * softbox(R) * 8;
        float3 spec = float3(1.8 * pow(NH, 650.0) + 0.22 * pow(NH, 55.0));
        float2 cd = -normalize(L.xy);
        float cau = pow(max(dot(N.xy / max(length(N.xy), 1e-4), cd), 0.0), 3.0) * (1 - edge) * smoothstep(0.15, 0.7, abs(t)) * 0.28;
        float3 add = (refl * 0.55 + spec + cau) * (1 - 0.5 * seam);
        float3 pm = body * aB * ao + add;
        a = clamp(aB + dot(add, float3(0.3333)) * 0.85, 0.0, 1.0);
        col = pm / max(a, 1e-4);
    }
    col = pow(clamp(col, 0.0, 1.0), float3(1 / 2.2));
    return float4(col * a, a);
}

// ---------- signed distances; dividers carved
static float mainD(thread const Ctx &c, float3 p) {
    constant float *u = c.u;
    int i, nb; float bd; sliceInfo(c, p.xy, i, nb, bd);
    float z = p.z - u[U_LIFT] * selBlend(c, i, nb, bd);
    float2 q = float2(length(p.xy) - u[U_R], z / u[U_K]);
    return (length(q) - u[U_r]) * u[U_K] + u[U_GROOVE] * 1.1 * (1 - smoothstep(0.0, 1.6, bd));
}
static float subD(thread const Ctx &c, float3 p) {
    constant float *u = c.u;
    if (u[U_SUBON] < 0.5) return 1e5;
    float2 cp; int ci, cn; float cbd; subInfo(c, p.xy, cp, ci, cn, cbd);
    float z = p.z - u[U_LIFT] * subSelBlend(c, ci, cn, cbd);
    float3 v = float3(p.xy - cp, z / u[U_K]);
    return (length(v) - u[U_SUBr]) * u[U_K] + u[U_GROOVE] * 1.1 * (1 - smoothstep(0.0, 1.6, cbd));
}
static float mapD(thread const Ctx &c, float3 p) { return min(mainD(c, p), subD(c, p)); }
static float3 calcN(thread const Ctx &c, float3 p) {
    float2 e = float2(0.04, -0.04);
    return normalize(e.xyy * mapD(c, p + e.xyy) + e.yyx * mapD(c, p + e.yyx) + e.yxy * mapD(c, p + e.yxy) + e.xxx * mapD(c, p + e.xxx));
}
static float boundR(thread const Ctx &c) {
    constant float *u = c.u;
    return max(u[U_R] + u[U_r], u[U_SUBON] > 0.5 ? u[U_SUBR] + u[U_SUBr] : 0.0) + abs(u[U_LIFT]) + 3;
}
static bool march(thread const Ctx &c, float3 ro, float3 rd, thread float &t, thread float &dmin) {
    float Rb = boundR(c); dmin = 1e5;
    float b = dot(ro, rd), cc = dot(ro, ro) - Rb * Rb, h = b * b - cc;
    if (h < 0) return false;
    h = sqrt(h); t = -b - h; float tmax = -b + h;
    for (int k = 0; k < 140; k++) {
        float d = mapD(c, ro + rd * t); dmin = min(dmin, d);
        if (d < 0.01) return true;
        t += d * 0.7; if (t > tmax) return false;
    }
    return false;
}
static float softShadow(thread const Ctx &c, float3 ro, float3 rd) {
    float res = 1, t = 1;
    for (int k = 0; k < 44; k++) {
        float h = mapD(c, ro + rd * t);
        res = min(res, 3.2 * h / t);
        t += clamp(h, 1.0, 14.0);
        if (res < 0.001 || t > 260) break;
    }
    return clamp(res, 0.0, 1.0);
}

// edge = 1 when this pixel needs super-sampling (silhouette, grazing angle, a divider)
static float4 sampleAt(thread const Ctx &c, float2 p, thread float &edge) {
    constant float *u = c.u;
    float P = u[U_P];
    float3 roW = float3(0, 0, P), rdW = normalize(float3(p, -P));
    float3x3 Mt = transpose(c.M);
    float3 ro = Mt * roW, rd = Mt * rdW; float t, dmin;
    if (march(c, ro, rd, t, dmin)) {
        float3 pos = ro + rd * t; float3 nL = calcN(c, pos); float3 nW = c.M * nL;
        float tt, sel, seam, occ = 1;
        // Where a slice sits lower than its neighbour, the neighbour's wall shades it:
        // real geometry, so a pressed slice reads as pressed, not just recoloured.
        float lift = u[U_LIFT];
        if (subD(c, pos) < mainD(c, pos)) {
            float2 cp; int ci, cn; float cbd; subInfo(c, pos.xy, cp, ci, cn, cbd);
            float2 v = pos.xy - cp;
            tt = clamp(dot(v, cp / max(length(cp), 1e-3)) / u[U_SUBr], -1.0, 1.0);
            sel = subSelBlend(c, ci, cn, cbd); seam = u[U_GROOVE] * (1 - smoothstep(0.0, 1.4, cbd));
            if (lift != 0) { float dz = (c.subSel[cn] - c.subSel[ci]) * sign(lift); occ = 1 - 0.35 * max(dz, 0.0) * (1 - smoothstep(0.0, 5.0, cbd)); }
        } else {
            int i, nb; float bd; sliceInfo(c, pos.xy, i, nb, bd);
            tt = clamp((length(pos.xy) - u[U_R]) / u[U_r], -1.0, 1.0);
            sel = selBlend(c, i, nb, bd); seam = u[U_GROOVE] * (1 - smoothstep(0.0, 1.4, bd));
            if (lift != 0) { float dz = (c.sel[nb] - c.sel[i]) * sign(lift); occ = 1 - 0.35 * max(dz, 0.0) * (1 - smoothstep(0.0, 5.0, bd)); }
        }
        edge = (dot(nW, -rdW) < 0.45 || seam > 0.02) ? 1 : 0;
        return shade(c, nW, -rdW, nL, tt, sel, seam, occ);
    }
    edge = dmin * u[U_SCALE] < 2 ? 1 : 0;
    // missed: the ray lands on the page below — the soft shadow the ring casts.
    // (It is drawn in a window that ignores the mouse, so it can be as soft and wide
    // as it looks best; `reach` only bounds the work.)
    float3 gp = roW + rdW * ((-u[U_GROUND] - roW.z) / rdW.z);
    float3 Ls = normalize(float3(0, 0.32, 1));
    float sh = 1 - smoothstep(0.0, 1.0, softShadow(c, Mt * gp, Mt * Ls));
    float a = sh * u[U_SHADOW];
    // distance from the nearest solid, measured on the page
    float away = mapD(c, Mt * float3(gp.xy, 0));
    a *= 1 - smoothstep(u[U_REACH] * 0.45, u[U_REACH], away);
    if (a < 1.0 / 255.0) a = 0;
    return float4(0, 0, 0, a);
}

fragment float4 donutFragment(VOut in [[stage_in]],
                              constant float *u [[buffer(0)]],
                              constant float *sel [[buffer(1)]],
                              constant float *subSel [[buffer(2)]]) {
    Ctx c;
    c.u = u; c.sel = sel; c.subSel = subSel;
    // row-major floats -> float3x3 (Metal matrices are column-major)
    c.M = float3x3(float3(u[U_M + 0], u[U_M + 3], u[U_M + 6]),
                   float3(u[U_M + 1], u[U_M + 4], u[U_M + 7]),
                   float3(u[U_M + 2], u[U_M + 5], u[U_M + 8]));
    float s = u[U_SCALE];
    float2 center = float2(u[U_CX], u[U_CY]);
    // Metal's pixel origin is top-left with y down; flip to y up
    float2 px = in.pos.xy;
    float2 p0 = float2(px.x - center.x, center.y - px.y) / s;
    float edge;
    float4 c0 = sampleAt(c, p0, edge);
    if (edge < 0.5) return c0;
    const float2 offs[4] = { float2(-0.125, -0.375), float2(0.375, -0.125), float2(0.125, 0.375), float2(-0.375, 0.125) };
    float4 acc = 0; float e2;
    for (int k = 0; k < 4; k++) {
        float2 q = px + offs[k];
        acc += sampleAt(c, float2(q.x - center.x, center.y - q.y) / s, e2);
    }
    return acc * 0.25;
}
