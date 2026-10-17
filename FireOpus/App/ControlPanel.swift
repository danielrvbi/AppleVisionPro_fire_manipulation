import SwiftUI

/// Minimal floating test harness: mode, play/pause, restart, quality, scale, intensity, hands.
/// At launch it first asks for Auto (demo defaults + the mode pill) or Full settings.
struct ControlPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if model.launchStyle == nil { chooser } else { panel }
        }
        .padding(26)
        .frame(width: 520)
        .task {
            // Launch argument picked the style already: start as soon as the window is up.
            if let style = model.launchStyle, model.spaceState == .closed { await start(style) }
        }
    }

    private var chooser: some View {
        VStack(spacing: 16) {
            Text("Fire").font(.largeTitle.bold())
            HStack(spacing: 16) {
                launchButton("Auto demo", subtitle: "Low quality, tuned size & intensity, just the fire",
                             systemImage: "sparkles", style: .auto)
                launchButton("Full settings", subtitle: "Every control, as a test panel",
                             systemImage: "slider.horizontal.3", style: .full)
            }
        }
    }

    private func launchButton(_ title: String, subtitle: String, systemImage: String, style: AppModel.LaunchStyle) -> some View {
        Button {
            Task { await start(style) }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.largeTitle)
                Text(title).font(.title3.bold())
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding(8)
        }
        .buttonBorderShape(.roundedRectangle(radius: 24))
    }

    private var panel: some View {
        @Bindable var model = model
        return VStack(spacing: 18) {
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
                    Slider(value: $model.scale, in: AppModel.scaleRange)
                }
                GridRow {
                    Text("Intensity")
                    Slider(value: $model.intensity, in: AppModel.intensityRange)
                }
                GridRow {
                    Text("Hands")
                    Toggle(model.handTrackingAvailable ? "Fire follows your palms" : "Hand tracking unavailable (simulator or no permission)",
                           isOn: $model.handTrackingEnabled)
                        .disabled(!model.handTrackingAvailable)
                }
                GridRow {
                    Text("Markers")
                    Toggle("Show control points", isOn: $model.showControlPoints)
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
    }

    /// Applies the launch choice and opens the fire. Auto swaps this panel for the mode pill
    /// (opened first so it can be placed beside this window, away from the hands).
    private func start(_ style: AppModel.LaunchStyle) async {
        if style == .auto, model.launchStyle != .auto { model.applyAutoPreset() }
        model.launchStyle = style
        if model.spaceState == .closed { await toggleSpace() }
        if style == .auto {
            openWindow(id: AppModel.modeBarWindowID)
            dismissWindow(id: AppModel.controlsWindowID)
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

/// Auto mode's only UI: a small movable pill (its own window, so the system grab bar lets you
/// park it anywhere out of the demo) with one button per fire mode and a way back to Full settings.
struct ModeBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FireMode.allCases) { m in
                Button {
                    model.mode = m
                } label: {
                    Image(systemName: m.symbolName)
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .background(model.mode == m ? Color.orange.opacity(0.4) : .clear, in: Circle())
                }
                .buttonBorderShape(.circle)
                .buttonStyle(.borderless)
                .help(m.title)
                .accessibilityLabel(m.title)
            }
            Divider().frame(height: 34)
            Button {
                model.launchStyle = .full
                openWindow(id: AppModel.controlsWindowID)
                dismissWindow(id: AppModel.modeBarWindowID)
            } label: {
                Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44)
            }
            .buttonBorderShape(.circle)
            .buttonStyle(.borderless)
            .help("Full settings")
            .accessibilityLabel("Full settings")
        }
        .padding(10)
        .glassBackgroundEffect(in: Capsule())
    }
}

private extension FireMode {
    var symbolName: String {
        switch self {
        case .livingFlame: "flame.fill"
        case .flowingRibbon: "scribble.variable"
        case .twoHandArc: "rainbow"
        }
    }
}
