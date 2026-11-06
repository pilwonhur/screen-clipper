import CoreGraphics
import Foundation
import Vision

/// On-device text recognition (Apple Vision), Korean + English.
public enum OCR {
    public static var languages = ["ko-KR", "en-US"]

    /// Text of one image, top to bottom; items on the same line are joined with two spaces.
    public static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let items = (request.results ?? []).compactMap { obs -> (box: CGRect, text: String)? in
            guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return (obs.boundingBox, s)
        }
        // Vision boxes are normalized with the origin at the bottom-left.
        let sorted = items.sorted { $0.box.midY > $1.box.midY }
        var lines: [[(box: CGRect, text: String)]] = []
        for item in sorted {
            if let last = lines.last?.last, verticalOverlap(last.box, item.box) > 0.5 {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }
        return lines.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ") }
            .joined(separator: "\n")
    }

    static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return max(0, overlap) / max(0.0001, min(a.height, b.height))
    }

    /// Transcript for a list of page images, with a `--- page N ---` marker per page.
    public static func transcript(pages: [URL]) async -> String {
        var parts = [String](repeating: "", count: pages.count)
        await withTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func add() {
                guard next < pages.count else { return }
                let i = next, url = pages[i]
                next += 1
                group.addTask {
                    let text = (try? ImageFiles.load(url)).flatMap { try? recognize($0) } ?? ""
                    return (i, text)
                }
            }
            for _ in 0..<min(3, pages.count) { add() }
            for await (i, text) in group {
                parts[i] = text
                add()
            }
        }
        return parts.enumerated().map { "--- page \($0.offset + 1) ---\n\($0.element)" }.joined(separator: "\n\n")
    }
}
