import Foundation
import Metal
import RealityKit
import UIKit

enum FireQuality: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var particleFactor: Float {
        switch self {
        case .low: 0.45
        case .medium: 0.7
        case .high: 1.0
        }
    }
}

/// The reusable fire VFX engine.
///
/// Drive it with one or two control points (scripted now, hand-tracked later):
/// ```
/// let fire = try await FireEffect.make()
/// content.add(fire.root)
/// fire.setMode(.twoHandArc)
/// fire.setControlPoints(primary: leftPalm, secondary: rightPalm) // switches off the script
/// fire.update(dt: dt)                                            // once per frame
/// fire.dissipate() / fire.ignite()
/// ```
@MainActor
final class FireEffect {
    enum LayerKind: CaseIterable {
        case shade, smoke, glow, flame, core, embers
    }

    /// Root entity; place/scale it in the scene. Control points are in its local space.
    let root = Entity()

    private(set) var mode: FireMode = .livingFlame
    var isPaused = false
    var quality: FireQuality = .high
    /// When true the built-in choreography supplies control points.
    var usesScriptedMotion = true
    var showsControlPoints = false { didSet { markers.forEach { $0.isEnabled = showsControlPoints } } }
    /// Brightness / emission multiplier the user can tweak (0...1.5).
    var userIntensity: Float = 1.0

    private(set) var intensity: Float = 0
    private var targetIntensity: Float = 1

    private let gpu: FireGPU
    private var layers: [LayerKind: ParticleLayer] = [:]
    private var shapes: [FireMode: SpineShape] = [
        .livingFlame: LivingFlameShape(),
        .flowingRibbon: RibbonShape(),
        .twoHandArc: ArcShape(),
    ]
    private let choreography = ScriptedChoreography()

    private var simTime: Float = 0
    private var scriptTime: Float = 0
    private var frame: UInt32 = 0
    /// Frames rendered (advances while paused too; the simulation step is what pauses).
    var frameCount: UInt32 { frame }

    // transition state
    private var previousMode: FireMode?
    private var transition: Float = 1
    private let transitionDuration: Float = 2.2

    // external control points (critically damped smoothing for noisy tracking input)
    private var external: (SIMD3<Float>, SIMD3<Float>)?
    private var smoothed: (a: SIMD3<Float>, b: SIMD3<Float>, va: SIMD3<Float>, vb: SIMD3<Float>)?

    private var lastSpine: [SpinePoint] = []
    private var markers: [ModelEntity] = []

    private init(gpu: FireGPU) {
        self.gpu = gpu
        root.name = "FireEffect"
    }

