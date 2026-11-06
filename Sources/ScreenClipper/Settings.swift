import AppKit
import ClipperCore
import SwiftUI

/// Non-secret settings live in UserDefaults; secrets in the Keychain.
enum Prefs {
    static let d = UserDefaults.standard
    enum Key {
        static let autoSend = "autoSend", countdown = "countdownSeconds", summary = "summaryEnabled"
        static let archive = "archiveRoot", maxScreens = "maxScreens", maxMinutes = "maxMinutes"
        static let roleID = "secretaryRoleID", hotKey = "captureHotKey", regions = "regionMemory"
    }
    enum Secret { static let webhook = "discordWebhookURL", anthropic = "anthropicAPIKey" }

    static func registerDefaults() {
        d.register(defaults: [Key.autoSend: true, Key.countdown: 3, Key.summary: true,
                              Key.maxScreens: 300, Key.maxMinutes: 5, Key.roleID: ""])
        if d.string(forKey: Key.archive) == nil, let root = ObsidianArchiver.defaultRoot() {
            d.set(root.path, forKey: Key.archive)
        }
    }

    static var autoSend: Bool { d.bool(forKey: Key.autoSend) }
    static var countdown: Int { d.integer(forKey: Key.countdown) }
    static var summaryEnabled: Bool { d.bool(forKey: Key.summary) }
    static var maxScreens: Int { max(10, d.integer(forKey: Key.maxScreens)) }
    static var maxMinutes: Int { max(1, d.integer(forKey: Key.maxMinutes)) }
    static var roleID: String? {
        let s = (d.string(forKey: Key.roleID) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
    static var archiveRoot: URL? {
        guard let p = d.string(forKey: Key.archive), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }
    static var webhookURL: URL? {
        guard let s = Keychain.get(Secret.webhook), DiscordWebhook.isValidURL(s) else { return nil }
        return URL(string: s.trimmingCharacters(in: .whitespaces))
    }
    static var anthropicKey: String? {
        let k = Keychain.get(Secret.anthropic)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (k?.isEmpty ?? true) ? nil : k
    }
    static var hotKey: HotKeySpec {
        get { d.data(forKey: Key.hotKey).flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) } ?? .defaultCapture }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: Key.hotKey) }
    }
    static var regions: RegionMemory {
        get { d.data(forKey: Key.regions).flatMap { try? JSONDecoder().decode(RegionMemory.self, from: $0) } ?? RegionMemory() }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: Key.regions) }
    }

    static var publisherSettings: ClipPublisher.Settings {
        .init(webhookURL: webhookURL, roleID: roleID, archiveRoot: archiveRoot)
    }
}

extension Notification.Name {
    static let hotKeyChanged = Notification.Name("ScreenClipperHotKeyChanged")
}

// MARK: - Settings window

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Screen Clipper Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.Key.autoSend) private var autoSend = true
    @AppStorage(Prefs.Key.countdown) private var countdown = 3
    @AppStorage(Prefs.Key.summary) private var summaryEnabled = true
    @AppStorage(Prefs.Key.archive) private var archivePath = ""
    @AppStorage(Prefs.Key.maxScreens) private var maxScreens = 300
    @AppStorage(Prefs.Key.maxMinutes) private var maxMinutes = 5
    @AppStorage(Prefs.Key.roleID) private var roleID = ""

    @State private var webhook = Keychain.get(Prefs.Secret.webhook) ?? ""
    @State private var apiKey = Keychain.get(Prefs.Secret.anthropic) ?? ""
    @State private var status = ""
    @State private var hotKey = Prefs.hotKey
    @State private var recording = false
    @State private var monitor: Any?
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    @State private var axOK = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section("Discord") {
                HStack {
                    SecureField("Webhook URL", text: $webhook, prompt: Text("https://discord.com/api/webhooks/…"))
                    Button("Paste") { webhook = clipboard(); saveSecrets() }
                }
                TextField("Secretary role ID", text: $roleID, prompt: Text("e.g. 1234567890 (for @mentions)"))
                HStack {
                    Button("Save") { saveSecrets() }
                    Button("Send test post") { Task { await testPost() } }
                    Text(status).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Section("AI summary") {
                Toggle("Add a brief AI summary to each clip", isOn: $summaryEnabled)
                HStack {
                    SecureField("Anthropic API key", text: $apiKey, prompt: Text("sk-ant-…"))
                    Button("Paste") { apiKey = clipboard(); saveSecrets() }
                }
                Text("Pages and OCR text are sent to the Claude API (claude-opus-5-5) to write the summary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sending") {
                Toggle("Send automatically after capture", isOn: $autoSend)
                Stepper("Cancel window: \(countdown) s", value: $countdown, in: 0...10)
            }
            Section("Obsidian archive") {
                HStack {
                    Text(archivePath.isEmpty ? "Not set" : archivePath).lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
                Button("Use default (open vault / 81 Screen Clips)") {
                    archivePath = ObsidianArchiver.defaultRoot()?.path ?? ""
                }
            }
            Section("Capture") {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    Button(recording ? "Press new shortcut…" : hotKey.display) { startRecording() }
                }
                Stepper("Check in after \(maxScreens) screens", value: $maxScreens, in: 50...3000, step: 50)
                Stepper("Check in after \(maxMinutes) min", value: $maxMinutes, in: 1...60)
            }
            Section("Permissions") {
                HStack {
                    Label("Screen Recording", systemImage: screenOK ? "checkmark.circle.fill" : "xmark.circle")
                    Spacer()
                    Button("Open Settings") { Permissions.openScreenRecording() }
                }
                HStack {
                    Label("Accessibility (for scrolling)", systemImage: axOK ? "checkmark.circle.fill" : "xmark.circle")
                    Spacer()
                    Button("Open Settings") { Permissions.openAccessibility() }
                }
                Button("Refresh") { screenOK = CGPreflightScreenCaptureAccess(); axOK = AXIsProcessTrusted() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .onDisappear { saveSecrets(); stopRecording() }
    }

    private func clipboard() -> String {
        (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveSecrets() {
        let w = webhook.trimmingCharacters(in: .whitespaces)
        if !w.isEmpty && !DiscordWebhook.isValidURL(w) { status = "That doesn't look like a Discord webhook URL."; return }
        Keychain.set(w, for: Prefs.Secret.webhook)
        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Prefs.Secret.anthropic)
        status = w.isEmpty ? "Saved." : "Saved. Webhook: …\(w.suffix(6))"
    }

    private func testPost() async {
        saveSecrets()
        guard let url = Prefs.webhookURL else { status = "Add a webhook URL first."; return }
        status = "Sending…"
        let hook = DiscordWebhook(url: url)
        let role = Prefs.roleID
        let text = (role.map { "<@&\($0)> " } ?? "") + "✅ Screen Clipper is connected."
        do {
            do {
                _ = try await hook.send(content: text, threadName: "Screen Clipper test", mentionRole: role)
            } catch DiscordError.http(400, let body) where body.lowercased().contains("thread") {
                _ = try await hook.send(content: text, mentionRole: role)
            }
            status = "Test post sent."
        } catch {
            status = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { archivePath = url.path }
    }

    private func startRecording() {
        stopRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }   // Esc cancels
            let spec = HotKeySpec(event: event)
            guard spec.hasModifier else { NSSound.beep(); return nil }
            hotKey = spec
            Prefs.hotKey = spec
            NotificationCenter.default.post(name: .hotKeyChanged, object: nil)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }
}

enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAll() {
        if !screenRecording { CGRequestScreenCaptureAccess() }
        if !accessibility {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
    }

    static func openScreenRecording() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    static func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
