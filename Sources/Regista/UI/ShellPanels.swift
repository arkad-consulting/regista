import AppKit
import RegistaCore
import SwiftUI

// The window shell's panels (S1 #75): the side panel of each activity, the main area with the project tabs, the
// editor toolbar, and the right panel (Gobbo · Claude · Ispettore), the same on every activity.

// MARK: - Side panel

/// The active activity's content under its title ("MEDIA", "REGISTRA" …).
struct SidePanel: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.navOverride) private var navOverride

    private var nav: Navigation { navOverride ?? store.nav }

    var body: some View {
        let a = nav.activity
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SectionLabel(ActivityInfo.of(a).title)
                Spacer(minLength: 4)
                trailing(a)
            }
            .padding(.horizontal, 14)
            .frame(height: Chrome.headerHeight)
            .overlay(alignment: .bottom) { Ed.rule2.frame(height: 1) }
            content(a).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Ed.side)
        .overlay(alignment: .trailing) { Ed.rule.frame(width: 1) }
    }

    @ViewBuilder private func trailing(_ a: Navigation.Activity) -> some View {
        switch a {
        case .media: AccentLinkButton(title: loc("Importa…"), tip: "Importa video, audio o immagini nel progetto", shortcut: "⌘I") { Panels.importMedia(store) }
        default: EmptyView()
        }
    }

    @ViewBuilder private func content(_ a: Navigation.Activity) -> some View {
        switch a {
        case .home: HomeSide()
        case .record: RecordView(part: .controls)
        case .media: MediaTab()
        case .texts: TextsPanel(tab: nav.textsTab)
        case .audio: AudioPanel(tab: nav.soundTab)
        case .voice: VoiceTab()
        case .graphics: GraphicsPanel(section: nav.graphicsSection)
        case .generate: GeneratePanel()
        case .export: ExportSettingsPanel()
        }
    }
}

/// Inizio's side panel: the ways to start a project and the recent projects by name.
struct HomeSide: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View { Content(recents: store.recents) }

    private struct Content: View {
        @EnvironmentObject private var store: EditorStore
        @ObservedObject var recents: RecentProjects

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SideRow(symbol: "plus.square", title: loc("Nuovo progetto…"), detail: "⌘N") { Panels.newProject(store) }
                    SideRow(symbol: "folder", title: loc("Apri progetto…"), detail: "⌘O") { Panels.openProject(store) }
                    SideRow(symbol: "square.and.arrow.down", title: loc("Importa media…"), detail: "⌘I") { Panels.importMedia(store, newProject: true) }
                    SectionLabel("RECENTI")
                        .padding(.horizontal, 8).padding(.top, 18).padding(.bottom, 4)
                    if recents.infos.isEmpty {
                        Text(verbatim: loc("Nessun progetto recente")).font(Ed.ui(12)).foregroundStyle(Ed.text4).padding(.horizontal, 8)
                    }
                    ForEach(recents.infos) { info in
                        let open = store.projectURL?.standardizedFileURL.path == info.path
                        SideRow(symbol: open ? "film.fill" : "film", title: info.name, detail: info.duration > 0 ? clockTime(info.duration) : nil, on: open) {
                            store.openProject(URL(fileURLWithPath: info.path, isDirectory: true))
                        }
                    }
                }
                .padding(8)
            }
        }
    }
}

