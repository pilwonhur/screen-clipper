import AppKit

/// Small floating status panel near the capture region. Never activates the app, and is
/// excluded from screenshots.
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private var actions: [() -> Void] = []
    private var hideWork: DispatchWorkItem?
    private var timer: Timer?
    /// Region (Quartz) the panel stays next to.
    var anchor: CGRect?

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 60),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 320
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        p.contentView = fx
        return p
    }

    func show(_ text: String, buttons titles: [(String, () -> Void)] = []) {
        hideWork?.cancel()
        let p = panel ?? makePanel()
        panel = p
        label.stringValue = text
        for v in buttons.arrangedSubviews { buttons.removeArrangedSubview(v); v.removeFromSuperview() }
        actions = titles.map(\.1)
        for (i, t) in titles.enumerated() {
            let b = NSButton(title: t.0, target: self, action: #selector(tapped(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            if i == titles.count - 1 { b.keyEquivalent = "" }
            buttons.addArrangedSubview(b)
        }
        buttons.isHidden = titles.isEmpty
        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? CGSize(width: 300, height: 60)
        p.setContentSize(size)
        p.setFrameOrigin(origin(for: size))
        p.orderFrontRegardless()
    }

    func update(_ text: String) {
        label.stringValue = text
    }

    func hide(after seconds: TimeInterval = 0) {
        timer?.invalidate()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Shows a question; returns the index of the chosen button. With a timeout, the text is
    /// formatted with the seconds left ("%d") and `defaultIndex` is chosen when time runs out.
    func ask(_ text: String, buttons titles: [String], timeout: Int? = nil, defaultIndex: Int = 0) async -> Int {
        await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            var finished = false
            func done(_ i: Int) {
                guard !finished else { return }
                finished = true
                MainActor.assumeIsolated { self.timer?.invalidate() }
                cont.resume(returning: i)
            }
            var remaining = timeout ?? 0
            let render = { timeout == nil ? text : String(format: text, remaining) }
            show(render(), buttons: titles.enumerated().map { (i, t) in (t, { done(i) }) })
            if timeout != nil {
                if remaining <= 0 { done(defaultIndex); return }
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        remaining -= 1
                        if remaining <= 0 { done(defaultIndex) } else { self?.update(render()) }
                    }
                }
            }
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        guard sender.tag < actions.count else { return }
        actions[sender.tag]()
    }

    /// Above the region if there is room, else below it, else the top-right of the screen.
    private func origin(for size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first { s in anchor.map { s.frame.intersects(Geometry.toCocoa($0)) } ?? false }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        if let a = anchor.map(Geometry.toCocoa) {
            let x = min(max(vf.minX + 8, a.midX - size.width / 2), vf.maxX - size.width - 8)
            if a.maxY + 10 + size.height <= vf.maxY { return CGPoint(x: x, y: a.maxY + 10) }
            if a.minY - 10 - size.height >= vf.minY { return CGPoint(x: x, y: a.minY - 10 - size.height) }
        }
        return CGPoint(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 16)
    }
}
