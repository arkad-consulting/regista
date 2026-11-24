import AppKit
import Combine
import Foundation
import RegistaCore
import RegistaEngines
import RegistaMCP

/// One open project (a tab of the `Workbench`, S2 #76) and the owner of its `RegistaCore.Engine`. Every button, menu
/// item, shortcut and every MCP command routed to this tab goes through `Engine.execute` on the tab's serial queue;
/// after each command the store publishes a snapshot (project, history) on the main actor, so the UI follows the agent
/// live. What all tabs share (navigation, recents, the activity log, agents, the approval and the sheets) lives in the
/// workbench: the store forwards those properties under their old names and re-publishes the workbench's changes.
@MainActor
final class EditorStore: ObservableObject {
    enum Workspace: String, CaseIterable, Identifiable {
        case home, record, pro, simple, export
        var id: String { rawValue }
    }

    enum Tool: String, CaseIterable { case select, razor, text, hand }

    /// One executed command, for the Agent panel.
    struct Activity: Identifiable, Equatable {
        enum Status: Equatable { case running, ok, failed }
        let id = UUID()
        var source: String
        var isAgent: Bool
        var command: String
        var params: String
        var status: Status = .running
        /// The second line: what happened, in words (CommandLines), or the error of a failed command.
        var result = ""
        /// The result's raw fields, for the row's tooltip (Summary.details).
        var details = ""
        var started = Date()
        var seconds: Double = 0
        /// Only looked (a query that writes nothing the user keeps): collapsed with its neighbours in the Claude tab.
        var readOnly = false
        /// The project of the tab it ran in, when that was not the tab on screen.
        var project: String?
        /// A line that is not a command (a tab opened by the agent, projects not found at launch).
        var note: String?
        /// An export whose result carries `aiDisclosure` (a generated voice in the video): «Ultimo export» shows the note (#25).
        var aiDisclosure = false
    }

    /// The workbench this tab belongs to, and the tab's id ("tab-1"…, project.list's id).
    let bench: Workbench
    let tabID: String
    /// A project being opened in this tab (restore, File › Apri recente) until its snapshot arrives.
    var pendingPath: URL?
    private var bag: Set<AnyCancellable> = []

    // Snapshot of the engine (written only by `apply`).
    @Published private(set) var project: Project?
    @Published private(set) var projectURL: URL?
    @Published private(set) var dirty = false
    @Published private(set) var undoNames: [String] = []
    @Published private(set) var redoNames: [String] = []

