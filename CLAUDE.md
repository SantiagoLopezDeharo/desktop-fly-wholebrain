# DesktopFly — agent notes

A 3D fruit fly on a transparent macOS overlay, behavior-driven by a 1 kHz
leaky-integrate-and-fire (LIF) simulation of a 668-neuron circuit extracted
from the real FlyWire connectome (FAFB v783). The body is procedural
SceneKit; the brain data is real.

## Files

| file | contents |
|---|---|
| `main.swift` | overlay scene, CLI modes, `SignalBuilder` (rates→commands), `Coordinator` (render-loop hub), `AppDelegate` (menu, timers, display switching) |
| `FlyModel.swift` | procedural fly body + `Fly` behavior (states, gait, flight, ledges, sleep) |
| `Sim.swift` | data loading, `BrainSignals`, `SpikeBus`, `LIFSim` (CSR network, stimulation API) |
| `BrainView.swift` | brain window: point clouds, click-to-stimulate, spike flashes |
| `Environment.swift` | permission-free senses: `WindowSense` (ledges/looms), circadian curve, user idle, thermal tempo |
| `Food.swift` | draggable food decals (`FoodItem`/`FoodPanelView`); positive-smell attraction lives in `Fly.foodSeek` (`FlyModel.swift`) |
| `etl.py` | raw Codex dumps → `data/brain_points.json` + `data/circuit.json` |
| `etl_fullbrain.py` | raw Codex dumps → `data/fullbrain.bin` (whole brain, binary CSR) |
| `data/` | shipped derived data (CC BY-NC 4.0 — see `data/DATA_LICENSE.md`) |
| `docs/WHOLE_BRAIN_ROADMAP.md` | whole-brain scale-up: measurements, what's done, what's left |

## Two brains

The app runs **either** the curated 668-neuron circuit (default) **or** the
whole FlyWire v783 brain (`--fullbrain`): 139,255 neurons / 2,700,513 edges.

```sh
python3 etl_fullbrain.py <raw_dir>   # build data/fullbrain.bin (~24 MB, gitignored)
./DesktopFly --fullbrain             # live fly driven by the whole brain
./DesktopFly --brainbench            # whole-brain speed + stability + body coupling
```

Whole-brain specifics, all in `Sim.swift`:
- `LIFSim(fullBrain:)` is a separate init from `LIFSim(circuit:)`. **Changes to
  one do not apply to the other** — the 668 path is tuned and must stay put.
- Command-DN baselines are `0.004` here, not `0.036`. The circuit needed the
  large value because the excerpt carried almost no drive onto those DNs; the
  whole brain delivers 2.7k–23.8k synapses each, so the old value pins every
  command on permanently.
- **Homeostasis is a modeling choice, not connectome data**: a global gain
  holds the population at ~5 Hz, and `tunePop` nudges each command DN toward a
  target resting rate. Without them the network has no usable operating point.
  Say so in any writeup — it is the least "the data did it" part of the system.
- The whole brain runs on its own thread (`SimRunner` in `main.swift`) because
  a step costs ~3 ms per simulated ms. It falls behind gracefully (brain in
  slow motion) rather than spiralling; it does **not** hit 1 kHz realtime on
  4-core Intel.
