import Foundation
import simd

/// The three fire forms. Each turns one or two control points into a "spine": a polyline with
/// radius and heat that the GPU particles are emitted from and held to.
enum FireMode: String, CaseIterable, Identifiable, Sendable {
    case livingFlame
    case flowingRibbon
    case twoHandArc

    var id: String { rawValue }
    var title: String {
        switch self {
        case .livingFlame: "Living Flame"
        case .flowingRibbon: "Flowing Ribbon"
        case .twoHandArc: "Two-Hand Arc"
        }
    }
    /// How many control points the form consumes (hand tracking: 1 = one palm, 2 = both palms).
    var controlPointCount: Int { self == .twoHandArc ? 2 : 1 }
}

let spinePointCount = 48
private let worldUp = SIMD3<Float>(0, 1, 0)

/// Per-form tuning that is blended during transitions.
struct ModeStyle {
    var density: Float        // fraction of particle capacity in use
    var buoyancy: Float       // scales upward acceleration
    var cohesion: Float       // spring pulling young particles to the spine
    var cohesionDecay: Float  // how quickly particles break free with age
    var inherit: Float        // fraction of spine velocity given to new particles
    var flowAlong: Float      // m/s along the spine tangent
    var flowToCentre: Float   // 1 => flow from both ends toward the middle
    var lifeScale: Float
    var spreadGrowth: Float
    var alphaScale: Float
    var smokeLift: Float      // where smoke is born, in spine radii above the spine
    var converge: Float = 0   // horizontal pull of aging flame toward the axis (living flame)

    static func style(for mode: FireMode) -> ModeStyle {
        switch mode {
        case .livingFlame:
            ModeStyle(density: 0.32, buoyancy: 1.0, cohesion: 0, cohesionDecay: 1, inherit: 0.35,
                      flowAlong: 0, flowToCentre: 0, lifeScale: 1.0, spreadGrowth: 0, alphaScale: 1.0, smokeLift: 5.0, converge: 9)
        case .flowingRibbon:
            ModeStyle(density: 0.8, buoyancy: 0.8, cohesion: 38, cohesionDecay: 2.6, inherit: 0.55,
                      flowAlong: 0.0, flowToCentre: 0, lifeScale: 1.0, spreadGrowth: 1.2, alphaScale: 0.55, smokeLift: 2.5)
        case .twoHandArc:
            ModeStyle(density: 0.8, buoyancy: 0.85, cohesion: 32, cohesionDecay: 2.4, inherit: 0.4,
                      flowAlong: 0.12, flowToCentre: 1, lifeScale: 1.0, spreadGrowth: 1.0, alphaScale: 0.55, smokeLift: 2.8)
        }
    }

    static func lerp(_ a: ModeStyle, _ b: ModeStyle, _ t: Float) -> ModeStyle {
        func m(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        return ModeStyle(density: m(a.density, b.density), buoyancy: m(a.buoyancy, b.buoyancy),
                         cohesion: m(a.cohesion, b.cohesion), cohesionDecay: m(a.cohesionDecay, b.cohesionDecay),
                         inherit: m(a.inherit, b.inherit), flowAlong: m(a.flowAlong, b.flowAlong),
                         flowToCentre: m(a.flowToCentre, b.flowToCentre), lifeScale: m(a.lifeScale, b.lifeScale),
                         spreadGrowth: m(a.spreadGrowth, b.spreadGrowth), alphaScale: m(a.alphaScale, b.alphaScale),
                         smokeLift: m(a.smokeLift, b.smokeLift), converge: m(a.converge, b.converge))
    }
}

/// Builds a spine from control points. Stateful shapes (the ribbon rope) keep their own simulation.
@MainActor
protocol SpineShape: AnyObject {
    func reset(primary: SIMD3<Float>, secondary: SIMD3<Float>)
    func update(primary: SIMD3<Float>, secondary: SIMD3<Float>, time: Float, dt: Float) -> [SpinePoint]
}

// MARK: - Living flame

/// A short vertical emitter column above one palm that gently "breathes".
@MainActor
final class LivingFlameShape: SpineShape {
    func reset(primary: SIMD3<Float>, secondary: SIMD3<Float>) {}