    /// The activity log of every tab (the workbench's).
    var activity: [Activity] {
        get { bench.activity }
        set { bench.activity = newValue }
    }
    /// Connected MCP clients (names from their initialize).
    var agents: [String] { bench.agents }
    /// Set when the last connected regista-mcp reported a build different from this app's (shown on the agent pill).
    var agentBuildMismatch: BuildStamp.Mismatch? { bench.agentBuildMismatch }
    /// The command running now in this tab, if any.
    @Published private(set) var running: String?
    @Published var errorMessage: String?
    /// The last ducking check of this tab's music (E3 #55), shown while the audio it measured is unchanged.
    @Published var musicCheck: MusicCheck?
    /// The measured loudness of the music files of this tab, by path (the Semplice level's music presets).
    @Published var musicLoudness: [String: Double] = [:]
    var socketProblem: String? {
        get { bench.socketProblem }
        set { bench.socketProblem = newValue }
    }
    /// A paid generation estimate waiting for the user's decision (the confirmation sheet).
    var pendingApproval: GenerationApprovals.Entry? {
        get { bench.pendingApproval }
        set { bench.pendingApproval = newValue }
    }
    /// Long work started from the UI (steps, export, voice renders, takes, training…): shown where it was started and in
    /// the status bar's jobs list (E2 #54).
    let jobs = JobCenter()
    /// The voice features (Voce panel, recording flow, Settings › Profilo e voce).
    private(set) lazy var voice = VoiceModel(store: self, defaults: bench.defaults)
    /// The Generate panel (G1 #5).
    private(set) lazy var generation = GenerateState(store: self)
    /// The voice recording flow (a sheet on the main window).
    var showVoiceSetup: Bool {
        get { bench.showVoiceSetup }
        set { bench.showVoiceSetup = newValue }
    }
    /// Activity, editor level and the right panel's tab: the window's, shared by all tabs (`Workbench.nav`).
    var nav: Navigation {
        get { bench.nav }
        set { bench.nav = newValue }
    }
    /// The workspace in the main area (the editor levels keep the library activity).
    var workspace: Workspace {
        get { nav.workspace }
        set { nav.show(newValue) }
    }
    /// An activity of the bar, ⌘1…⌘9.
    func select(_ activity: Navigation.Activity) { nav.select(activity) }
    /// The editor at the level used last, on the library activity used last.
    func showEditor() { nav.showEditor() }
    /// Projects opened or saved last (File › Apri recente, Inizio).
    var recents: RecentProjects { bench.recents }
    /// RAM, tier and engines ready, for Inizio (engines.status, read at launch and when Inizio appears).
    var engineSummary: EngineSummary? { bench.engineSummary }
    @Published var tool: Tool = .select
    @Published var selection: Set<String> = [] {
        didSet {
            if !selection.isEmpty, captionPick != nil { captionPick = nil }
            if !selection.isEmpty { mediaFocus = false }
        }
    }
    /// A caption block picked on the timeline (the inspector shows its style, keywords and text).
    @Published var captionPick: CaptionPick? {
        didSet {
            if captionPick != nil, !selection.isEmpty { selection = [] }
            if captionPick != nil { mediaFocus = false }
        }
    }
    /// The Media panel has the focus (a tile was clicked, nothing chosen on the timeline since): ⌫ removes the selected
    /// tile's file from the project (#142) instead of deleting clips.
    @Published var mediaFocus = false
    /// Clips copied with ⌘C (pasted at the playhead with ⌘V).
    var clipboard: [String] = []
    /// Asset shown in the Source monitor.
    @Published var sourceAssetID: String?
    /// The Semplice step the person opened in this tab, kept while the tab is open (#104): «Pro» and back to «Semplice»
    /// rebuild the level's views, and the step left open must be the one that comes back. Nil until a step is opened.
    @Published var simpleOpen: SimpleStep?
    /// Where a recording started from this tab goes, as chosen on Registra (nil: the default), kept while the tab is open.
    @Published var recordingChoice: RecordingDestination?
    /// The format chosen on Registra for a take joining this tab's project (#160, a preset id; nil: the project's own): the
    /// project changes to it when the take lands.
    @Published var recordingFormat: String?
    /// The last framing check of this tab's edit (#152): «Trova il volto» shows a cut head while it holds.
    @Published var framing: FramingCheck?
    /// Instagram UI guides on the Program monitor: off until asked for (they are guides, not a crop).
    @Published var safeZones = false
    /// The Marca picker (the toolbar's "Marca: <kit>" popover, ⇧⌘B): the one place the project's kit is picked (E4 #3).
    var showBrandKits: Bool {
        get { bench.showBrandKits }
        set { bench.showBrandKits = newValue }
    }
    /// Selected transcript word range (timeline word indices).
    @Published var wordSelection: ClosedRange<Int>? {
        didSet { if wordSelection != nil { mediaFocus = false } }
    }
    /// Timeline zoom, points per second; `autoFit` keeps the whole edit in view until the user zooms.
    @Published var pxPerSec: Double = 20
    @Published var autoFit = true
    @Published private(set) var fitRequest = 0

    /// Words as the timeline plays them (derived from the snapshot).
    private(set) var words: [TimelineWord] = []
    /// Bumped whenever the project snapshot changes (cheap change detection for derived views).
    @Published private(set) var projectVersion = 0

    // Direct manipulation on the preview (issue #21, CanvasEditor.swift).
    /// The caption track (`caption:<trackId>`, whichever chunk shows) or the clip selected on the preview.
    @Published var canvasSelection: String?
    /// "Tutti i sottotitoli" or "Solo questo": what a caption drag moves.
    @Published var captionScope: CaptionScope = .all
    /// Arrow nudges and ⌥-scroll resizing not committed yet (one command per burst).
    @Published var canvasPending: CanvasPending?
    /// A drag is in progress on a preview (the static safe zones give way to the red Instagram zones).
    @Published var canvasDragging = false
    /// The selected element as the preview last drew it, and whether the pointer is over a preview.
    var canvasElement: CanvasElement?
    var canvasHover = false
    var canvasCommit: DispatchWorkItem?

    nonisolated(unsafe) let engine: Engine
    nonisolated let generationState: URL
    nonisolated let queue = DispatchQueue(label: "regista.engine", qos: .userInitiated)  // l10n-ignore
    /// A second engine, without a project, for long commands that do not touch the edit (voice.preview,
    /// voice.enroll.add): they run beside the editor's queue, so the edit and the agent never wait on them, and its
    /// own Cancel stops their processes.
    nonisolated(unsafe) let asideEngine: Engine
    nonisolated let asideQueue = DispatchQueue(label: "regista.engine.aside", qos: .userInitiated)  // l10n-ignore
    nonisolated let asideCancellation = GenerationCancellation()
    let ui = AppUIHost()
    let preview = PreviewController()
    let media = MediaCache()
    let previews = EffectPreviews()

