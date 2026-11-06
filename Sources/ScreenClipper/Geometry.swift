import AppKit

/// Converts between Cocoa screen coordinates (origin bottom-left of the main display, y up)
/// and Quartz coordinates (origin top-left of the main display, y down) used by
/// ScreenCaptureKit, CGEvent and the window list.
enum Geometry {
    static var mainHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    static func toQuartz(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// The app and window the user wants to capture (frontmost when the hotkey fired).
struct TargetInfo {
    var appName: String
    var bundleID: String?
    var pid: pid_t
    var windowTitle: String
    /// Window frame, Quartz coordinates.
    var windowBounds: CGRect?

    static func frontmost() -> TargetInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        var info = TargetInfo(appName: app.localizedName ?? "App", bundleID: app.bundleIdentifier,
                              pid: app.processIdentifier, windowTitle: "", windowBounds: nil)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                                       && ($0[kCGWindowLayer as String] as? Int) == 0 }) {
            info.windowTitle = (w[kCGWindowName as String] as? String) ?? ""
            if let b = w[kCGWindowBounds as String] as? NSDictionary { info.windowBounds = CGRect(dictionaryRepresentation: b) }
        }
        return info
    }

    var title: String {
        let t = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? appName : t
    }
}

/// Remembers the last region per app, relative to the app's window so it follows the window.
struct RegionMemory: Codable {
    struct Entry: Codable { var dx, dy, w, h: CGFloat; var absolute: CGRect }
    var entries: [String: Entry] = [:]

    func region(for target: TargetInfo) -> CGRect? {
        guard let key = target.bundleID, let e = entries[key] else { return nil }
        if let wb = target.windowBounds {
            return CGRect(x: wb.minX + e.dx, y: wb.minY + e.dy, width: e.w, height: e.h)
        }
        return e.absolute
    }

    mutating func remember(_ rect: CGRect, for target: TargetInfo) {
        guard let key = target.bundleID else { return }
        let wb = target.windowBounds ?? .zero
        entries[key] = Entry(dx: rect.minX - wb.minX, dy: rect.minY - wb.minY, w: rect.width, h: rect.height, absolute: rect)
    }
}
