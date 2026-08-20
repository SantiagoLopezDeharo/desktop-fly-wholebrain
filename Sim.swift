// Sim.swift — loads real FlyWire v783 data and runs a leaky-integrate-and-fire
// simulation of the escape/steering circuit (LC4/LPLC2 -> DNp01 giant fiber,
// DNa02 steering, MDN backward walking) with real signed synapse weights.

import Foundation
import simd

// What the brain tells the body each frame.
struct BrainSignals {
    var escape = false        // giant fiber spiked -> takeoff NOW
    var nervous: CGFloat = 0  // looming-detector population rate, 0..1
    var turnBias: CGFloat = 0 // rad/s steering from DNa01/DNa02 left-right rate difference
    var backward = false      // MDN burst -> backward walking
    var walkDrive: CGFloat = 0  // DNp09 forward-walking command rate, ~0..1.5
    var groomDrive: CGFloat = 0 // DNg11 grooming command rate, ~0..1.5
    var wingDrive: CGFloat = 0  // DNp02/04/11 escape-maneuver DN rate, ~0..1.3
    var arousal: CGFloat = 0    // whole-population activity, ~0..1
    var tempo: CGFloat = 1      // thermal "temperature" scaling of locomotion
    var sleep = false           // circadian + idle -> sleep-like state
    var foodAttraction: CGFloat = 0  // food-odor ORN population rate, 0..1 (whole-brain only)
    var hasFoodSense = false         // true only when the loaded brain has food_orn neurons
    var flightSteerBias: CGFloat = 0 // DNb01 L-R (baseline-adapted), -1..1, real mid-flight steering
    var headGroomDrive: CGFloat = 0  // DNg12 above its own baseline, 0..1, head-sweep emphasis
}

struct BrainPointsFile: Decodable {
    let classes: [String]
    let points: [[Float]]     // [x, y, z, classIndex]
}
struct CircuitNeuronFile: Decodable {
    let id: String
    let type: String
    let role: String          // lc4 | lplc2 | gf | dna02 | mdn | other
    let side: String          // left | right | center
    let pos: [Float]
}
struct CircuitFile: Decodable {
    let neurons: [CircuitNeuronFile]
    let edges: [[Float]]      // [preIdx, postIdx, signedSynCount]
}

func findDataDir() -> URL? {
    let fm = FileManager.default
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent()
    let candidates = [
        exeDir.appendingPathComponent("data"),
        URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("data"),
    ]
    return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("circuit.json").path) }
}

func loadBrainData() -> (points: BrainPointsFile, circuit: CircuitFile)? {
    guard let dir = findDataDir(),
          let pData = try? Data(contentsOf: dir.appendingPathComponent("brain_points.json")),
          let cData = try? Data(contentsOf: dir.appendingPathComponent("circuit.json")),
          let points = try? JSONDecoder().decode(BrainPointsFile.self, from: pData),
          let circuit = try? JSONDecoder().decode(CircuitFile.self, from: cData)
    else { return nil }
    return (points, circuit)
}

// Cheap deterministic PRNG. The stock SystemRandomNumberGenerator is a CSPRNG
// and was the single largest cost in the step loop at whole-brain scale (one
// call per neuron per millisecond = 139M calls/s); swapping it is a ~4.8x win
// with statistically identical population rates.
// SplitMix64. Chosen over plain xorshift64 because the noise test here is a
// `random < 0.0022` comparison that leans on low bits, which xorshift64 mixes
// weakly. (Two --behaviortest scenarios are inherently flaky at ~3/25 both
// before and after this change; don't read RNG regressions into them without
// a 25-run sample.)
struct Xorshift: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64 = 0x853c49e6748fea9b) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// Role ids. Numeric so the per-spike switch in step() is an integer compare
// instead of a String compare. Order MUST match ROLES in etl_fullbrain.py.
enum Role: UInt8 {
    case other = 0, lc4, lplc2, gf, dna01, dna02, dnp09, dng11, mdn, escw,
         ascending, sensory, foodOrn, dnb01, dng12
    init?(slug: String) {
        switch slug {
        case "other": self = .other
        case "lc4": self = .lc4
        case "lplc2": self = .lplc2
        case "gf": self = .gf
        case "dna01": self = .dna01
        case "dna02": self = .dna02
        case "dnp09": self = .dnp09
        case "dng11": self = .dng11
        case "mdn": self = .mdn
        case "escw": self = .escw
        case "ascending": self = .ascending
        case "sensory": self = .sensory
        case "food_orn": self = .foodOrn
        case "dnb01": self = .dnb01
        case "dng12": self = .dng12
        default: return nil
        }
    }
    var slug: String {
        switch self {
        case .other: return "other"
        case .lc4: return "lc4"
        case .lplc2: return "lplc2"
        case .gf: return "gf"
        case .dna01: return "dna01"
        case .dna02: return "dna02"
        case .dnp09: return "dnp09"
        case .dng11: return "dng11"
        case .mdn: return "mdn"
        case .escw: return "escw"
        case .ascending: return "ascending"
        case .sensory: return "sensory"
        case .foodOrn: return "food_orn"
        case .dnb01: return "dnb01"
        case .dng12: return "dng12"
        }
    }
}

