import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// What the click audit could not drive yet (#36), driven with the mouse on the real views: Export's bit rate slider read
// as an assistive client reads it.

extension MouseSuites {
@Suite(.serialized) @MainActor struct ClickCoverageTests {
    /// Esporta › Bit rate: its value reads as an assistive client reads it, and a drag along it changes it once, to
    /// where the drag let go.
    @Test func theBitRateSliderReadsItsValueAndADragChangesIt() async throws {
        let options = ExportOptions.shared
        let saved = options.bitrate
        defer { options.bitrate = saved }
        options.bitrate = 14
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .export, rightTab: .inspector))
        await app.settle()
        func slider() -> RigElement? { app.rig.elements().first { $0.label == "Bit rate" && $0.visible } }
        let s = try #require(slider(), "no Bit rate slider on Esporta")
        #expect(s.valueDescription == "14 Mbps", "the slider reads «\(s.valueDescription)»")
        // A press on the track at 30 %, dragged to 80 % (the track is the bottom 18 pt of the labelled slider).
        let y = s.frame.maxY - 9
        let from = CGPoint(x: s.frame.minX + s.frame.width * 0.3, y: y)
        var seen: [Double] = []
        let watch = options.$bitrate.dropFirst().removeDuplicates().sink { seen.append($0) }
        app.rig.drag(from: from, by: CGSize(width: s.frame.width * 0.5, height: 0))
        await app.settle()
        watch.cancel()
        // 6…30 Mbps by 1: 80 % along is 25.2 → 25.
        #expect(options.bitrate == 25, "the drag left the bit rate at \(options.bitrate)")
        #expect(slider()?.valueDescription == "25 Mbps", "after the drag the slider reads «\(slider()?.valueDescription ?? "nothing")»")
        #expect(seen.first.map { abs($0 - 13) <= 1 } == true && seen.last == 25, "the value went \(seen)")
        // Released, it stays: a second look changes nothing.
        await app.idle(0.3)
        #expect(options.bitrate == 25 && slider()?.valueDescription == "25 Mbps")
    }

    /// Testi e sottotitoli › Trascrizione: a word's click reads its own modifiers (#36). ⌘-click selects a word, ⇧-click
    /// extends the selection to another, ⌥-click starts again from a word, a plain click goes to the word.
    @Test func theTranscriptWordsReadTheClicksModifiers() async throws {
        let app = try await AppRig()
        defer { app.close() }
        var nav = Navigation(activity: .texts, rightTab: .inspector)
        nav.textsTab = .transcript
        app.hostEditor(nav)
        await app.settle()
        func word(_ w: String) throws -> CGPoint {
            try #require(app.rig.elements().first { $0.role == "AXStaticText" && $0.name.trimmingCharacters(in: .whitespaces) == w && WindowPart.side.contains($0.centre) },
                         "no word «\(w)» in the transcript").centre
        }
        let words = app.store.words.map(\.text)
        let regista = try #require(words.firstIndex(of: "Regista")), il = try #require(words.firstIndex(of: "il")), oggi = try #require(words.firstIndex(of: "Oggi"))
        app.rig.click(try word("Regista"), modifiers: .command)
        await app.settle()
        #expect(app.store.wordSelection == regista...regista, "⌘-click did not select «Regista»: \(String(describing: app.store.wordSelection))")
        app.rig.click(try word("il"), modifiers: .shift)
        await app.settle()
        #expect(app.store.wordSelection == regista...il, "⇧-click did not extend to «il»: \(String(describing: app.store.wordSelection))")
        app.rig.click(try word("Oggi"), modifiers: .option)
        await app.settle()
        #expect(app.store.wordSelection == oggi...oggi, "⌥-click did not start again from «Oggi»: \(String(describing: app.store.wordSelection))")
        app.rig.click(try word("il"))
        await app.settle()
        #expect(app.store.wordSelection == nil, "a plain click kept a selection")
        #expect(abs(app.store.preview.playhead.time - app.store.words[il].start.seconds) < 0.05, "a plain click did not go to «il»")
    }
}
}
