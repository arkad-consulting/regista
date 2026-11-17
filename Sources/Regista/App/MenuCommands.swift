import AppKit
import SwiftUI

/// One item of the menu bar (#36): what it is called, where it sits, its key (from `AppShortcuts`), whether it can run
/// now and what it does. `MenuCommands.all` is the only source of the menu bar: `EditorCommands` draws these, and the
/// tests run the very same closures on the live model (a hosted view has no app menu to click).
@MainActor
struct MenuCommand: Identifiable {
    /// The menu, and the group of the standard menus it replaces.
    enum Place: String, CaseIterable {
        case appInfo, newItem, saveItem, undoRedo, editing, record, view, help
    }

    let id: String
    let place: Place
    /// In the interface language.
    let title: String
    /// The submenu it belongs to (in the interface language), nil: the menu itself.
    var submenu: String?
    var shortcut: AppShortcut?
    var enabled = true
    /// A separator above it.
    var divider = false
    let run: @MainActor () -> Void
}

/// What the menu items act on: the tab on screen of the workbench, the recent projects, the recorder, and the ways out
/// of the main window the app's scene gives (the help window, Settings, the About panel).
@MainActor
struct MenuContext {
    let bench: Workbench
    let recents: RecentProjects
    let recorder: Recorder
    var openGuide: (HelpGuide) -> Void
    var openShortcuts: () -> Void
    var showAbout: () -> Void = { EditorCommands.showAbout() }

    /// The tab on screen when the item runs.
    var store: EditorStore { bench.active }
}

