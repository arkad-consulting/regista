import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista
@testable import RegistaCore

// The person's skills in Impostazioni › Regia e skill (#157), driven with real mouse and key events (MouseRig) on the live
// tab over the rig's scratch support folder: the built-ins read-only with Duplica, a skill's three tabs (each change one
// skill.set), Esporta… and Importa una skill… through the panels the rig answers, ⋯ (Rinomina, Elimina), «Chiedi a Claude».

@MainActor private func skillsBook(_ app: AppRig) -> RuleBook { app.store.engine.context.services.rules }

@MainActor private func until(_ app: AppRig, _ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > end { return false }
        await app.idle(0.05)
    }
    return true
}

@MainActor private func control(_ app: AppRig, _ name: String) -> RigElement? {
    app.rig.elements().first { $0.isControl && $0.visible && $0.name == name }
}

@MainActor private func control(_ app: AppRig, containing text: String) -> RigElement? {
    app.rig.elements(containing: text).first { $0.isControl }
}

/// A switch of a check (an RSwitch named by the check's title, valued 0 / 1).
@MainActor private func ruleSwitch(_ app: AppRig, _ title: String) -> RigElement? {
    app.rig.elements().first { $0.label == title && $0.isControl && ($0.value == "0" || $0.value == "1") && $0.visible }
}

/// A segment of a choice's row, right of its title.
@MainActor private func segment(_ app: AppRig, choice: String, _ label: String) -> RigElement? {
    guard let t = app.rig.elements().first(where: { $0.role == "AXStaticText" && $0.value == choice }) else { return nil }
    return app.rig.elements().first { $0.isControl && abs($0.centre.y - t.centre.y) < 8 && $0.frame.minX > t.frame.maxX && $0.name == label }
}

@MainActor private func editor(_ app: AppRig) -> RigElement? { app.rig.elements().first { $0.role == "AXTextArea" && $0.visible } }

/// The same, in view or not (what `reveal` scrolls to).
@MainActor private func anyEditor(_ app: AppRig) -> RigElement? { app.rig.elements().first { $0.role == "AXTextArea" } }

@MainActor private func anyControl(_ app: AppRig, _ name: String) -> RigElement? {
    app.rig.elements().first { $0.isControl && $0.name == name }
}

/// Scrolls the item's pane until what `find` returns is whole in view.
@MainActor private func reveal(_ app: AppRig, _ find: () -> RigElement?, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0..<40 {
        let e = try #require(find(), "nothing to bring into view", sourceLocation: sourceLocation)
        guard let pane = app.rig.elements().filter({ $0.role == "AXScrollArea" && $0.frame.minX > RulesSettings.listWidth })
            .max(by: { $0.frame.height < $1.frame.height })?.frame else { return }
        if pane.insetBy(dx: 0, dy: -0.5).contains(e.frame) || (e.frame.height >= pane.height - 4 && pane.contains(e.centre)) { return }
        app.rig.scrollContent(at: CGPoint(x: pane.midX, y: pane.minY + 12), by: e.frame.midY > pane.midY ? 80 : -80)
        await app.settle()
    }
    Issue.record("could not bring \(find()?.description ?? "it") into view", sourceLocation: sourceLocation)
}

/// A skill of the person's on the rig's folder, made as Claude would make it.
@MainActor private func makeSkill(_ app: AppRig, _ title: String = "Long interview", basedOn: String? = "talking-head-reel") async throws -> String {
    var params: [String: JSONValue] = ["title": .string(title), "steps": "1. Read the questions.\n2. Cut the pauses.",
                                       "rules": ["prose": "No music under the answers."], "choices": ["captions": "elegant-serif"]]
    if let basedOn { params["basedOn"] = .string(basedOn) }
    return try #require(try await app.store.silent("skill.create", .object(params))["skill"]?.stringValue)
}

