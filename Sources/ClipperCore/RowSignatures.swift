import Foundation

/// A compact fingerprint of every row in a frame.
///
/// Each row is split into `blocks` horizontal blocks. For each block we keep the mean
/// luminance and the mean horizontal gradient (how much "texture" the block has).
/// Layout per row: `[mean_0 ..< mean_B, grad_0 ..< grad_B]`.
public struct RowSignatures {
    public let height: Int
    public let blocks: Int
    public let stride: Int
    public private(set) var data: [Float]
    /// True when a row is flat (background, bubble fill): it carries no position information.
    public private(set) var uniform: [Bool]

    // Tolerances shared by the matcher and the band detector.
    public static let blockTolerance: Float = 2.0   // small differences (anti-aliasing noise)
    public static let hardTolerance: Float = 12.0   // one block this different = rows differ
    public static let maxSoftDifferences = 1        // more blocks than this over blockTolerance = rows differ

    public init(frame: Frame, blocks requested: Int = 64, excludeRight: Int = 0, excludeLeft: Int = 0) {
        let x0 = max(0, min(excludeLeft, frame.width - 1))
        let x1 = max(x0 + 1, frame.width - max(0, excludeRight))
        let usable = x1 - x0
        let B = max(1, min(requested, usable / 4))
        let S = 2 * B
        let H = frame.height
        let bpr = frame.bytesPerRow
        var out = [Float](repeating: 0, count: H * S)
        var uni = [Bool](repeating: false, count: H)

        // Block boundaries (same for every row).
        var bounds = [Int](repeating: 0, count: B + 1)
        for b in 0...B { bounds[b] = x0 + b * usable / B }

        frame.pixels.withUnsafeBufferPointer { px in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<H {
                    let rowBase = y * bpr
                    let first = rowBase + x0 * 4
                    var prevL = (Int(px[first]) * 299 + Int(px[first + 1]) * 587 + Int(px[first + 2]) * 114) / 1000
                    var minMean: Float = .greatestFiniteMagnitude, maxMean: Float = -.greatestFiniteMagnitude
                    var maxGrad: Float = 0
                    for b in 0..<B {
                        let bx0 = bounds[b], bx1 = bounds[b + 1]
                        var sum = 0, gsum = 0
                        var i = rowBase + bx0 * 4
                        for _ in bx0..<bx1 {
                            let l = (Int(px[i]) * 299 + Int(px[i + 1]) * 587 + Int(px[i + 2]) * 114) / 1000
                            sum += l
                            gsum += abs(l - prevL)
                            prevL = l
                            i += 4
                        }
                        let n = Float(max(1, bx1 - bx0))
                        let mean = Float(sum) / n, grad = Float(gsum) / n
                        o[y * S + b] = mean
                        o[y * S + B + b] = grad
                        minMean = min(minMean, mean); maxMean = max(maxMean, mean); maxGrad = max(maxGrad, grad)
                    }
                    uni[y] = (maxMean - minMean) <= 1.5 && maxGrad <= 0.5
                }
            }
        }
        self.height = H
        self.blocks = B
        self.stride = S
        self.data = out
        self.uniform = uni
    }

    @inline(__always) public func mean(_ y: Int, _ b: Int) -> Float { data[y * stride + b] }
    @inline(__always) public func grad(_ y: Int, _ b: Int) -> Float { data[y * stride + blocks + b] }

    /// True when row `y` here and row `oy` in `other` look different.
    /// `active` limits the comparison to some blocks (nil = all).
    public func rowDiffers(_ y: Int, _ other: RowSignatures, _ oy: Int, active: [Int]? = nil) -> Bool {
        data.withUnsafeBufferPointer { a in
            other.data.withUnsafeBufferPointer { b in
                RowSignatures.rowDiffers(a, y * stride, b, oy * other.stride, blocks: blocks,
                                         uniformBoth: uniform[y] && other.uniform[oy], active: active)
            }
        }
    }

    @inline(__always)
    static func rowDiffers(_ a: UnsafeBufferPointer<Float>, _ ai: Int, _ b: UnsafeBufferPointer<Float>, _ bi: Int,
                           blocks B: Int, uniformBoth: Bool, active: [Int]?) -> Bool {
        if uniformBoth {
            // Flat rows: comparing one block is enough.
            let k = active?.first ?? 0
            return abs(a[ai + k] - b[bi + k]) > blockTolerance
        }
        var soft = 0
        if let active {
            for k in active {
                let dm = abs(a[ai + k] - b[bi + k])
                if dm > hardTolerance { return true }
                if dm > blockTolerance { soft += 1; if soft > maxSoftDifferences { return true } }
                let dg = abs(a[ai + B + k] - b[bi + B + k])
                if dg > hardTolerance { return true }
                if dg > blockTolerance { soft += 1; if soft > maxSoftDifferences { return true } }
            }
        } else {
            for k in 0..<(2 * B) {
                let d = abs(a[ai + k] - b[bi + k])
                if d > hardTolerance { return true }
                if d > blockTolerance { soft += 1; if soft > maxSoftDifferences { return true } }
            }
        }
        return false
    }
}
