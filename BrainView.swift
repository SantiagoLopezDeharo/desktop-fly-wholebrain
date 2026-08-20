// BrainView.swift — live visualization of the real FlyWire v783 brain:
// 23k real soma positions as a rotating point cloud, the escape circuit
// highlighted, and LIF spikes flashing at real neuron locations.

import Cocoa
import SceneKit
import simd

// `additive`: true glows (colors of overlapping points sum, no depth test) —
// right for sparse clouds and bright markers, but at whole-brain density the
// optic lobes alone (77,873 of 139,255 neurons) saturate straight to white
// and erase the exact structure it's meant to show. false gives normal
// depth-tested alpha blending instead, so dense regions occlude properly and
// read as an actual 3D shape.
private func pointCloud(positions: [SIMD3<Float>], colors: [SIMD4<Float>],
                        rMin: CGFloat, rMax: CGFloat, additive: Bool = true) -> SCNGeometry {
    let vData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
    let vSrc = SCNGeometrySource(data: vData, semantic: .vertex,
                                 vectorCount: positions.count, usesFloatComponents: true,
                                 componentsPerVector: 3, bytesPerComponent: 4,
                                 dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
    let cData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
    let cSrc = SCNGeometrySource(data: cData, semantic: .color,
                                 vectorCount: colors.count, usesFloatComponents: true,
                                 componentsPerVector: 4, bytesPerComponent: 4,
                                 dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
    let idx = Array(0..<UInt32(positions.count))
    let iData = idx.withUnsafeBufferPointer { Data(buffer: $0) }
    let elem = SCNGeometryElement(data: iData, primitiveType: .point,
                                  primitiveCount: positions.count, bytesPerIndex: 4)
    elem.pointSize = 0.05
    elem.minimumPointScreenSpaceRadius = rMin
    elem.maximumPointScreenSpaceRadius = rMax
    let g = SCNGeometry(sources: [vSrc, cSrc], elements: [elem])
    let m = SCNMaterial()
    m.lightingModel = .constant
    if additive {
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
    } else {
        m.blendMode = .alpha
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
    }
    g.materials = [m]
    return g
}

// super_class palette (index order from etl.py's 9-class list, used for the
// legacy 23k-point ambient cloud in circuit mode)
private let CLASS_COLORS: [SIMD4<Float>] = [
    SIMD4(0.16, 0.22, 0.34, 1),   // optic — dim blue (majority, keep subtle)
    SIMD4(0.45, 0.33, 0.16, 1),   // central — amber
    SIMD4(0.14, 0.36, 0.34, 1),   // sensory — teal
    SIMD4(0.10, 0.48, 0.62, 1),   // visual_projection — cyan
    SIMD4(0.38, 0.22, 0.55, 1),   // visual_centrifugal — violet
    SIMD4(0.62, 0.28, 0.10, 1),   // descending — orange
    SIMD4(0.20, 0.45, 0.18, 1),   // ascending — green
    SIMD4(0.55, 0.14, 0.14, 1),   // motor — red
    SIMD4(0.50, 0.25, 0.40, 1),   // endocrine — pink
]

// Same palette keyed by name (fullbrain.bin's 10-class list, one more entry
// than the legacy cloud above: sensory_ascending). Used to color the ~86% of
// whole-brain neurons that aren't in a named command population, so the
// point cloud reads as real anatomy (optic lobes, central brain, ...)
// instead of a flat gray mass.
private let SC_COLOR: [String: SIMD4<Float>] = [
    "optic": SIMD4(0.16, 0.22, 0.34, 1),
    "central": SIMD4(0.45, 0.33, 0.16, 1),
    "sensory": SIMD4(0.14, 0.36, 0.34, 1),
    "visual_projection": SIMD4(0.10, 0.48, 0.62, 1),
    "visual_centrifugal": SIMD4(0.38, 0.22, 0.55, 1),
    "descending": SIMD4(0.62, 0.28, 0.10, 1),
    "ascending": SIMD4(0.20, 0.45, 0.18, 1),
    "motor": SIMD4(0.55, 0.14, 0.14, 1),
    "endocrine": SIMD4(0.50, 0.25, 0.40, 1),
    "sensory_ascending": SIMD4(0.20, 0.40, 0.30, 1),
]

// Bright signature color for a named command/sensory population, or nil for
// unclassified ("other") neurons. Shared by the circuit-overlay pass and the
// whole-brain bulk pass so both modes use identical role colors.
private func roleColor(_ role: String) -> SIMD4<Float>? {
    switch role {
    case "lc4", "lplc2": return SIMD4(0.15, 0.85, 1.0, 1)
    case "dna01", "dna02": return SIMD4(1.0, 0.55, 0.10, 1)
    case "mdn": return SIMD4(1.0, 0.20, 0.80, 1)
    case "dnp09": return SIMD4(0.25, 1.0, 0.35, 1)
    case "dng11": return SIMD4(0.75, 0.55, 1.0, 1)
    case "escw": return SIMD4(1.0, 0.35, 0.25, 1)
    case "gf": return SIMD4(1.0, 0.95, 0.4, 1)
    case "food_orn": return SIMD4(0.85, 0.60, 0.10, 1)
    case "dnb01": return SIMD4(0.35, 0.80, 0.95, 1)
    case "dng12": return SIMD4(0.95, 0.45, 0.75, 1)
    default: return nil
    }
}

struct BrainScene {
    let scene: SCNScene
    let cameraNode: SCNNode
    let brainGroup: SCNNode
    let flashPool: [SCNNode]
}

func buildBrainScene(points: BrainPointsFile?, sim: LIFSim, wholeBrain: Bool) -> BrainScene {
    let scene = SCNScene()
    scene.background.contents = NSColor(calibratedRed: 0.03, green: 0.035, blue: 0.06, alpha: 1)

    let group = SCNNode()
    scene.rootNode.addChildNode(group)

    if wholeBrain {
        // Whole-brain mode: render every one of sim.n simulated neurons —
        // this IS the network actually running, not a separately-sampled
        // decoration. Earlier this used the old 668-circuit era's 23k-point
        // brain_points.json as ambient background, which is a different,
        // unrelated point set: the view looked "full" but wasn't showing the
        // brain that was actually computing. Named command populations get
        // their bright signature color; the ~86% "other" bulk is colored by
        // real super_class (sim.types) instead of flat gray, so anatomy
        // (optic lobes, central brain, ...) is visible.
        var pts: [SIMD3<Float>] = []
        var cols: [SIMD4<Float>] = []
        pts.reserveCapacity(sim.n)
        cols.reserveCapacity(sim.n)
        for i in 0..<sim.n {
            pts.append(sim.positions[i])
            cols.append(roleColor(sim.roles[i]) ?? SC_COLOR[sim.types[i]] ?? SIMD4(0.3, 0.3, 0.3, 1))
        }
        group.addChildNode(SCNNode(geometry: pointCloud(positions: pts, colors: cols,
                                                        rMin: 0.6, rMax: 1.5, additive: false)))

        // named populations get a second, brighter/bigger pass so they don't
        // get lost in 139k points (cheap: these lists are a few hundred long).
        // additive here is fine — these are a few hundred sparse markers.
        let named = sim.loomLeft + sim.loomRight + sim.gf + sim.dnaL + sim.dnaR
                  + sim.mdn + sim.fwd + sim.groom + sim.escw + sim.foodOrn
                  + sim.dnb01L + sim.dnb01R + sim.dng12
        if !named.isEmpty {
            var npts: [SIMD3<Float>] = []
            var ncols: [SIMD4<Float>] = []
            for i in named {
                npts.append(sim.positions[i])
                ncols.append(roleColor(sim.roles[i]) ?? SIMD4(0.8, 0.8, 0.8, 1))
            }
            group.addChildNode(SCNNode(geometry: pointCloud(positions: npts, colors: ncols, rMin: 1.8, rMax: 2.8)))
        }
    } else {
        // circuit mode: 23k-point real-soma ambient cloud + bright overlay
        // at the ~668 simulated neurons, unchanged from the original design
        guard let points = points else { fatalError("circuit mode needs brain_points.json") }
        var pts: [SIMD3<Float>] = []
        var cols: [SIMD4<Float>] = []
        pts.reserveCapacity(points.points.count)
        for p in points.points where p.count >= 4 {
            pts.append(SIMD3(p[0], p[1], p[2]))
            let ci = Int(p[3])
            cols.append(ci < CLASS_COLORS.count ? CLASS_COLORS[ci] : SIMD4(0.3, 0.3, 0.3, 1))
        }
        group.addChildNode(SCNNode(geometry: pointCloud(positions: pts, colors: cols, rMin: 0.7, rMax: 1.6)))

        var cpts: [SIMD3<Float>] = []
        var ccols: [SIMD4<Float>] = []
        for i in 0..<sim.n {
            cpts.append(sim.positions[i])
            ccols.append(roleColor(sim.roles[i]) ?? SIMD4(0.45, 0.45, 0.50, 1))
        }
        group.addChildNode(SCNNode(geometry: pointCloud(positions: cpts, colors: ccols, rMin: 1.6, rMax: 2.6)))
    }

    // the two giant fibers get actual glowing markers
    for i in 0..<sim.n where sim.roles[i] == "gf" {
        let s = SCNSphere(radius: 0.28)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        m.emission.contents = NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.25, alpha: 1)
        m.blendMode = .add
        s.materials = [m]
        let node = SCNNode(geometry: s)
        node.position = SCNVector3(CGFloat(sim.positions[i].x), CGFloat(sim.positions[i].y),
                                   CGFloat(sim.positions[i].z))
        node.opacity = 0.35
        group.addChildNode(node)
    }

    // spike flash pool
    var pool: [SCNNode] = []
    let flashGeo = SCNSphere(radius: 0.16)
    let fm = SCNMaterial()
    fm.lightingModel = .constant
    fm.diffuse.contents = NSColor.black
    fm.emission.contents = NSColor(calibratedRed: 0.75, green: 0.95, blue: 1.0, alpha: 1)
    fm.blendMode = .add
    flashGeo.materials = [fm]
    for _ in 0..<48 {
        let node = SCNNode(geometry: flashGeo)
        node.isHidden = true
        group.addChildNode(node)
        pool.append(node)
    }

    // slow rotation about the vertical axis
    group.runAction(.repeatForever(.rotateBy(x: 0, y: 0.35, z: 0, duration: 6)))
    group.eulerAngles = SCNVector3(-0.15, 0, 0)

    let camera = SCNCamera()
    camera.fieldOfView = 46
    camera.zNear = 1
    camera.zFar = 120
    let camNode = SCNNode()
    camNode.camera = camera
    camNode.position = SCNVector3(0, 0.6, 29)
    scene.rootNode.addChildNode(camNode)

    return BrainScene(scene: scene, cameraNode: camNode, brainGroup: group, flashPool: pool)
}

// Drains the spike bus inside the brain view's own render loop.
final class BrainRenderDriver: NSObject, SCNSceneRendererDelegate {
    let sim: LIFSim
    let flashPool: [SCNNode]
    private var next = 0

    init(sim: LIFSim, flashPool: [SCNNode]) {
        self.sim = sim
        self.flashPool = flashPool
    }

    func flash(neuron: Int, isGF: Bool) {
        guard neuron < sim.n, !flashPool.isEmpty else { return }
        let node = flashPool[next]
        next = (next + 1) % flashPool.count
        let p = sim.positions[neuron]
        node.position = SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z))
        node.isHidden = false
        node.removeAllActions()
        node.opacity = isGF ? 1.0 : 0.8
        node.scale = isGF ? SCNVector3(3.2, 3.2, 3.2) : SCNVector3(1, 1, 1)
        node.runAction(.sequence([.fadeOut(duration: isGF ? 0.6 : 0.28), .hide()]))
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let bus = sim.spikeBus else { return }
        for e in bus.popAll() { flash(neuron: e.neuron, isGF: e.isGF) }
    }
}

