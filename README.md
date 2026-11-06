# Screen Clipper

**Capture a whole scrolling conversation from any Mac app with one shortcut, and hand it to someone else
through Discord, with an AI summary and a searchable copy in Obsidian.**

Screen Clipper is a small macOS menu-bar app. You scroll a chat (MS Teams, KakaoTalk, Messages, Slack, a web
page, anything that scrolls vertically) to where you want to start, press a hotkey and drag a box over the
content. The app then:

1. **scrolls to the bottom by itself**, taking screenshots as it goes,
2. **stitches** them into one continuous capture (no gaps, no duplicates, no repeated toolbars),
3. **reads the text** on-device with Apple Vision OCR (Korean + English),
4. writes a **brief AI summary** (gist, to-dos, dates) in the conversation's own language with Claude,
5. **posts it to a Discord forum channel** (one post per clip, pinging a role), and
6. **saves a note in your Obsidian vault** with the summary, page images and full transcript.

It was built so that assistants who don't have access to someone's chat accounts can still see exactly what
was said: **what you see on screen is what gets captured**, unlike clipping tools that parse page structure
and miss content.

> Status: v0.1 (milestones M0 + M1 of [`PRD.md`](PRD.md)). The stitching engine is tested pixel-exact on
> synthetic chats; real-world testing across apps is ongoing. macOS 14+ only.

---

## Contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Setup](#setup)
- [Usage](#usage)
- [What gets produced](#what-gets-produced)
- [Settings reference](#settings-reference)
- [Privacy and security](#privacy-and-security)
- [How the stitching works](#how-the-stitching-works)
- [Project layout](#project-layout)
- [Development](#development)
- [Troubleshooting](#troubleshooting)
- [Limitations and roadmap](#limitations-and-roadmap)
- [License](#license)

---

## Features

- **Works with any app** that shows content in a vertically scrolling view, with no app-specific code.
- **One shortcut** (default **⌃⌥⌘C**): drag a region, or press **Enter** to reuse the last region for that
  app (remembered relative to the app's window, so it follows the window when it moves).
- **Automatic scrolling and capture**: synthetic scroll events, waiting for animations and fading scrollbars
  to settle before each screenshot.
- **Clean stitching**: fixed headers, input boxes and floating "jump to latest" buttons are detected and
  left out of the middle of the capture; scrollbars are ignored when matching.
- **Readable pages**: the long capture is split into screen-sized pages, cut only on blank rows between
  messages, so pages are readable on a phone and no text line is split.
- **On-device OCR** (Apple Vision, `ko-KR` + `en-US`), with a transcript per page.
- **AI summary** with Claude (`claude-opus-5-5`): one-line gist plus up to 5 labeled bullets (to-do,
  deadline, decision…), in the conversation's language. Best-effort: if it fails, the clip is posted anyway.
- **Discord delivery** through a webhook (no bot to host): a new forum post per clip, a role @mention, the
  summary first, page images in batches, and the transcript (inline excerpt + full `.md` attachment).
- **Auto-send** with a short cancel window (default 3 s).
- **Obsidian archive**: one note per clip with frontmatter, summary, embedded page images (compressed) and
  the full transcript, in a separate folder (default `<vault>/81 Screen Clips/`).
- **Retry queue**: if Discord can't be reached, clips wait locally and are posted automatically (backoff,
  and immediately when the network comes back). Posting resumes where it stopped.
- **Long captures**: pages are written to disk as the capture runs (constant memory). At a limit (default
  300 screens / 5 min) the app asks whether to continue instead of stopping silently.
- **Secrets in the Keychain**, never in files or logs.

## How it works

```
 Hotkey ──► drag region ──► scroll + screenshot loop ──► stitch ──► pages (PNG)
                                   │                                     │
                                   └─ waits for each screen to settle    ▼
                                                               OCR (Vision, on-device)
                                                                         │
                                                                         ▼
                                                        AI summary (Claude API, optional)
                                                                         │
                                                       3 s cancel window │
                                         ┌───────────────────────────────┴──────────────┐
                                         ▼                                              ▼
                          Obsidian note + images                         Discord forum post (webhook)
                       (<vault>/81 Screen Clips/)                 summary · @role · pages · transcript
```

Clips are staged in `~/Library/Application Support/Screen Clipper/clips/<id>/` (pages, transcript,
`meta.json` with progress) and deleted once they are archived and posted.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon or Intel.
- Xcode 16+ (Swift 5.10+ toolchain) to build.
- A Discord server where you can create a channel and a webhook.
- Optional: an Anthropic API key for the AI summary.
- Optional: Obsidian (any folder works as the archive).

## Install

```bash
git clone https://github.com/pilwonhur/screen-clipper.git
cd screen-clipper

# Recommended once: a local code-signing certificate, so macOS keeps the app's permissions across rebuilds.
./scripts/make_signing_cert.sh

# Build and install to ~/Applications/Screen Clipper.app
./scripts/build_app.sh
```

Build files go to `~/Library/Caches/ScreenClipper/build` (handy if the source folder is synced by
Dropbox/iCloud). Override with `SCRATCH=…`, the install folder with `DEST=…`, and the signing identity
with `SIGN_IDENTITY=…`.

**About signing:** the app is not notarized. Without a stable signing identity (ad-hoc signing), every
rebuild looks like a new app to macOS and you must re-grant Screen Recording and Accessibility.
`make_signing_cert.sh` creates a self-signed certificate called "Screen Clipper Dev" in your login keychain
(used only to sign this app; delete it in Keychain Access any time). It shows as "not trusted"; that is
expected and fine for local signing.

## Setup

### 1. Permissions

Open **Screen Clipper** from `~/Applications` (menu-bar icon: a viewfinder). Then, in **System Settings →
Privacy & Security**:

- **Screen Recording** → add/enable Screen Clipper (to take screenshots).
- **Accessibility** → add/enable Screen Clipper (to send scroll events).

The app is in your *home* Applications folder: in the **+** file picker press **⌘⇧G** and type
`~/Applications`. Quit and reopen the app after granting Screen Recording. Check in **Settings →
Permissions → Refresh**.

### 2. Discord

1. In your server, create a **Forum** channel (e.g. `#clips`) and make it private to you and the readers.
2. **Webhook:** Edit Channel → Integrations → Webhooks → New Webhook → **Copy Webhook URL**. One webhook
   for this one channel is all you need.
3. **Role to ping (optional):** create a role (e.g. `Secretary`), give it to the readers and allow it to
   view the channel. Turn on User Settings → Advanced → **Developer Mode**, then Server Settings → Roles →
   ⋯ → **Copy Role ID**. If pings don't arrive, enable "Allow anyone to @mention this role".
4. *(Optional)* Forum tags such as `To-do` / `Done` for readers to track progress.

A regular text channel also works: the app detects it and posts plain messages with the title in bold.

### 3. Anthropic API key (optional, for summaries)

console.anthropic.com → Settings → Billing (API usage is billed separately from a Claude subscription) →
Settings → API Keys → Create Key. Expect roughly a few cents to $0.20 per clip; you can set a monthly limit
under Settings → Limits.

### 4. Screen Clipper settings

Menu-bar icon → **Settings…**

- **Webhook URL**: click **Paste** (or ⌘V), then **Send test post**. A post "Screen Clipper test" should
  appear and ping the role.
- **Secretary role ID**: paste the role ID.
- **Anthropic API key**: click **Paste**.
- **Obsidian archive**: defaults to `<currently open vault>/81 Screen Clips` (read from Obsidian's own
  vault list); choose any folder.

## Usage

1. Scroll the app to the **first message** you want to share.
2. Press **⌃⌥⌘C** (or menu → **Capture Region**).
3. Drag a box over the **scrolling content only** (leave out sidebars if you can; the input box is fine),
   or press **Enter** to reuse the yellow dashed region from last time. **Esc** cancels.
4. **Keep the mouse still.** The status panel shows "Capturing… N screens". **Esc** or **Stop** ends early
   and keeps what was captured.
5. After OCR and the summary, it shows "Sending to Discord in 3 s…" with **Cancel** (keep it in Obsidian
   only) and **Send now**.
6. A notification confirms the post; click it to open the post in Discord.

To add a note for the readers, reply in the Discord post yourself.

Menu-bar menu: **Capture Region**, pending posts and **Retry Now**, **Open Clips Folder**, **Settings…**,
**Open Log**, **Quit**.

## What gets produced

### Discord (forum channel)

```
#clips
└─ [KakaoTalk] Project A group chat · 11/04 14:32         ← one forum post per clip
   @Secretary
   🤖 AI summary
   Scheduling the Project A kickoff
   • To-do: confirm a meeting time with Kim between 11/10 and 11/12
   • Deadline: draft slides by Sun 11/9
   -# Source: KakaoTalk · 12 pages · captured 2026-11-04 14:32
   [page-01.png] … [page-10.png]        (≤ 10 images and ≤ 9 MB per message)
   [page-11.png] [page-12.png]
   📄 Transcript (excerpt; full text attached)  + transcript.md
```

The summary comes first because the forum list previews the first message. The transcript excerpt is
inline because Discord search indexes message text, not attachments.

### Obsidian

```
<vault>/81 Screen Clips/
├── 2026-11-04_14-32-05_KakaoTalk_Project A group chat.md
└── _pages/20261104-143205/20261104-143205_p01.jpg …     (JPEG, ≤ ~400 KB each)
```

```markdown
---
title: "Project A group chat"
source_app: "KakaoTalk"
window: "Project A group chat"
created: 2026-11-04
captured: 2026-11-04T14:32:05+09:00
pages: 12
clip_id: "20261104-143205"
discord: "https://discord.com/channels/…"
tags:
  - "screen-clips"
read:
---

## AI summary
…plain bullets (never `- [ ]`, so they don't show up in Tasks plugin queries)

## Pages
![[20261104-143205_p01.jpg]]
…

## Transcript
````text
--- page 1 ---
…OCR text (fenced, so it can't turn into headings or tasks)
````
```

## Settings reference

| Setting | Default | Notes |
|---|---|---|
| Webhook URL | — | Keychain. Must be a `discord.com/api/webhooks/…` URL. |
| Secretary role ID | empty | Pinged once per clip (first message only). Only this role can be mentioned. |
| AI summary | on | Uses the Anthropic API key (Keychain). |
| Send automatically | on | Off = ask "Send / Save only" after each capture. |
| Cancel window | 3 s | 0 = send immediately. |
| Obsidian archive | `<open vault>/81 Screen Clips` | Any folder. |
| Shortcut | ⌃⌥⌘C | Click to record a new one (needs ⌘, ⌥ or ⌃). |
| Check in after | 300 screens / 5 min | Asks Continue / Stop & send; stops after 10 s without an answer. |

## Privacy and security

- **Where content goes:** your Mac (staging + Obsidian folder), your Discord channel, and, only for the
  summary, the Claude API (page images + OCR text). OCR itself runs on-device. Turn the summary off to keep
  everything except the Discord post local.
- **Discord is not end-to-end encrypted.** Use a private channel, and 2FA for its members.
- **Secrets** (webhook URL, API key) are stored in the macOS Keychain and never written to logs, clips or
  the archive. Anyone with the webhook URL can post to the channel: regenerate it in Discord if it leaks.
- **Mentions are restricted**: `allowed_mentions` permits only the configured role, so text captured from
  a chat can never ping `@everyone` or other users.
- **Third-party messages:** clips contain other people's messages. Use the cancel window when a capture
  includes something the readers don't need, and check your organization's policy before sharing work
  chats.
- **Logs** (`~/Library/Logs/ScreenClipper.log`) contain app names, window titles, and capture statistics,
  not message content.

## How the stitching works

The hard part is joining screenshots of a view that scrolls by an unknown amount, with fixed UI on top.

1. **Row signatures.** Each screenshot row is reduced to 64 blocks × (mean luminance, mean horizontal
   gradient). A right-edge strip (~20 pt) is ignored because of overlay scrollbars.
2. **Shift matching** (`ShiftMatcher`). For every candidate shift *d*, rows of the new frame are compared
   with rows *d* lower in the previous frame, **per block**: flat-and-equal blocks carry no information and
   are skipped; the rest agree or disagree. The score is the fraction of disagreeing blocks, so a small
   overlay (a floating button) can't spoil a match. Clearly wrong shifts are abandoned early. If another
   shift fits almost as well, the match is *ambiguous* and the expected shift (from the requested scroll
   distance) breaks the tie.
3. **Fixed bands** (`StitchAssembler`). Each frame is modeled as a fixed header, a scrolling viewport and a
   fixed footer. Bands are found from rows identical in place across frames, and from textured blocks that
   stay put while the content moves (in vertical runs, connected to the screen edge). Bands only grow, plus
   a margin: over-estimating a band is harmless (content just arrives in a later frame), under-estimating
   would repeat UI.
4. **Assembly.** Output = the first frame down to its footer, then only the new rows of each frame, then the
   rest of the last frame. If two frames can't be matched even after backing up half a step, a red dashed
   **gap marker** is inserted rather than guessing.
5. **Capture loop** (`CaptureSession`). Scrolls about 60% of the trusted viewport per step (adapting to how
   far the app actually scrolls), waits until two consecutive screenshots are identical, detects the scroll
   direction, tries other cursor positions if nothing moves, and stops after two scrolls with no change.
6. **Pagination** (`Paginator`). Cuts pages at about 1.2 × the screen height, at the middle of the nearest
   run of blank rows.

The test suite renders a synthetic chat (Korean/English bubbles, avatars, photo blocks, repeated messages,
header, input box, floating button, scrollbar), scrolls it by random amounts unknown to the stitcher, and
checks the result **pixel-for-pixel** against the original.

## Project layout

```
Package.swift
Sources/
  ClipperCore/            library (no UI)
    CaptureSession.swift    scroll → settle → screenshot → stitch loop
    ScreenGrabber.swift     ScreenCaptureKit screenshots, synthetic scroll events
    RowSignatures.swift     per-row block fingerprints
    ShiftMatcher.swift      finds how far content moved
    StitchAssembler.swift   fixed-band detection and assembly
    Paginator.swift         blank-row page cuts
    OCR.swift               Apple Vision text recognition
    ClaudeSummarizer.swift  Claude Messages API (raw HTTPS)
    DiscordWebhook.swift    webhook client (multipart, rate limits, batching)
    ClipPublisher.swift     resumable archive + post steps
    ObsidianArchiver.swift  note + image writer
    ClipStore.swift         staging folder and meta.json
    Keychain.swift, Log.swift, ImageFiles.swift, Frame.swift
    Synthetic.swift         synthetic chat renderer for tests
  ScreenClipper/          menu-bar app (AppKit + SwiftUI)
    main.swift              app delegate, menu
    ClipController.swift    capture → OCR → summary → send flow, retry queue, notifications
    RegionSelector.swift    full-screen selection overlay
    HUD.swift               floating status panel
    Settings.swift          preferences, settings window, permissions
    HotKeys.swift           global shortcuts (Carbon)
    Geometry.swift          coordinate conversion, target window, region memory
  clipper-spike/          command-line test tool
Tests/ClipperCoreTests/   stitching, pagination, OCR, summary parsing, Discord, Obsidian
Resources/Info.plist
scripts/build_app.sh, scripts/make_signing_cert.sh
PRD.md                    product requirements (refined), PRD_init.md (original brief)
```

## Development

```bash
# Tests (release mode: the stitching tests do real image work)
swift test -c release --scratch-path ~/Library/Caches/ScreenClipper/build

# Command-line tool
swift build -c release --scratch-path ~/Library/Caches/ScreenClipper/build --product clipper-spike
B=~/Library/Caches/ScreenClipper/build/release
$B/clipper-spike where                           # prints the mouse position (points) for 5 s
$B/clipper-spike capture X Y W H out --frames    # capture a region; keeps raw frames for debugging
$B/clipper-spike synth 7 11 out                  # synthetic stitch self-check, writes out/stitched.png
```

`capture` runs from your terminal, so the terminal app needs Screen Recording and Accessibility permission.
Coordinates are points with the origin at the top-left of the main display.

The summary request is a plain `POST https://api.anthropic.com/v1/messages` (`anthropic-version:
2026-10-21`), with structured JSON output (`output_config.format`), `effort: low`, and server-side
fallback (`fallbacks: "default"`, beta header `server-side-fallback-2026-07-01`). A `refusal` stop reason
means "no summary", never a failed clip.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Screen Clipper needs permissions" keeps appearing after granting | The app's signature changed (rebuild with ad-hoc signing). Run `make_signing_cert.sh` once, rebuild, then remove and re-add the app in Screen Recording and Accessibility, and reopen it. |
| Can't find the app in the + picker | It's in `~/Applications`: press ⌘⇧G and type `~/Applications`. |
| "The view didn't scroll" | Click once inside the content so it can receive scroll events, then try again. Make sure the region covers the scrolling view. |
| Hover toolbars or tooltips in the capture | The cursor is parked at the region's right edge; select the region so its right edge is on the scrollbar. Report the app if it persists. |
| Red dashed line in a page | Two screens couldn't be matched (very little overlap or blank content). Re-capture with the mouse still. |
| Summary says "unavailable" | Menu → Open Log for the reason (API key, billing, network). |
| Clip not in Discord | Menu shows "Waiting to post: N" and the last error; **Retry Now**. Check the webhook with **Send test post**. |
| Shortcut does nothing | Another app may use it. Record a different one in Settings. |

## Limitations and roadmap

- Vertical scrolling downward only; one display at a time; apps that ignore synthetic scroll events show a
  message instead of capturing.
- Attachments are captured as they appear on screen, not at original resolution.
- The transcript is plain OCR text (no speaker structure).
- Planned (M2 in `PRD.md`): review window before sending, redaction, recall last clip, pause on mouse
  movement, an Obsidian index note, 90-day image retention.

## License

[MIT](LICENSE)