// Whole-brain network read from data/fullbrain.bin (built by etl_fullbrain.py).
// Flat CSR, no parsing: the arrays are memcpy'd straight out of the file.
struct FullBrain {
    var n: Int
    var roleId: [UInt8]
    var side: [UInt8]            // 0 center, 1 left, 2 right
    var superClass: [UInt8]
    var positions: [SIMD3<Float>]
    var rowStart: [Int]
    var colIdx: [Int32]
    var syn: [Float]             // signed synapse counts, NOT yet weight-scaled
}

func loadFullBrain(_ url: URL? = nil) -> FullBrain? {
    let path: URL
    if let u = url { path = u }
    else if let dir = findDataDir() { path = dir.appendingPathComponent("fullbrain.bin") }
    else { return nil }
    guard let data = try? Data(contentsOf: path, options: .mappedIfSafe), data.count > 16
    else { return nil }

    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> FullBrain? in
        guard raw.load(fromByteOffset: 0, as: UInt32.self) == 0x42_59_4C_46 else { return nil } // "FLYB" LE
        let version = raw.load(fromByteOffset: 4, as: UInt32.self)
        guard version == 1 else { return nil }
        let n = Int(raw.load(fromByteOffset: 8, as: UInt32.self))
        let e = Int(raw.load(fromByteOffset: 12, as: UInt32.self))

        var off = 16
        var roleId = [UInt8](repeating: 0, count: n)
        var side = [UInt8](repeating: 0, count: n)
        var sclass = [UInt8](repeating: 0, count: n)
        var pos = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {                       // 16-byte records
            roleId[i] = raw.load(fromByteOffset: off, as: UInt8.self)
            side[i] = raw.load(fromByteOffset: off + 1, as: UInt8.self)
            sclass[i] = raw.load(fromByteOffset: off + 2, as: UInt8.self)
            pos[i] = SIMD3<Float>(raw.loadUnaligned(fromByteOffset: off + 4, as: Float.self),
                                  raw.loadUnaligned(fromByteOffset: off + 8, as: Float.self),
                                  raw.loadUnaligned(fromByteOffset: off + 12, as: Float.self))
            off += 16
        }
        var rowStart = [Int](repeating: 0, count: n + 1)
        for i in 0...n {
            rowStart[i] = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
            off += 4
        }
        var colIdx = [Int32](repeating: 0, count: e)
        for k in 0..<e {
            colIdx[k] = Int32(bitPattern: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
            off += 4
        }
        var syn = [Float](repeating: 0, count: e)
        for k in 0..<e {
            syn[k] = raw.loadUnaligned(fromByteOffset: off, as: Float.self)
            off += 4
        }
        return FullBrain(n: n, roleId: roleId, side: side, superClass: sclass,
                         positions: pos, rowStart: rowStart, colIdx: colIdx, syn: syn)
    }
}

// Thread-safe spike hand-off from the sim (fly render loop) to the brain window.
final class SpikeBus {
    private let lock = NSLock()
    private var events: [(neuron: Int, isGF: Bool)] = []
    func push(_ e: [(Int, Bool)]) {
        lock.lock()
        events.append(contentsOf: e)
        if events.count > 256 { events.removeFirst(events.count - 256) }
        lock.unlock()
    }
    func popAll() -> [(neuron: Int, isGF: Bool)] {
        lock.lock(); defer { lock.unlock() }
        let e = events; events.removeAll(); return e
    }
}

