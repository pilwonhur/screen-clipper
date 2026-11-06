import Foundation

/// How far the content moved between two frames.
public struct MatchResult: CustomStringConvertible {
    /// Pixels the content moved up (positive = scrolled toward the end).
    public var shift: Int
    /// Fraction of compared blocks that disagreed (0 = perfect).
    public var score: Float
    /// Blocks that carried information (texture or color change).
    public var informative: Int
    /// Another shift fit almost as well.
    public var ambiguous: Bool
    /// Safe to stitch with.
    public var confident: Bool

    public var description: String {
        "shift=\(shift) score=\(String(format: "%.3f", score)) informative=\(informative) ambiguous=\(ambiguous) confident=\(confident)"
    }
}

public struct MatchParams {
    /// Rows above this are a fixed header band (ignored).
    public var top: Int
    /// Rows at or below this are a fixed footer band (ignored), for each frame.
    public var prevBottom: Int
    public var curBottom: Int
    /// Search range for the shift.
    public var minShift: Int
    public var maxShift: Int
    /// Shift we expect from the scroll we asked for, if known.
    public var expected: Int?
    /// Minimum overlapping rows a shift needs.
    public var minEvidence: Int
    /// Blocks to compare (nil = all), used to skip static side columns.
    public var activeBlocks: [Int]?

    public init(top: Int, prevBottom: Int, curBottom: Int, minShift: Int, maxShift: Int,
                expected: Int? = nil, minEvidence: Int, activeBlocks: [Int]? = nil) {
        self.top = top; self.prevBottom = prevBottom; self.curBottom = curBottom
        self.minShift = minShift; self.maxShift = maxShift; self.expected = expected
        self.minEvidence = minEvidence; self.activeBlocks = activeBlocks
    }
}

public enum ShiftMatcher {
    /// Acceptable mismatch fraction for a confident match (overlays, animated content, noise).
    public static let maxConfidentScore: Float = 0.25

    /// Finds `d` such that row `y` of `cur` matches row `y + d` of `prev`.
    ///
    /// Scoring is per block: blocks that are flat and equal on both sides carry no information
    /// and are skipped; the rest either agree or disagree. A small overlay (a floating button)
    /// only spoils a few blocks, so the true shift still scores near zero.
    public static func match(prev: RowSignatures, cur: RowSignatures, params p: MatchParams) -> MatchResult? {
        precondition(prev.stride == cur.stride && prev.height == cur.height)
        struct Candidate { var d: Int; var mism: Int; var info: Int; var score: Float }
        var candidates: [Candidate] = []
        let B = cur.blocks
        let active = p.activeBlocks ?? Array(0..<B)
        let tol = RowSignatures.blockTolerance
        let minBlocks = max(64, p.minEvidence * 6)

        prev.data.withUnsafeBufferPointer { pa in
            cur.data.withUnsafeBufferPointer { ca in
                active.withUnsafeBufferPointer { act in
                    let S = cur.stride
                    for d in p.minShift...max(p.minShift, p.maxShift) where d != 0 {
                        let yStart = max(p.top, p.top - d)
                        let yEnd = min(p.curBottom, p.prevBottom - d)
                        if yEnd - yStart < p.minEvidence { continue }
                        var mism = 0, info = 0
                        var abandoned = false
                        for y in yStart..<yEnd {
                            let py = y + d
                            if cur.uniform[y] && prev.uniform[py] {
                                // Two flat rows: one comparison decides.
                                let k = act[0]
                                if abs(ca[y * S + k] - pa[py * S + k]) > tol {
                                    mism += act.count; info += act.count
                                }
                            } else {
                                let ci = y * S, pi = py * S
                                for k in act {
                                    let cm = ca[ci + k], pm = pa[pi + k]
                                    let cg = ca[ci + B + k], pg = pa[pi + B + k]
                                    let dm = abs(cm - pm), dg = abs(cg - pg)
                                    if dm <= tol && dg <= tol && cg <= 0.5 && pg <= 0.5 { continue }  // flat and equal
                                    info += 1
                                    if dm > tol || dg > tol { mism += 1 }
                                }
                            }
                            // Give up on clearly wrong shifts early.
                            if info >= 400 && mism * 2 > info { abandoned = true; break }
                        }
                        if abandoned || info < minBlocks { continue }
                        candidates.append(Candidate(d: d, mism: mism, info: info, score: Float(mism) / Float(info)))
                    }
                }
            }
        }
        guard !candidates.isEmpty else { return nil }

        // Best = lowest score; ties go to more evidence.
        func better(_ a: Candidate, _ b: Candidate) -> Bool {
            if abs(a.score - b.score) > 0.005 { return a.score < b.score }
            return a.info > b.info
        }
        var best = candidates[0]
        for c in candidates.dropFirst() where better(c, best) { best = c }

        // Other shifts (not just neighbors of the best) that fit about as well.
        let rivals = candidates.filter { abs($0.d - best.d) > 4 && $0.score <= best.score + 0.02 }
        var ambiguous = !rivals.isEmpty
        var chosen = best
        if ambiguous, let expected = p.expected {
            let pool = [best] + rivals
            chosen = pool.min(by: { abs($0.d - expected) < abs($1.d - expected) })!
            // Resolved if the pick is close to what we asked for and clearly closer than the others.
            let others = pool.filter { $0.d != chosen.d }.map { abs($0.d - expected) }
            let tolerance = max(8, abs(expected) / 4)
            if abs(chosen.d - expected) <= tolerance && (others.min() ?? .max) > tolerance {
                ambiguous = false
            }
        }
        let confident = !ambiguous && chosen.score <= maxConfidentScore
        return MatchResult(shift: chosen.d, score: chosen.score, informative: chosen.info,
                           ambiguous: ambiguous, confident: confident)
    }
}
