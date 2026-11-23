import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista
@testable import RegistaCore

// Editing rules (#31), the interface: Impostazioni › Regia e skill (#157) and the Export card, driven with real mouse and key events
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

/// The title of a choice's row (its text: the lookup key in a window without words).
@MainActor private func choiceTitle(_ app: AppRig, _ title: String) -> RigElement? {
    app.rig.elements().first { $0.role == "AXStaticText" && $0.value == title }
}

/// A control on a choice's row, right of its title.
@MainActor private func onChoiceRow(_ app: AppRig, _ title: String, _ match: (RigElement) -> Bool) -> RigElement? {
    guard let t = choiceTitle(app, title) else { return nil }
    return app.rig.elements().first { $0.isControl && abs($0.centre.y - t.centre.y) < 8 && $0.frame.minX > t.frame.maxX && match($0) }
}

/// A segment of a choice (named by its option's label).
@MainActor private func segment(_ app: AppRig, choice: String, _ label: String) -> RigElement? {
    onChoiceRow(app, choice) { $0.name == label }
}

/// The menu of a choice with more than four options (its value: the current option's label).
@MainActor private func menuControl(_ app: AppRig, choice: String) -> RigElement? {
    onChoiceRow(app, choice) { $0.role == "AXButton" }
}

/// The number of a choice (an InspectorValueField, named by its tooltip).
@MainActor private func numberField(_ app: AppRig, choice: String) -> RigElement? {
    guard let t = choiceTitle(app, choice) else { return nil }
    return app.rig.elements().first { $0.name.contains("Clicca per scrivere il valore") && abs($0.centre.y - t.centre.y) < 8 }
}

/// Clicks the tab of the item on screen named `title` (Regole, Scelte, Passi: the key in a window without words).
@MainActor private func openPane(_ app: AppRig, _ title: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let tab = try #require(app.rig.elements().first { $0.isControl && $0.visible && $0.name == title }, "no tab «\(title)»", sourceLocation: sourceLocation)
    app.rig.click(tab.centre)
    await app.settle()
}