final class LIFSim {
    let n: Int
    let roles: [String]          // kept for BrainView / diagnostics
    let types: [String]
    let positions: [SIMD3<Float>]
    private var roleId: [UInt8]  // hot-path role lookup (integer compare)
    private var isDnaLeft: [Bool] // replaces dnaL.contains(i) linear search
    private var isDnb01Left: [Bool] = []

    // LIF state
    private var v: [Float]
    private var refr: [Float]
    private var baseline: [Float]        // per-neuron constant drive (heterogeneous excitability)

    // CSR adjacency, weights pre-scaled
    private var rowStart: [Int]
    private var colIdx: [Int32]
    private var w: [Float]

    // groups
    private(set) var loomLeft: [Int] = []
    private(set) var loomRight: [Int] = []
    private(set) var gf: [Int] = []
    private(set) var dnaL: [Int] = []      // DNa01 + DNa02, left
    private(set) var dnaR: [Int] = []      // DNa01 + DNa02, right
    private(set) var mdn: [Int] = []
    private(set) var fwd: [Int] = []       // DNp09
    private(set) var groom: [Int] = []     // DNg11
    private(set) var escw: [Int] = []      // DNp02/04/11 escape-maneuver (wing) DNs
    private(set) var ascend: [Int] = []    // ascending partners (leg proprioception)
    private(set) var sens: [Int] = []      // sensory partners (air-puff pathway)
    // Food-odor ORNs (DM1/DM4/VA2/VM3/DP1m glomeruli, real cell types
    // documented as attraction-driving). Whole-brain only: the 668-neuron
    // circuit never includes these, so this stays empty there and food
    // injection below is a harmless no-op for that mode.
    private(set) var foodOrn: [Int] = []
    // Flight-steering command neuron (real synaptic input only -- nothing
    // injects into it; whatever the whole brain naturally drives it with is
    // what steers flight). L/R split like dnaL/dnaR since steering needs the
    // bilateral difference.
    private(set) var dnb01L: [Int] = []
    private(set) var dnb01R: [Int] = []
    // Grooming subtype distinct from `groom` (DNg11): head sweeps vs
    // front-leg rubbing. Pooled, not L/R split -- magnitude only, like escw.
    private(set) var dng12: [Int] = []
    private var ascendPhase: [Float] = []  // per-ascending-neuron gait phase offset

    // inputs (0..1), set each frame by the coordinator
    var loomL: Float = 0
    var loomR: Float = 0
    var gaitDrive: Float = 0   // body walking intensity -> ascending neurons
    var gaitPhase: Float = 0   // body gait phase 0..1 -> rhythmic proprioception
    var airPuff: Float = 0     // fast cursor motion near the fly -> sensory neurons
    var foodDrive: Float = 0   // nearby food -> food-odor ORNs (proximity, 0..1)
    var activityScale: Float = 1  // circadian / sleep neuromodulation of baseline+noise
    var sensoryGate: Float = 1    // sleep gates sensory input (raised arousal threshold)

    // outputs
    private(set) var rateLoom: Float = 0   // Hz per LC neuron (EMA)
    private(set) var rateDNaL: Float = 0
    private(set) var rateDNaR: Float = 0
    private(set) var rateMDN: Float = 0
    private(set) var rateFwd: Float = 0
    private(set) var rateGroom: Float = 0
    private(set) var rateEscW: Float = 0
    private(set) var rateFoodOrn: Float = 0
    private(set) var rateDNb01L: Float = 0
    private(set) var rateDNb01R: Float = 0
    private(set) var rateDNg12: Float = 0
    private(set) var ratePop: Float = 0    // whole-population Hz per neuron
    private var gfLatch = false
    private(set) var simMs: Int = 0
    private(set) var totalSpikes: Int = 0

    // GABA/Glut synapses deliver with a few ms delay; the LC->GF electrical
    // coupling is instantaneous. This latency window is what lets the giant
    // fiber fire before feedforward inhibition arrives.
    private let inhDelayMs = 4
    private var inhQueue: [[Float]]
    private var qHead = 0

