import CoreGraphics
import Foundation

/// Archives a clip to Obsidian and posts it to Discord, step by step. Progress is saved in the
/// clip's meta after every step, so a failed post resumes where it stopped.
public final class ClipPublisher {
    public struct Settings {
        public var webhookURL: URL?
        public var roleID: String?
        public var archiveRoot: URL?
        public init(webhookURL: URL?, roleID: String?, archiveRoot: URL?) {
            self.webhookURL = webhookURL; self.roleID = roleID; self.archiveRoot = archiveRoot
        }
    }

    public let store: ClipStore
    public var settings: Settings

    public init(store: ClipStore, settings: Settings) {
        self.store = store
        self.settings = settings
    }

    /// Runs whatever is left to do for this clip. Throws the Discord error if posting failed
    /// (the archive is still written first).
    public func publish(_ meta: inout ClipMeta) async throws {
        let pages = store.pages(meta.id)
        let transcript = store.transcript(meta.id)

        // 1. Obsidian note (local, so it never waits for the network).
        if !meta.archive.done, let root = settings.archiveRoot {
            let archiver = ObsidianArchiver(root: root)
            let note = try archiver.archive(meta, pages: pages, transcript: transcript)
            meta.archive.notePath = note.path
            meta.archive.done = true
            meta.archive.linkWritten = meta.discord.link != nil
            try store.save(meta)
        } else if settings.archiveRoot == nil {
            meta.archive.done = true
        }

        // 2. Discord.
        if meta.sendToDiscord && !meta.discord.done, let url = settings.webhookURL {
            do {
                try await postToDiscord(&meta, webhook: DiscordWebhook(url: url), pages: pages, transcript: transcript)
                meta.discord.done = true
                meta.discord.lastError = nil
                try store.save(meta)
            } catch {
                meta.discord.attempts += 1
                meta.discord.lastError = error.localizedDescription
                let delay = min(3600, 60 * pow(2, Double(min(meta.discord.attempts - 1, 6))))
                meta.discord.nextAttempt = Date().addingTimeInterval(delay)
                try? store.save(meta)
                throw error
            }
        }

        // 3. Put the Discord link into the note.
        if meta.archive.done && !meta.archive.linkWritten, let link = meta.discord.link,
           let path = meta.archive.notePath, let root = settings.archiveRoot {
            try? ObsidianArchiver(root: root).writeDiscordLink(noteURL: URL(fileURLWithPath: path), link: link)
            meta.archive.linkWritten = true
            try store.save(meta)
        }
    }

    // MARK: - Discord

    static func threadName(_ meta: ClipMeta) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return String("[\(meta.app)] \(meta.title) · \(f.string(from: meta.capturedAt))".prefix(100))
    }

    /// The first message: role mention, AI summary, source line.
    public static func headerText(_ meta: ClipMeta, roleID: String?) -> String {
        var lines: [String] = []
        if let roleID, !roleID.isEmpty { lines.append("<@&\(roleID)>") }
        if let s = meta.summary {
            lines.append("🤖 **AI summary**")
            lines.append(s.gist)
            lines.append(contentsOf: s.cleanBullets.map { "• " + $0 })
        } else if let note = meta.summaryNote {
            lines.append("🤖 AI summary: (\(note))")
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("-# Source: \(meta.app) · \(meta.pageCount) page\(meta.pageCount == 1 ? "" : "s") · captured \(f.string(from: meta.capturedAt))")
        if meta.seams > 0 { lines.append("⚠️ \(meta.seams) possible gap(s), marked with a red dashed line.") }
        var text = lines.joined(separator: "\n")
        if text.count > DiscordWebhook.maxContent { text = String(text.prefix(DiscordWebhook.maxContent - 1)) + "…" }
        return text
    }

    static func pageFile(_ url: URL, index: Int) throws -> DiscordFile {
        let name = String(format: "page-%02d", index + 1)
        let data = try Data(contentsOf: url)
        if data.count <= DiscordWebhook.maxBytesPerMessage {
            return DiscordFile(name: name + ".png", data: data, mimeType: "image/png")
        }
        let jpeg = try ImageFiles.jpegData(try ImageFiles.load(url), maxBytes: DiscordWebhook.maxBytesPerMessage)
        return DiscordFile(name: name + ".jpg", data: jpeg, mimeType: "image/jpeg")
    }

    private func postToDiscord(_ meta: inout ClipMeta, webhook: DiscordWebhook, pages: [URL], transcript: String) async throws {
        if meta.discord.guildID == nil { meta.discord.guildID = try? await webhook.guildID() }
        let files = try pages.enumerated().map { try Self.pageFile($0.element, index: $0.offset) }
        let batches = DiscordWebhook.batches(files)
        let total = max(1, batches.count)

        while meta.discord.batchesPosted < total {
            let i = meta.discord.batchesPosted
            let batch = i < batches.count ? batches[i] : []
            let message: DiscordMessage
            if i == 0 {
                let header = Self.headerText(meta, roleID: settings.roleID)
                do {
                    message = try await webhook.send(content: header, threadName: Self.threadName(meta),
                                                     files: batch, mentionRole: settings.roleID)
                } catch DiscordError.http(400, let body) where body.lowercased().contains("thread") {
                    // Not a forum channel: post as normal messages with the title in bold.
                    meta.discord.nonForum = true
                    message = try await webhook.send(content: "**\(Self.threadName(meta))**\n" + header,
                                                     files: batch, mentionRole: settings.roleID)
                }
                meta.discord.firstMessageID = message.id
                meta.discord.threadID = meta.discord.nonForum ? message.channelId : message.channelId
            } else {
                message = try await webhook.send(content: nil, threadID: meta.discord.nonForum ? nil : meta.discord.threadID,
                                                 files: batch)
            }
            meta.discord.messageIDs.append(message.id)
            meta.discord.batchesPosted += 1
            try store.save(meta)
        }

        if !meta.discord.transcriptPosted {
            let fence = "```"
            var excerpt = String(transcript.prefix(1850)).replacingOccurrences(of: fence, with: "'''")
            if transcript.count > 1850 { excerpt += "\n…" }
            let content = "📄 Transcript (excerpt; full text attached)\n\(fence)\n\(excerpt)\n\(fence)"
            let file = DiscordFile(name: "transcript.md", data: Data(transcript.utf8), mimeType: "text/markdown")
            let message = try await webhook.send(content: content, threadID: meta.discord.nonForum ? nil : meta.discord.threadID,
                                                 files: [file])
            meta.discord.messageIDs.append(message.id)
            meta.discord.transcriptPosted = true
            try store.save(meta)
        }
    }
}
