import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #36: the menu bar's items and their shortcuts. A hosted window has no app menu, so the tests run the items of the one
// table the menu bar is drawn from (`MenuCommands.all`) on the live model: the rig's workbench, recorder and services,
// with the ways out of the window (the help window, Settings, the About panel) written down instead of opened. Each item
// runs once and has its effect; each is disabled exactly when its state says so; no two share a key and none takes one
// of macOS's own. The keys the editor's views and the teleprompter handle go through the rig's window as key events,
// each once, with their effect.

/// macOS's own shortcuts: an item may take one only to do what macOS means by it (⌘W: close what is in front).
let reservedShortcuts: [String: String] = ["⌘Q": "", "⌘H": "", "⌘M": "", "⌘⇥": "", "⌘" + AppShortcut.keyName(.space): "", "⌘`": "",
                                           "⌘W": "closeTab"]

extension MouseSuites {
@Suite(.serialized) @MainActor struct MenuCommandTests {
    /// The ways out of the main window, written down.
    final class Outside {
        var guides: [HelpGuide] = []
        var shortcuts = 0
        var about = 0
    }

    static func context(_ app: AppRig, _ out: Outside) -> MenuContext {
        MenuContext(bench: app.store.bench, recents: app.store.bench.recents, recorder: app.recorder,
                    openGuide: { out.guides.append($0) }, openShortcuts: { out.shortcuts += 1 }, showAbout: { out.about += 1 })
    }

