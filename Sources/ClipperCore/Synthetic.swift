import CoreGraphics
import CoreText
import Foundation

/// Deterministic random numbers for repeatable synthetic tests.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Draws a long fake chat (the "document") and renders what a chat window would show
/// at any scroll position: fixed header, scrolling messages, input box, a floating
/// "jump to latest" button and an overlay scrollbar. Used to test stitching end to end.
public final class SyntheticChat {
    public let width: Int
    public let document: Frame
    public let screenHeight: Int
    public let headerHeight: Int
    public let footerHeight: Int
    public var viewportHeight: Int { screenHeight - headerHeight - footerHeight }
    public var maxScroll: Int { document.height - viewportHeight }
    public var showsFloatingButton = true

    static let samples = [
        "안녕하세요, 내일 회의 일정 확인 부탁드립니다.",
        "Can we move the review to Thursday 3pm?",
        "네 알겠습니다. 자료는 오늘 저녁까지 보내드릴게요.",
        "프로젝트 A 킥오프는 11/12 10시로 확정되었습니다.",
        "I'll send the draft by Friday. 초안 먼저 공유드려요.",
        "장소는 본사 3층 회의실입니다.",
        "ㅋㅋㅋ 좋아요",
        "Budget sheet v3 attached — please check row 42.",
        "출장 일정: 11/18–11/20 부산, 숙소 예약 필요",
        "OK 👍",
        "다음 주 화요일까지 발표자료 초안 부탁드려요.",
        "Thanks! Talk soon.",
    ]

    public init(width: Int = 1200, documentHeight: Int = 9000, screenHeight: Int = 1400,
                headerHeight: Int = 110, footerHeight: Int = 150, seed: UInt64 = 1) {
        self.width = width
        self.screenHeight = screenHeight
        self.headerHeight = headerHeight
        self.footerHeight = footerHeight
        self.document = SyntheticChat.drawDocument(width: width, height: documentHeight, seed: seed)
    }

