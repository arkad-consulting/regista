import Combine
import struct RegistaCore.BuildStamp
import SwiftUI

@main
struct RegistaApp: App {
    @StateObject private var app: AppState
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Prefs.registerDefaults()
        NSWindow.allowsAutomaticWindowTabbing = false   // the project tabs are the app's own
        Ed.registerFonts()
        _app = StateObject(wrappedValue: AppState())
    }

    var body: some Scene {
        Window("Regista", id: "main") {  // l10n-ignore — the app's name
            ActiveTab(bench: app.bench) { app.inject(EditorRoot(), store: $0) }
                .frame(minWidth: 1024, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { EditorCommands(bench: app.bench, recents: app.bench.recents, recorder: app.recorder) }
        Settings {
            ActiveTab(bench: app.bench) { app.inject(SettingsView(), store: $0) }
        }
    }
}

/// The view built on the tab on screen, rebuilt when another tab is selected (S2 #76).
struct ActiveTab<Content: View>: View {
    @ObservedObject var bench: Workbench
    @ViewBuilder let content: (EditorStore) -> Content

    var body: some View { content(bench.active) }
}

/// ⌘Q with unsaved tabs asks once, listing them (S2 #76).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var bench: Workbench?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let bench = Self.bench, !bench.unsaved.isEmpty else { return .terminateNow }
            Task { @MainActor in sender.reply(toApplicationShouldTerminate: await bench.confirmQuit()) }
            return .terminateLater
        }
    }
}

/// Menu items: each one is a command (or a dialog that ends in one), on the tab on screen.
struct EditorCommands: Commands {
    @ObservedObject var bench: Workbench
    @ObservedObject var recents: RecentProjects
    @ObservedObject var recorder: Recorder

    private var store: EditorStore { bench.active }

    /// ⇧⌘R from any screen: starting a take switches to Registra first; stopping leaves the screen as it is. A recording
    /// belongs to the tab it was started from: another tab cannot start or stop it (it says why).
    @MainActor static func toggleRecording(_ store: EditorStore, _ recorder: Recorder) {
        if let why = store.bench.recordingRefusal(for: store) { store.errorMessage = why; return }
        if recorder.isRecording { recorder.stop(); return }
        if store.workspace != .record { store.select(.record) }
        Task {
            await recorder.prepare()
            recorder.start()
        }
    }

