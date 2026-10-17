import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let immersiveSpaceID = "FireSpace"
    static let controlsWindowID = "controls"
    static let modeBarWindowID = "modeBar"

    enum SpaceState { case closed, opening, open }
    /// Chosen at launch: `.full` is the test panel, `.auto` is demo defaults plus the mode pill.
    enum LaunchStyle: String { case auto, full }

    var spaceState: SpaceState = .closed
    /// nil until the user picks at launch.
    var launchStyle: LaunchStyle?
    var mode: FireMode = .livingFlame
    var isPaused = false
    var quality: FireQuality = .high
    var scale: Float = 1.0
    var intensity: Float = 1.0
    var isLit = true
    var showControlPoints = false
    /// User toggle: let tracked palms drive the fire when hand tracking is available.
    var handTrackingEnabled = true
    /// Set once the immersive space has tried to start hand tracking (false in the simulator).
    var handTrackingAvailable = false
    /// Bumped to request a restart of the effect.
    var restartToken = 0
    var statusMessage: String?

    static let scaleRange: ClosedRange<Float> = 0.5...1.6
    static let intensityRange: ClosedRange<Float> = 0.2...1.5

    init() {
        // Launch arguments for testing, e.g. `-fireMode twoHandArc`, `-launchStyle auto`.
        if let raw = UserDefaults.standard.string(forKey: "fireMode"), let m = FireMode(rawValue: raw) {
            mode = m
        }
        if let raw = UserDefaults.standard.string(forKey: "launchStyle"), let s = LaunchStyle(rawValue: raw) {
            launchStyle = s
        }
        if AutoTest.isEnabled { launchStyle = .full }
        if launchStyle == .auto { applyAutoPreset() }
    }

    /// Demo defaults: low quality, scale at 60% and intensity at 80% of slider travel, hands on.
    func applyAutoPreset() {
        func travel(_ r: ClosedRange<Float>, _ f: Float) -> Float { r.lowerBound + f * (r.upperBound - r.lowerBound) }
        quality = .low
        scale = travel(Self.scaleRange, 0.6)
        intensity = travel(Self.intensityRange, 0.8)
        mode = .livingFlame
        handTrackingEnabled = true
        showControlPoints = false
        isLit = true
        isPaused = false
    }
}