    /// A tab of `bench` (`Workbench.newTab`).
    init(bench: Workbench, tabID: String) {
        self.bench = bench
        self.tabID = tabID
        var services = bench.makeServices()
        services.ui = ui
        services.tabs = WorkbenchTabs(bench)
        engine = Engine(services: services)
        var aside = services
        aside.ui = nil
        aside.cancellation = asideCancellation
        asideEngine = Engine(services: aside)
        generationState = services.generationState
        ui.store = self
        preview.store = self
        previews.store = self
        // The views observe the store: the workbench's changes (navigation, log, agents, sheets) are the store's too.
        bench.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        // The window's jobs list follows every tab's jobs (the panels observe `jobs` themselves: a progress step does
        // not redraw the whole editor).
        jobs.objectWillChange.sink { [weak bench] _ in bench?.jobsHub.objectWillChange.send() }.store(in: &bag)
        refreshApprovals()   // an estimate the agent left while the app was closed
    }

    /// A workbench of its own with this store as its one tab (tests, previews). `defaults` and `seedFolders` (where the
    /// recent list is seeded from) are for tests, and so are `services` (what the workbench's tabs may call outside the
    /// process); the app makes its tabs through `Workbench`.
    convenience init(defaults: UserDefaults = .standard, seedFolders: [URL]? = nil,
                     services: @escaping @MainActor () -> EngineServices = Workbench.liveServices) {
        let bench = Workbench(defaults: defaults, seedFolders: seedFolders, services: services)
        self.init(bench: bench, tabID: bench.nextTabID())
        bench.adopt(self)
    }

    var agentConnected: Bool { bench.agentConnected }
    var agentName: String { bench.agentName }

    // MARK: The tab

    /// The tab on screen.
    var isActive: Bool { bench.activeID == tabID }
    /// No project, none being opened, not recording: the tab shows Inizio and the next project opened goes here.
    var isEmpty: Bool { project == nil && pendingPath == nil && bench.recordingTabID != tabID }
    /// The tab's name: the project's, the one being opened, or "Nuova scheda".
    var tabTitle: String { project?.name ?? pendingPath?.deletingPathExtension().lastPathComponent ?? loc("Nuova scheda") }
    /// What still works in this tab (a job or a command), in words; nil when idle.
    var runningWork: String? {
        if let j = jobs.jobs.last(where: \.isRunning) { return j.title }
        return running.map(CommandTitles.title)
    }

    /// The tab left the screen: the preview player lets go of its items and the frame caches empty (rebuilt on return).
    func suspend() {
        preview.suspend()
        media.suspend()
        previews.purge()
    }

    /// The tab is on screen again: the preview is rebuilt from the project.
    func resume() {
        media.resume()
        preview.projectChanged()
    }

    /// Saves this tab's project (asks for a folder when it has none). false when cancelled or failed.
    func save() async -> Bool {
        guard project != nil else { return true }
        var params: JSONValue = [:]
        if projectURL == nil {
            guard let url = Panels.askProjectFolder(self) else { return false }
            params = ["path": .string(url.path)]
        }
        do {
            try await perform("project.save", params)
            return true
        } catch {
            show(error)
            return false
        }
    }

    // MARK: Running commands

    /// A failed command in the window's alert, in words a person can act on: a known engine error becomes its sentence,
    /// any other keeps the engine's detail after a translated lead (never the raw message alone, spec rule 2).
    func show(_ error: Error) {
        errorMessage = StepError.readable(error, fallback: "Il motore ha risposto: %@")
    }

    /// Fire-and-forget from a button: errors show in the window.
    func run(_ id: String, _ params: JSONValue = [:]) {
        queue.async { [self] in
            if case .failure(let e) = execute(id, params, source: "Tu", agent: false) {
                DispatchQueue.main.async { self.show(e) }
            }
        }
    }

