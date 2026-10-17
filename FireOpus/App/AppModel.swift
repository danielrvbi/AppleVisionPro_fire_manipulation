import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let immersiveSpaceID = "FireSpace"

    enum SpaceState { case closed, opening, open }

    var spaceState: SpaceState = .closed
    var mode: FireMode = .livingFlame
    var isPaused = false
    var quality: FireQuality = .high
    var scale: Float = 1.0
    var intensity: Float = 1.0
    var isLit = true
    var showControlPoints = false
    /// Bumped to request a restart of the effect.
    var restartToken = 0
    var statusMessage: String?

    init() {
        // Launch argument for testing, e.g. `-fireMode twoHandArc`.
        if let raw = UserDefaults.standard.string(forKey: "fireMode"), let m = FireMode(rawValue: raw) {
            mode = m
        }
    }
}
