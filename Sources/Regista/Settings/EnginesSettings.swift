import AppKit
import RegistaCore
import SwiftUI

/// What a render of the Motori tab shows instead of the live state (ui.screenshot `settings-engines[-tier]`): an
/// engines.status result taken for the render and the tier to draw it as. Never written anywhere.
struct EnginesDemo {
    var status: JSONValue
    var tier: MachineTier?
    /// A row drawn open (its detail: the ComfyUI setup, a model's files).
    var open: String? = nil
}

/// The Motori tab's live state: engines.status (the same data Claude reads), the tier forced in engines.json, the
/// free disk. Installs and removals run here as jobs of the tab on screen.
@MainActor
final class EnginesModel: ObservableObject {
    @Published private(set) var status: JSONValue?
    @Published private(set) var forcedTier: MachineTier?
    @Published var error: String?
    /// The removal in progress (files are being deleted).
    @Published private(set) var removing: String?

    let installer = EngineInstaller.locate()

    func reload(_ store: EditorStore) async {
        forcedTier = Self.readForcedTier()
        if let r = try? await store.silent("engines.status") {
            status = r
            if let s = EngineSummary(status: r) { store.bench.engineSummary = s }
        }
    }

    // MARK: Tier

    nonisolated static func readForcedTier(_ file: URL = EngineConfig.defaultFile) -> MachineTier? {
        guard let data = FileManager.default.contents(atPath: file.path),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (o["tier"] as? String).flatMap(MachineTier.init)
    }

    /// Writes `tier` in engines.json (nil removes it: detect from the RAM), keeping every other key.
    nonisolated static func writeForcedTier(_ tier: MachineTier?, to file: URL = EngineConfig.defaultFile) throws {
        try writeSetting("tier", tier?.rawValue, to: file)
    }

    /// Writes one key of engines.json (nil removes it), keeping every other key: the tier, ComfyUI's address and folder (#6).
    nonisolated static func writeSetting(_ key: String, _ value: String?, to file: URL = EngineConfig.defaultFile) throws {
        var o: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: file.path) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RegistaError(String(format: loc("%@ non è un file JSON valido: non l'ho toccato."), file.path))
            }
            o = parsed
        }
        if let value { o[key] = value } else { o.removeValue(forKey: key) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (out + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    /// ComfyUI's address (`comfyServer`) or folder (`comfyStart`) from its row (#6), then the row says what it finds.
    func setComfy(_ key: String, _ value: String?, store: EditorStore) {
        do {
            try Self.writeSetting(key, value)
            error = nil
        } catch {
            self.error = loc("Non ho potuto salvare la scelta: %@", error.localizedDescription)
        }
        Task { await reload(store) }
    }

    func setForcedTier(_ tier: MachineTier?) {
        do {
            try Self.writeForcedTier(tier)
            forcedTier = tier
            error = nil
        } catch {
            self.error = loc("Non ho potuto salvare la scelta: %@", error.localizedDescription)
        }
    }

    // MARK: Install / remove

    static func jobKind(_ id: String) -> String { "engine.\(id)" }

    /// `scripts/install.sh --only <id>` as a job of the tab on screen: progress from its downloads, Cancel stops it and
    /// what it started. A failed install leaves what was there.
    func install(_ row: EngineCatalog.Row, store: EditorStore) {
        guard let installer else { return }
        Self.install(row.id, name: row.name, installer: installer, store: store) { [weak self, weak store] in
            if let store { Task { await self?.reload(store) } }
        }
    }

    /// The install job itself, also started by Inizio's «Per cominciare» for the transcription model (#112): the same
    /// kind, title, progress and failure line wherever it starts. `finished` runs after it ends, whatever the outcome.
    static func install(_ id: String, name: String, installer: EngineInstaller, store: EditorStore, finished: @escaping @MainActor () -> Void) {
        final class Ref: @unchecked Sendable { var id: UUID? }
        let ref = Ref()
        let jobs = store.jobs
        let command = CommandJob { [weak jobs] fraction, detail in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let id = ref.id else { return }
                    if fraction == nil, detail == nil { jobs?.progressUnknown(id) } else { jobs?.update(id, progress: fraction, detail: detail) }
                }
            }
        }
        let job = jobs.start(kind: Self.jobKind(id), title: String(format: loc("Installo %@"), loc(name)), tab: loc("Motori"),
                             onCancel: { command.cancel() }) { _ in
            defer { finished() }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                Thread.detachNewThread {
                    let r = Result { try CommandJob.$current.withValue(command) { try installer.install(id) } }
                    cont.resume(with: r)
                }
            }
            if command.isCancelled { throw CancellationError() }
        }
        ref.id = job
    }

    /// Deletes the engine's files in Regista's engines folder (the confirmation was shown by the view).
    func remove(_ id: String, store: EditorStore) {
        removing = id
        Task {
            let result = await Task.detached { Result { try EngineCatalog.remove(id) } }.value
            if case .failure(let e) = result { error = loc("Non ho potuto rimuovere il motore: %@", e.localizedDescription) } else { error = nil }
            removing = nil
            await reload(store)
        }
    }
}

