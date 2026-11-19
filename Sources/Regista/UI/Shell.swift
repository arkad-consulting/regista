import AppKit
import RegistaCore
import SwiftUI

/// The navigation an offscreen ui.screenshot render shows instead of the store's (activity, level, tabs).
private struct NavOverrideKey: EnvironmentKey { static let defaultValue: Navigation? = nil }
/// The side panel's width, for content that lays itself out to it (Registra's display picker).
private struct SidePanelWidthKey: EnvironmentKey { static let defaultValue: CGFloat = Chrome.sideDefault }

extension EnvironmentValues {
    var navOverride: Navigation? {
        get { self[NavOverrideKey.self] }
        set { self[NavOverrideKey.self] = newValue }
    }
    var sidePanelWidth: CGFloat {
        get { self[SidePanelWidthKey.self] }
        set { self[SidePanelWidthKey.self] = newValue }
    }
}

/// The window shell's sizes (S1 #75, approved design A). Its colours and fonts are design tokens (`Ed`, Tokens.swift).
enum Chrome {
    /// The title row in a render (the live window has no title row: its band is the native toolbar macOS lays out,
    /// WindowChrome, and a render draws it at that measured height).
    static let titleHeight: CGFloat = 40
    static let activityWidth: CGFloat = 52
    static let rightWidth: CGFloat = 320
    static let statusHeight: CGFloat = 24
    static let tabsHeight: CGFloat = 36
    static let headerHeight: CGFloat = 38
    static let toolbarHeight: CGFloat = 40
    static let sideDefault: CGFloat = 300

    /// The side panel's width range in a window `width` wide.
    static func sideRange(_ width: CGFloat) -> ClosedRange<CGFloat> { SplitSize.range(240, min(440, width * 0.3)) }
}

/// The single editor window, VS Code's layout in macOS materials: title row; activity bar · side panel · main area
/// (project tabs on top) · right panel; status bar.
struct EditorRoot: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.navOverride) private var navOverride
    @AppStorage(Accent.followKey) private var accentFollows = false
    @AppStorage(ShellPrefs.sideShown) private var sideShown = true
    @AppStorage(ShellPrefs.rightShown) private var rightShown = true
    @AppStorage(ShellPrefs.sideWidth) private var sideWidth = SplitSize.automatic
    /// false for the offscreen copy rendered by ui.screenshot (it always shows both panels).
    var live = true

    var body: some View {
        // The accent (Arkad gold, or the active kit's): a change rebuilds the tree so every view picks it up.
        let accent = Accent.resolve(kit: store.project?.brand, follow: accentFollows)
        Accent.set(accent)
        // Another tab on screen is another document: the tree is rebuilt on its store (players, caches, selection).
        return content.id(accent).id(store.tabID)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // The live window's top band is the native toolbar (traffic lights, Claude's status, the panel toggles):
            // the content starts right under it. A render has no window, so it draws the same band as a title row.
            if !live { TitleRow() }
            GeometryReader { g in
                let range = Chrome.sideRange(g.size.width)
                let side = SplitSize.resolve(sideWidth, automatic: Chrome.sideDefault, in: range)
                HStack(spacing: 0) {
                    ActivityBar()
                    if sideShown || !live {
                        // Above the main area (#33): a level wider than the main area overflows it, and `clipped` clips
                        // its drawing, not its hit testing: drawn first, the panels lost their clicks to the overflow.
                        // The panels keep the height they are given (#41): a tab taller than it scrolls, and anything
                        // still taller goes on below, clipped, never pushing the panel's header up.
                        SidePanel().frame(width: side, height: g.size.height, alignment: .top).clipped()
                            .environment(\.sidePanelWidth, side).zIndex(1)
                        Splitter(orientation: .vertical, stored: $sideWidth, current: side, range: range, thickness: 0)
                    }
                    MainArea().frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).clipped()
                    if rightShown || !live {
                        RightPanel().frame(width: Chrome.rightWidth, height: g.size.height, alignment: .top).clipped().zIndex(1)
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            .overlay(alignment: .top) { if live { Ed.rule.frame(height: 1) } }   // the toolbar band's hairline
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { if live { WindowChrome.shared.contentTop = $0 } }
            StatusBar()
        }
        .background(Ed.main, ignoresSafeAreaEdges: [])
        .background(Ed.bar)   // under the toolbar band
        .environment(\.colorScheme, .dark)
        .background(WindowAccessor { w in
            guard live else { return }
            store.bench.window = w
            WindowChrome.shared.track(w, items: AnyView(TitleBarItems(bench: store.bench)))
            w.backgroundColor = Ed.windowBackground
            w.appearance = NSAppearance(named: .darkAqua)   // the toolbar's controls in the shell's dark materials
            w.tabbingMode = .disallowed   // the project tabs are ours
            w.title = store.project?.name ?? "Regista"  // l10n-ignore
            TitleBarArea.installEdgeMonitor()
        })
        .onChange(of: store.project?.name) { _, name in if live { store.ui.window?.title = name ?? "Regista" } }  // l10n-ignore
        .onAppear { if live { KeyMonitor.install(store.bench) } }
        .sheet(isPresented: Binding(get: { live && store.pendingApproval != nil }, set: { if !$0 { store.pendingApproval = nil } })) {
            if let e = store.pendingApproval { ApprovalSheet(entry: e) }
        }
        .sheet(isPresented: Binding(get: { live && store.showVoiceSetup }, set: { store.showVoiceSetup = $0 })) {
            VoiceSetupSheet()
        }
        .alert("Comando non riuscito", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: store.errorMessage ?? "")
        }
    }
}

