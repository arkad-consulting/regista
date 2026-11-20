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
            adoptDownloads(store)
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

    // MARK: ComfyUI model files (#121)

    static func fetchKind(_ file: String) -> String { "fetch.\(file)" }

    /// Why the last «Scarica» of a row was refused (no room, no folder…), in the person's words, by row id.
    @Published var fetchRefusal: [String: String] = [:]

    /// generate.fetch for one file, or for a model's missing files («Scarica tutti»), on the tab's queue like any command;
    /// it answers at once and each download it started is followed as a job of the tab on screen.
    func fetch(_ files: [EngineCatalog.ModelFile], row: EngineCatalog.Row, store: EditorStore) {
        guard let first = files.first else { return }
        let model = ComfyCheck.workflows.first { $0.engine == row.id }?.model
        let params: JSONValue = files.count > 1 && model != nil ? ["model": .string(model!)] : ["file": .string(first.name)]
        fetchRefusal[row.id] = nil
        Task {
            do {
                let r = try await store.perform("generate.fetch", params)
                for j in r["jobs"]?.arrayValue ?? [] {
                    guard let id = j["jobId"]?.stringValue, let name = j["file"]?.stringValue else { continue }
                    follow(id, file: name, store: store)
                }
            } catch {
                fetchRefusal[row.id] = FetchWords.readable(error)
            }
            await reload(store)
        }
    }

    /// A download of this process (ModelDownloads) as a job: its bar and percent from the bytes received, the file's name
    /// on its line, Cancel stops it (the partial file stays for the next «Scarica»), a failure in the person's words.
    func follow(_ id: String, file: String, store: EditorStore) {
        let jobs = store.jobs
        let kind = Self.fetchKind(file)
        guard jobs.latest(kind)?.isRunning != true, let total = ModelDownloads.shared.job(id)?.file.bytes, total > 0 else { return }
        final class Ref: @unchecked Sendable { var id: UUID? }
        let ref = Ref()
        let job = jobs.start(kind: kind, title: String(format: loc("Scarico %@"), file), tab: loc("Motori"),
                             onCancel: { ModelDownloads.shared.cancel(id) }) { [weak self, weak store, weak jobs] _ in
            defer { if let store { Task { await self?.reload(store) } } }
            let end: ModelDownloads.Job? = await withCheckedContinuation { cont in
                Thread.detachNewThread {
                    let j = ModelDownloads.shared.wait(id) { received in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if let uid = ref.id { jobs?.update(uid, progress: Double(received) / Double(total), detail: file) }
                            }
                        }
                    }
                    cont.resume(returning: j)
                }
            }
            switch end?.state {
            case .cancelled: throw CancellationError()
            // The job's line reads the error's description: the sentence itself.
            case .failed: throw CommandError(.io, end?.failure.map(FetchWords.sentence) ?? loc("Download non riuscito: %@", ""))
            default: return
            }
        }
        ref.id = job
    }

    /// Downloads started elsewhere (Claude's generate.fetch in this app) into the ComfyUI folder the status names.
    private func adoptDownloads(_ store: EditorStore) {
        let folder = (status?["engines"]?.arrayValue ?? []).first { $0["id"] == "comfyui" }?["path"]?.stringValue
        guard let folder else { return }
        for d in ModelDownloads.shared.all where d.state == .running && d.target.path.hasPrefix(folder + "/") {
            follow(d.id, file: d.file.name, store: store)
        }
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
                                                      cancel: { if let j = jobs.latest(EnginesModel.jobKind(r.id)) { jobs.cancel(j.id) } },
                                                      fetchJobs: demo == nil ? Dictionary(r.files.compactMap { f in jobs.latest(EnginesModel.fetchKind(f.name)).map { (f.name, $0) } },
                                                                                          uniquingKeysWith: { a, _ in a }) : [:],
                                                      fetchRefusal: model.fetchRefusal[r.id],
                                                      fetch: { files in model.fetch(files, row: r, store: store) },
                                                      cancelFetch: { name in if let j = jobs.latest(EnginesModel.fetchKind(name)) { jobs.cancel(j.id) } })
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
                    Text(loc("Controllo dei motori…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if demo == nil { await model.reload(store) } }
        .onDisappear { focus = "" }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button(loc("Rimuovi"), role: .destructive) {
                if let r = confirmRemove { model.remove(r.id, store: store) }
                confirmRemove = nil
            }
        } message: {
            Text(verbatim: confirmMessage)
        }
        .confirmationDialog(licenceTitle, isPresented: Binding(get: { confirmLicence != nil }, set: { if !$0 { confirmLicence = nil } })) {
            Button(loc("Accetto la licenza e installo")) {
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
            LabeledContent(loc("Memoria")) { Text(verbatim: String(format: loc("%d GB di RAM"), c.memoryGB)) }
            LabeledContent(loc("Livello")) {
                HStack(spacing: 6) {
                    Text(verbatim: Self.tierName(c.tier)).fontWeight(.medium)
                    if let d = c.detected, d != c.tier {
                        Text(verbatim: String(format: loc("forzato (dalla RAM: %@)"), Self.tierName(d))).foregroundStyle(.orange)
                    }
                }
            }
            LabeledContent(loc("Spazio libero")) { Text(verbatim: Self.freeDisk()) }
            Picker(loc("Forza livello"), selection: Binding(get: { shownTier.map(\.rawValue) ?? "" }, set: { v in model.setForcedTier(MachineTier(rawValue: v)) })) {
                Text(loc("Automatico")).tag("")
                ForEach(MachineTier.allCases, id: \.self) { t in Text(verbatim: Self.tierName(t)).tag(t.rawValue) }
            }
            .disabled(demo != nil)
        } header: { Text(loc("Questo Mac")) } footer: {
            Text(loc("Automatico sceglie il livello dalla RAM. Un livello più alto mostra e installa motori che possono rallentare il Mac o fermarsi per mancanza di memoria; uno più basso li nasconde. Vale per questa schermata subito, per il resto dell'app alla prossima apertura di Regista."))
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
        case .base: Text(loc("Base · da 8 GB"))
        case .medium: Text(loc("Medio · da 16 GB"))
        case .pro: Text(loc("Pro · da 32 GB"))
        case .cloud: Text(loc("Nel cloud"))
        case .planned: Text(loc("In arrivo"))
        }
    }

    @ViewBuilder private func groupFooter(_ g: EngineCatalog.Group) -> some View {
        switch g {
        case .base: Text(loc("Registrare, tagliare, sottotitoli, pulire la voce, grafica ed export."))
        case .medium: Text(loc("In più: voce clonata da un riferimento (circa 8 GB mentre lavora), titoli 3D, grafica HTML, tempi delle parole più precisi."))
        case .pro: Text(loc("In più: allenamento della voce (circa 2 ore), immagini, clip e musica generate in locale."))
        case .cloud: Text(loc("Generazione a pagamento: il costo è mostrato e approvato ogni volta."))
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
    /// The download job of each of its model files (#121), by file name.
    var fetchJobs: [String: JobCenter.Job] = [:]
    var fetchRefusal: String? = nil
    var fetch: (_ files: [EngineCatalog.ModelFile]) -> Void = { _ in }
    var cancelFetch: (_ file: String) -> Void = { _ in }
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
                    Button(loc("Annulla"), action: cancel).controlSize(.small)
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
                Text(loc("I file di supporto di questo motore sono più vecchi di quelli dell'app: rimuovilo e installalo di nuovo."))
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
                    Button(loc("Installa"), action: install).disabled(busy || !canInstall)
                        .help(canInstall ? "" : loc(ReleaseWords.pick("Questa copia di Regista non contiene l'installatore: usa scripts/install.sh", bundle: appBundle)))
                case .remove:
                    Button(loc("Rimuovi…"), action: remove).disabled(busy || removing)
                case .howTo:
                    Button(row.method == "cloud" ? loc("Come attivarlo") : loc("Come installarlo")) { expanded.toggle() }
                case .firstUse:
                    Button(loc("Come arriva")) { expanded.toggle() }
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
                Button(loc("Controlla di nuovo"), action: checkAgain).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    /// A ComfyUI model's files: name, folder, size, licence, the publisher's page, whether ComfyUI sees it, and its
    /// download (#121): «Scarica» with its size on a missing file with a direct URL, «Scarica tutti» above several, and
    /// while a file downloads its bar, percent and «Annulla» in the same place.
    private var filesList: some View {
        let ready = row.files.filter(canFetch)
        return VStack(alignment: .leading, spacing: 8) {
            if row.files.contains(where: { $0.download == "noFolder" && $0.present != true }) {
                Text(loc("Regista non sa in quale cartella è ComfyUI (lo avvia un programma, o ne conosce solo l'indirizzo): imposta la «Cartella di ComfyUI» nella riga di ComfyUI per scaricare i file da qui."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if ready.count > 1 {
                EdButton(title: String(format: loc("Scarica tutti (%d file, %@)"), ready.count,
                                       EnginesSettings.localDisk(EngineManifest.sizeText(ready.reduce(Int64(0)) { $0 + $1.bytes }))),
                         symbol: "arrow.down.circle") { fetch(ready) }
                    .fixedSize()
            }
            if let fetchRefusal {
                Text(verbatim: fetchRefusal).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(row.files, id: \.name) { f in fileRow(f) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func fileRow(_ f: EngineCatalog.ModelFile) -> some View {
        let job = fetchJobs[f.name]
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(verbatim: f.name).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                if let present = f.present {
                    Text(verbatim: present ? loc("c'è") : loc("manca")).font(.caption.weight(.medium)).foregroundStyle(present ? .green : .orange)
                }
                Spacer(minLength: 8)
                if let job, job.isRunning {
                    JobProgressBar(progress: job.progress).frame(width: 110)
                    Text(verbatim: JobProgressBar.percent(job.progress ?? 0, estimated: false)).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).fixedSize()
                    EdButton(title: "Annulla") { cancelFetch(f.name) }.fixedSize()
                } else if canFetch(f) {
                    Text(verbatim: EnginesSettings.localDisk(f.size)).font(.caption).foregroundStyle(.secondary).fixedSize()
                    EdButton(title: "Scarica", symbol: "arrow.down.circle") { fetch([f]) }.fixedSize()
                }
            }
            Text(verbatim: "\(f.folder) · \(EnginesSettings.localDisk(f.size)) · \(loc(f.licence))").font(.caption).foregroundStyle(.secondary)
            Text(verbatim: f.url).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            if let line = fetchLine(f, job) {
                Text(verbatim: line.text).font(.caption).foregroundStyle(line.color).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A missing file Regista can download now: a direct URL, the ComfyUI folder known, not there, not downloading.
    private func canFetch(_ f: EngineCatalog.ModelFile) -> Bool {
        f.download == "ready" && f.present != true && fetchJobs[f.name]?.isRunning != true
    }

    /// What the file's download says under it: a failure, a cancel, done, or why there is no «Scarica».
    private func fetchLine(_ f: EngineCatalog.ModelFile, _ job: JobCenter.Job?) -> (text: String, color: Color)? {
        if let job, case .failed(let why) = job.state, f.download == "ready" { return (why, .red) }
        if job?.state == .cancelled, f.download == "ready" { return (loc("Download annullato: «Scarica» riprende da dove si è fermato."), .secondary) }
        guard f.present != true else { return nil }
        switch f.download {
        case "there": return (loc("Scaricato: riavvia ComfyUI perché lo veda."), .green)
        case "otherSize":
            return (loc("C'è già un file con questo nome ma di un'altra dimensione: Regista non lo sovrascrive. Spostalo altrove per scaricarlo di nuovo."), .orange)
        case "manual":
            return (loc("Il suo autore chiede un accesso o di accettare la licenza sulla sua pagina: scaricalo da lì e mettilo nella cartella indicata."), .secondary)
        default: return nil
        }
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

/// A download's refusal or failure in the person's words (#121): the engine's sentences are English.
enum FetchWords {
    static func sentence(_ f: FetchFailure) -> String {
        switch f.kind {
        case .checksum:
            return loc("Il file scaricato non corrisponde al suo checksum e l'ho cancellato: scaricalo di nuovo. Se succede ancora, il file sulla pagina dell'autore è cambiato.")
        case .space(let missing):
            return loc("Non c'è abbastanza spazio sul disco di ComfyUI: libera altri %@, poi scarica di nuovo.", EnginesSettings.localDisk(EngineManifest.sizeText(missing)))
        case .lost(let received, let total):
            return loc("La connessione si è interrotta dopo %@ di %@: «Scarica» riprende da lì.",
                       EnginesSettings.localDisk(EngineManifest.sizeText(received)), EnginesSettings.localDisk(EngineManifest.sizeText(total)))
        case .otherSize:
            return loc("C'è già un file con questo nome ma di un'altra dimensione: Regista non lo sovrascrive. Spostalo altrove per scaricarlo di nuovo.")
        case .noFolder:
            return loc("Regista non sa in quale cartella è ComfyUI (lo avvia un programma, o ne conosce solo l'indirizzo): imposta la «Cartella di ComfyUI» nella riga di ComfyUI per scaricare i file da qui.")
        case .http(let code):
            return loc("Il server ha risposto %d: riprova più tardi.", code)
        case .manual, .cancelled, .io:
            return loc("Download non riuscito: %@", f.message)
        }
    }

    /// generate.fetch's refusal (a CommandError carrying the engine's sentence), else a failure.
    static func readable(_ error: Error) -> String {
        if let f = error as? FetchFailure { return sentence(f) }
        let raw = JobCenter.message(error)
        // The engine's words, matched (English, not UI).
        if raw.contains("not enough free space"), let r = raw.range(of: #"free [0-9.]+ [GM]B more"#, options: .regularExpression) {  // l10n-ignore
            let amount = String(raw[r].dropFirst(5).dropLast(5))
            return loc("Non c'è abbastanza spazio sul disco di ComfyUI: libera altri %@, poi scarica di nuovo.", EnginesSettings.localDisk(amount))
        }
        if raw.contains("Settings › Motori › ComfyUI to download") { return sentence(FetchFailure(.noFolder, raw)) }  // l10n-ignore
        if raw.contains("does not overwrite it") { return sentence(FetchFailure(.otherSize, raw)) }  // l10n-ignore
        return loc("Download non riuscito: %@", raw)
    }
}
