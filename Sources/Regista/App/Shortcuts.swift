import SwiftUI

/// Every keyboard shortcut of the app, in one place (M2 #59): the menus (`EditorCommands`) take their key from here,
/// and Impostazioni › Scorciatoie lists this catalog, so the list cannot drift from what the keys really do. The editor
/// keys that are not menu items (transport, tools) are handled by `KeyMonitor` and the teleprompter, and listed here.
struct AppShortcut: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case file, edit, editing, record, view, editor, teleprompter

        var title: String {
            switch self {
            case .file: loc("File")
            case .edit: loc("menu.edit")   // the Edit menu; "Modifica" is also the verb (FR: Édition vs Modifier)
            case .editing: loc("Montaggio")
            case .record: loc("Registra")
            case .view: loc("Vista")
            case .editor: loc("Nella timeline")
            case .teleprompter: loc("Gobbo")
            }
        }
    }

    let id: String
    /// A lookup key (the Italian text, or a semantic key such as "menu.undo"), shown through `loc`.
    let title: String
    let group: Group
    let key: KeyEquivalent
    let modifiers: EventModifiers

    /// "⇧⌘R", "⌃⇥", "Spazio".
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(key)
    }

    static func keyName(_ k: KeyEquivalent) -> String {
        switch k {
        case .tab: "⇥"
        case .space: loc("Spazio")
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .delete: "⌫"
        case .deleteForward: "⌦"
        case .home: "↖"
        case .end: "↘"
        case .escape: "⎋"
        default: String(k.character).uppercased()
        }
    }

    static func == (a: AppShortcut, b: AppShortcut) -> Bool { a.id == b.id && a.display == b.display && a.title == b.title }
}

enum AppShortcuts {
    private static func s(_ id: String, _ title: String, _ g: AppShortcut.Group, _ k: KeyEquivalent, _ m: EventModifiers = .command) -> AppShortcut {
        AppShortcut(id: id, title: title, group: g, key: k, modifiers: m)
    }

    // File
    static let newProject = s("newProject", "Nuovo progetto…", .file, "n")
    static let newTab = s("newTab", "Nuova scheda", .file, "t")
    static let openProject = s("openProject", "Apri progetto…", .file, "o")
    static let importMedia = s("importMedia", "Importa media…", .file, "i")
    static let closeTab = s("closeTab", "Chiudi la scheda", .file, "w")
    static let save = s("save", "Salva", .file, "s")
    static let saveAs = s("saveAs", "Salva con nome…", .file, "s", [.command, .shift])
    static let settings = s("settings", "Impostazioni", .file, ",")
    // Modifica
    static let undo = s("undo", "menu.undo", .edit, "z")
    static let redo = s("redo", "menu.redo", .edit, "z", [.command, .shift])
    // Montaggio
    static let cut = s("cut", "Taglia al cursore", .editing, "k")
    static let autoEdit = s("autoEdit", "Montaggio automatico", .editing, "m", [.command, .shift])
    // Registra
    static let record = s("record", "Avvia o ferma la registrazione", .record, "r", [.command, .shift])
    static let pause = s("pause", "Pausa o riprendi", .record, "p", [.command, .shift])
    // Vista
    static let simple = s("simple", "Monta — Semplice", .view, "1", [.command, .option])
    static let pro = s("pro", "Monta — Pro", .view, "2", [.command, .option])
    static let nextTab = s("nextTab", "Scheda successiva", .view, .tab, .control)
    static let previousTab = s("previousTab", "Scheda precedente", .view, .tab, [.control, .shift])
    static let nextTabAlt = s("nextTabAlt", "Scheda successiva", .view, "]", [.command, .shift])
    static let previousTabAlt = s("previousTabAlt", "Scheda precedente", .view, "[", [.command, .shift])
    static let sidePanel = s("sidePanel", "Mostra o nascondi il pannello laterale", .view, "s", [.command, .control])
    static let rightPanel = s("rightPanel", "Mostra o nascondi il pannello destro", .view, "i", [.command, .option])
    static let brandKit = s("brandKit", "Brand kit…", .view, "b", [.command, .shift])

    /// ⌘1…⌘9: the activity bar, top to bottom (Vista menu).
    static func activity(_ i: Int, title: String) -> AppShortcut {
        s("activity.\(i + 1)", title, .view, KeyEquivalent(Character("\(i + 1)")))  // l10n-ignore — an id and a key
    }

    static var activities: [AppShortcut] {
        Navigation.Activity.allCases.enumerated().map { i, a in activity(i, title: ActivityInfo.of(a).title) }
    }

    /// The editor's keys outside the menus (`KeyMonitor`): transport, tools, clips.
    static let editor: [AppShortcut] = [
        s("play", "Riproduci o metti in pausa", .editor, .space, []),
        s("shuttleBack", "Indietro (J), ferma (K), avanti (L)", .editor, "j", []),
        s("frameBack", "Un fotogramma indietro (⇧: un secondo)", .editor, .leftArrow, []),
        s("frameForward", "Un fotogramma avanti (⇧: un secondo)", .editor, .rightArrow, []),
        s("start", "All'inizio", .editor, .home, []),
        s("end", "Alla fine", .editor, .end, []),
        s("delete", "Elimina la selezione (⇧: chiude il vuoto)", .editor, .delete, []),
        s("select", "Strumento selezione", .editor, "v", []),
        s("razor", "Strumento lama", .editor, "c", []),
        s("text", "Strumento testo", .editor, "t", []),
        s("hand", "Strumento mano", .editor, "h", []),
        s("zoomIn", "Ingrandisci la timeline", .editor, "=", []),
        s("zoomOut", "Riduci la timeline", .editor, "-", []),
        s("fit", "Adatta la timeline", .editor, "\\", []),
        s("copy", "Copia le clip", .editor, "c"),
        s("paste", "Incolla al cursore", .editor, "v"),
        s("duplicate", "Duplica le clip", .editor, "d"),
    ]

    /// The teleprompter's keys (also pedals and presentation remotes).
    static let teleprompter: [AppShortcut] = [
        s("prompterPlay", "Avvia o ferma lo scorrimento", .teleprompter, .space, []),
        s("prompterNext", "Frase successiva (anche → e Pag giù)", .teleprompter, .downArrow, []),
        s("prompterBack", "Frase precedente (anche ← e Pag su)", .teleprompter, .upArrow, []),
        s("prompterToggle", "Avvia o ferma il gobbo dalla finestra", .teleprompter, .space, .option),
    ]

    /// Every shortcut, menu order then the editor and the teleprompter.
    static var all: [AppShortcut] {
        [newProject, newTab, openProject, importMedia, closeTab, save, saveAs, settings, undo, redo, cut, autoEdit, record, pause]
            + activities + [simple, pro, nextTab, previousTab, nextTabAlt, previousTabAlt, sidePanel, rightPanel, brandKit]
            + editor + teleprompter
    }

    /// The rows whose title or keys contain `query` (case- and accent-insensitive), grouped in catalog order.
    static func search(_ query: String, in list: [AppShortcut] = all) -> [(group: AppShortcut.Group, items: [AppShortcut])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let hits = q.isEmpty ? list : list.filter {
            loc($0.title).range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.display.range(of: q, options: .caseInsensitive) != nil
        }
        return AppShortcut.Group.allCases.compactMap { g in
            let items = hits.filter { $0.group == g }
            return items.isEmpty ? nil : (g, items)
        }
    }
}

extension View {
    /// The catalog's key for a menu item.
    func shortcut(_ s: AppShortcut) -> some View { keyboardShortcut(s.key, modifiers: s.modifiers) }
}
