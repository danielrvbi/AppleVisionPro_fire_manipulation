import SwiftUI

@main
struct FireOpusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: AppModel.controlsWindowID) {
            ControlPanel()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 360)

        // Auto mode's pill: a static, movable window that first appears beside the control
        // panel (off to the side, clear of the hands) instead of in front of the fire.
        WindowGroup(id: AppModel.modeBarWindowID) {
            ModeBar()
                .environment(model)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, context in
            if let controls = context.windows.first(where: { $0.id == AppModel.controlsWindowID }) {
                return WindowPlacement(.leading(controls))
            }
            return WindowPlacement()
        }

        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            ImmersiveFireView()
                .environment(model)
                .persistentSystemOverlays(.hidden)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
