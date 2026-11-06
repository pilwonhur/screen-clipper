import Foundation

/// Receives the stitched output, row by row.
public protocol RowSink: AnyObject {
    func append(frame: Frame, rows: Range<Int>)
    /// A visible "possible gap here" marker (used when two frames could not be matched).
    func appendSeamMarker(width: Int)
    func finish()
}

/// Joins consecutive, overlapping frames into one continuous image.
///
/// Model: each frame shows a fixed header band (`hTop` rows), a scrolling viewport, and a
/// fixed footer band (`hBot` rows: input box, floating "jump to latest" buttons...).
/// Bands are detected automatically and only ever grow. Over-estimating a band is safe
/// (the content just arrives in a later frame); under-estimating would repeat fixed UI.
///
/// Output = first frame down to its footer, then for every new frame only the rows that
/// are new, then the rest of the last frame (including its footer) at the end.
public final class StitchAssembler {
    public let sink: RowSink
    /// Right-edge columns ignored when matching (overlay scrollbar).
    public let rightExclude: Int
    public static let signatureBlocks = 64

    public private(set) var hTop = 0
    public private(set) var hBot = 0
    public private(set) var seams = 0
    public private(set) var framesAccepted = 0
    public private(set) var started = false
    public private(set) var prev: Frame?
    public private(set) var prevSig: RowSignatures?
    /// Blocks that belong to a non-scrolling side column (excluded from matching).
    public private(set) var staticBlocks: Set<Int> = []
    /// Output so far ends at this row of `prev`.
    private var prevCut = 0

    public var height: Int { prev?.height ?? 0 }
    /// Rows of the current frame that are content (not footer).
    public var cutLine: Int { height - hBot }
    /// Height of the scrolling viewport, in pixels.
    public var viewportHeight: Int { max(1, cutLine - hTop) }

    public init(sink: RowSink, rightExclude: Int) {
        self.sink = sink
        self.rightExclude = rightExclude
    }

    public func signatures(for f: Frame) -> RowSignatures {
        RowSignatures(frame: f, blocks: Self.signatureBlocks, excludeRight: rightExclude)
    }

    public func begin(_ first: Frame) {
        prev = first
        prevSig = signatures(for: first)
    }

    /// True if `sig` shows the same picture as the previous frame (nothing scrolled).
    public func isUnchanged(_ sig: RowSignatures) -> Bool {
        guard let p = prevSig else { return false }
        let active = activeBlocks(for: sig)
        var differing = 0
        for y in hTop..<max(hTop + 1, cutLine) where y < sig.height {
            if sig.rowDiffers(y, p, y, active: active) { differing += 1 }
        }
        return Double(differing) <= Double(max(1, cutLine - hTop)) * 0.01
    }

    /// Finds how far the content moved since the previous frame.
    public func match(_ sig: RowSignatures, expected: Int?, allowNegative: Bool) -> MatchResult? {
        guard let p = prevSig else { return nil }
        updateStaticBlocks(prev: p, cur: sig)
        if !started { preDetectBands(prev: p, cur: sig) }
        let H = sig.height
        let minEvidence = max(12, H / 25)
        let bottom = H - hBot
        let maxShift = bottom - hTop - minEvidence
        guard maxShift >= 1 else { return nil }
        let params = MatchParams(top: hTop, prevBottom: bottom, curBottom: bottom,
                                 minShift: allowNegative ? -maxShift : 1, maxShift: maxShift,
                                 expected: expected, minEvidence: minEvidence,
                                 activeBlocks: activeBlocks(for: sig))
        return ShiftMatcher.match(prev: p, cur: sig, params: params)
    }

    /// Adds the new rows of `f`, which moved `d` pixels relative to the previous frame.
    public func accept(_ f: Frame, sig: RowSignatures, shift d: Int) {
        guard let p = prev, let ps = prevSig else { begin(f); return }
        detectBands(prev: ps, cur: sig, d: d)
        if !started {
            sink.append(frame: p, rows: 0..<(p.height - hBot))
            prevCut = p.height - hBot
            started = true
        }
        let c = f.height - hBot
        let start = max(0, prevCut - d)
        if c > start {
            sink.append(frame: f, rows: start..<c)
            prevCut = c
        } else {
            prevCut = start
        }
        prev = f
        prevSig = sig
        framesAccepted += 1
    }

    /// Adds `f` after a visible gap marker, when it could not be matched.
    public func acceptWithSeam(_ f: Frame, sig: RowSignatures) {
        guard let p = prev else { begin(f); return }
        if !started {
            sink.append(frame: p, rows: 0..<(p.height - hBot))
            started = true
        }
        sink.appendSeamMarker(width: f.width)
        let c = f.height - hBot
        if c > hTop { sink.append(frame: f, rows: hTop..<c) }
        prevCut = c
        prev = f
        prevSig = sig
        seams += 1
        framesAccepted += 1
    }

    /// Adds the rest of the last frame (including the footer) and closes the output.
    public func finish() {
        if let p = prev {
            if !started {
                sink.append(frame: p, rows: 0..<p.height)
            } else if prevCut < p.height {
                sink.append(frame: p, rows: prevCut..<p.height)
            }
        }
        sink.finish()
    }

