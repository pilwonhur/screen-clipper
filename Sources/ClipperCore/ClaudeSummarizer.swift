import Foundation

/// The brief summary posted at the top of each clip.
public struct ClipSummary: Codable, Equatable {
    public var language: String
    public var gist: String
    public var bullets: [String]

    public init(language: String, gist: String, bullets: [String]) {
        self.language = language; self.gist = gist; self.bullets = bullets
    }

    /// Bullets as plain text, never as task checkboxes.
    public var cleanBullets: [String] {
        bullets.prefix(5).map { b in
            var s = b.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["- [ ]", "- [x]", "[ ]", "[x]", "- ", "• ", "* "] where s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return s
        }.filter { !$0.isEmpty }
    }
}

public enum SummaryError: LocalizedError {
    case http(Int, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Claude API error \(code): \(body.prefix(300))"
        case .badResponse(let s): return "Unexpected Claude API response: \(s.prefix(300))"
        }
    }
}

/// Calls the Claude Messages API over HTTPS (there is no official Swift SDK).
public final class ClaudeSummarizer {
    public let apiKey: String
    public let model: String
    public var timeout: TimeInterval = 45
    /// Send page images when the clip has at most this many pages.
    public var maxImagePages = 50
    public var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String = "claude-opus-5-5") {
        self.apiKey = apiKey
        self.model = model
    }

    static let systemPrompt = """
    You summarize a clip captured from the user's screen: screenshots of a chat or document, \
    plus OCR text of the same pages. The summary is read by the user's secretaries, who will act on it.

    Rules:
    - Use only information visible in the clip. Never invent names, dates, times, places, or tasks.
    - Mark anything uncertain or partly unreadable with "(?)".
    - Write in the clip's main language (if the conversation is mostly Korean, write Korean).
    - Be brief: a one-line gist and at most 5 bullets, under 800 characters in total.
    - Start each bullet with a short label in that language, e.g. To-do / Deadline / Decision / Schedule \
    (Korean: 할 일 / 마감 / 결정 / 일정). Put what the secretaries need to do first, with who/what/when.
    - Plain text only: no markdown, no checkboxes.
    - If nothing is actionable, give the gist and the key points.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "language": ["type": "string", "description": "BCP-47 code of the clip's main language, e.g. ko or en"],
            "gist": ["type": "string", "description": "One line: what this clip is about"],
            "bullets": ["type": "array", "items": ["type": "string"], "description": "At most 5 short labeled bullets"],
        ],
        "required": ["language", "gist", "bullets"],
        "additionalProperties": false,
    ]

    /// Returns nil if the model declined the request.
    public func summarize(transcript: String, pages: [URL], sourceApp: String, title: String) async throws -> ClipSummary? {
        var content: [[String: Any]] = []
        var imagesBytes = 0
        if pages.count <= maxImagePages {
            for url in pages {
                guard let img = try? ImageFiles.load(url),
                      let jpeg = try? ImageFiles.jpegData(img, maxBytes: 600_000, maxDimension: 1568) else { continue }
                imagesBytes += jpeg.count
                if imagesBytes > 18_000_000 { content.removeAll(); break }   // keep the request well under the size limit
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                           "data": jpeg.base64EncodedString()]])
            }
        }
        let text = String(transcript.prefix(400_000))
        content.append(["type": "text", "text": """
        Source app: \(sourceApp)
        Window title: \(title)
        Pages: \(pages.count)\(content.isEmpty ? " (images not attached; summarize from the OCR text)" : "")

        OCR text of the pages:
        \(text)
        """])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": Self.systemPrompt,
            "messages": [["role": "user", "content": content]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": Self.schema]],
            "fallbacks": "default",
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SummaryError.http(status, String(decoding: data, as: UTF8.self)) }
        return try Self.parse(data)
    }

    /// Parses a Messages API response. Returns nil on a refusal.
    public static func parse(_ data: Data) throws -> ClipSummary? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryError.badResponse(String(decoding: data, as: UTF8.self))
        }
        if (json["stop_reason"] as? String) == "refusal" { return nil }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
              let textData = text.data(using: .utf8) else {
            throw SummaryError.badResponse(String(decoding: data, as: UTF8.self))
        }
        var summary = try JSONDecoder().decode(ClipSummary.self, from: textData)
        summary.bullets = summary.cleanBullets
        return summary
    }
}
