# Technical report — Fire Opus (Step 1: scripted fire VFX)

## What was generated

| Area | Files | Notes |
|---|---|---|
| Xcode project | `project.yml` → `FireOpus.xcodeproj` | XcodeGen, visionOS 27, bundle `dev.elemental.fire.opus`, Swift 6 strict concurrency |
| GPU simulation | `FireOpus/Shaders/FireSimulation.metal` | spawn on spine, buoyancy, 2-octave curl noise, drag, cohesion, convergence, quad emission into `LowLevelMesh` |
| Procedural texture | `FireOpus/Shaders/NoiseTexture.metal` | tileable fbm / ridged / smoke channels, generated on GPU at startup into a `LowLevelTexture` |
| Materials | `FireOpus/VFX/FireMaterials.swift`, `ShaderGraphBuilder.swift` | 4 ShaderGraph programs (flame, spark, smoke, shade) built in code with the visionOS 27 `ShaderGraph` API |
| Engine | `FireOpus/VFX/FireEffect.swift`, `ParticleLayer.swift`, `FireShapes.swift` | 6 layers, mode morphing, intensity, pause, restart, quality, control-point API |
| Choreography | `FireOpus/Choreography/ScriptedChoreography.swift` | slow eased palm paths for the three modes |
| App | `FireOpus/App/*` | control window, mixed immersive space, head-relative placement (ARKit world tracking), autotest |
| Tools | `Tools/run_sim.sh`, `Tools/shot.sh`, `Tools/check_metal.swift` | build/run on the Opus simulator by UUID, screenshots, offline kernel compile check |

No bitmap, video, USD or Reality Composer Pro assets exist in the project; all visual content is
computed at runtime.

## Key technical decisions

1. **Programmatic ShaderGraph (visionOS 27).** The SDK ships a new `ShaderGraph` module
   (`ShaderGraph.NodeLibrary`, `ShaderGraphMaterial.Program.Descriptor`). I enumerated its 1,517
   node definitions on the host Mac and checked every node used. This allowed a custom
   vertex stage (per-eye billboarding) and fragment stage (noise erosion, colour ramp) without
   hand-authoring USD or opening Reality Composer Pro.
   Finding: `ND_realitykit_geometry_modifier_custom_attribute` fails with
   `failedToConstructMaterial` when used, so per-particle data travels in the standard
   `color`, `normal`, `uv0` and `uv1` attributes instead.
2. **Runtime Metal compilation.** The Metal Toolchain component is not installed on this Mac
   (`xcodebuild` asks for `-downloadComponent MetalToolchain`). Rather than modify the shared
   Xcode install, the kernels ship as source in a folder reference and are compiled with
   `MTLDevice.makeLibrary(source:)` at launch. `Tools/check_metal.swift` compiles the same source
   on the Mac GPU as a pre-flight check.
3. **Particles + spine, not meshes.** A procedural ribbon mesh with scrolling noise would show
   its own surface and edges. Thousands of noise-eroded, velocity-stretched cards around a 3D
   spine give volumetric parallax, ragged licking silhouettes and continuous motion. The same
   spine abstraction drives all three modes and hand tracking later.
4. **Heat-shade layer.** Additive fire over a bright passthrough room washes to white. A faint
   alpha-blended dark haze behind the body restores saturation. It is a deliberate art-directed
   cheat (real flames don't darken the background).

## What was tested (and how)

All tests ran on this Mac against the **Vision Pro Opus** simulator
(`25507330-F20F-4074-889C-4044BD6D44FF`). Every simulator command used that UUID explicitly.

| Check | Result |
|---|---|
| `xcodebuild … -configuration Debug -destination id=<Opus UUID> … CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED** |
| Same, `-configuration Release` (simulator) | **BUILD SUCCEEDED**, ran |
| `-configuration Release -destination generic/platform=visionOS CODE_SIGNING_ALLOWED=NO build` (device SDK, compile only) | **BUILD SUCCEEDED** (not signed, not installed on a headset) |
| Metal kernels via `Tools/check_metal.swift` | compile OK (`generateFireNoise`, `simulateFire`) |
| ShaderGraph materials | all four programs construct at runtime in the simulator (`FireOpus: effect ready`) |
| Head-relative placement | world tracking works in the simulator (`placed fire relative to head at (0.0, 1.38, -0.85)` with the earlier 0.22 m drop) |
| Visual inspection | ~25 simulator screenshots across iterations of all three modes and mid-transition morphs, compared against the references |
| Autotest (`-fireAutoTest YES`) | **PASS**: 2 full cycles of all modes + pause/resume + dissipate/ignite + restart + quality low/high; entity count constant (8), memory footprint flat at ~71 MB, no fault-level log messages |

Iterations driven by those screenshots: flame far too tall → buoyancy/drag/life retuned; white
blow-out → cooler body temperature, core reduced, shade layer added; bonfire "V" silhouette →
convergence force; straight rope-like ribbon → path-following trail; floating rope tail → drift
removed; over-bright compressed arc → particle count proportional to spine length; heavy smoke
cloud → smoke opacity reduced.

## Not verified / unknown

* **No physical Apple Vision Pro was used.** Headset visual quality, stereo comfort, true depth
  and parallax under head motion, and performance are **unverified**. No frame-rate figure is
  claimed. The simulator's ~120 updates/s says nothing about headset GPU load.
* The device build was compiled but never signed, installed or run.
* Runtime Metal compilation on device is a supported API but untested here. It adds a one-off
  compile at launch, estimated at well under a second (not measured).
* Fill-rate cost: on **High** the ribbon/arc can have ~5–6k alpha-blended cards (most
  additive), with heavy overdraw near the viewer. If the headset drops frames, use the
  **Quality** control (Low = 45 % of particles) or lower `capacity` in `FireEffect.build()`.
  The per-pixel shader is cheap (one texture sample, no procedural noise per pixel).
* Simulator rendering may differ from the headset in tone mapping and passthrough brightness.
  The look was tuned against the simulator's bright daylight room, so it may appear more saturated
  and brighter in a dim real room. `Intensity` adjusts this.
* In the simulator, the virtual room's furniture can occlude the fire (seen with the sofa). On
  device, passthrough does not occlude virtual content in this way.

## Visual compromises vs. the reference images

* The references are offline-rendered CGI with millions of filament details. Here the inner
  filaments come from a 256² noise texture eroding each card. The base of the living flame reads
  as a smooth bright glow rather than a web of fine white filaments.
* Cards are camera-facing (per eye), so an individual tongue has no true thickness. Volume comes
  from the 3D distribution of many cards.
* Smoke is intentionally faint. Strong dark smoke over passthrough looks like dirt on the display.
* No light is cast onto real surfaces or hands (passthrough cannot be relit without scene
  reconstruction, which is out of scope).
* Glow is a soft halo layer, not a post-process bloom (RealityKit offers no custom post-FX).

## Next step (hand tracking)

Add a `HandTrackingProvider`, compute palm centres (e.g. middle-finger metacarpal + palm
normal offset), convert them to `fire.root` local space and call
`fire.setControlPoints(primary:secondary:)` each frame. Choose the mode from hand pose or keep
the selector. The engine already smooths noisy input with a critically damped spring.
