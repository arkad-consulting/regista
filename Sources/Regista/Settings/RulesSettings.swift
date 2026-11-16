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

/// Bumped after every rule sheet written, from any tab and by an agent (EditorStore.execute): the Export card checks again.
@MainActor
final class RulesRevision: ObservableObject {
    static let shared = RulesRevision()
    @Published private(set) var value = 0
    func bump() { value += 1 }
}

/// The rule sheets as Impostazioni › Regole shows them: read with rules.list / rules.get, written with rules.set, reset,
/// addKind, removeKind (logged like any command). A switch or a number saves at once; the prose saves when the editor
/// loses the cursor or after a short pause in typing.
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

    struct Check: Equatable, Identifiable {
        let id: String
        /// English title (a lookup key).
        let title: String
        var on: Bool
        var value: Double?
        var unit: String?
    }

    weak var store: EditorStore?
    let demo: Bool
    @Published var sheets: [Sheet] = []
    @Published private(set) var kind = RuleBook.everyVideo
    @Published var checks: [Check] = []
    @Published private(set) var prose = ""
    @Published var problems: [String] = []
    @Published var path: String?
    @Published var folder: String?
    /// The prose on screen is the one in the file, written by this tab since it was opened.
    @Published var saved = false
    @Published var error: String?
    @Published var adding = false
    @Published var newTitle = ""
    @Published var confirmDelete = false
    /// The prose the file holds.
    private var stored = ""
    private var pending: Task<Void, Never>?

    /// Seconds without typing before the prose is saved.
    static let pause: Double = 1.2

    init(demo: Bool = false) { self.demo = demo }

    var sheet: Sheet? { sheets.first { $0.kind == kind } }
    var isEveryVideo: Bool { kind == RuleBook.everyVideo }
    var fileName: String { "\(kind).md" }
    /// What Mostra nel Finder selects: the user's file, else the rules folder when it exists.
    var finderURL: URL? {
        if let path { return URL(fileURLWithPath: path) }
        guard let folder, FileManager.default.fileExists(atPath: folder) else { return nil }
        return URL(fileURLWithPath: folder, isDirectory: true)
    }

    // MARK: Reading

    func load() async {
        guard let store, !demo else { return }
        do {
            let list = try await store.silent("rules.list")
            folder = list["folder"]?.stringValue
            sheets = (list["sheets"]?.arrayValue ?? []).compactMap(Self.sheet)
            let wanted = UserDefaults.standard.string(forKey: SettingsRoute.rulesKey) ?? kind
            kind = sheets.contains { $0.kind == wanted } ? wanted : RuleBook.everyVideo
            apply(try await store.silent("rules.get", ["kind": .string(kind)]), prose: true)
        } catch {
            self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
        }
    }

    /// A sheet written elsewhere (an agent, another window): read again, keeping prose the person is still typing.
    func refresh() async {
        guard let store, !demo else { return }
        let typing = prose != stored
        guard let list = try? await store.silent("rules.list") else { return }
        sheets = (list["sheets"]?.arrayValue ?? []).compactMap(Self.sheet)
        if !sheets.contains(where: { $0.kind == kind }) { kind = RuleBook.everyVideo }
        if let s = try? await store.silent("rules.get", ["kind": .string(kind)]) { apply(s, prose: !typing) }
    }

    static func sheet(_ j: JSONValue) -> Sheet? {
        guard let kind = j["kind"]?.stringValue else { return nil }
        return Sheet(kind: kind, title: j["title"]?.stringValue ?? kind, builtIn: j["builtIn"]?.boolValue ?? false, edited: j["edited"]?.boolValue ?? false)
    }

    private func apply(_ s: JSONValue, prose withProse: Bool) {
        checks = (s["checks"]?.arrayValue ?? []).compactMap { c in
            guard let id = c["id"]?.stringValue else { return nil }
            return Check(id: id, title: c["title"]?.stringValue ?? id, on: c["on"]?.boolValue ?? true, value: c["value"]?.doubleValue,
                         unit: c["unit"]?.stringValue)
        }
        problems = (s["status"]?["problems"]?.arrayValue ?? []).map { loc(message: $0) }
        path = s["path"]?.stringValue
        if let i = sheets.firstIndex(where: { $0.kind == kind }) { sheets[i].edited = s["edited"]?.boolValue ?? false }
        if withProse, let p = s["prose"]?.stringValue {
            prose = p
            stored = p
        }
    }

    // MARK: Writing

    func select(_ k: String) {
        guard k != kind else { return }
        flush()
        kind = k
        saved = false
        error = nil
        UserDefaults.standard.set(k, forKey: SettingsRoute.rulesKey)
        guard let store, !demo else { return }
        Task { if let s = try? await store.silent("rules.get", ["kind": .string(k)]), kind == k { apply(s, prose: true) } }
    }

    func set(_ id: String, on: Bool) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].on = on
        write(["kind": .string(kind), "checks": .object([id: ["on": .bool(on)]])])
    }

    func set(_ id: String, value text: String) {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t), v.isFinite else {
            error = loc("«%@» non è un numero", text)
            return
        }
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        write(["kind": .string(kind), "checks": .object([id: ["on": .bool(checks[i].on), "value": .number(v)]])])
    }

    /// The editor's text changed: saved after a pause in typing.
    func edit(_ text: String) {
        guard text != prose else { return }
        prose = text
        saved = false
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pause))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Saves the prose now when it differs from the file (the editor lost the cursor, another sheet was chosen).
    func flush() {
        pending?.cancel()
        pending = nil
        guard prose != stored, !demo else { return }
        let text = prose
        write(["kind": .string(kind), "prose": .string(text)], sent: text)
    }

    private func write(_ params: JSONValue, sent: String? = nil, reload: Bool = false) {
        guard let store, !demo else { return }
        let k = kind
        Task {
            do {
                let r = try await store.perform("rules.set", params)
                guard kind == k else { return }
                error = nil
                apply(r, prose: reload)
                if let sent {
                    stored = sent
                    saved = prose == sent
                }
            } catch {
                self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
        }
    }

    func reset() {
        guard let store, !demo else { return }
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

    func delete() {
        guard let store, !demo, sheet?.builtIn == false else { return }
        pending?.cancel()
        let k = kind
        Task {
            do {
                try await store.perform("rules.removeKind", ["kind": .string(k)])
                UserDefaults.standard.set(RuleBook.everyVideo, forKey: SettingsRoute.rulesKey)
                await load()
            } catch {
                self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
        }
    }

    /// The new kind starts from the sheet on screen when it is a kind (an empty sheet from «for every video»).
    var addFrom: Sheet? { isEveryVideo ? nil : sheet }

    func addKind() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !demo, !title.isEmpty else { return }
        flush()
        var params: [String: JSONValue] = ["title": .string(title)]
        if let from = addFrom { params["from"] = .string(from.kind) }
        Task {
            do {
                let r = try await store.perform("rules.addKind", .object(params))
                adding = false
                newTitle = ""
                if let k = r["kind"]?.stringValue { UserDefaults.standard.set(k, forKey: SettingsRoute.rulesKey) }
                await load()
            } catch {
                self.error = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
        }
    }

    /// Importa…: a Markdown file replaces the sheet on screen (header and prose, as written).
    func importFile() {
        guard !demo else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.message = loc("Scegli un file Markdown con le regole: prende il posto di questo foglio")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            error = loc("Non riesco a leggere %@", url.lastPathComponent)
            return
        }
        pending?.cancel()
        write(["kind": .string(kind), "text": .string(String(decoding: data, as: UTF8.self))], reload: true)
    }

    func showInFinder() {
        guard let url = finderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Sample (renders)

    /// The tab with sample sheets, from the shipped ones: «for every video» edited with the text size off, and a
    /// kind of the user's own. Nothing is read from or written to the rules folder.
    static func sample() -> RulesModel {
        let m = RulesModel(demo: true)
        let book = RuleBook(directory: URL(fileURLWithPath: "/nonexistent"))
        let language = RuleBook.interfaceLanguage()
        m.sheets = ([RuleBook.everyVideo] + RuleBook.builtInKinds).map {
            Sheet(kind: $0, title: book.title($0, language: language), builtIn: true, edited: $0 == RuleBook.everyVideo)
        }
        // l10n-ignore-begin — sample data: a kind a user named
        m.sheets.append(Sheet(kind: "youtube-tutorial", title: "Tutorial YouTube", builtIn: false, edited: true))
        // l10n-ignore-end
        m.checks = book.checks(RuleBook.everyVideo, language: language).map {
            Check(id: $0.spec.id, title: $0.spec.title, on: $0.spec.id != "text-size", value: $0.value, unit: $0.spec.number?.unit)
        }
        m.prose = RuleSheetText.parse(book.text(RuleBook.everyVideo, language: language) ?? "").prose
        m.stored = m.prose
        m.path = "/rules/every-video.md"
        return m
    }
}

/// Impostazioni › Regole (#31): the sheets on the left (for every video, the kinds, «new kind…»), the sheet on screen on
/// the right: its checks with their switches and numbers, the prose Claude reads (Markdown), Mostra nel Finder, Importa…,
/// Ripristina il predefinito (Elimina… for a kind of the user's own). Design-system controls only, so every one is driven
/// by the mouse tests (the native form is not, #36).
struct RulesSettings: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var revision = RulesRevision.shared
    @StateObject private var model: RulesModel

    init(demo: Bool = false) {
        _model = StateObject(wrappedValue: demo ? RulesModel.sample() : RulesModel())
    }

    var body: some View {
        HStack(spacing: 0) {
            sheetsColumn.frame(width: 224)
            Ed.rule.frame(width: 1)
            sheetPane
        }
        .task {
            model.store = store
            await model.load()
        }
        .onChange(of: revision.value) { Task { await model.refresh() } }
        .onDisappear { model.flush() }
        .confirmationDialog(loc("Eliminare il tipo «%@»?", model.sheet?.shownTitle ?? ""), isPresented: $model.confirmDelete) {
            Button(loc("Elimina"), role: .destructive) { model.delete() }
        } message: {
            Text(verbatim: loc("Il foglio viene eliminato: i progetti di questo tipo seguono le regole del loro formato."))
        }
    }

    // MARK: The sheets

    private var sheetsColumn: some View {
        VStack(alignment: .leading, spacing: Ed.Space.xxs) {
            ScrollView {
                VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                    groupLabel("Vale sempre")
                    ForEach(model.sheets.filter { $0.kind == RuleBook.everyVideo }) { row($0) }
                    groupLabel("Per tipo di video").padding(.top, 10)
                    ForEach(model.sheets.filter { $0.kind != RuleBook.everyVideo }) { row($0) }
                    if model.adding { newKind.padding(.top, Ed.Space.s) } else {
                        RChips<String>(items: [], selection: nil, add: .init(title: "Nuovo tipo…") {
                            model.adding = true
                        }) { _ in }
                        .padding(.top, Ed.Space.s)
                    }
                }
            }
            Text(verbatim: loc("Claude legge «%@» più il foglio del tipo scelto nel progetto.", loc("For every video")))
                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Ed.Space.s).padding(.top, Ed.Space.s)
        }
        .padding(.horizontal, 10).padding(.vertical, 14)
    }

    private func groupLabel(_ key: String) -> some View {
        Text(verbatim: loc(key)).font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text3)
            .padding(.horizontal, Ed.Space.s).padding(.bottom, Ed.Space.xs)
    }

    private func row(_ s: RulesModel.Sheet) -> some View {
        SideRow(symbol: Self.symbol(s.kind), title: s.shownTitle,
                // An edited built-in sheet: a dot (the header says «modificato da te»); a kind of the user's: «tuo».
                detail: s.builtIn ? (s.edited ? "•" : nil) : loc("tuo"), on: s.kind == model.kind) {
            model.select(s.kind)
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case RuleBook.everyVideo: "checklist"
        case "talking-head-reel": "person.crop.rectangle"
        case "screen-tutorial": "display"
        case "voice-over-video": "waveform"
        case "reel-graphics": "textformat"
        default: "doc.text"
        }
    }

    private var newKind: some View {
        VStack(alignment: .leading, spacing: 6) {
            RTextField(placeholder: "Nome del tipo", text: $model.newTitle)
            Text(verbatim: model.addFrom.map { loc("Parte dal foglio «%@»", $0.shownTitle) } ?? loc("Parte da un foglio vuoto"))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            HStack(spacing: 6) {
                EdButton(title: "Annulla", quiet: true) {
                    model.adding = false
                    model.newTitle = ""
                }
                EdButton(title: "Crea", prominent: true, disabled: model.newTitle.trimmingCharacters(in: .whitespaces).isEmpty) { model.addKind() }
            }
        }
    }

    // MARK: The sheet on screen

    private var meta: String {
        let on = model.checks.filter(\.on).count
        let count = on == 1 ? loc("1 controllo attivo") : loc("%@ controlli attivi", "\(on)")
        guard let s = model.sheet else { return count }
        let origin = s.builtIn ? (s.edited ? loc("modificato da te") : loc("predefinito")) : loc("tipo tuo")
        return origin + " · " + count
    }

    private var sheetPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: Ed.Space.m) {
                Text(verbatim: model.sheet?.shownTitle ?? "").font(Ed.ui(Ed.TypeSize.title, .bold)).foregroundStyle(Ed.text).lineLimit(1)
                Spacer(minLength: Ed.Space.s)
                Text(verbatim: meta).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).lineLimit(1)
            }
            Text(verbatim: loc("Controlli prima dell'export")).font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text3)
            VStack(spacing: 0) {
                ForEach(Array(model.checks.enumerated()), id: \.element.id) { i, c in
                    checkRow(c)
                    if i < model.checks.count - 1 { Ed.line.frame(height: 1) }
                }
            }
            .padding(.horizontal, Ed.Space.m)
            .rCard(.raised, padding: 0)
            if !model.isEveryVideo {
                Text(verbatim: loc("Un controllo cambiato qui vale solo per questo tipo; gli altri seguono «%@».", loc("For every video")))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.problems, id: \.self) { p in
                Label { Text(verbatim: p) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.warn)
            }
            if let e = model.error {
                Text(verbatim: e).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: Ed.Space.m) {
                Text(verbatim: loc("Regole che Claude legge prima di montare")).font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text3)
                Spacer(minLength: Ed.Space.s)
                if model.saved {
                    Text(verbatim: loc("salvato")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.ok)
                }
                Text(verbatim: loc("Markdown · %@", model.fileName)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).lineLimit(1)
            }
            RTextEditor(placeholder: "Le regole, in Markdown", text: Binding(get: { model.prose }, set: { model.edit($0) }),
                        kind: .scrolls(min: 80, max: .infinity), mono: true, onBlur: { model.flush() })
            HStack(spacing: Ed.Space.s) {
                EdButton(title: "Mostra nel Finder", disabled: model.finderURL == nil) { model.showInFinder() }
                EdButton(title: "Importa…") { model.importFile() }
                Spacer()
                if model.sheet?.builtIn == false {
                    EdButton(title: "Elimina il tipo…", destructive: true) { model.confirmDelete = true }
                } else {
                    EdButton(title: "Ripristina il predefinito", disabled: model.sheet?.edited != true) { model.reset() }
                }
            }
        }
        .padding(EdgeInsets(top: Ed.Space.l, leading: 20, bottom: 14, trailing: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

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

    /// "0,3", "28": a number as the person reads it.
    static func number(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale.current
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}
