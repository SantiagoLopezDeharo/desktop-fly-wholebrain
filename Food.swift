// Food.swift — draggable "food" desktop decals that give the fly a positive
// smell to walk toward. There's no real appetitive/olfactory circuit wired
// into this connectome subset (adding one is a new-neuron-population project
// of its own — see CLAUDE.md's recipe), so food position is fed straight to
// Fly.foodSeek (FlyModel.swift) as a direct behavioral pull rather than a
// stimulated neuron population — the same honesty tradeoff the README
// already makes for window-loom stimuli.

import Cocoa

private let FOOD_EMOJI = ["🍓", "🍯", "🍌", "🧁", "🍇", "🧀"]

// Small translucent "plate" behind a centered emoji. Drags via
// isMovableByWindowBackground on the owning panel; right-click removes it
// without waiting for a fly to find it.
private final class FoodPanelView: NSView {
    let emoji: String
    var onRemove: (() -> Void)?

    init(emoji: String) {
        self.emoji = emoji
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: 0.26).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()

        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20)]
        let size = emoji.size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 1)
        emoji.draw(at: origin, withAttributes: attrs)
    }

    override func rightMouseDown(with event: NSEvent) { onRemove?() }
    override var mouseDownCanMoveWindow: Bool { true }
}

final class FoodItem {
    let id: Int
    let panel: NSPanel

    init(id: Int, at screenPoint: NSPoint, onRemove: @escaping () -> Void) {
        self.id = id
        let size = NSSize(width: 34, height: 34)
        let origin = NSPoint(x: screenPoint.x - size.width / 2, y: screenPoint.y - size.height / 2)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = FoodPanelView(emoji: FOOD_EMOJI.randomElement()!)
        view.onRemove = onRemove
        panel.contentView = view
        panel.orderFrontRegardless()
    }

    // center of the panel's current on-screen position (it may have been dragged)
    var screenCenter: NSPoint { NSPoint(x: panel.frame.midX, y: panel.frame.midY) }

    func remove(animated: Bool = true) {
        guard animated else { panel.orderOut(nil); return }
        let p = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}
