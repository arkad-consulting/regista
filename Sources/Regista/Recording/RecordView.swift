import AppKit
import RegistaCore
import SwiftUI

/// ui.screenshot's `record` parameter: the Registra screen drawn in a given state, without touching the recorder.
struct RecordDemo {
    var sources: RecordingSources
    /// The row whose choices are open.
    var open: RecordingSources.Source?
    /// Draw the rows as if macOS had granted every permission (the look of a normal session on an unsigned build).
    var grantPermissions = false
    /// Sample displays instead of the connected ones (the display picker in a render).
    var displays: [DisplayInfo]?
}

private struct RecordDemoKey: EnvironmentKey { static let defaultValue: RecordDemo? = nil }

extension EnvironmentValues {
    var recordDemo: RecordDemo? {
        get { self[RecordDemoKey.self] }
        set { self[RecordDemoKey.self] = newValue }
    }
}

/// Registra (issue #50), in two parts of the window shell (S1 #75): the live preview in the main area; in the side
/// panel the four presets, one row and one switch per source (Schermo, Camera, Microfono, Audio del Mac, Gobbo), the
/// face layout when screen and camera are both on, and the Record button. Every choice lives in `recorder.sources` and
/// survives a relaunch.
struct RecordView: View {
    enum Part { case preview, controls }
    let part: Part
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var prompter = TeleprompterController.shared
    @Environment(\.recordDemo) private var demo
    @AppStorage(Prefs.autoEditKey) private var autoEdit = true
    @State private var openRow: RecordingSources.Source?
    /// Bumped when displays are connected or rearranged: the picker reads them again.
    @State private var screensChanged = 0
    @Environment(\.sidePanelWidth) private var columnWidth

    private var live: Bool { demo == nil }
    private var s: RecordingSources { demo?.sources ?? recorder.sources }
    private var open: RecordingSources.Source? { demo?.open ?? openRow }

    var body: some View {
        switch part {
        case .preview:
            RecordPreview(sources: s, environment: env, live: live, sampleLevel: demo?.grantPermissions == true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { if live { await recorder.prepare() } }
        case .controls:
            column
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in screensChanged += 1 }
        }
    }

    /// The displays the picker shows: the demo's samples, else the connected ones.
    private var displays: [DisplayInfo] {
        _ = screensChanged
        return demo?.displays ?? DisplayInfo.connected()
    }

    // MARK: Model

    var env: RecordingEnvironment { Self.environment(recorder, demo: demo) }

    /// The facts the rows are drawn from (in a demo render: the demo's sources, optionally with every permission).
    static func environment(_ recorder: Recorder, demo: RecordDemo?) -> RecordingEnvironment {
        let sources = demo?.sources ?? recorder.sources
        var e = recorder.environment(prompterSummary: prompterSummary(TeleprompterController.shared, microphone: sources.microphone).text)
        if let demo {
            e.targetName = recorder.targetName(demo.sources.target ?? .display(CGMainDisplayID()))
            // A sample display does not exist: its size comes from the sample.
            if let d = demo.displays?.first(where: { ScreenTarget.display($0.id) == demo.sources.target }) {
                e.targetName = String(format: loc("Schermo intero %d×%d"), Int(d.frame.width), Int(d.frame.height))
            }
            if demo.grantPermissions { e.camera = .granted; e.microphone = .granted; e.screen = .granted }
        }
        return e
    }

    /// What a render of `demo` shows (ui.screenshot's shown.record), from the same rows the view draws.
    static func describe(_ demo: RecordDemo, recorder: Recorder) -> JSONValue {
        let s = demo.sources, env = environment(recorder, demo: demo)
        let rows = s.rows(env, lookup: loc).map { r -> JSONValue in
            ["source": .string(r.source.rawValue), "on": .bool(r.on), "enabled": .bool(r.enabled), "detail": .string(r.detail),
             "permission": .string(r.permission.rawValue), "blocked": .bool(r.blocked)]
        }
        let reason = s.blockReason(env, lookup: loc)
        return ["preset": s.preset.map { .string($0.rawValue) } ?? .null, "screen": .bool(s.screen), "camera": .bool(s.camera),
                "microphone": .bool(s.microphone), "systemAudio": .bool(s.systemAudio), "prompter": .bool(s.prompter),
                "faceLayout": s.showsFaceLayout ? .string(s.layout.label) : .null, "open": demo.open.map { .string($0.rawValue) } ?? .null,
                "rows": .array(rows), "canRecord": .bool(reason == nil), "blockReason": reason.map { .string($0) } ?? .null,
                "displays": .number(Double((demo.displays ?? DisplayInfo.connected()).count)),
                "displayPicker": .bool(s.screen && (demo.displays ?? DisplayInfo.connected()).count > 1),
                "permissions": .string(demo.grantPermissions ? "granted" : "actual")]
    }

