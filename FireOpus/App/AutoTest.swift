import Foundation
import RealityKit

/// Scripted runtime test, enabled with the launch argument `-fireAutoTest YES`.
/// Drives the same AppModel the control panel uses through every mode transition, pause/resume,
/// dissipate/ignite, restart and quality change, logging entity counts and memory footprint so
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
        model.mode = .livingFlame
        await wait(4)
        log("PASS")
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