    // params
    private let decay: Float = 0.9512     // exp(-1/20): 20 ms membrane tau, 1 ms step
    private let threshold: Float = 1.0
    private let refractoryMs: Float = 2
    private let weightScale: Float = 0.0008
    private let pNoise: Float = 0.0022
    private let noiseKick: Float = 0.42
    private let loomGain: Float = 0.30
    private let foodOrnGain: Float = 0.34
    private let rateAlpha: Float = 1.0 / 120.0
    private var burstUntil = 0            // occasional "arousal" noise bursts
    private var burstNext = 12_000

    // Homeostatic gain control (whole-brain only; identity for the 668 circuit).
    // The hand-tuned 668-neuron operating point does not survive 208x more
    // neurons and real recurrence — without this the network either seizes or
    // goes silent. Slowly scales baseline drive to hold a target population
    // rate, which is a modeling choice, not connectome data.
    private(set) var homeostasis = false
    private(set) var homeoGain: Float = 1
    var homeoTargetHz: Float = 5.0
    private let homeoRate: Float = 0.0006

    // Per-population intrinsic-excitability homeostasis. The command DNs have
    // wildly different in-degree at whole-brain scale (DNg11 2.7k synapses vs
    // DNa02 23.8k), so no single baseline suits them all: too high and every
    // command latches on, too low and they never reach threshold. This nudges
    // each population's baseline toward a target resting rate, slowly enough
    // (~8 s) that stimulus-driven modulation still passes through unattenuated.
    private var popTuned = false

    let spikeBus: SpikeBus?
    private var rng = Xorshift()

    // "optogenetic" stimulation from brain-window clicks (any thread)
    private struct Stim { let idx: [Int]; let strength: Float; let durationMs: Int; var untilMs = 0 }
    private var pendingStims: [Stim] = []
    private var activeStims: [Stim] = []
    private let stimLock = NSLock()

    func stimulate(_ indices: [Int], strength: Float, durationMs: Int) {
        guard !indices.isEmpty else { return }
        stimLock.lock()
        pendingStims.append(Stim(idx: indices, strength: strength, durationMs: durationMs))
        if pendingStims.count > 8 { pendingStims.removeFirst() }
        stimLock.unlock()
    }

    init(circuit: CircuitFile, spikeBus: SpikeBus?) {
        self.spikeBus = spikeBus
        n = circuit.neurons.count
        roles = circuit.neurons.map { $0.role }
        types = circuit.neurons.map { $0.type }
        positions = circuit.neurons.map {
            SIMD3<Float>($0.pos.count == 3 ? $0.pos[0] : 0,
                         $0.pos.count == 3 ? $0.pos[1] : 0,
                         $0.pos.count == 3 ? $0.pos[2] : 0)
        }
        roleId = circuit.neurons.map { (Role(slug: $0.role) ?? .other).rawValue }
        isDnaLeft = [Bool](repeating: false, count: n)
        v = [Float](repeating: 0, count: n)
        refr = [Float](repeating: 0, count: n)
        inhQueue = Array(repeating: [Float](repeating: 0, count: n), count: 5)

        for (i, nr) in circuit.neurons.enumerated() {
            switch nr.role {
            case "lc4", "lplc2":
                if nr.side == "left" { loomLeft.append(i) } else { loomRight.append(i) }
            case "gf": gf.append(i)
            case "dna01", "dna02":
                if nr.side == "left" { dnaL.append(i) } else { dnaR.append(i) }
            case "mdn": mdn.append(i)
            case "dnp09": fwd.append(i)
            case "dng11": groom.append(i)
            case "escw": escw.append(i)
            case "other":
                // partners keep their super_class as `type`
                if nr.type == "ascending" { ascend.append(i) }
                else if nr.type == "sensory" { sens.append(i) }
            default: break
            }
        }
        for i in dnaL { isDnaLeft[i] = true }
        ascendPhase = ascend.map { _ in Float.random(in: 0...(2 * Float.pi)) }

        // Heterogeneous baseline drive: interneurons get enough to crackle at a
        // few Hz; sensory and command neurons stay quiet unless driven.
        var base = [Float](repeating: 0, count: n)
        for i in 0..<n {
            switch circuit.neurons[i].role {
            case "other": base[i] = Float.random(in: 0.010...0.070)
            case "lc4", "lplc2": base[i] = 0.004
            // command DNs get deterministic, side-symmetric baselines: their
            // asymmetries and bursts must come from network dynamics, not luck
            case "dna01", "dna02", "mdn", "dng11", "escw": base[i] = 0.036
            case "dnp09": base[i] = 0.038
            default: base[i] = 0.002        // gf: quiet unless synaptically driven
            }
        }
        baseline = base

        // CSR
        var counts = [Int](repeating: 0, count: n)
        for e in circuit.edges { counts[Int(e[0])] += 1 }
        rowStart = [Int](repeating: 0, count: n + 1)
        for i in 0..<n { rowStart[i + 1] = rowStart[i] + counts[i] }
        colIdx = [Int32](repeating: 0, count: circuit.edges.count)
        w = [Float](repeating: 0, count: circuit.edges.count)
        // LC4/LPLC2 -> GF and the wind pathway (JO sensory) -> GF couple via
        // electrical (gap-junction) synapses, which chemical synapse counts
        // under-represent; boost that drive.
        let gapJunctionBoost: Float = 6.0
        var fill = rowStart
        for e in circuit.edges {
            let pre = Int(e[0]), post = Int(e[1])
            var weight = e[2] * weightScale
            let electrical = roles[pre] == "lc4" || roles[pre] == "lplc2"
                || (roles[pre] == "other" && types[pre] == "sensory")
            if electrical && roles[post] == "gf" {
                weight *= gapJunctionBoost
            }
            colIdx[fill[pre]] = Int32(post)
            w[fill[pre]] = weight
            fill[pre] += 1
        }
    }