    /// The Gobbo row's line: what the teleprompter will do with the recording.
    static func prompterSummary(_ p: TeleprompterController, microphone: Bool) -> (text: String, warning: Bool) {
        if p.mode == .voice, !microphone { return (loc("Modalità Voce senza microfono: scorre solo a mano o col pedale"), true) }
        let how = p.mode == .voice ? "\(p.mode.label) · \(PrompterLanguage.name(p.language))" : p.mode.label
        return (String(format: loc("Si apre e parte con la registrazione · %@"), how), false)
    }

    private var rows: [SourceRowInfo] { s.rows(env, lookup: loc) }
    private var blockReason: String? { live ? recorder.blockReason : s.blockReason(env, lookup: loc) }

    private func binding(_ source: RecordingSources.Source) -> Binding<Bool> {
        // The Mac's sound shows off while the screen is off (it would not be recorded); the choice is kept.
        Binding(get: { source == .systemAudio ? s.recordsSystemAudio : s.isOn(source) }, set: { on in
            guard !recorder.isRecording else { return }
            recorder.sources.set(source, on)
        })
    }

    // MARK: Column

    private var column: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Ed.Space.xl) {
                    RSection(loc("Cosa registri")) {
                        RChips(items: RecordingSources.Preset.allCases.map { .init(id: $0, title: loc($0.title), symbol: $0.symbol) },
                               selection: s.preset, columns: 2) { p in
                            guard !recorder.isRecording else { return }
                            recorder.sources.apply(p)
                        }
                        .disabled(recorder.isRecording)
                    }
                    RSection(loc("Sorgenti")) { sourceRows }
                    if s.showsFaceLayout {
                        RSection(loc("Volto nel video")) { FaceLayoutControls(layout: layoutBinding) }
                    }
                }
                .padding(Ed.Space.l)
            }
            footer
        }
    }

    private var layoutBinding: Binding<LayoutSpec> {
        Binding(get: { s.layout }, set: { recorder.sources.layout = $0 })
    }

    private var sourceRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.source) { i, r in
                if i > 0 { Ed.line.frame(height: 1) }
                row(r)
                if r.source == .screen, r.on, displays.count > 1 { displayPicker }
                if r.source == .screen, r.blocked { screenGuidance }
                if open == r.source, r.hasChoices, r.enabled {
                    choices(r.source)
                        .padding(.horizontal, Ed.Space.s)
                        .padding(.bottom, Ed.Space.s)
                        .background(Ed.raised.opacity(0.55))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Ed.Radius.xl).fill(Ed.header))
        .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.xl))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.xl).strokeBorder(Ed.line2))
        .disabled(recorder.isRecording)
    }

    private func row(_ r: SourceRowInfo) -> some View {
        let (detail, warning) = rowDetail(r)
        return RSwitchRow(symbol: r.symbol, title: loc(r.title), detail: detail, isOn: binding(r.source), enabled: r.enabled, warning: warning,
                          expanded: r.hasChoices && r.enabled ? open == r.source : nil,
                          onOpen: { withAnimation(.easeOut(duration: 0.16)) { openRow = openRow == r.source ? nil : r.source } }) {
            if r.source == .microphone, r.on, r.permission != .denied {
                if live { MicLevelMeter(level: recorder.level).padding(.top, 3) }
                // A render has no live sound: an empty meter, or a sample level when drawing the granted look.
                else { RLevelMeter(value: demo?.grantPermissions == true ? 0.62 : 0).frame(width: 150).padding(.top, 3) }
            }
        } trailing: {
            // The screen's own steps sit under its row; the Mac's sound shares that permission (issue #67).
            if r.blocked, r.source != .screen, r.source != .systemAudio {
                EdButton(title: loc("Consenti…")) { recorder.openSettings(for: r.source) }
                    .tip("Apre Impostazioni di Sistema › Privacy e sicurezza, dove si consente Regista")
            }
        }
    }

    /// The row's second line: why it is disabled, the missing permission, or the current choice.
    private func rowDetail(_ r: SourceRowInfo) -> (String, Bool) {
        if !r.enabled, let why = r.disabledReason { return (why, false) }
        if r.on, r.permission == .denied {
            switch r.source {
            case .camera: return (loc("macOS non consente la camera a Regista"), true)
            case .microphone: return (loc("macOS non consente il microfono a Regista"), true)
            case .systemAudio: return (loc("Usa il permesso dello Schermo: segui i passi qui sopra"), true)
            default: return (loc("Registrazione dello schermo non ancora attiva"), true)
            }
        }
        if r.on, r.permission == .undetermined, r.source != .prompter, r.source != .systemAudio {
            return (r.detail + " · " + loc("macOS chiederà il permesso"), false)
        }
        if r.source == .prompter { return (r.detail, r.on && Self.prompterSummary(prompter, microphone: s.microphone).warning) }
        return (r.detail, false)
    }

    /// Issue #67: the screen permission was asked and is not in effect yet. What to do, in plain words, and the three
    /// ways forward — only "Riprova" asks macOS again.
    private var screenGuidance: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            Text(verbatim: ScreenAccess.guidance(promptShown: live && recorder.screenPromptShown, lookup: loc))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: Ed.Space.xs, lineSpacing: Ed.Space.xs) {
                EdButton(title: loc("Apri Impostazioni"), symbol: "gearshape") { recorder.openSettings(for: .screen) }
                    .tip("Apre Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio di sistema")
                EdButton(title: loc("Riapri Regista"), symbol: "arrow.triangle.2.circlepath") {
                    recorder.relaunchApp(blocked: ScreenAccess.relaunchBlock(recording: recorder.isRecording, unsaved: store.dirty, lookup: loc))
                }
                .tip("Chiude e riapre Regista: il permesso vale da quel momento")
                EdButton(title: loc("Riprova"), symbol: "arrow.clockwise") { recorder.retryScreen() }
                    .tip("Chiede di nuovo il permesso a macOS, poi lo ricontrolla")
            }
        }
        .padding(.horizontal, Ed.Space.m)
        .padding(.bottom, Ed.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Several displays: the choice of screen stays in view under the Schermo row (issue #50); a click selects a display
    /// and outlines that physical screen for a moment.
    private var displayPicker: some View {
        DisplayPicker(displays: displays, target: s.target, width: columnWidth - 2 * Ed.Space.l - 2 * Ed.Space.m, select: { d in
            guard live, !recorder.isRecording else { return }
            recorder.sources.target = .display(d.id)
            ScreenOutline.flash(d)
        }, hover: { d in
            guard live, !recorder.isRecording else { return }
            ScreenOutline.flash(d)
        })
    }

    @ViewBuilder
    private func choices(_ source: RecordingSources.Source) -> some View {
        switch source {
        case .screen: ScreenChoices(sources: s, grant: demo?.grantPermissions == true, listsDisplays: displays.count <= 1)
        case .camera:
            DeviceChoices(items: recorder.cameras.map { .init(id: $0.uniqueID, title: $0.localizedName, symbol: "video") },
                          selection: s.camera ? recorder.deviceID(.camera, in: s) : nil, empty: loc("Nessuna camera trovata")) { id in
                recorder.sources.cameraID = id
                recorder.sources.camera = true
            }
        case .microphone:
            DeviceChoices(items: recorder.microphones.map { .init(id: $0.uniqueID, title: $0.localizedName, symbol: "mic") },
                          selection: s.microphone ? recorder.deviceID(.microphone, in: s) : nil, empty: loc("Nessun microfono trovato")) { id in
                recorder.sources.microphoneID = id
                recorder.sources.microphone = true
            }
        case .systemAudio, .prompter: EmptyView()
        }
    }

    // MARK: Footer

    private var footer: some View {
        // One recording at a time, owned by the tab it was started from (S2 #76): another tab cannot start or stop it.
        let elsewhere = live ? store.bench.recordingRefusal(for: store) : nil
        return VStack(alignment: .leading, spacing: Ed.Space.m) {
            if let elsewhere {
                Label { Text(verbatim: elsewhere).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "record.circle") }
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.warn)
            } else if let e = recorder.errorMessage, live {
                Label { Text(verbatim: e).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.octagon") }
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.danger)
            } else if let why = blockReason, !recorder.isRecording {
                Label { Text(verbatim: why).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.warn)
            }
            RToggle(title: loc("Montaggio automatico a fine registrazione"), isOn: $autoEdit,
                    subtitle: s.screen ? loc("Per camera e voce. Una registrazione dello schermo si apre in Monta da montare") : nil)
                .disabled(s.screen)
                .opacity(s.screen ? 0.5 : 1)
            if recorder.isRecording, let why = recorder.pauseUnavailableReason {
                Text(verbatim: why).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
            if elsewhere == nil {
            HStack(spacing: Ed.Space.s) {
                if recorder.isRecording {
                    EdButton(title: recorder.isPaused ? loc("Riprendi") : loc("Pausa"), symbol: recorder.isPaused ? "play.fill" : "pause.fill",
                             large: true, disabled: !recorder.canPause) { recorder.togglePause() }
                        .tip(recorder.pauseUnavailableReason ?? "Pausa / Riprendi", shortcut: "⇧⌘P")
                }
                EdButton(title: recorder.isRecording ? String(format: loc("Ferma · %@"), timecode(recorder.elapsed)) : loc("Registra"),
                         symbol: recorder.isRecording ? "stop.fill" : "record.circle", destructive: true, large: true, fill: true,
                         disabled: !recorder.isRecording && (blockReason != nil || (live && !recorder.isReady))) { recorder.toggleRecording() }
                    .tip("Avvia / Ferma registrazione", shortcut: "⇧⌘R")
            }
            }
        }
        .padding(Ed.Space.l)
        .overlay(alignment: .top) { Ed.rule2.frame(height: 1) }
    }
}