/// The shell's remembered choices (user defaults): which panels show and the side panel's width.
enum ShellPrefs {
    static let sideShown = "shell.sidePanel", rightShown = "shell.rightPanel", sideWidth = "shell.sideWidth"

    static func toggle(_ key: String) {
        let d = UserDefaults.standard
        d.set(!(d.object(forKey: key) as? Bool ?? true), forKey: key)
    }
}

// MARK: - Window chrome

/// The main window's title-bar chrome: one native band. The traffic lights are never moved by hand: the window gets a
/// unified compact toolbar, so macOS itself lays out a title bar of that height and centres the three buttons on it;
/// Claude's status and the two panel toggles are that toolbar's one item (macOS places, aligns and hit-tests them),
/// and the SwiftUI content starts under the toolbar (its safe area). Renders draw the band as `TitleRow`, at the
/// height macOS reports (`titleBar`). Tracks full screen and where the buttons are.
@MainActor
final class WindowChrome: ObservableObject {
    static let shared = WindowChrome()
    /// Right edge of the zoom button, in points from the window's left edge (measured; this is macOS's usual value).
    @Published private(set) var trafficLights: CGFloat = 69
    /// Height of the title bar macOS lays out (the title row's height), measured outside full screen.
    @Published private(set) var titleBar: CGFloat = Chrome.titleHeight
    @Published private(set) var fullScreen = false
    /// Where the content's first row (activity bar, side panel, project tabs, right panel) begins, in points from the
    /// top of the window's content view (set by the live EditorRoot; equals `titleBar` when there is one band).
    var contentTop: CGFloat?
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    /// `items`: the title row's controls, put in the toolbar the first time this window is seen.
    func track(_ w: NSWindow, items: AnyView? = nil) {
        if window !== w {
            window = w
            Self.configure(w, items: items.map { v in
                let host = NSHostingView(rootView: v)
                host.appearance = NSAppearance(named: .darkAqua)
                return host
            })
            let nc = NotificationCenter.default
            observers.forEach(nc.removeObserver)
            let on: (Notification.Name, @escaping @MainActor (WindowChrome) -> Void) -> NSObjectProtocol = { name, act in
                nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let self { act(self) } }
                }
            }
            observers = [
                on(NSWindow.willEnterFullScreenNotification) { $0.fullScreen = true },
                on(NSWindow.willExitFullScreenNotification) { $0.fullScreen = false },
                on(NSWindow.didExitFullScreenNotification) { $0.measure() },
                on(NSWindow.didEnterFullScreenNotification) { $0.measure() },
                on(NSWindow.didResizeNotification) { $0.measure() },
            ]
        }
        DispatchQueue.main.async { self.measure() }
    }

    /// The window's title bar: transparent, no title, and a unified compact toolbar holding `items` on the right
    /// (empty without them). macOS then lays out a taller title bar and centres the traffic lights on it, in their
    /// native place.
    static func configure(_ w: NSWindow, items: NSView? = nil) {
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        if w.toolbar == nil { w.toolbar = TitleBarToolbar(controls: items) }
        w.toolbarStyle = .unifiedCompact
    }

    private func measure() {
        guard let w = window else { return }
        let full = w.styleMask.contains(.fullScreen)
        if full != fullScreen { fullScreen = full }
        guard !full else { return }
        if let x = Self.trafficLightsEdge(w), abs(x - trafficLights) > 0.5 { trafficLights = x }
        let bar = Self.titleBarHeight(w)
        if bar > 0, abs(bar - titleBar) > 0.5 { titleBar = bar }
    }

    static func buttons(_ w: NSWindow) -> [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
    }

    /// The title bar macOS lays out: the part of the window above its content layout rect.
    static func titleBarHeight(_ w: NSWindow) -> CGFloat { (w.frame.height - w.contentLayoutRect.height).rounded() }

    /// The three buttons' frames: left edge and vertical centre from the window's top edge (they share one centre).
    static func trafficLightFrames(_ w: NSWindow) -> [(minX: CGFloat, midY: CGFloat)] {
        buttons(w).filter { $0.window != nil }.map { b in
            let r = b.convert(b.bounds, to: nil)
            return (r.minX, w.frame.height - r.midY)
        }
    }

    /// Right edge of the rightmost visible standard window button, in window coordinates.
    static func trafficLightsEdge(_ w: NSWindow) -> CGFloat? {
        let edges = buttons(w).filter { !$0.isHidden && $0.window != nil }.map { $0.convert($0.bounds, to: nil).maxX }
        return edges.max()
    }

    /// The toolbar item holding the title row's controls (nil in a bare window).
    static func titleItems(_ w: NSWindow) -> NSView? {
        (w.toolbar as? TitleBarToolbar)?.controls.flatMap { $0.window === w ? $0 : nil }
    }
}

