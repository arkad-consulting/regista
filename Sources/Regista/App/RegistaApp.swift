import Combine
import struct RegistaCore.BuildStamp
import enum RegistaCore.EngineScripts
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
                // A copy opened outside an Applications folder offers to move itself there (#110).
                .movePrompt(app.movePrompt)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { EditorCommands(bench: app.bench, recents: app.bench.recents, recorder: app.recorder) }
        Settings {
            ActiveTab(bench: app.bench) { app.inject(SettingsView(), store: $0) }
        }
        // The guides, offline and in the app's language (K1 #7): Aiuto › Guida di Regista and the others.
        Window(Text(loc("Aiuto")), id: HelpCenter.windowID) {
            HelpView(center: HelpCenter.shared)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: HelpView.size.width, height: HelpView.size.height)
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

/// The menu bar: the items of `MenuCommands.all` (each one a command, or a dialog that ends in one, on the tab on screen).
struct EditorCommands: Commands {
    @ObservedObject var bench: Workbench
    @ObservedObject var recents: RecentProjects
    @ObservedObject var recorder: Recorder
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

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

    /// The ways out of the main window the scene gives, and what the items act on.
    private var context: MenuContext {
        MenuContext(bench: bench, recents: recents, recorder: recorder,
                    openGuide: { [openWindow] g in HelpCenter.open(g, with: openWindow) },
                    openShortcuts: { [openSettings] in SettingsRoute.open(.shortcuts, with: openSettings) })
    }

    // Drawn from the one table of the app's commands (#36): `MenuCommands.all`, which the tests run on the live model.
    var body: some Commands {
        let items = MenuCommands.all(context)
        CommandGroup(replacing: .appInfo) { MenuItems(items, .appInfo) }
        CommandGroup(replacing: .newItem) { MenuItems(items, .newItem) }
        CommandGroup(replacing: .saveItem) { MenuItems(items, .saveItem) }
        CommandGroup(replacing: .undoRedo) { MenuItems(items, .undoRedo) }
        CommandMenu("Montaggio") { MenuItems(items, .editing) }
        CommandMenu("Registra") { MenuItems(items, .record) }
        CommandMenu("Vista") { MenuItems(items, .view) }
        // The standard Help menu (Aiuto / Help / Aide / Ajuda).
        CommandGroup(replacing: .help) { MenuItems(items, .help) }
    }
}

@MainActor
final class AppState: ObservableObject {
    /// The open projects, one tab each (S2 #76).
    let bench = Workbench()
    let meter = LoudnessMeter()
    let recorder = Recorder()
    /// The launch alert of a copy outside an Applications folder (#110): nil location everywhere else.
    let movePrompt = MovePrompt()

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
        // A sample of the app when its main thread stops answering for 2 s (#161), kept on this Mac.
        HangLog.watchdog.start()
        bench.follow(recorder).store(in: &bag)
        // An engines folder installed by an older app gets this app's helper scripts (#61), off the main thread.
        Task.detached(priority: .utility) { EngineScripts.refresh() }
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