/// The microphone level, observed on its own (it changes twenty times a second).
struct MicLevelMeter: View {
    @ObservedObject var level: MicLevel
    var segments = 24
    var height: CGFloat = 5

    var body: some View {
        RLevelMeter(value: level.value, segments: segments, height: height).frame(maxWidth: segments > 24 ? .infinity : 150)
    }
}

// MARK: - Choices

/// Cameras or microphones, the one in use checked, with a refresh for devices plugged in later.
private struct DeviceChoices: View {
    @EnvironmentObject private var recorder: Recorder
    let items: [RChoiceList<String>.Item]
    let selection: String?
    let empty: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.xs) {
            RChoiceList(items: items, selection: selection, empty: empty, onSelect: onSelect)
            HStack {
                Spacer()
                EdButton(title: loc("Aggiorna"), symbol: "arrow.clockwise") { recorder.refreshDevices() }
                    .tip("Aggiorna dispositivi")
            }
        }
    }
}

/// What to record of the screen — a display, a window or an area — and the cursor and keys options.
private struct ScreenChoices: View {
    @EnvironmentObject private var recorder: Recorder
    let sources: RecordingSources
    let grant: Bool
    /// One display: its line stays here (several: the picker under the row shows them).
    let listsDisplays: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            if listsDisplays {
                caption(loc("Schermi"))
                RChoiceList(items: displays, selection: display(sources.target ?? .display(CGMainDisplayID()))) { id in recorder.sources.target = .display(id) }
            }
            caption(loc("Finestre"))
            if recorder.screenPermission == .granted || grant {
                RChoiceList(items: recorder.windows.map { w in
                    .init(id: w.windowID, title: w.title?.isEmpty == false ? w.title! : (w.owningApplication?.applicationName ?? loc("Finestra")),
                          subtitle: w.owningApplication?.applicationName, symbol: "macwindow")
                }, selection: { if case .window(let id) = sources.target { id } else { nil } }(), empty: loc("Nessuna finestra aperta")) { id in
                    recorder.sources.target = .window(id)
                }
            } else {
                Text(verbatim: loc("Le finestre compaiono quando macOS consente a Regista di registrare lo schermo."))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).padding(.horizontal, Ed.Space.s).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Ed.Space.s) {
                EdButton(title: loc("Scegli un'area…"), symbol: "rectangle.dashed") { pickArea() }
                if case .area(_, let r) = sources.target {
                    Text(verbatim: String(format: loc("Area %d×%d"), Int(r.width), Int(r.height)))
                        .font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.gold)
                }
                Spacer()
                EdButton(title: loc("Aggiorna"), symbol: "arrow.clockwise") { Task { await recorder.refreshScreen() } }
            }
            .padding(.horizontal, Ed.Space.xs)
            Ed.line.frame(height: 1).padding(.vertical, Ed.Space.xxs)
            RToggle(title: loc("Nascondi il cursore di sistema"), isOn: Binding(get: { sources.hideCursor }, set: { recorder.sources.hideCursor = $0 }),
                    subtitle: loc("In montaggio Regista lo ridisegna più grande e fluido, con un'onda a ogni clic"))
                .padding(.horizontal, Ed.Space.s)
            if !recorder.logsKeys {
                HStack(alignment: .top, spacing: Ed.Space.s) {
                    Text(verbatim: loc("I clic vengono registrati; i tasti premuti solo con il permesso Accessibilità."))
                        .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Ed.Space.xs)
                    EdButton(title: loc("Consenti…")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                    }
                }
                .padding(.horizontal, Ed.Space.s)
            }
        }
        .padding(.top, Ed.Space.xs)
    }

    private func display(_ t: ScreenTarget) -> CGDirectDisplayID? { if case .display(let id) = t { id } else { nil } }

    /// Every connected display (listed without the screen permission: NSScreen).
    private var displays: [RChoiceList<CGDirectDisplayID>.Item] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }   // l10n-ignore
            let b = CGDisplayBounds(id)
            return .init(id: id, title: String(format: loc("Schermo intero %d×%d"), Int(b.width), Int(b.height)),
                         subtitle: screen.localizedName, symbol: "display")
        }
    }

    private func caption(_ t: String) -> some View {
        SectionLabel(t).padding(.horizontal, Ed.Space.s).padding(.top, Ed.Space.xs)
    }

    private func pickArea() {
        guard let screen = NSScreen.main, let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }   // l10n-ignore
        AreaPicker.pick(on: screen) { rect in
            if let rect { recorder.sources.target = .area(id, rect) }
        }
    }
}

