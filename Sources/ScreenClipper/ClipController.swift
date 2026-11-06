import AppKit
import ClipperCore
import Network
import UserNotifications

/// Runs a capture from hotkey to Discord, and keeps retrying clips that could not be posted.
@MainActor
final class ClipController: CaptureSessionDelegate {
    let store = ClipStore()
    private(set) var busy = false
    private var session: CaptureSession?
    private var inFlight: Set<String> = []
    private var retryTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    var onQueueChange: (() -> Void)?

    init() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.processQueue() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.processQueue(force: true) }
        }
        pathMonitor.start(queue: .main)
    }

    var pendingClips: [ClipMeta] { store.allClips().filter { !$0.isComplete } }

    // MARK: - Capture

    func capture() async {
        guard !busy else { NSSound.beep(); return }
        guard Permissions.screenRecording && Permissions.accessibility else {
            Permissions.requestAll()
            alert("Screen Clipper needs permissions",
                  "Allow Screen Clipper under System Settings → Privacy & Security → Screen Recording and → Accessibility, then try again. (You may need to quit and reopen Screen Clipper after granting Screen Recording.)")
            return
        }
        busy = true
        defer { busy = false; session = nil; HotKeyCenter.shared.unregister(HotKeyID.escape) }

        guard let target = TargetInfo.frontmost() else { NSSound.beep(); return }
        var memory = Prefs.regions
        guard let rect = await RegionSelector.select(remembered: memory.region(for: target)) else { return }
        memory.remember(rect, for: target)
        Prefs.regions = memory
        NSRunningApplication(processIdentifier: target.pid)?.activate()
        try? await Task.sleep(nanoseconds: 250_000_000)

        let capturedAt = Date()
        let id = ClipMeta.newID(for: capturedAt)
        let hud = HUD.shared
        hud.anchor = rect
        var config = CaptureSession.Config(rect: rect, pagesDirectory: store.pagesDirectory(id))
        config.maxScreens = Prefs.maxScreens
        config.maxDuration = TimeInterval(Prefs.maxMinutes * 60)
        let session = CaptureSession(config: config)
        session.delegate = self
        self.session = session
        hud.show("Capturing… keep the mouse still. (Esc = stop)", buttons: [("Stop", { session.stop() })])
        HotKeyCenter.shared.register(id: HotKeyID.escape, HotKeySpec(keyCode: 53, modifiers: 0)) { session.stop() }
        Log.info("Capture started: \(target.appName) “\(target.title)” rect=\(rect)")

        let outcome: CaptureSession.Outcome
        do {
            outcome = try await session.run()
        } catch {
            Log.error("Capture failed: \(error)")
            hud.show("Capture failed: \(error.localizedDescription)")
            hud.hide(after: 5)
            store.delete(id)
            return
        }
        HotKeyCenter.shared.unregister(HotKeyID.escape)
        guard case let .finished(pages, screens, seams, scrolled) = outcome, !pages.isEmpty else {
            hud.show("Nothing was captured."); hud.hide(after: 3); store.delete(id); return
        }
        Log.info("Capture finished: \(screens) screens, \(pages.count) pages, \(seams) seams, scrolled=\(scrolled)")

        if !scrolled {
            let choice = await hud.ask("The view didn't scroll. If this isn't the bottom already, click inside the content once and try again.",
                                       buttons: ["Cancel", "Send this screen"])
            if choice == 0 { hud.hide(); store.delete(id); return }
        }

        // OCR.
        hud.show("Reading text… (\(pages.count) page\(pages.count == 1 ? "" : "s"))")
        let transcript = await OCR.transcript(pages: pages)
        try? transcript.write(to: store.transcriptURL(id), atomically: true, encoding: .utf8)

        var meta = ClipMeta(id: id, app: target.appName, bundleID: target.bundleID, window: target.windowTitle,
                            title: target.title, capturedAt: capturedAt, pageCount: pages.count, screens: screens,
                            seams: seams, sendToDiscord: Prefs.webhookURL != nil)

        // AI summary (best effort: never blocks delivery).
        if Prefs.summaryEnabled {
            if let key = Prefs.anthropicKey {
                hud.show("Writing a brief summary…")
                do {
                    let summarizer = ClaudeSummarizer(apiKey: key)
                    if let s = try await summarizer.summarize(transcript: transcript, pages: pages,
                                                             sourceApp: target.appName, title: target.title) {
                        meta.summary = s
                    } else {
                        meta.summaryNote = "unavailable"
                        Log.info("Summary declined by the model.")
                    }
                } catch {
                    meta.summaryNote = "unavailable"
                    Log.error("Summary failed: \(error.localizedDescription)")
                }
            } else {
                meta.summaryNote = "unavailable: no API key in Settings"
            }
        }

        // Send (with a short cancel window), or archive only.
        if meta.sendToDiscord {
            if Prefs.autoSend {
                let seconds = Prefs.countdown
                if seconds > 0 {
                    let choice = await hud.ask("Sending to Discord in %d s…", buttons: ["Cancel", "Send now"],
                                               timeout: seconds, defaultIndex: 1)
                    if choice == 0 { meta.sendToDiscord = false }
                }
            } else {
                let choice = await hud.ask("Send this clip to Discord?", buttons: ["Save only", "Send"])
                meta.sendToDiscord = choice == 1
            }
        }
        do { try store.save(meta) } catch { Log.error("Saving clip failed: \(error)") }
        hud.show(meta.sendToDiscord ? "Posting…" : "Saving to Obsidian…")
        hud.hide(after: 1.5)
        Task { await self.publish(id, announce: true) }
    }

    // MARK: - CaptureSessionDelegate

    nonisolated func captureProgress(screens: Int, elapsed: TimeInterval) {
        Task { @MainActor in
            HUD.shared.update("Capturing… \(screens) screens. Keep the mouse still. (Esc = stop)")
        }
    }

    nonisolated func captureLimitReached(screens: Int, elapsed: TimeInterval) async -> Bool {
        await MainActor.run { NSSound.beep() }
        let choice = await HUD.shared.ask("This capture is long (\(screens) screens, \(Int(elapsed / 60)) min). Stopping and sending in %d s…",
                                          buttons: ["Stop & send", "Continue"], timeout: 10, defaultIndex: 0)
        await MainActor.run {
            HUD.shared.show("Capturing… keep the mouse still. (Esc = stop)", buttons: [("Stop", { [weak self] in self?.session?.stop() })])
        }
        return choice == 1
    }

    // MARK: - Publishing and retries

    func publish(_ id: String, announce: Bool) async {
        guard !inFlight.contains(id), var meta = store.load(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id); onQueueChange?() }
        let publisher = ClipPublisher(store: store, settings: Prefs.publisherSettings)
        do {
            try await publisher.publish(&meta)
            Log.info("Clip \(id) published (discord=\(meta.discord.done), archive=\(meta.archive.done))")
            if meta.sendToDiscord {
                Notifier.post(title: "Posted to Discord", body: meta.title, url: meta.discord.link)
            } else if announce {
                Notifier.post(title: "Saved to Obsidian", body: meta.title, url: nil)
            }
            if meta.isComplete { store.delete(id) }
        } catch {
            Log.error("Publishing \(id) failed: \(error.localizedDescription)")
            if meta.discord.attempts == 1 || announce {
                Notifier.post(title: "Couldn't post yet — will retry", body: "\(meta.title): \(error.localizedDescription)", url: nil)
            }
        }
    }

    /// Posts clips whose retry time has come (or all pending ones when `force`).
    func processQueue(force: Bool = false) {
        guard !busy else { return }
        for meta in pendingClips where !inFlight.contains(meta.id) {
            if force || (meta.discord.nextAttempt ?? .distantPast) <= Date() {
                Task { await publish(meta.id, announce: false) }
            }
        }
        onQueueChange?()
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// macOS notifications; clicking one opens its Discord link.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, url: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let url { content.userInfo = ["url": url] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
