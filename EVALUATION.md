# Fire VFX evaluation

Evaluate both implementations wearing Apple Vision Pro, not from one flattering screenshot. Rate each 1–5 independently:

| Metric | Astra | Opus | How to judge |
|---|---|---|---|
| Visual fidelity |  |  | Looks like layered fire rather than orange graphics |
| 3D spatial quality |  |  | Natural parallax and depth during head movement |
| Motion continuity |  |  | Smooth flowing ribbons, no visible discontinuities |
| Two-point deformation |  |  | Arc expands/compresses elegantly |
| Quality of embers/smoke |  |  | Detail supports main fire rather than obscuring it |
| Performance |  |  | Stable and responsive on hardware; measure if possible |
| Autonomous completion |  |  | Little or no manual authoring needed |
| Reliability |  |  | Build, run and loop without crashes or leaks |

Record separately: build passes (yes/no), run on headset (yes/no), manual fixes, number of corrective prompts, approximate tokens and direct cost if available. Neither agent wins purely because it produced prettier **reference images**. The evaluated output must be executable VFX.

**Stop condition:** If one implementation looks convincingly fiery and 3D while moving, Step 1 has succeeded. Then and only then add real hand control as Step 2.