struct EnginesSettings: View {
    @EnvironmentObject private var store: EditorStore
    var demo: EnginesDemo?
    @StateObject private var model = EnginesModel()
    @AppStorage(SettingsRoute.engineKey) private var focus = ""
    @State private var confirmRemove: EngineCatalog.Row?
    /// A non-commercial engine (the Italian / French aligners, #20): its licence is shown and accepted before the install.
    @State private var confirmLicence: EngineCatalog.Row?

    private var status: JSONValue? { demo?.status ?? model.status }
    private var shownTier: MachineTier? { demo == nil ? model.forcedTier : demo?.tier }

    var body: some View {
        Group {
            if let status {
                let catalog = EngineCatalog(status: status, tier: demo == nil ? model.forcedTier : demo?.tier)
                ScrollViewReader { proxy in
                    Form {
                        mac(catalog)
                        ForEach(EngineCatalog.Group.allCases, id: \.self) { g in
                            let rows = catalog.rows(g)
                            if !rows.isEmpty {
                                Section {
                                    ForEach(rows) { r in
                                        ObservingJobs(jobs: store.jobs) { jobs in
                                        EngineRowView(row: r, highlighted: demo == nil && focus == r.id, open: demo?.open == r.id,
                                                      job: demo == nil ? jobs.latest(EnginesModel.jobKind(r.id)) : nil,
                                                      canInstall: model.installer != nil || demo != nil, removing: model.removing == r.id,
                                                      install: { if r.nonCommercial { confirmLicence = r } else { model.install(r, store: store) } }, remove: { confirmRemove = r },
                                                      checkAgain: { Task { await model.reload(store) } },
                                                      setComfy: { key, value in model.setComfy(key, value, store: store) },
                                                      cancel: { if let j = jobs.latest(EnginesModel.jobKind(r.id)) { jobs.cancel(j.id) } })
                                        }
                                        .id(r.id)
                                    }
                                } header: { groupHeader(g) } footer: { groupFooter(g) }
                            }
                        }
                        if let e = model.error { Text(verbatim: e).foregroundStyle(.red) }
                    }
                    .formStyle(.grouped)
                    .onAppear { if !focus.isEmpty { proxy.scrollTo(focus, anchor: .center) } }
                    .onChange(of: focus) { _, id in if !id.isEmpty { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Controllo dei motori…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if demo == nil { await model.reload(store) } }
        .onDisappear { focus = "" }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Rimuovi", role: .destructive) {
                if let r = confirmRemove { model.remove(r.id, store: store) }
                confirmRemove = nil
            }
        } message: {
            Text(verbatim: confirmMessage)
        }
        .confirmationDialog(licenceTitle, isPresented: Binding(get: { confirmLicence != nil }, set: { if !$0 { confirmLicence = nil } })) {
            Button("Accetto la licenza e installo") {
                if let r = confirmLicence { model.install(r, store: store) }
                confirmLicence = nil
            }
        } message: {
            Text(verbatim: licenceMessage)
        }
    }

    private var licenceTitle: String { String(format: loc("Licenza di %@"), loc(confirmLicence?.name ?? "")) }

    static func licenceMessage(_ r: EngineCatalog.Row) -> String {
        let url = EngineManifest.shared.entry(r.id)?.licenceUrl.map { " (\($0))" } ?? ""
        return String(format: loc("%@%@: solo uso non commerciale. Il lavoro per i clienti è uso commerciale. Senza questo motore Regista trascrive la lingua con whisper.cpp, libero per ogni uso. Installandolo accetti la licenza."), r.licence, url)
    }

    private var licenceMessage: String { confirmLicence.map(Self.licenceMessage) ?? "" }

    // MARK: This Mac

    private func mac(_ c: EngineCatalog) -> some View {
        Section {
            LabeledContent("Memoria") { Text(verbatim: String(format: loc("%d GB di RAM"), c.memoryGB)) }
            LabeledContent("Livello") {
                HStack(spacing: 6) {
                    Text(verbatim: Self.tierName(c.tier)).fontWeight(.medium)
                    if let d = c.detected, d != c.tier {
                        Text(verbatim: String(format: loc("forzato (dalla RAM: %@)"), Self.tierName(d))).foregroundStyle(.orange)
                    }
                }
            }
            LabeledContent("Spazio libero") { Text(verbatim: Self.freeDisk()) }
            Picker("Forza livello", selection: Binding(get: { shownTier.map(\.rawValue) ?? "" }, set: { v in model.setForcedTier(MachineTier(rawValue: v)) })) {
                Text("Automatico").tag("")
                ForEach(MachineTier.allCases, id: \.self) { t in Text(verbatim: Self.tierName(t)).tag(t.rawValue) }
            }
            .disabled(demo != nil)
        } header: { Text("Questo Mac") } footer: {
            Text("Automatico sceglie il livello dalla RAM. Un livello più alto mostra e installa motori che possono rallentare il Mac o fermarsi per mancanza di memoria; uno più basso li nasconde. Vale per questa schermata subito, per il resto dell'app alla prossima apertura di Regista.")
        }
    }

    /// The manifest's "0.21 GB" / "81 MB" in the user's numbers and units ("0,21 Go" in French).
    static func localDisk(_ text: String) -> String {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]), ["GB", "MB"].contains(String(parts[1])) else { return text }
        let digits = parts[0].split(separator: ".").dropFirst().first?.count ?? 0
        let number = value.formatted(.number.precision(.fractionLength(digits)))
        return parts[1] == "GB" ? loc("%@ GB", number) : loc("%@ MB", number)
    }

