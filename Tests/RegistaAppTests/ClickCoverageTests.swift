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
}
}