    // Whole-brain init: 139k neurons / 2.7M edges straight from fullbrain.bin.
    // Homeostasis is ON here by default — see the `homeostasis` note above.
    init(fullBrain fb: FullBrain, spikeBus: SpikeBus?) {
        self.spikeBus = spikeBus
        n = fb.n
        roleId = fb.roleId
        positions = fb.positions
        let scNames = ["optic", "central", "sensory", "visual_projection",
                       "visual_centrifugal", "descending", "ascending", "motor",
                       "endocrine", "sensory_ascending"]
        roles = fb.roleId.map { (Role(rawValue: $0) ?? .other).slug }
        types = fb.superClass.map { scNames[Int($0) < scNames.count ? Int($0) : 1] }
        isDnaLeft = [Bool](repeating: false, count: n)
        isDnb01Left = [Bool](repeating: false, count: n)
        v = [Float](repeating: 0, count: n)
        refr = [Float](repeating: 0, count: n)
        inhQueue = Array(repeating: [Float](repeating: 0, count: n), count: 5)
        homeostasis = true

        for i in 0..<n {
            let left = fb.side[i] == 1
            switch Role(rawValue: fb.roleId[i]) ?? .other {
            case .lc4, .lplc2: if left { loomLeft.append(i) } else { loomRight.append(i) }
            case .gf: gf.append(i)
            case .dna01, .dna02: if left { dnaL.append(i) } else { dnaR.append(i) }
            case .mdn: mdn.append(i)
            case .dnp09: fwd.append(i)
            case .dng11: groom.append(i)
            case .escw: escw.append(i)
            case .ascending: ascend.append(i)
            case .sensory: sens.append(i)
            case .foodOrn: foodOrn.append(i)
            case .dnb01: if left { dnb01L.append(i) } else { dnb01R.append(i) }
            case .dng12: dng12.append(i)
            case .other: break
            }
        }
        for i in dnaL { isDnaLeft[i] = true }
        for i in dnb01L { isDnb01Left[i] = true }
        var phaseRng = Xorshift(seed: 0x5DEECE66D)
        ascendPhase = ascend.map { _ in Float.random(in: 0...(2 * Float.pi), using: &phaseRng) }

        // Baselines run cooler than the 668-neuron circuit: with 2.7M real
        // edges most drive now arrives through the network, not the baseline,
        // and homeostasis trims the absolute level at runtime.
        var base = [Float](repeating: 0, count: n)
        var baseRng = Xorshift(seed: 0xDEADBEEF)
        for i in 0..<n {
            switch Role(rawValue: fb.roleId[i]) ?? .other {
            case .lc4, .lplc2: base[i] = 0.004
            case .gf: base[i] = 0.002
            // Command DNs get almost no intrinsic drive here. In the 668-neuron
            // circuit they needed baseline ~0.036 because the excerpt carried
            // almost no drive onto them (DNg11 had 6 synapses); the whole brain
            // delivers 2.7k-24k synapses each, so a baseline that size
            // double-counts and pins every command on permanently.
            case .dna01, .dna02, .mdn, .dng11, .escw, .dnp09, .dnb01, .dng12: base[i] = 0.004
            case .sensory, .foodOrn: base[i] = 0.006
            default: base[i] = Float.random(in: 0.008...0.042, using: &baseRng)
            }
        }
        baseline = base

        rowStart = fb.rowStart
        colIdx = fb.colIdx
        w = [Float](repeating: 0, count: fb.syn.count)
        let gapJunctionBoost: Float = 6.0
        for i in 0..<n {
            let r = Role(rawValue: fb.roleId[i]) ?? .other
            let electrical = (r == .lc4 || r == .lplc2 || r == .sensory)
            for k in fb.rowStart[i]..<fb.rowStart[i + 1] {
                var weight = fb.syn[k] * weightScale
                if electrical, Role(rawValue: fb.roleId[Int(fb.colIdx[k])]) == .gf {
                    weight *= gapJunctionBoost
                }
                w[k] = weight
            }
        }
    }