    static func tierName(_ t: MachineTier) -> String {
        switch t {
        case .base: loc("Base")
        case .medium: loc("Medio")
        case .pro: loc("Pro")
        }
    }

    static func freeDisk() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return "?" }
        return String(format: loc("%d GB"), Int(Double(v) / 1e9))
    }

    private func groupHeader(_ g: EngineCatalog.Group) -> some View {
        switch g {
        case .base: Text("Base · da 8 GB")
        case .medium: Text("Medio · da 16 GB")
        case .pro: Text("Pro · da 32 GB")
        case .cloud: Text("Nel cloud")
        case .planned: Text("In arrivo")
        }
    }

    @ViewBuilder private func groupFooter(_ g: EngineCatalog.Group) -> some View {
        switch g {
        case .base: Text("Registrare, tagliare, sottotitoli, pulire la voce, grafica ed export.")
        case .medium: Text("In più: voce clonata da un riferimento (circa 8 GB mentre lavora), titoli 3D, grafica HTML, tempi delle parole più precisi.")
        case .pro: Text("In più: allenamento della voce (circa 2 ore), immagini, clip e musica generate in locale.")
        case .cloud: Text("Generazione a pagamento: il costo è mostrato e approvato ogni volta.")
        case .planned: EmptyView()
        }
    }

    private var confirmTitle: String {
        String(format: loc("Rimuovere %@?"), confirmRemove?.name ?? "")
    }

    private var confirmMessage: String {
        guard let r = confirmRemove else { return "" }
        let stops = EngineCatalog.stopsWorking(r.id)
        let names = EngineCatalog.dependents(of: r.id).map { loc($0.name) }
        var text = String(format: loc("Smette di funzionare: %@."), stops.map { loc($0) }.joined(separator: ", "))
        if !names.isEmpty { text += " " + String(format: loc("Lo usano anche: %@."), names.joined(separator: ", ")) }
        return text + " " + loc("I file del motore vanno via dalla cartella dei motori di Regista; si può reinstallare da qui.")
    }
}

