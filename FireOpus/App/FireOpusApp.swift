import SwiftUI

@main
struct FireOpusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "controls") {
            ControlPanel()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 360)

        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            ImmersiveFireView()
                .environment(model)
                .persistentSystemOverlays(.hidden)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
