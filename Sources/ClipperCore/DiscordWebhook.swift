import Foundation

public enum DiscordError: LocalizedError {
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Discord error \(code): \(body.prefix(300))"
        case .badResponse: return "Unexpected response from Discord."
        }
    }
    /// Worth retrying later (network trouble, rate limits, server errors).
    public var isTransient: Bool {
        if case .http(let code, _) = self { return code == 429 || code >= 500 }
        return true
    }
}

public struct DiscordFile {
    public var name: String
    public var data: Data
    public var mimeType: String
    public init(name: String, data: Data, mimeType: String) { self.name = name; self.data = data; self.mimeType = mimeType }
}

/// A message created by the webhook.
public struct DiscordMessage {
    public var id: String
    /// For a new forum post this is the post's thread ID.
    public var channelId: String
}

/// Posts through a Discord webhook (no bot needed).
public final class DiscordWebhook {
    public let url: URL
    public static let maxContent = 2000
    public static let maxFilesPerMessage = 10
    /// Conservative per-message upload budget (non-boosted servers allow 10 MB).
    public static let maxBytesPerMessage = 9_000_000

    public init(url: URL) { self.url = url }

    public static func isValidURL(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), let host = u.host else { return false }
        return (host.hasSuffix("discord.com") || host.hasSuffix("discordapp.com")) && u.path.contains("/api/webhooks/")
    }

    /// Server (guild) ID, used to build links to posts.
    public func guildID() async throws -> String? {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DiscordError.http(status, String(decoding: data, as: UTF8.self)) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["guild_id"] as? String
    }

    /// Sends one message. `threadName` starts a new forum post; `threadID` posts inside one.
    /// `mentionRole` (a role ID) is the only mention allowed to ping.
    public func send(content: String?, threadName: String? = nil, threadID: String? = nil,
                     files: [DiscordFile] = [], mentionRole: String? = nil) async throws -> DiscordMessage {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var query = comps.queryItems ?? []
        query.append(URLQueryItem(name: "wait", value: "true"))
        if let threadID { query.append(URLQueryItem(name: "thread_id", value: threadID)) }
        comps.queryItems = query

        var payload: [String: Any] = [
            "allowed_mentions": ["parse": [String](), "roles": mentionRole.map { [$0] } ?? []],
        ]
        if let content, !content.isEmpty { payload["content"] = String(content.prefix(Self.maxContent)) }
        if let threadName { payload["thread_name"] = String(threadName.prefix(100)) }
        if !files.isEmpty {
            payload["attachments"] = files.enumerated().map { ["id": $0.offset, "filename": $0.element.name] }
        }

        let boundary = "ScreenClipper-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(try JSONSerialization.data(withJSONObject: payload))
        add("\r\n")
        for (i, f) in files.enumerated() {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"files[\(i)]\"; filename=\"\(f.name)\"\r\nContent-Type: \(f.mimeType)\r\n\r\n")
            body.append(f.data)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")

        var attempt = 0
        while true {
            var request = URLRequest(url: comps.url!, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("ScreenClipper (macOS, 0.1)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 429 && attempt < 5 {
                attempt += 1
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let wait = (json?["retry_after"] as? Double)
                    ?? Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                try await Task.sleep(nanoseconds: UInt64((wait + 0.25) * 1_000_000_000))
                continue
            }
            guard (200..<300).contains(status) else { throw DiscordError.http(status, String(decoding: data, as: UTF8.self)) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String, let channel = json["channel_id"] as? String else {
                throw DiscordError.badResponse
            }
            return DiscordMessage(id: id, channelId: channel)
        }
    }

    /// Splits files into messages: at most 10 files and `maxBytesPerMessage` per message.
    public static func batches(_ files: [DiscordFile]) -> [[DiscordFile]] {
        var result: [[DiscordFile]] = []
        var current: [DiscordFile] = []
        var bytes = 0
        for f in files {
            if !current.isEmpty && (current.count >= maxFilesPerMessage || bytes + f.data.count > maxBytesPerMessage) {
                result.append(current); current = []; bytes = 0
            }
            current.append(f); bytes += f.data.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
