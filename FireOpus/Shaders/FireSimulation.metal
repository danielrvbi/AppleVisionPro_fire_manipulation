// FireSimulation.metal
// GPU particle simulation for the fire VFX.
//
// One thread per particle. Each frame a particle is advanced (buoyancy, curl-noise
// turbulence, drag, cohesion to the moving "spine" curve), respawned along the spine
// when dead, and expanded into one quad (4 vertices) written straight into the
// RealityKit LowLevelMesh vertex buffer. The quad is NOT oriented here: all four
// vertices sit at the particle centre and carry the stretch axis + half-extents; the
// ShaderGraph geometry modifier billboards them per eye on the GPU.

#include <metal_stdlib>
using namespace metal;

struct Particle {
    float4 posAge;   // xyz position (entity space, metres), w age (s); age < 0 => waiting
    float4 velLife;  // xyz velocity (m/s), w lifetime (s); 0 => dead
    float4 misc;     // x seed, y spine parameter s, z size jitter, w heat at spawn
    float4 extra;    // xyz spawn offset from spine, w temperature jitter
};

struct SpinePoint {
    float4 posRadius; // xyz position, w radius (m)
    float4 velHeat;   // xyz velocity of that spine point, w heat / emission weight 0..1
};

struct LayerParams {
    float4 time;     // x time, y dt, z frame index, w global intensity 0..1
    uint4  counts;   // x active particles, y spine points, z capacity, w reset flag
    float4 life;     // x min life, y max life, z spawn radius factor, w spawn lift (x radius)
    float4 size;     // x start half-width, y peak half-width, z end half-width, w velocity stretch
    float4 motion;   // x buoyancy, y drag, z curl strength, w curl scale (1/m)
    float4 motion2;  // x curl speed, y cohesion, z inherit spine velocity, w flow along spine
    float4 heat;     // x temperature at birth, y temperature at death, z alpha scale, w max stretch factor
    float4 range;    // x s min, y s max, z axis mode (0 velocity, 1 up), w flow mode (0 forward, 1 to centre)
    float4 extra2;   // x cohesion decay exponent, y flicker, z reference radius, w spread growth
    float4 shape;    // x convergence toward the spine axis (horizontal), yzw reserved
};

struct FireVertex {
    float4 color;           // x temperature, y alpha, z age01, w seed
    packed_float3 position; // particle centre
    packed_float3 normal;   // unit stretch axis
    float2 uv0;             // quad corner 0..1
    float2 uv1;             // x half-width, y half-length (metres)
    float2 pad;
};

// ---------------------------------------------------------------- hashing
static inline uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
static inline float rand01(thread uint &s) {
    s = pcg(s);
    return float(s) * (1.0 / 4294967296.0);
}

// ---------------------------------------------------------------- simplex noise (Ashima / Gustavson)
static inline float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static inline float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static inline float4 permute(float4 x) { return mod289(((x * 34.0) + 10.0) * x); }
static inline float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

