import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// Editing rules (#31), the interface: Impostazioni › Regole and the Export card, driven with real mouse and key events
// (MouseRig) on the live views over the rig's scratch rules folder (RigIsolation.swift): every switch, number, editor,
// button and link does what it says, once, through its command.

/// The rig's scratch rules folder (never the support folder of the person running the tests).
@MainActor private func rulesBook(_ app: AppRig) -> RuleBook { app.store.engine.context.services.rules }

/// Waits (in loops of ours) until `condition` holds, at most `seconds`.
@MainActor private func until(_ app: AppRig, _ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > end { return false }
        await app.idle(0.05)
    }
    return true
}

/// The switch of a check (an RSwitch: a toggle named by the check's title, valued 0 / 1).
@MainActor private func ruleSwitch(_ app: AppRig, _ title: String) -> RigElement? {
    app.rig.elements().first { $0.label == title && $0.isControl && ($0.value == "0" || $0.value == "1") && $0.visible }
}

@MainActor private func control(_ app: AppRig, containing text: String) -> RigElement? {
    app.rig.elements(containing: text).first { $0.isControl }
}

/// A reel that breaks the rules: a title over the opening captions, a logo landing on the last spoken word (4.46 s).
@MainActor func breakTheRules(_ app: AppRig) async throws {
    try await app.store.perform("title.add", ["text": "APERTURA", "start": 0, "duration": 2])
    let card = try RigProject.media.get().appendingPathComponent("card.png")
    try await app.store.perform("logo.add", ["path": .string(card.path), "start": 4.3, "end": 6])
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct RulesMouseTests {
    private func hostRules(_ app: AppRig) async {
        app.host(SettingsView(pinned: .rules).environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)), size: SettingsView.size)
        await app.settle()
        _ = await until(app) { ruleSwitch(app, "Minimum text size") != nil }
    }

    /// A switch and a number save at once (rules.set), the prose after a pause in typing and when the editor loses the
    /// cursor; the edited sheet is marked; Ripristina il predefinito brings the shipped sheet back.
    @Test func switchesNumbersAndTheProseSaveAndResetBringsTheDefaultBack() async throws {
        let saved = UserDefaults.standard.object(forKey: SettingsRoute.rulesKey)
        defer { UserDefaults.standard.set(saved, forKey: SettingsRoute.rulesKey) }
        UserDefaults.standard.removeObject(forKey: SettingsRoute.rulesKey)
        let app = try await AppRig()
        defer { app.close() }
        let book = rulesBook(app)
        await hostRules(app)
        #expect(control(app, containing: "Ripristina il predefinito")?.enabled == false, "an unedited sheet offers a reset")

        // The switch.
        var n = app.store.activity.count
        let sw = try #require(ruleSwitch(app, "Minimum text size"), "no switch for text-size")
        #expect(sw.value == "1")
        app.rig.click(sw.centre)
        _ = await until(app) { FileManager.default.fileExists(atPath: book.file("every-video").path) }
        await app.settle()
        #expect(app.commands(since: n) == ["rules.set"], "the switch ran \(app.commands(since: n))")
        let off = RuleSheetText.parse(book.text("every-video", language: "en") ?? "")
        #expect(off.entries.first { $0.id == "text-size" }?.on == false, "the file does not have text-size off")
        #expect(ruleSwitch(app, "Minimum text size")?.value == "0", "the switch did not stay off")
        #expect(!app.rig.elements(containing: "modificato da te").isEmpty, "the edited sheet is not marked as edited")
        #expect(app.rig.elements().contains { $0.isControl && $0.name.hasPrefix("For every video") && $0.name.contains("•") }, "the edited sheet's row is not marked")

        // The number: a click makes a field, Return saves.
        n = app.store.activity.count
        // The value on the check's row (named by its tooltip, like every InspectorValueField).
        let row = try #require(ruleSwitch(app, "Minimum text size"))
        let number = try #require(app.rig.elements(containing: "Clicca per scrivere il valore").first { abs($0.centre.y - row.centre.y) < 6 },
                                  "no value field for text-size")
        app.rig.click(number.centre)
        app.rig.pump(0.1)
        #expect(app.rig.isTyping, "a click on the number did not make a field")
        app.rig.key("a", keyCode: 0, modifiers: .command)
        app.rig.type("32")
        app.rig.key(.returnKey)
        _ = await until(app) { RuleSheetText.parse(book.text("every-video", language: "en") ?? "").entries.first { $0.id == "text-size" }?.value == 32 }
        await app.settle()
        #expect(app.commands(since: n) == ["rules.set"], "the number ran \(app.commands(since: n))")
        let v = RuleSheetText.parse(book.text("every-video", language: "en") ?? "").entries.first { $0.id == "text-size" }
        #expect(v?.value == 32 && v?.on == false, "the number did not save (\(String(describing: v)))")

        // The prose: typing saves after a pause, and says so.
        n = app.store.activity.count
        let editor = try #require(app.rig.elements().first { $0.role == "AXTextArea" && $0.visible }, "no editor")
        app.rig.click(CGPoint(x: editor.frame.maxX - 20, y: editor.frame.maxY - 12))
        app.rig.pump(0.1)
        #expect(app.rig.isTyping, "a click on the editor did not put the cursor in it")
        app.rig.key(.end, modifiers: .command)
        app.rig.type("QX")
        #expect(app.commands(since: n).isEmpty, "the prose saved before the pause")
        _ = await until(app, 4) { book.text("every-video", language: "en")?.contains("QX") == true }
        await app.settle()
        #expect(book.text("every-video", language: "en")?.contains("QX") == true, "the prose was not saved after the pause")
        #expect(app.commands(since: n) == ["rules.set"], "the pause ran \(app.commands(since: n))")
        #expect(!app.rig.elements(containing: "salvato").isEmpty, "the editor does not say saved")
        // …and when the cursor leaves (a click on another control): saved at once, well before the pause.
        app.rig.type("QY")
        let logoEnd = try #require(ruleSwitch(app, "The logo only at the end"))
        app.rig.click(logoEnd.centre)
        _ = await until(app, 0.8) { book.text("every-video", language: "en")?.contains("QXQY") == true }
        #expect(book.text("every-video", language: "en")?.contains("QXQY") == true, "leaving the editor did not save the prose")

        // Reset.
        n = app.store.activity.count
        let reset = try #require(control(app, containing: "Ripristina il predefinito"))
        #expect(reset.enabled)
        app.rig.click(reset.centre)
        _ = await until(app) { !FileManager.default.fileExists(atPath: book.file("every-video").path) }
        await app.settle()
        #expect(app.commands(since: n) == ["rules.reset"], "reset ran \(app.commands(since: n))")
        #expect(!book.edited("every-video"))
        _ = await until(app) { ruleSwitch(app, "Minimum text size")?.value == "1" }
        #expect(ruleSwitch(app, "Minimum text size")?.value == "1", "the default did not come back on screen")
        #expect(app.rig.elements(containing: "QX").isEmpty, "the edited prose is still on screen")
    }

    /// A sheet on the left opens it; «Nuovo tipo…» adds a kind from it; a header problem shows under the checks with its
    /// line; Importa… asks for a file, Mostra nel Finder shows the sheet's file; Elimina il tipo… asks, then deletes.
    @Test func kindsAreAddedReportTheirHeaderAndAreDeleted() async throws {
        let saved = UserDefaults.standard.object(forKey: SettingsRoute.rulesKey)
        defer { UserDefaults.standard.set(saved, forKey: SettingsRoute.rulesKey) }
        UserDefaults.standard.removeObject(forKey: SettingsRoute.rulesKey)
        let app = try await AppRig()
        defer { app.close() }
        let book = rulesBook(app)
        await hostRules(app)

        let prose = { app.rig.elements().first { $0.role == "AXTextArea" }?.value ?? "" }
        let everyVideo = prose()
        let reel = try #require(control(app, containing: "Talking-head reel"), "no row for the reel's sheet")
        app.rig.click(reel.centre)
        _ = await until(app) { prose() != everyVideo }
        #expect(prose() != everyVideo && prose() == RuleSheetText.parse(book.text("talking-head-reel", language: RuleBook.interfaceLanguage()) ?? "").prose,
                "the editor does not show the reel's sheet")
        _ = await until(app) { !app.rig.elements(containing: "Un controllo cambiato qui vale solo per questo tipo").isEmpty }
        #expect(!app.rig.elements(containing: "predefinito").isEmpty, "the reel's sheet is not on screen")
        #expect(UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == "talking-head-reel")

        // A new kind, from the sheet on screen (Annulla closes the form without a command).
        var n = app.store.activity.count
        app.rig.click(try #require(control(app, containing: "Nuovo tipo…")).centre)
        await app.settle()
        app.rig.click(try #require(control(app, containing: "Annulla"), "no Annulla in the new kind's form").centre)
        await app.settle()
        #expect(app.rig.elements().first { $0.role == "AXTextField" && $0.label == "Nome del tipo" } == nil && app.commands(since: n).isEmpty,
                "Annulla did not close the form (\(app.commands(since: n)))")
        app.rig.click(try #require(control(app, containing: "Nuovo tipo…")).centre)
        await app.settle()
        let field = try #require(app.rig.elements().first { $0.role == "AXTextField" && $0.label == "Nome del tipo" }, "no name field")
        #expect(!app.rig.elements(containing: "Parte dal foglio «Talking-head reel»").isEmpty)
        app.rig.click(field.centre)
        app.rig.pump(0.1)
        app.rig.type("YouTube tutorial")
        n = app.store.activity.count
        app.rig.click(try #require(control(app, containing: "Crea")).centre)
        _ = await until(app) { FileManager.default.fileExists(atPath: book.file("youtube-tutorial").path) }
        await app.settle()
        #expect(app.commands(since: n) == ["rules.addKind"], "Crea ran \(app.commands(since: n))")
        #expect(RuleSheetText.parse(book.text("youtube-tutorial", language: "en") ?? "").prose.hasPrefix("# YouTube tutorial"))
        _ = await until(app) { control(app, containing: "Elimina il tipo…") != nil }
        #expect(control(app, containing: "Elimina il tipo…") != nil, "the new kind is not the sheet on screen")
        #expect(!app.rig.elements(containing: "tuo").filter(\.isControl).isEmpty, "the user's kind is not marked as theirs")

        // A header written by hand with a mistake: shown under the checks with its line.
        try Data("---\nsurprise: on\n---\n# YouTube tutorial\n".utf8).write(to: book.file("youtube-tutorial"))
        RulesRevision.shared.bump()
        _ = await until(app) { !app.rig.elements(containing: "Line 2:").isEmpty }
        #expect(!app.rig.elements(containing: "Line 2:").isEmpty, "the header problem is not shown with its line")

        // Importa… (the open panel, answered Cancel by the rig) and Mostra nel Finder (recorded, not opened).
        var events = RigGuard.events.count
        app.rig.click(try #require(control(app, containing: "Importa…")).centre)
        await app.settle()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .panel }, "Importa… asked for no file")
        events = RigGuard.events.count
        app.rig.click(try #require(control(app, containing: "Mostra nel Finder")).centre)
        await app.settle()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .finder && $0.detail.contains("youtube-tutorial.md") },
                "Mostra nel Finder did not show the sheet's file: \(RigGuard.events.dropFirst(events))")

        // Elimina il tipo…: a confirmation, then the sheet is gone and «for every video» is on screen.
        n = app.store.activity.count
        app.rig.click(try #require(control(app, containing: "Elimina il tipo…")).centre)
        await app.settle()
        let confirm = try #require(app.rig.sheetButtons().first { $0.title == "Elimina" }, "no confirmation: \(app.rig.sheetButtons().map(\.title))")
        app.rig.click(confirm)
        _ = await until(app) { !FileManager.default.fileExists(atPath: book.file("youtube-tutorial").path) }
        await app.settle()
        #expect(app.commands(since: n) == ["rules.removeKind"], "Elimina ran \(app.commands(since: n))")
        #expect(control(app, containing: "YouTube tutorial") == nil, "the deleted kind is still listed")
    }

    /// The Export card on a reel that breaks the rules: the failing checks with «go to» and «fix» (one undo step), the
    /// kind picker, the link to Settings › Regole, «fix all and export»; then one line when everything passes.
    @Test func theExportCardGoesToFixesAndExports() async throws {
        let saved = [SettingsRoute.tabKey, SettingsRoute.rulesKey].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) } }
        let app = try await AppRig()
        defer { app.close() }
        try await breakTheRules(app)
        app.hostEditor(Navigation(activity: .export, rightTab: .inspector))
        await app.settle()
        _ = await until(app, 4) { control(app, containing: "Esporta lo stesso") != nil }
        let failing = try #require(try await app.store.silent("rules.check")["violations"]?.arrayValue?.filter { $0["severity"] == "fail" })
        #expect(failing.count >= 2, "the reel does not break two rules: \(failing)")
        #expect(!app.rig.elements(containing: "\(failing.count) da sistemare").isEmpty, "the card does not count the failing checks")
        #expect(control(app, containing: "Esporta video…") == nil, "the plain export button shows while a rule fails")

        // Vai a: the playhead to the violation.
        app.store.preview.seek(3)
        let first = try #require(failing.first?["time"]?.doubleValue)
        app.rig.click(try #require(control(app, containing: "Vai a \(ExportRulesCard.time(first))")).centre)
        await app.settle()
        #expect(abs(app.store.preview.playhead.time - first) < 0.05, "Vai a did not move the playhead to \(first) (\(app.store.preview.playhead.time))")

        // Sistema: the violation's own fix, one undo step.
        var n = app.store.activity.count
        let undo = app.store.undoNames.count
        let fixCommand = try #require(failing.first?["fix"]?["command"]?.stringValue)
        app.rig.click(try #require(app.rig.elements().first { $0.isControl && $0.name == "Sistema" }).centre)
        await app.settle()
        #expect(app.commands(since: n) == [fixCommand], "Sistema ran \(app.commands(since: n))")
        #expect(app.store.undoNames.count == undo + 1, "the fix is not one undo step")
        _ = await until(app) { !app.rig.elements(containing: "\(failing.count - 1) da sistemare").isEmpty }
        #expect(!app.rig.elements(containing: "\(failing.count - 1) da sistemare").isEmpty, "the card did not check again after the fix")

        // The kind: the button opens the kinds, a row sets it (one undo step).
        app.rig.click(try #require(control(app, containing: "Talking-head reel")).centre)
        await app.settle()
        n = app.store.activity.count
        app.rig.click(try #require(control(app, containing: "Voice-over video"), "the kinds did not open").centre)
        await app.settle()
        #expect(app.commands(since: n) == ["project.setKind"] && app.store.project?.kind == "voice-over-video", "the kind row ran \(app.commands(since: n))")
        _ = await until(app) { control(app, containing: "Voice-over video") != nil }

        // The link opens Settings › Regole on the project's kind.
        UserDefaults.standard.removeObject(forKey: SettingsRoute.tabKey)
        app.rig.click(try #require(control(app, containing: "Le regole si cambiano in Impostazioni › Regole")).centre)
        await app.settle()
        #expect(UserDefaults.standard.string(forKey: SettingsRoute.tabKey) == SettingsTab.rules.rawValue)
        #expect(UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == "voice-over-video")

        // Sistema tutto ed esporta: the fixes in one step, then the save panel (answered Cancel by the rig: nothing exported).
        n = app.store.activity.count
        let events = RigGuard.events.count
        app.rig.click(try #require(control(app, containing: "Sistema tutto ed esporta")).centre)
        _ = await until(app) { RigGuard.events.count > events }
        await app.settle()
        #expect(app.commands(since: n).first == "rules.fix", "fix all ran \(app.commands(since: n))")
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .panel && $0.detail.contains("Esporta il video") }, "no save panel after the fixes")
        #expect(try await app.store.silent("rules.check")["pass"] == true)

        // Everything passes: one line, and the export button as before.
        _ = await until(app) { control(app, containing: "Esporta video…") != nil }
        #expect(!app.rig.elements(containing: "controlli rispettati").isEmpty, "the card is not one line when everything passes")
        #expect(control(app, containing: "Esporta lo stesso") == nil && control(app, containing: "Esporta video…") != nil)
    }

    /// «Esporta lo stesso» is always there while a rule fails, even when no fix exists; it asks where, then exports with
    /// the override (the save panel is answered Cancel by the rig; the call is the one the button builds).
    @Test func exportAnywayIsAlwaysOffered() async throws {
        let app = try await AppRig()
        defer { app.close() }
        // A logo across the video: a rule without an automatic fix.
        let card = try RigProject.media.get().appendingPathComponent("card.png")
        try await app.store.perform("logo.add", ["path": .string(card.path), "start": 0, "end": 6])
        app.hostEditor(Navigation(activity: .export, rightTab: .inspector))
        await app.settle()
        _ = await until(app, 4) { control(app, containing: "Esporta lo stesso") != nil }
        #expect(control(app, containing: "Sistema tutto ed esporta") == nil, "fix all is offered with nothing to fix")
        let anyway = try #require(control(app, containing: "Esporta lo stesso"), "no Esporta lo stesso")
        #expect(anyway.enabled)
        let events = RigGuard.events.count
        app.rig.click(anyway.centre)
        await app.settle()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .panel && $0.detail.contains("Esporta il video") }, "Esporta lo stesso asked for no file")
        #expect(ExportCalls.render(path: "/x.mp4", preset: "9:16", captions: true, bitrate: 14, anyway: true).params["exportAnyway"] == true)
        #expect(ExportCalls.render(path: "/x.mp4", preset: "9:16", captions: true, bitrate: 14).params["exportAnyway"] == nil)
    }
}
}

