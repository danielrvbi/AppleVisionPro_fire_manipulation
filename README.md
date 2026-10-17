# Fire Opus — real-time fire VFX for Apple Vision Pro

A native visionOS 27 app (Swift / SwiftUI / RealityKit) that renders a living, spatial fire effect
in a **mixed immersive space** (passthrough). Three scripted demos:

| Mode | Reference | What it shows |
|---|---|---|
| **Living Flame** | visual_01, visual_04 | A hovering flame above a (virtual) palm: white-yellow core, orange translucent tongues converging to a licking tip, red edges, embers, faint smoke. |
| **Flowing Ribbon** | visual_02, motion_01 | A continuous stream of fire whose body retraces the leading hand's figure-eight path → S / hook curves with lag and momentum. Flames peel upward off the stream. |
| **Two-Hand Arc** | visual_03, motion_02, motion_03 | A fire bridge between two simulated palms that slowly expands/compresses and turns in a circle, with a travelling wave and depth undulation. |

Everything is generated at runtime: no images, videos, sprite sheets, USD files or Reality
Composer Pro projects. The reference PNGs are art direction only and are not used by the app.

---

## Build & run

Requirements: Xcode 27 with the visionOS 27 SDK, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). **No Metal Toolchain download is needed** (kernels compile at runtime).

```sh
xcodegen generate            # creates FireOpus.xcodeproj from project.yml
open FireOpus.xcodeproj
```

### Simulator

```sh
Tools/run_sim.sh Debug                 # build + install + launch on the "Vision Pro Opus" simulator
Tools/run_sim.sh Debug twoHandArc      # start in a given mode (livingFlame | flowingRibbon | twoHandArc)
Tools/shot.sh name                     # screenshot into build/name*.png
```

The script always targets simulator `25507330-F20F-4074-889C-4044BD6D44FF` by UUID and keeps
DerivedData in `./DerivedData.nosync`. Simulator builds pass `CODE_SIGNING_ALLOWED=NO`: this
project lives on an iCloud-synced Desktop, and File Provider stamps `com.apple.FinderInfo` onto
the `.app` bundle, which `codesign` rejects. The Mach-O binaries are still linker ad-hoc signed,
which is all the simulator needs.

Equivalent raw command:

```sh
xcodebuild -project FireOpus.xcodeproj -scheme FireOpus -configuration Debug \
  -destination "id=25507330-F20F-4074-889C-4044BD6D44FF" \
  -derivedDataPath ./DerivedData.nosync CODE_SIGNING_ALLOWED=NO build
```

### Physical Apple Vision Pro

1. Open `FireOpus.xcodeproj`, select the **FireOpus** target → *Signing & Capabilities*, tick
   *Automatically manage signing* and choose your **Team** (or set `DEVELOPMENT_TEAM` in
   `project.yml` and re-run `xcodegen generate`).
   If you build from an iCloud-synced folder and hit *“resource fork, Finder information, or
   similar detritus not allowed”*, move the checkout (or DerivedData) to a non-synced folder.
2. Pair the headset (Settings → General → Remote Devices on the Vision Pro; Xcode → Devices and
   Simulators), enable Developer Mode on the headset.
3. Select the Vision Pro as run destination, build & run (prefer the **Release** configuration
   when judging smoothness).
4. On launch the control window opens and the immersive space opens automatically; the fire
   appears ~0.85 m in front of you, slightly below eye level. Use the window to switch demos,
   pause/play, restart, dissipate/ignite, change quality, scale and intensity, and to show the
   simulated control points (“hands”). Best viewed in a dim room.

Launch arguments (Xcode scheme → Arguments, or `simctl launch … <args>`):
`-fireMode <mode>` start mode, `-fireAutoTest YES` scripted runtime test (see below).

---

## How it works

```
 control points (scripted, or tracked palms on device)
            │
            ▼
   SpineShape (per mode)  ──►  spine: 48 points {position, radius, heat, velocity}
            │                    (blended across mode transitions)
            ▼
   Metal compute kernel (one thread per particle, 6 layers, ~7k particles)
     spawn on spine · buoyancy · curl-noise turbulence · drag · cohesion to the moving spine ·
     convergence to the flame axis · temperature/alpha over life
     → writes 4 vertices per particle straight into a RealityKit LowLevelMesh
            │
            ▼
   ShaderGraphMaterial built in code (visionOS 27 `ShaderGraph` API, MaterialX nodes)
     vertex stage: billboard every quad toward the camera *of the eye being rendered*,
                   stretched along particle velocity → licking tongues, correct stereo
     fragment stage: teardrop mask eroded by scrolling procedural noise + ridged filaments,
                     black-body colour ramp, additive (flames) or alpha (smoke/shade) blending
```

### Rendering techniques

