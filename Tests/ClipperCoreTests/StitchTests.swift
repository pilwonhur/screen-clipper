import ClipperCore
import Foundation
import Testing

typealias CollectSink = MemorySink

func simulate(_ chat: SyntheticChat, start: Int, seed: UInt64, stepRange: ClosedRange<Double> = 0.35...0.75) -> SyntheticRun {
    SyntheticRun.run(chat, start: start, seed: seed, stepRange: stepRange)
}

/// Checks that the stitched output reproduces the document exactly, with no gaps or duplicates.
func verify(_ sim: SyntheticRun, _ chat: SyntheticChat) {
    #expect(sim.unconfident == 0, "\(sim.notes)")
    #expect(sim.wrongShifts == 0)
    #expect(sim.output.height == chat.screenHeight + (sim.lastOffset - sim.firstOffset), "output height")
    #expect(sim.badRows(chat).isEmpty, "rows that differ from the original document")
}

@Suite struct StitchTests {
    @Test func stitchesLongChatWithFloatingButton() {
        let chat = SyntheticChat(seed: 7)
        let sim = simulate(chat, start: 250, seed: 11)
        verify(sim, chat)
        // The footer band must cover the input box and the floating button.
        #expect(sim.assembler.hBot >= chat.footerHeight + 30 + 76)
        #expect(sim.assembler.hBot <= Int(Double(chat.screenHeight) * 0.45))
        #expect(sim.assembler.framesAccepted > 5)
    }

    @Test func stitchesWithoutFloatingButton() {
        let chat = SyntheticChat(seed: 3)
        chat.showsFloatingButton = false
        let sim = simulate(chat, start: 0, seed: 5)
        verify(sim, chat)
        #expect(sim.assembler.hBot >= chat.footerHeight)
    }

    @Test(arguments: [21, 22, 23, 24] as [UInt64])
    func stitchesWithSmallAndLargeSteps(seed: UInt64) {
        let chat = SyntheticChat(width: 1000, documentHeight: 7000, screenHeight: 1200, seed: seed)
        let sim = simulate(chat, start: 100, seed: seed, stepRange: 0.15...0.85)
        verify(sim, chat)
    }

    @Test func detectsNoMovement() {
        let chat = SyntheticChat(seed: 2)
        let asm = StitchAssembler(sink: CollectSink(), rightExclude: 40)
        asm.begin(chat.screen(at: 500))
        #expect(asm.isUnchanged(asm.signatures(for: chat.screen(at: 500))))
        #expect(!asm.isUnchanged(asm.signatures(for: chat.screen(at: 700))))
    }

    @Test func detectsScrollingTheWrongWay() {
        let chat = SyntheticChat(seed: 4)
        let asm = StitchAssembler(sink: CollectSink(), rightExclude: 40)
        asm.begin(chat.screen(at: 2000))
        let sig = asm.signatures(for: chat.screen(at: 1700))
        let m = asm.match(sig, expected: nil, allowNegative: true)
        #expect(m?.shift == -300)
    }

    @Test func refusesToGuessAcrossAGap() {
        let chat = SyntheticChat(seed: 9)
        let asm = StitchAssembler(sink: CollectSink(), rightExclude: 40)
        asm.begin(chat.screen(at: 0))
        // Scrolled further than one screen: no overlap to match.
        let sig = asm.signatures(for: chat.screen(at: chat.viewportHeight + 400))
        let m = asm.match(sig, expected: nil, allowNegative: false)
        #expect(m == nil || m?.confident == false)
    }
}

@Suite struct PaginatorTests {
    @Test func pagesReassembleExactlyAndCutOnBlankRows() throws {
        let chat = SyntheticChat(seed: 7)
        let sim = simulate(chat, start: 250, seed: 11)
        var pages: [Frame] = []
        let pager = Paginator(width: sim.output.width, frameHeight: chat.screenHeight, ignoreRight: 40) { pages.append($0) }
        // Feed in uneven chunks, like the assembler does.
        var y = 0
        var rng = SeededRandom(seed: 1)
        while y < sim.output.height {
            let n = min(sim.output.height - y, Int.random(in: 50...900, using: &rng))
            pager.append(frame: sim.output, rows: y..<(y + n))
            y += n
        }
        pager.finish()
        #expect(pages.count >= 3)
        // Concatenated pages == stitched output.
        let joined = pages.flatMap { $0.pixels }
        #expect(joined == sim.output.pixels)
        // Every page but the last is within the size limits.
        for p in pages.dropLast() {
            #expect(p.height >= pager.minHeight && p.height <= pager.maxHeight)
        }
        // Cuts land on blank rows: the last row of each page has no text.
        let columns = 0..<(sim.output.width - 40)
        var cutsThroughContent = 0
        for p in pages.dropLast() {
            let last = p.height - 1
            let first = Array(p.pixels[(last * p.bytesPerRow)..<(last * p.bytesPerRow + 4)])
            var ink = 0
            for x in columns {
                let i = last * p.bytesPerRow + x * 4
                if abs(Int(p.pixels[i]) - Int(first[0])) > 8 || abs(Int(p.pixels[i + 1]) - Int(first[1])) > 8 { ink += 1 }
            }
            if ink > 2 { cutsThroughContent += 1 }
        }
        #expect(cutsThroughContent == 0)
    }
}
