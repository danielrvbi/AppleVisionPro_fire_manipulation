# Vision Pro Fire VFX: Astra vs Opus

This pack contains **8 image references** and a **single identical benchmark prompt** for two independent coding agents.

## Files

| Filename | Role |
| --- | --- |
| `references/visual_01_living_flame.png` | Idle palm flame appearance |
| `references/visual_02_flowing_ribbon.png` | Curving fire stream shape |
| `references/visual_03_two_hand_arc.png` | Two-point flame shape |
| `references/visual_04_fire_anatomy.png` | Close-up shader/particle details |
| `references/visual_05_quality_comparison.png` | Avoid vs target look |
| `references/motion_01_follow_and_flow.png` | Inertial one-point movement storyboard |
| `references/motion_02_circular_motion.png` | Circular two-point movement storyboard |
| `references/motion_03_expand_compress.png` | Two-point separation storyboard |
| `START_HERE.md` | Copy this entire prompt to both agents |
| `EVALUATION.md` | Device review and benchmark scorecard |

## Run Astra and Opus simultaneously

Create TWO completely independent project directories or Git worktrees. Place this reference pack into each one, then run Astra in one directory and Opus in the other. Provide **exactly the same `START_HERE.md`** to each. Do not let agents concurrently edit one shared source tree or use the same Xcode DerivedData directory. If running concurrent builds, each should use its own `-derivedDataPath` and distinct build output folder.

The cleanest A/B comparison allows both to solve the same problem independently. Do not merge their implementations until after you have tested each. If they share one paid provider or API quota, requests can compete for rate limits or spend tokens concurrently.

## Important

The source images are visual storyboards, **not actual executable assets**. The agents must recreate the visuals as real-time 3D/VFX systems. Passing static image overlays off as the result defeats the experiment.