    static func make() async throws -> FireEffect {
        guard let gpu = FireGPU.shared else { throw NSError(domain: "FireEffect", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal unavailable"]) }
        let effect = FireEffect(gpu: gpu)
        try await effect.build()
        return effect
    }

    private func build() async throws {
        let noise = try gpu.makeNoiseTexture(size: 256)
        let flameMat = try await FireMaterials.make(.flame, noise: noise, gain: 1.0)
        let coreMat = try await FireMaterials.make(.flame, noise: noise, gain: 1.0)
        let emberMat = try await FireMaterials.make(.spark, noise: noise, gain: 1.6, falloff: 1.4)
        let glowMat = try await FireMaterials.make(.spark, noise: noise, gain: 1.0, falloff: 2.4)
        let smokeMat = try await FireMaterials.make(.smoke, noise: noise, gain: 1.0)
        let shadeMat = try await FireMaterials.make(.shade, noise: noise, gain: 1.0, falloff: 1.6)

        let group = ModelSortGroup(depthPass: nil)
        let specs: [(LayerKind, Int, ShaderGraphMaterial, Int32)] = [
            (.shade, 160, shadeMat, 0),
            (.smoke, 420, smokeMat, 1),
            (.glow, 70, glowMat, 2),
            (.flame, 4800, flameMat, 3),
            (.core, 1100, coreMat, 4),
            (.embers, 320, emberMat, 5),
        ]
        for (kind, cap, mat, order) in specs {
            let layer = try ParticleLayer(name: "\(kind)", capacity: cap, material: mat, sortOrder: order, sortGroup: group, gpu: gpu)
            layers[kind] = layer
            root.addChild(layer.entity)
        }

        for _ in 0..<2 {
            let m = ModelEntity(mesh: .generateSphere(radius: 0.012),
                                materials: [UnlitMaterial(color: UIColor(white: 1, alpha: 0.35))])
            m.isEnabled = false
            markers.append(m)
            root.addChild(m)
        }
        restart()
    }

    // MARK: - Public control API

    func setMode(_ newMode: FireMode, animated: Bool = true) {
        guard newMode != mode else { return }
        let (a, b) = currentControlPoints(for: newMode)
        shapes[newMode]?.reset(primary: a, secondary: b)
        if animated {
            previousMode = mode
            transition = 0
        } else {
            previousMode = nil
            transition = 1
        }
        mode = newMode
    }

    /// Feed palm positions (root-local metres). Disables the scripted motion.
    func setControlPoints(primary: SIMD3<Float>, secondary: SIMD3<Float>? = nil) {
        usesScriptedMotion = false
        external = (primary, secondary ?? primary)
    }

    func ignite() { targetIntensity = 1 }
    func dissipate() { targetIntensity = 0 }

    func restart() {
        layers.values.forEach { $0.reset() }
        scriptTime = 0
        intensity = 0
        targetIntensity = 1
        previousMode = nil
        transition = 1
        smoothed = nil
        lastSpine = []
        for (m, shape) in shapes {
            let (a, b) = currentControlPoints(for: m)
            shape.reset(primary: a, secondary: b)
        }
    }

    // MARK: - Frame update

    func update(dt rawDt: Float) {
        let dt = min(max(rawDt, 0), 1.0 / 30.0)
        let stepDt: Float = isPaused ? 0 : dt
        if !isPaused {
            simTime += dt
            scriptTime += dt
            intensity += (targetIntensity - intensity) * min(1, dt * 1.2)
            if transition < 1 { transition = min(1, transition + dt / transitionDuration) }
        }
        frame &+= 1
        #if DEBUG
        if frame % 600 == 1 {
            NSLog("FireOpus: frame \(frame) mode \(mode.rawValue) intensity \(intensity) dt \(rawDt)")
        }
        #endif

        // 1. Control points -> spine (blended across a mode transition)
        if !isPaused || lastSpine.isEmpty {
            let w = smoothstep(0, 1, transition)
            var spine = spineFor(mode, dt: stepDt)
            if let prev = previousMode, w < 1 {
                let from = spineFor(prev, dt: stepDt)
                spine = zip(from, spine).map { a, b in
                    SpinePoint(position: simd_mix(a.position, b.position, SIMD3(repeating: w)),
                               radius: a.radius + (b.radius - a.radius) * w,
                               heat: a.heat + (b.heat - a.heat) * w)
                }
            } else if w >= 1 {
                previousMode = nil
            }
            // spine velocity by finite difference (drives inheritance & cohesion damping)
            if lastSpine.count == spine.count, stepDt > 0 {
                for i in spine.indices {
                    var v = (spine[i].position - lastSpine[i].position) / stepDt
                    let speed = simd_length(v)
                    if speed > 3 { v *= 3 / speed }
                    let smoothedV = simd_mix(lastSpine[i].velocity, v, SIMD3(repeating: 0.35))
                    spine[i].velHeat = SIMD4(smoothedV, spine[i].heat)
                }
            }
            lastSpine = spine
        }

        // 2. Per-layer parameters
        let style: ModeStyle = {
            let target = ModeStyle.style(for: mode)
            guard let prev = previousMode else { return target }
            return ModeStyle.lerp(ModeStyle.style(for: prev), target, smoothstep(0, 1, transition))
        }()

        // Ribbon/arc: keep particles-per-metre constant so a compressed spine doesn't blow out.
        var spineLength: Float = 0
        for i in 1..<max(lastSpine.count, 1) { spineLength += simd_distance(lastSpine[i].position, lastSpine[i - 1].position) }
        let byLength = min(max(spineLength / 0.7, 0.3), 1)
        let lengthFactor = 1 + (byLength - 1) * style.lengthNormalized

        guard let cb = gpu.queue.makeCommandBuffer() else { return }
        for kind in LayerKind.allCases {
            guard let layer = layers[kind] else { continue }
            var p = Self.params(for: kind, style: style)
            let active = Float(layer.capacity) * min(1, style.density) * quality.particleFactor * lengthFactor
            p.time = SIMD4(simTime, stepDt, Float(frame), intensity * min(userIntensity, 1))
            p.counts.x = UInt32(active)
            p.heat.z *= max(userIntensity, 0)
            layer.params = p
            layer.encode(into: cb, gpu: gpu, spine: lastSpine)
        }
        cb.commit()

        // 3. Debug markers
        if showsControlPoints {
            let (a, b) = currentControlPoints(for: mode)
            markers[0].position = a
            markers[1].position = b
            markers[1].isEnabled = mode.controlPointCount > 1
        }
    }

    // MARK: - Internals

    private func currentControlPoints(for m: FireMode) -> (SIMD3<Float>, SIMD3<Float>) {
        if !usesScriptedMotion, let s = smoothed { return (s.a, s.b) }
        if !usesScriptedMotion, let e = external { return e }
        let out = choreography.controlPoints(for: m, time: scriptTime)
        return (out.primary, out.secondary)
    }

    private func spineFor(_ m: FireMode, dt: Float) -> [SpinePoint] {
        var (a, b) = currentControlPoints(for: m)
        if !usesScriptedMotion, let e = external {
            // critically damped spring toward tracked targets
            var s = smoothed ?? (e.0, e.1, .zero, .zero)
            let omega: Float = 14
            if dt > 0 {
                s.va += (omega * omega * (e.0 - s.a) - 2 * omega * s.va) * dt
                s.vb += (omega * omega * (e.1 - s.b) - 2 * omega * s.vb) * dt
                s.a += s.va * dt
                s.b += s.vb * dt
            }
            smoothed = s
            (a, b) = (s.a, s.b)
        }
        return shapes[m]!.update(primary: a, secondary: b, time: scriptTime, dt: dt)
    }

    /// Hand-tuned layer recipes. Distances in metres, times in seconds.
    static func params(for kind: LayerKind, style: ModeStyle) -> LayerParams {
        var p = LayerParams()
        let ls = style.lifeScale
        let flow = SIMD4<Float>(0, 1, 0, style.flowToCentre > 0.5 ? 1 : 0)
        switch kind {
        case .flame:
            p.life = [0.4 * ls, 0.9 * ls, 0.8, 0.2]
            p.size = [0.016, 0.03, 0.011, 4.0]
            p.motion = [1.1 * style.buoyancy, 3.0, 0.22, 9.0]
            p.motion2 = [0.9, style.cohesion, style.inherit, style.flowAlong]
            p.heat = [0.8, 0.2, 0.14 * style.alphaScale, 3.4]
            p.shape = [style.converge, 0, 0, 0]
            p.range = flow
            p.extra2 = [style.cohesionDecay, 0, 0.034, style.spreadGrowth]
        case .core:
            p.life = [0.18, 0.38, 0.55, 0.0]
            p.size = [0.012, 0.02, 0.012, 1.4]
            p.motion = [0.6 * style.buoyancy, 4.0, 0.12, 10.0]
            p.motion2 = [1.1, style.cohesion * 1.2, style.inherit, style.flowAlong * 0.5]
            p.heat = [1.1, 0.8, 0.12 * style.alphaScale, 2.2]
            p.shape = [style.converge * 0.5, 0, 0, 0]
            p.range = flow
            p.extra2 = [style.cohesionDecay, 0, 0.034, 0.3]
        case .embers:
            p.life = [0.8, 1.7, 1.5, 0.5]
            p.size = [0.0022, 0.0018, 0.0010, 6.0]
            p.motion = [0.25, 1.2, 0.6, 4.5]
            p.motion2 = [0.5, style.cohesion * 0.15, style.inherit * 0.35, style.flowAlong]
            p.heat = [1.0, 0.5, 0.9, 5.0]
            p.range = flow
            p.extra2 = [3.0, 0.6, 0.034, 2.0]
        case .glow:
            p.life = [0.9, 1.6, 0.6, 0.6]
            p.size = [0.06, 0.085, 0.075, 0]
            p.motion = [0.15, 3.0, 0.05, 3.0]
            p.motion2 = [0.3, style.cohesion * 0.8, style.inherit, 0]
            p.heat = [0.75, 0.5, 0.03, 1.0]
            p.range = [0, 1, 1, 0]
            p.extra2 = [1.0, 0, 0.034, 0.5]
        case .shade:
            // Soft soot haze behind the body: keeps colours saturated over bright passthrough.
            p.life = [0.7, 1.3, 0.7, 2.6]
            p.size = [0.05, 0.075, 0.07, 0]
            p.motion = [0.3, 3.0, 0.08, 3.0]
            p.motion2 = [0.3, style.cohesion * 0.8, style.inherit, 0]
            p.heat = [0, 0, 0.16 * (0.4 + 0.6 * style.alphaScale), 1.0]
            p.range = [0, 1, 1, 0]
            p.extra2 = [1.0, 0, 0.034, 0.5]
            p.shape = [style.converge * 0.5, 0, 0, 0]
        case .smoke:
            p.life = [1.4, 2.6, 1.2, style.smokeLift]
            p.size = [0.03, 0.065, 0.10, 0]
            p.motion = [0.25, 1.4, 0.3, 4.0]
            p.motion2 = [0.4, 0, style.inherit * 0.5, 0]
            p.heat = [0.45, 0.0, 0.07 * (0.3 + 0.7 * style.alphaScale), 1.0]
            p.range = [0, 1, 1, 0]
            p.extra2 = [1.0, 0, 0.034, 0]
        }
        return p
    }
}