/// The main window's toolbar: a flexible space, then the title row's controls as one item (none in a bare window).
final class TitleBarToolbar: NSToolbar, NSToolbarDelegate {
    static let itemsID = NSToolbarItem.Identifier("regista.titleItems")
    let controls: NSView?

    init(controls: NSView?) {
        self.controls = controls
        super.init(identifier: "regista.main")
        showsBaselineSeparator = false
        allowsUserCustomization = false
        displayMode = .iconOnly
        delegate = self
    }

    private var ids: [NSToolbarItem.Identifier] { controls == nil ? [] : [.flexibleSpace, Self.itemsID] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.itemsID, let controls else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = controls
        item.isBordered = false   // the controls draw their own backgrounds
        return item
    }
}

// MARK: - Title row

/// The top band as a render draws it (the live window's band is the native toolbar, WindowChrome): the traffic
/// lights' place, an empty drag area (double-click zooms, as macOS does), and on the right the title row's controls.
struct TitleRow: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var chrome = WindowChrome.shared

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            TitleBarItems(bench: store.bench)
        }
        .padding(.trailing, 10)
        .frame(height: chrome.titleBar)
        .background(TitleBarArea())
        .background(Ed.bar)
        .overlay(alignment: .bottom) { Ed.rule.frame(height: 1) }
    }
}

/// Claude's status and the two panel toggles: the live window's toolbar item, and the right end of a render's title row.
struct TitleBarItems: View {
    /// The workbench (the toolbar item outlives any one tab).
    let bench: Workbench
    @AppStorage(ShellPrefs.sideShown) private var sideShown = true
    @AppStorage(ShellPrefs.rightShown) private var rightShown = true