    func update(primary a: SIMD3<Float>, secondary _: SIMD3<Float>, time t: Float, dt _: Float) -> [SpinePoint] {
        let breath = 1 + 0.08 * sin(t * 1.7) + 0.05 * sin(t * 2.9 + 1.0)
        return (0..<spinePointCount).map { i in
            let s = Float(i) / Float(spinePointCount - 1)
            let sway = SIMD3<Float>(sin(t * 1.3 + s * 2.0), 0, cos(t * 1.1 + s * 1.7)) * 0.004 * s
            let p = a + worldUp * (s * 0.05) + sway
            let r = 0.034 * (1 - 0.55 * s) * breath
            return SpinePoint(position: p, radius: r, heat: 1 - 0.25 * s)
        }
    }
}

// MARK: - Flowing ribbon

/// A follow-the-leader rope: the head is the control point, the body coasts with inertia and is
/// dragged along with a maximum segment length, which gives the lag and momentum of motion_01.
@MainActor
final class RibbonShape: SpineShape {
    /// How far back in time the tail reaches along the leader's path.
    let trailDuration: Float = 3.4
    private var history: [(t: Float, p: SIMD3<Float>)] = []
    private var clock: Float = 0
    private var x: [SIMD3<Float>] = []

    func reset(primary: SIMD3<Float>, secondary _: SIMD3<Float>) {
        clock = 0
        history = [(0, primary)]
        x = Array(repeating: primary, count: spinePointCount)
    }

    /// Leader position `delay` seconds ago (linear interpolation in the recorded path).
    private func pathPosition(delay: Float) -> SIMD3<Float> {
        let target = clock - delay
        guard let first = history.first else { return .zero }
        if target <= first.t { return first.p }
        var j = history.count - 1
        while j > 0 && history[j - 1].t > target { j -= 1 }
        let a = history[max(j - 1, 0)], b = history[j]
        let span = max(b.t - a.t, 1e-5)
        return simd_mix(a.p, b.p, SIMD3(repeating: min(max((target - a.t) / span, 0), 1)))
    }

    func update(primary a: SIMD3<Float>, secondary _: SIMD3<Float>, time t: Float, dt: Float) -> [SpinePoint] {
        if x.isEmpty { reset(primary: a, secondary: a) }
        if dt > 0 {
            clock += dt
            history.append((clock, a))
            if let first = history.first, clock - first.t > trailDuration + 0.5 { history.removeFirst() }

            for i in 0..<spinePointCount {
                let s = Float(i) / Float(spinePointCount - 1)
                let delay = s * trailDuration
                // The body retraces the head's path; older parts drift up slightly and undulate.
                var target = pathPosition(delay: delay)
                target += worldUp * (0.035 * s * s)
                target += SIMD3<Float>(sin(t * 0.9 + s * 7.0), sin(t * 1.3 + s * 5.0 + 1.0), cos(t * 0.7 + s * 6.0)) * (0.012 * s)
                // Followers further down the body respond more lazily -> momentum and lag.
                let k = 26.0 - 20.0 * s
                x[i] += (target - x[i]) * (1 - exp(-dt * k))
            }
            x[0] = a
            for i in 1..<(spinePointCount - 1) {
                x[i] = x[i] * 0.7 + (x[i - 1] + x[i + 1]) * 0.15
            }
        }
        return (0..<spinePointCount).map { i in
            let s = Float(i) / Float(spinePointCount - 1)
            let r = 0.046 + (0.016 - 0.046) * pow(s, 0.8)
            let head = 1 - smoothstep(0, 0.12, s)
            let heat = (1.0 + (0.38 - 1.0) * s) + 0.15 * head
            return SpinePoint(position: x[i], radius: r, heat: min(heat, 1))
        }
    }
}

// MARK: - Two-hand arc

/// A bridge between two palms. It bows upward (in the plane facing the viewer), carries a slow
/// travelling wave plus a depth undulation, and gathers into a tall flame when the palms meet.
@MainActor
final class ArcShape: SpineShape {
    func reset(primary: SIMD3<Float>, secondary: SIMD3<Float>) {}

    func update(primary a: SIMD3<Float>, secondary b: SIMD3<Float>, time t: Float, dt _: Float) -> [SpinePoint] {
        let ab = b - a
        let d = max(simd_length(ab), 1e-4)
        let dir = ab / d
        // Bulge direction: perpendicular to AB inside the frontal plane (continuous under rotation).
        var n = simd_cross(SIMD3<Float>(0, 0, 1), dir)
        if simd_length(n) < 1e-3 { n = worldUp }
        n = simd_normalize(n)
        let depth = simd_normalize(simd_cross(dir, n))
        let h = 0.07 + 0.40 * d

        return (0..<spinePointCount).map { i in
            let s = Float(i) / Float(spinePointCount - 1)
            let bell = sin(Float.pi * s)
            var p = a + ab * s + n * (h * pow(bell, 0.85))
            p += n * (0.022 * sin(2 * .pi * 1.5 * s - 1.9 * t) * bell)
            p += depth * (0.035 * sin(.pi * 2 * s + 0.8 * t) * bell)
            let edge = abs(2 * s - 1)
            let r = 0.03 + 0.013 * edge * edge
            let heat = 0.78 + 0.22 * edge
            return SpinePoint(position: p, radius: r, heat: heat)
        }
    }
}

@inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}