    /// The standard About panel with the build (git sha, dirty flag, date) that scripts/build-app.sh wrote into
    /// Info.plist, e.g. "Version 0.2.0 (3551262-dirty.3267e1 · 2026-11-12 14:03 UTC)".
    @MainActor static func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let id = info["RegistaBuildID"] as? String ?? BuildStamp.current.id
        let build = [id, info["RegistaBuildDate"] as? String].compactMap { $0 }.joined(separator: " · ")
        NSApp.orderFrontStandardAboutPanel(options: [.version: build])
        NSApp.activate()
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("Informazioni su Regista") { Self.showAbout() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Nuovo progetto…") { Panels.newProject(store) }.shortcut(AppShortcuts.newProject)
            Button("Nuova scheda") { bench.openNewTab() }.shortcut(AppShortcuts.newTab)
            Button("Apri progetto…") { Panels.openProject(store) }.shortcut(AppShortcuts.openProject)
            Menu("Apri recente") {
                ForEach(recents.urls, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { store.openProject(url) }
                }
                if !recents.urls.isEmpty { Divider() }
                Button("Cancella elenco") { recents.clear() }.disabled(recents.urls.isEmpty)
            }
            Divider()
            Button("Importa media…") { Panels.importMedia(store) }.shortcut(AppShortcuts.importMedia)
        }
        CommandGroup(replacing: .saveItem) {
            // ⌘W closes the tab on screen; another window in front (Settings, a sheet's window) closes as usual.
            Button("Chiudi la scheda") {
                if let w = NSApp.keyWindow, let main = bench.window, w !== main { return w.performClose(nil) }
                let s = store
                Task { await bench.close(s) }
            }
            .shortcut(AppShortcuts.closeTab)
            Button("Salva") { Panels.save(store) }.shortcut(AppShortcuts.save)
            Button("Salva con nome…") { Panels.saveAs(store) }.shortcut(AppShortcuts.saveAs)
        }
        CommandGroup(replacing: .undoRedo) {
            // #65: "menu.undo", not "Annulla" (Cancel in a dialog): one Italian word, two meanings elsewhere.
            Button(loc("menu.undo")) {
                if let t = NSApp.keyWindow?.firstResponder as? NSTextView { t.undoManager?.undo() } else { store.undo() }
            }
            .shortcut(AppShortcuts.undo)
            Button(loc("menu.redo")) {
                if let t = NSApp.keyWindow?.firstResponder as? NSTextView { t.undoManager?.redo() } else { store.redo() }
            }
            .shortcut(AppShortcuts.redo)
        }
        CommandMenu("Montaggio") {
            Button("Taglia al cursore") { store.cutAtPlayhead() }.shortcut(AppShortcuts.cut)
            Button("Montaggio automatico") { store.autoEdit(script: TeleprompterController.shared.text) }
                .shortcut(AppShortcuts.autoEdit)
            Button("Genera sottotitoli") { store.run("captions.generate", ["style": "talking-head-v1"]) }
            Divider()
            Button("Adatta la timeline") { store.zoomToFit() }
        }
        CommandMenu("Registra") {
            Button(loc(recorder.isRecording ? "Ferma registrazione" : "Avvia registrazione")) { Self.toggleRecording(store, recorder) }
                .shortcut(AppShortcuts.record)
            Button(loc(recorder.isPaused ? "Riprendi" : "Pausa")) { recorder.togglePause() }
                .shortcut(AppShortcuts.pause)
                .disabled(!recorder.isRecording || !recorder.canPause)
        }
        CommandMenu("Vista") {
            // The activity bar, top to bottom: ⌘1…⌘9.
            ForEach(Array(Navigation.Activity.allCases.enumerated()), id: \.element) { i, a in
                Button(ActivityInfo.of(a).title) { store.select(a) }.shortcut(AppShortcuts.activity(i, title: ActivityInfo.of(a).title))
            }
            Divider()
            Button("Monta — Semplice") { store.workspace = .quick }.shortcut(AppShortcuts.simple)
            Button("Monta — Pro") { store.workspace = .pro }.shortcut(AppShortcuts.pro)
            Divider()
            Button("Scheda successiva") { bench.selectNext(1) }.shortcut(AppShortcuts.nextTab)
            Button("Scheda precedente") { bench.selectNext(-1) }.shortcut(AppShortcuts.previousTab)
            Button("Scheda successiva") { bench.selectNext(1) }.shortcut(AppShortcuts.nextTabAlt)
            Button("Scheda precedente") { bench.selectNext(-1) }.shortcut(AppShortcuts.previousTabAlt)
            Divider()
            Button("Mostra o nascondi il pannello laterale") { ShellPrefs.toggle(ShellPrefs.sideShown) }
                .shortcut(AppShortcuts.sidePanel)
            Button("Mostra o nascondi il pannello destro") { ShellPrefs.toggle(ShellPrefs.rightShown) }
                .shortcut(AppShortcuts.rightPanel)
            Divider()
            Button("Zone di sicurezza") { store.safeZones.toggle() }
            // The Marca picker lives on the editor's toolbar: go to the editor, then open it.
            Button("Brand kit…") {
                if !store.nav.inEditor { store.showEditor() }
                store.showBrandKits = true
            }.shortcut(AppShortcuts.brandKit)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    /// The open projects, one tab each (S2 #76).
    let bench = Workbench()
    let meter = LoudnessMeter()
    let recorder = Recorder()

    private var bag: Set<AnyCancellable> = []
    /// Subscriptions to the tab on screen, renewed when another tab is selected.
    private var activeBag: Set<AnyCancellable> = []

    /// The tab on screen.
    var store: EditorStore { bench.active }

    init() {
        AppDelegate.bench = bench
        bench.recorder = recorder
        // Every tab's UI host renders that tab with the app's environment.
        bench.onNewTab = { [unowned self] tab in
            tab.ui.makeRoot = { [unowned self, weak tab] nav in
                guard let tab else { return AnyView(EmptyView()) }
                return AnyView(self.inject(EditorRoot(live: false), store: tab).environment(\.navOverride, nav))
            }
            tab.ui.makeRootFor = { [unowned self] other, nav in
                AnyView(self.inject(EditorRoot(live: false), store: other).environment(\.navOverride, nav))
            }
            tab.ui.makeView = { [unowned self, weak tab] view in
                guard let tab else { return view }
                return AnyView(self.inject(view, store: tab))
            }
            tab.ui.recorder = self.recorder
        }
        bench.restoreTabs()
        bench.$activeID.removeDuplicates().sink { [unowned self] id in
            DispatchQueue.main.async { self.follow(self.bench.tab(id) ?? self.bench.active) }
        }
        .store(in: &bag)
        TeleprompterController.shared.recorder = recorder
        startPrompterDemoIfRequested()
        DebugSnapshots.startIfRequested()
        AutoSave.start(bench)
        // A recording belongs to the tab it was started from (the one on screen then).
        recorder.$isRecording.removeDuplicates().dropFirst().sink { [unowned self] on in
            DispatchQueue.main.async { if on { self.bench.recordingStarted() } else { self.bench.recordingStopped() } }
        }
        .store(in: &bag)
        // The teleprompter's live take markers are written next to the recording before it is imported, in its tab.
        recorder.onSessionFinished = { [weak self] url in
            Task { @MainActor in
                await TeleprompterController.shared.saveTakes(for: url.deletingLastPathComponent())
                self?.bench.recordingTarget(newProject: true).importSession(url)
            }
        }
        recorder.onFinished = { [weak self] url in
            Task { @MainActor in
                await TeleprompterController.shared.saveTakes(for: url)
                guard let self else { return }
                let tab = self.bench.recordingTarget(newProject: false)
                tab.importRecording(url)
                if Prefs.autoEdit { tab.autoEdit(script: TeleprompterController.shared.text) }
            }
        }
    }

    /// The loudness meter and the teleprompter follow the tab on screen.
    private func follow(_ store: EditorStore) {
        activeBag = []
        // The loudness curve follows every edit and every decoded source, whatever is on screen.
        store.$project.combineLatest(store.media.$revision)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [unowned self, weak store] project, _ in if let store { meter.update(project, cache: store.media) } }
            .store(in: &activeBag)
        // A script prepared by the agent (script.prepare / script.set) goes straight to the teleprompter.
        store.$project.map { $0?.script?.prompt }.removeDuplicates().compactMap { $0 }
            .sink { prompt in
                let p = TeleprompterController.shared
                if p.text != prompt { p.text = prompt }
            }
            .store(in: &activeBag)
    }
}

extension AppState {
    /// Developer flag: `--prompter-demo <script.txt>` opens the teleprompter already listening,
    /// visible to screenshots (normally it is hidden from screen capture). Used to test voice following.
    private func startPrompterDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--prompter-demo") else { return }
        let p = TeleprompterController.shared
        if i + 1 < args.count, let script = try? String(contentsOfFile: args[i + 1], encoding: .utf8) {
            p.text = script
        }
        p.capturableForTesting = true
        p.mode = .voice
        DispatchQueue.main.async {
            p.restart()
            p.show()
            p.play()
        }
    }
}

extension AppState {
    /// The environment every editor view expects, on the tab `store`.
    func inject<V: View>(_ view: V, store: EditorStore) -> some View {
        view
            .environmentObject(self)
            .environmentObject(store)
            .environmentObject(store.preview)
            .environmentObject(store.preview.playhead)
            .environmentObject(store.media)
            .environmentObject(meter)
            .environmentObject(recorder)
    }
}