    var body: some View {
        HStack(spacing: 6) {
            ClaudeStatus(bench: bench)
            Color.clear.frame(width: 4, height: 1)
            IconButton(symbol: "sidebar.left", help: sideShown ? "Nascondi il pannello laterale" : "Mostra il pannello laterale",
                       shortcut: "⌃⌘S", chrome: true, dimmed: !sideShown) { ShellPrefs.toggle(ShellPrefs.sideShown) }
            IconButton(symbol: "sidebar.right", help: rightShown ? "Nascondi il pannello destro" : "Mostra il pannello destro",
                       shortcut: "⌥⌘I", chrome: true, dimmed: !rightShown) { ShellPrefs.toggle(ShellPrefs.rightShown) }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// "● Claude collegato": a click opens the Claude tab of the right panel. Follows the agent in every tab.
struct ClaudeStatus: View {
    @ObservedObject var bench: Workbench
    @State private var hover = false

    enum Status: CaseIterable { case disconnected, connected, working }

    var body: some View {
        let store = bench
        let last = store.activity.last
        let status: Status = !store.agentConnected ? .disconnected
            : (last?.isAgent == true && last?.status == .running ? .working : .connected)
        Button {
            store.nav.rightTab = .claude
            UserDefaults.standard.set(true, forKey: ShellPrefs.rightShown)
        } label: {
            ClaudeStatusLabel(name: store.agentName, status: status, warning: store.agentBuildMismatch != nil, hover: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tip(store.socketProblem ?? store.agentBuildMismatch.map { Self.buildNotice($0) } ?? "Claude Code si collega da solo all'app aperta (server MCP regista)")
    }

    /// The app and the connected regista-mcp come from different builds (#45): which one to rebuild. Italian keys,
    /// localized by `.tip` (English in en.lproj).
    /// A release build (#113) says what a downloaded app can do instead (ReleaseWords).
    static func buildNotice(_ m: BuildStamp.Mismatch, bundle: Bundle = .main) -> String {
        ReleaseWords.pick(sourceNotice(m), bundle: bundle)
    }

    private static func sourceNotice(_ m: BuildStamp.Mismatch) -> String {
        switch m {
        case .rebuildApp: return "Questa app è più vecchia del server MCP collegato: chiudi Regista, esegui scripts/build-app.sh --install e riaprila."
        case .rebuildMCP: return "Il server MCP collegato è più vecchio di questa app: esegui scripts/build-mcp.sh e riavvia la sessione di Claude."
        case .rebuildBoth: return "Questa app e il server MCP collegato vengono da build diverse: esegui scripts/build-app.sh --install, riapri Regista e riavvia la sessione di Claude."
        }
    }
}

struct ClaudeStatusLabel: View {
    let name: String
    let status: ClaudeStatus.Status
    var warning = false
    var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status == .disconnected ? Ed.text4 : (status == .working ? Ed.gold : Ed.online))
                .frame(width: 7, height: 7)
            Text(verbatim: "\(name) " + (status == .working ? loc("al lavoro") : status == .connected ? loc("collegato") : loc("non collegato")))
                .font(Ed.ui(Ed.TypeSize.body))
                .foregroundStyle(status == .disconnected ? Ed.text3 : Ed.text2)
                .lineLimit(1)
                .fixedSize()
            if warning {
                Image(systemName: "exclamationmark.triangle.fill").font(Ed.icon(Ed.TypeSize.caption)).foregroundStyle(Ed.gold)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.m, style: .continuous).fill(hover ? Ed.controlOn.opacity(0.6) : Ed.control))
    }
}

// MARK: - Activity bar

/// What an activity is called and drawn with.
struct ActivityInfo {
    let title: String
    let symbol: String
    let tip: String

    static func of(_ a: Navigation.Activity) -> ActivityInfo {
        switch a {
        case .home: ActivityInfo(title: loc("Inizio"), symbol: "house", tip: "Inizio: cosa vuoi fare e progetti recenti")
        case .record: ActivityInfo(title: loc("Registra"), symbol: "record.circle", tip: "Registra schermo, camera, microfono e gobbo")
        case .media: ActivityInfo(title: loc("Media"), symbol: "film", tip: "Media: i file del progetto")
        case .texts: ActivityInfo(title: loc("Testi e sottotitoli"), symbol: "captions.bubble", tip: "Testi e sottotitoli: sottotitoli, copione, trascrizione e riprese")
        case .audio: ActivityInfo(title: loc("Audio"), symbol: "waveform", tip: "Audio: volume, voce pulita e musica")
        case .voice: ActivityInfo(title: loc("Voce"), symbol: "mic", tip: "Voce: dal testo alla voce fuori campo, con la tua voce clonata")
        case .graphics: ActivityInfo(title: loc("Grafica"), symbol: "sparkles", tip: "Grafica: filtri, effetti, stili e marca")
        case .generate: ActivityInfo(title: loc("Genera"), symbol: "wand.and.rays", tip: "Genera immagini, clip e musica")
        case .export: ActivityInfo(title: loc("Esporta"), symbol: "square.and.arrow.up", tip: "Esporta il video, i sottotitoli o il progetto")
        }
    }
}

/// Icons only, one active at a time (a gold marker on the left edge); Motori and Impostazioni at the bottom.
struct ActivityBar: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.navOverride) private var navOverride
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let active = (navOverride ?? store.nav).activity
        VStack(spacing: Ed.Space.xs) {
            ForEach(Navigation.Activity.allCases) { a in
                let i = ActivityInfo.of(a)
                ActivityButton(symbol: i.symbol, active: active == a, tip: i.tip, shortcut: a.shortcut, label: i.title) { store.select(a) }
            }
            Spacer(minLength: Ed.Space.s)
            ActivityButton(symbol: "cpu", active: false, tip: "Motori: RAM, livello e motori installati",
                           shortcut: nil, label: loc("Motori")) { SettingsRoute.open(.engines, with: openSettings) }
            ActivityButton(symbol: "gearshape", active: false, tip: "Impostazioni", shortcut: "⌘,", label: loc("Impostazioni")) { openSettings() }
        }
        .padding(.vertical, 10)
        .frame(width: Chrome.activityWidth)
        .frame(maxHeight: .infinity)
        .background(Ed.bar)
        .overlay(alignment: .trailing) { Ed.rule.frame(width: 1) }
    }
}

