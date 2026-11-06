import CoreGraphics
import Foundation

/// Callbacks from a running capture. Called on an arbitrary thread.
public protocol CaptureSessionDelegate: AnyObject {
    func captureProgress(screens: Int, elapsed: TimeInterval)
    /// Limit reached: return true to keep going.
    func captureLimitReached(screens: Int, elapsed: TimeInterval) async -> Bool
}

/// Scrolls a region to the bottom, capturing and stitching as it goes, and writes pages to disk.
public final class CaptureSession {
    public struct Config {
        /// Region in global Quartz coordinates (points, origin top-left).
        public var rect: CGRect
        public var pagesDirectory: URL
        public var maxScreens = 300
        public var maxDuration: TimeInterval = 300
        /// Scroll step as a fraction of the viewport.
        public var stepFraction = 0.6
        public var settleTimeout: TimeInterval = 2.0
        /// Ignore this many points at the right edge when matching (overlay scrollbar).
        public var scrollbarStrip: CGFloat = 20
        /// Save every accepted raw frame (debugging).
        public var framesDirectory: URL?

        public init(rect: CGRect, pagesDirectory: URL) {
            self.rect = rect
            self.pagesDirectory = pagesDirectory
        }
    }

    public enum Outcome {
        /// Pages written in order. `scrolled` is false if the view never moved.
        case finished(pages: [URL], screens: Int, seams: Int, scrolled: Bool)
    }

    public let config: Config
    public weak var delegate: CaptureSessionDelegate?
    private var stopRequested = false
    private let lock = NSLock()

    public init(config: Config) {
        self.config = config
    }

