# PRD — Screen Clipper

| | |
|---|---|
| Version | 0.5 (refined from `PRD_init.md`; updated with decisions from 2026-11-04 and 2026-11-05) |
| Date | 2026-11-05 |
| Owner | Pilwon |
| Platform | macOS (native menu-bar app) |
| Status | Ready to build: all open questions resolved (see [Decisions](#14-decisions)). Next step: M0 spike. |

---

## 1. Summary

Screen Clipper is a macOS menu-bar app that works with **any app whose content scrolls vertically**. Chat apps such as MS Teams, KakaoTalk, and Messages are just examples. I scroll the app to a starting point, press a hotkey, and drag a box around the content. The app then:

1. scrolls down to the bottom by itself,
2. joins the screenshots into one continuous capture,
3. pulls the text out with on-device OCR,
4. writes a **brief AI summary** (gist, to-dos, key dates) in the conversation's own language,
5. **posts automatically** to a private forum channel on my existing Discord server, one post per clip, and
6. saves a copy as a note in my **Obsidian vault** (`81 Screen Clips/`).

My secretaries open the Discord post to read the summary and the full conversation, reply in the thread, and mark it done.

The core idea: **what you see is what gets captured.** Clipping tools that parse page structure (like the Obsidian Web Clipper) miss content. Screenshots don't. OCR text and the AI summary sit alongside them for searching, copying, and quick reading.

## 2. Problem

- I do much of my work in chat and collaboration apps (MS Teams, KakaoTalk, Messages, and others). My secretaries cannot access these accounts.
- Today I pass on context by hand: forwarding, retyping, or taking screenshots one at a time. This is slow and things get dropped.
- The Obsidian Web Clipper only works for web pages and loses content (images, dynamically loaded messages, app-only views).
- None of these apps offers one simple way to export a conversation to another person.

## 3. Goals and non-goals

### Goals
- **G1 — Hands-off:** hotkey → select region (or press Enter to reuse the last one) → done. Scrolling, capturing, summarizing, sending, and archiving all happen automatically.
- **G2 — Complete:** every message between the start point and the bottom appears exactly once, with no gaps and no duplicates.
- **G3 — Any app:** works with any app that shows content in a vertically scrolling view. There is no code specific to one app.
- **G4 — Readable on any device:** secretaries can read the clip in Discord on desktop or phone without zooming into one huge image.
- **G5 — Text + images + summary:** images stay visible, the text is copyable and searchable, and a short summary shows what needs doing.
- **G6 — Zero setup for secretaries:** they only need Discord. They install nothing.
- **G7 — Private:** OCR runs on-device. Content goes only to my private Discord channel, my Obsidian vault, and the Claude API (for the summary).

### Non-goals (v1)
- Integrations or exports built for one particular app.
- Apps that ignore synthetic scrolling. This should be rare; v1 shows a clear message instead (C9).
- Getting attachments at original resolution (full-size photos, PDFs, files). If secretaries need the file, I forward it separately.
- A full who-said-what log of the conversation. The transcript is plain OCR text; the AI summary covers the key points.
- Monitoring chats in the background or syncing them automatically. Every capture is started by me.
- Horizontal scrolling, or scrolling upward.
- Windows, iOS, or iPadOS.

## 4. Users

| Role | Who | Needs |
|---|---|---|
| Operator | Me | Fast capture from any app, without babysitting the process. A searchable copy in Obsidian. |
| Readers | Secretaries (on Discord) | A quick summary, the complete record behind it, a way to ask questions and mark items done. Phone-friendly. |

## 5. User flow

### Default (automatic)
```
[Any app]  I scroll to the first message I want to share
     │
     ▼
⌃⌥⌘C (global hotkey)  ──►  Crosshair overlay: I drag a box over the content area
     │                       (the last box used for this app is pre-selected; Enter reuses it)
     ▼
Capture HUD (small floating panel):  "Capturing… 14 screens"   [Stop]  (Esc = stop)
     │   the app scrolls, waits for the view to settle, and captures, until it reaches the bottom
     ▼
Processing (automatic): stitch → split into pages → OCR → AI summary
     ▼
HUD: "Sending to Discord in 3 s…"   [Cancel]  [Review]
     ▼
Posted ✓  → macOS notification with "Open in Discord" · note saved to Obsidian
```

To add a note for the secretaries, I reply in the clip's Discord thread myself, or I use review mode.

### Review mode (optional)
Opened with ⌃⌥⌘⇧C instead of the normal hotkey, or by clicking [Review] during the countdown. It opens a Review window before sending:
- Title (pre-filled: "<App> · <window title> · <date time>")
- Note to secretaries
- AI summary (editable)
- Page previews: trim the start/end, delete a page, redact a box
- OCR text preview
- Buttons: [Save only]  [Send to Discord]

## 6. Functional requirements

Priority: **P0** = MVP, **P1** = soon after MVP, **P2** = later.

### 6.1 Trigger and region selection
| ID | Requirement | Pri |
|---|---|---|
| R1 | Menu-bar icon and a global hotkey (configurable) start a capture. A second hotkey starts a capture in review mode. | P0 |
| R2 | Crosshair overlay to drag a rectangle on any display. Show its size in pixels. | P0 |
| R3 | Remember the last region for each app (bundle ID + window) and offer it as the default. Pressing Enter reuses it. | P0 |
| R4 | Fill in the frontmost app's name and window title automatically for labeling. This works for any app. | P0 |

### 6.2 Auto-scroll and capture
| ID | Requirement | Pri |
|---|---|---|
| C1 | Capture the region at native (Retina) resolution. | P0 |
| C2 | Scroll down with synthetic scroll-wheel events aimed at the selected region. Each step is about 60–70% of the region height, so consecutive frames overlap. | P0 |
| C3 | After each scroll, wait until two consecutive frames are identical before capturing. This handles smooth scrolling, momentum, and loading spinners. Time out after about 2 s. | P0 |
| C4 | **Bottom detection:** stop when 2 scrolls in a row produce no change. | P0 |
| C5 | **Check-in limits, not hard stops:** captures are usually short but occasionally very long. When the capture reaches 300 screens or 5 min (configurable), the HUD asks [Continue] [Stop & send]. With no answer within 10 s, it stops and sends. | P0 |
| C6 | Esc or [Stop] ends the capture and keeps everything captured so far. | P0 |
| C7 | Before each scroll, park the cursor in a safe spot inside the region (for example, the left padding). This keeps scroll events going to the right view and avoids hover toolbars (many chat apps show reaction bars on hover). | P0 |
| C8 | If I move the mouse or switch apps during the capture, pause and ask whether to resume or stop. | P1 |
| C9 | If the first scroll doesn't move the view, stop and show: "This app didn't scroll. Click once inside the content and try again." | P0 |
| C10 | Fallback scroll methods for apps that ignore wheel events (Page Down key, or the Accessibility scroll bar value). | P2 |

### 6.3 Stitching
| ID | Requirement | Pri |
|---|---|---|
| S1 | Measure the exact vertical shift between consecutive frames by matching image rows (not by trusting the scroll amount), then add only the new strip. | P0 |
| S2 | Detect **fixed elements**: rows that stay identical at the same position while the content moves (sticky date headers, "new messages" banners, the input box if it was included in the selection). Leave them out of the match and out of the added strips. | P0 |
| S3 | Ignore a narrow strip on the right edge (about 20 pt) when matching, because the macOS overlay scrollbar appears there during scrolling. | P0 |
| S4 | If the match confidence is low, retry with a smaller scroll step. If it is still low, mark the seam in the output ("⚠ possible gap here") instead of failing silently. | P0 |
| S5 | **Pagination:** split the stitched image into pages about 1–1.5× the screen height. Cut only on blank rows (the gaps between messages), never through a line of text. | P0 |
| S6 | **Build pages as the capture goes:** write each finished page to disk and keep only the current page in memory. Never hold the full stitched image, so very long captures don't run out of memory. | P0 |

### 6.4 Text extraction (OCR)
| ID | Requirement | Pri |
|---|---|---|
| T1 | Run on-device OCR on each page with Apple Vision (`VNRecognizeTextRequest`, accurate mode, languages `ko-KR` + `en-US`). | P0 |
| T2 | Produce a transcript with the text in reading order and a `--- page N ---` marker matching each page image. | P0 |
| T3 | Keep layout hints in a simple form: if text sits mostly on the right side (usually my own messages), prefix it with `→`. | P2 |

### 6.5 AI summary
| ID | Requirement | Pri |
|---|---|---|
| AI1 | After OCR, send the page images and transcript to the Claude API. Get back a **brief** summary: a one-line gist, to-dos for the secretaries (what, for whom, by when), and key dates or decisions. At most about 5 bullets and 800 characters. For long clips (more than about 50 pages), send only the transcript to keep cost and request size reasonable. | P0 |
| AI2 | Use only what is in the clip; never invent names, dates, or tasks. Mark unclear items with "(?)". Label the summary "AI summary" so secretaries know a machine wrote it. | P0 |
| AI3 | Always write the summary in the **conversation's original language**. If the conversation mixes languages, use the main one. | P0 |
| AI4 | **Best-effort:** if the API fails, times out (about 30 s), or declines the request, post without a summary and add "(summary unavailable)". The summary never blocks delivery. | P0 |
| AI5 | On/off switch in Settings (default on). | P0 |
| AI6 | Turn the summary on or off per app. | P2 |

### 6.6 Sending
| ID | Requirement | Pri |
|---|---|---|
| U1 | **Auto-send:** post to Discord as soon as processing finishes (default on). | P0 |
| U2 | **Cancel window:** the HUD counts down before sending (default 3 s; 0 = send immediately), with [Cancel] (keep the local copy, don't send) and [Review]. | P0 |
| U3 | **Review mode:** Review window with title, note, editable summary, page thumbnails, OCR text, and trim / delete page. | P1 |
| U4 | **Redaction** in review mode: draw boxes to black out sensitive areas. The redaction applies to both the images and the OCR text (and the summary is regenerated). | P1 |
| U5 | **Recall last clip:** a menu item that deletes the clip's Discord messages through the webhook. I delete the empty forum post in Discord myself. | P1 |

### 6.7 Discord delivery
| ID | Requirement | Pri |
|---|---|---|
| D1 | Post through a **Discord webhook** to a **forum channel**. Each clip becomes a new forum post (`thread_name` = `[<App>] <title> · <date time>`). | P0 |
| D2 | Post layout: see §7. The AI summary goes at the top of the first message. Images are sent in batches of at most 10 per message, and each message stays under Discord's upload limit. A long clip simply becomes more messages in the same post. | P0 |
| D3 | Paste the first ~1,900 characters of the transcript inline, because Discord search indexes message text but not attachments. Attach the full transcript as `transcript.md`. | P0 |
| D4 | Retry queue: if posting fails (offline, rate-limited), keep the clip in `~/Library/Application Support/Screen Clipper/queue/` and retry with backoff. Show the status in the menu-bar menu. | P0 |
| D5 | After a successful post, show a notification with an "Open in Discord" link. It is built from the message returned by `?wait=true`. | P0 |
| D6 | **@mention the `Secretary` role** once per clip (in the first message only), so secretaries get a push notification. Use the role ID from Settings, and limit mentions to that role with `allowed_mentions`. Default on. | P0 |
| D7 | Apply forum tags automatically (for example "To-do"). This needs tag IDs, which may require a bot instead of a webhook. | P2 |

### 6.8 Obsidian archive
| ID | Requirement | Pri |
|---|---|---|
| A1 | Save every clip into my Obsidian vault under a **separate folder, `81 Screen Clips/`**, next to `80 Clippings` (which the Web Clipper uses) but separate from it. Write plain files; Obsidian picks them up automatically and no plugin is needed. | P0 |
| A2 | **One note per clip**, with frontmatter + AI summary + embedded page images + transcript (template below). Use the same frontmatter keys as the Web Clipper notes (`title`, `created`, `tags`, `read`) so clips work with the vault's existing `read: true` workflow. Tag the notes `screen-clips`, not `clippings`. | P0 |
| A3 | File naming follows the Web Clipper pattern: `YYYY-MM-DD_HH-MM-SS_<App>_<title>.md`. Remove characters Obsidian doesn't allow in file names (`\ / : * ? " < > \| # ^ [ ]`). | P0 |
| A4 | Store page images in `81 Screen Clips/_pages/<clip-id>/`, with file names unique across the vault (`<clip-id>_p01.jpg`) so that `![[…]]` embeds never resolve to another clip's image. | P0 |
| A5 | Compress the vault copies of the images (JPEG or similar, about 85% quality, target ≤ ~400 KB per page), because the vault syncs through iCloud and possibly Obsidian Sync. Discord still gets full-quality PNGs. | P0 |
| A6 | On first run, create the index note `81 Screen Clips/810. Screen Clips MOC.md` following the vault's index-note convention (`moc_purpose`, `moc_contents`, `moc_keywords` frontmatter) with Dataview lists: unread / read / all. | P1 |
| A7 | Write to-dos in the summary as plain bullets, **not** `- [ ]` checkboxes, so they don't show up in my Tasks plugin queries (they are the secretaries' tasks, not mine). | P0 |
| A8 | The archive location is configurable (default above). | P0 |
| A9 | **Image retention: 90 days.** Move page images older than 90 days to the macOS Trash (so they can still be recovered), and keep the notes forever. Replace the note's "Pages" section with "Page images removed after 90 days — see the Discord post" plus the link, so no broken image embeds are left. Runs once a day; the number of days is configurable. | P1 |

Vault layout:
```
<vault>/
├── 80 Clippings/                      ← Web Clipper (unchanged)
└── 81 Screen Clips/                   ← new, Screen Clipper only
    ├── 810. Screen Clips MOC.md       ← Dataview index (A6)
    ├── 2026-11-04_14-32-05_KakaoTalk_프로젝트 A 단톡방.md
    └── _pages/
        └── 20261104-143205/
            ├── 20261104-143205_p01.jpg
            └── …
```

Note template:
```markdown
---
title: "프로젝트 A 단톡방"
source_app: "KakaoTalk"
window: "프로젝트 A 단톡방"
created: 2026-11-04
captured: 2026-11-04T14:32:05+09:00
pages: 12
discord: "https://discord.com/channels/…"
tags:
  - "screen-clips"
read:
---

## AI summary
프로젝트 A 킥오프 미팅 일정 조율 중
- 할 일: 김OO 팀장과 11/10–11/12 중 미팅 시간 확정
- 마감: 발표자료 초안 11/9(일)까지

## Pages
![[20261104-143205_p01.jpg]]
![[20261104-143205_p02.jpg]]
…

## Transcript
--- page 1 ---
…
```

### 6.9 Settings
Hotkeys · Discord webhook URL (stored in the Keychain) · Anthropic API key (stored in the Keychain) · auto-send on/off and countdown length · AI summary on/off · archive folder (default `<open vault>/81 Screen Clips`) · OCR languages · check-in limits · image retention (default 90 days) · `Secretary` role ID (for @mentions).

First-run setup: grant Screen Recording and Accessibility → paste the webhook URL and the `Secretary` role ID → paste the Anthropic API key → confirm the archive folder → send a test post (it should ping the secretaries).

## 7. What secretaries see in Discord

One-time setup (about 5 minutes, done by me in my **existing Discord server**):

1. Create a **Forum** channel `#clips`. Make it private: visible only to me and a `Secretary` role.
2. Go to Channel settings → Integrations → Webhooks → New Webhook → Copy URL, and paste the URL into Screen Clipper's Settings.
3. Copy the `Secretary` role's ID and paste it into Settings. To do this, turn on User Settings → Advanced → Developer Mode, then open Server Settings → Roles → `Secretary` → ⋯ → Copy Role ID. If pings don't arrive, turn on "Allow anyone to @mention this role" for that role.
4. (Optional) Create forum tags `To-do` and `Done`. App names don't need tags: they already appear in each post title, and clips can come from any app.

Each clip shows up like this:

```
#clips (Forum)
└─ 📌 [KakaoTalk] 프로젝트 A 단톡방 · 11/04 14:32          ← one forum post per clip
   ┌ Screen Clipper (webhook) ───────────────────────────────
   │ @Secretary                                 ← one push notification per clip
   │ 🤖 AI summary
   │ 프로젝트 A 킥오프 미팅 일정 조율 중
   │ • 할 일: 김OO 팀장과 11/10–11/12 중 미팅 시간 확정
   │ • 마감: 발표자료 초안 11/9(일)까지
   │ • 결정: 장소는 본사 3층 회의실
   │ Source: KakaoTalk · 12 pages · captured 2026-11-04 14:32
   │ [page-01] [page-02] … [page-10]          (images, ≤10 per message)
   ├──────────────────────────────────────────────────────────
   │ [page-11] [page-12]
   ├──────────────────────────────────────────────────────────
   │ 📄 transcript.md
   │ > first ~1,900 chars of OCR text (so Discord search finds it)
   └──────────────────────────────────────────────────────────
   Me: 이건 오늘 중으로 부탁해요                 ← my optional note, as a thread reply
   Secretary A: 미팅 11/12 10시로 잡았습니다 ✅
```

Why this design:
- **Webhook rather than a bot:** no server or code to host. It's a single URL. The trade-off is that it can only post, not read, but posting is all v1 needs.
- **Forum channel rather than a regular channel:** each clip is its own thread. Secretaries can reply, ask questions, and tag a clip `Done` without the clips getting mixed together. Titles can be searched and browsed, and the layout works well on the Discord phone app.
- **Summary first:** the forum post preview shows the start of the first message, so secretaries see the gist and to-dos without opening the images.
- **Pages rather than one tall image:** Discord shrinks very tall images into unreadable thumbnails. Screen-sized pages are readable on a phone.

## 8. Technical approach

| Area | Choice | Notes |
|---|---|---|
| Language/UI | Swift + SwiftUI, `MenuBarExtra` app | Native, small, no runtime dependencies. |
| Min OS | macOS 14+ | Needed for the ScreenCaptureKit screenshot API. |
| Screen capture | ScreenCaptureKit (`SCScreenshotManager`) | `CGWindowListCreateImage` is deprecated or removed on current macOS. |
| Scrolling | `CGEvent` scroll-wheel events, pixel units | Needs **Accessibility** permission. Works the same way in any app, with no app-specific code. |
| Cursor parking | `CGWarpMouseCursorPosition` | Restore the original cursor position when finished. |
| Stitching | Row-signature matching (per-row hash or luminance profile), searched over the plausible offset range, with a confidence score | Fixed-element mask (S2), scrollbar strip excluded (S3), pages written as the capture goes (S6). |
| OCR | Vision `VNRecognizeTextRequest` | Runs on-device. Korean is supported. |
| AI summary | Claude API `POST /v1/messages` over HTTPS with `URLSession` (there is no official Swift SDK). Model `claude-opus-5-5`, effort `low`. A JSON-schema structured output (`language`, `gist`, `todos[]`, `dates[]`, `decisions[]`) is turned into Discord markdown and Obsidian markdown. | Server-side fallback is on (`fallbacks: "default"`, beta header `server-side-fallback-2026-07-01`). Check `stop_reason` before reading the result: `refusal` → post without a summary (AI4). |
| Discord | `URLSession` multipart POST to the webhook. Use `?wait=true` for the first post, then `?thread_id=` for later messages in the same post | Respect `429` rate limits (`retry_after`). |
| Obsidian | Plain file writes into the vault folder (iCloud Drive path) | No Obsidian plugin or API needed. |
| Secrets | Webhook URL and Anthropic API key kept in the macOS Keychain | Both work like passwords. |
| Distribution | Personal build, signed locally (no App Store) | App Store sandboxing would block synthetic input events. |

**Permissions needed on first run:** Screen Recording (for capture) and Accessibility (for scrolling). The app checks both and links straight to the matching System Settings pane. macOS may ask to re-confirm Screen Recording from time to time.

**Expected speed:** about 0.3–0.6 s per screen (scroll + settle + capture). A 100-screen conversation takes about 1 minute, plus about 5–20 s for the summary.

**Expected summary cost:** a few cents to about $0.20 per typical clip (Opus 5.5 costs $4 per million input tokens and $20 per million output tokens; page images make up most of the input). For long clips, only the text is sent (AI1), which keeps the cost bounded. Measure during M1.

## 9. Edge cases and risks

| Risk | Impact | Mitigation |
|---|---|---|
| Smooth scrolling / momentum makes frames blur or shift | Bad stitch | Wait for identical consecutive frames before capturing (C3). Use pixel-unit events with no momentum phase. |
| Sticky headers, floating "jump to latest" buttons, unread banners | Duplicated or garbled strips | Fixed-element detection (S2). Advise selecting only the content area, without the input box or sidebar. |
| Hover toolbars and tooltips | UI noise in the capture | Park the cursor (C7). |
| An app ignores synthetic scroll events | Nothing captured | Detect it on the first scroll and show a clear message (C9). Fallback methods later (C10). |
| New messages arrive during the capture | Content shifts | Accept it. The bottom check still stops the capture. Matching handles small changes. |
| Lazy loading shows spinners or placeholders | Blank areas captured | The settle wait (C3) times out after about 2 s. Mark low-confidence seams (S4). |
| Repeated identical content (e.g. the same sticker sent many times) | Wrong offset match | Limit the offset search to the expected range around the requested scroll step. Check confidence. |
| Rare very long capture | Memory, file size, many Discord messages | Check-in limits (C5). Pages written as the capture goes (S6). Summary from text only (AI1). Discord batching (D2). |
| Discord upload limit (10 MB per message on non-boosted servers as of 2025; check during implementation) | Post fails | Keep each message under the limit. Use PNG, and fall back to high-quality JPEG for photo-heavy pages. |
| Vault growth (images sync through iCloud, and Obsidian Sync if used) | Storage and sync slowdowns | Compressed vault images (A5). 90-day image retention (A9). Optionally exclude `81 Screen Clips/_pages` in Obsidian Sync settings. |
| OCR mistakes on mixed Korean/English text, emoji, or stylized fonts | Slightly wrong text | Images are the source of truth. The text is a convenience for search and copy. |
| **Auto-send posts the wrong thing** (wrong region, sensitive content) | Unwanted content in Discord | Cancel window (U2). Recall (U5). Discord lets me delete any post in my server. |
| **AI summary is wrong or misses something** | Secretary acts on bad info | Labeled "AI summary". The rule against inventing anything (AI2). The images and transcript sit right below for checking. |
| Claude API down or slow | Delayed post | 30 s timeout, then post without a summary (AI4). |
| Region spans two displays, or the displays use different scaling | Capture errors | v1: limit the region to one display. |

## 10. Privacy and security

- **Where content goes:**
  - My Obsidian vault, which syncs through iCloud and through Obsidian Sync if that is in use.
  - My private Discord channel. Discord is a third-party service and messages are not end-to-end encrypted. The channel must be private (only me and the `Secretary` role), and all members should use 2FA.
  - The Claude API, for the summary only. Under Anthropic's commercial API terms, API inputs aren't used for model training by default. The summary can be turned off at any time (AI5).
- **MS Teams content:** confirmed OK to share over Discord (decision 2026-11-04).
- **Other people's messages:** clips contain messages from third parties. Use the cancel window or review mode (trim, redact) when a clip includes content the secretaries don't need.
- **OCR runs on-device.** Text extraction never leaves the Mac.
- **Credentials:** the webhook URL and the Anthropic API key are stored in the Keychain and never written to logs, the vault, or the queue. If either leaks, regenerate it (in Discord or the Anthropic Console).

## 11. Alternatives considered

| Option | Why not (as the main approach) |
|---|---|
| Obsidian Web Clipper / DOM-based clipping | Web pages only. It already missed content in practice. |
| Accessibility (AX) text extraction | Gives exact text, but support differs widely between apps and there are no images. → Possible P2 improvement: use AX text where available and fall back to OCR. |
| App-specific exports (KakaoTalk "대화 내보내기", Messages `chat.db`, Teams Graph API) | Higher quality but needs separate work for each app, and the tool must work with any app (decision 2026-11-05). Not planned. |
| Discord bot instead of webhook | Needs a hosted process and a token. Only worth it for auto-tagging (D7) or reading secretary replies. |
| Shared Dropbox folder instead of Discord | Simple, but there's no notification, no discussion thread, and no "done" status. |
| Saving clips into `80 Clippings` | Would mix clips with web clippings and their Dataview lists. A separate folder was requested. |
| Summary from text only (no images) | Cheaper, but OCR text loses who said what (bubble side, names, avatars). Images + text gives a better summary for a few more cents. Text only is still used for long clips. |

## 12. Milestones

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0 — Spike** (1–2 days) | Command-line prototype: fixed region → scroll/capture loop → stitch → pages on disk. Test on Teams, KakaoTalk, Messages, and at least 2 other kinds of app (e.g. a browser page, Slack). | Stitched output of 20+ screens with no gaps or duplicates in all tested apps. *This is the riskiest part, so prove it first.* |
| **M1 — MVP** | Menu-bar app, hotkeys, region select + memory, HUD with check-in limits, pagination, OCR, AI summary, auto-send with cancel window, webhook posting to a forum with a `Secretary` @mention, notification link, Obsidian note + images, retry queue. | Acceptance tests in §13 pass. |
| **M2 — Polish** | Review mode (U3), redaction (U4), recall (U5), pause on user input (C8), MOC index note (A6), 90-day image retention (A9). | Used every day for 1 week without manual fixes. |
| **M3 — Optional** | Fallback scroll methods (C10). AX text extraction. Auto-tagging through a bot. Per-app summary settings. | Decide after M2 based on what the secretaries say. |

## 13. Success criteria (acceptance tests)

1. **Completeness:** In Teams, KakaoTalk, Messages, and at least 2 other kinds of app, a capture of 20+ screens contains every message exactly once (checked manually against the app).
2. **Clean output:** No hover toolbars, scrollbars, or repeated sticky headers inside the stitched content.
3. **Effort:** 2 user actions from start to Discord post (hotkey → drag, or hotkey → Enter). No further input needed.
4. **Speed:** A 20-screen capture finishes in under 30 s. Summary and posting together finish in under 45 s on a normal connection.
5. **Long capture:** A 500-screen capture finishes with stable memory use. It posts correctly across multiple Discord messages and gets a text-only summary.
6. **Readability:** A secretary can read every page on the Discord phone app without pinch-zooming.
7. **OCR:** At least 95% of lines in a mixed Korean/English sample are correct.
8. **Summary quality:** On a spot-check of 10 real clips, the summary is in the conversation's language, the to-dos match what I would have told the secretaries, and nothing is invented.
9. **Obsidian:** Each clip appears in `81 Screen Clips/` as one note that shows its images and summary, is found by vault search, and does not add tasks to my Tasks queries.
10. **Reliability:** If the network is down, the clip is kept and posted automatically once the network comes back. If the Claude API fails, the clip is still posted and archived, just without a summary.
11. **Notification:** Each new clip sends exactly one push notification to the secretaries, however many messages the post has.
12. **Retention:** For a clip older than 90 days, the page images are in the macOS Trash, and the note still opens and links to the Discord post.

## 14. Decisions

| Date | Decision |
|---|---|
| 2026-11-04 | Use my **existing Discord server**, with a new private forum channel `#clips`. |
| 2026-11-04 | Sharing **MS Teams content over Discord is allowed**. |
| 2026-11-04 | **Auto-send** is the default. Review mode is optional. |
| 2026-11-04 | Add a **brief AI summary** to each clip (Claude API, on by default, can be switched off). |
| 2026-11-05 | I already have an **Anthropic API key**. It is pasted into Settings during first-run setup. |
| 2026-11-05 | The summary is always in the **conversation's original language**. |
| 2026-11-05 | Captures are usually short but **occasionally very long**. Limits are check-ins, not hard stops, and long captures must be handled gracefully. |
| 2026-11-05 | Archive to the **Obsidian vault** in a separate folder, **`81 Screen Clips/`**. |
| 2026-11-05 | The tool must work with **any app** that scrolls vertically. Teams, KakaoTalk, and Messages are only examples. |
| 2026-11-05 | **@mention the `Secretary` role** on each new clip. |
| 2026-11-05 | Keep page images in the vault for **90 days**; keep notes forever. |

## 15. Open questions

None right now. Next step: the M0 spike (§12), which tests the scroll-and-stitch approach in real apps.