struct ActivityButton: View {
    let symbol: String
    let active: Bool
    let tip: String
    let shortcut: String?
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Ed.icon(Ed.TypeSize.heading, .regular))
                .foregroundStyle(active ? Ed.text : (hover ? Ed.text2 : Ed.text3))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(active ? Ed.control : (hover ? Ed.control.opacity(0.55) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Chrome.activityWidth)
        .overlay(alignment: .leading) {
            // The marker hugs the bar's left edge, as in VS Code.
            UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 2, topTrailing: 2))
                .fill(Ed.gold)
                .frame(width: 3, height: 22)
                .opacity(active ? 1 : 0)
        }
        .onHover { hover = $0 }
        .tip(tip, shortcut: shortcut)
        .accessibilityLabel(Text(verbatim: loc(label)))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Status bar

/// RAM and tier, the loudness of the edit when known, the command running (in words), a hint, the save state.
struct StatusBar: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var meter: LoudnessMeter
    @EnvironmentObject private var recorder: Recorder
    @Environment(\.navOverride) private var navOverride

    private var nav: Navigation { navOverride ?? store.nav }

    private var hint: String {
        switch nav.workspace {
        case .home: return loc("⌘1…⌘9 cambiano attività · ⌘N nuovo progetto · ⌘O apri")
        case .pro:
            switch store.tool {
            case .select: return loc("Clic per selezionare, trascina per spostare, trascina i bordi per rifilare. ⌫ elimina, ⇧⌫ elimina e chiude il vuoto. ⌘K taglia al cursore.")
            case .razor: return loc("Lama: clic su una clip per tagliarla in quel punto.")
            case .text: return loc("Testo: clic su una parola dei sottotitoli per metterla (o toglierla) tra le parole chiave.")
            case .hand: return loc("Mano: trascina per scorrere la timeline.")
            }
        case .simple: return loc("Spazio avvia/pausa · un passo alla volta, a sinistra · ⌥⌘2 livello Pro")
        case .export: return loc("L'export usa lo stesso compositore dell'anteprima: quello che vedi è quello che esce.")
        case .record: return loc("⇧⌘R registra/stop · ⇧⌘P pausa · ⌥Spazio avvia/pausa il gobbo")
        }
    }

    var body: some View {
        HStack(spacing: Ed.Space.l) {
            if let s = store.engineSummary {
                Text(verbatim: String(format: loc("Mac %d GB · livello %@"), s.memoryGB, Self.tierName(s.tier))).fixedSize()
            }
            if store.project != nil, let l = Self.loudness(meter.curve) {
                Text(verbatim: l).fixedSize()
            }
            if let r = store.running, !store.jobs.jobs.contains(where: \.isRunning) {   // a job says it better (jobs item)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: CommandTitles.title(r)).foregroundStyle(Ed.text2).fixedSize()
                }
            }
            Text(verbatim: hint).foregroundStyle(Ed.text4).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            Spacer(minLength: Ed.Space.s)
            JobsStatusItem()   // long work of every tab: progress, Cancel, errors (E2 #54)
            if recorder.isRecording {
                HStack(spacing: 5) {
                    // A paused take says so, in the colour of the preview's paused pill (#65).
                    Circle().fill(recorder.isPaused ? Ed.warn : Ed.danger).frame(width: 6, height: 6)
                    Text(verbatim: String(format: loc(recorder.isPaused ? "In pausa · %@" : "Registrazione %@"), timecode(recorder.elapsed))).fixedSize()
                }
            }
            if let save = saveState {
                Text(verbatim: save).fixedSize()
            }
        }
        .font(Ed.ui(Ed.TypeSize.small))
        .foregroundStyle(Ed.text3)
        .padding(.horizontal, Ed.Space.m)
        .frame(height: Chrome.statusHeight)
        .background(Ed.bar)
        .overlay(alignment: .top) { Ed.rule.frame(height: 1) }
    }

    private var saveState: String? {
        guard store.project != nil else { return nil }
        if store.projectURL == nil { return loc("Non ancora salvato") }
        return store.dirty ? loc("Modifiche non salvate") : loc("Salvato")
    }

    static func tierName(_ tier: String) -> String {
        switch tier {
        case "base": loc("Base")
        case "medium": loc("Medio")
        case "pro": loc("Pro")
        default: tier
        }
    }

    /// "−14,9 LUFS · picco −0,2 dB" (nil before the edit was measured).
    static func loudness(_ c: LoudnessCurve) -> String? {
        guard c.integrated.isFinite else { return nil }
        let f = { (v: Double) in v.formatted(.number.precision(.fractionLength(1))).replacingOccurrences(of: "-", with: "−") }
        return c.truePeak.isFinite ? String(format: loc("%@ LUFS · picco %@ dB"), f(c.integrated), f(c.truePeak)) : "\(f(c.integrated)) LUFS"
    }
}

