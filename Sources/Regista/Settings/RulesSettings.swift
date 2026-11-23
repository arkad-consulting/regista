import AppKit
import RegistaCore
import SwiftUI
import UniformTypeIdentifiers

/// A text the engine gives as `message` / `messageKey` / `messageArgs` (the editing rules, #31), in the app's language:
/// the numbers among the values written as that language writes them (#47).
func loc(message m: JSONValue?) -> String {
    guard let m else { return "" }
    let key = m["messageKey"]?.stringValue ?? m["message"]?.stringValue ?? ""
    let args = m["messageArgs"]?.arrayValue?.compactMap { $0.stringValue ?? $0.doubleValue.map(Words.number) } ?? []
    return args.isEmpty ? loc(key) : String(format: loc(key), locale: Locale.current, arguments: args)
}

/// Bumped after every rule sheet or skill written, from any tab and by an agent (EditorStore.execute): the Export card
/// checks again and Impostazioni › Regia e skill reads again.
@MainActor
final class RulesRevision: ObservableObject {
    static let shared = RulesRevision()
    @Published private(set) var value = 0
    func bump() { value += 1 }
}

/// Impostazioni › Regia e skill as a model (#31, #157): «Per ogni video», the built-in recipes (read-only) and the person's
/// skills, read with rules.list / rules.get / skill.list / skill.get. «Per ogni video» is written with rules.set and reset
/// as before; a skill with skill.set (one undo step each), skill.create, duplicate, remove, export and import. A switch, a
/// choice or a number saves at once; the prose and the steps save when the editor loses the cursor or after a short pause
/// in typing.
@MainActor
final class RulesModel: ObservableObject {
    struct Sheet: Equatable, Identifiable {
        var id: String { kind }
        let kind: String
        /// A lookup key for a built-in sheet, the user's own words for a kind of theirs.
        let title: String
        let builtIn: Bool
        var edited: Bool
        var shownTitle: String { builtIn ? loc(title) : title }
    }

    /// A skill of the person's in the list.
    struct Skill: Equatable, Identifiable {
        var id: String { slug }
        let slug: String
        let title: String
        /// The built-in recipe it is based on.
        let basedOn: String?
    }

    struct Check: Equatable, Identifiable {
        let id: String
        /// English title (a lookup key).
        let title: String
        var on: Bool
        var value: Double?
        var unit: String?
    }

    /// A choice of the sheet on screen (one regia): its options, the option it has, its number when it has one.
    struct Choice: Equatable, Identifiable {
        struct Option: Equatable {
            let id: String
            /// English label (a lookup key).
            let label: String
            /// What it does, as the engine gives it (message / messageKey / messageArgs).
            let meaning: JSONValue
        }
        let id: String
        /// English title (a lookup key).
        let title: String
        /// What the choice is about (a lookup key): the menu's tooltip.
        let meaning: String
        var value: String
        let options: [Option]
        var number: [Double]?
        var unit: String?

        var option: Option? { options.first { $0.id == value } }
    }

    /// The tabs of the item on screen.
    enum Pane: String { case rules, choices, steps }

    /// What «Importa una skill…» found in the file the person chose, before anything is written (skill.import dryRun).
    struct ImportPreview: Equatable {
        let path: String
        let title: String
        /// The built-in recipe it is based on.
        let basedOn: String?
        /// Its check lines, as the person reads them («Minimum text size: 40»).
        let checks: [String]
        let prose: String
        /// Its choices: title and option, as the person reads them.
        let choices: [String]
        let steps: String
        /// The person's skill with the same title, if any.
        let conflict: String?
    }

    weak var store: EditorStore?
    let demo: Bool
    @Published var sheets: [Sheet] = []
    @Published var skills: [Skill] = []
    /// The item on screen: every-video, a built-in recipe or a skill's slug.
    @Published private(set) var selection = RuleBook.everyVideo
    /// The sheet the rules and choices on screen come from (a recipe without a sheet of its own shows its kind's).
    @Published private(set) var kind = RuleBook.everyVideo
    @Published var pane = Pane.rules
    @Published var checks: [Check] = []
    /// The person's choices that apply to the sheet on screen (one regia).
    @Published var choices: [Choice] = []
    @Published private(set) var prose = ""
    @Published private(set) var steps = ""
    @Published var problems: [String] = []
    @Published var path: String?
    @Published var folder: String?
    /// The prose on screen is the one in the file, written by this tab since it was opened.
    @Published var saved = false
    /// The same for the steps.
    @Published var stepsSaved = false
    @Published var error: String?
    @Published var adding = false
    @Published var newTitle = ""
    @Published var renaming = false
    @Published var renameTitle = ""
    @Published var confirmDelete = false
    @Published var importing: ImportPreview?
    /// The title an imported skill takes when one of the person's has the file's.
    @Published var importTitle = ""
    /// The prose and the steps the files hold.
    private var stored = ""
    private var storedSteps = ""
    private var pending: Task<Void, Never>?
    private var pendingSteps: Task<Void, Never>?

    /// Seconds without typing before the prose or the steps are saved.
    static let pause: Double = 1.2