enum MenuCommands {
    /// Every item of the menu bar, in menu order, as it reads and can run in this state.
    @MainActor static func all(_ c: MenuContext) -> [MenuCommand] {
        var items: [MenuCommand] = []
        func add(_ id: String, _ place: MenuCommand.Place, _ title: String, submenu: String? = nil, _ shortcut: AppShortcut? = nil,
                 enabled: Bool = true, divider: Bool = false, _ run: @escaping @MainActor () -> Void) {
            items.append(MenuCommand(id: id, place: place, title: title, submenu: submenu, shortcut: shortcut, enabled: enabled, divider: divider, run: run))
        }
        add("about", .appInfo, loc("Informazioni su Regista")) { c.showAbout() }

        // File
        add("newProject", .newItem, loc("Nuovo progetto…"), AppShortcuts.newProject) { Panels.newProject(c.store) }
        add("newTab", .newItem, loc("Nuova scheda"), AppShortcuts.newTab) { c.bench.openNewTab() }
        add("openProject", .newItem, loc("Apri progetto…"), AppShortcuts.openProject) { Panels.openProject(c.store) }
        let recent = loc("Apri recente")
        for url in c.recents.urls {
            add("recent:" + url.path, .newItem, url.deletingPathExtension().lastPathComponent, submenu: recent) { c.store.openProject(url) }
        }
        add("clearRecents", .newItem, loc("Cancella elenco"), submenu: recent, enabled: !c.recents.urls.isEmpty,
            divider: !c.recents.urls.isEmpty) { c.recents.clear() }
        add("importMedia", .newItem, loc("Importa media…"), AppShortcuts.importMedia, divider: true) { Panels.importMedia(c.store) }
        // ⌘W closes the tab on screen; another window in front (Settings, a sheet's window) closes as usual.
        add("closeTab", .saveItem, loc("Chiudi la scheda"), AppShortcuts.closeTab) {
            if let w = NSApp.keyWindow, let main = c.bench.window, w !== main { return w.performClose(nil) }
            let s = c.store
            Task { await c.bench.close(s) }
        }
        add("save", .saveItem, loc("Salva"), AppShortcuts.save) { Panels.save(c.store) }
        add("saveAs", .saveItem, loc("Salva con nome…"), AppShortcuts.saveAs) { Panels.saveAs(c.store) }

        // Modifica (#65: "menu.undo", not "Annulla" — Cancel in a dialog). Typing in a text: its own undo.
        add("undo", .undoRedo, loc("menu.undo"), AppShortcuts.undo) {
            if let t = NSApp.keyWindow?.firstResponder as? NSTextView { t.undoManager?.undo() } else { c.store.undo() }
        }
        add("redo", .undoRedo, loc("menu.redo"), AppShortcuts.redo) {
            if let t = NSApp.keyWindow?.firstResponder as? NSTextView { t.undoManager?.redo() } else { c.store.redo() }
        }

        // Montaggio
        add("cut", .editing, loc("Taglia al cursore"), AppShortcuts.cut) { c.store.cutAtPlayhead() }
        add("autoEdit", .editing, loc("Montaggio automatico"), AppShortcuts.autoEdit) { c.store.autoEdit(script: TeleprompterController.shared.ownScript) }
        add("captions", .editing, loc("Genera sottotitoli")) { c.store.run("captions.generate", ["style": "talking-head-v1"]) }
        add("zoomToFit", .editing, loc("Adatta la timeline"), divider: true) { c.store.zoomToFit() }

        // Registra
        add("record", .record, loc(c.recorder.isRecording ? "Ferma registrazione" : "Avvia registrazione"), AppShortcuts.record) {
            EditorCommands.toggleRecording(c.store, c.recorder)
        }
        add("pause", .record, loc(c.recorder.isPaused ? "Riprendi" : "Pausa"), AppShortcuts.pause, enabled: c.recorder.isRecording) {
            c.recorder.togglePause()
        }

        // Vista: the activity bar, top to bottom (⌘1…⌘9), the levels, the tabs, the panels.
        for (i, a) in Navigation.Activity.allCases.enumerated() {
            let title = ActivityInfo.of(a).title
            add("activity.\(i + 1)", .view, title, AppShortcuts.activity(i, title: title)) { c.store.select(a) }  // l10n-ignore — an id
        }
        add("simple", .view, loc("Monta — Semplice"), AppShortcuts.simple, divider: true) { c.store.workspace = .simple }
        add("pro", .view, loc("Monta — Pro"), AppShortcuts.pro) { c.store.workspace = .pro }
        add("nextTab", .view, loc("Scheda successiva"), AppShortcuts.nextTab, divider: true) { c.bench.selectNext(1) }
        add("previousTab", .view, loc("Scheda precedente"), AppShortcuts.previousTab) { c.bench.selectNext(-1) }
        add("nextTabAlt", .view, loc("Scheda successiva"), AppShortcuts.nextTabAlt) { c.bench.selectNext(1) }
        add("previousTabAlt", .view, loc("Scheda precedente"), AppShortcuts.previousTabAlt) { c.bench.selectNext(-1) }
        add("sidePanel", .view, loc("Mostra o nascondi il pannello laterale"), AppShortcuts.sidePanel, divider: true) { ShellPrefs.toggle(ShellPrefs.sideShown) }
        add("rightPanel", .view, loc("Mostra o nascondi il pannello destro"), AppShortcuts.rightPanel) { ShellPrefs.toggle(ShellPrefs.rightShown) }
        add("safeZones", .view, loc("Zone di sicurezza"), divider: true) { c.store.safeZones.toggle() }
        // The Marca picker lives on the editor's toolbar: go to the editor, then open it.
        add("brandKit", .view, loc("Brand kit…"), AppShortcuts.brandKit) {
            if !c.store.nav.inEditor { c.store.showEditor() }
            c.store.showBrandKits = true
        }

        // Aiuto (Help / Aide / Ajuda): the guides shipped in the app, the shortcuts, the issues page.
        for g in HelpGuide.allCases {
            add("help.\(g.rawValue)", .help, loc(g.title), g == .userGuide ? AppShortcuts.help : nil) { c.openGuide(g) }
        }
        add("shortcuts", .help, loc("Scorciatoie da tastiera"), divider: true) { c.openShortcuts() }
        add("reportProblem", .help, loc("Segnala un problema…")) { HelpCenter.reportProblem() }
        return items
    }
}

/// The items of one place of the menu bar, a submenu for consecutive items that name one.
struct MenuItems: View {
    private let blocks: [Block]

    private enum Block: Identifiable {
        case item(MenuCommand)
        case submenu(String, [MenuCommand])
        var id: String {
            switch self {
            case .item(let c): c.id
            case .submenu(let t, _): "submenu:" + t
            }
        }
    }

    init(_ all: [MenuCommand], _ place: MenuCommand.Place) {
        var out: [Block] = []
        for c in all where c.place == place {
            if let s = c.submenu {
                if case .submenu(let t, let list)? = out.last, t == s { out[out.count - 1] = .submenu(t, list + [c]) } else { out.append(.submenu(s, [c])) }
            } else {
                out.append(.item(c))
            }
        }
        blocks = out
    }

    var body: some View {
        ForEach(blocks) { b in
            switch b {
            case .item(let c): Self.button(c)
            case .submenu(let title, let list):
                Menu(title) { ForEach(list) { Self.button($0) } }
            }
        }
    }

    @ViewBuilder private static func button(_ c: MenuCommand) -> some View {
        if c.divider { Divider() }
        if let s = c.shortcut {
            Button(c.title) { c.run() }.shortcut(s).disabled(!c.enabled)
        } else {
            Button(c.title) { c.run() }.disabled(!c.enabled)
        }
    }
}
