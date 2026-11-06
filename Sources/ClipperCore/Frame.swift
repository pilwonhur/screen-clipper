import CoreGraphics
import Foundation

/// An RGBA8 bitmap (sRGB, premultiplied alpha, bytes R,G,B,A), stored top row first.
public struct Frame {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public var bytesPerRow: Int { width * 4 }

    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "pixel buffer size mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A frame filled with one opaque gray level.
    public init(width: Int, height: Int, gray: UInt8 = 255) {
        var px = [UInt8](repeating: gray, count: width * height * 4)
        if gray != 255 {
            for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        }
        self.init(width: width, height: height, pixels: px)
    }

    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: Frame.colorSpace,
                                      bitmapInfo: Frame.bitmapInfo) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, pixels: px)
    }

    /// Makes a CGImage from a range of rows (all rows by default).
    public func makeImage(rows: Range<Int>? = nil) -> CGImage? {
        let r = rows ?? 0..<height
        guard !r.isEmpty, r.lowerBound >= 0, r.upperBound <= height else { return nil }
        let data = Data(pixels[(r.lowerBound * bytesPerRow)..<(r.upperBound * bytesPerRow)])
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: r.count, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: Frame.colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: Frame.bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// True if row `y` of this frame equals row `oy` of `other` over the given columns.
    public func rowEquals(_ y: Int, _ other: Frame, _ oy: Int, columns: Range<Int>) -> Bool {
        let a = y * bytesPerRow + columns.lowerBound * 4
        let b = oy * other.bytesPerRow + columns.lowerBound * 4
        let n = columns.count * 4
        return pixels.withUnsafeBufferPointer { pa in
            other.pixels.withUnsafeBufferPointer { pb in
                memcmp(pa.baseAddress! + a, pb.baseAddress! + b, n) == 0
            }
        }
    }
}