/// The card's report from a real check: the kinds, the failures and their fixes, the passed checks, the header problems.
@MainActor
@Test func theExportCardReadsTheCheck() throws {
    let report = RulesReport(check: [
        "kind": "talking-head-reel", "kindTitle": "Talking-head reel", "pass": false,
        "violations": [
            ["check": "title-captions", "severity": "fail", "time": 0.4, "message": "x", "messageKey": "Captions show while the opening title is on screen (%1$@–%2$@ s).",
             "messageArgs": ["0.00", "2.00"], "fix": ["command": "captions.clear", "params": ["from": 0, "to": 2]]],
            ["check": "logo-pause", "severity": "warn", "time": 5, "message": "y", "messageKey": "y", "messageArgs": [], "fix": .null],
        ],
        "checks": [["id": "title-captions", "title": "No captions while the opening title is on screen", "ran": true, "violations": 1],
                   ["id": "logo-end", "title": "The logo only at the end", "ran": true, "violations": 0],
                   ["id": "face-clear", "title": "No logo or title over the speaker's face", "ran": false, "violations": 0]],
        "sheetProblems": [["sheet": "every-video", "line": 2, "message": "m", "messageKey": "Line %1$@: unknown check «%2$@».", "messageArgs": ["2", "x"]]],
        "note": .null,
    ], list: ["sheets": [["kind": "every-video", "title": "For every video", "builtIn": true], ["kind": "talking-head-reel", "title": "Talking-head reel", "builtIn": true],
                         ["kind": "yt", "title": "YouTube", "builtIn": false]]])
    #expect(report.kinds.map(\.kind) == ["talking-head-reel", "yt"])
    #expect(report.failures.count == 1 && report.violations.count == 2 && report.fixable)
    #expect(report.violations[0].message == "Captions show while the opening title is on screen (0.00–2.00 s).")
    #expect(report.violations[0].fix == StepCall(id: "captions.clear", params: ["from": 0, "to": 2]) && report.violations[1].fix == nil)
    #expect(report.passed == ["The logo only at the end"], "a check that did not run is not counted as passed")
    #expect(report.problems == ["Line 2: unknown check «x»."])
    #expect(ExportRulesCard.time(41.8) == "0:41" && ExportRulesCard.time(0.3) == "0:00")
}

/// Esporta opens on the project's own format; a format chosen for a project holds until its format changes (a 16:9
/// screen recording exported as a 9:16 reel by default, found by the journeys).
@MainActor
@Test func theExportFormatFollowsTheProject() {
    #expect(ExportOptions.preset(width: 1920, height: 1080) == "16:9" && ExportOptions.preset(width: 540, height: 960) == "9:16")
    #expect(ExportOptions.preset(width: 1080, height: 1350) == "4:5" && ExportOptions.preset(width: 1080, height: 1080) == "1:1")
    #expect(ExportOptions.preset(width: 1000, height: 700) == nil)
    let o = ExportOptions()
    o.follow(tab: "t1", width: 1920, height: 1080)
    #expect(o.preset == "16:9")
    o.preset = "1:1"
    o.follow(tab: "t1", width: 1920, height: 1080)
    #expect(o.preset == "1:1", "the person's choice did not hold for the same project")
    o.follow(tab: "t2", width: 1080, height: 1920)
    #expect(o.preset == "9:16", "another project did not start from its own format")
    o.preset = "16:9"
    o.follow(tab: "t2", width: 1000, height: 700)
    #expect(o.preset == "16:9", "a format with no chip changed the choice")
}