/// Scrolls the sheet's pane (at the top of its scroll area, never over the prose editor's own scroll view) until what
/// `find` returns is whole in view.
@MainActor private func reveal(_ app: AppRig, _ find: () -> RigElement?, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0..<40 {
        let e = try #require(find(), "nothing to bring into view", sourceLocation: sourceLocation)
        guard let pane = app.rig.elements().filter({ $0.role == "AXScrollArea" && $0.frame.minX > RulesSettings.listWidth })
            .max(by: { $0.frame.height < $1.frame.height })?.frame else { return }
        let shown = e.frame.height < pane.height - 4 ? pane.insetBy(dx: 0, dy: -0.5).contains(e.frame) : pane.insetBy(dx: 0, dy: 4).contains(e.centre)
        if shown { return }
        app.rig.scrollContent(at: CGPoint(x: pane.midX, y: pane.minY + 12), by: e.frame.midY > pane.midY ? 80 : -80)
        await app.settle()
    }
    Issue.record("could not bring \(find()?.description ?? "it") into view", sourceLocation: sourceLocation)
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
        // The editor is under the checks and the choices: the pane scrolls to it.
        try await reveal(app) { app.rig.elements().first { $0.role == "AXTextArea" } }
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
        try await reveal(app) { app.rig.elements().first { $0.label == "The logo only at the end" && $0.isControl } }
        let logoEnd = try #require(ruleSwitch(app, "The logo only at the end"))
        app.rig.click(logoEnd.centre)
        _ = await until(app, 0.8) { book.text("every-video", language: "en")?.contains("QXQY") == true }
        #expect(book.text("every-video", language: "en")?.contains("QXQY") == true, "leaving the editor did not save the prose")
        await app.settle()

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

    /// The Scelte section (one regia): a segment, the menu and the number field of a choice each change that choice's
    /// line of the sheet and nothing else, through rules.set, once; the edited sheet's row in the side list is marked;
    /// Ripristina il predefinito brings every choice back to its default. On «Per ogni video», then on a kind.
    @Test func theChoicesChangeTheirLineAndResetGoesBackToTheDefault() async throws {
        let saved = UserDefaults.standard.object(forKey: SettingsRoute.rulesKey)
        defer { UserDefaults.standard.set(saved, forKey: SettingsRoute.rulesKey) }
        UserDefaults.standard.removeObject(forKey: SettingsRoute.rulesKey)
        let app = try await AppRig()
        defer { app.close() }
        let book = rulesBook(app)
        await hostRules(app)
        // The header's lines (its comments left out: the sheet a set writes is in the interface language).
        let lines = { (kind: String) in (RuleSheetText.parse(book.text(kind, language: "en") ?? "").header ?? []).filter { !$0.hasPrefix("#") } }
        try await openPane(app, "Scelte")

        /// Clicks `target` once it is in view (the pane scrolls), and says which lines of `kind`'s sheet changed.
        func click(_ find: () -> RigElement?, _ what: String, kind: String = RuleBook.everyVideo, command: String = "rules.set",
                   sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String] {
            let before = lines(kind)
            try await reveal(app, find)
            let target = try #require(find(), "no \(what)", sourceLocation: sourceLocation)
            let n = app.store.activity.count
            app.rig.click(target.centre)
            _ = await until(app) { lines(kind) != before }
            await app.settle()
            #expect(app.commands(since: n) == [command], "\(what) ran \(app.commands(since: n))", sourceLocation: sourceLocation)
            #expect(find() != nil, "\(what) is gone after the click", sourceLocation: sourceLocation)
            let after = lines(kind)
            return after.count == before.count ? zip(before, after).filter { $0 != $1 }.map(\.1) : after.filter { !before.contains($0) }
        }

        // A segment: pace → Fast. One line changes, and the meaning under the title follows.
        #expect(segment(app, choice: "Pace", "Normal")?.selected == true, "the default pace is not chosen")
        #expect(try await click({ segment(app, choice: "Pace", "Fast") }, "the Fast segment") == ["pace: fast"])
        #expect(segment(app, choice: "Pace", "Fast")?.selected == true, "the segment did not stay chosen")
        #expect(app.rig.elements(containing: "longer ones are cut").contains { $0.name.contains("0.4") || $0.name.contains("0,4") },
                "the meaning does not follow the chosen pace: \(app.rig.elements(containing: "longer ones are cut").map(\.name))")
        #expect(app.rig.elements().contains { $0.isControl && $0.name.hasPrefix("For every video") && $0.name.contains("•") }, "the edited sheet's row is not marked")

        // The menu (more than four options): Caption style → Ghost karaoke.
        let menu = { menuControl(app, choice: "Caption style") }
        try await reveal(app, menu)
        #expect(menu()?.value == "Talking head", "the caption style's menu does not read its option: \(String(describing: menu()))")
        app.rig.takeKey()
        app.rig.click(try #require(menu()).centre)
        let pop = try #require(await openedPopover(app), "the caption style's menu did not open")
        let rows = pop.elements().filter { $0.isControl && $0.visible }
        #expect(rows.count == 5 && rows.first { $0.selected }?.name.hasPrefix("Talking head") == true, "the menu lists \(rows.map(\.name))")
        var before = lines(RuleBook.everyVideo)
        var n = app.store.activity.count
        pop.click(try #require(rows.first { $0.name.hasPrefix("Ghost karaoke") }).centre)
        _ = await until(app) { lines(RuleBook.everyVideo) != before }
        await app.settle()
        #expect(app.commands(since: n) == ["rules.set"], "the menu ran \(app.commands(since: n))")
        #expect(zip(before, lines(RuleBook.everyVideo)).filter { $0 != $1 }.map(\.1) == ["captions: ghost-karaoke"])
        #expect(menu()?.value == "Ghost karaoke", "the menu does not read the new option")

        // The number field: framing's zoom, a click makes a field, Return saves; the graphics' range takes «4–10».
        for (choice, typed, line) in [("Framing", "1,3", "framing: alternate 1.3"), ("Graphics before delivering", "4–10", "graphics: on 4-10")] {
            let field = { numberField(app, choice: choice) }
            try await reveal(app, field)
            before = lines(RuleBook.everyVideo)
            n = app.store.activity.count
            app.rig.click(try #require(field(), "no number for \(choice)").centre)
            app.rig.pump(0.1)
            #expect(app.rig.isTyping, "a click on \(choice)'s number did not make a field")
            app.rig.key("a", keyCode: 0, modifiers: .command)
            app.rig.type(typed)
            app.rig.key(.returnKey)
            _ = await until(app) { lines(RuleBook.everyVideo) != before }
            await app.settle()
            #expect(app.commands(since: n) == ["rules.set"], "\(choice)'s number ran \(app.commands(since: n))")
            #expect(zip(before, lines(RuleBook.everyVideo)).filter { $0 != $1 }.map(\.1) == [line])
        }

        // Reset (below the pane, always in view): every choice back to its default, on screen and in the sheet.
        n = app.store.activity.count
        app.rig.click(try #require(control(app, containing: "Ripristina il predefinito")).centre)
        _ = await until(app) { !book.edited(RuleBook.everyVideo) }
        await app.settle()
        #expect(app.commands(since: n) == ["rules.reset"])
        _ = await until(app) { segment(app, choice: "Pace", "Normal")?.selected == true }
        #expect(segment(app, choice: "Pace", "Normal")?.selected == true, "the default pace did not come back")
        #expect(menuControl(app, choice: "Caption style")?.value == "Talking head", "the default caption style did not come back")

        // On a built-in recipe: only its kind's choices, read-only (a click runs nothing).
        app.rig.click(try #require(control(app, containing: "Talking-head reel")).centre)
        _ = await until(app) { choiceTitle(app, "Sound without a face") == nil && segment(app, choice: "Sound effects", "None") != nil }
        await app.settle()
        #expect(app.rig.elements(containing: "Sound without a face").isEmpty, "the reel shows a choice of faceless videos")
        n = app.store.activity.count
        app.rig.click(try #require(segment(app, choice: "Sound effects", "None")).centre)
        await app.settle()
        #expect(app.commands(since: n).isEmpty && !book.edited("talking-head-reel"), "a click on a built-in ran \(app.commands(since: n))")
        // On a skill (#157): every choice, and a change writes the skill (skill.set, one undo step), not «Per ogni video».
        let slug = try #require(try await app.store.silent("skill.create", ["title": "Studio", "basedOn": "talking-head-reel"])["skill"]?.stringValue)
        RulesRevision.shared.bump()
        _ = await until(app) { control(app, containing: "Studio") != nil }
        app.rig.click(try #require(control(app, containing: "Studio")).centre)
        _ = await until(app) { choiceTitle(app, "Sound without a face") != nil }
        await app.settle()
        #expect(try await click({ segment(app, choice: "Sound effects", "None") }, "the skill's None segment", kind: slug, command: "skill.set").contains("sfx: none"))
        #expect(!book.edited(RuleBook.everyVideo), "a choice on a skill wrote «Per ogni video»")
    }

    /// The Scelte section in Italian and French, on «Per ogni video» and on the talking-head reel: each row's title whole,
    /// its controls right of it inside the pane, its meaning under it (REGISTA_UI_SNAPSHOTS: the whole pane, to look at).
    @Test(arguments: ["it", "fr"])
    func theChoicesReadWholeInTheirLanguage(_ language: String) async throws {
        let saved = UserDefaults.standard.object(forKey: SettingsRoute.rulesKey)
        defer { UserDefaults.standard.set(saved, forKey: SettingsRoute.rulesKey) }
        let app = try await AppRig()
        defer { app.close() }
        let table = MouseRig.table(language)
        let height: CGFloat = 1500
        for kind in [RuleBook.everyVideo, "talking-head-reel"] {
            UserDefaults.standard.set(kind, forKey: SettingsRoute.rulesKey)
            app.host(SettingsView(pinned: .rules, height: height).environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)),
                     size: CGSize(width: SettingsView.size.width, height: height), language: language)
            await app.settle()
            _ = await app.until(4) { app.rig.elements().contains { $0.isControl && $0.name == table.localizedString(forKey: "Scelte", value: nil, table: nil) } }
            try await openPane(app, table.localizedString(forKey: "Scelte", value: nil, table: nil))
            let specs = RuleChoiceSpec.all.filter { $0.applies(to: kind) }
            let titles = specs.map { table.localizedString(forKey: $0.title, value: nil, table: nil) }
            // The rows of this sheet (a kind's: without the choices of other kinds).
            let others = RuleChoiceSpec.all.filter { !$0.applies(to: kind) }.map { table.localizedString(forKey: $0.title, value: nil, table: nil) }
            _ = await app.until(4) { choiceTitle(app, titles.last!) != nil && others.allSatisfy { choiceTitle(app, $0) == nil } }
            await app.settle()
            let font = NSFont.systemFont(ofSize: Ed.TypeSize.body)
            for (spec, title) in zip(specs, titles) {
                guard let t = choiceTitle(app, title) else { Issue.record("\(language) \(kind): no row «\(title)»"); continue }
                #expect(naturalWidth(title, font) <= t.frame.width + 1, "\(language): «\(title)» is cut (\(t.frame.width) pt)")
                let controls = app.rig.elements().filter { $0.isControl && abs($0.centre.y - t.centre.y) < 8 && $0.frame.minX > RulesSettings.listWidth }
                #expect(!controls.isEmpty, "\(language): «\(title)» has no control")
                for c in controls {
                    #expect(c.frame.minX >= t.frame.maxX && c.frame.maxX <= SettingsView.size.width - 20 + 0.5,
                            "\(language): \(spec.id)'s \(c.description) at \(c.frame) overlaps its title or leaves the pane")
                }
            }
            if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
                try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-rules-choices-\(kind)-\(language).png"))
            }
        }
    }

    /// One list (#156): every check and every choice the tab shows comes from the specs — on «Per ogni video» all of them,
    /// on each built-in kind the choices that apply to it, in the specs' order — and a misspelled key or an option that
    /// does not exist in a sheet shows under the checks with its line, as an unknown check does.
    @Test func everyCheckAndChoiceComesFromTheSpecsAndAMisspelledKeyIsReported() async throws {
        let saved = UserDefaults.standard.object(forKey: SettingsRoute.rulesKey)
        defer { UserDefaults.standard.set(saved, forKey: SettingsRoute.rulesKey) }
        let app = try await AppRig()
        defer { app.close() }
        let book = rulesBook(app)
        for kind in [RuleBook.everyVideo] + RuleBook.builtInKinds {
            UserDefaults.standard.set(kind, forKey: SettingsRoute.rulesKey)
            // The model the tab draws.
            let model = RulesModel()
            model.store = app.store
            await model.load()
            #expect(model.checks.map(\.id) == RuleCheckSpec.ids, "\(kind): the checks are not the specs: \(model.checks.map(\.id))")
            #expect(model.checks.map(\.title) == RuleCheckSpec.all.map(\.title), "\(kind)")
            let choices = RuleChoiceSpec.all.filter { $0.applies(to: kind) }
            #expect(model.choices.map(\.id) == choices.map(\.id), "\(kind): the choices are not the specs: \(model.choices.map(\.id))")
            for (c, spec) in zip(model.choices, choices) {
                #expect(c.title == spec.title && c.options.map(\.id) == spec.optionIDs && c.options.map(\.label) == spec.options.map(\.label),
                        "\(kind): \(c.id) is not its spec")
                #expect(c.value == spec.defaultOption && c.number == spec.number?.defaultValue, "\(kind): \(c.id) is not at its default")
            }
            // The tab: a row for each of them, and no other.
            app.host(SettingsView(pinned: .rules, height: 1500).environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)),
                     size: CGSize(width: SettingsView.size.width, height: 1500))
            await app.settle()
            _ = await until(app, 4) { app.rig.elements().contains { $0.label == RuleCheckSpec.all.last!.title && $0.isControl } && model.kind == kind }
            for check in RuleCheckSpec.all {
                #expect(app.rig.elements().contains { $0.label == check.title && $0.isControl }, "\(kind): no switch for \(check.id)")
            }
            try await openPane(app, "Scelte")
            _ = await until(app, 4) { choiceTitle(app, choices.last!.title) != nil }
            let all = RuleChoiceSpec.all.map(\.title)
            let shown = app.rig.elements().filter { $0.role == "AXStaticText" && all.contains($0.value) }.map(\.value)
            #expect(shown == choices.map(\.title), "\(kind): the tab shows the choices \(shown)")
        }

        // A misspelled key and an option that does not exist, written by hand: each shown with its line.
        UserDefaults.standard.set(RuleBook.everyVideo, forKey: SettingsRoute.rulesKey)
        let text = try #require(RuleDefaults.text(RuleBook.everyVideo, language: "en"))
        try FileManager.default.createDirectory(at: book.directory, withIntermediateDirectories: true)
        try Data(text.replacingOccurrences(of: "\npace: normal\n", with: "\npace: speedy\ncaptoins: none\n").utf8).write(to: book.file(RuleBook.everyVideo))
        defer { try? FileManager.default.removeItem(at: book.file(RuleBook.everyVideo)) }
        let lines = text.components(separatedBy: "\n")
        let pace = try #require(lines.firstIndex(of: "pace: normal")) + 1
        await hostRules(app)
        let misspelled = "Line \(pace + 1): unknown check or choice «captoins».", wrong = "Line \(pace): pace is one of calm, normal, fast."
        _ = await until(app, 4) { !app.rig.elements(containing: misspelled).isEmpty }
        #expect(!app.rig.elements(containing: misspelled).isEmpty, "the misspelled key is not reported: \(app.rig.elements(containing: "Line").map(\.name))")
        #expect(!app.rig.elements(containing: wrong).isEmpty, "the option that does not exist is not reported")
        // The line that is wrong is ignored: the pace is the default.
        try await openPane(app, "Scelte")
        #expect(segment(app, choice: "Pace", "Normal")?.selected == true, "a wrong line changed the pace")
    }

    /// #130: the list of sheets holds every built-in kind's name whole, on one line, in the four languages, beside an
    /// edited sheet's dot (the narrowest room a built-in name gets); a skill the user named longer than the row is cut at its
    /// end inside the row (#157); a click anywhere on a row (its glyph, its title, the empty space before its detail) selects
    /// that sheet.
    @Test(arguments: ["it", "en", "fr", "pt"])
    func theKindNamesFitTheirList(_ language: String) async throws {
        let saved = UserDefaults.standard.object(forKey: SettingsRoute.rulesKey)
        defer { UserDefaults.standard.set(saved, forKey: SettingsRoute.rulesKey) }
        UserDefaults.standard.set(RuleBook.everyVideo, forKey: SettingsRoute.rulesKey)
        let app = try await AppRig()
        defer { app.close() }
        let e = Engine(services: app.store.engine.context.services)
        for kind in [RuleBook.everyVideo] + RuleBook.builtInKinds { _ = try e.execute("rules.set", params: ["kind": .string(kind), "checks": ["text-size": false]]) }
        // «Per ogni video» and the five built-in recipes (#157), each edited sheet with its dot.
        let builtIn = [RuleBook.everyVideo] + Recipes.all.map(\.name)
        // A skill a user named, longer than the row, based on a recipe.
        let long = "Intervista lunga con due ospiti e le domande del pubblico in sala"
        let added = try e.execute("skill.create", params: ["title": .string(long), "basedOn": "screen-tutorial"])
        let longKind = try #require(added["skill"]?.stringValue)
        app.host(SettingsView(pinned: .rules).environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)),
                 size: SettingsView.size, language: language)
        await app.settle()
        let table = MouseRig.table(language)
        let titles = builtIn.map { table.localizedString(forKey: rulesBook(app).title($0, language: RuleBook.interfaceLanguage()), value: nil, table: nil) }
        _ = await app.until(3) { app.rig.controls().contains { $0.name.hasPrefix(titles.last!) } }
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-rules-list-\(language).png"))
        }
        let font = NSFont.systemFont(ofSize: Ed.TypeSize.control)
        let dot = naturalWidth("•", NSFont.systemFont(ofSize: Ed.TypeSize.small))
        func row(_ title: String) -> RigElement? {
            app.rig.controls().first { $0.visible && $0.role == "AXButton" && $0.name.hasPrefix(title) && $0.frame.maxX <= RulesSettings.listWidth + 1 }
        }
        for title in titles {
            guard let r = row(title) else {
                Issue.record("\(language): no row «\(title)»: \(app.rig.controls().map(\.description))"); continue
            }
            // The row: its padding, the glyph, a gap, the title, a gap, the detail.
            let room = r.frame.width - 2 * Ed.Space.s - 18 - Ed.Space.s - Ed.Space.s - dot
            let needed = naturalWidth(title, font)
            #expect(needed <= room, "\(language): «\(title)» needs \(needed) pt, its row \(r.frame) leaves \(room) pt beside the dot")
            #expect(r.name.contains("•"), "\(language): the edited sheet «\(title)» has no dot: «\(r.name)»")
        }
        // The user's skill: in the row, cut at its end, with no detail beside it (what it is based on is in its header).
        let longRow = try #require(row(String(long.prefix(12))), "\(language): no row for the user's skill")
        #expect(longRow.frame.maxX <= RulesSettings.listWidth + 1 && !longRow.name.contains("•"), "\(language): «\(longRow.name)» at \(longRow.frame)")

        // A click selects the row it lands on: at the glyph, on the title, in the space before the detail.
        let reel = try #require(row(titles[1]))
        for (i, point) in [CGPoint(x: reel.frame.minX + 12, y: reel.centre.y), reel.centre, CGPoint(x: reel.frame.maxX - 22, y: reel.centre.y)].enumerated() {
            app.rig.click(try #require(row(titles[0])).frame.origin.applying(.init(translationX: 30, y: 10)))
            _ = await app.until(2) { UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == RuleBook.everyVideo }
            #expect(UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == RuleBook.everyVideo, "\(language): «\(titles[0])» was not selected")
            let n = app.store.activity.count
            app.rig.click(point)
            _ = await app.until(2) { UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == builtIn[1] }
            await app.settle()
            #expect(UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == builtIn[1], "\(language): click \(i) at \(point) did not select «\(titles[1])»")
            #expect(app.commands(since: n).isEmpty, "\(language): a click on a row ran \(app.commands(since: n))")
            #expect(row(titles[1]) != nil, "\(language): the row is gone after the click")
        }
        app.rig.click(CGPoint(x: longRow.frame.maxX - 6, y: longRow.centre.y))
        _ = await app.until(2) { UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == longKind }
        #expect(UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == longKind, "\(language): a click at the end of the skill's row did not select it")
    }

    /// A row on the left opens its item; a skill's header problem shows under the checks with its line; on «Per ogni
    /// video», Importa… asks for a file and Mostra nel Finder shows the sheet's folder or file.
    @Test func aSkillsHeaderProblemShowsAndEveryVideoKeepsItsButtons() async throws {
        let saved = UserDefaults.standard.object(forKey: SettingsRoute.rulesKey)
        defer { UserDefaults.standard.set(saved, forKey: SettingsRoute.rulesKey) }
        UserDefaults.standard.removeObject(forKey: SettingsRoute.rulesKey)
        let app = try await AppRig()
        defer { app.close() }
        let book = rulesBook(app)
        await hostRules(app)

        let prose = { app.rig.elements().first { $0.role == "AXTextArea" }?.value ?? "" }
        let everyVideo = prose()
        // Importa… (the open panel, answered Cancel by the rig: nothing written) and Mostra nel Finder (recorded, not opened).
        var events = RigGuard.events.count
        var n = app.store.activity.count
        app.rig.click(try #require(control(app, containing: "Importa…")).centre)
        await app.settle()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .panel } && app.commands(since: n).isEmpty, "Importa… asked for no file")
        try await app.store.perform("rules.set", ["kind": "every-video", "checks": ["text-size": false]])
        _ = await until(app) { control(app, containing: "Ripristina il predefinito")?.enabled == true }
        await app.settle()
        events = RigGuard.events.count
        app.rig.click(try #require(control(app, containing: "Mostra nel Finder")).centre)
        await app.settle()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .finder && $0.detail.contains("every-video.md") },
                "Mostra nel Finder did not show the sheet's file: \(RigGuard.events.dropFirst(events))")

        // A skill written by hand with a mistake in its header: on screen with its line, its rules in the editor.
        try FileManager.default.createDirectory(at: book.skillsDirectory, withIntermediateDirectories: true)
        try Data("---\ntitle: YouTube tutorial\nsurprise: on\n---\n## Steps\n\n1. Record.\n\n## Rules\n\nZoom on every click.\n".utf8).write(to: book.file("youtube-tutorial"))
        RulesRevision.shared.bump()
        _ = await until(app) { control(app, containing: "YouTube tutorial") != nil }
        n = app.store.activity.count
        app.rig.click(try #require(control(app, containing: "YouTube tutorial"), "the hand-written skill is not listed").centre)
        _ = await until(app) { prose() != everyVideo }
        #expect(prose() == "Zoom on every click.\n", "the editor does not show the skill's rules: \(prose())")
        #expect(UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == "youtube-tutorial" && app.commands(since: n).isEmpty)
        _ = await until(app) { !app.rig.elements(containing: "Line 3:").isEmpty }
        #expect(!app.rig.elements(containing: "Line 3:").isEmpty, "the header problem is not shown with its line")
        #expect(control(app, containing: "Ripristina il predefinito") == nil, "a skill offers to reset a default")
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

        // The link opens Settings › Regia e skill on the project's kind.
        UserDefaults.standard.removeObject(forKey: SettingsRoute.tabKey)
        app.rig.click(try #require(control(app, containing: "Le regole si cambiano in Impostazioni › Regia e skill")).centre)
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

    /// #47: the kind menu's first entry leaves the kind to the project's format: chosen while the project has no kind of
    /// its own; a click on it runs project.setKind without a kind, once, and the card checks again with the format's kind.
    @Test func theKindMenuFollowsTheProjectsFormat() async throws {
        let app = try await AppRig()
        defer { app.close() }
        try await app.store.perform("project.setKind", ["kind": "voice-over-video"])
        app.hostEditor(Navigation(activity: .export, rightTab: .inspector))
        await app.settle()
        _ = await until(app, 4) { control(app, containing: "Voice-over video") != nil }
        app.rig.click(try #require(control(app, containing: "Voice-over video"), "the card does not show the project's kind").centre)
        await app.settle()
        let follow = try #require(control(app, containing: "Segui il formato del progetto"), "no entry for the format in the kinds")
        #expect(!follow.selected, "the format's entry is chosen while the project has a kind of its own")
        // Its line names the kind the format gives (a 9:16 reel: the talking-head reel).
        #expect(follow.name.contains("Talking-head reel"), "the entry does not name the format's kind: \(follow.name)")
        let n = app.store.activity.count
        app.rig.click(follow.centre)
        await app.settle()
        #expect(app.commands(since: n) == ["project.setKind"] && app.store.project?.kind == nil, "the entry ran \(app.commands(since: n))")
        // The card checks again: the kind is the format's; the menu closed, and opened again it has the format's entry chosen.
        #expect(await until(app, 4) { control(app, containing: "Talking-head reel") != nil }, "the card does not show the format's kind")
        #expect(control(app, containing: "Voice-over video") == nil && control(app, containing: "Segui il formato del progetto") == nil,
                "the kinds did not close after the choice")
        app.rig.click(try #require(control(app, containing: "Talking-head reel")).centre)
        await app.settle()
        #expect(control(app, containing: "Segui il formato del progetto")?.selected == true, "the format's entry is not chosen")
        // Choosing it again runs nothing.
        let m = app.store.activity.count
        app.rig.click(try #require(control(app, containing: "Segui il formato del progetto")).centre)
        await app.settle()
        #expect(app.commands(since: m).isEmpty, "choosing the entry already chosen ran \(app.commands(since: m))")
        #expect(control(app, containing: "Talking-head reel") != nil, "the kind button is gone")
        // With REGISTA_UI_SNAPSHOTS: the menu open, in Italian and French, to look at.
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            for language in ["it", "fr"] {
                app.hostEditor(Navigation(activity: .export, rightTab: .inspector), language: language)
                await app.settle()
                _ = await until(app, 4) { app.rig.elements().contains { $0.isControl && $0.label.hasPrefix(language == "it" ? "Reel parlato" : "Reel face caméra") } }
                if let kind = app.rig.elements().first(where: { $0.isControl && $0.label.hasPrefix(language == "it" ? "Reel parlato" : "Reel face caméra") }) {
                    app.rig.click(kind.centre)
                    await app.settle()
                }
                try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("kind-menu-\(language).png"))
            }
        }
    }

    /// «Esporta lo stesso» is always there while a rule fails, even when no fix exists; it asks where, then exports with
    /// the override (the save panel is answered Cancel by the rig; the call is the one the button builds).
    @Test func exportAnywayIsAlwaysOffered() async throws {
        let app = try await AppRig()
        defer { app.close() }
        // A title too small to read: a rule without an automatic fix.
        try await app.store.perform("title.add", ["text": "piccolo", "start": 1, "duration": 2, "size": 10])
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

extension MouseSuites {
/// «Logo nel video» follows the project's rules (#74): with «The logo only at the end» on (the default), the switch puts the
/// logo in the closing 2 s of the video and its caption says so; with the rule off, the brand's corner for the whole video.
/// Grafica › Logo and Semplice › Grafica, by clicks on the real window.
@Suite(.serialized) @MainActor struct LogoSwitchMouseTests {
    private func logoSwitch(_ app: AppRig) -> RigElement? {
        app.rig.elements().first { $0.isControl && $0.visible && $0.label.hasPrefix("Logo nel video") && ["0", "1"].contains($0.value) }
    }
    private func logos(_ app: AppRig) -> [Clip] { app.store.project?.tracks.filter { $0.role == "logo" }.flatMap(\.clips) ?? [] }
    private var atEnd: String { LogoSwitch.caption(atEnd: true) }
    private let corner = "Nell'angolo della marca, per tutto il video."

    /// Clicks the switch: one command, the switch still there and flipped.
    private func flip(_ app: AppRig, _ command: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let sw = try #require(logoSwitch(app), "no «Logo nel video»", sourceLocation: sourceLocation)
        let was = sw.value
        let n = app.store.activity.count
        app.rig.click(sw.centre)
        await app.settle()
        #expect(app.commands(since: n) == [command], "the switch ran \(app.commands(since: n))", sourceLocation: sourceLocation)
        #expect(logoSwitch(app).map { $0.value != was } == true, "the switch is gone or did not flip", sourceLocation: sourceLocation)
    }

    /// The rig's rules folder is the test process's: the sheet switched off here is put back whatever happens.
    private func check(_ app: AppRig, open: () async throws -> Void) async throws {
        do { try await steps(app, open: open) } catch {
            _ = try? await app.store.silent("rules.reset", ["kind": "every-video"])
            throw error
        }
        _ = try await app.store.silent("rules.reset", ["kind": "every-video"])
    }

    private func steps(_ app: AppRig, open: () async throws -> Void) async throws {
        let book = app.store.engine.context.services.rules
        try await app.store.perform("brandkit.apply", ["kit": "cafe-atelier"])
        let end = try #require(app.store.project?.videoEnd).seconds
        // The rule on (the shipped sheets).
        #expect(book.logoOnlyAtEnd(try #require(app.store.project)))
        try await open()
        #expect(app.rig.elements(containing: atEnd).isEmpty == false, "the caption does not say the logo goes at the end")
        try await flip(app, "logo.add")
        let closing = try #require(logos(app).first, "no logo")
        #expect(logos(app).count == 1 && abs(closing.start.seconds - (end - 2)) < 0.04 && abs(closing.end.seconds - end) < 0.04,
                "the logo is \(closing.start.seconds)–\(closing.end.seconds) s, not the last 2 s of a \(end) s video")
        #expect(try await app.store.silent("rules.check")["violations"]?.arrayValue?.contains { $0["check"] == "logo-end" } == false,
                "the logo the switch placed breaks «The logo only at the end»")
        try await flip(app, "timeline.delete")
        #expect(logos(app).isEmpty)
        // The rule off: the corner for the whole video.
        try await app.store.perform("rules.set", ["kind": "every-video", "checks": ["logo-end": false]])
        #expect(!book.logoOnlyAtEnd(try #require(app.store.project)))
        try await open()
        #expect(app.rig.elements(containing: corner).isEmpty == false, "with the rule off the caption does not say the corner")
        try await flip(app, "logo.add")
        let whole = try #require(logos(app).first, "no logo")
        #expect(whole.start == .zero && abs(whole.end.seconds - (app.store.project?.duration.seconds ?? 0)) < 0.04,
                "with the rule off the logo is \(whole.start.seconds)–\(whole.end.seconds) s, not the whole video")
    }

    @Test func grafica() async throws {
        let app = try await AppRig()
        defer { app.close() }
        var nav = Navigation(activity: .graphics, rightTab: .inspector)
        nav.graphicsSection = .logo
        try await check(app) {
            app.hostEditor(nav)
            await app.settle()
            _ = await until(app) { logoSwitch(app) != nil }
        }
        // A long language, for a look at the caption's wrap ($REGISTA_UI_SNAPSHOTS).
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            app.hostEditor(nav, language: "fr")
            await app.settle()
            try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("logo-switch-fr.png"))
        }
    }

    @Test func semplice() async throws {
        let app = try await AppRig()
        defer { app.close() }
        try await check(app) {
            app.hostEditor(Navigation(activity: .media, level: .simple, rightTab: .inspector))
            await app.settle()
            // The rail's Grafica row (in the rail's column, under «Fai tutto»).
            let all = app.rig.elements()
            let doAll = try #require(all.first { $0.isControl && $0.label.hasPrefix("Taglia, sceglie le riprese") }, "no rail")
            let title = SimpleStep.graphics.title()
            let row = try #require(all.first { $0.role == "AXButton" && $0.frame.minX >= doAll.frame.minX - 4 && $0.frame.maxX <= doAll.frame.maxX + 4
                && ($0.label == title || $0.label.components(separatedBy: ", ").contains(title)) }, "no Grafica on the rail")
            app.rig.click(row.centre)
            await app.settle()
            _ = await until(app) { logoSwitch(app) != nil }
        }
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
        "sheetProblems": [["sheet": "every-video", "line": 2, "message": "m", "messageKey": "Line %1$@: unknown check or choice «%2$@».", "messageArgs": ["2", "x"]]],
        "note": .null,
    ], list: ["sheets": [["kind": "every-video", "title": "For every video", "builtIn": true], ["kind": "talking-head-reel", "title": "Talking-head reel", "builtIn": true],
                         ["kind": "yt", "title": "YouTube", "builtIn": false]]])
    #expect(report.kinds.map(\.kind) == ["talking-head-reel", "yt"])
    #expect(report.failures.count == 1 && report.violations.count == 2 && report.fixable)
    #expect(report.violations[0].message == "Captions show while the opening title is on screen (0.00–2.00 s).")
    #expect(report.violations[0].fix == StepCall(id: "captions.clear", params: ["from": 0, "to": 2]) && report.violations[1].fix == nil)
    #expect(report.passed == ["The logo only at the end"], "a check that did not run is not counted as passed")
    #expect(report.problems == ["Line 2: unknown check or choice «x»."])
    #expect(ExportRulesCard.time(41.8) == "0:41" && ExportRulesCard.time(0.3) == "0:00")
}

