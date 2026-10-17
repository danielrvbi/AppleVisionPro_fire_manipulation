import Foundation
import simd

/// Slow, Tai-Chi-paced scripted "hands". Produces the control points that real hand tracking
/// will provide later (palm positions in the fire root's local space, metres).
struct ScriptedChoreography {
    struct Output {
        var primary: SIMD3<Float>
        var secondary: SIMD3<Float>
    }

    func controlPoints(for mode: FireMode, time t: Float) -> Output {
        switch mode {
        case .livingFlame:
            // A palm holding the flame, hovering with a calm breathing drift.
            let p = SIMD3<Float>(0.012 * sin(0.6 * t),
                                 -0.07 + 0.012 * sin(0.9 * t + 1.0),
                                 0.012 * sin(0.45 * t))
            return Output(primary: p, secondary: p)

        case .flowingRibbon:
            // The leading hand draws a lazy horizontal figure-eight; the rope behind it becomes an S.
            let w = 2 * Float.pi / 9.0
            let tau = t + 0.35 * sin(w * t) / w        // ease: lingers at the ends of each stroke
            let p = SIMD3<Float>(0.27 * sin(w * tau),
                                 -0.02 + 0.11 * sin(2 * w * tau) + 0.03 * sin(0.37 * t),
                                 0.09 * sin(w * tau + 1.2))
            return Output(primary: p, secondary: p)

        case .twoHandArc:
            // Expansion / compression (motion_03) layered with a slow circular turn (motion_02).
            let open = 0.5 - 0.5 * cos(2 * Float.pi * t / 14.0)
            let d = 0.13 + 0.36 * open
            let theta = 0.85 * sin(2 * Float.pi * t / 22.0)
            let rot = simd_quatf(angle: theta, axis: SIMD3<Float>(0, 0, 1))
            let centre = SIMD3<Float>(0, -0.09 + 0.02 * sin(0.5 * t), 0)
            let zA = 0.04 * sin(0.4 * t)
            let a = centre + rot.act(SIMD3<Float>(-d / 2, 0, zA))
            let b = centre + rot.act(SIMD3<Float>(d / 2, 0, -zA))
            return Output(primary: a, secondary: b)
        }
    }
}