// MARK: - Displays

extension DisplayInfo {
    /// The connected displays (NSScreen: no permission needed), in NSScreen order.
    @MainActor
    static func connected() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }   // l10n-ignore
            return DisplayInfo(id: id, name: screen.localizedName, frame: CGDisplayBounds(id), main: id == CGMainDisplayID())
        }
    }
}

/// One tile per display, laid out as in macOS Displays settings (a grid when the setup is too wide for that); the
/// main display carries the menu bar strip, the recorded one is gold. The line under it says what is recorded.
private struct DisplayPicker: View {
    let displays: [DisplayInfo]
    let target: ScreenTarget?
    /// The width the tiles are laid out in (the side panel's, less its margins).
    let width: CGFloat
    let select: (DisplayInfo) -> Void
    let hover: (DisplayInfo) -> Void
    private var selected: CGDirectDisplayID? { DisplayInfo.selected(target, main: displays.first(where: \.main)?.id ?? CGMainDisplayID()) }

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            if let tiles = DisplayInfo.arrangement(displays, width: width, maxHeight: 140, minTile: CGSize(width: 64, height: 40)) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(displays.enumerated()), id: \.element.id) { i, d in
                        let r = tiles[i].insetBy(dx: 1.5, dy: 1.5)
                        tile(d).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    }
                }
                .frame(width: width, height: tiles.map(\.maxY).max() ?? 0, alignment: .topLeading)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(displays) { d in tile(d).frame(height: 52) }
                }
                .frame(width: width)
            }
            Text(verbatim: summary).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Ed.Space.m)
        .padding(.bottom, Ed.Space.m)
    }

    private func tile(_ d: DisplayInfo) -> some View {
        DisplayTile(display: d, on: d.id == selected, action: { select(d) }, hovered: { hover(d) })
    }

    private var summary: String {
        guard let d = displays.first(where: { $0.id == selected }) else {
            return loc("Registri una finestra: scegli uno schermo per registrarlo intero")
        }
        if case .area = target { return String(format: loc("Registri un'area di %@"), d.name) }
        let line = String(format: loc("Registri %@ · %d×%d"), d.name, Int(d.frame.width), Int(d.frame.height))
        return d.main ? line + " · " + loc("schermo principale") : line
    }
}