static float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);
    float3 i  = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);
    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);
    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;
    i = mod289(i);
    float4 p = permute(permute(permute(
                 i.z + float4(0.0, i1.z, i2.z, 1.0))
               + i.y + float4(0.0, i1.y, i2.y, 1.0))
               + i.x + float4(0.0, i1.x, i2.x, 1.0));
    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;
    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);
    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);
    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);
    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));
    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);
    float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
    float4 m = max(0.5 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 105.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

// Vector potential: three decorrelated noise fields, two octaves.
static inline float3 potential(float3 p) {
    const float3 o1 = float3(31.416, -47.853, 12.793);
    const float3 o2 = float3(-233.145, -113.408, -185.31);
    float3 a = float3(snoise(p), snoise(p + o1), snoise(p + o2));
    float3 q = p * 2.03 + float3(17.1, 3.7, -9.2);
    float3 b = float3(snoise(q), snoise(q + o1), snoise(q + o2));
    return a + 0.5 * b;
}

// Divergence-free turbulence (curl of the potential, central differences).
static float3 curlNoise(float3 p) {
    const float e = 0.06;
    const float3 dx = float3(e, 0, 0), dy = float3(0, e, 0), dz = float3(0, 0, e);
    float3 px0 = potential(p - dx), px1 = potential(p + dx);
    float3 py0 = potential(p - dy), py1 = potential(p + dy);
    float3 pz0 = potential(p - dz), pz1 = potential(p + dz);
    float x = (py1.z - py0.z) - (pz1.y - pz0.y);
    float y = (pz1.x - pz0.x) - (px1.z - px0.z);
    float z = (px1.y - px0.y) - (py1.x - py0.x);
    return float3(x, y, z) / (2.0 * e);
}

// ---------------------------------------------------------------- spine sampling
struct SpineSample { float3 pos; float radius; float3 vel; float heat; float3 tangent; };

static SpineSample sampleSpine(constant SpinePoint *spine, uint count, float s) {
    SpineSample o;
    if (count < 2) {
        o.pos = spine[0].posRadius.xyz; o.radius = spine[0].posRadius.w;
        o.vel = spine[0].velHeat.xyz;   o.heat = spine[0].velHeat.w;
        o.tangent = float3(0, 1, 0);
        return o;
    }
    float f = clamp(s, 0.0, 1.0) * float(count - 1);
    uint i = min(uint(floor(f)), count - 2);
    float t = f - float(i);
    SpinePoint a = spine[i], b = spine[i + 1];
    o.pos = mix(a.posRadius.xyz, b.posRadius.xyz, t);
    o.radius = mix(a.posRadius.w, b.posRadius.w, t);
    o.vel = mix(a.velHeat.xyz, b.velHeat.xyz, t);
    o.heat = mix(a.velHeat.w, b.velHeat.w, t);
    float3 d = b.posRadius.xyz - a.posRadius.xyz;
    float len = length(d);
    o.tangent = len > 1e-5 ? d / len : float3(0, 1, 0);
    return o;
}

// ---------------------------------------------------------------- kernel
kernel void simulateFire(device Particle *particles  [[buffer(0)]],
                         constant LayerParams &P     [[buffer(1)]],
                         constant SpinePoint *spine  [[buffer(2)]],
                         device FireVertex *verts    [[buffer(3)]],
                         uint id                     [[thread_position_in_grid]])
{
    if (id >= P.counts.z) return;

    const float time = P.time.x;
    const float dt = P.time.y;
    const float intensity = P.time.w;
    const uint spineCount = max(P.counts.y, 1u);
    const float3 up = float3(0, 1, 0);

    Particle p = particles[id];
    uint rng = pcg(id * 9781u + uint(P.time.z) * 6271u + 17u);

    if (P.counts.w != 0u) {
        // Reset: stagger births so the effect fades in instead of popping.
        float maxLife = max(P.life.y, 0.05);
        p.posAge = float4(0, 0, 0, -rand01(rng) * maxLife);
        p.velLife = float4(0);
        p.misc = float4(0);
        p.extra = float4(0);
    }

    float age = p.posAge.w + dt;
    float life = p.velLife.w;
    bool alive = (life > 0.0) && (age >= 0.0) && (age < life);
    const bool active = id < P.counts.x;

    if (!alive && age >= 0.0) {
        // Dead (or just finished waiting): try to respawn.
        bool spawned = false;
        if (active && dt > 0.0 && rand01(rng) < intensity) {
            float s = mix(P.range.x, P.range.y, rand01(rng));
            SpineSample sp = sampleSpine(spine, spineCount, s);
            if (rand01(rng) < sp.heat) {
                // point in a ball, biased toward the centre (hotter, denser core)
                float u = rand01(rng) * 2.0 - 1.0;
                float phi = rand01(rng) * 6.2831853;
                float rr = pow(rand01(rng), 0.6);
                float sq = sqrt(max(0.0, 1.0 - u * u));
                float3 dir = float3(sq * cos(phi), u, sq * sin(phi));
                float3 offset = dir * rr * sp.radius * P.life.z;

                float3 v0 = sp.vel * P.motion2.z;
                float flowSign = (P.range.w > 0.5) ? (s < 0.5 ? 1.0 : -1.0) : 1.0;
                v0 += sp.tangent * P.motion2.w * flowSign;
                v0 += dir * 0.03;

                float lifeT = mix(P.life.x, P.life.y, rand01(rng));
                p.posAge = float4(sp.pos + offset + up * P.life.w * sp.radius, 0.0);
                p.velLife = float4(v0, lifeT);
                p.misc = float4(rand01(rng), s, 0.7 + 0.6 * rand01(rng), sp.heat);
                p.extra = float4(offset, 0.85 + 0.3 * rand01(rng));
                age = 0.0;
                life = lifeT;
                spawned = true;
            }
        }
        if (!spawned) {
            p.velLife.w = 0.0;   // stays dead, retries next frame
            life = 0.0;
        }
        alive = spawned;
    }

    float3 pos = p.posAge.xyz;
    float3 vel = p.velLife.xyz;

    if (alive && dt > 0.0) {
        float a01 = clamp(age / life, 0.0, 1.0);
        SpineSample sp = sampleSpine(spine, spineCount, p.misc.y);

        // Turbulence: curl noise whose domain drifts downward => structures appear to rise.
        float3 q = pos * P.motion.w + float3(0.0, -time * P.motion2.x, time * 0.11);
        float3 turb = curlNoise(q);

        float hot = clamp(p.misc.w, 0.0, 1.0);
        float3 acc = up * P.motion.x * (0.55 + 0.45 * hot) * (1.0 - 0.35 * a01);
        acc += turb * P.motion.z * (0.35 + 0.9 * a01);
        acc -= vel * P.motion.y;

        // Cohesion: young particles stay glued to the (moving) spine, old ones break free.
        if (P.motion2.y > 0.0) {
            float k = P.motion2.y * pow(1.0 - a01, P.extra2.x);
            float3 target = sp.pos + p.extra.xyz * (1.0 + a01 * P.extra2.w);
            acc += (target - pos) * k;
            acc += (sp.vel - vel) * sqrt(k) * 1.6;
        }

        // Convergence: older gas is drawn toward the flame axis -> tongues meet in a tip.
        if (P.shape.x > 0.0) {
            float3 d = sp.pos - pos;
            d.y = 0.0;
            acc += d * P.shape.x * a01;
        }

        vel += acc * dt;
        pos += vel * dt;
    }

    p.posAge = float4(pos, age);
    p.velLife.xyz = vel;
    particles[id] = p;

    // ------------------------------------------------------------ emit quad
    float halfW = 0.0, halfL = 0.0, temp = 0.0, alpha = 0.0, a01 = 0.0;
    float3 axis = up;
    if (alive) {
        a01 = clamp(age / life, 0.0, 1.0);
        SpineSample sp = sampleSpine(spine, spineCount, p.misc.y);
        float rScale = clamp(sp.radius / max(P.extra2.z, 1e-4), 0.45, 2.2);

        float w = mix(P.size.x, P.size.y, smoothstep(0.0, 0.3, a01));
        w = mix(w, P.size.z, smoothstep(0.3, 1.0, a01));
        halfW = w * p.misc.z * rScale;

        float speed = length(vel);
        if (P.range.z < 0.5 && speed > 1e-4) {
            axis = vel / speed;
            halfL = halfW * min(1.0 + speed * P.size.w, P.heat.w);
        } else {
            halfL = halfW;
        }

        temp = mix(P.heat.x, P.heat.y, pow(a01, 0.75)) * p.extra.w * mix(0.55, 1.0, p.misc.w);
        alpha = smoothstep(0.0, 0.12, a01) * (1.0 - smoothstep(0.5, 1.0, a01)) * P.heat.z;
        if (P.extra2.y > 0.0) {
            float fl = 0.5 + 0.5 * sin(time * 23.0 + p.misc.x * 61.0) * sin(time * 7.3 + p.misc.x * 17.0);
            alpha *= mix(1.0, fl, P.extra2.y);
        }
    }

    FireVertex v;
    v.color = float4(temp, alpha, a01, p.misc.x);
    v.position = packed_float3(pos);
    v.normal = packed_float3(axis);
    v.uv1 = float2(halfW, halfL);
    v.pad = float2(0);
    uint base = id * 4u;
    v.uv0 = float2(0, 0); verts[base + 0] = v;
    v.uv0 = float2(1, 0); verts[base + 1] = v;
    v.uv0 = float2(0, 1); verts[base + 2] = v;
    v.uv0 = float2(1, 1); verts[base + 3] = v;
}
