import Foundation

/// Collects stitched rows and cuts them into screen-sized pages, cutting only on blank rows
/// (the gaps between messages) so no line of text is split. Only the current page is kept
/// in memory, so very long captures are fine.
public final class Paginator: RowSink {
    public let width: Int
    public let targetHeight: Int
    public let minHeight: Int
    public let maxHeight: Int
    /// Right-edge columns ignored when deciding whether a row is blank (scrollbar).
    public let ignoreRight: Int
    public private(set) var pagesEmitted = 0
    public private(set) var totalRows = 0

    private var buffer: [UInt8] = []
    private var ink: [Int] = []          // pixels that differ from the row's background, per row
    /// A row with at most this much ink counts as blank (allows a thin border line).
    private var blankInk: Int { max(2, width / 400) }
    private let emit: (Frame) throws -> Void
    public private(set) var lastError: Error?

    /// - Parameter frameHeight: height of one captured screen, in pixels.
    public init(width: Int, frameHeight: Int, ignoreRight: Int = 0, emit: @escaping (Frame) throws -> Void) {
        self.width = width
        let target = min(3000, max(800, Int(Double(frameHeight) * 1.2)))
        self.targetHeight = target
        self.minHeight = Int(Double(target) * 0.7)
        self.maxHeight = Int(Double(target) * 1.25)
        self.ignoreRight = ignoreRight
        self.emit = emit
    }

    public var bufferedRows: Int { ink.count }

    public func append(frame: Frame, rows: Range<Int>) {
        precondition(frame.width == width, "frame width changed")
        let bpr = frame.bytesPerRow
        frame.pixels.withUnsafeBufferPointer { px in
            for y in rows {
                buffer.append(contentsOf: px[(y * bpr)..<((y + 1) * bpr)])
                ink.append(Self.inkCount(px, rowStart: y * bpr, width: width, ignoreRight: ignoreRight))
            }
        }
        totalRows += rows.count
        while ink.count >= maxHeight { cutPage() }
    }

    public func appendSeamMarker(width w: Int) {
        // Red/white dashes, 8 rows.
        var px = [UInt8](repeating: 255, count: w * 4 * 8)
        for y in 2..<6 {
            for x in 0..<w where (x / 24) % 2 == 0 {
                let i = (y * w + x) * 4
                px[i] = 230; px[i + 1] = 40; px[i + 2] = 40; px[i + 3] = 255
            }
        }
        append(frame: Frame(width: w, height: 8, pixels: px), rows: 0..<8)
    }

    public func finish() {
        while ink.count >= maxHeight { cutPage() }
        if !ink.isEmpty { emitPage(rows: ink.count) }
    }

    // MARK: - Cutting

    private func cutPage() {
        emitPage(rows: chooseCut())
    }

    /// Picks a cut row: the middle of the blank run closest to the target height,
    /// or the least-inked row if there is no blank row.
    func chooseCut() -> Int {
        let lo = minHeight, hi = min(maxHeight, ink.count)
        guard lo < hi else { return hi }
        var bestCut = -1, bestDistance = Int.max
        var y = lo
        while y < hi {
            if ink[y] <= blankInk {
                let runStart = y
                while y < hi && ink[y] <= blankInk { y += 1 }
                let mid = (runStart + y) / 2
                let dist = abs(mid - targetHeight)
                if dist < bestDistance { bestDistance = dist; bestCut = mid }
            } else {
                y += 1
            }
        }
        if bestCut > 0 { return bestCut }
        var minInk = Int.max, minRow = hi
        for r in lo..<hi where ink[r] < minInk { minInk = ink[r]; minRow = r }
        return minRow
    }

    private func emitPage(rows n: Int) {
        let bpr = width * 4
        let page = Frame(width: width, height: n, pixels: Array(buffer[0..<(n * bpr)]))
        buffer.removeFirst(n * bpr)
        ink.removeFirst(n)
        do { try emit(page) } catch { lastError = error }
        pagesEmitted += 1
    }

    static func inkCount(_ px: UnsafeBufferPointer<UInt8>, rowStart: Int, width: Int, ignoreRight: Int) -> Int {
        let end = max(1, width - ignoreRight)
        // Background = the most common color among a few samples (robust to a border line at the edge).
        let samples = [end / 20, end / 4, end / 2, (end * 3) / 4, (end * 19) / 20].map { rowStart + min(end - 1, $0) * 4 }
        func close(_ a: Int, _ b: Int) -> Bool {
            abs(Int(px[a]) - Int(px[b])) <= 8 && abs(Int(px[a + 1]) - Int(px[b + 1])) <= 8 && abs(Int(px[a + 2]) - Int(px[b + 2])) <= 8
        }
        var ref = samples[0], bestVotes = -1
        for s in samples {
            let votes = samples.filter { close($0, s) }.count
            if votes > bestVotes { bestVotes = votes; ref = s }
        }
        let r0 = Int(px[ref]), g0 = Int(px[ref + 1]), b0 = Int(px[ref + 2])
        var count = 0
        var i = rowStart
        for _ in 0..<end {
            if abs(Int(px[i]) - r0) > 8 || abs(Int(px[i + 1]) - g0) > 8 || abs(Int(px[i + 2]) - b0) > 8 { count += 1 }
            i += 4
        }
        return count
    }
}