    /// Awaitable, for sequences (import, automatic edit).
    @discardableResult
    func perform(_ id: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in cont.resume(with: execute(id, params, source: "Tu", agent: false)) }
        }
    }

    /// A query on the engine queue that stays out of the activity list (previews drawn for the UI itself).
    nonisolated func silent(_ id: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in cont.resume(with: Result { try engine.execute(id, params: params) }) }
        }
    }

    /// A long command that does not touch the edit, on the aside engine (logged like the others). A Cancel
    /// (`cancelAside`) stops the processes it waits for; the command then fails with "cancelled".
    func aside(_ id: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { cont in
            asideQueue.async { [self] in
                asideCancellation.reset()
                let entry = logStart(id, params, source: "Tu", agent: false, quiet: true)
                let result = Result { try asideEngine.execute(id, params: params) }
                logEnd(entry, id, result, started: entry.started)
                cont.resume(with: result)
            }
        }
    }

    /// Stops the aside command running now (the job's Cancel).
    nonisolated func cancelAside() { asideCancellation.cancel() }

    nonisolated private func logStart(_ id: String, _ params: JSONValue, source: String, agent: Bool, quiet: Bool) -> Activity {
        var entry = Activity(source: source, isAgent: agent, command: id, params: Summary.params(params),
                             readOnly: ActivityFeed.isLook(id, kind: engine.registry[id]?.kind))
        DispatchQueue.main.async { [self] in
            if !quiet { running = id }
            if !isActive, bench.tabs.count > 1 { entry.project = tabTitle }   // ran in a tab the user is not looking at
            activity.append(entry)
            if activity.count > 400 { activity.removeFirst(activity.count - 400) }
        }
        return entry
    }

    nonisolated private func logEnd(_ entry: Activity, _ id: String, _ result: Result<JSONValue, Error>, started: Date) {
        let seconds = Date().timeIntervalSince(started)
        DispatchQueue.main.async { [self] in
            if let i = activity.lastIndex(where: { $0.id == entry.id }) {
                activity[i].seconds = seconds
                switch result {
                case .success(let r):
                    activity[i].status = .ok
                    activity[i].result = CommandLines.line(id, r) ?? ""
                    activity[i].details = Summary.details(id, r)
                    activity[i].aiDisclosure = r["aiDisclosure"] != nil
                case .failure(let e):
                    activity[i].status = .failed
                    activity[i].result = StepError.readable(e, fallback: "Il motore ha risposto: %@")
                    // The engine's text whole, one hover away (#88): the sentence above is what the person reads.
                    activity[i].details = JobCenter.message(e)
                }
            }
        }
    }

    /// Runs on `queue`. Logs the command in the activity list and publishes the new snapshot.
    nonisolated func execute(_ id: String, _ params: JSONValue, source: String, agent: Bool) -> Result<JSONValue, Error> {
        let quiet = Self.quietCommands.contains(id)
        let entry = logStart(id, params, source: source, agent: agent, quiet: quiet)
        let result = Result { try engine.execute(id, params: params) }
        let kind = engine.registry[id]?.kind
        let snap = Snap(engine)
        logEnd(entry, id, result, started: entry.started)
        DispatchQueue.main.async { [self] in
            if !quiet { running = nil }
            apply(snap)
            if case .success = result { noteEditor(command: id, kind: kind, agent: agent) }
            // Opened or saved (Save As included), from the UI or by an agent: the project goes to the recent list.
            if case .success = result, id == "project.open" || id == "project.save", let url = snap.url { recents.note(url) }
            if case .success = result, kind == .session { bench.persistTabs() }
            if id.hasPrefix("generate.") { refreshApprovals() }
            // A kit written or put back by undo (E4 #3): the Marca picker and Settings › Brand kit read the kits again.
            if case .success = result, id.hasPrefix("brandkit.") || id.hasPrefix("history.") { BrandKitLibrary.shared.reload() }
            // A rule sheet written (Settings › Regole or an agent, #31): the Export card checks again.
            if case .success = result, id.hasPrefix("rules."), kind == .session { RulesRevision.shared.bump() }
            // A skill written, removed or put back by an undo (#157): Settings › Regia e skill reads again.
            if case .success = result, Self.skillWrites.contains(id) || id.hasPrefix("history.") { RulesRevision.shared.bump() }
        }
        return result
    }

    /// Reads engines.status off the list of activities (it hashes a few binaries: a moment, on the engine queue).
    func refreshEngines() {
        Task {
            if let r = try? await silent("engines.status"), let s = EngineSummary(status: r) { bench.engineSummary = s }
        }
    }

    // MARK: Paid generation approvals

    /// Shows the newest paid estimate still waiting (an agent's generate.estimate / a refused generate.run left it).
    func refreshApprovals() {
        guard bench.panelPricing == 0 else { return }
        let pending = (try? GenerationApprovals(directory: generationState).pending()) ?? []
        // The Generate panel's own estimates are approved in the panel (its approval card), not in this sheet.
        pendingApproval = pending.last { !bench.panelEstimates.contains($0.estimate.estimateID) }
    }

    /// The user's decision on the sheet: generate.approve runs here, in the app (agents cannot call it).
    func decideApproval(approve: Bool) {
        guard let e = pendingApproval else { return }
        pendingApproval = nil
        Task {
            do {
                // The agent reads the token with generate.list (approvals) and passes it to generate.run.
                try await perform("generate.approve", ["estimateId": .string(e.estimate.estimateID), "decline": .bool(!approve)])
            } catch {
                show(error)
            }
        }
    }

    /// Commands that only look at the app (logged, but they do not mark the editor busy).
    nonisolated static let quietCommands: Set<String> = ["ui.screenshot", "preview.frame", "project.state", "project.list"]
    /// The commands that write one of the person's skills (#157).
    nonisolated static let skillWrites: Set<String> = ["skill.create", "skill.set", "skill.duplicate", "skill.remove", "skill.import"]

    /// Socket handler (any thread): the agent's command, serialized with the user's.
    nonisolated func agentExecute(_ id: String, _ params: JSONValue, client: String) throws -> JSONValue {
        let name = client.lowercased().contains("claude") ? "Claude" : client
        return try queue.sync { execute(id, params, source: name, agent: true) }.get()
    }

    private struct Snap: @unchecked Sendable {
        var project: Project?
        var url: URL?
        var dirty: Bool
        var undo: [String]
        var redo: [String]
        init(_ e: Engine) {
            project = e.project
            url = e.projectURL
            dirty = e.isDirty
            undo = e.context.history.undoStack.map(\.command)
            redo = e.context.history.redoStack.map(\.command)
        }
    }

    /// Publishes the engine's state now (a scratch store a render opened a project in, on the main thread).
    func refreshFromEngine() { apply(Snap(engine)) }

    private func apply(_ s: Snap) {
        let changed = s.project != project
        let reopened = s.url != projectURL || (s.project?.name != project?.name)
        project = s.project
        projectURL = s.url
        dirty = s.dirty
        undoNames = s.undo
        redoNames = s.redo
        guard changed else { return }
        projectVersion += 1
        if s.project == nil || reopened { canvasSelection = nil }
        if let p = s.project, let track = TimelineTranscript.defaultTrack(in: p) {
            words = TimelineTranscript.words(of: track, in: p)
        } else {
            words = []
        }
        if let ws = wordSelection, ws.upperBound >= words.count { wordSelection = nil }
        let ids = Set(s.project?.tracks.flatMap(\.clips).map(\.id) ?? [])
        selection = selection.intersection(ids)
        if let pick = captionPick, s.project?.tracks.first(where: { $0.id == pick.trackID })?.captions?.chunks.indices.contains(pick.chunk) != true {
            captionPick = nil
        }
        if reopened { sourceAssetID = s.project?.assets.first { $0.video != nil }?.id }
        if let a = sourceAssetID, s.project?.asset(a) == nil { sourceAssetID = nil }
        if sourceAssetID == nil { sourceAssetID = s.project?.assets.first { $0.video != nil }?.id }
        if isActive { preview.projectChanged() }   // a tab in the background rebuilds its player when shown (`resume`)
    }

    /// A project the agent starts or opens while Monta or Esporta is on screen shows in the Semplice level (what the
    /// agent did, in plain view). Projects opened by hand go to the level used last (`openProject`).
    private func noteEditor(command: String, kind: CommandKind?, agent: Bool) {
        guard agent, kind == .session, command == "project.new" || command == "project.open" else { return }
        if nav.inEditor || workspace == .export { workspace = .simple }
    }

    // MARK: Convenience actions (each one is commands)

    func zoom(by factor: Double) {
        pxPerSec = min(max(pxPerSec * factor, 2), 400)
        autoFit = false
    }

    func zoomToFit() { fitRequest += 1 }

    func undo() { if !undoNames.isEmpty { run("history.undo") } }
    func redo() { if !redoNames.isEmpty { run("history.redo") } }

    func cutAtPlayhead() {
        guard project != nil else { return }
        run("timeline.cut", ["at": .number(preview.time)])
    }

    func deleteSelection(ripple: Bool) {
        if !selection.isEmpty {
            run("timeline.delete", ["clipIds": .array(selection.sorted().map { .string($0) }), "ripple": .bool(ripple)])
            selection = []
        } else if let ws = wordSelection {
            deleteWords(ws)
        }
    }

    func deleteWords(_ range: ClosedRange<Int>) {
        guard range.upperBound < words.count else { return }
        let text = words[range].map(\.text).joined(separator: " ")
        run("transcript.deleteWords", ["from": .number(Double(range.lowerBound)), "to": .number(Double(range.upperBound)), "expect": .string(text)])
        wordSelection = nil
    }

    func setTrack(_ id: String, _ field: String, _ value: Bool) {
        run("track.set", .object(["trackId": .string(id), field: .bool(value)]))
    }

    /// Opens a saved project (recent list, File menu) and shows it in Monta at the level used last: in the tab where it
    /// is already open, else in this tab when empty, else in a new tab (`Workbench.open`).
    func openProject(_ url: URL) { bench.open(url) }

    /// The × of the project tab: a recording or a job running asks first, unsaved changes ask Salva / Non salvare /
    /// Annulla, then project.close and the tab goes away (`Workbench.close`).
    func closeProject() {
        Task { await bench.close(self) }
    }

    /// Closes this tab's project after asking to save unsaved changes (Salva / Non salvare / Annulla), and takes the tab
    /// out of the strip. false when cancelled or failed.
    func closeTab() async -> Bool {
        guard let p = project else {
            bench.remove(self)
            return true
        }
        var save = false
        if dirty {
            switch bench.askSave(p.name) {
            case .save: save = true
            case .discard: break
            case .cancel: return false
            }
        }
        var target: URL?
        if save, projectURL == nil {
            guard let url = Panels.askProjectFolder(self) else { return false }
            target = url
        }
        do {
            if save { try await perform("project.save", target.map { ["path": .string($0.path)] } ?? [:]) }
            try await perform("project.close", ["discard": .bool(!save)])
            bench.remove(self)
            return true
        } catch {
            show(error)
            return false
        }
    }

    /// The tab a new project started from here goes to: this one when empty, otherwise a new tab, selected.
    func tabForNewProject() -> EditorStore {
        guard !isEmpty else { return self }
        let t = bench.tabForProject()
        bench.select(t.tabID)
        return t
    }

    /// A new empty project in the projects folder (saved on the first ⌘S), shown in the editor (`activity`: Pro on that
    /// library activity). In this tab when it is empty, otherwise in a new tab.
    /// `kind`: the kind of video (its rule sheet) when the way in says which it is (Video senza volto: a voice-over video).
    func newEmptyProject(name: String, activity: Navigation.Activity? = nil, kind: String? = nil) {
        let tab = tabForNewProject()
        guard tab === self else { return tab.newEmptyProject(name: name, activity: activity, kind: kind) }
        Task {
            do {
                var params = GeneralPrefs.newProject(name: Self.freeName(name, in: Self.projectsFolder), directory: Self.projectsFolder)
                if let kind, case .object(var o) = params { o["kind"] = .string(kind); params = .object(o) }
                try await perform("project.new", params)
                if let activity {
                    workspace = .pro
                    select(activity)
                } else {
                    showEditor()
                }
            } catch {
                show(error)
            }
        }
    }

    /// `base`, or `base 2`, `base 3`… : the first name with no `<name>.regista` in `folder`.
    nonisolated static func freeName(_ base: String, in folder: URL) -> String {
        let fm = FileManager.default
        var name = base, n = 2
        while fm.fileExists(atPath: folder.appendingPathComponent("\(name).\(ProjectStore.fileExtension)").path) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// Imports files; a video goes on the timeline (picture on V1, sound on A1, linked) when the timeline is empty.
    /// `newProject`: always start a new project named after the first file (Inizio › Monta un video).
    func importMedia(_ urls: [URL], newProject: Bool = false) {
        if newProject {
            let tab = tabForNewProject()
            if tab !== self { return tab.importMedia(urls, newProject: true) }
        }
        Task {
            do {
                if project == nil || newProject {
                    let name = urls.first?.deletingPathExtension().lastPathComponent ?? loc("Progetto")
                    try await perform("project.new", GeneralPrefs.newProject(name: Self.freeName(name, in: Self.projectsFolder), directory: Self.projectsFolder))
                }
                for url in urls {
                    let r = try await perform("media.import", ["path": .string(url.path)])
                    if let id = r.value(at: "asset.id")?.stringValue, (project?.duration ?? .zero) == .zero,
                       project?.asset(id)?.video != nil, project?.asset(id)?.image == nil {
                        try await placeOnTimeline(id)
                    }
                }
            } catch {
                show(error)
            }
        }
    }

    func placeOnTimeline(_ assetID: String) async throws {
        guard let p = project, let asset = p.asset(assetID) else { return }
        var video = p.tracks.first { $0.kind == .video }?.id
        var audio = p.tracks.first { $0.kind == .audio }?.id
        if asset.video != nil, video == nil { video = try await perform("track.add", ["kind": "video"]).value(at: "track.id")?.stringValue }
        if asset.audio != nil, audio == nil { audio = try await perform("track.add", ["kind": "audio"]).value(at: "track.id")?.stringValue }
        var picture: String?
        if asset.video != nil, let video {
            // A camera clip of another aspect than the project's is framed on the face in the same undo step (#154).
            picture = try await perform("timeline.place", ["assetId": .string(assetID), "trackId": .string(video), "frameOnFace": true])
                .value(at: "clip.id")?.stringValue
        }
        if asset.audio != nil, let audio {
            var params: JSONValue = ["assetId": .string(assetID), "trackId": .string(audio)]
            if let picture { params = ["assetId": .string(assetID), "trackId": .string(audio), "linkTo": .string(picture)] }
            try await perform("timeline.place", params)
        }
    }

    /// The local, deterministic automatic edit (no LLM): "Fai tutto" — transcribe, copione (the teleprompter's text when
    /// there is one), takes, cut, clean voice, captions — as one job of this tab with sub-steps, stoppable (E2 #54).
    /// Right after a recording the import may still be running: wait for it (15 s at most) before starting.
    func autoEdit(script: String?) {
        Task {
            for _ in 0..<75 where TextSteps.mainAsset(project) == nil || running != nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard TextSteps.mainAsset(project) != nil else {
                errorMessage = loc("Importa prima un video")
                return
            }
            // In Semplice, its own "Fai tutto" (with the light grade, without the steps this Mac cannot run).
            if nav.level == .simple { doEverything(script: script) } else { runAll(settings: stepSettings, script: script) }
        }
    }

    /// Where a recording started from this tab goes (#39): a new project when the tab has none; otherwise the choice made
    /// on Registra, by default this project (#140: several takes in a row join the same project).
    var recordingDestination: RecordingDestination {
        guard project != nil else { return .newProject }
        return recordingChoice ?? .thisProject
    }

    /// A finished recording in this tab (`Workbench.recordingTarget` chose it): a camera / voice take (a movie file) or a
    /// screen session (`session`: its session.json). `newProject`: a new project named like the recording, saved in the
    /// projects folder, the take on its timeline (a take: in the take's own format; a session: 16:9, screen, camera with
    /// the layout chosen while recording, mic — recording.import). Otherwise into this project: the take joins Media,
    /// selected there, and goes on the timeline when the timeline is empty. `format`: the video's format chosen on Registra
    /// (#153, a preset id): a new project gets it through project.format, so the clip is framed on the face; nil keeps the
    /// take's own format (a session: 16:9). A take joining this project with another format changes the project to it
    /// (#160). The window stays where it is (#140: on
    /// Registra, ready for the next take) unless `openEditor` (the automatic edit follows): then the editor on Media. A
    /// notice says where the take went and how many takes the project holds, with "Vai al montaggio" and "Mostra nel Finder".
    func importRecording(_ url: URL, session: Bool, newProject: Bool, format: String? = nil, openEditor: Bool = false) {
        if openEditor {
            workspace = .pro
            select(.media)
        }
        Task {
            do {
                let file = session ? url.deletingLastPathComponent() : url
                let before = Set(project?.assets.map(\.id) ?? [])
                if newProject {
                    let name = Self.freeName(Self.recordingProjectName(file, session: session), in: Self.projectsFolder)
                    if session {
                        try await perform("project.new", ["name": .string(name), "directory": .string(Self.projectsFolder.path), "width": 1920, "height": 1080])
                        try await perform("recording.import", ["path": .string(url.path)])
                        if let format, format != "16:9" { try await perform("project.format", ["preset": .string(format)]) }
                    } else {
                        try await perform("project.new", GeneralPrefs.newProject(name: name, directory: Self.projectsFolder))
                        let id = try await perform("media.import", ["path": .string(url.path)]).value(at: "asset.id")?.stringValue ?? ""
                        if format == nil, let v = project?.asset(id)?.video, let s = project?.settings, (v.width, v.height) != (s.width, s.height) {
                            try await perform("project.format", ["width": .number(Double(v.width)), "height": .number(Double(v.height))])
                        }
                        try await placeOnTimeline(id)
                        // The chosen format, the clip on the timeline: project.format frames it on the face (tracking it first).
                        if let format, project?.asset(id)?.video != nil { try await perform("project.format", ["preset": .string(format)]) }
                    }
                    try await perform("project.save")
                } else {
                    // Another format chosen on Registra for this project (#160): the project changes to it once the take is
                    // in (project.format, one undo step, the faces framed), else a take of another format is framed on the face.
                    let format = format.flatMap { f in project.flatMap(ScreenLook.formatID) == f ? nil : f }
                    if session, (project?.duration ?? .zero) == .zero {
                        try await perform("recording.import", ["path": .string(url.path)])
                    } else {
                        // A session into a project already edited: its files join Media, the timeline stays as it is.
                        let files = session ? try Self.sessionFiles(url) : [url]
                        for f in files {
                            let id = try await perform("media.import", ["path": .string(f.path)]).value(at: "asset.id")?.stringValue ?? ""
                            if !session, (project?.duration ?? .zero) == .zero, project?.asset(id)?.video != nil {
                                // A take of another format is framed on the face as it is placed (#150, #154).
                                try await placeOnTimeline(id)
                            }
                        }
                    }
                    if let format { try await perform("project.format", ["preset": .string(format)]) }
                    recordingFormat = nil
                }
                let added = project?.assets.filter { !before.contains($0.id) } ?? []
                let shown = added.first(where: { $0.video != nil }) ?? added.first
                if let shown { sourceAssetID = shown.id }
                let takes = project.map { Self.takeCount($0, recordings: bench.recordingsFolder) } ?? 0
                bench.notice = Workbench.Notice(text: loc("Ripresa salvata in «%@» · %@", project?.name ?? tabTitle, Plural.text(takes, "1 ripresa", "%d riprese")),
                                                file: file, take: shown.map { Workbench.Notice.Take(tabID: tabID, assetID: $0.id) })
            } catch {
                show(error)
            }
        }
    }

    /// The takes `project` holds: its files Regista recorded (in the `recordings` folder), a screen session's files
    /// counted once (they share the session's folder).
    nonisolated static func takeCount(_ project: Project, recordings: URL) -> Int {
        let root = recordings.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return Set(project.assets.compactMap { a -> String? in
            let path = URL(fileURLWithPath: a.path).resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(root) else { return nil }
            return path.dropFirst(root.count).split(separator: "/").first.map(String.init)
        }).count
    }

    /// "Vai al montaggio" of the notice after a take: the take's tab, the Pro editor on Media, the take in Source.
    func showTake(_ assetID: String) {
        bench.select(tabID)
        workspace = .pro
        select(.media)
        if project?.asset(assetID) != nil { sourceAssetID = assetID }
    }

    /// A new project's name for a recording: the take's own ("Registrazione <date>"), or for a screen session (its folder
    /// is "Sessione <date>") "Registrazione" with the session's date, in the interface language.
    nonisolated static func recordingProjectName(_ file: URL, session: Bool) -> String {
        guard session else { return file.deletingPathExtension().lastPathComponent }
        let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return loc("Registrazione %@", f.string(from: date))
    }

    /// The media files of a screen session (screen, camera, microphone, the Mac's sound).
    nonisolated static func sessionFiles(_ sessionFile: URL) throws -> [URL] {
        let s = try RecordingSession.load(sessionFile)
        let folder = sessionFile.deletingLastPathComponent()
        return s.sources.map { URL(fileURLWithPath: s.path(of: $0, sessionFolder: folder)) }
    }

    static var projectsFolder: URL { Paths.ensure(Paths.root.appendingPathComponent("Progetti", isDirectory: true)) }
    static var exportsFolder: URL { Paths.ensure(Paths.root.appendingPathComponent("Export", isDirectory: true)) }
}

