# Whole-brain roadmap

> **STATUS: the whole brain runs.** 139,255 neurons / 2,700,513 edges, stable,
> driving the fly's body. See "Results" below. Sections 1–4 are the analysis
> that got there and remain accurate; the workstream list records what is done
> and what is left.

## Results (achieved)

```
./DesktopFly --brainbench     # whole-brain harness: speed, stability, body coupling
./DesktopFly --fullbrain      # live desktop fly driven by all 139k neurons
python3 etl_fullbrain.py <raw_dir>   # rebuild data/fullbrain.bin (~24 MB, gitignored)
```

| | result |
|---|---|
| network | 139,255 neurons, 2,700,513 edges, mean out-degree 19.4 |
| load time | **0.04 s** (binary CSR; the JSON path extrapolated to ~11 s) |
| process RSS, live app | **84 MB** |
| step cost | **~3.0 ms wall per sim-ms** (single-threaded) |
| population rate | 5.00 Hz, min 4.99 / max 5.02 over 5 s — no seizure, no collapse |
| escape latency | **GF fires 4 ms after abrupt loom** — invariant holds at full scale |
| resting DN rates | DNa 9.4/4.2, DNp09 0.4, DNg11 2.3, MDN 1.8, escW 3.4 Hz |
| body coupling | 5/5 scenarios pass (GF→flight, DNg11→groom, DNp09→walk, MDN→backward, loom→takeoff) |
| both legacy suites | still pass (`--simtest`, `--behaviortest`) |

Two predictions from the analysis below were wrong in the good direction:
**3.0 ms/sim-ms rather than the predicted 4.7**, because the real connectome is
modular and spatially clustered where the synthetic benchmark was random — the
cache behaves better on real data. And the app renders at 13.6 fps in
whole-brain mode against **17–20 fps in stock 668-circuit mode**, i.e. the whole
brain costs ~25% of frame rate, not the collapse a 3 ms inline step implied —
because the sim was moved to its own thread (`SimRunner`).

Honest caveats:
- **Not 1 kHz realtime on this hardware.** At ~3.0 ms/sim-ms the brain runs at
  roughly 1/3 speed; `SimRunner` degrades gracefully (slow motion) rather than
  spiralling. Getting to true realtime still needs WS3's SIMD + MIMD, and
  probably Apple Silicon.
- **Homeostasis is a modeling choice, not connectome data.** Both the global
  gain and the per-population DN tuning are documented as such in `Sim.swift`.
  Without them the network does not sit at a usable operating point.


Goal: replace the curated 668-neuron circuit with the **full FlyWire v783
connectome** (139,255 neurons / 2,700,513 thresholded connections) as the
driver for the fly's behavior.

Everything below is measured on the actual code, not estimated. Reproduce with
`./DesktopFly --brainbench`. Measurements taken 2026-08-19 on an
Intel i7-1068NG7 (4 physical cores / 8 logical, 16 GB).

---

## 1. Correction to the original feasibility estimate

The first pass at this concluded "~10 GB RAM, 3.5 min load, not feasible."
**That was wrong by ~18×.** It extrapolated from 54.5M *synapses*, but the CSR
in `Sim.swift` stores *edges* — unique pre→post pairs, each carrying a
`syn_count` — and FlyWire v783 has 2,700,513 such pairs (the published
2,701,601 counts rows before de-duplicating across neuropils), not 54.5M. The current `data/circuit.json` confirms the ratio:
18,968 edges carrying 202,774 synapses (10.7 syn/edge).

Corrected, the project is **substantially more feasible than first stated**.
Memory is a non-issue. Compute is the real constraint, and it is a ~5× problem,
not a ~200× one.

## 2. Scale-up factors

| | current | full brain | factor |
|---|---|---|---|
| neurons | 668 | 139,255 | 208× |
| edges | 18,968 | 2,700,513 | 142× |
| avg out-degree | 28.4 | 19.4 | **0.68×** |

Note the last row: the curated circuit is *denser* than the brain average, so
per-spike fanout cost goes **down** at full scale. The original claim that the
full brain is "proportionally denser" was an artifact of the same 50M error.

## 3. Measured performance

Running the **real `LIFSim`** on a synthetic network with full-brain statistics
(random topology — a conservative bound, since the real connectome is modular
and spatially clustered, so cache behaviour should be *better*):

| configuration | wall ms per sim-ms | note |
|---|---|---|
| stock `Sim.swift` | **22.4** | as shipped |
| + xorshift RNG (1-line change) | **4.7** | 4.8× faster, popRate unchanged |
| + sparse inhibition delivery | 4.7 | **no gain — see below** |

Realtime 1 kHz requires ≤ 1.0 ms per sim-ms. Current gap: **~4.7×**.

### Phase breakdown at full scale (post-RNG-fix)

