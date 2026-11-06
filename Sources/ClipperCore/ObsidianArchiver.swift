import Foundation

/// Saves each clip as one Obsidian note (frontmatter + AI summary + page images + transcript)
/// in a separate vault folder, `81 Screen Clips/` by default.
public struct ObsidianArchiver {
    public let root: URL
    public static let folderName = "81 Screen Clips"

    public init(root: URL) { self.root = root }

    /// `<open vault>/81 Screen Clips`, from Obsidian's own vault list.
    public static func defaultRoot() -> URL? {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return nil }
        let list = vaults.values.compactMap { v -> (path: String, open: Bool, ts: Double)? in
            guard let p = v["path"] as? String else { return nil }
            return (p, (v["open"] as? Bool) ?? false, (v["ts"] as? Double) ?? 0)
        }
        guard let pick = list.first(where: \.open) ?? list.max(by: { $0.ts < $1.ts }) else { return nil }
        return URL(fileURLWithPath: pick.path).appendingPathComponent(folderName, isDirectory: true)
    }

    /// Removes characters Obsidian doesn't allow in file names.
    public static func sanitize(_ s: String, maxLength: Int = 80) -> String {
        let banned = CharacterSet(charactersIn: "\\/:*?\"<>|#^[]\n\r\t")
        let cleaned = s.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return String(cleaned.prefix(maxLength))
    }

    static func yamlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }

    public func noteURL(for meta: ClipMeta) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = [f.string(from: meta.capturedAt), Self.sanitize(meta.app, maxLength: 30), Self.sanitize(meta.title)]
            .filter { !$0.isEmpty }.joined(separator: "_")
        return root.appendingPathComponent(name + ".md")
    }

    /// Writes compressed page images and the note. Returns the note's URL.
    @discardableResult
    public func archive(_ meta: ClipMeta, pages: [URL], transcript: String) throws -> URL {
        let fm = FileManager.default
        let imageDir = root.appendingPathComponent("_pages/\(meta.id)", isDirectory: true)
        try fm.createDirectory(at: imageDir, withIntermediateDirectories: true)
        var embeds: [String] = []
        for (i, page) in pages.enumerated() {
            let name = String(format: "%@_p%02d.jpg", meta.id, i + 1)
            let img = try ImageFiles.load(page)
            try ImageFiles.jpegData(img, maxBytes: 400_000).write(to: imageDir.appendingPathComponent(name), options: .atomic)
            embeds.append("![[\(name)]]")
        }
        let url = noteURL(for: meta)
        try render(meta, embeds: embeds, transcript: transcript).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public func render(_ meta: ClipMeta, embeds: [String], transcript: String) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]

        var lines = [
            "---",
            "title: \(Self.yamlString(meta.title))",
            "source_app: \(Self.yamlString(meta.app))",
            "window: \(Self.yamlString(meta.window))",
            "created: \(day.string(from: meta.capturedAt))",
            "captured: \(iso.string(from: meta.capturedAt))",
            "pages: \(meta.pageCount)",
            "clip_id: \(Self.yamlString(meta.id))",
            "discord: \(Self.yamlString(meta.discord.link ?? ""))",
            "tags:",
            "  - \"screen-clips\"",
            "read:",
            "---",
            "",
        ]
        if let s = meta.summary {
            lines.append("## AI summary")
            lines.append(s.gist)
            // Plain bullets, never "- [ ]": these are the secretaries' tasks, not mine.
            lines.append(contentsOf: s.cleanBullets.map { "- " + $0 })
            lines.append("")
        } else if let note = meta.summaryNote {
            lines.append("## AI summary")
            lines.append("(summary \(note))")
            lines.append("")
        }
        if meta.seams > 0 {
            lines.append("> [!warning] \(meta.seams) possible gap(s) in this capture (marked with a red dashed line).")
            lines.append("")
        }
        lines.append("## Pages")
        lines.append(contentsOf: embeds)
        lines.append("")
        lines.append("## Transcript")
        // A fence keeps OCR text from turning into headings or tasks.
        lines.append("````text")
        lines.append(transcript.replacingOccurrences(of: "````", with: "'''"))
        lines.append("````")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Fills in the `discord:` line once the post exists.
    public func writeDiscordLink(noteURL: URL, link: String) throws {
        let text = try String(contentsOf: noteURL, encoding: .utf8)
        let updated = text.replacingOccurrences(of: "discord: \"\"", with: "discord: \(Self.yamlString(link))")
        try updated.write(to: noteURL, atomically: true, encoding: .utf8)
    }
}