    init(demo: Bool = false) { self.demo = demo }

    var isEveryVideo: Bool { selection == RuleBook.everyVideo }
    var builtInRecipe: Recipe? { Recipes.named(selection) }
    var isBuiltIn: Bool { builtInRecipe != nil }
    var skill: Skill? { skills.first { $0.slug == selection } }
    var isSkill: Bool { skill != nil }
    var sheet: Sheet? { sheets.first { $0.kind == kind } }
    var fileName: String { "\(selection).md" }

    /// The title of an item of the list.
    func title(_ name: String) -> String {
        if let t = RuleBook.builtInTitle(name) { return loc(t) }
        return skills.first { $0.slug == name }?.title ?? name
    }

    var shownTitle: String { title(selection) }

    /// What the header says under the title.
    var subtitle: String {
        if isEveryVideo { return loc("Vale per tutte le skill, anche le tue") }
        if isBuiltIn { return loc("Di Regista: si legge e si duplica, non si cambia") }
        guard let base = skill?.basedOn else { return loc("Basata su nessuna ricetta") }
        return loc("Basata su %@", title(base))
    }

    /// What Mostra nel Finder selects: the file of the item on screen, else the rules folder when it exists.
    var finderURL: URL? {
        if let path { return URL(fileURLWithPath: path) }
        guard let folder, FileManager.default.fileExists(atPath: folder) else { return nil }
        return URL(fileURLWithPath: folder, isDirectory: true)
    }

    /// The tabs of the item on screen: «Per ogni video» has no steps.
    var panes: [Pane] { isEveryVideo ? [.rules, .choices] : [.rules, .choices, .steps] }

    /// The sentence «Chiedi a Claude» copies: the skill's name in an example of what to ask.
    var askClaude: String { loc("Nella mia skill «%@», niente musica e le schede più lunghe", shownTitle) }

    // MARK: Reading