private struct DisplayTile: View {
    let display: DisplayInfo
    let on: Bool
    let action: () -> Void
    let hovered: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(verbatim: display.name).font(Ed.ui(Ed.TypeSize.micro, .medium)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                Text(verbatim: "\(Int(display.frame.width))×\(Int(display.frame.height))").font(Ed.mono(Ed.TypeSize.tiny))
                    .foregroundStyle(on ? Ed.gold : Ed.text3).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(on || hover ? Ed.text : Ed.text2)
            .padding(.horizontal, Ed.Space.xs).padding(.top, display.main ? 6 : 3).padding(.bottom, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(on ? Ed.goldSoft : (hover ? Ed.hover : Ed.well))
            // The main display has the menu bar, as in macOS Displays settings.
            .overlay(alignment: .top) { if display.main { Rectangle().fill(on ? Ed.gold.opacity(0.7) : Ed.text3).frame(height: 3) } }
            .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(on ? Ed.gold.opacity(0.85) : Ed.line2, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover = inside
            if inside { hovered() }
        }
        .accessibilityAddTraits(on ? .isSelected : [])
        .tip("Registra questo schermo; lo evidenzia per un attimo")
    }
}

/// A brief gold outline with the display's name on that physical screen, so the person sees which one a tile is
/// (issue #50). Click-through, above everything, never captured (sharingType = .none); fades out after about 1.5 s.
@MainActor
enum ScreenOutline {
    private static var window: NSWindow?
    private static var generation = 0

    static func flash(_ display: DisplayInfo) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.id   // l10n-ignore
        }) else { return }
        generation += 1
        let g = generation
        let w = window ?? makeWindow()
        window = w
        w.setFrame(screen.frame, display: false)
        w.contentView = NSHostingView(rootView: OutlineView(name: display.name))
        w.alphaValue = 1
        w.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            guard g == generation else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                w.animator().alphaValue = 0
            }
            guard g == generation else { return }
            w.orderOut(nil)
        }
    }

    private static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.sharingType = .none
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return w
    }

    private struct OutlineView: View {
        let name: String
        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: Ed.Radius.xl).strokeBorder(Ed.gold, lineWidth: 6)
                Text(verbatim: name).font(Ed.ui(Ed.TypeSize.large, .semibold)).foregroundStyle(Accent.on)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Capsule().fill(Ed.gold))
            }
            .padding(Ed.Space.xs)
        }
    }
}

