import AppKit
import Combine
import Foundation
import RegistaCore
import RegistaMCP

/// The open projects, one tab each (S2 #76), and everything the tabs share. Each tab is an `EditorStore`: its own
/// engine and queue (project, undo, dirty state), jobs, preview player, caches, selection and playhead. Shared here:
/// the window's navigation and right-panel tab, the recent projects, the engine summary, the activity log, the agents
/// connected through the engine socket (one server for the app), the paid-generation approval, the brand-kit and voice
/// sheets, and which tab the recorder (one camera / microphone / screen at a time) belongs to.
///
/// The agent's commands act on the active tab unless they name another one (`project`: a tab id or the project path);
/// a command routed to another tab runs there without changing what the user looks at. `project.new` / `project.open`
/// from the agent fill the active tab when it is empty, otherwise open a new tab, and select it — the activity log says
/// so. The open tabs (their project paths) and the selected one come back at the next launch.
@MainActor
final class Workbench: ObservableObject {
    @Published private(set) var tabs: [EditorStore] = []
    @Published private(set) var activeID = ""

    /// Activity, editor level and the right panel's tab (`Navigation`); the activity, the level and the tab
    /// are remembered across launches.
    @Published var nav: Navigation {
        didSet {
            guard nav != oldValue else { return }
            defaults.set(nav.activity.rawValue, forKey: Navigation.activityKey)
            defaults.set(nav.level.rawValue, forKey: Navigation.levelKey)
            defaults.set(nav.rightTab.rawValue, forKey: Navigation.rightTabKey)
        }
    }
    /// Projects opened or saved last (File › Apri recente, Inizio).
    let recents: RecentProjects
    /// RAM, tier and engines ready, for Inizio (engines.status, read at launch and when Inizio appears).
    @Published var engineSummary: EngineSummary?
    /// Every command run in any tab, and the notes about tabs (the right panel's Claude tab).
    @Published var activity: [EditorStore.Activity] = []
    /// Connected MCP clients (names from their initialize).
    @Published private(set) var agents: [String] = []
    /// Set when the last connected regista-mcp reported a build different from this app's (shown on the agent pill).
    @Published private(set) var agentBuildMismatch: BuildStamp.Mismatch?
    @Published var socketProblem: String?
    /// A paid generation estimate waiting for the user's decision (the confirmation sheet).
    @Published var pendingApproval: GenerationApprovals.Entry?
    /// Paid estimates the Generate panel asked for: approved on its own card, never in the window's sheet.
    var panelEstimates: Set<String> = []
    /// The panel is asking for a paid estimate now: the sheet waits, so it never flashes up for the panel's own request.
    var panelPricing = 0
    /// The brand kit gallery sheet (issue #17) and the voice recording flow.
    @Published var showBrandKits = false
    @Published var showVoiceSetup = false
    /// The tab the running recording belongs to (nil when nothing records).
    @Published private(set) var recordingTabID: String?
    /// Pinged when a job of any tab changes: the status bar's jobs list follows it (E2 #54).
    let jobsHub = JobsHub()
    /// The tab the last recording belonged to, until its file is imported.
    private var finishedRecordingTabID: String?
    /// Where the running recording goes and where the last one goes, as Registra showed it when it started (#39).
    private var startedDestination: RecordingDestination?
    private var finishedDestination: RecordingDestination?
    /// The one-line notice over the main area: where the last recording went, with its file (#39).
    @Published var notice: Notice?

    let defaults: UserDefaults
    /// The main window (set by the live EditorRoot); every tab's UI host renders and captures it.
    weak var window: NSWindow? { didSet { for t in tabs { t.ui.window = window } } }
    /// The app's recorder (closing the tab that records stops it).
    weak var recorder: Recorder?
    /// Called for each new tab before it is used (AppState wires the app's environment into its UI host).
    var onNewTab: ((EditorStore) -> Void)?
    private var server: EngineSocketServer?
    private var nextNumber = 1
    /// Builds the services of every tab's engines, including tabs opened later by a click or by the agent (#35): the
    /// app's are `liveServices`; a test gives services that cannot reach outside the test.
    let makeServices: @MainActor () -> EngineServices

