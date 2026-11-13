import AppKit
import RegistaCore
import SwiftUI

/// Whether Claude Desktop and Claude Code know Regista's MCP server, read from their own config files (M2 #59).
struct ClaudeClients: Equatable {
    enum State: Equatable {
        /// `mcpServers.regista` runs this command (`exists`: the file is there and executable).
        case connected(command: String, exists: Bool)
        case notConnected
        /// The config file is unreadable: nothing is touched.
        case unreadable(String)
    }

    var desktop: State
    var code: State

    static var desktopConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }
    /// Claude Code's user-scope servers (`claude mcp add --scope user`).
    static var codeConfig: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    static func read(desktop: URL = desktopConfig, code: URL = codeConfig) -> ClaudeClients {
        ClaudeClients(desktop: state(desktop), code: state(code))
    }

    /// `mcpServers.regista.command` of a config file.
    static func state(_ file: URL) -> State {
        guard let data = FileManager.default.contents(atPath: file.path) else { return .notConnected }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable(String(format: loc("%@ non è un file JSON valido"), file.lastPathComponent))
        }
        guard let servers = o["mcpServers"] as? [String: Any], let r = servers["regista"] as? [String: Any],
              let command = r["command"] as? String else { return .notConnected }
        return .connected(command: command, exists: FileManager.default.isExecutableFile(atPath: EngineConfig.expand(command)))
    }

    /// The regista-mcp this app ships (`Contents/MacOS/regista-mcp`, scripts/build-app.sh), nil in a plain `swift build`.
    static func bundledMCP(bundle: Bundle = .main) -> String? {
        let own = bundle.bundleURL.appendingPathComponent("Contents/MacOS/regista-mcp").path
        return FileManager.default.isExecutableFile(atPath: own) ? own : nil
    }

    /// The regista-mcp to connect: the app's own copy when it ships one, else the one a client already runs.
    func mcpBinary(bundle: Bundle = .main) -> String? {
        if let own = Self.bundledMCP(bundle: bundle) { return own }
        for s in [code, desktop] { if case .connected(let c, true) = s { return EngineConfig.expand(c) } }
        return nil
    }

    /// What a client's row says (M3 #60): connected to this app's own server, to another copy (a development build under
    /// .build/, an older app, a file that is gone: offer to repoint it), not connected, or a config Regista does not touch.
    enum Verdict: Equatable {
        case here(String)
        case elsewhere(command: String, exists: Bool)
        case notConnected
        case unreadable(String)
    }

    static func verdict(_ s: State, bundled: String?) -> Verdict {
        switch s {
        case .connected(let c, let exists):
            if let bundled, EngineConfig.expand(c) == bundled { return .here(bundled) }
            if bundled == nil, exists { return .here(EngineConfig.expand(c)) }   // a build without its own server: keep what works
            return .elsewhere(command: c, exists: exists)
        case .notConnected: return .notConnected
        case .unreadable(let why): return .unreadable(why)
        }
    }

    static var desktopInstalled: Bool {
        ["/Applications/Claude.app", "~/Applications/Claude.app"].contains { FileManager.default.fileExists(atPath: EngineConfig.expand($0)) }
    }

    /// The `claude` command line (Claude Code), where its installers put it.
    static func claudeCLI() -> String? {
        ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map(EngineConfig.expand).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The entry "Collega Claude Desktop" writes, shown before it is written.
    static func desktopEntry(_ mcp: String) -> String {
        "\"regista\": {\"command\": \"\(mcp)\", \"args\": []}"  // l10n-ignore
    }
}

