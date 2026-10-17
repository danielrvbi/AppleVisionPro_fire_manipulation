// NoiseTexture.metal
// Generates the tileable flame-detail texture used by the fire materials (run once at startup).
//   R: billowy fbm           -> ragged flame-tongue silhouettes
//   G: ridged multifractal    -> thin bright filaments / veins inside the flame
//   B: vertically stretched fbm -> wispy smoke structure
//   A: secondary fbm (decorrelated) -> extra breakup

#include <metal_stdlib>
using namespace metal;

static inline uint hash2(int2 p, uint seed) {
    uint h = uint(p.x) * 73856093u ^ uint(p.y) * 19349663u ^ seed * 83492791u;
    h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
    return h;
}

static inline float2 gradient(int2 cell, int period, uint seed) {
    int2 c = int2((cell.x % period + period) % period, (cell.y % period + period) % period);
    float a = float(hash2(c, seed) & 0xffffu) * (6.2831853 / 65536.0);
    return float2(cos(a), sin(a));
}

// Periodic Perlin gradient noise in [-1, 1] approximately; `period` in cells.
static float pnoise(float2 p, int period, uint seed) {
    int2 i = int2(floor(p));
    float2 f = p - floor(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float n00 = dot(gradient(i + int2(0, 0), period, seed), f - float2(0, 0));
    float n10 = dot(gradient(i + int2(1, 0), period, seed), f - float2(1, 0));
    float n01 = dot(gradient(i + int2(0, 1), period, seed), f - float2(0, 1));
    float n11 = dot(gradient(i + int2(1, 1), period, seed), f - float2(1, 1));
    return mix(mix(n00, n10, u.x), mix(n01, n11, u.x), u.y) * 1.414;
}

static float fbm(float2 uv, int basePeriod, int octaves, uint seed) {
    float sum = 0.0, amp = 0.5, norm = 0.0;
    int period = basePeriod;
    for (int o = 0; o < octaves; ++o) {
        sum += amp * pnoise(uv * float(period), period, seed + uint(o) * 101u);
        norm += amp;
        amp *= 0.5;
        period *= 2;
    }
    return sum / norm;
}

static float ridged(float2 uv, int basePeriod, int octaves, uint seed) {
    float sum = 0.0, amp = 0.55, norm = 0.0, prev = 1.0;
    int period = basePeriod;
    for (int o = 0; o < octaves; ++o) {
        float n = 1.0 - abs(pnoise(uv * float(period), period, seed + uint(o) * 131u));
        n = n * n;
        sum += amp * n * prev;
        norm += amp;
        prev = clamp(n * 1.6, 0.0, 1.0);
        amp *= 0.5;
        period *= 2;
    }
    return sum / norm;
}

kernel void generateFireNoise(texture2d<float, access::write> out [[texture(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid) + 0.5) / float2(w, h);

    // Domain warp (still periodic because the warp itself is periodic).
    float2 warp = float2(fbm(uv, 3, 3, 7u), fbm(uv, 3, 3, 13u)) * 0.12;
    float2 wuv = uv + warp;

    float r = fbm(wuv, 4, 5, 1u) * 0.5 + 0.5;
    r = smoothstep(0.18, 0.82, r);

    float g = ridged(wuv + float2(0.37, 0.11), 3, 5, 3u);
    g = smoothstep(0.25, 0.95, g);

    // Smoke: elongated along v (anisotropic periods: 2 cells across u, 6 along... handled by scaling)
    float2 suv = float2(uv.x, uv.y);
    float b = fbm(suv + warp * 1.5, 3, 5, 5u) * 0.5 + 0.5;
    b = smoothstep(0.2, 0.85, b);

    float a = fbm(wuv + float2(0.71, 0.29), 5, 4, 11u) * 0.5 + 0.5;

    out.write(float4(r, g, b, a), gid);
}