| phase | share | ms/sim-ms | parallelizable? |
|---|---|---|---|
| synapse fanout | 44.8% | 2.092 | by partition (MIMD) |
| leak + noise | 26.8% | 1.254 | trivially (SIMD + MIMD) |
| inhibition deliver | 12.5% | 0.586 | trivially |
| threshold scan | 9.3% | 0.432 | trivially |
| rate accounting | 6.6% | 0.308 | cheap fix (see WS1) |
| input injection | ~0% | 0.001 | — |

Two results worth recording because they contradict the obvious guess:

- **The per-neuron RNG was the single biggest cost**, not the network.
  `Float.random(in:using:)` against `SystemRandomNumberGenerator`
  (`Sim.swift:266`) is a CSPRNG call *per neuron per millisecond* — 139M
  calls/sec at full scale. Swapping in a xorshift gave 4.8× for one line, with
  identical population rates.
- **Making inhibition delivery sparse gained nothing.** The dense scan
  (`Sim.swift:286`) walks 139k contiguous floats = 557 KB, which is L2-resident
  and sequentially prefetched; replacing it with a dirty-index list traded
  sequential access for scattered access and came out even. Do not "optimize"
  this without re-measuring.

### Parallel scaling is the binding constraint

Measured on the dense per-neuron sweep, `DispatchQueue.concurrentPerform`:

| chunks | speedup |
|---|---|
| 2 | 1.27× |
| 4 | 1.77× |
| 6 | 1.93× |
| **8** | **2.11× (peak)** |
| 16 | 1.90× (regresses) |

It plateaus at ~2.1× and degrades past that — the sweep is
memory-bandwidth / dispatch-overhead bound, not compute bound, so the 4
physical cores do **not** deliver 4×.

**Therefore, on this machine:** 4.7 ms ÷ 2.1 ≈ **2.2 ms per sim-ms**, using
100% of all cores with nothing left for SceneKit. Full-brain 1 kHz realtime is
**not reachable on this 2020 Intel laptop** by threading alone. It needs SIMD
on the dense 48.6%, and realistically Apple Silicon (more P-cores, far higher
memory bandwidth). This should be settled early — see WS0.

## 4. Memory: a non-issue

| | measured / computed |
|---|---|
| full-scale process RSS (incl. source arrays held live) | **192 MB** |
| CSR steady state (2.7M × 8 B) | ~22 MB |
| per-neuron state (v, refr, baseline, pos, inhQueue) | ~10 MB |
| app baseline (Cocoa/SceneKit, measured via `--snapshot`) | 30–45 MB |
| **realistic steady state** | **~100 MB** |

The only memory concern is the **JSON load path**. Measured at 205 B/edge peak
and 4.15 µs/edge across two synthetic sizes (scaling was linear: 4× edges →
4.15× memory, 4.2× time), 2.7M edges extrapolates to **~554 MB peak / ~11 s**.
Survivable, but WS2 removes it.

---

## Workstreams

Status key: **[done]** shipped · **[partial]** started · **[todo]** not begun.

### WS0 — Benchmark harness first **[done]**
Shipped as `./DesktopFly --brainbench`: loads `fullbrain.bin`, reports speed
against the 1 kHz budget, checks the network is neither seizing nor silent,
and runs the body-coupling scenarios.
**Still worth doing: run it on an Apple Silicon machine.** The performance plan
branches on whether the 2.11× parallel ceiling is this laptop's memory
bandwidth or something structural.

### WS1 — Cheap wins **[done]**
1. **Xorshift RNG** — 4.8×, one line. Biggest single win available.
2. **`roles`/`types` as `UInt8` enums, not `String`** — the hot loop does a
   `switch` on `String` per spike (`Sim.swift:310`) plus `dnaL.contains(i)`
   linear search; 6.6% of step time, and it also cuts ~5 MB.
3. Hoist `activityScale`/`decay` multiplies out of the per-neuron loop.

Expect ~4.7 → ~4.0 ms before any architectural change.

### WS2 — Data pipeline **[done]**
- Extend `etl.py` with a whole-brain mode: keep all 139k neurons, all edges,
  drop the `MAX_PARTNERS = 330` selection. `NT_SIGN` already maps
  neurotransmitter → sign, so it carries over unchanged.
- **Replace JSON with a flat binary format** (header + neuron table + CSR
  arrays, `mmap`-able straight into `[Int32]`/`[Float]`). Kills the 554 MB /
  11 s load. Keep JSON for the 668-circuit so existing tests stay valid.
- Size check: binary CSR ≈ 22 MB + ~10 MB metadata. Committable, though Git LFS
  or a fetch script is cleaner. **`data/` stays CC BY-NC 4.0** — keep the
  license split and the Dorkenwald/Schlegel citations intact.