/// The start prompt for a Claude Desktop project (handoff/START-PROMPT.md, compiled in): the block after the "---".
enum StartPrompt {
    static var text: String {
        let all = String(decoding: PackageResources.START_PROMPT_md, as: UTF8.self)
        guard let r = all.range(of: "\n---\n") else { return all }
        return all[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ClaudeSettings: View {
    @EnvironmentObject private var store: EditorStore
    @State private var clients = ClaudeClients.read()
    @State private var confirm: Target?
    @State private var copied = false

    enum Target: Identifiable { case desktop, code; var id: Self { self } }

    var body: some View {
        Form {
            Section {
                ObservingBench(bench: store.bench) { bench in
                    LabeledContent("Collegamento") {
                        HStack(spacing: 6) {
                            Circle().fill(bench.agentConnected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                            Text(verbatim: bench.agentConnected ? String(format: loc("%@ è collegato a Regista"), bench.agentName) : loc("Nessun Claude collegato ora"))
                        }
                    }
                    LabeledContent("Build di questa app") { Text(verbatim: Self.appBuild).font(.callout.monospaced()).textSelection(.enabled) }
                    LabeledContent("Server MCP di questa app") {
                        Text(verbatim: ClaudeClients.bundledMCP() ?? loc("Non incluso in questa build: installa l'app con scripts/install.sh"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    if let m = bench.agentBuildMismatch {
                        Label { Text(verbatim: loc(ClaudeStatus.buildNotice(m))).fixedSize(horizontal: false, vertical: true) } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            } header: { Text("Stato") } footer: {
                Text("Claude lavora nell'app aperta tramite il server regista-mcp: quando l'app e il server vengono da build diverse, alcuni comandi non si trovano.")
            }
            Section("Claude Desktop") {
                clientRow(clients.desktop, installed: ClaudeClients.desktopInstalled, target: .desktop)
            }
            Section("Claude Code") {
                clientRow(clients.code, installed: ClaudeClients.claudeCLI() != nil, target: .code)
            }
            Section {
                Text("1. In Claude Desktop crea un progetto «Regista» e incolla queste istruzioni nelle sue istruzioni (in Claude Code basta scriverle nella prima richiesta).")
                    .fixedSize(horizontal: false, vertical: true)
                Text("2. Apri Regista, poi chiedi per esempio: «monta questo video: ~/Movies/Regista/Registrazioni/<file>.mov con il copione <copione>.md». Vedi ogni passo dal vivo nell'app.")
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(verbatim: StartPrompt.text).font(Ed.mono(11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                HStack {
                    Spacer()
                    if copied { Text("Copiate").foregroundStyle(.secondary) }
                    Button("Copia le istruzioni") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(StartPrompt.text, forType: .string)
                        copied = true
                    }
                }
            } header: { Text("Come usarlo") }
        }
        .formStyle(.grouped)
        .onAppear { clients = ClaudeClients.read() }
        .alert(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Collega") { if let t = confirm { connect(t) }; confirm = nil }
            Button("Annulla", role: .cancel) { confirm = nil }
        } message: {
            Text(verbatim: confirmMessage)
        }
    }

    static var appBuild: String {
        (Bundle.main.infoDictionary?["RegistaBuildID"] as? String) ?? BuildStamp.current.id
    }

    @ViewBuilder private func clientRow(_ s: ClaudeClients.State, installed: Bool, target: Target) -> some View {
        switch ClaudeClients.verdict(s, bundled: ClaudeClients.bundledMCP()) {
        case .here(let command):
            LabeledContent(loc("Collegato a questa app")) {
                Text(verbatim: command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
        case .elsewhere(let command, let exists):
            LabeledContent(exists ? loc("Collegato a un'altra copia di Regista") : loc("Collegato a un file che non c'è più")) {
                Text(verbatim: command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if exists {
                Text("Claude usa un server regista-mcp che non è quello di questa app (per esempio una build di sviluppo): i comandi nuovi possono mancare. Ricollegalo a questa app.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            connectButton(target, installed: installed, repoint: true)
        case .notConnected:
            LabeledContent(installed ? loc("Non collegato") : loc("Non installato su questo Mac")) { connectButton(target, installed: installed) }
        case .unreadable(let why):
            Text(verbatim: why + " · " + loc("Correggilo in Claude › Impostazioni › Sviluppatore: Regista non lo tocca.")).foregroundStyle(.orange)
        }
        ObservingJobs(jobs: store.jobs) { jobs in
            if let job = jobs.latest("claude.\(target)") {
                switch job.state {
                case .running: ProgressView().controlSize(.small)
                case .failed(let why): Text(verbatim: loc("Collegamento non riuscito: %@", why)).font(.caption).foregroundStyle(.red)
                case .done: Text(verbatim: target == .desktop ? loc("Fatto: chiudi Claude Desktop (⌘Q) e riaprilo.") : loc("Fatto: apri una nuova sessione di Claude Code.")).font(.caption).foregroundStyle(.secondary)
                case .cancelled: EmptyView()
                }
            }
        }
    }

    private func connectButton(_ t: Target, installed: Bool, repoint: Bool = false) -> some View {
        let mcp = clients.mcpBinary()
        let ready = mcp != nil && (t == .desktop || ClaudeClients.claudeCLI() != nil) && (t == .code || EngineInstaller.locate() != nil)
        let title = repoint ? loc("Ricollega a questa app…") : t == .desktop ? loc("Collega Claude Desktop…") : loc("Collega Claude Code…")
        return Button(title) { confirm = t }
            .disabled(!ready)
            .help(mcp == nil ? loc("Non trovo regista-mcp: esegui scripts/install.sh") : "")
    }

    private var confirmTitle: String {
        confirm == .desktop ? loc("Collegare Claude Desktop a Regista?") : loc("Collegare Claude Code a Regista?")
    }

    private var confirmMessage: String {
        guard let mcp = clients.mcpBinary() else { return "" }
        switch confirm {
        case .desktop:
            return String(format: loc("In %@ aggiungo, tenendo tutto il resto e con una copia di sicurezza prima:"), ClaudeClients.desktopConfig.path)
                + "\n\n" + ClaudeClients.desktopEntry(mcp)
        case .code:
            return loc("Eseguo:") + "\n\nclaude mcp add --scope user regista -- \(mcp)"  // l10n-ignore
        case nil: return ""
        }
    }

    /// The installer's own steps (claude_desktop.py set / claude mcp add), as a job.
    private func connect(_ t: Target) {
        guard let mcp = clients.mcpBinary() else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let steps: [(URL, [String])]
        switch t {
        case .desktop:
            guard let installer = EngineInstaller.locate() else { return }
            let py = installer.script.deletingLastPathComponent().appendingPathComponent("claude_desktop.py").path
            steps = [(URL(fileURLWithPath: "/usr/bin/python3"), ["-I", py, "set", ClaudeClients.desktopConfig.path, mcp])]
        case .code:
            guard let cli = ClaudeClients.claudeCLI() else { return }
            var s: [(URL, [String])] = []
            if case .connected = clients.code { s.append((URL(fileURLWithPath: cli), ["mcp", "remove", "regista", "--scope", "user"])) }
            s.append((URL(fileURLWithPath: cli), ["mcp", "add", "--scope", "user", "regista", "--", mcp]))
            steps = s
        }
        store.jobs.start(kind: "claude.\(t)", title: t == .desktop ? loc("Collego Claude Desktop") : loc("Collego Claude Code"), tab: loc("Claude")) { _ in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                Thread.detachNewThread {
                    cont.resume(with: Result { for (exe, args) in steps { try Subprocess.check(exe, args, currentDirectory: home) } })
                }
            }
            clients = ClaudeClients.read()
        }
    }
}