    /// What the screen shows when the document is scrolled to `offset`.
    public func screen(at offset: Int) -> Frame {
        let s = max(0, min(offset, maxScroll))
        let W = width, H = screenHeight, bpr = W * 4
        var px = [UInt8](repeating: 255, count: H * bpr)
        // Scrolling content.
        let docStart = s * bpr
        let count = viewportHeight * bpr
        px.replaceSubrange((headerHeight * bpr)..<(headerHeight * bpr + count),
                           with: document.pixels[docStart..<(docStart + count)])
        var frame = Frame(width: W, height: H, pixels: px)
        // Fixed UI drawn on top.
        frame.draw { ctx, h in
            // Header bar with a title.
            ctx.setFillColor(CGColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h - CGFloat(headerHeight), width: CGFloat(W), height: CGFloat(headerHeight)))
            ctx.setFillColor(CGColor(gray: 0.7, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h - CGFloat(headerHeight), width: CGFloat(W), height: 2))
            SyntheticChat.text(ctx, "프로젝트 A 단톡방 (5)", x: 40, baselineFromTop: 70, height: h, size: 36, color: CGColor(gray: 0.1, alpha: 1))
            // Input box.
            let fy = CGFloat(0)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: fy, width: CGFloat(W), height: CGFloat(footerHeight)))
            ctx.setFillColor(CGColor(gray: 0.75, alpha: 1))
            ctx.fill(CGRect(x: 0, y: CGFloat(footerHeight) - 2, width: CGFloat(W), height: 2))
            SyntheticChat.text(ctx, "메시지를 입력하세요", x: 40, baselineFromTop: Int(h) - footerHeight + 85, height: h, size: 30, color: CGColor(gray: 0.6, alpha: 1))
            ctx.setFillColor(CGColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(W) - 170, y: 40, width: 110, height: 64))
            SyntheticChat.text(ctx, "전송", x: W - 145, baselineFromTop: Int(h) - 62, height: h, size: 30, color: CGColor(gray: 0.1, alpha: 1))
            // Floating "jump to latest" button.
            if showsFloatingButton {
                let r = CGRect(x: CGFloat(W) - 140, y: CGFloat(footerHeight) + 30, width: 76, height: 76)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: r)
                ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
                ctx.setLineWidth(3)
                ctx.strokeEllipse(in: r)
                SyntheticChat.text(ctx, "↓", x: Int(r.midX) - 12, baselineFromTop: Int(h - r.midY) + 14, height: h, size: 40, color: CGColor(gray: 0.2, alpha: 1))
            }
            // Overlay scrollbar thumb on the right edge.
            let track = CGFloat(viewportHeight)
            let thumbH = max(60, track * CGFloat(viewportHeight) / CGFloat(document.height))
            let frac = CGFloat(s) / CGFloat(max(1, maxScroll))
            let thumbTopFromTop = CGFloat(headerHeight) + frac * (track - thumbH)
            ctx.setFillColor(CGColor(gray: 0.45, alpha: 0.8))
            let thumb = CGRect(x: CGFloat(W) - 16, y: h - thumbTopFromTop - thumbH, width: 10, height: thumbH)
            ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }
        return frame
    }

    // MARK: - Drawing

    static func drawDocument(width W: Int, height H: Int, seed: UInt64) -> Frame {
        var rng = SeededRandom(seed: seed)
        var frame = Frame(width: W, height: H, gray: 255)
        frame.draw { ctx, h in
            ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: h))
            var top = 30
            var repeatText: String? = nil
            var repeatsLeft = 0
            while top < H - 200 {
                let roll = Int.random(in: 0..<100, using: &rng)
                if roll < 6 {
                    // Date separator.
                    ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
                    ctx.fill(CGRect(x: 40, y: h - CGFloat(top + 30), width: CGFloat(W) - 80, height: 2))
                    text(ctx, "2026년 11월 \(Int.random(in: 1...28, using: &rng))일", x: W / 2 - 120, baselineFromTop: top + 20, height: h, size: 26, color: CGColor(gray: 0.45, alpha: 1))
                    top += 70
                    continue
                }
                if roll < 12 {
                    // "Photo": a block of noise.
                    let pw = Int.random(in: 300...520, using: &rng), ph = Int.random(in: 200...380, using: &rng)
                    let x = Bool.random(using: &rng) ? 110 : W - pw - 60
                    for yy in stride(from: 0, to: ph, by: 6) {
                        for xx in stride(from: 0, to: pw, by: 6) {
                            ctx.setFillColor(CGColor(red: CGFloat.random(in: 0...1, using: &rng), green: CGFloat.random(in: 0...1, using: &rng),
                                                     blue: CGFloat.random(in: 0...1, using: &rng), alpha: 1))
                            ctx.fill(CGRect(x: CGFloat(x + xx), y: h - CGFloat(top + yy + 6), width: 6, height: 6))
                        }
                    }
                    top += ph + Int.random(in: 20...40, using: &rng)
                    continue
                }
                // Message bubble (sometimes the same short message several times in a row).
                let message: String
                if repeatsLeft > 0, let r = repeatText { message = r; repeatsLeft -= 1 }
                else if roll < 20 { message = "ㅋㅋㅋ"; repeatText = message; repeatsLeft = 3 }
                else {
                    let lines = Int.random(in: 1...3, using: &rng)
                    message = (0..<lines).map { _ in samples.randomElement(using: &rng)! }.joined(separator: "\n")
                }
                let mine = Bool.random(using: &rng)
                let lines = message.split(separator: "\n").map(String.init)
                let lineHeight = 40
                let textWidth = lines.map { lineWidth($0, size: 28) }.max() ?? 100
                let bw = min(W - 260, textWidth + 40), bh = lines.count * lineHeight + 24
                let bx = mine ? W - bw - 60 : 110
                if !mine {
                    ctx.setFillColor(CGColor(red: CGFloat.random(in: 0.3...0.9, using: &rng), green: 0.5, blue: 0.7, alpha: 1))
                    ctx.fillEllipse(in: CGRect(x: 30, y: h - CGFloat(top + 64), width: 64, height: 64))
                }
                let bubble = CGRect(x: CGFloat(bx), y: h - CGFloat(top + bh), width: CGFloat(bw), height: CGFloat(bh))
                ctx.setFillColor(mine ? CGColor(red: 1.0, green: 0.90, blue: 0.2, alpha: 1) : CGColor(gray: 1, alpha: 1))
                ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: 18, cornerHeight: 18, transform: nil))
                ctx.fillPath()
                for (i, line) in lines.enumerated() {
                    text(ctx, line, x: bx + 20, baselineFromTop: top + 12 + (i + 1) * lineHeight - 10, height: h, size: 28, color: CGColor(gray: 0.1, alpha: 1))
                }
                text(ctx, String(format: "오후 %d:%02d", Int.random(in: 1...11, using: &rng), Int.random(in: 0...59, using: &rng)),
                     x: mine ? bx - 110 : bx + bw + 10, baselineFromTop: top + bh - 6, height: h, size: 20, color: CGColor(gray: 0.55, alpha: 1))
                top += bh + Int.random(in: 14...40, using: &rng)
            }
        }
        return frame
    }

    static func lineWidth(_ s: String, size: CGFloat) -> Int {
        let line = CTLineCreateWithAttributedString(attributed(s, size: size, color: CGColor(gray: 0, alpha: 1)))
        return Int(CTLineGetTypographicBounds(line, nil, nil, nil).rounded(.up))
    }

    static func attributed(_ s: String, size: CGFloat, color: CGColor) -> CFAttributedString {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, size, nil)
        let attrs = [kCTFontAttributeName as String: font, kCTForegroundColorAttributeName as String: color] as CFDictionary
        return CFAttributedStringCreate(nil, s as CFString, attrs)!
    }

    static func text(_ ctx: CGContext, _ s: String, x: Int, baselineFromTop: Int, height h: CGFloat, size: CGFloat, color: CGColor) {
        let line = CTLineCreateWithAttributedString(attributed(s, size: size, color: color))
        ctx.textPosition = CGPoint(x: CGFloat(x), y: h - CGFloat(baselineFromTop))
        CTLineDraw(line, ctx)
    }
}