    // MARK: - Fixed bands

    private func activeBlocks(for sig: RowSignatures) -> [Int]? {
        staticBlocks.isEmpty ? nil : (0..<sig.blocks).filter { !staticBlocks.contains($0) }
    }

    /// A block column whose textured rows mostly stay put while the rest changes is a static
    /// side column (for example a sidebar included in the selection).
    private func updateStaticBlocks(prev p: RowSignatures, cur c: RowSignatures) {
        let H = c.height
        var newStatic = staticBlocks
        var changedColumns = 0
        var candidates: [Int] = []
        for b in 0..<c.blocks where !staticBlocks.contains(b) {
            var textured = 0, same = 0
            for y in 0..<H where c.grad(y, b) >= 2.0 {
                textured += 1
                if abs(c.mean(y, b) - p.mean(y, b)) <= 0.75 && abs(c.grad(y, b) - p.grad(y, b)) <= 0.75 { same += 1 }
            }
            if textured >= H / 8 {
                if Double(same) >= Double(textured) * 0.85 { candidates.append(b) } else { changedColumns += 1 }
            }
        }
        // Only meaningful when other columns did change, and never more than a third of the width.
        if changedColumns >= 4 && candidates.count + staticBlocks.count <= c.blocks / 3 {
            newStatic.formUnion(candidates)
        }
        staticBlocks = newStatic
    }

    /// Before the first match: rows identical at the same position at the very top and bottom
    /// of both frames are a fixed header/footer (title bar, input box). Without this the first
    /// match would have to see through them.
    private func preDetectBands(prev p: RowSignatures, cur c: RowSignatures) {
        let H = c.height
        let cap = Int(Double(H) * 0.45)
        let active = activeBlocks(for: c)
        var t = 0
        while t < cap && !c.rowDiffers(t, p, t, active: active) { t += 1 }
        var b = 0
        while b < cap && !c.rowDiffers(H - 1 - b, p, H - 1 - b, active: active) { b += 1 }
        // Nothing moved at all: leave the bands alone.
        if t >= cap && b >= cap { return }
        hTop = max(hTop, t)
        hBot = max(hBot, b)
    }

    private func detectBands(prev p: RowSignatures, cur c: RowSignatures, d: Int) {
        let H = c.height
        let B = c.blocks
        guard d > 0, H > 8 else { return }
        let active = activeBlocks(for: c)

        // 1. Textured blocks that stayed in place while the content moved, in vertical runs
        //    (floating buttons, icons, header titles, input box text).
        var fixedRow = [Bool](repeating: false, count: H)
        let tol: Float = 0.75
        for b in 0..<B where !staticBlocks.contains(b) {
            var run = 0, gap = 0, runStart = 0, lastFixed = 0
            func closeRun() {
                if run >= 6 { for y in runStart...lastFixed { fixedRow[y] = true } }
                run = 0; gap = 0
            }
            for y in 0..<H {
                var isFixed = false
                let m1 = c.mean(y, b), g1 = c.grad(y, b)
                if g1 >= 2.0 && abs(m1 - p.mean(y, b)) <= tol && abs(g1 - p.grad(y, b)) <= tol {
                    if y + d < H {
                        let explainedByMotion = abs(m1 - p.mean(y + d, b)) <= tol && abs(g1 - p.grad(y + d, b)) <= tol
                        isFixed = !explainedByMotion
                    } else {
                        isFixed = true
                    }
                }
                if isFixed {
                    if run == 0 { runStart = y }
                    run += 1; gap = 0; lastFixed = y
                } else if run > 0 {
                    gap += 1
                    if gap > 2 { closeRun() }
                }
            }
            closeRun()
        }

        func sameInPlace(_ y: Int) -> Bool { !c.rowDiffers(y, p, y, active: active) }
        let half = H / 2
        let cap = Int(Double(H) * 0.45)

        // Bands grow outward from the real edges only: fixed rows must connect to the header or
        // footer (with small gaps allowed), so a stray coincidence mid-screen can't create a band.
        // A margin covers untextured edges (rounded tops of buttons, border lines).
        let margin = max(4, H / 30)

        // 2. Footer band: identical rows at the very bottom, then fixed rows above it.
        var start = H
        while start - 1 > half && sameInPlace(start - 1) { start -= 1 }
        var gap = 0
        var y = start - 1
        while y > half {
            if fixedRow[y] || (gap == 0 && sameInPlace(y)) { start = y; gap = 0 }
            else { gap += 1; if gap > H / 12 { break } }
            y -= 1
        }
        if start < H { start = max(half, start - margin) }
        hBot = max(hBot, min(H - start, cap))

        // 3. Header band, the same way from the top.
        var end = 0
        while end < half && sameInPlace(end) { end += 1 }
        gap = 0
        y = end
        while y < half {
            if fixedRow[y] || (gap == 0 && sameInPlace(y)) { end = y + 1; gap = 0 }
            else { gap += 1; if gap > H / 20 { break } }
            y += 1
        }
        if end > 0 { end = min(half, end + margin) }
        hTop = max(hTop, min(end, cap))
    }
}