// MARK: - Keyboard

/// Editor shortcuts that are not menu items: transport (Space, J K L, arrows), tools (V C T H),
/// delete, zoom, ⌘C / ⌘V / ⌘D on clips. Ignored while typing in a text field and on the Inizio and Registra screens.
@MainActor
enum KeyMonitor {
    private static var token: Any?
    /// The workbench whose window takes the keys (the last one installed: one in the app, one per test).
    private static weak var bench: Workbench?

    /// The keys go to the tab on screen.
    static func install(_ bench: Workbench) {
        self.bench = bench
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                guard let store = KeyMonitor.bench?.active, handle(event, store) else { return event }
                return nil
            }
        }
    }

    private static func handle(_ e: NSEvent, _ store: EditorStore) -> Bool {
        guard let window = store.ui.window, e.window === window, store.workspace != .record, store.workspace != .home else { return false }
        if window.firstResponder is NSText { return false }
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let p = store.preview
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, key == "k" { store.cutAtPlayhead(); return true }
        // Clips: copy, paste at the playhead, duplicate (timeline.duplicate); with nothing to act on the keys go on.
        if flags == .command, store.nav.inEditor {
            if key == "c", store.copySelection() { return true }
            if key == "v", store.pasteAtPlayhead() { return true }
            if key == "d", store.duplicateSelection() { return true }
        }
        guard flags.isSubset(of: [.shift]) else { return false }
        // A caption or graphic selected on the preview: arrows nudge it (⇧ = 10 px), Esc lets go of it.
        if store.handleCanvasKey(e.keyCode, shift: flags.contains(.shift)) { return true }
        switch (e.keyCode, key) {
        case (49, _): p.togglePlay()                                   // space
        case (_, "j"): p.shuttle(-1)
        case (_, "k"): p.shuttle(0)
        case (_, "l"): p.shuttle(1)
        case (123, _): p.step(frames: flags.contains(.shift) ? -30 : -1)   // ←
        case (124, _): p.step(frames: flags.contains(.shift) ? 30 : 1)     // →
        case (115, _): p.seek(0)                                       // home
        case (119, _): p.seek(p.duration)                              // end
        case (51, _), (117, _): store.deleteSelection(ripple: flags.contains(.shift))   // ⌫, ⌦
        case (_, "v"): store.tool = .select
        case (_, "c"): store.tool = .razor
        case (_, "t"): store.tool = .text
        case (_, "h"): store.tool = .hand
        case (_, "="), (_, "+"): store.zoom(by: 1.5)
        case (_, "-"): store.zoom(by: 1 / 1.5)
        case (_, "\\"): store.zoomToFit()
        default: return false
        }
        return true
    }
}


