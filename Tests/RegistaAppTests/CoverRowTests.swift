import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #42 by hand: Esporta › Copertina, every control clicked on the real panel in the editor window.

extension MouseSuites {
@Suite(.serialized) @MainActor struct CoverRowTests {
    /// The row closed, opened, each control once (the playhead's frame, the title typed, the three places, a kit's title
    /// style, «Salva copertina…» with the save panel answered), a change made by Claude showing at once, and the check's
    /// failure in words. Renders it + fr of the row closed, open with a title that fits and with one that fails
    /// (REGISTA_UI_SNAPSHOTS).
    @Test func theCoverRowSetsAndSavesTheCoverByMouse() async throws {
        let app = try await AppRig()
        defer { app.close() }
        try await app.store.perform("brandkit.apply", ["kit": "cafe-atelier", "captions": false])
        let shots = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        func host(_ lang: String? = nil) async {
            // A tall window: the open row sits under Controlli and File, past the bottom of a 900 pt window.
            app.hostEditor(Navigation(activity: .export, rightTab: .inspector), size: CGSize(width: 1440, height: 1500), language: lang)
            await app.settle()
        }
        func shot(_ name: String) throws { if let shots { try app.snapshot(to: shots.appendingPathComponent("n29-cover-\(name).png")) } }
        func cover() -> Cover? { app.store.project?.cover }
        func settleRender() async {
            for _ in 0..<80 { await app.idle(0.1) }   // the row renders the cover (cover.make) after each change
        }
        func ran(_ since: Int) -> [String] { app.commands(since: since).filter { $0.hasPrefix("cover.") } }
        await host()
        let events = RigGuard.events.count
        try shot("closed-it")
        #expect(app.rig.element("Usa questo fotogramma") == nil, "the row is open before a click")

        // The header opens the row; nothing set yet.
        let header = try #require(app.rig.element("Copertina"), "no Copertina row on Esporta")
        app.rig.click(header.centre)
        await app.settle()
        let use = try #require(app.rig.element("Usa questo fotogramma"), "the row did not open")
        #expect(cover() == nil)

        // «Usa questo fotogramma»: the playhead's frame, once.
        app.store.preview.seek(2.0)
        await app.settle()
        var n = app.store.activity.count
        app.rig.click(use.centre)
        await app.settle()
        #expect(cover()?.time == MediaTime(seconds: 2), "the cover is at \(String(describing: cover()?.time))")
        #expect(ran(n) == ["cover.set"], "ran \(ran(n))")
        await settleRender()

        // The title: typed, then Invio.
        let field = try #require(app.rig.elements().first { $0.label == "Titolo della copertina" && $0.visible }, "no title field")
        app.rig.click(field.centre)
        app.rig.type("Tre parole qui")
        n = app.store.activity.count
        app.rig.key(.returnKey)
        await app.settle()
        #expect(cover()?.title == "Tre parole qui" && ran(n) == ["cover.set"], "the title is \(String(describing: cover()?.title)), ran \(ran(n))")

        // A second line (#125): ⌥Invio starts it in the field, Invio saves both.
        app.rig.click(field.centre)
        (app.rig.window.firstResponder as? NSTextView)?.selectAll(nil)
        app.rig.type("Due")
        app.rig.key("\r", keyCode: MouseRig.Key.returnKey.code, modifiers: .option)
        app.rig.type("righe")
        n = app.store.activity.count
        app.rig.key(.returnKey)
        await app.settle()
        #expect(cover()?.title == "Due\nrighe" && ran(n) == ["cover.set"], "the two-line title is \(String(describing: cover()?.title)), ran \(ran(n))")

        // The three places, each once.
        for (name, place) in [("In alto", Cover.Place.top), ("In basso", .bottom), ("Al centro", .center)] {
            n = app.store.activity.count
            #expect(app.rig.click(name), "no «\(name)»")
            await app.settle()
            #expect(cover()?.place == place && ran(n) == ["cover.set"], "«\(name)»: \(String(describing: cover()?.place)), ran \(ran(n))")
        }
        // The kit's title style.
        n = app.store.activity.count
        #expect(app.rig.click("kicker"), "no kit title style «kicker»")
        await app.settle()
        #expect(cover()?.preset == "kicker" && ran(n) == ["cover.set"])
        try await app.store.perform("cover.set", ["preset": "hook"])
        await settleRender()
        let fits = app.rig.elements().contains { $0.visible && $0.name.contains("Il titolo resta nei due ritagli") }
        #expect(fits, "the check's words are not under the row")
        try shot("open-fits-it")

        // A change made by Claude shows at once: five lines at the top leave the grid's crop, the failure in words.
        try await app.store.perform("cover.set", ["title": "uno\\ndue\\ntre\\nquattro\\ncinque", "place": "top"])
        await settleRender()
        let failure = app.rig.elements().first { $0.visible && $0.name.contains("Il titolo esce dalla zona") }
        #expect(failure?.name.contains("px in alto") == true && failure?.name.contains("Con «Al centro» rientra.") == true,
                "the failure in words: «\(failure?.name ?? "none")»")
        try shot("open-fails-it")

        // «Salva copertina…»: the save panel answered, the PNG at the project's size.
        let out = rigTempDir("cover-save").appendingPathComponent("reel-copertina.png")
        RigGuard.panelAnswer = [out]
        defer { RigGuard.panelAnswer = nil }
        n = app.store.activity.count
        #expect(app.rig.click("Salva copertina…"))
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: out.path) { await app.idle(0.1) }
        await app.settle()
        #expect(ran(n) == ["cover.make"], "ran \(ran(n)); all since: \(app.commands(since: n))")
        let image = try #require(NSImage(contentsOf: out)?.representations.first, "no cover saved")
        #expect(image.pixelsWide == 1080 && image.pixelsHigh == 1920)
        #expect(RigGuard.events.dropFirst(events).allSatisfy { $0.kind == .panel }, "something besides the save panel showed: \(RigGuard.events.dropFirst(events))")

        // French: the same three states.
        try await app.store.perform("cover.set", ["title": "Tre parole qui", "place": "center"])
        await host("fr")
        try shot("closed-fr")
        app.rig.click(try #require(app.rig.element(MouseRig.table("fr").localizedString(forKey: "Copertina", value: nil, table: nil))).centre)
        await settleRender()
        try shot("open-fits-fr")
        try await app.store.perform("cover.set", ["title": "uno\\ndue\\ntre\\nquattro\\ncinque", "place": "top"])
        await settleRender()
        try shot("open-fails-fr")

        // Closed again by its header; still there.
        await host("it")
        app.rig.click(try #require(app.rig.element("Copertina")).centre)
        await app.settle()
        #expect(app.rig.element("Usa questo fotogramma") != nil)
        app.rig.click(try #require(app.rig.element("Copertina")).centre)
        await app.settle()
        #expect(app.rig.element("Usa questo fotogramma") == nil && app.rig.element("Copertina") != nil)
    }
}
}