/// One engine: state, what it unlocks, disk, licence, and its action. The manifest's `unlocks` phrases and install steps
/// are English (scripts/engines.manifest.json, also the docs' source): they are lookup keys, translated here (#84).
private struct EngineRowView: View {
    let row: EngineCatalog.Row
    let highlighted: Bool
    /// Drawn open (a render of the row's detail).
    var open = false
    let job: JobCenter.Job?
    let canInstall: Bool
    let removing: Bool
    let install: () -> Void
    let remove: () -> Void
    let checkAgain: () -> Void
    /// Writes ComfyUI's address or folder in engines.json (#6).
    let setComfy: (_ key: String, _ value: String?) -> Void
    let cancel: () -> Void
    /// This app: a release build names no script of the source folder (#113).
    @Environment(\.appBundle) private var appBundle
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(dot).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: loc(row.name)).fontWeight(.medium)
                        if row.nonCommercial { Badge(text: loc("non commerciale"), color: .orange) }
                        if row.paid { Badge(text: loc("a pagamento"), color: .orange) }
                        if row.optional { Badge(text: loc("facoltativo"), color: .secondary) }
                    }
                    (Text(verbatim: row.unlocks.map { loc($0) }.joined(separator: " · ")).foregroundStyle(.secondary)
                        + Text(verbatim: "   " + facts).font(.caption).foregroundStyle(.tertiary))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                trailing
            }
            if let job, job.isRunning {
                HStack(spacing: 8) {
                    if let p = job.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                    Button("Annulla", action: cancel).controlSize(.small)
                }
                if !job.detail.isEmpty { Text(verbatim: job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            } else if let job, case .failed(let why) = job.state {
                Text(verbatim: String(format: loc("Installazione non riuscita: %@"), why)).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expanded || open {
                if let setup = row.comfy { ComfySetupView(setup: setup, save: setComfy) }
                if let steps { howTo(steps) }
                if !row.files.isEmpty { filesList }
            }
            // Its helper scripts differ from the app's and could not be replaced (#61): normally they are, at launch.
            if row.state == .installed, !row.scriptsCurrent {
                Text("I file di supporto di questo motore sono più vecchi di quelli dell'app: rimuovilo e installalo di nuovo.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .listRowBackground(highlighted ? Color.accentColor.opacity(0.12) : nil)
    }

    private var dot: Color {
        switch row.state {
        case .installed: .green
        case .missing: .secondary.opacity(0.5)
        case .needsTier: .orange
        case .notChecked, .planned: .secondary.opacity(0.25)
        }
    }

    private var facts: String {
        let disk = row.disk == "–" ? loc("niente da scaricare") : row.disk == "?" ? loc("spazio variabile") : EnginesSettings.localDisk(row.disk)
        return "\(disk) · \(loc(row.licence))"
    }

    private var steps: [String]? {
        switch row.action {
        case .howTo(let s), .firstUse(let s): s
        default: nil
        }
    }

    @ViewBuilder private var trailing: some View {
        let busy = job?.isRunning == true
        switch row.state {
        case .needsTier(let t):
            StateText(text: String(format: loc("Serve il livello %@"), EnginesSettings.tierName(t)), color: .orange)
        case .planned:
            StateText(text: loc("In arrivo"), color: .secondary)
        default:
            HStack(spacing: 8) {
                StateText(text: stateText, color: row.state == .installed ? .green : .secondary)
                // ComfyUI's setup stays reachable once it works: its address and folder (#6).
                if row.comfy != nil, case .nothing = row.action { Button(loc("Imposta")) { expanded.toggle() } }
                switch row.action {
                case .install:
                    Button("Installa", action: install).disabled(busy || !canInstall)
                        .help(canInstall ? "" : loc(ReleaseWords.pick("Questa copia di Regista non contiene l'installatore: usa scripts/install.sh", bundle: appBundle)))
                case .remove:
                    Button("Rimuovi…", action: remove).disabled(busy || removing)
                case .howTo:
                    Button(row.method == "cloud" ? loc("Come attivarlo") : loc("Come installarlo")) { expanded.toggle() }
                case .firstUse:
                    Button("Come arriva") { expanded.toggle() }
                case .nothing:
                    EmptyView()
                }
            }
        }
    }

    private var stateText: String {
        if removing { return loc("Rimuovo…") }
        if job?.isRunning == true { return loc("Installo…") }
        switch row.state {
        case .installed:
            if row.shipped { return loc("Incluso nell'app") }
            if row.notNeeded { return loc("Non serve con questa app") }
            return row.method == "system" ? loc("Incluso in macOS") : loc("Installato")
        case .missing: return loc("Non installato")
        case .notChecked: return loc("Non controllato")
        case .planned: return loc("In arrivo")
        case .needsTier: return ""
        }
    }

    private func howTo(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: intro).font(.callout).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "\(i + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(verbatim: loc(ReleaseWords.pick(s, bundle: appBundle))).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .howTo = row.action {
                Button("Controlla di nuovo", action: checkAgain).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    /// A ComfyUI model's files: name, folder, size, licence, the publisher's page, and whether ComfyUI sees it.
    private var filesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(row.files, id: \.name) { f in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: f.name).font(.callout.monospaced()).textSelection(.enabled)
                        if let present = f.present {
                            Text(verbatim: present ? loc("c'è") : loc("manca")).font(.caption.weight(.medium)).foregroundStyle(present ? .green : .orange)
                        }
                    }
                    Text(verbatim: "\(f.folder) · \(EnginesSettings.localDisk(f.size)) · \(loc(f.licence))").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: f.url).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var intro: String {
        switch row.id {
        case "higgsfield":
            loc("Genera immagini e clip nel cloud, a pagamento: prima di ogni generazione Regista mostra il costo e aspetta la tua approvazione, entro un budget massimo. Serve un account Higgsfield e il suo programma da riga di comando, collegato con il tuo login.")
        case "comfyui", "comfyui-z-image", "comfyui-wan22", "comfyui-ace-step", "comfyui-upscale":
            loc("ComfyUI genera immagini, clip e musica sul tuo Mac, gratis, ma si prepara a mano (circa 70 GB con i modelli). I passi:")
        default:
            row.method == "firstUse" ? loc("Si scarica da solo la prima volta che serve:") : loc("Si prepara a mano:")
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(verbatim: text).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 0.5))
    }
}