// MARK: - Face layout

/// Where the face goes when screen and camera are both on: the six layouts as small drawings of their geometry, then
/// corner, size, shape and side where the layout has them. Also the inspector's Volto group (R2 #51), drawn at the
/// project's aspect.
struct FaceLayoutControls: View {
    @Binding var layout: LayoutSpec
    /// The output's width / height, the aspect the tiles are drawn at.
    var aspect: Double = 16.0 / 9.0
    var hint: String? = loc("Il volto si può spostare anche mentre registri: in montaggio ogni cambio diventa un tratto modificabile della timeline.")

    static let names: [(LayoutSpec.Kind, String)] = [
        (.bubble, "Bolla"), (.split, "Affiancati"), (.stack, "Verticale"), (.face, "Volto"), (.cutout, "Ritaglio"), (.screen, "Solo schermo"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.m) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Self.names, id: \.0) { kind, name in
                    LayoutTile(spec: LayoutSpec(kind: kind, corner: layout.corner, shape: layout.shape, size: layout.size,
                                               side: kind == layout.kind ? layout.side : nil), title: loc(name),
                               on: layout.kind == kind, aspect: aspect) {
                        var l = layout
                        l.kind = kind
                        // The cut-out stands on the bottom edge.
                        if kind == .cutout, l.corner?.hasPrefix("top") == true { l.corner = "bottomRight" }
                        layout = l
                    }
                }
            }
            if layout.kind == .bubble || layout.kind == .cutout {
                labeled(loc("Angolo")) {
                    RSegmented(items: corners.map { ($0, "") }, selection: Binding(get: { layout.corner ?? "bottomRight" }, set: { layout.corner = $0 }),
                               symbols: Self.cornerSymbols)
                }
                labeled(loc("Misura")) {
                    RSegmented(items: [("S", "S"), ("M", "M"), ("L", "L")], selection: Binding(get: { layout.size ?? "M" }, set: { layout.size = $0 }))
                }
            }
            if layout.kind == .split || layout.kind == .stack {
                // Which side the face is on (#66).
                let split = layout.kind == .split
                labeled(loc("Lato")) {
                    RSegmented(items: split ? [("left", loc("Sinistra")), ("right", loc("Destra"))] : [("top", loc("Sopra")), ("bottom", loc("Sotto"))],
                               selection: Binding(get: { layout.side ?? (split ? "right" : "bottom") }, set: { layout.side = $0 }),
                               symbols: split ? ["left": "rectangle.lefthalf.filled", "right": "rectangle.righthalf.filled"]
                                   : ["top": "rectangle.tophalf.filled", "bottom": "rectangle.bottomhalf.filled"])
                }
            }
            if layout.kind == .bubble {
                labeled(loc("Forma")) {
                    RSegmented(items: [("circle", loc("Cerchio")), ("rounded", loc("Quadrato"))],
                               selection: Binding(get: { layout.shape ?? "circle" }, set: { layout.shape = $0 }),
                               symbols: ["circle": "circle", "rounded": "square"])
                }
            }
            if let hint {
                Text(verbatim: hint).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var corners: [String] { layout.kind == .cutout ? ["bottomLeft", "bottomRight"] : LayoutSpec.corners }

    static let cornerSymbols = ["topLeft": "inset.filled.topleft.rectangle", "topRight": "inset.filled.topright.rectangle",
                                "bottomLeft": "inset.filled.bottomleft.rectangle", "bottomRight": "inset.filled.bottomright.rectangle"]

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: Ed.Space.m) {
            Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).lineLimit(1).minimumScaleFactor(0.75)
                .frame(width: 62, alignment: .leading)
            content()
        }
    }
}

/// One layout as a 16:9 drawing of its real geometry (Layouts.geometry): the screen in grey, the face in the accent.
private struct LayoutTile: View {
    let spec: LayoutSpec
    let title: String
    let on: Bool
    var aspect: Double = 16.0 / 9.0
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                GeometryReader { geo in
                    let W = geo.size.width, H = geo.size.height
                    let g = Layouts.geometry(spec, width: Int(W.rounded()), height: Int(H.rounded()), screen: (16, 9), camera: (16, 9))
                    ZStack(alignment: .topLeading) {
                        Ed.well
                        if g.screen.visible { box(g.screen, W: W, H: H, fill: Ed.text3.opacity(0.45)) }
                        if g.camera.visible { box(g.camera, W: W, H: H, fill: on ? Ed.gold : Ed.text2.opacity(0.8)) }
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxHeight: aspect < 1 ? 70 : nil)
                .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.s))
                Text(verbatim: title).font(Ed.ui(Ed.TypeSize.caption, on ? .semibold : .medium)).foregroundStyle(on ? Ed.text : Ed.text2).lineLimit(1)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(on ? Ed.goldSoft : (hover ? Ed.hover : Ed.header)))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.m).strokeBorder(on ? Ed.gold.opacity(0.6) : Ed.line2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func box(_ l: LayerLayout, W: Double, H: Double, fill: Color) -> some View {
        let (bw, bh) = l.boxSize(width: Int(W), height: Int(H))
        let radius: Double = switch l.mask?.shape {
        case .circle: min(bw, bh) / 2
        case .rounded: (l.mask?.radius ?? 0.1) * min(bw, bh)
        default: 1
        }
        return (l.mask?.shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: radius)))
            .fill(fill)
            .frame(width: bw, height: bh)
            .position(x: (l.placement?.x ?? 0.5) * W, y: (l.placement?.y ?? 0.5) * H)
    }
}