    // Slowly move a population's intrinsic drive toward `target` Hz.
    private func tunePop(_ idx: [Int], _ rate: Float, _ target: Float) {
        guard !idx.isEmpty else { return }
        let d = (target - rate) * 0.00004
        for i in idx { baseline[i] = min(0.060, max(0, baseline[i] + d)) }
    }

    func consumeGF() -> Bool {
        let s = gfLatch; gfLatch = false; return s
    }

    func step(_ ms: Int) {
        guard ms > 0 else { return }
        stimLock.lock()
        for var p in pendingStims {
            p.untilMs = simMs + p.durationMs
            activeStims.append(p)
        }
        pendingStims.removeAll()
        stimLock.unlock()
        activeStims.removeAll { simMs >= $0.untilMs }

        var spikedNow: [(Int, Bool)] = []
        for _ in 0..<ms {
            simMs += 1
            if simMs >= burstNext {
                burstUntil = simMs + 400
                burstNext = simMs + Int.random(in: 15_000...40_000, using: &rng)
            }
            let p = (simMs < burstUntil ? pNoise * 6 : pNoise) * activityScale

            let baseScale = activityScale * homeoGain   // homeoGain == 1 unless enabled
            for i in 0..<n {
                if refr[i] > 0 { refr[i] -= 1; v[i] *= decay; continue }
                var vi = v[i] * decay + baseline[i] * baseScale
                if Float.random(in: 0...1, using: &rng) < p { vi += noiseKick }
                v[i] = vi
            }
            if loomL > 0.001 { for i in loomLeft { v[i] += loomL * loomGain * sensoryGate } }
            if loomR > 0.001 { for i in loomRight { v[i] += loomR * loomGain * sensoryGate } }
            // body -> brain: gait rhythm into ascending (proprioceptive) neurons
            if gaitDrive > 0.001 {
                let ph = gaitPhase * 2 * Float.pi
                for (k, i) in ascend.enumerated() {
                    v[i] += gaitDrive * 0.09 * (0.5 + 0.5 * sin(ph + ascendPhase[k]))
                }
            }
            // fast air movement near the fly -> sensory pathway
            if airPuff > 0.001 { for i in sens { v[i] += airPuff * 0.12 * sensoryGate } }
            // nearby food -> food-odor ORNs (empty group outside whole-brain mode)
            if foodDrive > 0.001 { for i in foodOrn { v[i] += foodDrive * foodOrnGain * sensoryGate } }
            // brain-window click stimulation
            for s in activeStims where simMs < s.untilMs {
                for i in s.idx { v[i] += s.strength }
            }

            // deliver delayed inhibition scheduled for this millisecond
            for j in 0..<n where inhQueue[qHead][j] != 0 {
                v[j] = max(-2, v[j] + inhQueue[qHead][j])
                inhQueue[qHead][j] = 0
            }

            var spiked: [Int] = []
            for i in 0..<n where refr[i] <= 0 && v[i] >= threshold {
                v[i] = 0; refr[i] = refractoryMs
                spiked.append(i)
            }
            totalSpikes += spiked.count
            let inhSlot = (qHead + inhDelayMs) % inhQueue.count
            for i in spiked {
                for k in rowStart[i]..<rowStart[i + 1] {
                    let j = Int(colIdx[k])
                    if w[k] >= 0 { v[j] = max(-2, v[j] + w[k]) }
                    else { inhQueue[inhSlot][j] += w[k] }
                }
            }
            qHead = (qHead + 1) % inhQueue.count

            // group rates (Hz per neuron, EMA)
            var cLoom = 0, cDL = 0, cDR = 0, cM = 0, cF = 0, cG = 0, cW = 0, cFO = 0
            var cB01L = 0, cB01R = 0, cG12 = 0
            for i in spiked {
                switch Role(rawValue: roleId[i]) ?? .other {
                case .lc4, .lplc2: cLoom += 1
                case .dna01, .dna02: if isDnaLeft[i] { cDL += 1 } else { cDR += 1 }
                case .mdn: cM += 1
                case .dnp09: cF += 1
                case .dng11: cG += 1
                case .escw: cW += 1
                case .foodOrn: cFO += 1
                case .dnb01: if isDnb01Left[i] { cB01L += 1 } else { cB01R += 1 }
                case .dng12: cG12 += 1
                case .gf: gfLatch = true
                default: break
                }
            }
            let nLoom = Float(max(1, loomLeft.count + loomRight.count))
            rateLoom += (Float(cLoom) * 1000 / nLoom - rateLoom) * rateAlpha
            rateDNaL += (Float(cDL) * 1000 / Float(max(1, dnaL.count)) - rateDNaL) * rateAlpha
            rateDNaR += (Float(cDR) * 1000 / Float(max(1, dnaR.count)) - rateDNaR) * rateAlpha
            rateMDN  += (Float(cM)  * 1000 / Float(max(1, mdn.count))  - rateMDN)  * rateAlpha
            rateFwd  += (Float(cF)  * 1000 / Float(max(1, fwd.count))  - rateFwd)  * rateAlpha
            rateGroom += (Float(cG) * 1000 / Float(max(1, groom.count)) - rateGroom) * rateAlpha
            rateEscW += (Float(cW) * 1000 / Float(max(1, escw.count)) - rateEscW) * rateAlpha
            rateFoodOrn += (Float(cFO) * 1000 / Float(max(1, foodOrn.count)) - rateFoodOrn) * rateAlpha
            rateDNb01L += (Float(cB01L) * 1000 / Float(max(1, dnb01L.count)) - rateDNb01L) * rateAlpha
            rateDNb01R += (Float(cB01R) * 1000 / Float(max(1, dnb01R.count)) - rateDNb01R) * rateAlpha
            rateDNg12 += (Float(cG12) * 1000 / Float(max(1, dng12.count)) - rateDNg12) * rateAlpha
            ratePop  += (Float(spiked.count) * 1000 / Float(max(1, n)) - ratePop) * rateAlpha

            if homeostasis {
                homeoGain += (homeoTargetHz - ratePop) * homeoRate
                homeoGain = min(8, max(0.02, homeoGain))
                // command DNs: nudge intrinsic excitability toward resting
                // rates comparable to the 668-circuit operating point, so the
                // existing SignalBuilder thresholds stay meaningful
                if simMs % 50 == 0 {
                    tunePop(dnaL, rateDNaL, 4.0)
                    tunePop(dnaR, rateDNaR, 4.0)
                    tunePop(fwd, rateFwd, 4.0)
                    tunePop(groom, rateGroom, 3.0)
                    tunePop(mdn, rateMDN, 3.0)
                    tunePop(escw, rateEscW, 3.0)
                    tunePop(dnb01L, rateDNb01L, 4.0)
                    tunePop(dnb01R, rateDNb01R, 4.0)
                    tunePop(dng12, rateDNg12, 3.0)
                    popTuned = true
                }
            }

            if spikeBus != nil {
                let stride = max(1, spiked.count / 12)   // sample under heavy activity
                var i = 0
                while i < spiked.count {
                    spikedNow.append((spiked[i], roleId[spiked[i]] == Role.gf.rawValue))
                    i += stride
                }
            }
        }
        spikeBus?.push(spikedNow)
    }
}
