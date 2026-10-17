# FIRE VFX BENCHMARK: APPLE VISION PRO

You are an autonomous senior graphics programmer and technical VFX artist. Build a runnable visionOS application that recreates the *visual quality and motion language* of the eight PNG references in `references/` as a true real-time, spatial, animated fire effect.

## Context and goal
This is a small personal experiment designed to measure what an AI coding agent can autonomously create. It is **not** a game or product. I want a premium-looking, meditative fire-bending visual effect, inspired by slow Tai Chi movements: a floating flame, a flowing S-shaped ribbon, and a graceful arc between two virtual control points. The fire should appear to be living and guided, not fired as a weapon.

**Your objective is the visual effect itself.** Prioritize making one truly beautiful fire effect over implementing extra features. You have artistic and technical freedom within the requirements below. Do not ask me to manually create assets, author shaders, or edit nodes in Blender/Reality Composer Pro.

## Target runtime
- Apple Vision Pro, using a native visionOS Swift / SwiftUI / RealityKit application.
- Start in a **mixed immersive space** with passthrough surroundings. I don't want you to recreate the apartment shown in the reference images. The apartment and human hands are framing/context only, NOT textures, virtual scenery, or assets to be copied into the app.
- Create genuinely three-dimensional, world-anchored, stereoscopically sensible fire. It should have convincing volume/parallax when the viewer moves their head. Layered particles, procedural meshes/ribbons, custom materials/shaders, and GPU techniques are allowed when supported by the target platform.
- The eight reference PNGs are **art direction only**. Do not place the PNGs as flat cards, billboards of the whole image, animated video overlays, or pre-rendered fire sequences and claim these are the effect. Particle sprite textures are allowed as **components** of a spatial VFX implementation, but not as a substitute for actual 3D behavior.
- No external paid asset packs. You may generate textures, meshes, configuration, materials and animations through code/scripts. If something requires Reality Composer Pro interaction, investigate an automatable import/workflow or use another supported approach; report manual blockers explicitly.
- Prioritize a stable native headset frame rate. Avoid unbounded particles, heavy GPU passes, or excessive transparency overdraw. Report measured performance only when measured on hardware.

## Exactly what to make (Step 1 only)
Implement a single reusable fire effect with **three scripted demo modes**:

1. `Living Flame` (visual_01, visual_04): a small hovering flame with a bright white-yellow inner core, orange translucent tongues, subtle red edges, restrained embers, faint smoke and natural flicker. It should not look like an opaque orange cone or a flat sprite.
2. `Flowing Ribbon` (visual_02, motion_01): a continuous, curling, S-shaped living stream of fire, moving along an automatically animated path. It stretches and flows with smooth momentum and slight lag, rather than teleporting or following a rigid laser-like spline.
3. `Two-Hand Arc` (visual_03, motion_02, motion_03): a broad, dynamic fire bridge between two *simulated control points*. Use a scripted loop that demonstrates slow circular motion and expansion/compression. Shape must deform smoothly, with turbulence and trailing embers, not jump between fixed poses.

Use `visual_05_quality_comparison.png` as a clear anti-reference (left = unacceptable; right = target).

## Test harness
- Provide a tiny floating SwiftUI control window or minimal controls to switch among the three demo modes, pause/play animation, restart, and adjust quality/scale if practical.
- The effect must run autonomously on scripted paths. **Do not implement hand tracking or gesture recognition yet.** That is the next experiment. Design the effect so future hand-tracking can supply one or two changing 3D control positions without rewriting the VFX engine.
- Keep the environment minimal: ideally passthrough with the effect approximately 0.7–1.2 metres in front of the viewer, at a comfortable viewing height. Don't render a 3D room, arena, dummy, character, score, or unrelated UI.
- Preserve the effect across continuous loops. Handle pause/resume, returning to idle, and cleanup without leaking entities or emitters.

## Engineering and validation
- Use RealityKit capabilities supported by the installed SDK. Investigate `ParticleEmitterComponent`, procedural geometry, `ShaderGraphMaterial` or `CustomMaterial` as appropriate. Do not invent API names or assume shader features are supported; verify in installed SDK/documentation.
- Create a complete self-contained Xcode/visionOS project with all generated assets, build settings, and clear `README.md` instructions.
- Attempt a local build with `xcodebuild` if an Apple build environment is available, fix build errors, and report the exact command and result. Simulator testing is useful but does not establish physical-headset visual quality or performance.
- Expose clean VFX-facing controls (e.g. spawn, set control positions, set mode/intensity, update, dissipate); API naming is up to you.
- Leave readable source code, a compact implementation explanation, and a short summary of what you had to compromise visually because of real-time visionOS constraints.
- Keep scope bounded. No need for Firebase, networking, servers, authentication, game logic, scene editor, or extra infrastructure.

## Definition of done
1. A user can open the Xcode project and run it on an Apple Vision Pro (subject to ordinary Apple signing and device setup).
2. The fire is generated and animated by runtime-rendered VFX components, not a static/looped illustration.
3. All three scripted modes are visible and transition smoothly. The fire looks like the reference pack in *style* and *motion intent*, even if the exact film-CGI detail must be approximated.
4. A small change in camera/head position reveals genuine spatial volume rather than a billboarded photo.
5. The implementation is ready to be controlled by real hand-tracking data in a future step, without implementing that step now.
6. State clearly what you actually built, compiled, ran, and personally verified. Never claim headset testing if you did not perform it.

## Autonomous workflow
Inspect the references, choose a VFX strategy, build the complete first version, compile and iterate, and document the result. Make reasonable choices rather than stopping for design questions. If a feature cannot be achieved with the available SDK, pick the strongest viable alternative and document the deviation. If you can access screenshots or runtime feedback, use them to refine the output. Your final response should give the build result, project entry point, available modes, compromises, and any remaining device-only checks.
