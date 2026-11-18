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

}
}
