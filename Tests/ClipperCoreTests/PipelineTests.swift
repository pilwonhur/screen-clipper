import ClipperCore
import Foundation
import Testing

@Suite struct OCRTests {
    @Test func readsKoreanAndEnglishFromAChatPage() throws {
        let chat = SyntheticChat(seed: 7)
        chat.showsFloatingButton = false
        let screen = chat.screen(at: 0)
        let text = try OCR.recognize(screen.makeImage()!)
        #expect(text.contains("프로젝트"))
        #expect(text.contains("메시지를 입력하세요") || text.contains("메시지"))
        #expect(!text.isEmpty)
    }
}

@Suite struct SummaryParsingTests {
    @Test func parsesStructuredOutput() throws {
        let inner = #"{"language":"ko","gist":"킥오프 일정 조율","bullets":["- [ ] 할 일: 미팅 확정","마감: 11/9"]}"#
        let response: [String: Any] = [
            "stop_reason": "end_turn",
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": inner]],
        ]
        let s = try ClaudeSummarizer.parse(JSONSerialization.data(withJSONObject: response))
        #expect(s?.gist == "킥오프 일정 조율")
        #expect(s?.bullets == ["할 일: 미팅 확정", "마감: 11/9"])   // checkbox prefix removed
    }

    @Test func refusalGivesNoSummary() throws {
        let response: [String: Any] = ["stop_reason": "refusal", "content": [[String: Any]]()]
        #expect(try ClaudeSummarizer.parse(JSONSerialization.data(withJSONObject: response)) == nil)
    }
}

@Suite struct DiscordTests {
    func file(_ mb: Double) -> DiscordFile {
        DiscordFile(name: "p.png", data: Data(count: Int(mb * 1_000_000)), mimeType: "image/png")
    }

    @Test func batchesRespectCountAndSize() {
        let small = DiscordWebhook.batches((0..<23).map { _ in file(0.3) })
        #expect(small.map(\.count) == [10, 10, 3])
        let big = DiscordWebhook.batches((0..<5).map { _ in file(4) })
        #expect(big.map(\.count) == [2, 2, 1])
    }

    @Test func headerHasMentionSummaryAndFitsLimit() {
        var meta = ClipMeta(id: "20261104-143205", app: "KakaoTalk", bundleID: nil, window: "프로젝트 A", title: "프로젝트 A",
                            capturedAt: Date(), pageCount: 12, screens: 20, seams: 0, sendToDiscord: true)
        meta.summary = ClipSummary(language: "ko", gist: "일정 조율", bullets: ["할 일: 미팅 확정", String(repeating: "가", count: 3000)])
        let text = ClipPublisher.headerText(meta, roleID: "123")
        #expect(text.hasPrefix("<@&123>"))
        #expect(text.contains("🤖 **AI summary**"))
        #expect(text.count <= DiscordWebhook.maxContent)
    }

    @Test func recognizesWebhookURLs() {
        #expect(DiscordWebhook.isValidURL("https://discord.com/api/webhooks/1/abc"))
        #expect(!DiscordWebhook.isValidURL("https://example.com/api/webhooks/1/abc"))
    }
}

@Suite struct ObsidianTests {
    @Test func noteHasFrontmatterSummaryAndNoTasks() {
        var meta = ClipMeta(id: "20261104-143205", app: "KakaoTalk", bundleID: nil, window: "프로젝트 A: 단톡방",
                            title: "프로젝트 A: 단톡방", capturedAt: Date(), pageCount: 2, screens: 3, seams: 0, sendToDiscord: true)
        meta.summary = ClipSummary(language: "ko", gist: "일정 조율", bullets: ["[ ] 할 일: 미팅 확정"])
        let archiver = ObsidianArchiver(root: URL(fileURLWithPath: "/tmp/vault/81 Screen Clips"))
        let note = archiver.render(meta, embeds: ["![[20261104-143205_p01.jpg]]"], transcript: "- [ ] fake task in OCR\n# not a heading")
        #expect(note.hasPrefix("---\ntitle: \"프로젝트 A: 단톡방\""))
        #expect(note.contains("  - \"screen-clips\""))
        #expect(note.contains("- 할 일: 미팅 확정"))
        #expect(!note.contains("- [ ] 할 일"))
        #expect(note.contains("````text\n- [ ] fake task in OCR"))   // OCR text fenced, so no task is created
        #expect(!archiver.noteURL(for: meta).lastPathComponent.contains(":"))
        #expect(archiver.noteURL(for: meta).lastPathComponent.hasSuffix("_KakaoTalk_프로젝트 A 단톡방.md"))
    }

    @Test func archivesImagesAndWritesLinkLater() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ClipStore(root: tmp.appendingPathComponent("clips"))
        let meta = ClipMeta(id: "20261104-143205", app: "Messages", bundleID: nil, window: "Kim", title: "Kim",
                            capturedAt: Date(), pageCount: 1, screens: 1, seams: 0, sendToDiscord: false)
        try FileManager.default.createDirectory(at: store.pagesDirectory(meta.id), withIntermediateDirectories: true)
        try ImageFiles.writePNG(SyntheticChat(seed: 1).screen(at: 0), to: store.pagesDirectory(meta.id).appendingPathComponent("page-001.png"))
        try "hello".write(to: store.transcriptURL(meta.id), atomically: true, encoding: .utf8)
        try store.save(meta)

        let root = tmp.appendingPathComponent("81 Screen Clips")
        let publisher = ClipPublisher(store: store, settings: .init(webhookURL: nil, roleID: nil, archiveRoot: root))
        var m = store.load(meta.id)!
        try awaitResult { try await publisher.publish(&m) }
        #expect(m.archive.done)
        #expect(m.isComplete)
        let jpg = root.appendingPathComponent("_pages/20261104-143205/20261104-143205_p01.jpg")
        #expect(FileManager.default.fileExists(atPath: jpg.path))
        #expect(try Data(contentsOf: jpg).count <= 400_000)
        let note = try String(contentsOf: URL(fileURLWithPath: m.archive.notePath!), encoding: .utf8)
        #expect(note.contains("![[20261104-143205_p01.jpg]]"))
        try ObsidianArchiver(root: root).writeDiscordLink(noteURL: URL(fileURLWithPath: m.archive.notePath!), link: "https://discord.com/channels/1/2")
        let updated = try String(contentsOf: URL(fileURLWithPath: m.archive.notePath!), encoding: .utf8)
        #expect(updated.contains("discord: \"https://discord.com/channels/1/2\""))
    }
}

/// Runs an async throwing closure to completion from a synchronous test.
func awaitResult(_ body: @escaping () async throws -> Void) throws {
    let sem = DispatchSemaphore(value: 0)
    var failure: Error?
    Task { do { try await body() } catch { failure = error }; sem.signal() }
    sem.wait()
    if let failure { throw failure }
}