/// Where a finished recording goes (#39): a new project of its own, or the project of the tab it was started from.
enum RecordingDestination: String, Hashable {
    case newProject, thisProject
}

/// Short strings for the activity list's tooltips: the parameters and the result's raw fields (the second line is
/// CommandLines' sentence).
enum Summary {
    static func params(_ v: JSONValue) -> String {
        guard case .object(let o) = v, !o.isEmpty else { return "" }
        return o.keys.sorted().prefix(4).map { k in "\(k): \(scalar(o[k]!))" }.joined(separator: ", ")
    }

    static func scalar(_ v: JSONValue) -> String {
        switch v {
        case .string(let s):
            let s = s.hasPrefix("/") ? (s as NSString).lastPathComponent : s
            return s.count > 28 ? String(s.prefix(27)) + "…" : s
        case .number(let n): return n.rounded() == n && abs(n) < 1e9 ? String(Int(n)) : String(format: "%.2f", n)
        case .bool(let b): return b ? loc("sì") : loc("no")
        case .array(let a): return a.count <= 4 && a.allSatisfy({ if case .number = $0 { return true }; return false })
            ? "[" + a.map(scalar).joined(separator: ", ") + "]" : "[\(a.count)]"
        case .object(let o): return "{\(o.count)}"
        case .null: return "–"
        }
    }