### WS3 — Sim core **[partial]** — off-thread done; SIMD + MIMD still todo
- Move the sim **off the SceneKit render thread**. `Coordinator.enqueue{}`
  already exists for cross-thread state, so the plumbing is there. Decouples
  sim rate from frame rate and is a prerequisite for everything else.
- **SIMD the dense phases** (48.6%) via Accelerate/vDSP — leak, threshold, and
  inhibition delivery are all elementwise over contiguous `[Float]`.
- **MIMD partitioning** by neuropil, `concurrentPerform` per tick, cross-
  partition spikes routed through the existing delayed ring buffer (it already
  defers by 4 ms, so it doubles as a lock-free mailbox — no new sync needed).
- **Hard constraint:** electrical/gap-junction pairs must stay *within* one
  partition. The LC4/LPLC2→GF ×6 coupling (`Sim.swift:223`) is explicitly
  instantaneous and wins a race against 4 ms-delayed inhibition; a partitioner
  that splits GF from its LC inputs silently adds latency and breaks the
  "GF fires ≤ ~10 ms after abrupt loom" invariant. Treat as affinity
  constraints, not min-cut weights.

### WS4 — Biological stability **[done, with caveats]**
This, not performance, is what most likely sinks the project.

The current tuning is razor-thin by design (CLAUDE.md: neurons rest at
`baseline × 20.4` against threshold 1.0) and was hand-fitted to 668 neurons
with mostly feedforward structure. At 139k neurons with real recurrence, the
likely outcomes are **runaway synchronous activity (seizure)** or **silence** —
and the parameters that fix one cause the other.

Note the synthetic benchmark's stable ~11 Hz says **nothing** about this:
random topology is self-averaging in a way real modular recurrent topology is
not. Stability must be validated on real data.

Work: per-population homeostatic gain control or E/I-balance normalization;
revisit `weightScale = 0.0008`; revisit `NT_SIGN`'s treatment of DA/SER/OCT as
+0.5 (modulators as weak excitation is a real simplification at whole-brain
scale). Budget research time here, not just engineering time.

### WS5 — Readout and inputs **[partial]**
Good news: **the readout layer largely survives.** Every mapped population
(DNp01, DNa01/02, DNp09, DNg11, MDN, DNp02/04/11) still exists in the full
brain, so `SignalBuilder` → `BrainSignals` → `FlyModel.brainBehavior` keeps
working — the rate EMAs just read from a much larger network. Normalization
constants will need refitting, and every field must stay clamped (CLAUDE.md:
an unclamped `walkDrive` once sent the fly to 1,100 pt/s).

Upside unlocked: the full brain includes real sensory populations
(photoreceptors, Johnston's organ), so `WindowSense` looms could drive actual
visual neurons instead of being injected into LC4/LPLC2 directly.

### WS6 — Tests **[partial]**
`--simtest` and `--behaviortest` are the ground truth and **must keep passing**
(or be consciously re-baselined with the reason recorded). Add:
- a **performance regression test** (ms/sim-ms at fixed n), and
- a **stability test** — no runaway, no silence, over minutes of sim time.
  This is the acceptance criterion for WS4.

---

## What is left

1. **Realtime (WS3).** ~3.0 ms/sim-ms needs to become ≤1.0. The dense phases
   (48.6% of step time) are elementwise over contiguous `[Float]` and should
   vectorise well with Accelerate; synapse fanout (44.8%) needs neuropil
   partitioning with the gap-junction affinity constraint intact. The measured
   parallel ceiling on this 4-core Intel is only 2.11×, so **running
   `--brainbench` on Apple Silicon is the highest-information next step** —
   more P-cores and far higher memory bandwidth may close most of the gap for
   free.
2. **Refit the readout (WS5).** `SignalBuilder`'s constants (`rateFwd / 10`,
   `rateMDN > 8`, …) were fitted to the 668-neuron circuit. They work at
   whole-brain scale only because the per-population homeostat deliberately
   targets comparable resting rates. Fitting them to the whole brain directly
   would let that homeostat be loosened or removed — worth doing, because right
   now a modeling choice is propping up a readout it shouldn't need to.
3. **Real sensory pathways (WS5).** The whole brain ships 16,938 sensory
   neurons. Looms are still injected straight into LC4/LPLC2; they could drive
   actual photoreceptor populations instead, which is the main scientific
   upside the whole brain unlocks.
4. **Stability under load (WS6).** Verified at rest and under single-population
   stimulation. Not yet verified under sustained multi-modal input, or over
   hours. Add both as regression tests.
5. **`BrainView` at 139k.** It renders the whole point cloud and was written
   for 668 neurons. It works, but click-to-stimulate does an O(n) scan per
   click and the role colouring has not been tuned for this density.