/// #47: the rule messages give their numbers as values; the interface writes them as its language does (a decimal comma
/// in Italian, French and Portuguese, a point in English), the engine's English sentence keeps the point. One message
/// with a time range, one with a pause, in each language.
@MainActor
@Test(arguments: [("it", ","), ("en", "."), ("fr", ","), ("pt", ",")])
func ruleMessagesWriteNumbersInTheInterfaceLanguage(_ language: String, _ point: String) {
    let range = RuleText(rulePhrase("Captions show while the opening title is on screen (%1$@–%2$@ s)."), RuleText.s(1.25), RuleText.s(3.5))
    let pause = RuleText(rulePhrase("The logo enters %1$@ s after the last spoken word: the pause must be at least %2$@ s."),
                         RuleText.s(0.16), RuleText.s(0.3))
    #expect(range.json["messageArgs"] == [1.25, 3.5] && pause.json["messageArgs"] == [0.16, 0.3], "the values are not numbers")
    #expect(range.english.contains("(1.25–3.50 s)") && pause.english.contains("0.16 s after") && pause.english.contains("at least 0.30 s"))
    // The window's words in `language`, read here on the main thread only (MouseRig's way, without a window).
    Words.override = MouseRig.table(language)
    Words.applies = { true }
    defer { Words.override = nil; Words.applies = nil }
    let shownRange = loc(message: range.json), shownPause = loc(message: pause.json)
    #expect(shownRange.contains("1\(point)25") && shownRange.contains("3\(point)5 s"), "\(language): \(shownRange)")
    #expect(shownPause.contains("0\(point)16") && shownPause.contains("0\(point)3 s"), "\(language): \(shownPause)")
    #expect(shownRange != range.english || language == "en", "\(language): the message is not translated: \(shownRange)")
    let other = point == "," ? "." : ","
    #expect(!shownRange.contains("1\(other)25") && !shownPause.contains("0\(other)3"), "\(language): \(shownRange) / \(shownPause)")
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

/// The rich fixture with its take marked as a generated (cloned) voice: what voice.say leaves on the timeline.
@MainActor private func projectWithGeneratedVoice() throws -> URL {
    let folder = try RigProject.rich()
    let file = folder.appendingPathComponent("project.json")
    var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var assets = try #require(json["assets"] as? [[String: Any]])
    assets[0]["generated"] = ["provider": "voxcpm", "model": "voxcpm2", "kind": "voice", "prompt": "Oggi Regista monta il reel.", "cost": 0,
                              "unit": "credits", "created": "2026-11-16T10:00:00Z", "jobID": "job-1", "requestHash": "rig"]
    json["assets"] = assets
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    return folder
}

// #25: the AI-voice note where a person exports. With an audible generated voice clip the Export panel shows, with the
// checks, «Voce generata con IA», its sentence and «Copia» (once on the rig's pasteboard); without one, no such row. After an
// export whose result carries aiDisclosure, «Ultimo export» carries the same note.
extension MouseSuites {
@Suite(.serialized) @MainActor struct AIVoiceNoteMouseTests {
    @Test func theExportPanelShowsTheAIVoiceNote() async throws {
        let sentence = AIVoiceNote.sentence
        // Without a generated voice: no row.
        do {
            let app = try await AppRig()
            defer { app.close() }
            app.hostEditor(Navigation(activity: .export, rightTab: .inspector))
            await app.settle()
            #expect(app.store.project?.hasAudibleGeneratedVoice == false)
            #expect(app.rig.elements(containing: "Voce generata con IA").isEmpty, "the note shows without a generated voice")
        }
        let app = try await AppRig(project: nil)
        defer { app.close() }
        try await app.store.perform("project.open", ["path": .string(try projectWithGeneratedVoice().path)])
        _ = await until(app, 10) { app.store.project?.hasAudibleGeneratedVoice == true }
        #expect(app.store.project?.hasAudibleGeneratedVoice == true)
        app.hostEditor(Navigation(activity: .export, rightTab: .inspector))
        await app.settle()
        func row() -> RigElement? { app.rig.elements(containing: "Voce generata con IA").first }
        func copy() -> RigElement? {
            guard let r = row() else { return nil }
            return app.rig.elements().filter { $0.isControl && $0.name == "Copia" && $0.visible && abs($0.centre.y - r.centre.y) < 14 }.first
        }
        #expect(await until(app, 4) { row() != nil }, "no «Voce generata con IA» row with a generated voice on the timeline")
        #expect(!app.rig.elements(containing: sentence).isEmpty, "the row has no sentence under it")
        // In view (the panel scrolls), then «Copia», once.
        let start = try #require(row()).centre
        for _ in 0..<20 where copy().map({ !$0.clip.contains($0.frame) }) ?? true {
            app.rig.scrollContent(at: CGPoint(x: start.x, y: 300), by: 60)
            await app.settle()
        }
        let button = try #require(copy(), "the row has no «Copia» in view")
        let n = app.store.activity.count, changes = rigPasteboard.changeCount
        app.rig.click(button.centre)
        await app.settle()
        #expect(rigPasteboard.string(forType: .string) == sentence, "«Copia» put \(rigPasteboard.string(forType: .string) ?? "nothing") on the pasteboard")
        #expect(rigPasteboard.changeCount == changes + 1, "«Copia» wrote \(rigPasteboard.changeCount - changes) times")
        #expect(app.commands(since: n).isEmpty, "«Copia» ran \(app.commands(since: n))")
        #expect(copy() != nil, "«Copia» is gone after the click")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("export-ai-voice-note.png"))
        }

        // An export with that voice: «Ultimo export» carries the note too.
        let out = rigTempDir("ai-voice-export").appendingPathComponent("reel.mp4")
        try await app.store.perform("export.render", ["path": .string(out.path), "preset": "9:16", "exportAnyway": true])
        let last = try #require(app.store.activity.last { $0.command == "export.render" })
        #expect(last.status == .ok && last.aiDisclosure, "the export's activity does not carry aiDisclosure (\(last.status), \(last.result))")
        await app.settle()
        // (Counted in the whole panel, the part below the fold included.)
        func notes() -> Int { app.rig.elements().filter { $0.role == "AXStaticText" && $0.name == "Voce generata con IA" }.count }
        #expect(await until(app, 4) { notes() == 2 }, "«Ultimo export» does not carry the note: \(notes()) rows")
        // With REGISTA_UI_SNAPSHOTS: the panel in French too, scrolled to «Ultimo export».
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            app.rig.scrollContent(at: CGPoint(x: start.x, y: 300), by: 2000)
            await app.settle()
            try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("export-ai-voice-last-it.png"))
            app.hostEditor(Navigation(activity: .export, rightTab: .inspector), language: "fr")
            await app.settle()
            try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("export-ai-voice-note-fr.png"))
            app.rig.scrollContent(at: CGPoint(x: start.x, y: 300), by: 2000)
            await app.settle()
            try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("export-ai-voice-last-fr.png"))
        }
    }
}
}

