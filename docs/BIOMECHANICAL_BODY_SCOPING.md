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
3. **A different tech stack — correction from the first pass of this doc.**
   FlyGym is Python on **MuJoCo**. This app is Swift + SceneKit. The first
   version of this doc claimed no Swift/MuJoCo integration existed and
   bridging it would be a multi-week undertaking — **that was wrong**, not
   double-checked before writing. A maintained Swift Package Manager binding,
   [`liuliu/swift-mujoco`](https://github.com/liuliu/swift-mujoco), exists and
   ships as a native macOS framework (`-framework mujoco`). MuJoCo can link
   **directly into the Swift binary** — no Python subprocess, no IPC bridge,
   no separate language boundary to cross. (An IPC bridge to an actual Python
   FlyGym process is also viable — local-socket overhead is sub-millisecond,
   negligible next to the simulation cost below — and would make sense
   specifically to reuse an existing pretrained FlyGym controller rather than
   reimplementing body/actuator config in Swift. But it's not required.)
   The real remaining gap is the point below, which no amount of clean
   plumbing between processes fixes.
4. **Real-time performance, twice over.** The whole-brain LIF sim alone is
   already ~3 ms/sim-ms (0.33x realtime) on this 4-core Intel — see
   `docs/WHOLE_BRAIN_ROADMAP.md`. Add a second ~23K-neuron network (MANC) plus
   122-DOF rigid-body dynamics with contact resolution, and this stops being
   an interactive desktop pet and becomes what it is in the source papers: a
   batch/offline research computation, typically GPU-accelerated and trained
   with RL over many hours, not stepped live at 60 fps in a menu-bar app.
   Process architecture (native link vs. IPC) doesn't change this number
   either way — the compute has to happen somewhere.
5. **"Real spikes drive real joints" hasn't been demonstrated anywhere,
   research included.** I checked the most directly-relevant paper I could
   find, *"Whole-Brain Connectomic Graph Model Enables Whole-Body Locomotion
   Control in Fruit Fly"* (2026), expecting an existence proof. It isn't one:
   like NeuroMechFly's own connectome-constrained visual network, it uses
   connectome *topology* as a structural prior to initialize/constrain a
   **trained** neural network controller (RL), not literal LIF spikes wired
   straight to actuators. So the honest target, even at the research
   frontier, is "train a controller shaped by MANC's real wiring," not
   "simulate MANC and watch the joints move" — a materially different, softer
   claim than what item 1's DN→motor-neuron connectivity might suggest is
   possible.

## The honest comparison

This isn't "a bit more work than the whole-brain fork." Sections above are a
description of an active, multi-year, multi-paper research program at a
dedicated lab (2022, 2024, 2025 publications) with GPU infrastructure and RL
training pipelines behind it. DesktopFly's whole-brain work took this
session; this would not.

## If pursued anyway: the realistic shape of it

- **The process-architecture question has a clean answer now.** `swift-mujoco`
  (native, in-process) is simpler and avoids subprocess-lifecycle management
  (spawn, health-check, restart on crash, bundling a Python+MuJoCo runtime
  for end users who just wanted a desktop pet). An IPC bridge to real FlyGym
  is the better call only if reusing an existing Python environment/pretrained
  controller matters more than staying a single self-contained binary — worth
  keeping in mind, but not the default.
- **Don't rebuild the physics either way.** Whether native or IPC-bridged,
  drive an existing body model (FlyGym's, or build one against `swift-mujoco`
  from the same micro-CT-derived morphology) rather than reimplementing
  biomechanics from scratch.
- **The actual open problem is the controller, not the plumbing.** Per point 5
  above, nobody has shown raw connectome spikes driving joints directly.
  Realistic scope is training a controller (RL, most likely) that's
  *structured* by real MANC connectivity — which means this needs an RL
  training pipeline and iteration budget, not just a simulation loop.
- **Scope it as research, not a feature.** Natural first milestone: get a fly
  body (via `swift-mujoco` or FlyGym) walking under *any* controller — hand-
  written, not connectome-derived — to confirm the physics pipeline runs at
  all on available hardware, before attempting anything connectome-shaped.

## Recommendation

**No-go for DesktopFly, but softer than the first pass of this doc claimed.**
The tech-stack barrier is lower than I first said — `swift-mujoco` makes a
native, single-binary path real. What still doesn't change: the compute cost
(point 4) and, more fundamentally, that "real spiking drives real joints" is
not a solved problem to integrate — it's a research question to attempt,
requiring an RL training pipeline this project has none of. The measured
DNa-steering result (`CLAUDE.md`'s tuning gotchas) already shows how weak
real signal is at brain-only population scale; a full VNC + biomechanical
body doesn't sidestep that; it exchanges a hand-authored gait for a
hand-*trained* one shaped by real wiring, which is a genuinely interesting
but separate research project — its own repo, evaluated on its own timeline,
not a continuation of this fork.

## Sources

- MANC connectome scale: [Janelia MANC project](https://www.janelia.org/project-team/flyem/manc-connectome), [DN→motor circuit organization (eLife)](https://elifesciences.org/articles/96084)
- NeuroMechFly / FlyGym: [neuromechfly.org](https://neuromechfly.org/), [NeuroMechFly v2 (Nature Methods 2024)](https://www.nature.com/articles/s41592-024-02497-y), [whole-body physics simulation (Nature 2025)](https://www.nature.com/articles/s41586-025-09029-4)
- Swift/MuJoCo native binding: [`liuliu/swift-mujoco`](https://github.com/liuliu/swift-mujoco)
- Connectome-as-structural-prior, not literal spike-to-actuator: *"Whole-Brain
  Connectomic Graph Model Enables Whole-Body Locomotion Control in Fruit
  Fly"* (arXiv:2602.17997)