- **`food_orn` (244)**: DM1/DM4/VA2/VM3/DP1m antennal-lobe glomeruli, real
  cell types documented as attraction-driving (Nat. Commun. 2019,
  10.1038/s41467-019-09069-1). Whole-brain only — the 668 circuit never
  includes them. `Coordinator` computes proximity to the nearest `FoodItem`
  and sets `sim.foodDrive` (0..1); the resulting `sim.rateFoodOrn` becomes
  `BrainSignals.foodAttraction`, read by `Fly.foodSeek` (`FlyModel.swift`) to
  drive walking urgency. Direction-finding stays geometric (atan2 to the
  food's actual position) — that's sensory-transduction geometry, same
  category as how the loom pathway's own L/R injection split is computed, not
  a claim that steering itself is brain-derived. `--brainbench` probes the
  response curve and checks it doesn't leak into a false GF escape.

## Build, run, verify

```sh
./build.sh                     # bare swiftc, -swift-version 5, no Xcode project
./DesktopFly                   # menu-bar 🪰; quit from there
./DesktopFly --simtest         # circuit invariants (MUST pass after sim/etl changes)
./DesktopFly --behaviortest    # 17 end-to-end sim→body checks (MUST pass after behavior changes)
./DesktopFly --snapshot f.png  # offscreen fly render
./DesktopFly --brainshot b.png # offscreen brain render
```

Always run **both** suites after any change; they are the ground truth.
A handful of `--behaviortest` scenarios (seen so far: "DNp09 stim -> walks",
"ledge attach", "threat while grounded raises wings", "thermal tempo") are
inherently flaky at **roughly 4-5/25 runs total** — measured across several
commits, pre- and post-whole-brain. Don't chase a single red run or assume the
scenario name tells you which change caused it; take a 25-run sample on both
the suspect commit and its parent before concluding you broke something.
Key invariants: GF silent over 4 s of rest, GF fires ≤ ~10 ms after abrupt
loom, walk-drive duty 20–50%, siesta (scale 0.84) walk-drive > 3%,
no per-frame scale/z snap at landing.

**SourceKit note**: the IDE reports "Cannot find type ..." across files —
false positives. The five .swift files compile as one module via build.sh;
trust the compiler, not single-file diagnostics.

## Threading model

- SceneKit render thread: `Coordinator.renderer(_:updateAtTime:)` steps the
  sim and updates flies. All cross-thread mutation goes through
  `Coordinator.enqueue {}` (lock + pending-actions queue, drained per frame).
- Main thread: timers (mouse 30 Hz, windows 0.7 s), menu actions, global
  click monitor — these only call enqueue/setters.
- Brain window has its own render delegate; spikes cross via `SpikeBus` (locked).
- `LIFSim.stimulate()` is thread-safe (pending list merged at `step()`).

## Neuron → behavior mapping (current)

| role slug | FlyWire types (count) | drives | consumed in |
|---|---|---|---|
| `lc4`, `lplc2` | LC4 (104), LPLC2 (210) | looming input → nervous darting; excite GF | `BrainSignals.nervous` |
| `gf` | DNp01 (2) | escape takeoff (spike = takeoff) | `BrainSignals.escape` |
| `dna01`, `dna02` | DNa01 (2), DNa02 (2) | steering: L−R rate → turn bias (slow-adapted) | `BrainSignals.turnBias` |
| `dnp09` | DNp09 (2) | walk/rest hysteresis + walking speed | `BrainSignals.walkDrive` |
| `dng11` | DNg11 (6) | grooming hysteresis | `BrainSignals.groomDrive` |
| `mdn` | MDN (4) | backward walking burst | `BrainSignals.backward` |
| `escw` | DNp02/DNp04/DNp11 (6) | wing-beat effort in flight, threat wing-raise | `BrainSignals.wingDrive` |
| `other`+ascending (27) | strongest ascending partners | body→brain gait proprioception (input target) | `sim.gaitDrive/gaitPhase` |
| `other`+sensory (16) | strongest sensory partners | wind/tap input; electrically boosted onto GF | `sim.airPuff`, taps |

Whole-population rate → `BrainSignals.arousal` (spontaneous-takeoff gate,
flight effort). Only fly #1 has the brain; extra flies use legacy
distance-based behavior (`signals: nil` path).

## Adding a new neuron population (recipe)

1. **Check the type exists** in v783:
   `gzcat consolidated_cell_types.csv.gz | grep -c ',TYPE,'` (raw dumps: see
   README "Regenerating the data" for the GCS URLs; don't commit raw dumps).
2. **etl.py**: add `"TYPE": "roleslug"` to `CORE_TYPES`; add the slug to the
   reserved-partner loop AND the in-degree report loop.
3. **Rerun ETL** and read the report: `in-circuit drive onto roleslug` should
   be ≥ several hundred synapses — if it's tiny, the population will be
   noise-driven, not network-driven (this bug shipped once for DNg11: 6 syn).
4. **Sim.swift**: group array (`private(set) var xyz: [Int]`), populate in the
   init role switch, baseline (command DNs: deterministic `0.036`; never
   random per-side for bilateral pairs — asymmetry must come from wiring),
   rate EMA (`rateXyz`) in the spike-counting switch.
5. **SignalBuilder** (main.swift): normalize `rateXyz` into a new
   `BrainSignals` field — **always clamp** (an unclamped walkDrive once sent
   the fly to 1,100 pt/s).
6. **FlyModel.brainBehavior**: consume the signal. Use hysteresis + the
   `stateAge` dwell guard (≥0.4 s) for state changes, cooldown timers for
   one-shot actions; make sure the action works from every grounded state
   (MDN was once dead from idle).
7. **BrainView.swift**: role color in the circuit overlay + `regionName` label
   (clicking that region should demo the behavior).
8. **Tests**: add a `--behaviortest` scenario (stimulate population → assert
   body reaction) and, if sim-level, a `--simtest` probe. Run both suites.

## Tuning gotchas (learned the hard way)

- **Operating point is razor-thin**: neurons rest at `baseline × 20.4` vs
  threshold 1.0 (tau 20 ms). Never scale baselines linearly by a mood/time
  factor — compress toward 1 (`1 − (1−a)×0.35`), or populations go silent
  (the "siesta coma" bug).
- **Escape is a race**: LC→GF electrical drive (×6 boost) vs ~1,200 syn of
  feedforward inhibition (4 ms delayed). Slow ramps lose to inhibition by
  design — test escapes with **abrupt** loom steps, not ramps.
- **Live modifiers must never weaken takeoff**: flight effort =
  `max(baseEffort, live formula)` (a regression once halved escape altitude).
- Weight scale 0.0008/synapse; refractory 2 ms; inhibitory synaptic delay
  4 ms (ring buffer); `weightScale`/`gapJunctionBoost` live in `Sim.swift`.
- Landing must go through the flare (alt decays below 0.035) — never snap
  scale/z in `land()`.
- **Measured and rejected: real DNa-based food steering.** food_orn synaptic
  paths to DNa01/02 exist (3-4 hops, 7-43 syn bottleneck, confirmed by raw
  graph BFS) but the *functional* signal is too weak/inconsistent to use:
  stimulating food_orn-left produced the expected DNa left-bias in 8/10
  trials (mean +1.4 Hz vs ±2.8 Hz trial noise — small relative to the noise);
  food_orn-right produced the expected right-bias in only 3/10 (mean pointed
  the *wrong* way). DNa01/02 is 2 neurons/side, so population-rate noise
  dominates at that scale, and central-complex steering circuits are
  documented as having crossed/non-obvious topology, so "same-side stim ->
  same-side response" was never a safe assumption. Don't re-attempt this with
  the same naive same-side/crossed framing without new evidence; if revisited,
  measure properly first (LIFSim's RNG is seeded from a fixed default, so
  repeated `LIFSim(fullBrain:)` calls are bit-for-bit identical — vary the
  settle duration per trial to get real independent samples, and compare
  against a matched *unstimulated* run at the same settle offset, not a raw
  diff, since DNa's resting L-R diff swings ±5 Hz from noise alone).
  **Retested with PFL3** (24 neurons, direct 496-syn input to DNa02, the
  literature's actual steering-decision neuron, one hop closer to food_orn
  than DNa) with the same corrected methodology, n=15/side: same verdict, for
  a more interesting reason. food-L and food-R stimulation shifted PFL3's L-R
  balance the *same* direction (+0.34 vs +0.38 Hz, real SNR ~0.85, not just
  noise) instead of opposite directions — a real effect that isn't
  directional. Central-complex heading is a ring/population-vector code
  across ~16 EPG wedges; a left-half/right-half injection and readout is the
  wrong lens for that representation, and a correct one (decoding the actual
  EPG population vector) is a materially bigger undertaking, not attempted.
  Plausibly reflects real biology too: flies steer fast/precise turns
  visually, not via odor — consistent with this app's *visual* steering
  (loom → DNa → turnBias) already working. `foodSeek`'s direction stays
  geometric; only urgency is brain-derived.

## Repo conventions

- Public repo: `DenisSergeevitch/desktop-fly` (master). Code MIT; `data/` is
  CC BY-NC 4.0 (FlyWire terms) — keep the license split intact.
- README numeric claims (neuron/edge/synapse counts, latencies) must match
  `data/*.json` and suite output — reviewers falsify them against the data.
- `.gitignore` covers the binary, logs, and root-level PNGs (diagnostics
  outputs); intentional images live in `assets/`.
- Local folder is `fly-brain`; the remote is `desktop-fly` — harmless.