    static let tabsKey = "workbench.tabs", activeTabKey = "workbench.activeTab"

    /// `defaults` and `seedFolders` (where the recent list is seeded from) are for tests; the app uses the standard ones.
    /// `socketPath`: where to listen for the agent (one engine socket per app; nil: nowhere). `services`: what each tab's
    /// engines may call outside the process (the app: `liveServices`).
    init(defaults: UserDefaults = .standard, seedFolders: [URL]? = nil, socketPath: URL? = EngineSocket.defaultPath(),
         services: @escaping @MainActor () -> EngineServices = Workbench.liveServices) {
        self.defaults = defaults
        makeServices = services
        recents = RecentProjects(defaults: defaults, seedFolders: seedFolders)
        nav = Navigation.restored(activity: defaults.string(forKey: Navigation.activityKey) ?? defaults.string(forKey: Navigation.legacyWorkspaceKey),
                                  level: defaults.string(forKey: Navigation.levelKey), rightTab: defaults.string(forKey: Navigation.rightTabKey),
                                  hasRecents: !recents.paths.isEmpty)
        if let socketPath { startSocket(socketPath) }
        recents.refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.server?.stop() }
        }
    }

    /// The app's services: the engines of this Mac, its support folder (voice profiles, budget and approvals), the
    /// generation providers and the folders media.list may read.
    static func liveServices() -> EngineServices {
        EngineServices.live(library: MediaLibrary.from(arguments: [], environment: ProcessInfo.processInfo.environment))
    }

    /// The tab on screen (there is always one).
    var active: EditorStore { tabs.first { $0.tabID == activeID } ?? tabs[0] }
    func tab(_ id: String) -> EditorStore? { tabs.first { $0.tabID == id } }

    var agentConnected: Bool { !agents.isEmpty }
    var agentName: String {
        guard let a = agents.last else { return "Claude" }
        return a.lowercased().contains("claude") ? "Claude" : a
    }

    // MARK: Tabs

    /// The next tab id: tab-1, tab-2…
    func nextTabID() -> String {
        defer { nextNumber += 1 }
        return "tab-\(nextNumber)"
    }

    /// A store made outside (`EditorStore(defaults:)`, tests) joins as a tab.
    func adopt(_ store: EditorStore) {
        tabs.append(store)
        store.ui.window = window
        onNewTab?(store)
        if activeID.isEmpty { activeID = store.tabID; store.refreshEngines() }
        persistTabs()
    }

    /// A new empty tab after the others (not selected).
    @discardableResult
    func newTab() -> EditorStore {
        let store = EditorStore(bench: self, tabID: nextTabID())
        adopt(store)
        return store
    }

    /// ⌘T and the + tab: a new empty tab, selected, showing Inizio.
    func openNewTab() {
        let t = newTab()
        select(t.tabID)
    }

    /// Shows a tab. The one left behind lets go of its preview player and frame caches; an empty tab shows Inizio (or
    /// Registra when that is on screen), a project left on Inizio shows the editor.
    func select(_ id: String) {
        guard let next = tab(id) else { return }
        if id != activeID {
            let previous = tabs.first { $0.tabID == activeID }
            activeID = id
            previous?.suspend()
            next.resume()
        }
        if next.isEmpty {
            if nav.activity != .record { nav.select(.home) }
        } else if nav.activity == .home {
            nav.showEditor()
        }
        persistTabs()
    }

    /// ⌃Tab / ⌃⇧Tab, ⌘⇧] / ⌘⇧[.
    func selectNext(_ step: Int) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.tabID == activeID }) else { return }
        select(tabs[(i + step + tabs.count) % tabs.count].tabID)
    }

    /// Drag to reorder: `id` goes where `target` is.
    func move(_ id: String, to target: String) {
        guard id != target, let from = tabs.firstIndex(where: { $0.tabID == id }), let to = tabs.firstIndex(where: { $0.tabID == target }) else { return }
        let t = tabs.remove(at: from)
        tabs.insert(t, at: to)
        persistTabs()
    }

    /// The tab a new or opened project goes to: the active one when it is empty, otherwise a new tab (not selected yet).
    func tabForProject() -> EditorStore {
        active.isEmpty ? active : newTab()
    }

    /// The tab holding the project at `url`, if one does.
    func tab(holding url: URL) -> EditorStore? {
        let path = RecentList.normalized(url.path)
        return tabs.first { ($0.projectURL ?? $0.pendingPath).map { RecentList.normalized($0.path) } == path }
    }

    /// File › Apri recente, Inizio, Apri progetto…: selects the tab where the project is open, otherwise opens it in the
    /// active tab when that is empty or in a new tab, shown in the editor.
    func open(_ url: URL) {
        if let t = tab(holding: url) { return select(t.tabID) }
        let t = tabForProject()
        t.pendingPath = url
        Task {
            do {
                try await t.perform("project.open", ["path": .string(url.path)])
                t.pendingPath = nil
                select(t.tabID)
                nav.showEditor()
            } catch {
                t.pendingPath = nil
                recents.prune()
                if t.isEmpty, t !== active { remove(t) }
                active.show(error)
            }
        }
    }

    /// Takes a closed tab out of the strip (the last one stays, empty, on Inizio).
    func remove(_ store: EditorStore) {
        guard let i = tabs.firstIndex(where: { $0 === store }) else { return }
        if tabs.count == 1 {
            if store.isEmpty { nav.select(.home) }
            return persistTabs()
        }
        let wasActive = store.tabID == activeID
        tabs.remove(at: i)
        store.suspend()
        if recordingTabID == store.tabID { recordingTabID = nil }
        if wasActive { select(tabs[min(i, tabs.count - 1)].tabID) } else { persistTabs() }
    }

    /// The × of a tab, ⌘W, the context menu: a recording or a job running there asks first, unsaved changes ask Salva /
    /// Non salvare / Annulla. Returns whether the tab closed.
    @discardableResult
    func close(_ store: EditorStore) async -> Bool {
        if recordingTabID == store.tabID {
            guard confirm(String(format: loc("«%@» sta registrando."), store.tabTitle), loc("Chiudendo la scheda la registrazione si ferma; il file si apre in una nuova scheda."),
                          loc("Ferma e chiudi")) else { return false }
            recorder?.stop()
        } else if let work = store.runningWork {
            guard confirm(String(format: loc("In «%@» c'è un lavoro in corso: %@."), store.tabTitle, work), loc("Chiudendo la scheda il lavoro si ferma."),
                          loc("Chiudi")) else { return false }
            store.jobs.cancelAll()
        }
        return await store.closeTab()
    }

    /// Chiudi le altre: each one as its own close (stops at the first Annulla).
    func closeOthers(_ keep: EditorStore) async {
        for t in tabs where t !== keep {
            guard await close(t) else { return }
        }
    }

    enum SaveChoice { case save, discard, cancel }

    /// Closing a tab with unsaved changes asks Salva / Non salvare / Annulla (S1's dialog). Tests answer for the user.
    var saveDecision: (String) -> SaveChoice = { name in
        let a = NSAlert()
        a.messageText = String(format: loc("Salvare le modifiche a «%@»?"), name)
        a.informativeText = loc("Se non salvi, le modifiche vanno perse.")
        a.addButton(withTitle: loc("Salva"))
        a.addButton(withTitle: loc("Annulla"))
        a.addButton(withTitle: loc("Non salvare"))
        switch a.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    func askSave(_ name: String) -> SaveChoice { saveDecision(name) }

    private func confirm(_ message: String, _ detail: String, _ action: String) -> Bool {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.addButton(withTitle: action)
        a.addButton(withTitle: loc("Annulla"))
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: Recording

    /// The recorder's ends, as the app wires them at launch (a test's rig wires its own recorder the same way). A
    /// recording belongs to the tab it was started from (the one on screen then). The teleprompter's live take markers
    /// are written next to the recording before it is imported; a camera take and a screen session go where that tab
    /// chose on Registra (`recordingFinished`, #39), a camera take then edited automatically when Registra says so.
    func follow(_ recorder: Recorder) -> AnyCancellable {
        recorder.onSessionFinished = { [weak self] url in
            Task { @MainActor in
                await TeleprompterController.shared.saveTakes(for: url.deletingLastPathComponent())
                self?.recordingFinished(url, session: true)
            }
        }
        recorder.onFinished = { [weak self] url in
            Task { @MainActor in
                await TeleprompterController.shared.saveTakes(for: url)
                guard let self else { return }
                let tab = self.recordingFinished(url, session: false)
                if Prefs.autoEdit { tab.autoEdit(script: TeleprompterController.shared.text) }
            }
        }
        return recorder.$isRecording.removeDuplicates().dropFirst().sink { [weak self] on in
            DispatchQueue.main.async { if on { self?.recordingStarted() } else { self?.recordingStopped() } }
        }
    }

    /// The recorder started: the take belongs to the tab on screen.
    func recordingStarted() {
        if recordingTabID == nil {
            recordingTabID = activeID
            startedDestination = active.recordingDestination
        }
        notice = nil
    }

    /// The recorder stopped: its file goes to that tab when it is imported.
    func recordingStopped() {
        finishedRecordingTabID = recordingTabID
        finishedDestination = startedDestination
        recordingTabID = nil
        startedDestination = nil
    }

    /// Why `store` cannot start a recording now (nil: it can): the recorder belongs to another tab.
    func recordingRefusal(for store: EditorStore) -> String? {
        guard let owner = recordingTabID, owner != store.tabID else { return nil }
        let name = tab(owner)?.tabTitle ?? loc("un'altra scheda")
        return String(format: loc("Sta già registrando in «%@»: una registrazione alla volta. Fermala da quella scheda."), name)
    }

    /// Where a finished recording goes (#39), a camera / voice take and a screen session alike: into the project of the
    /// tab it was started from when Registra said "Questo progetto" there as the recording started; otherwise into a new
    /// project, in that tab when it is empty, else in a new tab (also when the tab was closed while recording). The tab is
    /// selected.
    func recordingTarget() -> (tab: EditorStore, newProject: Bool) {
        let owner = finishedRecordingTabID.flatMap(tab)
        let wanted = finishedDestination ?? owner?.recordingDestination
        finishedRecordingTabID = nil
        finishedDestination = nil
        let target: (tab: EditorStore, newProject: Bool)
        if let owner, owner.project != nil, wanted == .thisProject {
            target = (owner, false)
        } else if let owner, owner.isEmpty {
            target = (owner, true)
        } else {
            target = (newTab(), true)
        }
        select(target.tab.tabID)
        return target
    }

    /// The recorder's file is written (`session`: a screen session's session.json): it goes where `recordingTarget`
    /// says; the notice tells where. Returns the tab it went to.
    @discardableResult
    func recordingFinished(_ url: URL, session: Bool) -> EditorStore {
        let (tab, newProject) = recordingTarget()
        tab.importRecording(url, session: session, newProject: newProject)
        return tab
    }

    /// What a notice says, and the file "Mostra nel Finder" shows.
    struct Notice: Equatable {
        var text: String
        var file: URL?
    }

    // MARK: Unsaved work

    /// The tabs with unsaved changes.
    var unsaved: [EditorStore] { tabs.filter { $0.project != nil && $0.dirty } }

    /// ⌘Q with unsaved tabs: one dialog listing them (Salva tutti / Annulla / Esci senza salvare). Returns whether to quit.
    func confirmQuit() async -> Bool {
        let list = unsaved
        guard !list.isEmpty else { return true }
        let a = NSAlert()
        a.messageText = list.count == 1 ? String(format: loc("Salvare le modifiche a «%@» prima di uscire?"), list[0].tabTitle)
            : String(format: loc("%d progetti hanno modifiche non salvate."), list.count)
        a.informativeText = list.map { "• " + $0.tabTitle }.joined(separator: "\n") + "\n\n" + loc("Se non salvi, le modifiche vanno perse.")
        a.addButton(withTitle: list.count == 1 ? loc("Salva") : loc("Salva tutti"))
        a.addButton(withTitle: loc("Annulla"))
        a.addButton(withTitle: loc("Esci senza salvare"))
        switch a.runModal() {
        case .alertFirstButtonReturn:
            for t in list {
                guard await t.save() else { return false }
            }
            return true
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: Restore

    /// The open tabs (project paths) and the selected one, for the next launch. Only projects saved on disk.
    func persistTabs() {
        let paths = tabs.compactMap { t -> String? in
            guard let u = t.projectURL ?? t.pendingPath, RecentList.projectExists(u.path) else { return nil }
            return RecentList.normalized(u.path)
        }
        defaults.set(paths, forKey: Self.tabsKey)
        let activePath = (active.projectURL ?? active.pendingPath).map { RecentList.normalized($0.path) }
        defaults.set(activePath.flatMap { paths.firstIndex(of: $0) } ?? 0, forKey: Self.activeTabKey)
    }

    /// At launch: one tab per remembered project still on disk (missing ones are skipped, with a quiet note in the
    /// activity log), the remembered one selected; one empty tab when there is none.
    func restoreTabs() {
        let paths = defaults.stringArray(forKey: Self.tabsKey) ?? []
        let selected = defaults.integer(forKey: Self.activeTabKey)
        var opened: [EditorStore] = []
        var missing: [String] = []
        for p in paths {
            guard RecentList.projectExists(p) else { missing.append(URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent); continue }
            let t = newTab()
            let url = URL(fileURLWithPath: p, isDirectory: true)
            t.pendingPath = url
            opened.append(t)
            Task {
                do { try await t.perform("project.open", ["path": .string(url.path)]) } catch { t.show(error) }
                t.pendingPath = nil
                persistTabs()
            }
        }
        if tabs.isEmpty { newTab() }
        let index = paths.indices.contains(selected) ? paths[selected] : nil
        select((index.flatMap { p in opened.first { $0.pendingPath.map { RecentList.normalized($0.path) } == p } } ?? tabs[0]).tabID)
        if !missing.isEmpty { note(String(format: loc("Non trovati, schede non riaperte: %@"), missing.joined(separator: ", "))) }
    }

    /// A line in the activity log that is not a command (a tab opened by the agent, projects not found at launch).
    func note(_ text: String, agent: Bool = false) {
        var a = EditorStore.Activity(source: agent ? "Claude" : loc("Tu"), isAgent: agent, command: "", params: "")
        a.status = .ok
        a.note = text
        activity.append(a)
    }

    // MARK: The agent's commands

    /// `project.list`: the open tabs, in order.
    func listJSON() -> JSONValue {
        let rows: [JSONValue] = tabs.map { t in
            ["id": .string(t.tabID), "name": t.project.map { .string($0.name) } ?? .null,
             "path": t.projectURL.map { .string($0.path) } ?? .null, "dirty": .bool(t.project != nil && t.dirty),
             "active": .bool(t.tabID == activeID), "recording": .bool(t.tabID == recordingTabID)]
        }
        return ["tabs": .array(rows), "active": .string(activeID)]
    }

    /// The tab a command names (`project`: a tab id or the project's path), or the active one.
    func resolve(_ target: String?) throws -> EditorStore {
        guard let target else { return active }
        if let t = tabs.first(where: { ProjectTarget.matches(target, tabID: $0.tabID, path: $0.projectURL) }) { return t }
        let open = tabs.map { t in "\(t.tabID)" + (t.projectURL.map { " (\($0.path))" } ?? t.project.map { " (\($0.name), unsaved)" } ?? " (empty)") }  // l10n-ignore
        throw CommandError(.notFound, "No open tab matches project '\(target)': the open tabs are \(open.joined(separator: ", ")) — project.list shows them, project.open opens another")  // l10n-ignore
    }

    /// Socket handler (any thread): the agent's command, routed to its tab and serialized with the user's commands there.
    nonisolated func agentExecute(_ id: String, _ params: JSONValue, client: String) throws -> JSONValue {
        if id == "project.new" || id == "project.open" { return try agentOpen(id, params, client: client) }
        var target: String?, rest = params
        if ProjectTarget.accepts(id) { (target, rest) = try ProjectTarget.split(params) }
        let store = try DispatchQueue.main.sync { try MainActor.assumeIsolated { try self.resolve(target) } }
        let result = try store.agentExecute(id, rest, client: client)
        if id == "project.close" {
            DispatchQueue.main.async { MainActor.assumeIsolated { if store.isEmpty { self.remove(store) } } }
        }
        return result
    }

    /// project.new / project.open from the agent: an already open project's tab is selected; otherwise the active tab
    /// when empty, or a new tab, runs the command and is selected once it succeeded. The log says what happened.
    nonisolated private func agentOpen(_ id: String, _ params: JSONValue, client: String) throws -> JSONValue {
        let path = id == "project.open" ? params["path"]?.stringValue.map { ProjectStore.folder(for: $0) } : nil
        let (store, existing, created) = DispatchQueue.main.sync {
            MainActor.assumeIsolated { () -> (EditorStore, Bool, Bool) in
                if let path, let t = self.tab(holding: path) { return (t, true, false) }
                let empty = self.active.isEmpty
                return (empty ? self.active : self.newTab(), false, !empty)
            }
        }
        if existing {
            let result = try store.agentExecute("project.state", .object([:]), client: client)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let was = store.tabID == self.activeID
                    self.select(store.tabID)
                    let text = was ? loc("Claude ha chiesto «%@», già aperto in questa scheda.") : loc("Claude è passato alla scheda di «%@», già aperta.")
                    self.note(String(format: text, store.tabTitle), agent: true)
                }
            }
            return result
        }
        do {
            let result = try store.agentExecute(id, params, client: client)
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self.select(store.tabID)
                    let name = store.tabTitle
                    if created {
                        let text = id == "project.new" ? loc("Claude ha creato «%@» in una nuova scheda.") : loc("Claude ha aperto «%@» in una nuova scheda.")
                        self.note(String(format: text, name), agent: true)
                    }
                }
            }
            return result
        } catch {
            if created { DispatchQueue.main.async { MainActor.assumeIsolated { self.remove(store) } } }
            throw error
        }
    }

    // MARK: Socket

    private func startSocket(_ path: URL) {
        let server = EngineSocketServer(path: path, handler: { [weak self] command, params, client in
            guard let self else { throw SocketError("the app is closing") }  // l10n-ignore
            return try self.agentExecute(command, params, client: client)
        }, onClient: { [weak self] name, build in
            DispatchQueue.main.async {
                guard let self else { return }
                if let name {
                    self.agents.append(name)
                    // A client that sends no build (a raw socket check, an old server) is not judged.
                    self.agentBuildMismatch = build.flatMap { BuildStamp.mismatch(app: .current, mcp: $0) }
                } else if !self.agents.isEmpty {
                    self.agents.removeFirst()
                    if self.agents.isEmpty { self.agentBuildMismatch = nil }
                }
            }
        })
        do {
            try server.start()
            self.server = server
        } catch {
            socketProblem = loc("Claude non può collegarsi a questa app: %@", "\(error)")
        }
    }
}

/// `project.list` for the engines of the app's tabs: the workbench's tabs, read on the main thread.
final class WorkbenchTabs: ProjectTabs, @unchecked Sendable {
    weak var bench: Workbench?
    init(_ bench: Workbench) { self.bench = bench }

    func list() -> JSONValue {
        let read: @Sendable () -> JSONValue = { [weak bench] in MainActor.assumeIsolated { bench?.listJSON() ?? ["tabs": [], "active": .null] } }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }
}
