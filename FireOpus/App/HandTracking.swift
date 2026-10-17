import ARKit
import QuartzCore
import RealityKit

/// Palm positions in world space (immersive-space origin), either hand possibly missing.
struct Palms {
    var left: SIMD3<Float>?
    var right: SIMD3<Float>?
}

/// Reads palm points from ARKit hand tracking. Device only: the simulator has no hand tracking,
/// so `start()` returns false there and the scripted choreography keeps driving the fire.
@MainActor
final class HandControl {
    private let session = ARKitSession()
    private let hands = HandTrackingProvider()
    private(set) var isRunning = false
    /// How far the control point sits off the palm, along the palm normal (metres).
    var palmLift: Float = 0.035

    func start() async -> Bool {
        guard HandTrackingProvider.isSupported else {
            NSLog("FireOpus: hand tracking not supported; using scripted motion")
            return false
        }
        let auth = await session.requestAuthorization(for: [.handTracking])
        guard auth[.handTracking] == .allowed else {
            NSLog("FireOpus: hand tracking not authorized; using scripted motion")
            return false
        }
        do {
            try await session.run([hands])
        } catch {
            NSLog("FireOpus: hand tracking unavailable (\(error)); using scripted motion")
            return false
        }
        isRunning = true
        NSLog("FireOpus: hand tracking running")
        return true
    }

    func stop() {
        session.stop()
        isRunning = false
    }

    /// Predicted palm points for this frame.
    func palms() -> Palms {
        guard isRunning, hands.state == .running else { return Palms() }
        let (left, right) = hands.handAnchors(at: CACurrentMediaTime())
        return Palms(left: left.flatMap(palm), right: right.flatMap(palm))
    }

    /// Palm centre (wrist / middle metacarpal / middle knuckle), lifted along the palm normal.
    private func palm(_ anchor: HandAnchor) -> SIMD3<Float>? {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        func joint(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
            let j = skeleton.joint(name)
            guard j.isTracked else { return nil }
            let m = anchor.originFromAnchorTransform * j.anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        guard let wrist = joint(.wrist), let metacarpal = joint(.middleFingerMetacarpal),
              let knuckle = joint(.middleFingerKnuckle), let index = joint(.indexFingerKnuckle),
              let little = joint(.littleFingerKnuckle) else { return nil }
        let centre = (wrist + metacarpal + knuckle) / 3
        // Right hand: index × little (from the wrist) points out of the palm; mirrored for the left.
        var normal = simd_cross(index - wrist, little - wrist)
        guard simd_length(normal) > 1e-6 else { return centre }
        normal = simd_normalize(normal) * (anchor.chirality == .left ? -1 : 1)
        return centre + normal * palmLift
    }
}

/// Per-frame glue between palm points and the fire: picks the hands the mode needs, converts to
/// the fire's local space, fades the fire out while they are missing and relights it where they
/// reappear. Pure logic, so the autotest can drive it with synthetic palms in the simulator.
@MainActor
final class HandDriver {
    /// Missing hands are tolerated this long before the fire fades (tracking blinks).
    var lossGrace: Float = 0.25
    /// A reappearing hand further than this from the last point snaps instead of sweeping.
    var snapDistance: Float = 0.12

    private(set) var isDriving = false
    private var acquired = false
    private var missing: Float = 0

    func step(fire: FireEffect, palms: Palms, userLit: Bool, dt: Float) {
        isDriving = true
        let points: (SIMD3<Float>, SIMD3<Float>)? = {
            if fire.mode.controlPointCount > 1 {
                guard let l = palms.left, let r = palms.right else { return nil }
                return (l, r)
            }
            guard let p = palms.right ?? palms.left else { return nil }
            return (p, p)
        }()

        if let (worldA, worldB) = points {
            let a = fire.root.convert(position: worldA, from: nil)
            let b = fire.root.convert(position: worldB, from: nil)
            let last = fire.controlPoints
            let jumped = simd_distance(a, last.primary) > snapDistance || simd_distance(b, last.secondary) > snapDistance
            let snap = !acquired || (missing > 0 && jumped)
            fire.setControlPoints(primary: a, secondary: b, snap: snap)
            acquired = true
            missing = 0
        } else {
            missing += max(dt, 0)
        }

        // Last points stay frozen while the fire fades; it relights only if the user wants it lit.
        let wantLit = userLit && acquired && missing < lossGrace
        if wantLit != fire.isIgnited { wantLit ? fire.ignite() : fire.dissipate() }
    }

    /// Back to the scripted choreography (hand tracking off or unavailable).
    func release(fire: FireEffect, userLit: Bool) {
        guard isDriving else { return }
        fire.releaseControlPoints()
        if userLit && !fire.isIgnited { fire.ignite() }
        isDriving = false
        acquired = false
        missing = 0
    }
}
