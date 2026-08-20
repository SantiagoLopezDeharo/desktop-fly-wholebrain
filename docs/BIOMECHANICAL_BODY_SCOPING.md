# Scoping: a real biomechanical body driven by real motor neurons

Not a plan to build — a go/no-go decision point. This is a genuinely
different project from DesktopFly, not a `Sim.swift` extension, and the
numbers below are why.

## What "the brain actually decides direction, with a real body" requires

1. **A second connectome.** FlyWire (what this app uses) covers the *brain*
   only. Leg motor neurons live in the ventral nerve cord — a separate
   dataset, **MANC** (Male Adult Nerve Cord, Janelia): 23,437 neurons,
   1,152,548 connections (~49 synapses/neuron average — denser than the
   brain's 19.4). Different license terms need checking before assuming
   FlyWire's CC BY-NC applies.
2. **A real biomechanical body**, not hand-authored SceneKit IK. The
   reference implementation is **NeuroMechFly / FlyGym**
   (neuromechfly.org, Ramdya lab, EPFL) — real fly morphology from micro-CT
   (65 segments, 122 degrees of freedom), open-source, actively developed
   (2022 → v2 2024, Nature Methods → 2025 Nature whole-body physics paper).
3. **A different tech stack.** FlyGym is a Python package built on
   **MuJoCo** (they moved off PyBullet specifically for stability/actuator
   support). This app is Swift + SceneKit on macOS. There is no mainstream
   Swift/SceneKit biomechanical physics engine to drop this into — MuJoCo has
   a C API that could in principle be bridged, but nobody has done that
   integration, and building it is itself a multi-week undertaking before any
   fly-specific work starts.
4. **Real-time performance, twice over.** The whole-brain LIF sim alone is
   already ~3 ms/sim-ms (0.33x realtime) on this 4-core Intel — see
   `docs/WHOLE_BRAIN_ROADMAP.md`. Add a second ~23K-neuron network (MANC) plus
   122-DOF rigid-body dynamics with contact resolution, and this stops being
   an interactive desktop pet and becomes what it is in the source papers: a
   batch/offline research computation, typically GPU-accelerated and trained
   with RL over many hours, not stepped live at 60 fps in a menu-bar app.

## The honest comparison

This isn't "a bit more work than the whole-brain fork." Sections above are a
description of an active, multi-year, multi-paper research program at a
dedicated lab (2022, 2024, 2025 publications) with GPU infrastructure and RL
training pipelines behind it. DesktopFly's whole-brain work took this
session; this would not.

## If pursued anyway: the realistic shape of it

- **Don't rebuild the physics.** Use FlyGym directly rather than
  reimplementing biomechanics — it's open-source and already does the hard
  part (morphology, muscle/actuator model, contact physics).
- **This stops being a macOS menu-bar app.** Realistically it becomes a
  Python/MuJoCo project that borrows the *concept* of `Sim.swift`'s brain
  loader (and possibly `etl_fullbrain.py`'s ETL logic, ported) rather than
  the Swift code itself. Treat it as a new repo, not a branch of
  `desktop-fly-wholebrain`.
- **Scope it as research, not a feature.** Natural first milestone: load
  FlyGym's fly body standalone, drive it with a *simplified* hand-written
  controller (no connectome yet) to confirm the pipeline runs at all on
  available hardware, before attempting to wire in FlyWire + MANC spiking
  output. Getting a real DN spike train to produce a coherent walk cycle
  through a muscle model is itself an open research problem, not a solved
  integration.

## Recommendation

**No-go for DesktopFly.** The measured DNa-steering result
(`CLAUDE.md`'s tuning gotchas) already shows real signal is available but
weak at the population scale the brain-only data supports; a full VNC +
biomechanical body wouldn't fix that, it would mean re-deriving the entire
motor pipeline in a different language and physics model. If there's future
appetite for the research-grade version, it should start as its own repo
scoped from FlyGym outward, evaluated on its own timeline — not as a
continuation of this fork.

## Sources

- MANC connectome scale: [Janelia MANC project](https://www.janelia.org/project-team/flyem/manc-connectome), [DN→motor circuit organization (eLife)](https://elifesciences.org/articles/96084)
- NeuroMechFly / FlyGym: [neuromechfly.org](https://neuromechfly.org/), [NeuroMechFly v2 (Nature Methods 2024)](https://www.nature.com/articles/s41592-024-02497-y), [whole-body physics simulation (Nature 2025)](https://www.nature.com/articles/s41586-025-09029-4)
