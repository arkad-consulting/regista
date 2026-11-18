import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// Labels that did not fit in French, the long language, found by the journey that walks the app in French (journey 9):
// each control drawn whole and still answering its click.

/// The width `text` needs on one line in `font`.
@MainActor
func naturalWidth(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }

extension MouseSuites {
@Suite(.serialized) @MainActor struct FrenchFitTests {
    /// The Claude tab's «Solo Claude» switch in French («Claude seulement»): its label whole, and a click shows only
    /// Claude's steps, then all of them again (#81).
    @Test func theClaudeOnlySwitchFitsInFrench() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        let bench = app.store.bench
        var mine = EditorStore.Activity(source: "Tu", isAgent: false, command: "script.set", params: "")
        mine.status = .ok
        var claude = EditorStore.Activity(source: "Claude", isAgent: true, command: "transcript.run", params: "")
        claude.status = .ok
        bench.activity = [mine, claude]
        app.hostEditor(Navigation(activity: .media, rightTab: .claude), language: "fr")
        await app.settle()
        let title = loc("Solo Claude")
        #expect(title == "Claude seulement")
        let toggle = try #require(app.rig.controls().first { $0.label == title }, "no «\(title)» switch: \(app.rig.controls().map(\.description))")
        let text = try #require(app.rig.elements().first { $0.visible && $0.role == "AXStaticText" && $0.value == title } ?? .some(toggle))
        let needed = naturalWidth(title, NSFont.systemFont(ofSize: Ed.TypeSize.body))
        // The switch is its label, a gap and the knob: wider than the label alone, and the label's text is not cut.
        #expect(toggle.frame.width >= needed + 30, "«\(title)» is \(toggle.frame.width) pt wide, its label needs \(needed) pt and the knob")
        #expect(text.frame.width >= needed - 1, "the label is drawn \(text.frame.width) pt wide for \(needed) pt")
        let user = CommandTitles.title("script.set")
        #expect(!app.rig.elements(containing: user).isEmpty, "the person's step is not in the log")
        app.rig.click(toggle.centre)
        await app.settle()
        #expect(app.rig.controls().first { $0.label == title }?.value == "1", "the click did not turn the switch on")
        for _ in 0..<40 where !app.rig.elements(containing: user).isEmpty { await app.idle(0.05) }
        #expect(app.rig.elements(containing: user).isEmpty, "the person's step is still listed with «\(title)» on: \(app.rig.elements(containing: user))")
        #expect(!app.rig.elements(containing: CommandTitles.title("transcript.run")).isEmpty, "Claude's step is gone")
        app.rig.click(try #require(app.rig.controls().first { $0.label == title }).centre)
        await app.settle()
        #expect(!app.rig.elements(containing: user).isEmpty, "the person's step did not come back")
    }

    /// Inizio at the minimum window in French (#82): the first card's action and its «ou importez une vidéo» do not
    /// overlap (the link leaves the action its room on the line, or the action goes on the line above) and each answers
    /// its own click; the line about this Mac is read whole.
    @Test func homeFitsTheMinimumWindowInFrench() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        app.hostEditor(Navigation(activity: .home, rightTab: .claude), size: RigWindowSize.minimum.size, language: "fr")
        await app.settle()
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] { try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("home-minimum-fr.png")) }
        let title = loc("Reel parlato"), action = loc("Apri Registra"), more = loc("o importa un video")
        let card = try #require(app.rig.elements().first { $0.visible && $0.isControl && $0.label.hasPrefix(title) }, "no «\(title)» card: \(app.rig.controls().map(\.description))")
        let link = try #require(app.rig.controls().first { $0.label == more }, "no «\(more)»: \(app.rig.controls().map(\.description))")
        // The action's words and arrow at the card's bottom-left (18 pt inside), on the link's line unless they are stacked.
        let actionWidth = naturalWidth(action, NSFont.systemFont(ofSize: Ed.TypeSize.small, weight: .medium)) + 6 + 10
        let room = card.frame.width - 36
        let sideBySide = actionWidth + Ed.Space.s + link.frame.width <= room
        if sideBySide {
            #expect(link.frame.minX >= card.frame.minX + 18 + actionWidth, "«\(more)» at \(link.frame) covers «\(action)» (\(actionWidth) pt from \(card.frame.minX + 18))")
        }
        // Stacked: the link alone on the card's last line, under the action.
        #expect(link.frame.maxY <= card.frame.maxY - 12 && link.frame.maxX <= card.frame.maxX - 12, "«\(more)» is outside its card: \(link.frame) in \(card.frame)")
        let events = RigGuard.events.count
        RigGuard.panelAnswer = []
        app.rig.click(link.centre)
        await app.settle()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .panel }, "«\(more)» asked for no video: \(RigGuard.events.dropFirst(events))")
        #expect(app.store.nav.activity != .record, "«\(more)» also ran the card's action")
        app.hostEditor(Navigation(activity: .home, rightTab: .claude), size: RigWindowSize.minimum.size, language: "fr")
        await app.settle()
        app.rig.click(CGPoint(x: card.frame.minX + 18 + actionWidth / 2, y: sideBySide ? link.centre.y : link.frame.minY - 12))
        await app.settle()
        #expect(app.store.nav.activity == .record, "a click on «\(action)» did not open Enregistrer")

        // The line about this Mac, whole (on two lines if it must).
        app.hostEditor(Navigation(activity: .home, rightTab: .claude), size: RigWindowSize.minimum.size, language: "fr")
        await app.settle()
        let line = try #require(app.rig.elements().first { $0.visible && $0.role == "AXStaticText" && $0.value.hasPrefix("RAM ") }, "no line about this Mac")
        let font = NSFont.systemFont(ofSize: Ed.TypeSize.small)
        let needed = naturalWidth(line.value, font)
        // On one line, or on more lines (it is never cut: no line limit).
        #expect(line.frame.width >= needed - 1 || line.frame.height > font.boundingRectForFont.height * 1.5, "«\(line.value)» is cut: \(line.frame) for \(needed) pt")
    }

}
}