    /// A result field's name in words.
    static func resultLabel(_ k: String) -> String {
        switch k {
        case "undone": loc("result.undone")
        case "redone": loc("result.redone")
        case "removed": loc("result.removed")
        case "duration": loc("result.duration")
        case "frames": loc("result.frames")
        case "words": loc("result.words")
        case "count": loc("result.count")
        case "chunks": loc("result.chunks")
        case "segments": loc("result.segments")
        case "read": loc("result.read")
        case "clips": loc("result.clips")
        case "lines": loc("result.lines")
        case "path": loc("result.path")
        case "integrated": loc("result.integrated")
        case "cues": loc("result.cues")
        default: k
        }
    }

    /// The most telling fields of a result.
    static func details(_ command: String, _ r: JSONValue) -> String {
        guard case .object(let o) = r else { return scalar(r) }
        // The result's field names in words (resultLabel).
        let preferred = ["undone", "redone", "removed", "duration", "frames", "words", "count", "chunks", "segments", "read", "clips",
                         "lines", "path", "integrated", "cues"]
        var parts: [String] = []
        for k in preferred {
            guard let v = o[k] else { continue }
            parts.append("\(resultLabel(k)) \(scalar(v))")
            if parts.count == 3 { break }
        }
        if let l = o["loudness"], let i = l["integrated"]?.doubleValue { parts.append(String(format: "%.1f LUFS", i)) }
        // An export whose first attempt stalled before the first second and started again (#116): said here, one hover
        // away, and nowhere else (the export ended as asked; nothing for the person to do).
        if let f = o["restartedAtFrame"]?.doubleValue { parts.append(String(format: loc("ripartito una volta dal fotogramma %@"), String(Int(f)))) }
        return parts.joined(separator: " · ")
    }
}
