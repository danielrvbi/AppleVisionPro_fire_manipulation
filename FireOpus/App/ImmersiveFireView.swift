import RealityKit
import SwiftUI

/// Mixed immersive space: passthrough plus the fire, ~0.85 m in front of the viewer.
struct ImmersiveFireView: View {
    @Environment(AppModel.self) private var model
    @State private var effect: FireEffect?
    @State private var updateSubscription: EventSubscription?
    @State private var placement = HeadPlacement()

    /// Comfortable palm height / distance for a seated or standing viewer.
    static let firePosition = SIMD3<Float>(0, 1.15, -0.85)

    var body: some View {
        RealityView { content in
            do {
                let fire = try await FireEffect.make()
                fire.root.position = Self.firePosition
                content.add(fire.root)
                apply(to: fire)
                effect = fire
                updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                    MainActor.assumeIsolated {
                        fire.update(dt: Float(event.deltaTime))
                    }
                }
                model.statusMessage = nil
                NSLog("FireOpus: effect ready")
                await placement.place(fire.root)
            } catch {
                model.statusMessage = "Fire failed: \(error.localizedDescription)"
                NSLog("FireOpus: effect build failed: \(error)")
            }
        }
        .onChange(of: model.mode) { _, m in effect?.setMode(m) }
        .onChange(of: model.isPaused) { _, p in effect?.isPaused = p }
        .onChange(of: model.quality) { _, q in effect?.quality = q }
        .onChange(of: model.scale) { _, s in effect?.root.scale = SIMD3(repeating: s) }
        .onChange(of: model.intensity) { _, i in effect?.userIntensity = i }
        .onChange(of: model.isLit) { _, lit in lit ? effect?.ignite() : effect?.dissipate() }
        .onChange(of: model.showControlPoints) { _, v in effect?.showsControlPoints = v }
        .onChange(of: model.restartToken) { _, _ in
            effect?.restart()
            model.isLit = true
        }
        .onDisappear {
            updateSubscription?.cancel()
            updateSubscription = nil
            effect?.root.removeFromParent()
            effect = nil
        }
    }

    private func apply(to fire: FireEffect) {
        fire.setMode(model.mode, animated: false)
        fire.isPaused = model.isPaused
        fire.quality = model.quality
        fire.root.scale = SIMD3(repeating: model.scale)
        fire.userIntensity = model.intensity
        fire.showsControlPoints = model.showControlPoints
        if !model.isLit { fire.dissipate() }
    }
}
