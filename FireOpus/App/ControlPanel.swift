import SwiftUI

/// Minimal floating test harness: mode, play/pause, restart, quality, scale, intensity.
struct ControlPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 18) {
            Picker("Demo", selection: $model.mode) {
                ForEach(FireMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button(model.isPaused ? "Play" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                    model.isPaused.toggle()
                }
                Button("Restart", systemImage: "arrow.counterclockwise") { model.restartToken += 1 }
                Button(model.isLit ? "Dissipate" : "Ignite", systemImage: model.isLit ? "wind" : "flame.fill") {
                    model.isLit.toggle()
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Quality")
                    Picker("Quality", selection: $model.quality) {
                        ForEach(FireQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                GridRow {
                    Text("Scale")
                    Slider(value: $model.scale, in: 0.5...1.6)
                }
                GridRow {
                    Text("Intensity")
                    Slider(value: $model.intensity, in: 0.2...1.5)
                }
                GridRow {
                    Text("Hands")
                    Toggle("Show simulated control points", isOn: $model.showControlPoints)
                }
            }

            HStack {
                if let msg = model.statusMessage {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.spaceState == .open ? "Hide Fire" : "Show Fire") {
                    Task { await toggleSpace() }
                }
                .disabled(model.spaceState == .opening)
            }
        }
        .padding(26)
        .frame(width: 520)
        .task {
            if model.spaceState == .closed { await toggleSpace() }
        }
    }

    private func toggleSpace() async {
        switch model.spaceState {
        case .open:
            await dismissImmersiveSpace()
            model.spaceState = .closed
        case .closed:
            model.spaceState = .opening
            switch await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
            case .opened: model.spaceState = .open
            default: model.spaceState = .closed
            }
        case .opening:
            break
        }
    }
}