private struct StateText: View {
    let text: String
    let color: Color
    var body: some View { Text(verbatim: text).font(.callout).foregroundStyle(color).lineLimit(1).fixedSize() }
}

/// ComfyUI's row detail (#6): its address and its folder, a one-off setup, with what Regista finds in words.
private struct ComfySetupView: View {
    let setup: EngineCatalog.ComfySetup
    let save: (_ key: String, _ value: String?) -> Void
    @State private var address: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: loc("Indirizzo")).frame(width: 150, alignment: .leading)
                TextField(loc("Indirizzo"), text: Binding(get: { address ?? setup.server }, set: { address = $0 }), prompt: Text(verbatim: ComfyServer.defaultAddress))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    .onSubmit(commit)
                Button(loc("Salva"), action: commit).controlSize(.small).disabled((address ?? setup.server) == setup.server)
            }
            Text(verbatim: serverWords).font(.caption).foregroundStyle(setup.running ? .green : .secondary).padding(.leading, 158)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: loc("Cartella di ComfyUI")).frame(width: 150, alignment: .leading)
                Text(verbatim: setup.start.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? loc("Non impostata"))
                    .font(.callout).foregroundStyle(setup.start == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button(loc("Scegli…"), action: choose).controlSize(.small)
                if setup.configured { Button(loc("Togli")) { save("comfyStart", nil) }.controlSize(.small) }
            }
            Text(verbatim: folderWords).font(.caption).foregroundStyle(setup.problem != nil ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 158)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var serverWords: String {
        guard setup.running else { return loc("Spento: non risponde nessuno a questo indirizzo") }
        return setup.startedByRegista ? loc("Risponde · avviato da Regista") : loc("Risponde")
    }

    private var folderWords: String {
        if setup.problem != nil { return loc("Questa cartella non avvia ComfyUI: serve una cartella di ComfyUI con il suo ambiente Python (.venv o venv), o un programma che lo avvia.") }
        guard setup.start != nil else { return loc("Non trovata: scegli la cartella dove hai installato ComfyUI, oppure avvialo da te e scrivi il suo indirizzo.") }
        return setup.configured ? loc("Regista avvia ComfyUI quando una generazione ne ha bisogno e lo ferma dopo.")
            : loc("Trovata in un posto consueto: Regista avvia ComfyUI da qui quando serve. Sceglila per fissarla.")
    }

    private func commit() {
        let value = (address ?? setup.server).trimmingCharacters(in: .whitespaces)
        address = nil
        save("comfyServer", value.isEmpty || value == ComfyServer.defaultAddress ? nil : value)
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        p.message = loc("La cartella di ComfyUI, o un programma che avvia ComfyUI")
        guard p.runModal() == .OK, let url = p.url else { return }
        save("comfyStart", url.path)
    }
}