    /// Ends the capture after the current step, keeping what was captured.
    public func stop() {
        lock.lock(); stopRequested = true; lock.unlock()
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }; return stopRequested
    }

    public func run() async throws -> Outcome {
        let rect = config.rect
        let grabber = try await ScreenGrabber(rect: rect)
        let scale = grabber.scale
        try FileManager.default.createDirectory(at: config.pagesDirectory, withIntermediateDirectories: true)
        if let fd = config.framesDirectory { try FileManager.default.createDirectory(at: fd, withIntermediateDirectories: true) }

        let originalCursor = Scroller.cursorPosition()
        defer { Scroller.moveCursor(to: originalCursor) }

        // Where to keep the cursor while scrolling. Right edge first (usually the scrollbar, which
        // does not trigger hover toolbars), then the center, then the left edge.
        let y = rect.midY
        var parkPoints = [CGPoint(x: rect.maxX - 8, y: y), CGPoint(x: rect.midX, y: y), CGPoint(x: rect.minX + 8, y: y)]
        var park = parkPoints.removeFirst()
        Scroller.moveCursor(to: park)
        try await Task.sleep(nanoseconds: 150_000_000)

        var first = try await settledGrab(grabber, previous: nil)
        var pages: [URL] = []
        var pageError: Error?
        let pagesDir = config.pagesDirectory
        let strip = Int(config.scrollbarStrip * scale)
        let assembler: StitchAssembler
        let paginator = Paginator(width: first.width, frameHeight: first.height, ignoreRight: strip) { page in
            let url = pagesDir.appendingPathComponent(String(format: "page-%03d.png", pages.count + 1))
            do { try ImageFiles.writePNG(page, to: url); pages.append(url) } catch { pageError = error }
        }
        assembler = StitchAssembler(sink: paginator, rightExclude: strip)
        assembler.begin(first)
        saveFrame(first, index: 0, shift: 0)

        let started = Date()
        var screens = 1
        var direction = 1
        var moved = false
        var noChange = 0
        var stepPoints = Double(rect.height) * config.stepFraction
        var ratio: Double? = nil          // measured pixels moved per requested pixel
        var screenLimit = config.maxScreens
        var timeLimit = config.maxDuration

        while !shouldStop {
            let elapsed = Date().timeIntervalSince(started)
            if screens >= screenLimit || elapsed >= timeLimit {
                let keepGoing = await delegate?.captureLimitReached(screens: screens, elapsed: elapsed) ?? false
                if !keepGoing { break }
                screenLimit += config.maxScreens
                timeLimit = elapsed + config.maxDuration
            }

            let requestedPixels = stepPoints * Double(scale)
            Scroller.moveCursor(to: park)
            Scroller.scroll(pixels: direction * Int(stepPoints.rounded()), at: park)
            let frame = try await settledGrab(grabber, previous: first)
            let sig = assembler.signatures(for: frame)

            if assembler.isUnchanged(sig) {
                if !moved {
                    // Nothing has ever scrolled: try the next cursor position before giving up.
                    if !parkPoints.isEmpty { park = parkPoints.removeFirst(); continue }
                    break
                }
                noChange += 1
                if noChange >= 2 { break }
                continue
            }
            noChange = 0

            let expected = ratio.map { Int(requestedPixels * $0) }
            var result = assembler.match(sig, expected: expected, allowNegative: !moved)

            if let r = result, r.confident, r.shift < 0 {
                // Scrolling went the wrong way: flip and try again from here.
                direction = -direction
                continue
            }

            var accepted = frame
            var acceptedSig = sig
            if result?.confident != true {
                // Probably scrolled too far: back up half a step and look again.
                Scroller.scroll(pixels: -direction * Int((stepPoints / 2).rounded()), at: park)
                let retry = try await settledGrab(grabber, previous: frame)
                let retrySig = assembler.signatures(for: retry)
                result = assembler.match(retrySig, expected: expected.map { $0 / 2 }, allowNegative: false)
                accepted = retry
                acceptedSig = retrySig
                stepPoints = max(40, stepPoints * 0.5)
            }

            if let r = result, r.confident, r.shift > 0 {
                assembler.accept(accepted, sig: acceptedSig, shift: r.shift)
                moved = true
                let measured = Double(r.shift) / max(1, requestedPixels)
                ratio = ratio.map { 0.5 * $0 + 0.5 * measured } ?? measured
                saveFrame(accepted, index: screens, shift: r.shift)
            } else {
                assembler.acceptWithSeam(accepted, sig: acceptedSig)
                moved = true
                saveFrame(accepted, index: screens, shift: -9999)
            }
            first = accepted
            screens += 1
            // Step = a fraction of the viewport we currently trust (bands excluded), in points.
            let viewportPoints = Double(assembler.viewportHeight) / Double(scale)
            let target = viewportPoints * config.stepFraction / (ratio ?? 1)
            stepPoints = min(target, stepPoints * 1.5)
            delegate?.captureProgress(screens: screens, elapsed: Date().timeIntervalSince(started))
        }

        assembler.finish()
        if let pageError { throw pageError }
        return .finished(pages: pages, screens: screens, seams: assembler.seams, scrolled: moved)
    }

    /// Captures until two consecutive screenshots match (scroll animation and fading
    /// scrollbars done), or the timeout passes.
    private func settledGrab(_ grabber: ScreenGrabber, previous: Frame?) async throws -> Frame {
        try await Task.sleep(nanoseconds: 120_000_000)
        var last = try await grabber.grab()
        let deadline = Date().addingTimeInterval(config.settleTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 90_000_000)
            let next = try await grabber.grab()
            if Self.nearlyEqual(last, next) { return next }
            last = next
        }
        return last
    }

    /// True if at most 1% of rows differ (tolerates a small animation).
    static func nearlyEqual(_ a: Frame, _ b: Frame) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let columns = 0..<a.width
        var differing = 0
        let allowed = max(1, a.height / 100)
        for y in 0..<a.height where !a.rowEquals(y, b, y, columns: columns) {
            differing += 1
            if differing > allowed { return false }
        }
        return true
    }

    private func saveFrame(_ frame: Frame, index: Int, shift: Int) {
        guard let dir = config.framesDirectory else { return }
        let url = dir.appendingPathComponent(String(format: "frame-%03d_shift%d.png", index, shift))
        try? ImageFiles.writePNG(frame, to: url)
    }
}
