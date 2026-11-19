import AppKit
import RegistaCore
import SwiftUI

/// Inizio's «Per cominciare» (#112): what a downloaded app still lacks, one row each, only while something is pending —
/// the transcription model (the one Base engine the app does not ship) and the connection to Claude. Nothing pending:
/// the block is not in the view tree.
enum FirstSteps {
    /// «Non uso Claude»: the Claude row stays hidden for good (in the workbench's defaults).
    static let noClaudeKey = "home.noClaude"
    /// The manifest entry the model row installs: the job Settings › Motori starts for it.
    static let modelID = "whisper-model"

    /// Neither Claude Desktop nor Claude Code runs a Regista server that is there: this app's own, or another copy that
    /// still exists (a build of the source folder, an older app). Pointing a working connection at this app is Settings ›
    /// Claude's job, not a first step; a connection to a file that is gone counts as none.
    static func claudePending(_ clients: ClaudeClients, bundle: Bundle) -> Bool {
        let bundled = ClaudeClients.bundledMCP(bundle: bundle)
        func connected(_ s: ClaudeClients.State) -> Bool {
            switch ClaudeClients.verdict(s, bundled: bundled) {
            case .here: return true
            case .elsewhere(_, let exists): return exists
            case .notConnected, .unreadable: return false
            }
        }
        return !connected(clients.desktop) && !connected(clients.code)
    }
}

/// How «Collega…» opens a Settings tab: SettingsRoute.open by default (a test records the tab instead: a hosted view has
/// no Settings scene).
private struct SettingsOpenerKey: EnvironmentKey { static let defaultValue: ((SettingsTab) -> Void)? = nil }

/// How the block reads the Claude clients' configuration: ClaudeClients.read by default (a test gives its own state: the
/// test process shares one configuration folder).
private struct ClaudeClientsReaderKey: EnvironmentKey { static let defaultValue: (() -> ClaudeClients)? = nil }

extension EnvironmentValues {
    var settingsOpener: ((SettingsTab) -> Void)? {
        get { self[SettingsOpenerKey.self] }
        set { self[SettingsOpenerKey.self] = newValue }
    }
    var claudeClientsReader: (() -> ClaudeClients)? {
        get { self[ClaudeClientsReaderKey.self] }
        set { self[ClaudeClientsReaderKey.self] = newValue }
    }
}

struct FirstStepsBlock: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.appBundle) private var appBundle
    @Environment(\.openSettings) private var openSettings
    @Environment(\.settingsOpener) private var opener
    @Environment(\.claudeClientsReader) private var reader
    @State private var clients = ClaudeClients.read()
    @State private var noClaude = false
    @State private var installer = EngineInstaller.locate()

    var body: some View {
        ObservingJobs(jobs: store.jobs) { jobs in
            let job = jobs.latest(EnginesModel.jobKind(FirstSteps.modelID))
            let model = store.engineSummary?.modelMissing == true || job?.isRunning == true
            let claude = !noClaude && !store.bench.defaults.bool(forKey: FirstSteps.noClaudeKey)
                && FirstSteps.claudePending(clients, bundle: appBundle)
            if model || claude {
                VStack(alignment: .leading, spacing: Ed.Space.s) {
                    SectionLabel("Per cominciare")
                    VStack(spacing: 0) {
                        if model { modelRow(job) }
                        if model && claude { Ed.line.frame(height: 1) }
                        if claude { claudeRow }
                    }
                    .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(Ed.panel))
                    .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).strokeBorder(Ed.line2, lineWidth: 1))
                }
                .padding(.top, 22)
            }
        }
        .onAppear { clients = readClients() }
        // Back from Settings › Claude (or from Claude Desktop): the connection is read again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in clients = readClients() }
    }

    private func readClients() -> ClaudeClients { reader?() ?? ClaudeClients.read() }

    // MARK: Rows

    private func row<Trailing: View>(_ symbol: String, _ text: String, detail: String? = nil, warning: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Ed.Space.m) {
            RowGlyph(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
                    Text(verbatim: text).font(Ed.ui(Ed.TypeSize.control)).foregroundStyle(Ed.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail { Text(verbatim: detail).font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize() }
                }
                if let warning {
                    Text(verbatim: warning).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Ed.Space.m)
            trailing()
        }
        .padding(.horizontal, Ed.Space.l)
        .padding(.vertical, Ed.Space.s)
        .frame(minHeight: 44)
    }

    /// The transcription model: what it is for, its size, «Scarica» — the install job of Settings › Motori; while it runs,
    /// its progress and «Annulla»; a failure keeps the row with the job's own line.
    private func modelRow(_ job: JobCenter.Job?) -> some View {
        let size = EnginesSettings.localDisk(EngineManifest.shared.diskText(FirstSteps.modelID))
        var failure: String?
        if let job, case .failed(let why) = job.state { failure = String(format: loc("Installazione non riuscita: %@"), why) }
        return row("waveform", loc("Modello per trascrivere e fare i sottotitoli"), detail: size, warning: failure) {
            if let job, job.isRunning {
                HStack(spacing: Ed.Space.s) {
                    JobProgressBar(progress: job.progress, estimated: job.estimated).frame(width: 140)
                    if let p = job.progress {
                        Text(verbatim: JobProgressBar.percent(p, estimated: job.estimated)).font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize()
                    }
                    EdButton(title: "Annulla") { store.jobs.cancel(job.id) }.fixedSize()
                }
            } else {
                EdButton(title: "Scarica", symbol: "arrow.down.circle", disabled: installer == nil) { download() }
                    .fixedSize()
                    .tip(installer == nil ? ReleaseWords.pick("Questa copia di Regista non contiene l'installatore: usa scripts/install.sh", bundle: appBundle) : "")
            }
        }
    }

    /// Claude: «Collega…» opens Settings › Claude, «Non uso Claude» hides the row for good. An app opened outside
    /// Applications (#110) reads as Settings › Claude does there.
    private var claudeRow: some View {
        let outside = ClaudeClients.bundledMCP(bundle: appBundle) != nil && AppLocation.shouldOffer(appBundle.bundleURL)
        let text = outside ? loc("Sposta Regista nella cartella Applicazioni prima di collegare Claude: da dove è aperto ora, il collegamento smetterebbe di funzionare.")
            : loc("Collega Claude per montare parlando")
        return row("sparkles", text) {
            HStack(spacing: Ed.Space.s) {
                EdButton(title: "Non uso Claude", quiet: true) {
                    store.bench.defaults.set(true, forKey: FirstSteps.noClaudeKey)
                    noClaude = true
                }
                .fixedSize()
                EdButton(title: "Collega…") {
                    if let opener { opener(.claude) } else { SettingsRoute.open(.claude, with: openSettings) }
                }
                .fixedSize()
            }
        }
    }

    private func download() {
        guard let installer, let entry = EngineManifest.shared.entry(FirstSteps.modelID) else { return }
        EnginesModel.install(entry.id, name: entry.name, installer: installer, store: store) { [weak store] in store?.refreshEngines() }
    }
}
