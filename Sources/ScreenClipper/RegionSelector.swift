import AppKit

/// Full-screen overlay to drag a capture region. Enter reuses the remembered region, Esc cancels.
/// Returns the region in Quartz coordinates.
@MainActor
final class RegionSelector {
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?

    static func select(remembered: CGRect?) async -> CGRect? {
        let selector = RegionSelector()
        return await withCheckedContinuation { cont in
            selector.continuation = cont
            selector.show(remembered: remembered)
        }
    }

    private func show(remembered: CGRect?) {
        let rememberedCocoa = remembered.map(Geometry.toCocoa)
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.screenOrigin = screen.frame.origin
            view.remembered = rememberedCocoa
            view.onDone = { [weak self] rect in self?.finish(rect) }
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
    }

    private func finish(_ cocoaRect: CGRect?) {
        NSCursor.pop()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        let result = cocoaRect.map(Geometry.toQuartz)
        continuation?.resume(returning: result)
        continuation = nil
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    var screenOrigin: CGPoint = .zero
    /// Remembered region, Cocoa global coordinates.
    var remembered: CGRect?
    var onDone: ((CGRect?) -> Void)?
    private var dragStart: CGPoint?
    private var dragRect: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    private func local(_ global: CGRect) -> CGRect { global.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.30).setFill()
        bounds.fill()
        if let r = dragRect {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.systemBlue.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)); p.lineWidth = 2; p.stroke()
            label("\(Int(r.width)) × \(Int(r.height)) pt", at: CGPoint(x: r.minX, y: r.maxY + 6))
        } else if let g = remembered {
            let r = local(g)
            if bounds.intersects(r) {
                NSColor.clear.setFill()
                r.fill(using: .copy)
                NSColor.systemYellow.setStroke()
                let p = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)); p.lineWidth = 2
                p.setLineDash([8, 5], count: 2, phase: 0); p.stroke()
                label("Enter = reuse this region", at: CGPoint(x: r.minX, y: r.maxY + 6))
            }
        }
        let hint = "Drag over the content to capture  ·  Enter = reuse last region  ·  Esc = cancel"
        label(hint, at: CGPoint(x: bounds.midX - 260, y: bounds.maxY - 80), size: 15)
    }

    private func label(_ s: String, at p: CGPoint, size: CGFloat = 13) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6),
        ]
        NSAttributedString(string: " \(s) ", attributes: attrs).draw(at: p)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragRect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let r = dragRect else { return }
        if r.width < 60 || r.height < 60 { dragRect = nil; needsDisplay = true; NSSound.beep(); return }
        onDone?(r.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y))
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: onDone?(nil)                                   // Esc
        case 36, 76: if let r = remembered { onDone?(r) } else { NSSound.beep() }   // Return / Enter
        default: super.keyDown(with: event)
        }
    }
}