/// A skill file someone wrote, in a scratch folder of its own.
private func skillFile(_ text: String, name: String = "from-a-colleague.md") throws -> URL {
    let dir = TemporaryFolder.url.appendingPathComponent("skills-ui-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct SkillsMouseTests {
    private func host(_ app: AppRig, select name: String, language: String? = nil, height: CGFloat? = nil) async {
        UserDefaults.standard.set(name, forKey: SettingsRoute.rulesKey)
        let h = height ?? SettingsView.size.height
        app.host(SettingsView(pinned: .rules, height: h).environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)),
                 size: CGSize(width: SettingsView.size.width, height: h), language: language)
        await app.settle()
        _ = await until(app, 4) { ruleSwitch(app, "Minimum text size") != nil || app.rig.elements().contains { $0.label == "Minimum text size" } }
        await app.settle()
    }

    private func pane(_ app: AppRig, _ title: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let tab = try #require(control(app, title), "no tab «\(title)»: \(app.rig.controls().map(\.description))", sourceLocation: sourceLocation)
        let n = app.store.activity.count
        app.rig.click(tab.centre)
        await app.settle()
        #expect(app.commands(since: n).isEmpty, "the tab «\(title)» ran \(app.commands(since: n))", sourceLocation: sourceLocation)
        #expect(control(app, title)?.selected == true, "the tab «\(title)» is not chosen", sourceLocation: sourceLocation)
    }

    private func keepSelection() -> () -> Void {
        let saved = UserDefaults.standard.object(forKey: SettingsRoute.rulesKey)
        return { UserDefaults.standard.set(saved, forKey: SettingsRoute.rulesKey) }
    }

    /// A built-in recipe reads, never changes: Duplica only in its header, its switches and choices answer no click, its
    /// steps are text; Duplica makes a skill based on it, with its steps, on screen at once.
    @Test func aBuiltInIsReadOnlyAndDuplicaMakesASkillOfIt() async throws {
        let restore = keepSelection()
        defer { restore() }
        let app = try await AppRig()
        defer { app.close() }
        let book = skillsBook(app)
        await host(app, select: "talking-head-reel")
        #expect(control(app, "Duplica") != nil, "no Duplica on a built-in")
        #expect(control(app, "Esporta…") == nil && control(app, containing: "Rinomina o elimina") == nil, "a built-in offers to export or rename")
        // A switch and a choice: nothing runs, nothing is written.
        let n = app.store.activity.count
        app.rig.click(try #require(ruleSwitch(app, "Minimum text size")).centre)
        await app.settle()
        try await pane(app, "Scelte")
        app.rig.click(try #require(segment(app, choice: "Pace", "Fast"), "no pace on the reel").centre)
        await app.settle()
        #expect(app.commands(since: n).isEmpty, "a click on a built-in ran \(app.commands(since: n))")
        #expect(!book.edited("talking-head-reel") && book.userKinds.isEmpty)
        // Its steps: the recipe's, as text, no editor.
        try await pane(app, "Passi")
        let shown = { app.rig.elements().contains { $0.value.contains("1. Find the material") || $0.label.contains("1. Find the material") } }
        _ = await until(app) { shown() }
        #expect(shown(), "the recipe's steps are not shown")
        #expect(editor(app) == nil, "a built-in's steps can be typed into")
        // Duplica.
        let m = app.store.activity.count
        app.rig.click(try #require(control(app, "Duplica")).centre)
        _ = await until(app) { !book.userKinds.isEmpty }
        await app.settle()
        #expect(app.commands(since: m) == ["skill.duplicate"], "Duplica ran \(app.commands(since: m))")
        let slug = try #require(book.userKinds.first)
        #expect(book.skill(slug)?.title == "Talking-head reel (copia)" && book.skill(slug)?.basedOn == "talking-head-reel")
        #expect(book.skill(slug)?.steps == Recipes.talkingHeadReel.steps)
        _ = await until(app) { control(app, "Esporta…") != nil }
        #expect(UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == slug, "the copy is not on screen")
        #expect(control(app, "Esporta…") != nil && editor(app) != nil, "the copy's steps cannot be changed")
        #expect(app.rig.controls().contains { $0.name.hasPrefix("Talking-head reel (copia)") && $0.frame.maxX <= RulesSettings.listWidth + 1 },
                "the copy is not in the list")
    }

    /// A skill's three tabs: a switch, the prose, a choice and the steps each run skill.set once and change the skill's
    /// file; the steps say «salvato»; Mostra nel Finder shows the file; «Chiedi a Claude» copies its sentence; an undo puts
    /// the steps back on screen.
    @Test func aSkillsTabsEachSaveThroughSkillSet() async throws {
        let restore = keepSelection()
        defer { restore() }
        let app = try await AppRig()
        defer { app.close() }
        let book = skillsBook(app)
        let slug = try await makeSkill(app)
        let file = book.file(slug)
        await host(app, select: slug)
        func changed(_ what: String, _ body: () async throws -> Void, wait: Double = 3, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let before = FileManager.default.contents(atPath: file.path)
            let n = app.store.activity.count
            try await body()
            _ = await until(app, wait) { FileManager.default.contents(atPath: file.path) != before }
            await app.settle()
            #expect(app.commands(since: n) == ["skill.set"], "\(what) ran \(app.commands(since: n))", sourceLocation: sourceLocation)
            #expect(FileManager.default.contents(atPath: file.path) != before, "\(what) did not change the skill's file", sourceLocation: sourceLocation)
        }
        // Regole: a switch, then the prose.
        try await changed("the switch") { app.rig.click(try #require(ruleSwitch(app, "The logo only at the end")).centre) }
        #expect(RuleSheetText.parse(book.skill(slug)?.sheetText ?? "").entries.first { $0.id == "logo-end" }?.on == false)
        #expect(!book.edited(RuleBook.everyVideo), "a skill's switch wrote «Per ogni video»")
        try await reveal(app) { anyEditor(app) }
        try await changed("the prose", {
            let e = try #require(editor(app))
            app.rig.click(CGPoint(x: e.frame.maxX - 20, y: e.frame.maxY - 12))
            app.rig.pump(0.1)
            app.rig.key(.end, modifiers: .command)
            app.rig.type(" QX")
        }, wait: 4)
        #expect(book.skill(slug)?.rules.contains("QX") == true)
        // Scelte.
        try await pane(app, "Scelte")
        try await reveal(app) { segment(app, choice: "Pace", "Fast") }
        try await changed("the Fast segment") { app.rig.click(try #require(segment(app, choice: "Pace", "Fast")).centre) }
        #expect(RuleSheetText.parse(book.skill(slug)?.sheetText ?? "").choices.contains { $0.id == "pace" && $0.value == "fast" })
        // Passi.
        try await pane(app, "Passi")
        try await changed("the steps", {
            let e = try #require(editor(app), "no steps editor")
            #expect(e.value.hasPrefix("1. Read the questions."), "the editor does not hold the steps: \(e.value.prefix(40))")
            app.rig.click(CGPoint(x: e.frame.maxX - 20, y: e.frame.maxY - 12))
            app.rig.pump(0.1)
            app.rig.key(.end, modifiers: .command)
            app.rig.type("\n3. Look at the frames.")
        }, wait: 4)
        #expect(book.skill(slug)?.steps.hasSuffix("3. Look at the frames.") == true)
        #expect(!app.rig.elements(containing: "salvato").isEmpty, "the steps do not say saved")
        // Mostra nel Finder: the skill's file (recorded, not opened).
        var events = RigGuard.events.count
        try await reveal(app) { anyControl(app, "Mostra nel Finder") }
        app.rig.click(try #require(control(app, "Mostra nel Finder")).centre)
        await app.settle()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .finder && $0.detail.contains("\(slug).md") }, "\(RigGuard.events.dropFirst(events))")
        // Chiedi a Claude: the sentence on the (rig's) pasteboard, nothing run.
        rigPasteboard.clearContents()
        events = app.store.activity.count
        try await reveal(app) { anyControl(app, "Copia") }
        app.rig.click(try #require(control(app, "Copia")).centre)
        await app.settle()
        let copied = rigPasteboard.string(forType: .string) ?? ""
        #expect(copied.contains("Long interview") && copied.contains("Nella mia skill"), "Copia put «\(copied)»")
        #expect(app.commands(since: events).isEmpty)
        // Undo (⌘Z in the app): the steps as before, on screen too.
        try await app.store.perform("history.undo")
        _ = await until(app) { editor(app)?.value.contains("Look at the frames") == false }
        #expect(book.skill(slug)?.steps == "1. Read the questions.\n2. Cut the pauses.", "undo did not put the steps back")
        #expect(editor(app)?.value.contains("Look at the frames") == false, "the editor still shows the undone steps")
    }

    /// Esporta… writes the file where the save panel says; ⋯ › Rinomina… renames it (skill.set), ⋯ › Elimina… asks, then
    /// removes it (skill.remove), and an undo brings it back to the list.
    @Test func exportRenameAndDeleteThroughTheirControls() async throws {
        let restore = keepSelection()
        defer { restore() }
        let app = try await AppRig()
        defer { app.close() }
        let book = skillsBook(app)
        let slug = try await makeSkill(app)
        await host(app, select: slug)
        // Esporta…: the panel answered with a scratch file.
        let out = TemporaryFolder.url.appendingPathComponent("skills-export-\(UUID().uuidString.prefix(6)).md")
        RigGuard.panelAnswer = [out]
        var n = app.store.activity.count
        app.rig.click(try #require(control(app, "Esporta…")).centre)
        _ = await until(app) { FileManager.default.fileExists(atPath: out.path) }
        await app.settle()
        #expect(app.commands(since: n) == ["skill.export"], "Esporta… ran \(app.commands(since: n))")
        #expect(FileManager.default.contents(atPath: out.path) == FileManager.default.contents(atPath: book.file(slug).path))
        // ⋯ › Rinomina…
        func more() async throws -> MouseRig {
            app.rig.takeKey()
            let menu = try #require(app.rig.elements().first { $0.isControl && $0.visible && $0.frame.minX > RulesSettings.listWidth && $0.name.contains("Rinomina o elimina la skill") },
                                    "no ⋯ button: \(app.rig.controls().map(\.description))")
            app.rig.click(menu.centre)
            return try #require(await openedPopover(app), "⋯ did not open")
        }
        var pop = try await more()
        pop.click(try #require(pop.elements().first { $0.isControl && $0.name.hasPrefix("Rinomina") }).centre)
        await app.settle()
        let field = try #require(app.rig.elements().first { $0.role == "AXTextField" && $0.label == "Nome della skill" && $0.visible }, "no rename field")
        app.rig.click(field.centre)
        app.rig.pump(0.1)
        app.rig.key(.end, modifiers: .command)
        for _ in field.value { app.rig.key(.delete) }   // empty the field as a person would
        app.rig.type("Interview")
        n = app.store.activity.count
        app.rig.key(.returnKey)
        _ = await until(app) { book.skill(slug)?.title == "Interview" }
        await app.settle()
        #expect(app.commands(since: n) == ["skill.set"] && book.skill(slug)?.title == "Interview", "Rinomina ran \(app.commands(since: n)), title «\(book.skill(slug)?.title ?? "none")»")
        _ = await until(app) { app.rig.controls().contains { $0.name.hasPrefix("Interview") && $0.frame.maxX <= RulesSettings.listWidth + 1 } }
        #expect(app.rig.controls().contains { $0.name.hasPrefix("Interview") && $0.frame.maxX <= RulesSettings.listWidth + 1 }, "the list keeps the old title")
        // ⋯ › Elimina…: a confirmation, then the file is gone and «Per ogni video» is on screen.
        pop = try await more()
        pop.click(try #require(pop.elements().first { $0.isControl && $0.name.hasPrefix("Elimina") }).centre)
        await app.settle()
        let confirm = try #require(app.rig.sheetButtons().first { $0.title == "Elimina" }, "no confirmation: \(app.rig.sheetButtons().map(\.title))")
        n = app.store.activity.count
        app.rig.click(confirm)
        _ = await until(app) { book.skill(slug) == nil }
        await app.settle()
        #expect(app.commands(since: n) == ["skill.remove"], "Elimina ran \(app.commands(since: n))")
        #expect(UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == RuleBook.everyVideo)
        #expect(!app.rig.controls().contains { $0.name.hasPrefix("Interview") }, "the removed skill is still listed")
        // Undo brings it back, in the list too.
        try await app.store.perform("history.undo")
        _ = await until(app) { app.rig.controls().contains { $0.name.hasPrefix("Interview") } }
        #expect(book.skill(slug)?.title == "Interview" && app.rig.controls().contains { $0.name.hasPrefix("Interview") }, "undo did not bring the skill back")
    }

    /// «+ Nuova skill…»: Annulla closes the form with no command; Crea makes an empty skill (skill.create) and shows its steps.
    @Test func aNewSkillIsMadeFromItsForm() async throws {
        let restore = keepSelection()
        defer { restore() }
        let app = try await AppRig()
        defer { app.close() }
        let book = skillsBook(app)
        await host(app, select: RuleBook.everyVideo)
        var n = app.store.activity.count
        app.rig.click(try #require(control(app, "+ Nuova skill…")).centre)
        await app.settle()
        app.rig.click(try #require(control(app, "Annulla"), "no Annulla in the form").centre)
        await app.settle()
        #expect(app.rig.elements().first { $0.role == "AXTextField" && $0.label == "Nome della skill" } == nil && app.commands(since: n).isEmpty)
        app.rig.click(try #require(control(app, "+ Nuova skill…")).centre)
        await app.settle()
        let field = try #require(app.rig.elements().first { $0.role == "AXTextField" && $0.label == "Nome della skill" }, "no name field")
        app.rig.click(field.centre)
        app.rig.pump(0.1)
        app.rig.type("Studio interview")
        n = app.store.activity.count
        app.rig.click(try #require(control(app, "Crea")).centre)
        _ = await until(app) { book.skill("studio-interview") != nil }
        await app.settle()
        #expect(app.commands(since: n) == ["skill.create"], "Crea ran \(app.commands(since: n))")
        #expect(book.skill("studio-interview")?.title == "Studio interview" && book.skill("studio-interview")?.basedOn == nil)
        _ = await until(app) { editor(app) != nil && control(app, "Passi")?.selected == true }
        #expect(control(app, "Passi")?.selected == true && editor(app) != nil, "the new skill's steps are not on screen")
    }

    /// «Importa una skill…»: the open panel, then a sheet with what the file says (nothing written) — Annulla closes it,
    /// Aggiungi adds it; a file that is not a skill, or holds a path, is refused with the reason and no sheet; the same
    /// title offers Sostituisci or another title.
    @Test func importShowsWhatTheFileSaysBeforeAddingIt() async throws {
        let restore = keepSelection()
        defer { restore() }
        let app = try await AppRig()
        defer { app.close() }
        let book = skillsBook(app)
        await host(app, select: RuleBook.everyVideo)
        let good = try skillFile("---\ntitle: Colleague's reel\nbased-on: talking-head-reel\nmusic: never\ntext-size: on 36\n---\n## Steps\n\n1. Cut tight.\n\n## Rules\n\nNo zoom.\n")
        func importing(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            RigGuard.panelAnswer = [url]
            let events = RigGuard.events.count
            let n = app.store.activity.count
            app.rig.click(try #require(control(app, "Importa una skill…"), sourceLocation: sourceLocation).centre)
            _ = await until(app) { RigGuard.events.count > events }
            await app.settle()
            #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .panel }, "no open panel", sourceLocation: sourceLocation)
            #expect(app.commands(since: n).isEmpty, "reading the file ran \(app.commands(since: n))", sourceLocation: sourceLocation)
        }
        // The sheet, then Annulla.
        try await importing(good)
        _ = await until(app) { control(app, "Aggiungi") != nil }
        for text in ["Colleague's reel", "Talking-head reel", "Cut tight.", "No zoom.", "Background music: Never", "Minimum text size: 36"] {
            #expect(!app.rig.elements(containing: text).isEmpty, "the sheet does not show «\(text)»")
        }
        #expect(book.userKinds.isEmpty, "the file was added before Aggiungi")
        var n = app.store.activity.count
        app.rig.click(try #require(control(app, "Annulla")).centre)
        await app.settle()
        #expect(control(app, "Aggiungi") == nil && app.commands(since: n).isEmpty && book.userKinds.isEmpty, "Annulla did not close the sheet")
        // Aggiungi.
        try await importing(good)
        _ = await until(app) { control(app, "Aggiungi") != nil }
        n = app.store.activity.count
        app.rig.click(try #require(control(app, "Aggiungi")).centre)
        _ = await until(app) { !book.userKinds.isEmpty }
        await app.settle()
        #expect(app.commands(since: n) == ["skill.import"], "Aggiungi ran \(app.commands(since: n))")
        let slug = try #require(book.userKinds.first)
        #expect(book.skill(slug)?.title == "Colleague's reel" && UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) == slug)
        // Not a skill; a path: the reason, no sheet, nothing written.
        for (text, reason) in [("# Just notes\n", "not a skill"), ("---\ntitle: Paths\n---\n## Steps\n\n1. Open ~/Movies/take.mov\n", "path of a computer")] {
            try await importing(try skillFile(text))
            _ = await until(app) { !app.rig.elements(containing: reason).isEmpty }
            #expect(!app.rig.elements(containing: reason).isEmpty, "the refusal does not say «\(reason)»")
            #expect(control(app, "Aggiungi") == nil && book.userKinds == [slug])
        }
        // The same title: Sostituisci, then another title.
        let same = try skillFile("---\ntitle: colleague's reel\n---\n## Steps\n\n1. Other steps.\n")
        try await importing(same)
        _ = await until(app) { control(app, "Sostituisci") != nil }
        #expect(!app.rig.elements(containing: "Hai già una skill").isEmpty, "the conflict is not said")
        n = app.store.activity.count
        app.rig.click(try #require(control(app, "Sostituisci")).centre)
        _ = await until(app) { book.skill(slug)?.steps == "1. Other steps." }
        await app.settle()
        #expect(app.commands(since: n) == ["skill.import"] && book.userKinds == [slug], "Sostituisci ran \(app.commands(since: n)) (\(book.userKinds))")
        try await importing(same)
        _ = await until(app) { control(app, "Sostituisci") != nil }
        n = app.store.activity.count
        app.rig.click(try #require(control(app, "Aggiungi")).centre)
        _ = await until(app) { book.userKinds.count == 2 }
        await app.settle()
        #expect(app.commands(since: n) == ["skill.import"] && book.userKinds.count == 2, "a new title ran \(app.commands(since: n))")
        let titles: [String] = book.userKinds.compactMap { book.skill($0)?.title }
        #expect(titles.contains("colleague's reel (copia)"), "\(titles)")
    }

    /// The tab read at full size in Italian and French (REGISTA_UI_SNAPSHOTS): a skill's three tabs, the import sheet and a
    /// built-in read-only; every title of the header and every tab whole in its place.
    @Test(arguments: ["it", "fr"])
    func theTabReadsWholeInItsLanguage(_ language: String) async throws {
        let restore = keepSelection()
        defer { restore() }
        let app = try await AppRig()
        defer { app.close() }
        let slug = try await makeSkill(app, "Service desk YouTube")
        let table = MouseRig.table(language)
        let word = { (key: String) in table.localizedString(forKey: key, value: nil, table: nil) }
        let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        func shoot(_ name: String) { if let dir { try? app.snapshot(to: dir.appendingPathComponent("settings-skills-\(name)-\(language).png")) } }
        await host(app, select: slug, language: language)
        _ = await until(app) { control(app, word("Esporta…")) != nil }
        for (key, name) in [("Regole", "rules"), ("Scelte", "choices"), ("Passi", "steps")] {
            let tab = try #require(control(app, word(key)), "\(language): no tab «\(word(key))»")
            app.rig.click(tab.centre)
            await app.settle()
            #expect(control(app, word(key))?.selected == true)
            shoot(name)
        }
        // The header's buttons inside the pane, left of nothing else.
        for key in ["Duplica", "Esporta…"] {
            let b = try #require(control(app, word(key)), "\(language): no «\(word(key))»")
            #expect(b.frame.minX > RulesSettings.listWidth && b.frame.maxX <= SettingsView.size.width - 19, "\(language): «\(word(key))» at \(b.frame)")
        }
        // The import sheet.
        RigGuard.panelAnswer = [try skillFile("---\ntitle: Intervista lunga\nbased-on: talking-head-reel\ncaptions: elegant-serif\nmusic: never\n---\n## Steps\n\n1. Leggi le domande.\n2. Taglia le pause, niente zoom.\n\n## Rules\n\nNiente musica sotto le risposte.\n")]
        app.rig.click(try #require(control(app, word("Importa una skill…"))).centre)
        _ = await until(app) { control(app, word("Aggiungi")) != nil }
        await app.settle()
        shoot("import")
        app.rig.click(try #require(control(app, word("Annulla"))).centre)
        await app.settle()
        // A built-in, read-only.
        app.rig.click(try #require(app.rig.controls().first { $0.name.hasPrefix(word("Talking-head reel")) && $0.frame.maxX <= RulesSettings.listWidth + 1 }).centre)
        _ = await until(app) { control(app, word("Esporta…")) == nil }
        await app.settle()
        shoot("builtin")
        #expect(control(app, word("Duplica")) != nil && control(app, word("Esporta…")) == nil)
    }
}
}

/// A built-in recipe's steps, wrapped by hand for Claude, read on screen as one paragraph per item: continuation lines join
/// their item, list items (nested ones included) keep their own line, blank lines stay.
@Suite struct BuiltInStepsTextTests {
    @Test func continuationLinesJoinTheirItem() {
        let text = "1. Find the material: text_read the\n   script to know what was said.\n    - a nested item\n      that goes on\n2. project_new.\n\nA paragraph."
        #expect(RulesSettings.unwrapped(text) == "1. Find the material: text_read the script to know what was said.\n    - a nested item that goes on\n2. project_new.\n\nA paragraph.")
    }

    @Test func everyBuiltInRecipeKeepsItsNumberedItems() {
        for recipe in Recipes.all {
            let steps = recipe.body
            let items = steps.components(separatedBy: "\n").filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }.count
            let shown = RulesSettings.unwrapped(steps).components(separatedBy: "\n")
            #expect(shown.filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }.count == items, "\(recipe.name)")
            #expect(!shown.contains { $0.hasPrefix("   ") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }, "\(recipe.name): a continuation line is left on its own")
        }
    }
}