extension Frame {
    /// Draws into this frame with Core Graphics (origin bottom-left, `h` = height).
    mutating func draw(_ body: (CGContext, CGFloat) -> Void) {
        let w = width, h = height
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: Frame.colorSpace, bitmapInfo: Frame.bitmapInfo) else { return }
            body(ctx, CGFloat(h))
        }
    }
}

/// Collects stitched rows in memory.
public final class MemorySink: RowSink {
    public private(set) var bytes: [UInt8] = []
    public private(set) var width = 0
    public private(set) var rows = 0
    public private(set) var seams = 0
    public init() {}
    public func append(frame: Frame, rows r: Range<Int>) {
        width = frame.width
        bytes.append(contentsOf: frame.pixels[(r.lowerBound * frame.bytesPerRow)..<(r.upperBound * frame.bytesPerRow)])
        rows += r.count
    }
    public func appendSeamMarker(width: Int) { seams += 1 }
    public func finish() {}
    public var frame: Frame { Frame(width: width, height: rows, pixels: bytes) }
}

/// Result of scrolling a synthetic chat and stitching it.
public struct SyntheticRun {
    public let output: Frame
    public let assembler: StitchAssembler
    public let firstOffset: Int
    public let lastOffset: Int
    public let unconfident: Int
    public let wrongShifts: Int
    public let steps: Int
    public let notes: [String]

    /// Scrolls by random amounts (unknown to the stitcher), sized like the real capture loop:
    /// a fraction of the viewport the stitcher currently believes in.
    public static func run(_ chat: SyntheticChat, start: Int, seed: UInt64,
                           stepRange: ClosedRange<Double> = 0.35...0.75) -> SyntheticRun {
        var rng = SeededRandom(seed: seed)
        let sink = MemorySink()
        let asm = StitchAssembler(sink: sink, rightExclude: 40)
        var s = start, accepted = start
        asm.begin(chat.screen(at: s))
        var noChange = 0, unconfident = 0, wrong = 0, steps = 0
        var notes: [String] = []
        while noChange < 2 {
            let viewport = asm.started ? asm.viewportHeight : chat.viewportHeight
            let step = max(1, Int(Double(viewport) * Double.random(in: stepRange, using: &rng)))
            s = min(s + step, chat.maxScroll)
            steps += 1
            let f = chat.screen(at: s)
            let sig = asm.signatures(for: f)
            if asm.isUnchanged(sig) { noChange += 1; continue }
            noChange = 0
            let mr = asm.match(sig, expected: nil, allowNegative: false)
            guard let m = mr, m.confident else {
                unconfident += 1
                notes.append("step \(steps) actual=\(s - accepted) result=\(mr.map { "\($0)" } ?? "nil") hTop=\(asm.hTop) hBot=\(asm.hBot)")
                asm.acceptWithSeam(f, sig: sig)
                accepted = s
                continue
            }
            if m.shift != s - accepted { wrong += 1 }
            asm.accept(f, sig: sig, shift: m.shift)
            accepted = s
        }
        asm.finish()
        return SyntheticRun(output: sink.frame, assembler: asm, firstOffset: start, lastOffset: accepted,
                            unconfident: unconfident, wrongShifts: wrong, steps: steps, notes: notes)
    }

    /// Output rows (in the part that should be pure document) that differ from the document.
    public func badRows(_ chat: SyntheticChat) -> [Int] {
        let expectedHeight = chat.screenHeight + (lastOffset - firstOffset)
        guard output.height == expectedHeight else { return [-1] }
        let columns = 0..<(chat.width - 48)
        var bad: [Int] = []
        for r in chat.headerHeight..<(output.height - assembler.hBot) {
            let docRow = firstOffset + r - chat.headerHeight
            if !output.rowEquals(r, chat.document, docRow, columns: columns) { bad.append(r) }
        }
        return bad
    }
}
