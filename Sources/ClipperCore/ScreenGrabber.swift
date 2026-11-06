import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

public enum CaptureError: LocalizedError {
    case noDisplay
    case captureFailed
    case permissionMissing(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplay: return "The selected region is not on any display."
        case .captureFailed: return "Taking a screenshot failed."
        case .permissionMissing(let what): return "\(what) permission is missing."
        }
    }
}

/// Screenshots of one screen region (global Quartz coordinates, points, origin top-left).
/// Screen Clipper's own windows (HUD) are excluded from the capture.
public final class ScreenGrabber {
    public let rect: CGRect
    public let scale: CGFloat
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration

    public init(rect: CGRect) async throws {
        self.rect = rect
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) }) else {
            throw CaptureError.noDisplay
        }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let bounds = CGDisplayBounds(display.displayID)
        let local = CGRect(x: rect.minX - bounds.minX, y: rect.minY - bounds.minY, width: rect.width, height: rect.height)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        self.filter = filter
        self.config = config
        self.scale = scale
    }

    public func grab() async throws -> Frame {
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let frame = Frame(cgImage: image) else { throw CaptureError.captureFailed }
        return frame
    }
}

/// Synthetic scrolling and cursor placement.
public enum Scroller {
    /// Posts one pixel-unit scroll-wheel event at `point` (global Quartz coordinates).
    /// Positive `pixels` = toward the end of the document (content moves up), when `direction` is 1.
    public static func scroll(pixels: Int, at point: CGPoint) {
        let amount = Int32(clamping: -pixels)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: amount, wheel2: 0, wheel3: 0) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    public static func moveCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
    }

    /// Current cursor position in global Quartz coordinates.
    public static func cursorPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