/// One row of a side list: symbol, title, a dim detail on the right.
struct SideRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var on = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(Ed.icon(12)).foregroundStyle(on ? Ed.gold : Ed.text3).frame(width: 18)
                Text(verbatim: loc(title)).font(Ed.ui(13)).foregroundStyle(Ed.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let detail { Text(verbatim: detail).font(Ed.ui(11)).foregroundStyle(Ed.text4).fixedSize() }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Ed.control : (hover ? Ed.control.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// "0:49", "1:02:05".
func clockTime(_ seconds: Double) -> String {
    let s = Int(max(0, seconds).rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Testi e sottotitoli: the steps from a clip to captions (E2 #54), captions and script, the transcript following the
/// playhead, the takes of each script line.
struct TextsPanel: View {
    @EnvironmentObject private var store: EditorStore
    let tab: Navigation.TextsTab

    var body: some View {
        VStack(spacing: 0) {
            RSegmented(items: [(.steps, "Passi"), (.captions, "Sottotitoli"), (.transcript, "Trascrizione"), (.takes, "Riprese")],
                       selection: Binding(get: { tab }, set: { store.nav.textsTab = $0 }),
                       tips: [.steps: "Dal video ai sottotitoli, un passo alla volta"])
                .padding(.horizontal, 12).padding(.vertical, 10)
            Group {
                switch tab {
                case .steps: StepsPanel()
                case .captions: TextsTab()
                case .transcript: TranscriptView()
                case .takes: TakesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Main area

/// The project tabs at the top, then what the activity shows: Inizio, Registra's live preview, Esporta's program
/// monitor, or the editor (toolbar, monitors, transport, timeline).
struct MainArea: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.navOverride) private var navOverride

    private var nav: Navigation { navOverride ?? store.nav }

    var body: some View {
        VStack(spacing: 0) {
            ProjectTabStrip()
            Group {
                switch nav.activity {
                case .home: HomeWorkspace()
                case .record: RecordView(part: .preview)
                case .export: ExportWorkspace()
                default:
                    VStack(spacing: 0) {
                        EditorToolbar(level: nav.level)
                        if nav.level == .pro {
                            ProWorkspace()
                        } else {
                            SimpleWorkspace()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Ed.main)
    }
}

/// What a project tab shows (S2 #76): a value, so a render can draw sample tabs (ui.screenshot `tabs`).
struct TabInfo: Identifiable, Equatable {
    enum State: String { case saved, unsaved, recording, working }
    let id: String
    var name: String
    /// The edit's length (nil: empty), or how long it has been recording.
    var duration: Double?
    var state: State
    var active: Bool
    var path: String?
    /// The tab has a project (or is recording): it can be saved and closed with its own ×.
    var hasProject: Bool

    init(id: String, name: String, duration: Double?, state: State, active: Bool, path: String?, hasProject: Bool) {
        self.id = id
        self.name = name
        self.duration = duration
        self.state = state
        self.active = active
        self.path = path
        self.hasProject = hasProject
    }

    /// A tab as it is now; `recordingElapsed`: the recorder's time when this tab owns the recording.
    @MainActor
    init(_ t: EditorStore, recordingElapsed: Double? = nil) {
        let recording = t.bench.recordingTabID == t.tabID
        let state: State = recording ? .recording : t.runningWork != nil ? .working
            : (t.project != nil && (t.dirty || t.projectURL == nil)) ? .unsaved : .saved
        self.init(id: t.tabID, name: t.project?.name ?? (recording ? loc("Nuova registrazione") : t.tabTitle),
                  duration: recording ? recordingElapsed : (t.project?.duration).flatMap { $0 > .zero ? $0.seconds : nil },
                  state: state, active: t.isActive, path: t.projectURL?.path, hasProject: t.project != nil || recording)
    }

    /// `n` tabs for a render: `active` first, then sample projects (unsaved, recording, saved, working…).
    static func samples(_ n: Int, active: TabInfo) -> [TabInfo] {
        var first = active
        first.active = true
        let others = [TabInfo(id: "sample-2", name: loc("Tutorial Regista"), duration: 228, state: .unsaved, active: false, path: nil, hasProject: true),
                      TabInfo(id: "sample-3", name: loc("Intervista Ada"), duration: 75, state: .recording, active: false, path: nil, hasProject: true),
                      TabInfo(id: "sample-4", name: loc("Reel lancio"), duration: 42, state: .saved, active: false, path: nil, hasProject: true),
                      TabInfo(id: "sample-5", name: loc("Video senza volto"), duration: 61, state: .working, active: false, path: nil, hasProject: true),
                      TabInfo(id: "sample-6", name: loc("Confronto v2"), duration: 39, state: .saved, active: false, path: nil, hasProject: true)]
        return [first] + others.prefix(max(0, n - 1))
    }

    var json: JSONValue {
        ["id": .string(id), "name": .string(name), "state": .string(state.rawValue), "active": .bool(active),
         "duration": duration.map { .number($0) } ?? .null]
    }
}

private struct TabsDemoKey: EnvironmentKey { static let defaultValue: [TabInfo]? = nil }

extension EnvironmentValues {
    /// Sample tabs an offscreen render draws instead of the open ones (ui.screenshot `tabs`).
    var tabsDemo: [TabInfo]? {
        get { self[TabsDemoKey.self] }
        set { self[TabsDemoKey.self] = newValue }
    }
}

/// One tab per open project, in opening order (drag one to reorder it), and a + tab that opens Inizio in a new empty
/// tab, spanning only the main area (S2 #76).
struct ProjectTabStrip: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.tabsDemo) private var demo

    var body: some View { Strip(bench: store.bench, demo: demo) }

    private struct Strip: View {
        @ObservedObject var bench: Workbench
        let demo: [TabInfo]?

        var body: some View {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        if let demo {
                            ForEach(demo) { TabLabel(info: $0) }
                        } else {
                            ForEach(bench.tabs, id: \.tabID) { ProjectTab(tab: $0) }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                PlusTab()
                Spacer(minLength: 0)
            }
            .frame(height: Chrome.tabsHeight)
            .background(Ed.bar)
            .overlay(alignment: .bottom) { Ed.rule2.frame(height: 1) }
        }
    }
}

/// A live tab: follows its store, its jobs and the recorder.
struct ProjectTab: View {
    @ObservedObject var tab: EditorStore
    @EnvironmentObject private var recorder: Recorder

    var body: some View { Content(tab: tab, jobs: tab.jobs, recorder: recorder) }

    private struct Content: View {
        @ObservedObject var tab: EditorStore
        @ObservedObject var jobs: JobCenter
        @ObservedObject var recorder: Recorder

        var body: some View {
            let bench = tab.bench
            let info = TabInfo(tab, recordingElapsed: recorder.isRecording ? recorder.elapsed : nil)
            TabLabel(info: info, onSelect: { bench.select(tab.tabID) }, onClose: { Task { await bench.close(tab) } },
                     onDrop: { bench.move($0, to: tab.tabID) })
                .contextMenu {
                    Button("Salva") { Panels.save(tab) }.disabled(tab.project == nil)
                    Button("Salva con nome…") { Panels.saveAs(tab) }.disabled(tab.project == nil)
                    Button("Mostra nel Finder") { if let u = tab.projectURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                        .disabled(tab.projectURL == nil)
                    Divider()
                    Button("Chiudi") { Task { await bench.close(tab) } }.disabled(bench.tabs.count == 1 && tab.isEmpty)
                    Button("Chiudi le altre") { Task { await bench.closeOthers(tab) } }.disabled(bench.tabs.count == 1)
                }
        }
    }
}

/// A tab as drawn: state dot, name, duration or "sta registrando", close ×; the active one raised with the accent on top.
struct TabLabel: View {
    let info: TabInfo
    var onSelect: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    var onDrop: ((String) -> Void)? = nil
    @State private var hover = false
    @State private var hoverClose = false

    var body: some View {
        HStack(spacing: 8) {
            dot(info.state)
            Text(verbatim: info.name)
                .font(Ed.ui(13, info.active ? .semibold : .regular)).foregroundStyle(info.active ? Ed.text : Ed.text2)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            if info.state == .recording {
                Text(verbatim: loc("sta registrando") + (info.duration.map { " " + timecode($0) } ?? "")).font(Ed.ui(12)).foregroundStyle(Ed.danger).fixedSize()
            } else if let d = info.duration {
                Text(verbatim: clockTime(d)).font(Ed.ui(12)).foregroundStyle(Ed.text3).fixedSize()
            }
            Button { onClose?() } label: {
                Image(systemName: "xmark").font(Ed.icon(9, .bold))
                    .foregroundStyle(hoverClose ? Ed.text : Ed.text3)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(hoverClose ? Ed.controlOn : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverClose = $0 }
            .tip("Chiudi la scheda", shortcut: "⌘W")
            .opacity(info.active || hover || info.hasProject ? 1 : 0)
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: Chrome.tabsHeight)
        .background(info.active ? Ed.toolbar : (hover ? Ed.control.opacity(0.35) : .clear))
        .overlay(alignment: .top) { if info.active { Ed.gold.frame(height: 2) } }
        .overlay(alignment: .trailing) { Ed.rule2.frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .overlay(MiddleClickArea { onClose?() })
        .onHover { hover = $0 }
        .tip(info.path ?? (info.hasProject ? "Non ancora salvato" : "Scheda vuota: scegli un progetto o registra"))
        .draggable(info.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let onDrop else { return false }
            onDrop(id)
            return true
        }
    }

    @ViewBuilder private func dot(_ s: TabInfo.State) -> some View {
        switch s {
        case .saved: Circle().strokeBorder(Ed.text4, lineWidth: 1.5).frame(width: 8, height: 8).tip("Salvato")
        case .unsaved: Circle().fill(Ed.gold).frame(width: 8, height: 8).tip("Modifiche non salvate", shortcut: "⌘S")
        case .recording: Circle().fill(Ed.danger).frame(width: 8, height: 8).tip("Sta registrando")
        case .working: ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 8, height: 8).tip("Lavoro in corso")
        }
    }
}

/// Middle-click on a tab closes it, as in a browser: a transparent view that only takes the other mouse buttons.
struct MiddleClickArea: NSViewRepresentable {
    let action: () -> Void

    final class Area: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            let t = NSApp.currentEvent?.type
            return t == .otherMouseDown || t == .otherMouseUp ? super.hitTest(point) : nil
        }
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() } else { super.otherMouseUp(with: event) }
        }
    }

    func makeNSView(context: Context) -> Area {
        let v = Area()
        v.action = action
        return v
    }

    func updateNSView(_ v: Area, context: Context) { v.action = action }
}

struct PlusTab: View {
    @EnvironmentObject private var store: EditorStore
    @State private var hover = false

    var body: some View {
        Button { store.bench.openNewTab() } label: {
            Image(systemName: "plus").font(Ed.icon(13, .regular))
                .foregroundStyle(hover ? Ed.text : Ed.text3)
                .frame(width: 36, height: Chrome.tabsHeight)
                .background(hover ? Ed.control.opacity(0.6) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tip("Nuova scheda: un nuovo progetto, uno recente o una registrazione (Inizio)", shortcut: "⌘T")
        .accessibilityLabel(Text(verbatim: loc("Nuova scheda")))
    }
}

/// The editor's toolbar: the level (Semplice | Pro), the format, undo · redo · history, and "Marca: <kit>".
struct EditorToolbar: View {
    @EnvironmentObject private var store: EditorStore
    let level: EditorStore.Workspace
    @State private var showHistory = false

    var body: some View {
        HStack(spacing: 12) {
            RSegmented(items: [(EditorStore.Workspace.simple, "Semplice"), (.pro, "Pro")], selection: Binding(get: { level }, set: { store.workspace = $0 }),
                       fill: false, tips: [.simple: "Livello semplice: sei passi guidati, un'anteprima e Fai tutto", .pro: "Livello Pro: timeline, monitor e pannelli"],
                       shortcuts: [.simple: "⌥⌘1", .pro: "⌥⌘2"])
            Ed.rule.frame(width: 1, height: 16)
            Text(verbatim: format).font(Ed.ui(12)).foregroundStyle(Ed.text3).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ToolbarIcon(symbol: "arrow.uturn.backward", tip: "Annulla l'ultima modifica", shortcut: "⌘Z", disabled: store.undoNames.isEmpty) { store.undo() }
                ToolbarIcon(symbol: "arrow.uturn.forward", tip: "Ripeti l'ultima modifica", shortcut: "⇧⌘Z", disabled: store.redoNames.isEmpty) { store.redo() }
                ToolbarIcon(symbol: "clock.arrow.circlepath", tip: "Cronologia: ogni modifica, tua o di Claude", disabled: false) { showHistory.toggle() }
                    .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                        HistoryTab().frame(width: 300, height: 380).background(Ed.panel).environment(\.colorScheme, .dark)
                    }
            }
            Ed.rule.frame(width: 1, height: 16)
            MarcaButton()
        }
        .padding(.horizontal, 14)
        .frame(height: Chrome.toolbarHeight)
        .background(Ed.toolbar)
        .overlay(alignment: .bottom) { Ed.rule2.frame(height: 1) }
    }

    /// "Formato 9:16 · 1080×1920 · 30 fps".
    private var format: String {
        guard let s = store.project?.settings else { return loc("Nessun progetto aperto") }
        let ratio: String = switch Double(s.width) / Double(max(s.height, 1)) {
        case 0.55...0.58: "9:16"
        case 0.79...0.81: "4:5"
        case 0.99...1.01: "1:1"
        case 1.76...1.79: "16:9"
        default: "\(s.width)×\(s.height)"
        }
        return String(format: loc("Formato %@ · %d×%d · %d fps"), ratio, s.width, s.height, Int(s.frameRate.doubleValue.rounded()))
    }
}

struct ToolbarIcon: View {
    let symbol: String
    let tip: String
    var shortcut: String? = nil
    let disabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(Ed.icon(13))
                .foregroundStyle(hover && !disabled ? Ed.text : Ed.text3)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover && !disabled ? Ed.control : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hover = $0 }
        .tip(tip, shortcut: shortcut)
    }
}

/// "Marca: WeSites": the project's brand kit; opens the Marca picker, the one place that picks it (E4 #3, ⇧⌘B).
struct MarcaButton: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.navOverride) private var navOverride
    @State private var hover = false

    var body: some View {
        Button { store.showBrandKits.toggle() } label: {
            HStack(spacing: 6) {
                if let k = store.project?.brand { KitBubble(kit: k, size: 14) } else {
                    Image(systemName: "paintpalette").font(Ed.icon(11)).foregroundStyle(Ed.text3)
                }
                Text(verbatim: String(format: loc("Marca: %@"), store.project?.brand?.name ?? loc("nessuna")))
                    .font(Ed.ui(12)).foregroundStyle(hover ? Ed.text : Ed.text2).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Ed.control : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tip("Marca del progetto: il brand kit di sottotitoli, titoli e logo", shortcut: "⇧⌘B")
        // Only the live window opens it (an offscreen render draws the picker as its own workspace, brand-picker).
        .popover(isPresented: Binding(get: { navOverride == nil && store.showBrandKits }, set: { store.showBrandKits = $0 }), arrowEdge: .bottom) {
            BrandPicker(onPick: { store.showBrandKits = false })
                .frame(height: BrandPicker.height(kits: BrandKitLibrary.shared.kits.count))
                .background(Ed.side)
                .environment(\.colorScheme, .dark)
        }
    }
}

// MARK: - Right panel

/// Gobbo · Claude · Ispettore: 320 pt, the same place, width and tabs on every activity. Remembers its tab.
struct RightPanel: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.navOverride) private var navOverride

    var body: some View {
        let tab = (navOverride ?? store.nav).rightTab
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Navigation.RightTab.allCases) { t in
                    RightTabButton(title: Self.title(t), on: t == tab) { store.nav.rightTab = t }
                }
            }
            .frame(height: Chrome.headerHeight)
            .overlay(alignment: .bottom) { Ed.rule2.frame(height: 1) }
            Group {
                switch tab {
                case .prompter: PrompterEditorView()
                case .claude: ClaudePanel()
                case .inspector: InspectorPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Ed.side)
        .overlay(alignment: .leading) { Ed.rule.frame(width: 1) }
    }

    static func title(_ t: Navigation.RightTab) -> String {
        switch t {
        case .prompter: loc("Gobbo")
        case .claude: "Claude"
        case .inspector: loc("Ispettore")
        }
    }
}

struct RightTabButton: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(Ed.ui(13, .medium))
                .foregroundStyle(on ? Ed.text : (hover ? Ed.text2 : Ed.text3))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { (on ? Ed.gold : .clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The activity log in human words; a calm state while no agent is connected.
struct ClaudePanel: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        if !store.agentConnected && store.activity.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles").font(Ed.icon(20, .light)).foregroundStyle(Ed.text3)
                    .frame(width: 52, height: 52).background(Circle().fill(Ed.control))
                Text(verbatim: loc("Claude non collegato")).font(Ed.ui(13, .semibold)).foregroundStyle(Ed.text)
                Text(verbatim: loc("Apri Claude Code nella cartella di Regista: si collega da solo a questa finestra. Qui vedrai, in parole semplici, ogni passo che fa."))
                    .font(Ed.ui(12)).foregroundStyle(Ed.text3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(store.agentConnected ? Ed.online : Ed.text4).frame(width: 7, height: 7)
                    Text(verbatim: store.agentConnected ? String(format: loc("%@ collegato"), store.agentName) : loc("Claude non collegato"))
                        .font(Ed.ui(12)).foregroundStyle(Ed.text2)
                    Spacer()
                    let steps = store.activity.filter { $0.isAgent && !$0.readOnly }.count
                    Text(verbatim: steps == 1 ? loc("1 passo di Claude") : String(format: loc("%d passi di Claude"), steps))
                        .font(Ed.ui(11)).foregroundStyle(Ed.text4)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                ActivityLog(compact: false)
            }
        }
    }
}
