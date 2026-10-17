import ARKit
import QuartzCore
import RealityKit

/// Places the fire once, relative to where the viewer is looking when the space opens:
/// `distance` ahead and `drop` below the eyes (palm height), yawed to face the viewer.
/// Yaw only — the fire's local +Y must stay world-up for buoyancy.
@MainActor
final class HeadPlacement {
    private let session = ARKitSession()
    private let world = WorldTrackingProvider()

    func place(_ entity: Entity, distance: Float = 0.85, drop: Float = 0.12) async {
        guard WorldTrackingProvider.isSupported else { return }
        do {
            try await session.run([world])
        } catch {
            NSLog("FireOpus: world tracking unavailable (\(error)); using fixed placement")
            return
        }
        for _ in 0..<60 {
            if let anchor = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked {
                let m = anchor.originFromAnchorTransform
                let head = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                var forward = -SIMD3<Float>(m.columns.2.x, 0, m.columns.2.z)
                if simd_length(forward) < 1e-3 { forward = [0, 0, -1] }
                forward = simd_normalize(forward)
                entity.position = head + forward * distance + SIMD3<Float>(0, -drop, 0)
                entity.orientation = simd_quatf(angle: atan2(-forward.x, -forward.z), axis: [0, 1, 0])
                NSLog("FireOpus: placed fire relative to head at \(entity.position)")
                session.stop()
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        session.stop()
        NSLog("FireOpus: no device anchor; using fixed placement")
    }
}