// SCNView that reports clicks, drag-to-orbit, scroll/pinch-to-zoom, and hover
// state without needing key focus. A mouseDown only becomes a "click" (stim)
// if the pointer never travels past a small threshold before mouseUp;
// anything past that is reported as a rotate drag instead, so orbiting the
// view and stimulating a region share the same button without conflict.
final class BrainSCNView: SCNView {
    var onClick: ((NSPoint) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onRotateDelta: ((CGFloat, CGFloat) -> Void)?   // (dx, dy) in points
    var onZoomDelta: ((CGFloat) -> Void)?              // +out / -in
    var onInteractionBegan: (() -> Void)?              // first real drag/zoom
    private var tracking: NSTrackingArea?
    private var dragStart: NSPoint = .zero
    private var lastDrag: NSPoint = .zero
    private var isDragging = false
    private let clickThreshold: CGFloat = 3

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        lastDrag = dragStart
        isDragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !isDragging {
            let moved = hypot(p.x - dragStart.x, p.y - dragStart.y)
            if moved < clickThreshold { return }
            isDragging = true
            onInteractionBegan?()
        }
        onRotateDelta?(p.x - lastDrag.x, p.y - lastDrag.y)
        lastDrag = p
    }
    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            onClick?(convert(event.locationInWindow, from: nil))
        }
        isDragging = false
    }
    override func scrollWheel(with event: NSEvent) {
        onInteractionBegan?()
        onZoomDelta?(-(event.scrollingDeltaY) * 0.06)
    }
    override func magnify(with event: NSEvent) {
        onInteractionBegan?()
        onZoomDelta?(-CGFloat(event.magnification) * 14)
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

final class BrainWindowController {
    let panel: NSPanel
    let driver: BrainRenderDriver
    private let sim: LIFSim
    private let brainGroup: SCNNode
    private let cameraNode: SCNNode
    private let view: BrainSCNView
    private let stimRing: SCNNode
    private let label = NSTextField(labelWithString: "")
    private var labelHider: DispatchWorkItem?

    // manual orbit/zoom state — see BrainSCNView's rotate/zoom callbacks
    private var yaw: Float = 0
    private var pitch: Float = -0.15
    private var distance: CGFloat = 29
    private let minDistance: CGFloat = 7
    private let maxDistance: CGFloat = 70
    private let maxPitch: Float = 1.4

    init(points: BrainPointsFile?, sim: LIFSim, wholeBrain: Bool, screen: NSScreen) {
        self.sim = sim
        let size = NSSize(width: 340, height: 280)
        let vis = screen.visibleFrame
        let origin = NSPoint(x: vis.maxX - size.width - 18, y: vis.minY + 18)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Fly Brain — FlyWire v783\(wholeBrain ? " · WHOLE BRAIN" : "")"
                    + " (click = stimulate, drag = rotate, scroll = zoom)"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces]

        let bs = buildBrainScene(points: points, sim: sim, wholeBrain: wholeBrain)
        brainGroup = bs.brainGroup
        cameraNode = bs.cameraNode
        driver = BrainRenderDriver(sim: sim, flashPool: bs.flashPool)

        // reusable stimulation ring
        let ringGeo = SCNSphere(radius: 2.2)
        let rm = SCNMaterial()
        rm.lightingModel = .constant
        rm.diffuse.contents = NSColor.black
        rm.emission.contents = NSColor(calibratedRed: 1.0, green: 0.9, blue: 0.5, alpha: 1)
        rm.blendMode = .add
        rm.transparency = 0.18
        rm.isDoubleSided = true
        ringGeo.materials = [rm]
        stimRing = SCNNode(geometry: ringGeo)
        stimRing.isHidden = true
        bs.brainGroup.addChildNode(stimRing)

        view = BrainSCNView(frame: NSRect(origin: .zero, size: size))
        view.scene = bs.scene
        view.pointOfView = bs.cameraNode
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30
        view.delegate = driver
        view.isPlaying = true
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        label.layer?.cornerRadius = 6
        label.isHidden = true
        view.addSubview(label)

        view.onHover = { [weak self] hovering in
            self?.brainGroup.isPaused = hovering   // hold the rotation while aiming
        }
        view.onClick = { [weak self] p in self?.handleClick(at: p) }

        // manual orbit: yaw/pitch straight into the group's Euler angles.
        // zoom: dolly the camera along its own local z, clamped so it never
        // crosses into the point cloud or drifts off into the void.
        view.onInteractionBegan = { [weak self] in
            self?.brainGroup.removeAllActions()   // ambient auto-spin yields to manual control, for good
        }
        view.onRotateDelta = { [weak self] dx, dy in
            guard let self = self else { return }
            self.yaw += Float(dx) * 0.010
            self.pitch = max(-self.maxPitch, min(self.maxPitch, self.pitch + Float(dy) * 0.010))
            self.brainGroup.eulerAngles = SCNVector3(self.pitch, self.yaw, 0)
        }
        view.onZoomDelta = { [weak self] d in
            guard let self = self else { return }
            self.distance = max(self.minDistance, min(self.maxDistance, self.distance + d))
            self.cameraNode.position.z = self.distance
        }
    }

    private func handleClick(at p: NSPoint) {
        let near = view.unprojectPoint(SCNVector3(p.x, p.y, 0))
        let far = view.unprojectPoint(SCNVector3(p.x, p.y, 1))
        let group = brainGroup.presentation
        let a = group.simdConvertPosition(SIMD3<Float>(Float(near.x), Float(near.y), Float(near.z)), from: nil)
        let b = group.simdConvertPosition(SIMD3<Float>(Float(far.x), Float(far.y), Float(far.z)), from: nil)
        let d = simd_normalize(b - a)

        // nearest circuit neuron to the click ray
        var best = -1
        var bestPerp = Float.greatestFiniteMagnitude
        for i in 0..<sim.n {
            let ap = sim.positions[i] - a
            let perp = simd_length(ap - simd_dot(ap, d) * d)
            if perp < bestPerp { bestPerp = perp; best = i }
        }
        guard best >= 0 else { return }
        let anchor = sim.positions[best]

        var picked = (0..<sim.n).filter { simd_distance(sim.positions[$0], anchor) < 2.2 }
        if picked.count < 4 {
            picked = (0..<sim.n).sorted {
                simd_distance(sim.positions[$0], anchor) < simd_distance(sim.positions[$1], anchor)
            }.prefix(6).map { $0 }
        } else if picked.count > 60 {
            picked = picked.sorted {
                simd_distance(sim.positions[$0], anchor) < simd_distance(sim.positions[$1], anchor)
            }.prefix(60).map { $0 }
        }

        sim.stimulate(picked, strength: 0.25, durationMs: 400)
        for i in picked.prefix(16) { driver.flash(neuron: i, isGF: false) }
        flashRing(at: anchor)
        showLabel(regionName(for: picked))
    }

    private func regionName(for picked: [Int]) -> String {
        var counts: [String: Int] = [:]
        for i in picked { counts[sim.roles[i], default: 0] += 1 }
        let major = counts.max { $0.value < $1.value }!.key
        let sideSuffix: (String) -> String = { role in
            let l = picked.filter { self.sim.roles[$0] == role && self.sim.positions[$0].x < 0 }.count
            let r = picked.filter { self.sim.roles[$0] == role }.count - l
            return l == r ? "" : (l > r ? " · left" : " · right")
        }
        switch major {
        case "lc4", "lplc2": return "⚡ Looming detectors (LC4/LPLC2)\(sideSuffix(major))"
        case "gf":           return "⚡ Giant Fiber (DNp01) — escape!"
        case "dna01", "dna02": return "⚡ Steering neurons (DNa01/02)\(sideSuffix(major))"
        case "dnp09":        return "⚡ Walking command (DNp09)"
        case "dng11":        return "⚡ Grooming command (DNg11)"
        case "escw":         return "⚡ Escape-wing DNs (DNp02/04/11)"
        case "mdn":          return "⚡ Moonwalker neurons (MDN)"
        case "food_orn":     return "🍯 Food-odor ORNs (DM1/DM4/VA2/VM3/DP1m)"
        case "dnb01":        return "🧭 Flight-steering command (DNb01) — real-time"
        case "dng12":        return "🫧 Head-sweep grooming (DNg12)"
        default:
            var t = sim.types[picked.first(where: { sim.roles[$0] == "other" }) ?? picked[0]]
            if t.isEmpty || t == "?" { t = "central" }
            return "⚡ \(t) neurons"
        }
    }

    private func flashRing(at pos: SIMD3<Float>) {
        stimRing.position = SCNVector3(CGFloat(pos.x), CGFloat(pos.y), CGFloat(pos.z))
        stimRing.removeAllActions()
        stimRing.isHidden = false
        stimRing.opacity = 1
        stimRing.scale = SCNVector3(0.5, 0.5, 0.5)
        stimRing.runAction(.group([.scale(to: 1.4, duration: 0.55),
                                   .sequence([.fadeOut(duration: 0.55), .hide()])]))
    }

    private func showLabel(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        let w = label.frame.width + 16
        label.frame = NSRect(x: (view.bounds.width - w) / 2, y: 10, width: w, height: label.frame.height + 6)
        label.isHidden = false
        labelHider?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.label.isHidden = true }
        labelHider = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    var isVisible: Bool { panel.isVisible }
    func show() { panel.orderFront(nil) }
    func hide() { panel.orderOut(nil) }

    func move(to screen: NSScreen) {
        let size = panel.frame.size
        let vis = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vis.maxX - size.width - 18, y: vis.minY + 18))
    }
}