    /// The keys of the table: unique, from the catalog, none of macOS's own (but for what macOS means by it).
    @Test func theMenuKeysAreUniqueAndLeaveMacOSAlone() async throws {
        let app = try await AppRig(project: "rich")
        defer { app.close() }
        let items = MenuCommands.all(Self.context(app, Outside()))
        #expect(Set(items.map(\.id)).count == items.count, "two items share an id")
        let keyed = items.compactMap { c in c.shortcut.map { (c.id, $0.display) } }
        let keys = Dictionary(grouping: keyed, by: \.1).filter { $0.value.count > 1 }
        #expect(keys.isEmpty, "items share a key: \(keys)")
        for (id, key) in keyed {
            if let owner = reservedShortcuts[key] { #expect(owner == id, "\(id) takes \(key), which macOS keeps for itself") }
        }
        // Every key of the table is the catalog's (Settings › Shortcuts and docs/reference list the catalog).
        let catalog = Dictionary(AppShortcuts.all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in items { if let s = c.shortcut { #expect(catalog[s.id] == s, "\(c.id): \(s.display) is not the catalog's") } }
        // Every menu shortcut of the catalog is on an item (the Settings item is the scene's own: ⌘,).
        let menuIDs = Set(items.compactMap { $0.shortcut?.id })
        for s in AppShortcuts.all where s.group != .editor && s.group != .teleprompter && s.id != "settings" {
            #expect(menuIDs.contains(s.id), "the catalog's \(s.id) (\(s.display)) is on no menu item")
        }
    }

    /// Each item, run as the menu runs it, does what it says once; the state-dependent ones are disabled exactly when
    /// their state says so.
    @Test func eachMenuItemRunsAndHasItsEffect() async throws {
        let app = try await AppRig(project: "rich")
        let out = Outside()
        let shell = (side: UserDefaults.standard.object(forKey: ShellPrefs.sideShown), right: UserDefaults.standard.object(forKey: ShellPrefs.rightShown))
        defer {
            UserDefaults.standard.set(shell.side, forKey: ShellPrefs.sideShown)
            UserDefaults.standard.set(shell.right, forKey: ShellPrefs.rightShown)
            app.close()
        }
        app.hostEditor(Navigation(activity: .media, level: .pro, rightTab: .inspector))
        app.store.bench.window = app.rig.window
        await app.settle()
        let bench = app.store.bench
        let scratch = rigTempDir("menu")
        var ran: Set<String> = []
        func item(_ id: String) throws -> MenuCommand {
            try #require(MenuCommands.all(Self.context(app, out)).first { $0.id == id }, "no menu item \(id)")
        }
        /// Runs an item as the menu does (only when it is enabled), then waits for its commands.
        func run(_ id: String) async throws {
            let c = try item(id)
            #expect(c.enabled, "\(id) is disabled")
            ran.insert(id)
            c.run()
            await app.settle()
        }
        func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > end { return false }
                await app.idle(0.05)
            }
            return true
        }
        var store: EditorStore { bench.active }

        try await run("about")
        #expect(out.about == 1)

        // Modifica: an edit, undone, redone.
        let before = store.project?.tracks.flatMap(\.clips).count ?? 0
        store.preview.seek(1.5)
        try await run("cut")
        #expect(await until { (store.project?.tracks.flatMap(\.clips).count ?? 0) > before }, "Taglia al cursore cut nothing")
        let cut = store.project?.tracks.flatMap(\.clips).count ?? 0
        try await run("undo")
        #expect(await until { store.project?.tracks.flatMap(\.clips).count == before }, "Annulla did not take the cut back")
        try await run("redo")
        #expect(await until { store.project?.tracks.flatMap(\.clips).count == cut }, "Ripeti did not put the cut back")

        // Montaggio.
        let fit = store.fitRequest
        try await run("zoomToFit")
        #expect(store.fitRequest == fit + 1)
        let commands = store.activity.count
        try await run("captions")
        #expect(await until(10) { app.commands(since: commands).contains("captions.generate") }, "Genera sottotitoli ran no captions.generate")
        try await run("autoEdit")
        #expect(await until(5) { store.jobs.latest(TextStep.allJobKind) != nil }, "Montaggio automatico started nothing")
        #expect(await until(90) { store.jobs.latest(TextStep.allJobKind)?.isRunning == false }, "the automatic edit did not end")

        // Vista: the activities, the levels, the panels, the safe zones, the brand kits.
        for (i, a) in Navigation.Activity.allCases.enumerated() {
            try await run("activity.\(i + 1)")
            #expect(store.nav.activity == a, "⌘\(i + 1) did not open \(a)")
        }
        try await run("pro")
        #expect(store.workspace == .pro)
        try await run("simple")
        #expect(store.workspace == .simple)
        let side = UserDefaults.standard.object(forKey: ShellPrefs.sideShown) as? Bool ?? true
        try await run("sidePanel")
        #expect((UserDefaults.standard.object(forKey: ShellPrefs.sideShown) as? Bool) == !side)
        let right = UserDefaults.standard.object(forKey: ShellPrefs.rightShown) as? Bool ?? true
        try await run("rightPanel")
        #expect((UserDefaults.standard.object(forKey: ShellPrefs.rightShown) as? Bool) == !right)
        let zones = store.safeZones
        try await run("safeZones")
        #expect(store.safeZones == !zones)
        store.select(.home)
        try await run("brandKit")
        #expect(store.nav.inEditor && store.showBrandKits, "Brand kit… did not open the picker in the editor")
        store.showBrandKits = false
        await app.settle()

        // Registra: Pausa is off until a take runs; the take runs, pauses, resumes and stops.
        var pause = try item("pause"), record = try item("record")
        #expect(!pause.enabled, "Pausa is enabled with no take running")
        #expect(record.title == "Avvia registrazione")
        try await run("record")
        #expect(await until { app.recorder.isRecording }, "Avvia registrazione did not start a take: \(app.recorder.errorMessage ?? "")")
        pause = try item("pause"); record = try item("record")
        #expect(pause.enabled && record.title == "Ferma registrazione")
        try await run("pause")
        pause = try item("pause")
        #expect(app.recorder.isPaused && pause.title == "Riprendi")
        try await run("pause")
        #expect(!app.recorder.isPaused)
        try await run("record")
        #expect(await until { !app.recorder.isRecording }, "Ferma registrazione did not stop the take")
        pause = try item("pause")
        #expect(!pause.enabled)

        // Aiuto: the guides, the shortcuts, the issues page.
        for g in HelpGuide.allCases { try await run("help.\(g.rawValue)") }
        #expect(out.guides == HelpGuide.allCases)
        try await run("shortcuts")
        #expect(out.shortcuts == 1)
        RigGuard.events.removeAll()
        try await run("reportProblem")
        #expect(RigGuard.events.contains { $0.kind == .url && $0.detail == HelpLibrary.issuesURL.absoluteString }, "\(RigGuard.events)")

        // File: save, save as, import, a new tab, the tabs in turn, a new project, open, recent, clear, close.
        try await run("save")
        #expect(await until { store.dirty == false }, "Salva did not save")
        let copy = scratch.appendingPathComponent("Copia")
        RigGuard.panelAnswer = [copy]
        try await run("saveAs")
        #expect(await until { store.projectURL?.deletingPathExtension().lastPathComponent == "Copia" }, "Salva con nome… did not save a copy: \(String(describing: store.projectURL))")
        let assets = store.project?.assets.count ?? 0
        let media = scratch.appendingPathComponent("altro.mov")
        try FileManager.default.copyItem(at: try RigProject.media.get().appendingPathComponent("take.mov"), to: media)
        RigGuard.panelAnswer = [media]
        try await run("importMedia")
        #expect(await until(10) { (store.project?.assets.count ?? 0) == assets + 1 }, "Importa media… imported nothing")
        try await run("save")
        let first = bench.activeID
        try await run("newTab")
        #expect(bench.tabs.count == 2)
        bench.select(first)
        await app.settle()
        for (id, step) in [("nextTab", 1), ("previousTab", -1), ("nextTabAlt", 1), ("previousTabAlt", -1)] {
            let from = bench.tabs.firstIndex { $0.tabID == bench.activeID } ?? 0
            try await run(id)
            let to = bench.tabs.firstIndex { $0.tabID == bench.activeID } ?? 0
            #expect(to == (from + step + bench.tabs.count) % bench.tabs.count, "\(id) went from tab \(from) to \(to)")
        }
        // A new project in the empty tab, then the copy opened from the open panel and from Apri recente.
        bench.select(bench.tabs[1].tabID)
        await app.settle()
        RigGuard.panelAnswer = [scratch.appendingPathComponent("Nuovo")]
        try await run("newProject")
        #expect(await until { store.project?.name == "Nuovo" }, "Nuovo progetto… made no project")
        try await run("save")
        let saved = try #require(bench.tabs.first?.projectURL ?? nil)
        try await run("closeTab")
        #expect(await until { bench.tabs.count == 1 }, "Chiudi la scheda did not close the tab")
        try await run("newTab")
        RigGuard.panelAnswer = [saved]
        try await run("openProject")
        #expect(await until(10) { store.projectURL?.standardizedFileURL == saved.standardizedFileURL }, "Apri progetto… opened \(String(describing: store.projectURL))")
        try await run("closeTab")
        #expect(await until { bench.tabs.count == 1 })
        try await run("newTab")
        let recents = MenuCommands.all(Self.context(app, out)).filter { $0.id.hasPrefix("recent:") }
        let recent = try #require(recents.first { $0.id == "recent:" + saved.path } ?? recents.first, "Apri recente lists nothing")
        try await run(recent.id)
        #expect(await until(10) { store.projectURL != nil && store.projectURL?.path == String(recent.id.dropFirst("recent:".count)) }, "Apri recente opened \(String(describing: store.projectURL))")
        try await run("clearRecents")
        let clear = try item("clearRecents")
        #expect(bench.recents.urls.isEmpty && !clear.enabled, "Cancella elenco left \(bench.recents.urls)")

        // Every item of the table ran (the recent projects: one of them).
        let all = Set(MenuCommands.all(Self.context(app, out)).map(\.id)).filter { !$0.hasPrefix("recent:") }
        #expect(all.subtracting(ran).isEmpty, "not run: \(all.subtracting(ran).sorted())")
    }

    /// The keys the editor's views handle (`AppShortcuts.editor` and ⌘K), each sent once through the rig's window as a
    /// key event, with its effect.
    @Test func eachEditorKeyDoesWhatTheCatalogSays() async throws {
        let app = try await AppRig(project: "rich")
        defer { app.close() }
        app.hostEditor(Navigation(activity: .media, level: .pro, rightTab: .inspector))
        app.store.bench.window = app.rig.window
        KeyMonitor.install(app.store.bench)
        await app.settle()
        let store = app.store, p = store.preview, r = app.rig!
        var sent: Set<String> = []
        func press(_ id: String, _ chars: String, _ code: UInt16, _ m: NSEvent.ModifierFlags = []) async {
            sent.insert(id)
            r.key(chars, keyCode: code, modifiers: m)
            await app.settle()
        }
        func until(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > end { return false }
                await app.idle(0.05)
            }
            return true
        }
        var clips: Int { store.project?.tracks.flatMap(\.clips).count ?? 0 }

        // Transport.
        p.seek(1)
        await app.settle()
        await press("frameForward", MouseRig.Key.right.characters, MouseRig.Key.right.code)
        #expect(abs(p.time - (1 + 1.0 / 30)) < 0.005, "→ moved the playhead to \(p.time)")
        await press("frameBack", MouseRig.Key.left.characters, MouseRig.Key.left.code)
        #expect(abs(p.time - 1) < 0.005, "← moved the playhead to \(p.time)")
        await press("frameForward", MouseRig.Key.right.characters, MouseRig.Key.right.code, .shift)
        #expect(abs(p.time - 2) < 0.005, "⇧→ moved the playhead to \(p.time)")
        await press("end", MouseRig.Key.end.characters, MouseRig.Key.end.code)
        #expect(abs(p.time - p.duration) < 0.05, "End moved the playhead to \(p.time) of \(p.duration)")
        await press("start", MouseRig.Key.home.characters, MouseRig.Key.home.code)
        #expect(p.time < 0.005, "Home moved the playhead to \(p.time)")
        await press("play", " ", MouseRig.Key.space.code)
        #expect(await until { p.isPlaying }, "Space did not play")
        await press("play", " ", MouseRig.Key.space.code)
        #expect(await until { !p.isPlaying }, "Space did not pause")
        await press("shuttleBack", "l", 37)
        #expect(await until { p.isPlaying }, "L did not play forward")
        await press("shuttleBack", "k", 40)
        #expect(await until { !p.isPlaying }, "K did not stop")
        p.seek(2)
        await app.settle()
        await press("shuttleBack", "j", 38)
        #expect(await until { p.isPlaying || p.time < 1.9 }, "J did not go back (\(p.time))")
        await press("shuttleBack", "k", 40)
        #expect(await until { !p.isPlaying })

        // Tools.
        for (id, key, code, tool) in [("razor", "c", UInt16(8), EditorStore.Tool.razor), ("text", "t", 17, .text), ("hand", "h", 4, .hand), ("select", "v", 9, .select)] {
            await press(id, key, code)
            #expect(store.tool == tool, "\(key.uppercased()) chose \(store.tool)")
        }

        // Zoom.
        let zoom = store.pxPerSec
        await press("zoomIn", "=", 24)
        #expect(store.pxPerSec > zoom, "= did not zoom in (\(zoom) → \(store.pxPerSec))")
        let zoomed = store.pxPerSec
        await press("zoomOut", "-", 27)
        #expect(store.pxPerSec < zoomed, "- did not zoom out (\(zoomed) → \(store.pxPerSec))")
        let fit = store.fitRequest
        await press("fit", "\\", 42)
        #expect(store.fitRequest == fit + 1, "\\ did not fit the timeline")

        // Clips: ⌘K cuts at the playhead, ⌫ deletes the piece after it (a gap), ⌘C / ⌘V put a copy of the first piece
        // in the gap, ⌘D duplicates the copy after itself, ⇧⌫ deletes the copy and closes the gap behind it.
        func pictures() -> [Clip] { (store.project?.tracks.first { $0.kind == .video }?.clips ?? []).sorted { $0.start < $1.start } }
        p.seek(1.5)
        await app.settle()
        var before = pictures().count
        await press("cut", "k", 40, .command)
        #expect(await until { pictures().count == before + 1 }, "⌘K cut nothing")
        let tail = try #require(pictures().last)
        store.selection = [tail.id]
        await press("delete", MouseRig.Key.delete.characters, MouseRig.Key.delete.code)
        #expect(await until { !pictures().contains { $0.id == tail.id } }, "⌫ deleted nothing")
        let head = try #require(pictures().first)
        store.selection = [head.id]
        await press("copy", "c", 8, .command)
        #expect(store.clipboard == [head.id], "⌘C copied \(store.clipboard)")
        p.seek(head.end.seconds)
        await app.settle()
        before = pictures().count
        await press("paste", "v", 9, .command)
        #expect(await until { pictures().count == before + 1 }, "⌘V pasted nothing: \(store.errorMessage ?? "")")
        let pasted = try #require(pictures().last)
        #expect(abs(pasted.start.seconds - head.end.seconds) < 0.05, "⌘V pasted at \(pasted.start.seconds), not at the playhead")
        store.selection = [pasted.id]
        before = pictures().count
        await press("duplicate", "d", 2, .command)
        #expect(await until { pictures().count == before + 1 }, "⌘D duplicated nothing: \(store.errorMessage ?? "")")
        let copy = try #require(pictures().last)
        store.selection = [pasted.id]
        await press("delete", MouseRig.Key.delete.characters, MouseRig.Key.delete.code, .shift)
        #expect(await until { !pictures().contains { $0.id == pasted.id } }, "⇧⌫ deleted nothing")
        let closed = pictures().first { $0.id == copy.id }
        #expect(closed.map { $0.start < copy.start } == true, "⇧⌫ did not close the gap (\(copy.start.seconds) → \(String(describing: closed?.start.seconds)))")

        // Every key of the catalog's editor list was sent.
        #expect(Set(AppShortcuts.editor.map(\.id)).subtracting(sent).isEmpty, "not sent: \(Set(AppShortcuts.editor.map(\.id)).subtracting(sent))")
    }

    /// The teleprompter's keys (`AppShortcuts.teleprompter`), each sent once through the rig's window while a take runs
    /// (the teleprompter is in use then, its window kept offscreen by the rig): Space, ↓, ↑, and ⌥Space on Gobbo's
    /// «Avvia».
    @Test func eachTeleprompterKeyDoesWhatTheCatalogSays() async throws {
        let app = try await AppRig(project: nil)
        let prompter = TeleprompterController.shared
        let d = UserDefaults.standard
        let saved = (text: prompter.text, mode: prompter.mode, storedText: d.object(forKey: "prompterText"), storedMode: d.object(forKey: "prompterMode"))
        defer {
            if prompter.isPlaying { prompter.togglePlay() }
            if prompter.isVisible { prompter.hide() }
            app.rig?.hold(0.8)
            prompter.text = saved.text
            prompter.mode = saved.mode
            d.set(saved.storedText, forKey: "prompterText")
            d.set(saved.storedMode, forKey: "prompterMode")
            app.close()
        }
        prompter.mode = .voice   // ↓ ↑ go by sentence (with no speech recognition in the rig, nothing else moves it)
        prompter.text = "1. Prima frase da leggere.\n2. Seconda frase da leggere.\n3. Terza frase da leggere."
        app.hostEditor(Navigation(activity: .record, rightTab: .prompter))
        await app.settle()
        func until(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > end { return false }
                await app.idle(0.05)
            }
            return true
        }
        let r = app.rig!
        var sent: Set<String> = []
        // ⌥Space: Gobbo's «Ascolta e segui» (the panel's button keyboard shortcut) shows the teleprompter and starts it.
        sent.insert("prompterToggle")
        r.key(" ", keyCode: MouseRig.Key.space.code, modifiers: .option)
        await app.settle()
        #expect(await until { prompter.isVisible }, "⌥Space did not show the teleprompter")
        // A take in progress keeps the teleprompter in use whatever its own state.
        await app.recorder.prepare()
        app.recorder.start()
        #expect(await until { app.recorder.isRecording }, "no take: \(app.recorder.errorMessage ?? "")")
        let playing = prompter.isPlaying
        sent.insert("prompterPlay")
        r.key(" ", keyCode: MouseRig.Key.space.code)
        await app.settle()
        #expect(await until { prompter.isPlaying != playing }, "Space did not start or stop the teleprompter")
        prompter.jump(toToken: 0)
        let start = prompter.follower.cursor
        sent.insert("prompterNext")
        r.key(.down)
        await app.settle()
        #expect(prompter.follower.cursor > start, "↓ did not go to the next sentence (\(start) → \(prompter.follower.cursor))")
        let next = prompter.follower.cursor
        sent.insert("prompterBack")
        r.key(.up)
        await app.settle()
        #expect(prompter.follower.cursor < next, "↑ did not go back (\(next) → \(prompter.follower.cursor))")
        app.recorder.stop()
        #expect(await until(5) { !app.recorder.isRecording })
        #expect(Set(AppShortcuts.teleprompter.map(\.id)).subtracting(sent).isEmpty)
    }
}
}
