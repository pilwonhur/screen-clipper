import AppKit
import ClipperCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = ClipController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        Notifier.shared.setup()
        installEditMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Screen Clipper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerHotKey()
        NotificationCenter.default.addObserver(forName: .hotKeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKey() }
        }

        Permissions.requestAll()
        if Prefs.webhookURL == nil { SettingsWindowController.shared.show() }
        controller.processQueue(force: true)
        Log.info("Screen Clipper started")
    }

    /// Menu-bar apps have no menu bar, which also disables ⌘C/⌘V/⌘A in text fields.
    /// A main menu with an Edit menu brings those shortcuts back (it is never shown).
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Screen Clipper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func registerHotKey() {
        let spec = Prefs.hotKey
        if !HotKeyCenter.shared.register(id: HotKeyID.capture, spec, handler: { [weak self] in self?.startCapture() }) {
            Log.error("Could not register shortcut \(spec.display) (in use by another app?)")
        }
    }

    @objc func startCapture() {
        Task { await controller.capture() }
    }

    // Rebuilt every time the menu opens, so the pending count is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let spec = Prefs.hotKey
        let capture = NSMenuItem(title: "Capture Region", action: #selector(startCapture), keyEquivalent: spec.menuKeyEquivalent)
        capture.keyEquivalentModifierMask = spec.menuModifiers
        capture.target = self
        capture.isEnabled = !controller.busy
        menu.addItem(capture)
        menu.addItem(.separator())

        let pending = controller.pendingClips
        if pending.isEmpty {
            menu.addItem(withTitle: "All clips posted", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            let item = menu.addItem(withTitle: "Waiting to post: \(pending.count)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            if let err = pending.last?.discord.lastError {
                menu.addItem(withTitle: "  Last error: \(err.prefix(60))", action: nil, keyEquivalent: "").isEnabled = false
            }
            add(menu, "Retry Now", #selector(retryNow))
        }
        menu.addItem(.separator())
        add(menu, "Open Clips Folder", #selector(openArchive))
        add(menu, "Settings…", #selector(openSettings), key: ",")
        add(menu, "Open Log", #selector(openLog))
        menu.addItem(.separator())
        add(menu, "Quit Screen Clipper", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func retryNow() { controller.processQueue(force: true) }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openArchive() {
        guard let root = Prefs.archiveRoot else { SettingsWindowController.shared.show(); return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