// MARK: - Paid generation approval

/// Confirmation sheet for a paid generation (Higgsfield): what will be generated, with which model, for how many
/// credits, and how many paid calls are left. Only here (or `regista-engine exec generate.approve` in a terminal)
/// can a paid run be approved: the agent cannot approve its own spending.
struct ApprovalSheet: View {
    @EnvironmentObject private var store: EditorStore
    let entry: GenerationApprovals.Entry

    private var remaining: Int {
        (try? GenerationBudget(directory: store.generationState).remaining(entry.estimate.provider)) ?? 0
    }

    var body: some View {
        let e = entry.estimate
        VStack(alignment: .leading, spacing: 14) {
            Text("Generazione a pagamento").font(Ed.display(Ed.TypeSize.heading, .semibold)).foregroundStyle(Ed.text)
            Text(verbatim: loc("%@ chiede di generare con %@. Approva solo lo scatto finale: per le prove c'è ComfyUI, gratis.",
                               store.agentName, e.provider.capitalized))
                .font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                row("Modello", e.model)
                row("Tipo", e.kind == .video ? loc("clip video") : e.kind == .image ? loc("immagine") : e.kind.rawValue)
                row("Costo", loc("%@ crediti", String(format: "%g", e.credits)))
                row("Budget", remaining == 1 ? loc("resta 1 chiamata su %@", String(cap(e.provider)))
                                             : loc("restano %@ chiamate su %@", String(remaining), String(cap(e.provider))))
            }
            Text("Prompt").font(Ed.ui(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.text3)
            ScrollView {
                Text(verbatim: e.prompt).font(Ed.mono(Ed.TypeSize.small)).foregroundStyle(Ed.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(height: 110)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(Ed.well))
            HStack {
                Spacer()
                EdButton(title: "Rifiuta") { store.decideApproval(approve: false) }
                EdButton(title: loc("Approva e spendi %@ crediti", String(format: "%g", e.credits)), prominent: true, disabled: remaining == 0) {
                    store.decideApproval(approve: true)
                }
            }
            if remaining == 0 {
                Text("Budget esaurito: nessuna altra chiamata a pagamento.").font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.danger)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Ed.panel)
    }

    private func cap(_ provider: String) -> Int { GenerationBudget.hardCaps[provider] ?? 0 }

    /// `label` is a key; `value` is already in words.
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: loc(label)).font(Ed.ui(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.text3).frame(width: 80, alignment: .leading)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(verbatim: value).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text)
        }
    }
}