// MARK: - Preview

/// The live preview in the output format: the screen and the face where the layout puts them (16:9), the camera alone,
/// or — with only the microphone — the voice and its level. Without frames (no permission, an offscreen render) each
/// part is drawn as a placeholder of the same geometry, so the layout still reads.
struct RecordPreview: View {
    @EnvironmentObject private var recorder: Recorder
    let sources: RecordingSources
    let environment: RecordingEnvironment
    let live: Bool
    /// A render drawn as if every permission were granted shows a sample level in the meter.
    var sampleLevel = false

    var body: some View {
        VStack(spacing: Ed.Space.m) {
            ZStack {
                content
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.xl))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.xl).strokeBorder(Ed.line2))
            .overlay(alignment: .topLeading) { if recorder.isRecording { recordingPill.padding(Ed.Space.m) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            caption
        }
        .padding(Ed.Space.xl)
        .background(Ed.bg)
    }

    @ViewBuilder
    private var content: some View {
        if sources.screen {
            layoutPreview
        } else if sources.camera {
            ZStack {
                Ed.stage
                if live, recorder.hasCamera { CameraPreview(session: recorder.session, gravity: .resizeAspectFill) }
                else { FacePlaceholder(note: cameraNote) }
            }
        } else if sources.microphone {
            voiceOnly
        } else {
            ZStack {
                Ed.stage
                EmptyHint(symbol: "power", text: loc("Accendi lo schermo, la camera o il microfono"))
            }
        }
    }

    private var cameraNote: String? {
        switch environment.camera {
        case .denied: loc("Camera non consentita in macOS")
        case .undetermined: loc("La camera appare quando macOS la consente")
        case .granted: live && !recorder.hasCamera ? loc("Nessuna camera collegata") : nil
        }
    }

    private var screenNote: String? {
        switch environment.screen {
        case .denied: ScreenAccess.guidance(promptShown: live && recorder.screenPromptShown, lookup: loc)
        case .undetermined: loc("Lo schermo appare quando macOS lo consente")
        case .granted: nil
        }
    }

    private var layoutPreview: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let spec = sources.effectiveLayout
            let g = Layouts.geometry(spec, width: Int(W), height: Int(H), screen: (16, 9), camera: (16, 9))
            ZStack(alignment: .topLeading) {
                Ed.stageDeep
                place(g.screen, W: W, H: H) {
                    if live, let frame = recorder.screenFrame { ScreenPreview(surface: frame) }
                    else { ScreenPlaceholder(note: screenNote, compact: false) }
                }
                .opacity(g.screen.visible ? 1 : 0)
                if sources.camera {
                    place(g.camera, W: W, H: H) {
                        if live, recorder.hasCamera { CameraPreview(session: recorder.session, gravity: .resizeAspectFill) }
                        else { FacePlaceholder(note: nil) }
                    }
                    .opacity(g.camera.visible ? 1 : 0)
                }
            }
        }
    }

    /// A layer drawn into its box (or the whole frame), clipped to its mask's shape.
    private func place<V: View>(_ l: LayerLayout, W: Double, H: Double, @ViewBuilder content: () -> V) -> some View {
        let (bw, bh) = l.boxSize(width: Int(W), height: Int(H))
        let cx = (l.placement?.x ?? 0.5) * W, cy = (l.placement?.y ?? 0.5) * H
        let radius: Double = switch l.mask?.shape {
        case .circle: min(bw, bh) / 2
        case .rounded: (l.mask?.radius ?? 0.1) * min(bw, bh)
        default: 0
        }
        let shape = maskShape(l, radius: radius)
        return content()
            .frame(width: bw, height: bh)
            .clipShape(shape)
            .overlay {
                if l.mask?.cutout == true {
                    // The person is cut out in the edit (Vision matte): the preview shows the box.
                    RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).foregroundStyle(.white.opacity(0.7))
                } else if l.mask?.borderWidth != nil {
                    shape.stroke(.white.opacity(0.85), lineWidth: 2)
                }
            }
            .shadow(color: .black.opacity(l.mask?.shadow ?? 0), radius: 8, y: 3)
            .position(x: cx, y: cy)
    }

    /// A circle mask is a circle (a rounded rectangle whose radius is half its side draws a broken outline).
    private func maskShape(_ l: LayerLayout, radius: Double) -> AnyShape {
        l.mask?.shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: radius))
    }

    private var voiceOnly: some View {
        ZStack {
            Ed.stage
            VStack(spacing: Ed.Space.l) {
                Image(systemName: "waveform")
                    .font(Ed.icon(Ed.TypeSize.large, .light))
                    .foregroundStyle(Ed.gold)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Ed.goldSoft))
                    .overlay(Circle().strokeBorder(Ed.gold.opacity(0.3)))
                Text(verbatim: loc("Solo voce")).font(Ed.display(Ed.TypeSize.heading, .medium)).foregroundStyle(Ed.text)
                Text(verbatim: environment.microphone == .denied ? loc("macOS non consente il microfono a Regista")
                               : (environment.microphoneName ?? loc("Nessun microfono collegato")))
                    .font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(environment.microphone == .denied ? Ed.warn : Ed.text2)
                Group {
                    if live { MicLevelMeter(level: recorder.level, segments: 40, height: 10) }
                    else { RLevelMeter(value: sampleLevel ? 0.62 : 0, segments: 40, height: 10) }
                }
                .frame(maxWidth: 360)
                Text(verbatim: loc("Nel file solo l'audio: nessuna immagine"))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            }
            .padding(Ed.Space.xl)
        }
    }

    private var caption: some View {
        HStack(spacing: Ed.Space.s) {
            SectionLabel("Anteprima")
            Text(verbatim: sources.screen ? "16:9" : (sources.camera ? loc("formato della camera") : loc("audio"))).font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            Spacer()
            Text(verbatim: inFile).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).lineLimit(1)
        }
    }

    /// "Nel file: schermo · camera · microfono".
    private var inFile: String {
        var parts: [String] = []
        if sources.screen { parts.append(loc("schermo")) }
        if sources.camera { parts.append(loc("camera")) }
        if sources.microphone { parts.append(loc("microfono")) }
        if sources.recordsSystemAudio { parts.append(loc("audio del Mac")) }
        return parts.isEmpty ? loc("Niente da registrare") : String(format: loc("Nel file: %@"), parts.joined(separator: " · "))
    }

    private var recordingPill: some View {
        HStack(spacing: 6) {
            Circle().fill(.white).frame(width: 7, height: 7)
            Text(verbatim: recorder.isPaused ? String(format: loc("In pausa · %@"), timecode(recorder.elapsed)) : timecode(recorder.elapsed))
                .font(Ed.mono(Ed.TypeSize.small, .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(recorder.isPaused ? Ed.warn : Ed.danger))
    }
}

/// The screen's place in the preview while there is no frame: a faint desktop drawing and, when known, why.
private struct ScreenPlaceholder: View {
    let note: String?
    let compact: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Ed.stageTop, Ed.stageBottom], startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(Ed.line2)
                    .frame(width: w * 0.46, height: h * 0.52).position(x: w * 0.33, y: h * 0.42)
                RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(Ed.line2)
                    .frame(width: w * 0.38, height: h * 0.44).position(x: w * 0.66, y: h * 0.56)
            }
            VStack(spacing: Ed.Space.s) {
                Image(systemName: "display").font(Ed.icon(Ed.TypeSize.large, .light)).foregroundStyle(Ed.text3)
                if let note {
                    Text(verbatim: note).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2).multilineTextAlignment(.center)
                        .frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Ed.Space.m)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.stageBottom.opacity(note == nil ? 0 : 0.85)))
        }
    }
}

/// The face's place in the preview while there is no camera frame: a fine outline of a head and shoulders.
private struct FacePlaceholder: View {
    let note: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Ed.cardTop, Ed.cardBottom], startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                let s = min(g.size.width, g.size.height)
                let line = StrokeStyle(lineWidth: max(1, s / 160))
                ZStack {
                    Circle().stroke(Ed.text3, style: line).frame(width: s * 0.2, height: s * 0.2).offset(y: -s * 0.1)
                    Path { p in
                        p.addArc(center: CGPoint(x: s * 0.2, y: s * 0.25), radius: s * 0.2, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                    }
                    .stroke(Ed.text3, style: line)
                    .frame(width: s * 0.4, height: s * 0.2)
                    .offset(y: s * 0.17)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            if let note {
                Text(verbatim: note).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2)
                    .padding(.horizontal, Ed.Space.m).padding(.vertical, Ed.Space.s)
                    .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.stageBottom.opacity(0.85)))
                    .offset(y: 0)
            }
        }
    }
}