* **GPU particle simulation (Metal compute → `LowLevelMesh`).** `Shaders/FireSimulation.metal`.
  Divergence-free curl noise (simplex, two octaves) gives organic, non-repeating swirl; the noise
  domain drifts so structures appear to rise. Particles are emitted along a *spine* and held to it
  by a spring that weakens with age, so ribbons stay coherent while older gas breaks free and
  rises as tongues. No CPU readback; the vertex buffer is replaced on the GPU each frame.
* **Programmatic ShaderGraph materials.** `VFX/FireMaterials.swift` builds the shaders with the
  new visionOS 27 `ShaderGraph` API through a small DSL (`VFX/ShaderGraphBuilder.swift`), so no
  Reality Composer Pro authoring is required. Verified against the installed SDK node library.
* **Per-eye billboarding in the vertex stage** (`realitykit_cameraposition` in model space),
  stretched along velocity. Each particle is a camera-facing card, but thousands of them
  distributed in 3D around a 3D spine give genuine volume and parallax; there is no single
  billboard of “the fire”.
* **Procedural detail texture.** `Shaders/NoiseTexture.metal` generates a tileable RGBA texture
  on the GPU at startup (`LowLevelTexture`): billowy fbm (tongue erosion), ridged multifractal
  (bright inner filaments), stretched fbm (smoke wisps).
* **Layers** (draw order via `ModelSortGroup`):
  `shade` (soft dark soot haze, alpha) → `smoke` (alpha) → `glow` (wide faint additive halo) →
  `flame` (main tongues, additive) → `core` (small, very hot, additive) → `embers` (tiny
  streaked sparks with flicker, additive).
  The colour comes from a temperature value per particle; overlapping additive layers saturate
  toward white-yellow in the dense core while thin edges stay orange-red.
* **Contrast on passthrough.** Additive light washes out over bright real rooms; the faint dark
  `shade` layer behind the flame body keeps the colours saturated (the references are shot in a
  dark room).

### Modes and the hand-tracking seam

`FireEffect` (in `VFX/FireEffect.swift`) is the engine API:

```swift
let fire = try await FireEffect.make()
content.add(fire.root)                       // place / scale root as you like
fire.setMode(.twoHandArc)                    // smooth 2.2 s morph between forms
fire.setControlPoints(primary: leftPalm,     // root-local metres; disables the script and
                      secondary: rightPalm,  // smooths input with a critically damped spring
                      snap: false)           // true: jump there (hand reappeared elsewhere)
fire.releaseControlPoints()                  // back to the scripted choreography
fire.update(dt:)                             // once per frame
fire.ignite() / fire.dissipate() / fire.restart()
fire.isPaused, fire.quality, fire.userIntensity, fire.showsControlPoints
```

Forms are `SpineShape`s (`VFX/FireShapes.swift`):
* `LivingFlameShape` – a short breathing emitter column above one palm.
* `RibbonShape` – records the leading control point's path; the body samples that history over
  3.4 s with per-segment lazy following, so it curls like the drawn stroke.
* `ArcShape` – bows between two points in the plane facing the viewer, height grows with
  separation, travelling wave + depth undulation, fire pooled in each palm.

The scripted motion (`Choreography/ScriptedChoreography.swift`) only produces control points:
slow, eased Tai-Chi-paced strokes.

### Hand tracking (device only)

`App/HandTracking.swift` drives the same seam from real hands:
* `HandControl` runs an ARKit `HandTrackingProvider` and returns predicted palm points each frame
  (centre of wrist / middle metacarpal / middle knuckle, lifted 3.5 cm along the palm normal).
* `HandDriver` picks the hands the mode needs (Living Flame / Ribbon: right palm, else left;
  Two-Hand Arc: left → primary, right → secondary), converts them into `fire.root` space and calls
  `setControlPoints`. Hands missing for > 0.25 s fade the fire out; when they reappear it relights
  there (`snap: true`, no sweep across the room). `releaseControlPoints()` hands back to the script.

The simulator has no hand tracking, so it keeps running the scripted motion (the panel's
"Hands" toggle is disabled). The autotest covers the driver logic with synthetic palms. Live hand
tracking needs a Vision Pro: set `DEVELOPMENT_TEAM` in `project.yml`, build to the device, accept
the hand-tracking prompt, and turn on "Show control points" to see the palm points.

### Project layout

```
project.yml                     XcodeGen spec (bundle id dev.elemental.fire.opus, visionOS 27)
FireOpus/App/                   SwiftUI app, control panel, immersive view, head placement, hand tracking, autotest
FireOpus/VFX/                   FireEffect engine, particle layers, shapes, materials, ShaderGraph DSL
FireOpus/Choreography/          scripted control-point motion
FireOpus/Shaders/               Metal kernels (shipped as source, compiled at runtime)
Tools/                          run_sim.sh, shot.sh, check_metal.swift
docs/                           original benchmark brief, evaluation sheet, technical report
```

See **[docs/TECHNICAL_REPORT.md](docs/TECHNICAL_REPORT.md)** for what was tested, compromises and
known limitations.
