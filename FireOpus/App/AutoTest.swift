import Foundation
import RealityKit

/// Scripted runtime test, enabled with the launch argument `-fireAutoTest YES`.
/// Drives the same AppModel the control panel uses through every mode transition, pause/resume,
/// dissipate/ignite, restart, quality change and synthetic hand input, logging entity counts and memory footprint so
/// leaks or stalls show up in the log (`FireOpus: autotest ...`).
@MainActor
enum AutoTest {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "fireAutoTest") }

    static func run(model: AppModel, effect: FireEffect, cycles: Int = 2) async {
        func log(_ step: String) {
            NSLog("FireOpus: autotest \(step) | mode=\(effect.mode.rawValue) frame=\(effect.frameCount) intensity=\(String(format: "%.2f", effect.intensity)) children=\(effect.root.children.count) footprintMB=\(String(format: "%.1f", memoryFootprintMB()))")
        }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

        log("start")
        for cycle in 1...cycles {
            for mode in FireMode.allCases {
                model.mode = mode
                log("cycle \(cycle) -> \(mode.rawValue)")
                await wait(9)
            }
            let before = effect.frameCount
            model.isPaused = true
            await wait(2)
            log("paused (frames advanced while paused: \(effect.frameCount - before))")
            model.isPaused = false
            await wait(2)
            log("resumed")
            model.isLit = false
            await wait(4)
            log("dissipated")
            model.isLit = true
            await wait(4)
            log("ignited")
            model.restartToken += 1
            await wait(3)
            log("restarted")
            model.quality = .low
            await wait(3)
            log("quality low")
            model.quality = .high
        }
        let handsOK = model.handTrackingAvailable ? true : await handInput(model: model, effect: effect, log: log)
        model.mode = .livingFlame
        await wait(4)
        log(handsOK ? "PASS" : "FAIL (hand input)")
    }

    /// Drives `HandDriver` with synthetic palms (simulator has no hand tracking): follow, loss
    /// fade, snap on reappear, two-hand arc, and release back to the script.
    private static func handInput(model: AppModel, effect: FireEffect, log: (String) -> Void) async -> Bool {
        let driver = HandDriver()
        var ok = true
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { effect.root.convert(position: p, to: nil) }
        func feed(_ seconds: Float, _ palms: (Float) -> Palms) async {
            var t: Float = 0
            while t < seconds {
                driver.step(fire: effect, palms: palms(t), userLit: model.isLit, dt: 1 / 60)
                try? await Task.sleep(for: .milliseconds(16))
                t += 1 / 60
            }
        }
        func check(_ name: String, _ pass: Bool) {
            ok = ok && pass
            log("hands \(name): \(pass ? "ok" : "FAILED")")
        }

        model.mode = .livingFlame
        try? await Task.sleep(for: .seconds(3))
        let p0 = SIMD3<Float>(0, -0.07, 0)
        await feed(3) { t in Palms(right: world(p0 + SIMD3(0.03 * sin(t), 0.01 * sin(1.7 * t), 0))) }
        check("follows palm", simd_distance(effect.controlPoints.primary, p0) < 0.05 && !effect.usesScriptedMotion)

        await feed(1.2) { _ in Palms() }
        check("fades when lost", !effect.isIgnited)

        let p1 = p0 + SIMD3<Float>(0.3, 0.1, 0)
        await feed(0.1) { _ in Palms(left: world(p1)) }
        check("snaps on reappear", simd_distance(effect.controlPoints.primary, p1) < 0.01 && effect.isIgnited)
        await feed(3) { _ in Palms(left: world(p1)) }

        model.mode = .twoHandArc
        await feed(8) { t in
            let d = 0.15 + 0.3 * (0.5 - 0.5 * cos(t * 0.8))
            return Palms(left: world(SIMD3(-d / 2, -0.09, 0)), right: world(SIMD3(d / 2, -0.09, 0)))
        }
        check("arc spans palms", simd_distance(effect.controlPoints.primary, effect.controlPoints.secondary) > 0.1)
        await feed(1) { _ in Palms(right: world(SIMD3(0.2, -0.09, 0))) }
        check("arc fades with one hand", !effect.isIgnited)
        await feed(2) { _ in Palms(left: world(SIMD3(-0.2, -0.09, 0)), right: world(SIMD3(0.2, -0.09, 0))) }
        check("arc relights with both", effect.isIgnited)

        driver.release(fire: effect, userLit: model.isLit)
        check("released to script", effect.usesScriptedMotion && effect.isIgnited)
        return ok
    }

    private static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
