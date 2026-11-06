import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFiles {
    public enum Failure: Error { case encode, decode(URL) }

    public static func pngData(_ image: CGImage) throws -> Data {
        try encode(image, type: .png, properties: [:])
    }

    public static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        try encode(image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    /// JPEG that tries to stay under `maxBytes`: lowers quality first, then scales down.
    public static func jpegData(_ image: CGImage, maxBytes: Int, maxDimension: Int? = nil) throws -> Data {
        var img = image
        if let maxDimension, max(img.width, img.height) > maxDimension {
            img = scaled(img, factor: Double(maxDimension) / Double(max(img.width, img.height))) ?? img
        }
        for q in [0.85, 0.75, 0.65] {
            let d = try jpegData(img, quality: q)
            if d.count <= maxBytes { return d }
        }
        var factor = 0.8
        while factor > 0.3 {
            if let s = scaled(img, factor: factor) {
                let d = try jpegData(s, quality: 0.7)
                if d.count <= maxBytes { return d }
            }
            factor -= 0.15
        }
        return try jpegData(img, quality: 0.6)
    }

    public static func scaled(_ image: CGImage, factor: Double) -> CGImage? {
        let w = max(1, Int(Double(image.width) * factor)), h = max(1, Int(Double(image.height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Frame.colorSpace, bitmapInfo: Frame.bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    public static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Failure.decode(url) }
        return img
    }

    public static func writePNG(_ frame: Frame, to url: URL) throws {
        guard let img = frame.makeImage() else { throw Failure.encode }
        try pngData(img).write(to: url, options: .atomic)
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw Failure.encode
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encode }
        return data as Data
    }
}