    func load() async {
        guard let store, !demo else { return }
        do {
            try await readLists(store)
            let wanted = UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) ?? selection
            show(valid(wanted) ? wanted : RuleBook.everyVideo)
            try await read(store, prose: true)
        } catch {
            self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
        }
    }

    private func readLists(_ store: EditorStore) async throws {
        let list = try await store.silent("rules.list")
        folder = list["folder"]?.stringValue
        sheets = (list["sheets"]?.arrayValue ?? []).compactMap(Self.sheet)
        skills = (try await store.silent("skill.list")["skills"]?.arrayValue ?? []).compactMap { s in
            s["skill"]?.stringValue.map { Skill(slug: $0, title: s["title"]?.stringValue ?? $0, basedOn: s["basedOn"]?.stringValue) }
        }
    }

    private func valid(_ name: String) -> Bool { name == RuleBook.everyVideo || Recipes.named(name) != nil || skills.contains { $0.slug == name } }

    private func show(_ name: String) {
        selection = name
        kind = Recipes.named(name)?.kind ?? name
        if !panes.contains(pane) { pane = .rules }
    }

    /// The rules and choices of the item on screen, and its steps.
    private func read(_ store: EditorStore, prose withProse: Bool) async throws {
        let (name, k) = (selection, kind)
        let s = try await store.silent("rules.get", ["kind": .string(k)])
        guard selection == name else { return }
        apply(s, prose: withProse)
        guard name != RuleBook.everyVideo else { return }
        let g = try await store.silent("skill.get", ["skill": .string(name)])
        guard selection == name else { return }
        path = g["path"]?.stringValue
        if withProse || steps == storedSteps {
            steps = g["steps"]?.stringValue ?? ""
            storedSteps = steps
        }
    }

    /// A sheet or a skill written elsewhere (an agent, another window, an undo): read again, keeping prose and steps the
    /// person is still typing.
    func refresh() async {
        guard let store, !demo else { return }
        let typing = prose != stored || steps != storedSteps
        guard (try? await readLists(store)) != nil else { return }
        if !valid(selection) { show(RuleBook.everyVideo) }
        try? await read(store, prose: !typing)
    }

    static func sheet(_ j: JSONValue) -> Sheet? {
        guard let kind = j["kind"]?.stringValue else { return nil }
        return Sheet(kind: kind, title: j["title"]?.stringValue ?? kind, builtIn: j["builtIn"]?.boolValue ?? false, edited: j["edited"]?.boolValue ?? false)
    }

    static func choice(_ c: JSONValue) -> Choice? {
        guard let id = c["id"]?.stringValue, let value = c["value"]?.stringValue else { return nil }
        let n = c["number"]
        let number = n.flatMap { $0["value"]?.doubleValue.map { [$0] } ?? $0["value"]?.arrayValue?.compactMap(\.doubleValue) }
        return Choice(id: id, title: c["title"]?.stringValue ?? id, meaning: c["meaning"]?.stringValue ?? "", value: value,
                      options: (c["options"]?.arrayValue ?? []).compactMap { o in
                          o["id"]?.stringValue.map { Choice.Option(id: $0, label: o["label"]?.stringValue ?? $0, meaning: o) }
                      },
                      number: number, unit: n?["unit"]?.stringValue)
    }

    private func apply(_ s: JSONValue, prose withProse: Bool) {
        checks = (s["checks"]?.arrayValue ?? []).compactMap { c in
            guard let id = c["id"]?.stringValue else { return nil }
            return Check(id: id, title: c["title"]?.stringValue ?? id, on: c["on"]?.boolValue ?? true, value: c["value"]?.doubleValue,
                         unit: c["unit"]?.stringValue)
        }
        choices = (s["choices"]?.arrayValue ?? []).compactMap(Self.choice)
        problems = (s["status"]?["problems"]?.arrayValue ?? []).map { loc(message: $0) }
        path = s["path"]?.stringValue
        if let i = sheets.firstIndex(where: { $0.kind == kind }) { sheets[i].edited = s["edited"]?.boolValue ?? false }
        if withProse, let p = s["prose"]?.stringValue {
            prose = p
            stored = p
        }
    }

    // MARK: Writing the rules and choices

    func select(_ name: String) {
        guard name != selection else { return }
        flush()
        flushSteps()
        show(name)
        saved = false
        stepsSaved = false
        error = nil
        renaming = false
        UserDefaults.standard.set(name, forKey: SettingsRoute.rulesKey)
        guard let store, !demo else { return }
        Task { try? await read(store, prose: true) }
    }

    func set(_ id: String, on: Bool) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].on = on
        write(checks: [id: ["on": .bool(on)]])
    }

    func set(_ id: String, value text: String) {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t), v.isFinite else {
            error = loc("«%@» non è un numero", text)
            return
        }
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        write(checks: [id: ["on": .bool(checks[i].on), "value": .number(v)]])
    }

    func choose(_ id: String, _ value: String) {
        guard let i = choices.firstIndex(where: { $0.id == id }), choices[i].value != value else { return }
        choices[i].value = value
        write(choices: [id: .string(value)])
    }

    /// A choice's number as typed ("1,3", "4–10"): sent as numbers, the engine checks the range.
    func choose(_ id: String, number text: String) {
        let parts = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "–", with: "-")
            .split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap(Double.init).filter(\.isFinite)
        guard !values.isEmpty, values.count == parts.count, choices.contains(where: { $0.id == id }) else {
            error = loc("«%@» non è un numero", text)
            return
        }
        write(choices: [id: ["number": .array(values.map { .number($0) })]])
    }

    /// The editor's text changed: saved after a pause in typing.
    func edit(_ text: String) {
        guard text != prose, !isBuiltIn else { return }
        prose = text
        saved = false
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pause))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Saves the prose now when it differs from the file (the editor lost the cursor, another item was chosen).
    func flush() {
        pending?.cancel()
        pending = nil
        guard prose != stored, !demo, !isBuiltIn else { return }
        let text = prose
        write(prose: text)
    }

    private func write(checks: [String: JSONValue] = [:], choices: [String: JSONValue] = [:], prose text: String? = nil) {
        guard let store, !demo, !isBuiltIn else { return }
        let (name, k) = (selection, kind)
        // «Per ogni video»: its sheet (rules.set, as before #157); a skill: skill.set, one undo step.
        let command: String
        var params: [String: JSONValue]
        if name == RuleBook.everyVideo {
            command = "rules.set"
            params = ["kind": .string(k)]
            if !checks.isEmpty { params["checks"] = .object(checks) }
            if !choices.isEmpty { params["choices"] = .object(choices) }
            if let text { params["prose"] = .string(text) }
        } else {
            command = "skill.set"
            params = ["skill": .string(name)]
            var rules: [String: JSONValue] = [:]
            if !checks.isEmpty { rules["checks"] = .object(checks) }
            if let text { rules["prose"] = .string(text) }
            if !rules.isEmpty { params["rules"] = .object(rules) }
            if !choices.isEmpty { params["choices"] = .object(choices) }
        }
        Task {
            do {
                var r = try await store.perform(command, .object(params))
                if command == "skill.set" { r = try await store.silent("rules.get", ["kind": .string(k)]) }
                guard selection == name else { return }
                error = nil
                apply(r, prose: false)
                if let text {
                    stored = text
                    saved = prose == text
                }
            } catch {
                self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
        }
    }

    func reset() {
        guard let store, !demo, isEveryVideo else { return }
        pending?.cancel()
        Task {
            do {
                let r = try await store.perform("rules.reset", ["kind": .string(kind)])
                error = nil
                saved = false
                if let s = r["sheet"] { apply(s, prose: true) }
            } catch {
                self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
        }
    }

    /// Importa… on «Per ogni video»: a Markdown file replaces its sheet (header and prose, as written).
    func importFile() {
        guard let store, !demo, isEveryVideo else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.message = loc("Scegli un file Markdown con le regole: prende il posto di questo foglio")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            error = loc("Non riesco a leggere %@", url.lastPathComponent)
            return
        }
        pending?.cancel()
        let k = kind
        Task {
            do {
                let r = try await store.perform("rules.set", ["kind": .string(k), "text": .string(String(decoding: data, as: UTF8.self))])
                error = nil
                apply(r, prose: true)
            } catch {
                self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
        }
    }

    func showInFinder() {
        guard let url = finderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: The steps

    func editSteps(_ text: String) {
        guard text != steps, isSkill else { return }
        steps = text
        stepsSaved = false
        pendingSteps?.cancel()
        pendingSteps = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pause))
            guard !Task.isCancelled else { return }
            self?.flushSteps()
        }
    }

    func flushSteps() {
        pendingSteps?.cancel()
        pendingSteps = nil
        guard steps != storedSteps, !demo, isSkill, let store else { return }
        let (name, text) = (selection, steps)
        Task {
            do {
                try await store.perform("skill.set", ["skill": .string(name), "steps": .string(text)])
                guard selection == name else { return }
                error = nil
                storedSteps = text
                stepsSaved = steps == text
            } catch {
                self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
        }
    }

    // MARK: The skills

    /// Runs a skill command, reads the lists again and shows `then` (the skill it made), or the error.
    private func skillCommand(_ id: String, _ params: JSONValue, then pick: ((JSONValue) -> String?)? = nil) {
        guard let store, !demo else { return }
        Task {
            do {
                let r = try await store.perform(id, params)
                error = nil
                if let name = pick?(r) { UserDefaults.standard.set(name, forKey: SettingsRoute.rulesKey) }
                await load()
            } catch {
                self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
        }
    }

    /// «X (copia)», «X (copia 2)»…: a title no skill of the person's has.
    func freeTitle(_ base: String) -> String {
        let taken = Set(skills.map { $0.title.lowercased() })
        var t = loc("%@ (copia)", base), n = 2
        while taken.contains(t.lowercased()) {
            t = loc("%@ (copia %@)", base, String(n))
            n += 1
        }
        return t
    }

    func createSkill() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        flush()
        flushSteps()
        skillCommand("skill.create", ["title": .string(title)]) { [weak self] r in
            self?.adding = false
            self?.newTitle = ""
            self?.pane = .steps
            return r["skill"]?.stringValue
        }
    }

    func duplicate() {
        guard isBuiltIn || isSkill else { return }
        flush()
        flushSteps()
        skillCommand("skill.duplicate", ["from": .string(selection), "title": .string(freeTitle(shownTitle))]) { $0["skill"]?.stringValue }
    }

    func startRename() {
        renameTitle = shownTitle
        renaming = true
    }

    func rename() {
        let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSkill, !title.isEmpty else { return }
        renaming = false
        guard title != shownTitle else { return }
        skillCommand("skill.set", ["skill": .string(selection), "title": .string(title)]) { $0["skill"]?.stringValue }
    }

    func delete() {
        guard isSkill else { return }
        pending?.cancel()
        pendingSteps?.cancel()
        let name = selection
        skillCommand("skill.remove", ["skill": .string(name)]) { _ in RuleBook.everyVideo }
    }

    /// Esporta…: a save panel, then the skill's file where the person chose.
    func exportSkill() {
        guard isSkill, !demo else { return }
        flush()
        flushSteps()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = fileName
        panel.message = loc("Dove salvare la skill «%@»", shownTitle)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        skillCommand("skill.export", ["skill": .string(selection), "path": .string(url.path)])
    }

    /// Importa una skill…: an open panel, then what the file says (nothing written yet), or why it is refused.
    func importSkill() {
        guard let store, !demo else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.message = loc("Scegli il file di una skill: Regista ti mostra cosa dice prima di aggiungerla")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let r = try await store.silent("skill.import", ["path": .string(url.path), "dryRun": true])
                error = nil
                importing = Self.preview(r, path: url.path)
                importTitle = importing.map { $0.conflict == nil ? $0.title : freeTitle($0.title) } ?? ""
            } catch {
                self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
        }
    }

    static func preview(_ r: JSONValue, path: String) -> ImportPreview? {
        guard let s = r["skill"], let title = s["title"]?.stringValue else { return nil }
        let checks: [String] = (s["rules"]?["switches"]?.arrayValue ?? []).compactMap { c in
            guard let id = c["id"]?.stringValue, let spec = RuleCheckSpec.named(id) else { return nil }
            let state = c["on"] == false ? loc("spento") : (c["value"]?.doubleValue).map { RulesSettings.number($0) + " " + (spec.number?.unit ?? "") } ?? loc("acceso")
            return loc(spec.title) + ": " + state
        }
        let choices: [String] = (s["choices"]?.arrayValue ?? []).compactMap { c in
            guard let t = c["title"]?.stringValue, let l = c["label"]?.stringValue else { return nil }
            return loc(t) + ": " + loc(l)
        }
        return ImportPreview(path: path, title: title, basedOn: s["basedOn"]?.stringValue, checks: checks, prose: s["rules"]?["prose"]?.stringValue ?? "",
                             choices: choices, steps: s["steps"]?.stringValue ?? "", conflict: s["conflict"]?["title"]?.stringValue)
    }

    /// Aggiungi (under the file's title, or the new one a conflict asks for) or Sostituisci.
    func confirmImport(replace: Bool) {
        guard let p = importing else { return }
        var params: [String: JSONValue] = ["path": .string(p.path)]
        if replace { params["replace"] = true }
        else if p.conflict != nil || importTitle.trimmingCharacters(in: .whitespaces) != p.title {
            params["title"] = .string(importTitle.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        importing = nil
        skillCommand("skill.import", .object(params)) { $0["added"]?.stringValue }
    }

    func copyAsk(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(askClaude, forType: .string)
    }

    // MARK: Sample (renders)

    /// The tab with sample sheets, from the shipped ones: «for every video» edited with the text size off, the built-in
    /// recipes and a skill of the person's. Nothing is read from or written to the support folder.
    static func sample() -> RulesModel {
        let m = RulesModel(demo: true)
        let book = RuleBook(directory: URL(fileURLWithPath: "/nonexistent"))
        let language = RuleBook.interfaceLanguage()
        m.sheets = ([RuleBook.everyVideo] + RuleBook.builtInKinds).map {
            Sheet(kind: $0, title: book.title($0, language: language), builtIn: true, edited: $0 == RuleBook.everyVideo)
        }
        // l10n-ignore-begin — sample data: a skill a user named
        m.skills = [Skill(slug: "youtube-tutorial", title: "Tutorial YouTube", basedOn: "screen-tutorial")]
        // l10n-ignore-end
        m.checks = book.checks(RuleBook.everyVideo, language: language).map {
            Check(id: $0.spec.id, title: $0.spec.title, on: $0.spec.id != "text-size", value: $0.value, unit: $0.spec.number?.unit)
        }
        m.choices = book.choices(RuleBook.everyVideo, language: language).compactMap { choice($0.json) }
        m.prose = RuleSheetText.parse(book.text(RuleBook.everyVideo, language: language) ?? "").prose
        m.stored = m.prose
        m.path = "/rules/every-video.md"
        return m
    }
}

/// Impostazioni › Regia e skill (#31, #157): on the left «Per ogni video», the built-in recipes (Di Regista, read-only)
/// and the person's skills (Le tue), «+ Nuova skill…» and «Importa una skill…»; on the right the item on screen: its title,
/// what it is based on, Duplica · Esporta… · ⋯ (Rinomina, Elimina), and the tabs Regole (the checks, their switches and
/// numbers, the prose Claude reads), Scelte (a segmented control, or a menu above four options, and the number where one
/// exists) and Passi (the steps, a Markdown editor, Mostra nel Finder, «Chiedi a Claude»). Importing shows what the file
/// says in a sheet before anything is written. Design-system controls only, so every one is driven by the mouse tests.
struct RulesSettings: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.pasteboard) private var pasteboard
    @ObservedObject private var revision = RulesRevision.shared
    @StateObject private var model: RulesModel
    /// The height of what an imported file says (the import sheet's box follows it).
    @State private var importHeight: CGFloat = 120

    init(demo: Bool = false) {
        _model = StateObject(wrappedValue: demo ? RulesModel.sample() : RulesModel())
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn.frame(width: Self.listWidth)
            Ed.rule.frame(width: 1)
            itemPane
        }
        .overlay { if let p = model.importing { importSheet(p) } }
        .task {
            model.store = store
            await model.load()
        }
        .onChange(of: revision.value) { Task { await model.refresh() } }
        .onDisappear {
            model.flush()
            model.flushSteps()
        }
        .confirmationDialog(loc("Eliminare la skill «%@»?", model.shownTitle), isPresented: $model.confirmDelete) {
            Button(loc("Elimina"), role: .destructive) { model.delete() }
        } message: {
            Text(verbatim: loc("Il file della skill viene eliminato: i progetti che la usano seguono le regole del loro formato. Puoi annullare con ⌘Z."))
        }
    }

    // MARK: The list

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: Ed.Space.xxs) {
            ScrollView {
                VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                    row(RuleBook.everyVideo, detail: model.sheets.first { $0.kind == RuleBook.everyVideo }?.edited == true ? "•" : nil)
                    groupLabel("Di Regista").padding(.top, 10)
                    ForEach(Recipes.all.map(\.name), id: \.self) { name in
                        row(name, detail: model.sheets.first { $0.kind == Recipes.named(name)?.kind }?.edited == true ? "•" : nil)
                    }
                    groupLabel("Le tue").padding(.top, 10)
                    ForEach(model.skills) { s in
                        // What it is based on is in its header: the row keeps its room for the title.
                        row(s.slug, detail: nil)
                    }
                    if model.skills.isEmpty {
                        Text(verbatim: loc("Nessuna skill: duplicane una di Regista, creane una nuova o importala."))
                            .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Ed.Space.s)
                    }
                    if model.adding { newSkill.padding(.top, Ed.Space.s) } else {
                        VStack(alignment: .leading, spacing: 6) {
                            EdButton(title: "+ Nuova skill…", fill: true) { model.adding = true }
                            EdButton(title: "Importa una skill…", quiet: true, fill: true) { model.importSkill() }
                        }
                        .padding(.top, Ed.Space.s)
                    }
                }
            }
            Text(verbatim: loc("Claude legge «%@» più la skill scelta nel progetto.", loc("For every video")))
                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Ed.Space.s).padding(.top, Ed.Space.s)
        }
        .padding(.horizontal, 10).padding(.vertical, 14)
    }

    private func groupLabel(_ key: String) -> some View {
        Text(verbatim: loc(key).uppercased()).font(Ed.ui(Ed.TypeSize.caption, .semibold)).foregroundStyle(Ed.text3)
            .padding(.horizontal, Ed.Space.s).padding(.bottom, Ed.Space.xs)
    }

    private func row(_ name: String, detail: String?) -> some View {
        SideRow(symbol: Self.symbol(name), title: model.title(name), detail: detail, on: name == model.selection, truncation: .tail) {
            model.select(name)
        }
    }

    /// The list: the longest built-in name of the four languages on one line beside an edited sheet's dot (#130); a skill
    /// the person named longer is cut at its end, before what it is based on.
    static let listWidth: CGFloat = 252

    static func symbol(_ name: String) -> String {
        switch name {
        case RuleBook.everyVideo: "checklist"
        case "talking-head-reel": "person.crop.rectangle"
        case "screen-tutorial": "display"
        case "voice-over-video": "waveform"
        case "reel-graphics": "textformat"
        case "prompt-to-reel": "text.bubble"
        default: "doc.text"
        }
    }

    private var newSkill: some View {
        VStack(alignment: .leading, spacing: 6) {
            RTextField(placeholder: "Nome della skill", text: $model.newTitle)
                .onSubmit { model.createSkill() }
            Text(verbatim: loc("Parte vuota: i passi, le regole e le scelte li scrivi tu o Claude."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                EdButton(title: "Annulla", quiet: true) {
                    model.adding = false
                    model.newTitle = ""
                }
                EdButton(title: "Crea", prominent: true, disabled: model.newTitle.trimmingCharacters(in: .whitespaces).isEmpty) { model.createSkill() }
            }
        }
    }

    // MARK: The item on screen

    /// The prose editor's height: the pane scrolls (the checks, then the prose), the buttons stay below it.
    static let editorHeight: CGFloat = 240
    /// The steps editor's height.
    static let stepsHeight: CGFloat = 200

    private var itemPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.horizontal, 20)
            RSegmented(items: model.panes.map { ($0, Self.paneTitle($0)) }, selection: $model.pane, fill: false)
                .fixedSize()
                .padding(.horizontal, 20)
            ScrollView {
                paneContent.padding(.horizontal, 20).padding(.bottom, Ed.Space.s)
            }
            if model.isEveryVideo { buttons.padding(.horizontal, 20) }
        }
        .padding(EdgeInsets(top: Ed.Space.l, leading: 0, bottom: 14, trailing: 0))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func paneTitle(_ p: RulesModel.Pane) -> String {
        switch p {
        case .rules: "Regole"
        case .choices: "Scelte"
        case .steps: "Passi"
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Ed.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                if model.renaming {
                    HStack(spacing: 6) {
                        RTextField(placeholder: "Nome della skill", text: $model.renameTitle).onSubmit { model.rename() }
                        EdButton(title: "Annulla", quiet: true) { model.renaming = false }
                        EdButton(title: "Salva", prominent: true, disabled: model.renameTitle.trimmingCharacters(in: .whitespaces).isEmpty) { model.rename() }
                    }
                } else {
                    Text(verbatim: model.shownTitle).font(Ed.ui(Ed.TypeSize.title, .bold)).foregroundStyle(Ed.text).lineLimit(1).truncationMode(.tail)
                }
                Text(verbatim: model.subtitle).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).lineLimit(1)
            }
            Spacer(minLength: Ed.Space.s)
            if !model.renaming {
                HStack(spacing: 6) {
                    if model.isBuiltIn || model.isSkill {
                        EdButton(title: "Duplica") { model.duplicate() }
                    }
                    if model.isSkill {
                        EdButton(title: "Esporta…") { model.exportSkill() }
                        FormatMenu(label: loc("Altre azioni"), items: [
                            FormatMenu.Item(id: "rename", title: loc("Rinomina…"), symbol: "pencil"),
                            FormatMenu.Item(id: "delete", title: loc("Elimina…"), symbol: "trash"),
                        ], selected: nil, tip: loc("Rinomina o elimina la skill"), symbol: "ellipsis", height: Ed.Height.control, display: "") { id in
                            if id == "rename" { model.startRename() } else { model.confirmDelete = true }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var paneContent: some View {
        switch model.pane {
        case .rules: rulesPane
        case .choices: choicesPane
        case .steps: stepsPane
        }
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.problems, id: \.self) { p in
                Label { Text(verbatim: p) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.warn)
            }
            if let e = model.error {
                Text(verbatim: e).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rulesPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: loc("Controlli prima dell'export")).font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text3)
            VStack(spacing: 0) {
                ForEach(Array(model.checks.enumerated()), id: \.element.id) { i, c in
                    checkRow(c)
                    if i < model.checks.count - 1 { Ed.line.frame(height: 1) }
                }
            }
            .padding(.horizontal, Ed.Space.m)
            .rCard(.raised, padding: 0)
            .disabled(model.isBuiltIn)
            if model.isSkill {
                Text(verbatim: loc("Un controllo cambiato qui vale solo per questa skill; gli altri seguono «%@».", loc("For every video")))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
            messages
            HStack(alignment: .firstTextBaseline, spacing: Ed.Space.m) {
                Text(verbatim: loc(model.isSkill ? "Regole che la skill aggiunge" : "Regole che Claude legge prima di montare"))
                    .font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text3)
                Spacer(minLength: Ed.Space.s)
                if model.saved {
                    Text(verbatim: loc("salvato")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.ok)
                }
                if !model.isBuiltIn {
                    Text(verbatim: loc("Markdown · %@", model.fileName)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).lineLimit(1)
                }
            }
            if model.isBuiltIn {
                readOnly(model.prose, height: Self.editorHeight)
            } else {
                RTextEditor(placeholder: "Le regole, in Markdown", text: Binding(get: { model.prose }, set: { model.edit($0) }),
                            kind: .scrolls(min: Self.editorHeight, max: Self.editorHeight), mono: true, onBlur: { model.flush() })
            }
        }
    }

    private var choicesPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            messages
            VStack(spacing: 0) {
                ForEach(Array(model.choices.enumerated()), id: \.element.id) { i, c in
                    choiceRow(c)
                    if i < model.choices.count - 1 { Ed.line.frame(height: 1) }
                }
            }
            .padding(.horizontal, Ed.Space.m)
            .rCard(.raised, padding: 0)
            .disabled(model.isBuiltIn)
            if model.isSkill {
                Text(verbatim: loc("Una scelta cambiata qui vale solo per questa skill; le altre seguono «%@».", loc("For every video")))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stepsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: loc(model.isBuiltIn ? "I passi che Claude segue con questa ricetta. Duplicala per cambiarli."
                                               : "I passi che Claude segue quando usi questa skill. Li cambi tu o Claude; le regole valgono comunque."))
                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            messages
            if model.isBuiltIn {
                readOnly(model.steps, height: Self.stepsHeight)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Ed.Space.m) {
                    Text(verbatim: loc("Passi")).font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text3)
                    Spacer(minLength: Ed.Space.s)
                    if model.stepsSaved {
                        Text(verbatim: loc("salvato")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.ok)
                    }
                    Text(verbatim: loc("Markdown · %@", model.fileName)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).lineLimit(1)
                }
                RTextEditor(placeholder: "1. Il primo passo…", text: Binding(get: { model.steps }, set: { model.editSteps($0) }),
                            kind: .scrolls(min: Self.stepsHeight, max: Self.stepsHeight), mono: true, onBlur: { model.flushSteps() })
                HStack(spacing: Ed.Space.s) {
                    EdButton(title: "Mostra nel Finder", disabled: model.finderURL == nil) { model.showInFinder() }
                    Spacer()
                }
                askClaude
            }
        }
    }

    /// «Chiedi a Claude»: an example of what to ask about this skill, and Copia (nothing is sent anywhere by the app).
    private var askClaude: some View {
        HStack(spacing: Ed.Space.s) {
            Image(systemName: "sparkles").font(Ed.icon(Ed.TypeSize.small)).foregroundStyle(Ed.gold)
            (Text(verbatim: loc("Chiedi a Claude") + "  ").font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundColor(Ed.gold)
                + Text(verbatim: "«" + model.askClaude + "»").font(Ed.ui(Ed.TypeSize.small)).foregroundColor(Ed.text2))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Ed.Space.s)
            EdButton(title: "Copia", symbol: "doc.on.doc") { model.copyAsk(to: pasteboard) }
        }
        .padding(.horizontal, Ed.Space.m).padding(.vertical, Ed.Space.s)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.m, style: .continuous).fill(Ed.gold.opacity(0.12)))
    }

    /// A built-in's text, read-only, in the editor's frame.
    private func readOnly(_ text: String, height: CGFloat) -> some View {
        ScrollView {
            Text(verbatim: text).font(Ed.mono(Ed.TypeSize.body)).foregroundStyle(Ed.text2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Ed.Space.s)
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(Ed.well))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.m).strokeBorder(Ed.line2))
    }

    private var buttons: some View {
        HStack(spacing: Ed.Space.s) {
            EdButton(title: "Mostra nel Finder", disabled: model.finderURL == nil) { model.showInFinder() }
            EdButton(title: "Importa…") { model.importFile() }
            Spacer()
            EdButton(title: "Ripristina il predefinito", disabled: model.sheet?.edited != true) { model.reset() }
        }
    }

    // MARK: The import sheet

    /// What the chosen file says, before anything is written: title, what it is based on, its rules, choices and steps;
    /// Aggiungi / Annulla, and on a conflict Sostituisci or another title.
    private func importSheet(_ p: RulesModel.ImportPreview) -> some View {
        ZStack {
            Color.black.opacity(0.35).contentShape(Rectangle()).onTapGesture {}
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: loc("Importa una skill")).font(Ed.ui(Ed.TypeSize.title, .bold)).foregroundStyle(Ed.text)
                Text(verbatim: loc("Ecco cosa dice il file. Niente è stato aggiunto: decidi tu.")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                let says = VStack(alignment: .leading, spacing: 8) {
                    field("Titolo", p.title)
                    field("Basata su", p.basedOn.map { model.title($0) } ?? loc("nessuna ricetta"))
                    field("Regole", (p.checks + (p.prose.isEmpty ? [] : [p.prose.trimmingCharacters(in: .whitespacesAndNewlines)])).joined(separator: "\n"))
                    field("Scelte", p.choices.joined(separator: "\n"))
                    field("Passi", p.steps)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Whole when it fits, else it scrolls: the box takes the height of what the file says, at most 300 pt.
                ScrollView {
                    says.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { importHeight = $0 }
                }
                .frame(height: min(max(importHeight, 40), 300))
                if let conflict = p.conflict {
                    Text(verbatim: loc("Hai già una skill «%@»: sostituiscila, o aggiungi questa con un altro nome.", conflict))
                        .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.warn).fixedSize(horizontal: false, vertical: true)
                    RTextField(placeholder: "Nome della skill", text: $model.importTitle)
                }
                HStack(spacing: 6) {
                    Spacer()
                    EdButton(title: "Annulla", quiet: true) { model.importing = nil }
                    if p.conflict != nil {
                        EdButton(title: "Sostituisci", destructive: true) { model.confirmImport(replace: true) }
                    }
                    EdButton(title: "Aggiungi", prominent: true,
                             disabled: model.importTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                || (p.conflict != nil && model.importTitle.trimmingCharacters(in: .whitespaces).lowercased() == p.conflict?.lowercased())) {
                        model.confirmImport(replace: false)
                    }
                }
            }
            .padding(Ed.Space.l)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(Ed.side))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).strokeBorder(Ed.line2))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
    }

    private func field(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: loc(key)).font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text3)
            Text(verbatim: value.isEmpty ? "—" : value).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Rows

    /// A choice: its title, the number where it has one and the control on one line; under them what the current option
    /// does. Four options or fewer: a segmented control; more: a menu (the caption style, the format).
    private func choiceRow(_ c: RulesModel.Choice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Ed.Space.s) {
                Text(verbatim: loc(c.title)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text).lineLimit(1).groupTip(loc(c.meaning))
                Spacer(minLength: Ed.Space.s)
                if let n = c.number {
                    InspectorValueField(text: Self.numbers(n), width: n.count == 2 ? 58 : 46, alignment: .center) { model.choose(c.id, number: $0) }
                    if let unit = c.unit, !unit.isEmpty {
                        Text(verbatim: unit).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text3)
                    }
                }
                if c.options.count > 4 {
                    FormatMenu(label: loc(c.option?.label ?? c.value),
                               items: c.options.map { FormatMenu.Item(id: $0.id, title: loc($0.label), symbol: Self.symbol(choice: c.id, option: $0.id)) },
                               selected: c.value, tip: loc(c.meaning)) { model.choose(c.id, $0) }
                } else {
                    RSegmented(items: c.options.map { ($0.id, $0.label) }, selection: Binding(get: { c.value }, set: { model.choose(c.id, $0) }), fill: false)
                        .fixedSize()
                }
            }
            if let meaning = c.option?.meaning {
                Text(verbatim: loc(message: meaning)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
        .frame(minHeight: 34)
    }

    /// The glyph of a menu's option: a format's shape, a caption style's speech bubble.
    static func symbol(choice: String, option: String) -> String {
        guard choice == "format" else { return "captions.bubble" }
        return option == "project" ? "aspectratio" : FormatMenu.symbol(option)
    }

    /// "1,15", "6–12": a choice's number, or its range, as the person reads it.
    static func numbers(_ values: [Double]) -> String { values.map(number).joined(separator: "–") }

    private func checkRow(_ c: RulesModel.Check) -> some View {
        HStack(spacing: Ed.Space.s) {
            Text(verbatim: loc(c.title)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(c.on ? Ed.text : Ed.text3)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Ed.Space.s)
            if let v = c.value, let unit = c.unit {
                InspectorValueField(text: Self.number(v), width: 46, alignment: .center) { model.set(c.id, value: $0) }
                if c.id == "logo-pause" {
                    // The engine warns past the minimum + 0.3 s (RuleCheck.logoPause).
                    Text(verbatim: "– " + Self.number(v + 0.3)).font(Ed.mono(Ed.TypeSize.body)).foregroundStyle(Ed.text3)
                }
                Text(verbatim: unit).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text3)
            }
            RSwitch(isOn: Binding(get: { c.on }, set: { model.set(c.id, on: $0) }), label: c.title)
        }
        .frame(minHeight: 34)
    }

    /// "0,3", "28": a number as the person reads it, in the words' language.
    static func number(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Words.locale
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}
