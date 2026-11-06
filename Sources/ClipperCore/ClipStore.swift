import Foundation

/// Everything about one clip, saved as `meta.json` so posting can resume after a failure.
public struct ClipMeta: Codable {
    public var id: String
    public var app: String
    public var bundleID: String?
    public var window: String
    public var title: String
    public var capturedAt: Date
    public var pageCount: Int
    public var screens: Int
    public var seams: Int
    public var summary: ClipSummary?
    /// Shown instead of a summary: "unavailable" (attempted and failed) or nil (turned off).
    public var summaryNote: String?
    public var sendToDiscord: Bool
    public var discord = DiscordState()
    public var archive = ArchiveState()

    public struct DiscordState: Codable {
        public var threadID: String?
        public var guildID: String?
        public var firstMessageID: String?
        public var messageIDs: [String] = []
        public var batchesPosted = 0
        public var transcriptPosted = false
        public var nonForum = false
        public var done = false
        public var attempts = 0
        public var nextAttempt: Date?
        public var lastError: String?
        public var link: String? {
            guard let guildID, let threadID else { return nil }
            return "https://discord.com/channels/\(guildID)/\(threadID)"
        }
    }

    public struct ArchiveState: Codable {
        public var notePath: String?
        public var done = false
        public var linkWritten = false
    }

    public init(id: String, app: String, bundleID: String?, window: String, title: String, capturedAt: Date,
                pageCount: Int, screens: Int, seams: Int, sendToDiscord: Bool) {
        self.id = id; self.app = app; self.bundleID = bundleID; self.window = window; self.title = title
        self.capturedAt = capturedAt; self.pageCount = pageCount; self.screens = screens; self.seams = seams
        self.sendToDiscord = sendToDiscord
    }

    /// Nothing left to do: archived, posted (if wanted), and the note has the post's link.
    public var isComplete: Bool {
        archive.done && (!sendToDiscord || discord.done)
            && (discord.link == nil || archive.notePath == nil || archive.linkWritten)
    }

    public static func newID(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}

/// Clips waiting to be posted live in `~/Library/Application Support/Screen Clipper/clips/<id>/`.
public final class ClipStore {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Clipper/clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    public func pagesDirectory(_ id: String) -> URL { directory(id).appendingPathComponent("pages", isDirectory: true) }
    public func transcriptURL(_ id: String) -> URL { directory(id).appendingPathComponent("transcript.md") }
    private func metaURL(_ id: String) -> URL { directory(id).appendingPathComponent("meta.json") }

    public func pages(_ id: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: pagesDirectory(id), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func save(_ meta: ClipMeta) throws {
        try FileManager.default.createDirectory(at: directory(meta.id), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: metaURL(meta.id), options: .atomic)
    }

    public func load(_ id: String) -> ClipMeta? {
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ClipMeta.self, from: data)
    }

    public func allClips() -> [ClipMeta] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { load($0.lastPathComponent) }.sorted { $0.id < $1.id }
    }

    public func transcript(_ id: String) -> String {
        (try? String(contentsOf: transcriptURL(id), encoding: .utf8)) ?? ""
    }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: directory(id))
    }
}
