import ClipperCore
import CoreGraphics
import Foundation

// M0 tool: test scroll-capture-stitch without the app UI.
//
//   clipper-spike where                      print the mouse position for 5 s (to find a region)
//   clipper-spike capture X Y W H [OUT] [--frames]
//                                            capture region (points, origin top-left of main display)
//   clipper-spike synth [SEED] [SIMSEED] [OUT]
//                                            stitch a synthetic chat and check it against the original
//
// The terminal app running this needs Screen Recording and Accessibility permission.

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    usage:
      clipper-spike where
      clipper-spike capture X Y W H [OUT_DIR] [--frames]
      clipper-spike synth [SEED] [SIMSEED] [OUT_DIR]
    """)
    exit(2)
}

final class PrintDelegate: CaptureSessionDelegate {
    func captureProgress(screens: Int, elapsed: TimeInterval) {
        print(String(format: "  %d screens, %.1fs", screens, elapsed))
    }
    func captureLimitReached(screens: Int, elapsed: TimeInterval) async -> Bool { false }
}

switch args.first {
case "where":
    for _ in 0..<5 {
        let p = Scroller.cursorPosition()
        print("mouse at x=\(Int(p.x)) y=\(Int(p.y))")
        Thread.sleep(forTimeInterval: 1)
    }

case "capture":
    guard args.count >= 5, let x = Double(args[1]), let y = Double(args[2]), let w = Double(args[3]), let h = Double(args[4]) else { usage() }
    let out = URL(fileURLWithPath: args.count > 5 && !args[5].hasPrefix("--") ? args[5] : "spike-out")
    var config = CaptureSession.Config(rect: CGRect(x: x, y: y, width: w, height: h),
                                       pagesDirectory: out.appendingPathComponent("pages"))
    if args.contains("--frames") { config.framesDirectory = out.appendingPathComponent("frames") }
    guard CGPreflightScreenCaptureAccess() else {
        CGRequestScreenCaptureAccess()
        print("Grant Screen Recording to this terminal app, then rerun."); exit(1)
    }
    print("Capturing in 3 s — switch to the app and don't touch the mouse…")
    Thread.sleep(forTimeInterval: 3)
    let delegate = PrintDelegate()
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let session = CaptureSession(config: config)
            session.delegate = delegate
            let started = Date()
            let outcome = try await session.run()
            if case let .finished(pages, screens, seams, scrolled) = outcome {
                print("done: \(screens) screens, \(pages.count) pages, \(seams) seams, scrolled=\(scrolled), \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                print("pages in \(out.appendingPathComponent("pages").path)")
                let text = await OCR.transcript(pages: pages)
                try text.write(to: out.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
                print("transcript: \(text.count) characters")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()

case "synth":
    let seed = UInt64(args.count > 1 ? args[1] : "7") ?? 7
    let simSeed = UInt64(args.count > 2 ? args[2] : "11") ?? 11
    let chat = SyntheticChat(seed: seed)
    let run = SyntheticRun.run(chat, start: 250, seed: simSeed)
    let bad = run.badRows(chat)
    print("out=\(run.output.height) expected=\(chat.screenHeight + run.lastOffset - run.firstOffset) hTop=\(run.assembler.hTop) hBot=\(run.assembler.hBot) unconfident=\(run.unconfident) wrong=\(run.wrongShifts) steps=\(run.steps) badRows=\(bad.count)")
    run.notes.forEach { print("  ", $0) }
    if args.count > 3 {
        let dir = URL(fileURLWithPath: args[3])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ImageFiles.writePNG(run.output, to: dir.appendingPathComponent("stitched.png"))
    }

default:
    usage()
}
