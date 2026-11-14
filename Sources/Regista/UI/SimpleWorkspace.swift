import AppKit
import RegistaCore
import SwiftUI

// E5 (#4): the Semplice level — for someone who has never used a video editor. On the left the six steps with their
// state and "Fai tutto"; beside them the open step, a short panel of switches and presets; then one monitor in the
// project's format and, under everything, the edit as a filmstrip. One thing at a time, plain words, never a dead end:
// a step that cannot run says why and offers the way on (import, the step before, install the engine).

/// A Semplice render from sample data (ui.screenshot `simple`): the snapshot drawn and the step open.
struct SimpleDemoValue {
    var snapshot: SimpleSnapshot
    var open: SimpleStep?
}

private struct SimpleDemoKey: EnvironmentKey { static let defaultValue: SimpleDemoValue? = nil }

extension EnvironmentValues {
    var simpleDemo: SimpleDemoValue? {
        get { self[SimpleDemoKey.self] }
        set { self[SimpleDemoKey.self] = newValue }
    }
}

struct SimpleWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.simpleDemo) private var demo

    var body: some View { Live(jobs: store.jobs, voice: store.voice, demo: demo) }

    private struct Live: View {
        @EnvironmentObject private var store: EditorStore
        @ObservedObject var jobs: JobCenter
        @ObservedObject var voice: VoiceModel
        let demo: SimpleDemoValue?
        /// The step the user opened; until then the next one to do.
        @State private var chosen: SimpleStep?

        static let railWidth: CGFloat = 268, panelWidth: CGFloat = 344

        var body: some View {
            let snap = demo?.snapshot ?? store.simpleSnapshot
            let open = demo?.open ?? chosen ?? SimpleStep.allCases.first { snap[$0].status == .running } ?? snap.next ?? .cut
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SimpleRail(snap: snap, open: open) { chosen = $0 }
                        .frame(width: Self.railWidth)
                    SimplePanel(snap: snap, step: open) { chosen = $0 }
                        .frame(width: Self.panelWidth)
                    VStack(spacing: 0) {
                        ProgramPicture(zones: false)
                            .padding(.horizontal, Ed.Space.xl).padding(.top, Ed.Space.l).padding(.bottom, Ed.Space.s)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        TransportBar()
                            .frame(maxWidth: 440)
                            .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous))
                            .padding(.bottom, Ed.Space.m)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Ed.main)
                }
                Filmstrip().frame(height: 112)
            }
            .background(Ed.main)
            .task { if demo == nil { await store.voice.refresh() } }
        }
    }
}

// MARK: - The rail

/// "Fai tutto", the six steps (glyph, name, state in words; the open one marked, the next one tagged) and the export.
private struct SimpleRail: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var prompter = TeleprompterController.shared
    let snap: SimpleSnapshot
    let open: SimpleStep
    let onOpen: (SimpleStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Ed.Space.l) {
                    doAll
                    VStack(spacing: 2) {
                        ForEach(Array(SimpleStep.allCases.enumerated()), id: \.element) { i, step in
                            SimpleStepRow(step: step, number: i + 1, state: snap[step], open: step == open,
                                          next: step == snap.next && step != open) { onOpen(step) }
                        }
                    }
                }
                .padding(Ed.Space.m)
            }
            exportBar
        }
        .background(Ed.side)
        .overlay(alignment: .trailing) { Ed.rule.frame(width: 1) }
    }

    @ViewBuilder private var doAll: some View {
        let pending = SimpleStep.allCases.filter { snap[$0].status == .todo }
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            if let job = snap.allJob, job.isRunning || job.state != .done {
                JobCard(job: job, onCancel: { store.jobs.cancel(job.id) }, onDismiss: { store.jobs.dismiss(job.id) })
            }
            if snap.allJob?.isRunning != true {
                EdButton(title: pending.isEmpty && snap.hasProject ? loc("Tutto fatto") : loc("Fai tutto"), symbol: "wand.and.stars",
                         prominent: snap.canDoEverything && !pending.isEmpty, large: true, fill: true,
                         disabled: !snap.canDoEverything || pending.isEmpty || snap.busy != nil) {
                    store.doEverything(script: prompter.text)
                }
                .tip("Taglia, sceglie le riprese, pulisce la voce, mette i sottotitoli e una luce più viva, in ordine", shortcut: "⇧⌘M")
                Text(verbatim: caption(pending)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func caption(_ pending: [SimpleStep]) -> String {
        if !snap.hasProject || snap[.cut].needsImport { return loc("Importa un video con la voce di chi parla: poi un clic fa il montaggio.") }
        if snap[.cut].status == .unavailable { return snap[.cut].line }
        if pending.isEmpty { return loc("Ogni passo è a posto. Puoi cambiarne uno quando vuoi, poi esporta.") }
        return loc("Fa da solo il montaggio di base. Dopo puoi cambiare ogni passo.")
    }

    /// The reel at −15 LUFS, into Esporta (format 9:16 chosen, the checks beside it).
    private var exportBar: some View {
        let ready = snap.hasProject && snap.next == nil && snap[.cut].status == .done
        return VStack(alignment: .leading, spacing: Ed.Space.xs + 2) {
            EdButton(title: loc("Esporta il reel"), symbol: "square.and.arrow.up", prominent: ready, fill: true,
                     disabled: !snap.hasProject || snap[.cut].needsImport) {
                ExportOptions.shared.preset = "9:16"
                store.select(.export)
            }
            .tip("Apre Esporta con il formato Reel 9:16: voce a −15 LUFS e i controlli prima di salvare")
            Text(verbatim: loc("Reel 9:16 a −15 LUFS, con i controlli prima di salvare."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Ed.Space.m)
        .overlay(alignment: .top) { Ed.rule2.frame(height: 1) }
    }
}

/// One step on the rail.
private struct SimpleStepRow: View {
    let step: SimpleStep
    let number: Int
    let state: SimpleState
    let open: Bool
    let next: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                SimpleGlyph(status: state.status, number: number).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: step.title()).font(Ed.ui(Ed.TypeSize.control, open ? .semibold : .medium))
                            .foregroundStyle(state.status == .blocked ? Ed.text2 : Ed.text).lineLimit(1)
                        if next {
                            Text(verbatim: loc("Prossimo")).font(Ed.ui(Ed.TypeSize.micro, .semibold)).foregroundStyle(Ed.text2)
                                .padding(.horizontal, 5).frame(height: 15)
                                .background(Capsule().fill(Ed.control))
                        }
                    }
                    // Before a video is imported only the first step says so: the others wait silently.
                    if !(state.needsImport && step != .cut) {
                        Text(verbatim: state.line).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(lineColor)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(open ? Ed.control : (hover ? Ed.control.opacity(0.5) : .clear)))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 2, topTrailing: 2)).fill(Ed.gold)
                    .frame(width: 3, height: 22).opacity(open ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(open ? .isSelected : [])
    }

    private var lineColor: Color {
        switch state.status {
        case .done: Ed.ok.opacity(0.9)
        case .unavailable: Ed.warn
        default: Ed.text3
        }
    }
}

/// The state as a glyph: a number to do, a check done, a dash not needed, a warning unavailable, a spinner running.
struct SimpleGlyph: View {
    let status: SimpleState.Status
    let number: Int

    var body: some View {
        ZStack {
            switch status {
            case .done:
                Circle().fill(Ed.ok.opacity(0.18))
                Image(systemName: "checkmark").font(Ed.icon(9, .bold)).foregroundStyle(Ed.ok)
            case .notNeeded:
                Circle().strokeBorder(Ed.line2, lineWidth: 1)
                Image(systemName: "minus").font(Ed.icon(8.5, .bold)).foregroundStyle(Ed.text3)
            case .unavailable:
                Circle().strokeBorder(Ed.warn.opacity(0.7), lineWidth: 1.2)
                Image(systemName: "exclamationmark").font(Ed.icon(9, .bold)).foregroundStyle(Ed.warn)
            case .running:
                Circle().strokeBorder(Ed.line2, lineWidth: 1.2)
                Circle().trim(from: 0, to: 0.3).stroke(Ed.gold, style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).padding(0.8)
                    .rotationEffect(.degrees(-90))
                Circle().fill(Ed.gold).frame(width: 5, height: 5)
            case .blocked:
                Circle().strokeBorder(Ed.line2, lineWidth: 1)
                Text(verbatim: "\(number)").font(Ed.mono(10, .medium)).foregroundStyle(Ed.text4)
            case .todo:
                Circle().strokeBorder(Ed.text3, lineWidth: 1.2)
                Text(verbatim: "\(number)").font(Ed.mono(10, .semibold)).foregroundStyle(Ed.text2)
            }
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - The open step

/// The open step: its name and state, why it cannot run (and the way on), its switches and presets, its job, then the
/// next step to do (or the export).
private struct SimplePanel: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.openSettings) private var openSettings
    let snap: SimpleSnapshot
    let step: SimpleStep
    let onOpen: (SimpleStep) -> Void

    private var state: SimpleState { snap[step] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Ed.Space.xl) {
                    header
                    if let job = snap.jobs[step], job.isRunning || isFailed(job) {
                        JobCard(job: job, onCancel: { store.jobs.cancel(job.id) }, onDismiss: { store.jobs.dismiss(job.id) })
                    }
                    if state.status == .blocked || state.status == .unavailable { wayOn }
                    // Nothing to set before there is a video; otherwise the controls stay visible, disabled while they cannot act.
                    if !state.needsImport {
                        content
                            .disabled(state.status == .blocked || state.status == .unavailable || state.status == .running || snap.allJob?.isRunning == true)
                            .opacity(state.status == .blocked || state.status == .unavailable ? 0.45 : 1)
                    }
                }
                .padding(Ed.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .background(Ed.panel)
        .overlay(alignment: .trailing) { Ed.rule.frame(width: 1) }
    }

    private func isFailed(_ j: JobCenter.Job) -> Bool { if case .failed = j.state { return true }; return false }

    private var header: some View {
        HStack(alignment: .top, spacing: Ed.Space.m) {
            Image(systemName: step.symbol).font(Ed.icon(14, .medium)).foregroundStyle(Ed.text2)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(Ed.raised))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: step.title()).font(Ed.ui(Ed.TypeSize.heading - 1, .semibold)).foregroundStyle(Ed.text)
                Text(verbatim: Self.purpose(step)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the step is for, in one sentence.
    static func purpose(_ s: SimpleStep) -> String {
        switch s {
        case .cut: loc("Le pause lunghe spariscono e di ogni frase resta la ripresa migliore.")
        case .captions: loc("Le parole compaiono mentre parli, con le più importanti evidenziate.")
        case .look: loc("La luce e il colore di tutto il video.")
        case .sound: loc("Una musica sotto la voce e qualche suono sui tagli.")
        case .voice: loc("Una voce pulita, al volume giusto per i social.")
        case .graphics: loc("Un titolo, il logo o una scheda animata, se servono.")
        }
    }

    /// Why the step cannot run, and the way to what is missing.
    @ViewBuilder private var wayOn: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s + 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: state.status == .unavailable ? "exclamationmark.triangle" : "lock").font(Ed.icon(10.5))
                    .foregroundStyle(state.status == .unavailable ? Ed.warn : Ed.text3)
                Text(verbatim: state.line).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
            }
            if state.needsImport {
                EdButton(title: loc("Importa un video…"), symbol: "square.and.arrow.down", prominent: true) { Panels.importMedia(store) }
            } else if let engine = state.install {
                EdButton(title: loc("Installa…"), symbol: "arrow.down.circle") { SettingsRoute.open(.engines, engine: engine, with: openSettings) }
            } else if let need = state.needs {
                EdButton(title: String(format: loc("Vai a «%@»"), need.title()), symbol: "arrow.turn.left.up") { onOpen(need) }
            }
        }
        .padding(Ed.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(Ed.well))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).strokeBorder(Ed.line))
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .cut: CutPanel(snap: snap)
        case .captions: CaptionsPanel(snap: snap)
        case .look: LookPanel(snap: snap)
        case .sound: SoundPanel(snap: snap)
        case .voice: VoicePanelSimple(snap: snap)
        case .graphics: GraphicsPanelSimple(snap: snap)
        }
    }

    /// The next step to do, or the export when every step is in place.
    @ViewBuilder private var footer: some View {
        if let next = snap.next, next != step {
            footerBar {
                Text(verbatim: loc("Prossimo passo")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                Spacer(minLength: 4)
                EdButton(title: next.title(), symbol: "arrow.right") { onOpen(next) }
            }
        } else if snap.next == nil, snap.hasProject, snap[.cut].status == .done {
            footerBar {
                Text(verbatim: loc("Ogni passo è a posto")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                Spacer(minLength: 4)
                EdButton(title: loc("Esporta il reel"), symbol: "square.and.arrow.up") {
                    ExportOptions.shared.preset = "9:16"
                    store.select(.export)
                }
            }
        }
    }

    private func footerBar<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: Ed.Space.s) { c() }
            .padding(.horizontal, Ed.Space.l).frame(height: 52)
            .overlay(alignment: .top) { Ed.rule2.frame(height: 1) }
    }
}

/// A group of controls under its small heading (none when the title is empty).
private struct StepGroup<C: View>: View {
    let title: String
    @ViewBuilder let content: () -> C

    init(_ title: String, @ViewBuilder content: @escaping () -> C) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s + 2) {
            if !title.isEmpty { SectionLabel(title) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A dim sentence under a control.
private func note(_ text: String) -> some View {
    Text(verbatim: text).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
}

/// Pro, on one of its panels: where the rest of a step lives.
@MainActor
private func openPro(_ store: EditorStore, _ go: (inout Navigation) -> Void) {
    store.workspace = .pro
    go(&store.nav)
}

// MARK: - Taglio e riprese

private struct CutPanel: View {
    @EnvironmentObject private var store: EditorStore
    let snap: SimpleSnapshot
    @State private var draft: CutPreset = .medium
    @State private var pausesDraft = true

    private var cut: Bool { snap[.cut].status == .done || store.project?.takes != nil || snap.retakes.count > 0 }

    var body: some View {
        let preset = cut ? (snap.cutPreset ?? .medium) : draft
        let pauses = cut ? snap.pauses : pausesDraft
        VStack(alignment: .leading, spacing: Ed.Space.xl) {
            StepGroup("PAUSE") {
                RToggle(title: "Togli le pause lunghe", isOn: Binding(get: { pauses }, set: { on in
                    if cut { store.simpleCut(preset, pauses: on) } else { pausesDraft = on }
                }), subtitle: "Resta un respiro prima e dopo ogni frase.")
                RSegmented(items: CutPreset.allCases.map { ($0, $0.title) }, selection: Binding(get: { preset }, set: { p in
                    if cut { store.simpleCut(p, pauses: pauses) } else { draft = p }
                }), tips: [.natural: "Lascia le pause brevi: un ritmo calmo", .medium: "Il ritmo dei reel approvati",
                           .tight: "Taglia quasi tutte le pause: un ritmo veloce"])
                .disabled(!pauses).opacity(pauses ? 1 : 0.45)
            }
            if !cut, snap[.cut].status != .running, snap.allJob?.isRunning != true {
                EdButton(title: loc("Taglia il video"), symbol: "scissors", prominent: true, fill: true, disabled: snap.busy != nil) {
                    store.simpleCut(draft, pauses: pausesDraft)
                }
            } else if cut {
                StepGroup("RIPRESE") {
                    if snap.retakes.isEmpty {
                        note(loc("Ogni frase è stata detta una volta sola: non c'è niente da scegliere."))
                    } else {
                        note(loc("Queste frasi le hai dette più volte. È scelta la ripresa migliore: provane un'altra se preferisci."))
                        ForEach(snap.retakes.prefix(5)) { r in RetakeRow(retake: r) }
                        if snap.retakes.count > 5 {
                            AccentLinkButton(title: String(format: loc("Altre %d frasi in Pro"), snap.retakes.count - 5)) {
                                openPro(store) { $0.select(.texts); $0.textsTab = .takes }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RetakeRow: View {
    @EnvironmentObject private var store: EditorStore
    let retake: Retake

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(retake.line)").font(Ed.mono(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.text3).frame(width: 16, alignment: .trailing)
                Text(verbatim: retake.text).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2).lineLimit(2)
            }
            RSegmented(items: (1...retake.takes).map { ($0, String(format: loc("Ripresa %d"), $0)) },
                       selection: Binding(get: { retake.chosen ?? 0 }, set: { store.runSimple(SimpleCalls.pick(line: retake.line, take: $0)) }),
                       height: 24)
                .padding(.leading, 22)
        }
    }
}

// MARK: - Sottotitoli

/// The caption styles in words.
func captionStyleName(_ id: String) -> String {
    switch id {
    case "elegant-serif": loc("Serif elegante")
    case "bold-keyword": loc("Bold + parola chiave")
    case "ghost-karaoke": loc("Karaoke fantasma")
    default: loc("Talking head")
    }
}

private struct CaptionsPanel: View {
    @EnvironmentObject private var store: EditorStore
    let snap: SimpleSnapshot
    @AppStorage(StepSettings.styleKey) private var saved = CaptionStyle.talkingHeadV1.id

    var body: some View {
        let on = snap.captionsTrack != nil
        let style = on ? snap.captionStyle : saved
        VStack(alignment: .leading, spacing: Ed.Space.xl) {
            StepGroup("") {
                RToggle(title: "Sottotitoli nel video", isOn: Binding(get: { on }, set: { store.simpleCaptions(on: $0, style: style) }),
                        subtitle: on ? String(format: loc("%d parole evidenziate"), snap.keywords) : "Si creano dal parlato, in pochi secondi.")
            }
            StepGroup("STILE") {
                RChips(items: CaptionStyle.all.map { .init(id: $0.id, title: captionStyleName($0.id)) }, selection: style, columns: 2, height: 30) {
                    store.simpleCaptionStyle($0)
                }
                note(loc("Talking head è lo stile dei reel approvati: maiuscole, parola chiave in un riquadro."))
            }
            if on {
                AccentLinkButton(title: loc("Parole chiave e testo in Pro")) { openPro(store) { $0.select(.texts); $0.textsTab = .captions } }
            }
        }
    }
}

// MARK: - Aspetto

private struct LookPanel: View {
    @EnvironmentObject private var store: EditorStore
    let snap: SimpleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.xl) {
            StepGroup("LUCE") {
                RToggle(title: "Luce leggera", isOn: Binding(get: { snap.light }, set: { on in
                    if let t = snap.videoTrack { store.runSimple(SimpleCalls.light(on, trackID: t)) }
                }), subtitle: "Un po' più di luce, contrasto e colore.")
            }
            StepGroup("COLORE") {
                RChips(items: SimpleLooks.ids.map { .init(id: $0, title: SimpleLooks.title($0)) }, selection: snap.look, columns: 3, height: 30) { id in
                    store.runSimple(SimpleCalls.look(id, amount: snap.look == "none" ? 0.6 : SimpleLooks.nearestAmount(snap.lookAmount)))
                }
                if snap.look != "none" {
                    RSegmented(items: SimpleLooks.amounts.map { ($0.id, $0.title) },
                               selection: Binding(get: { SimpleLooks.nearestAmount(snap.lookAmount) }, set: { store.runSimple(SimpleCalls.look(snap.look, amount: $0)) }))
                }
                note(loc("Un solo colore per tutto il video: è quello che si vede meglio."))
            }
            AccentLinkButton(title: loc("Altri filtri e regolazioni in Pro")) { openPro(store) { $0.showGraphics(.filters) } }
        }
    }
}

// MARK: - Musica e suoni

private struct SoundPanel: View {
    @EnvironmentObject private var store: EditorStore
    let snap: SimpleSnapshot

    private var canCutSounds: Bool { (store.project.flatMap(SimpleSnapshot.mainVideo)?.clips.count ?? 0) > 1 || snap.effects > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.xl) {
            StepGroup("MUSICA") {
                if let m = snap.music {
                    HStack(spacing: Ed.Space.s) {
                        Image(systemName: "music.note").font(Ed.icon(11, .medium)).foregroundStyle(Ed.musicWave)
                            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(Ed.musicWave.opacity(0.14)))
                        Text(verbatim: m.name).font(Ed.ui(Ed.TypeSize.body, .medium)).foregroundStyle(Ed.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        IconButton(symbol: "xmark", help: "Togli la musica") {
                            if let t = AudioCalls.musicTrack(store.project) { store.runSimple(SimpleCalls.removeMusic(t)) }
                        }
                    }
                    RSegmented(items: MusicLevel.allCases.map { ($0, $0.title) },
                               selection: Binding(get: { m.level ?? .medium }, set: { store.simpleMusicLevel($0) }),
                               tips: [.low: "Appena percettibile sotto la voce", .medium: "Il livello che mette Regista", .high: "Più presente, sempre sotto la voce"])
                    RToggle(title: "Si abbassa quando parli", isOn: Binding(get: { m.ducking }, set: { on in
                        store.runSimple(AudioCalls.duck(trackID: m.trackID, depth: on ? AudioCalls.defaultDepth : 0))
                    }), subtitle: "E risale nelle pause.")
                } else {
                    note(loc("La musica dura quanto il video e si abbassa da sola quando parli."))
                    ForEach(snap.musicFiles.prefix(3), id: \.id) { a in
                        SideRow(symbol: "waveform", title: a.name, detail: clockTime(a.duration.seconds)) { store.addMusic(URL(fileURLWithPath: a.path)) }
                    }
                    EdButton(title: loc("Scegli una musica…"), symbol: "music.note", disabled: snap.busy != nil) { Panels.addMusic(store) }
                }
            }
            .task(id: snap.music?.trackID) {
                if let p = store.project, let m = AudioCalls.musicTrack(p), let a = p.asset(m.clips[0].assetID) { await store.measureMusic(a) }
            }
            StepGroup("EFFETTI SONORI") {
                RToggle(title: "Un whoosh sui tagli", isOn: Binding(get: { snap.effects > 0 }, set: { store.runSimple(SimpleCalls.soundEffects($0)) }),
                        subtitle: canCutSounds ? "Leggero, al massimo sei, a qualche secondo l'uno dall'altro."
                                               : "Prima taglia il video: i suoni vanno sui tagli.")
                    .disabled(!canCutSounds)
            }
            AccentLinkButton(title: loc("Scegli i suoni uno per uno in Pro")) { openPro(store) { $0.select(.audio); $0.soundTab = .sfx } }
        }
    }
}

// MARK: - Voce

private struct VoicePanelSimple: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.openSettings) private var openSettings
    let snap: SimpleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.xl) {
            StepGroup("PULIZIA") {
                RToggle(title: "Pulisci la voce", isOn: Binding(get: { snap.cleaned }, set: { store.simpleClean($0) }),
                        subtitle: "Toglie il rumore e porta la voce a −15 LUFS, il volume giusto per Instagram.")
            }
            StepGroup("VOCE FUORI CAMPO") { voiceOver }
        }
    }

    @ViewBuilder private var voiceOver: some View {
        switch snap.voiceOver {
        case .ready:
            VoiceOverComposer(model: store.voice)
        case .engineMissing(let why):
            note(why)
            EdButton(title: loc("Installa…"), symbol: "arrow.down.circle") { SettingsRoute.open(.engines, engine: "voxcpm", with: openSettings) }
        case .noProfile:
            note(loc("Per dire un testo con la tua voce serve prima registrarla, una volta sola."))
            AccentLinkButton(title: loc("Prepara la tua voce")) { openPro(store) { $0.select(.voice) } }
        case .noVoice:
            note(loc("Il tuo profilo non ha ancora una voce pronta: registrala una volta, poi la usi qui."))
            AccentLinkButton(title: loc("Prepara la tua voce")) { openPro(store) { $0.select(.voice) } }
        case .locked:
            note(loc("Il profilo viene da un altro Mac: adottalo in Impostazioni › Profilo e voce."))
        case nil:
            note(loc("Controllo la tua voce…"))
        }
    }
}

/// A text said in the user's cloned voice, placed after the voice (voice.preview, then voice.say: the Voce panel's job).
private struct VoiceOverComposer: View {
    @ObservedObject var model: VoiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            TextField(loc("Scrivi cosa deve dire la tua voce"), text: $model.text, axis: .vertical)
                .textFieldStyle(.plain).font(Ed.ui(Ed.TypeSize.body)).lineLimit(3...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(Ed.well))
                .overlay(RoundedRectangle(cornerRadius: Ed.Radius.m).strokeBorder(Ed.line2))
            EdButton(title: loc("Metti nel video"), symbol: "waveform.badge.plus",
                     disabled: model.paragraphs.isEmpty || model.jobs?.latest("voice")?.isRunning == true) { model.place() }
        }
    }
}

// MARK: - Grafica

private struct GraphicsPanelSimple: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    let snap: SimpleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.xl) {
            StepGroup("TITOLO") {
                if let item = EffectsCatalog.named("text-hook") { CatalogRowItem(item: item) }
            }
            StepGroup("LOGO") {
                RToggle(title: "Logo nel video", isOn: Binding(get: { !snap.logoClips.isEmpty }, set: { on in
                    store.runSimple(on ? SimpleCalls.logo(snap.logoPlacement) : SimpleCalls.removeClips(snap.logoClips))
                }), subtitle: snap.logoReason ?? "Nell'angolo della marca, per tutto il video.")
                .disabled(snap.logoReason != nil && snap.logoClips.isEmpty)
            }
            StepGroup("SCHEDE ANIMATE") {
                ForEach(SimpleGraphics.templates, id: \.self) { id in
                    if let item = EffectsCatalog.named(id) { CatalogRowItem(item: item) }
                }
                note(loc("Si aggiungono alla testina: sposta prima la testina sulla frase giusta."))
            }
            AccentLinkButton(title: loc("Altre grafiche in Pro")) { openPro(store) { $0.showGraphics(.motion) } }
        }
        .onAppear { store.previews.refresh(at: playhead.time) }
    }
}

// MARK: - Filmstrip

/// The edit as a strip you can read: a time ruler, the clips as real frames, the playhead with its timecode, and above
/// the frames one bar per effect, graphic, transition or speed change (AppliedItems) — click a bar to go there and
/// pick it, ✕ on the picked bar removes it. Drag on the frames to scrub; drop a gallery tile to apply it there.
struct Filmstrip: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var media: MediaCache
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var studio = GraphicsState.shared
    /// Show the effect bars.
    var effects = true

    static let ruler: CGFloat = 18, lane: CGFloat = 16, maxLanes = 3, pad: CGFloat = 16

    var body: some View {
        GeometryReader { g in
            let p = store.project
            let duration = max(p?.duration.seconds ?? 0, 0.001)
            let W = g.size.width - Self.pad * 2
            let items = effects ? AppliedItems.list(p) : []
            let rows = Array(AppliedItems.rows(items, minimumGap: Double(70 / max(W, 1)) * duration).prefix(Self.maxLanes))
            let lanesH = effects ? CGFloat(max(rows.count, 1)) * Self.lane + 4 : 0
            let framesTop = Self.ruler + lanesH
            let H = max(g.size.height - framesTop - 8, 24)
            let x = { (t: Double) in CGFloat(t / duration) * W }
            let _ = media.revision
            ZStack(alignment: .topLeading) {
                rulerView(duration: duration, width: W)
                if effects {
                    if items.isEmpty, p?.duration ?? .zero > .zero {
                        Text("Gli effetti che aggiungi compaiono qui, nel punto dove li hai messi")
                            .font(Ed.ui(10)).foregroundStyle(Ed.text3)
                            .offset(y: Self.ruler + 1)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        ForEach(row) { it in bar(it, x: x(it.start), width: max(x(it.end) - x(it.start), 6)).offset(y: Self.ruler + CGFloat(r) * Self.lane) }
                    }
                }
                frames(p, duration: duration, width: W, height: H).frame(width: W, height: H).offset(y: framesTop)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        store.preview.seek(Double(min(max(v.location.x, 0), W) / W) * duration)
                    })
                // Playhead through ruler, bars and frames, with its timecode.
                Rectangle().fill(Ed.gold).frame(width: 2, height: g.size.height - 4)
                    .offset(x: x(playhead.time) - 1, y: 2).shadow(color: .black.opacity(0.6), radius: 2).allowsHitTesting(false)
                Text(verbatim: shortTime(playhead.time)).font(Ed.mono(9.5, .semibold)).foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 4).frame(height: 14).background(RoundedRectangle(cornerRadius: 3).fill(Ed.gold))
                    .fixedSize().offset(x: min(max(x(playhead.time) - 18, 0), W - 36), y: 1).allowsHitTesting(false)
            }
            .padding(.horizontal, Self.pad)
            .padding(.top, 4)
            // A Graphics panel row dropped on the strip applies at that moment (issue #16, E4 #3).
            .onDrop(of: [.text], isTargeted: nil) { providers, loc in
                guard let pr = providers.first else { return false }
                let time = Double(min(max(loc.x - Self.pad, 0), W) / W) * duration
                _ = pr.loadObject(ofClass: NSString.self) { s, _ in
                    guard let id = s as? String else { return }
                    DispatchQueue.main.async { GraphicsActions.apply(id, store: store, at: time) }
                }
                return true
            }
        }
        .background(Ed.panel)
        .overlay(alignment: .top) { Ed.line.frame(height: 1) }
    }

    private func rulerView(duration: Double, width W: CGFloat) -> some View {
        // A label every 1, 2, 5, 10… s so labels stay ≥ 60 px apart.
        let step = [1.0, 2, 5, 10, 15, 30, 60].first { CGFloat($0 / duration) * W >= 60 } ?? 60
        return Canvas { ctx, size in
            var t = 0.0
            while t <= duration + 0.001 {
                let px = CGFloat(t / duration) * W
                ctx.fill(Path(CGRect(x: px, y: size.height - 5, width: 1, height: 5)), with: .color(Ed.text3))
                ctx.draw(Text(verbatim: shortTime(t)).font(Ed.mono(9)).foregroundStyle(Ed.text3), at: CGPoint(x: px + 3, y: 6), anchor: .topLeading)
                t += step
            }
        }
        .frame(width: W, height: Self.ruler)
        .allowsHitTesting(false)
    }

    private func bar(_ it: AppliedItem, x: CGFloat, width: CGFloat) -> some View {
        let on = studio.appliedSelection == it.id
        return HStack(spacing: 3) {
            Image(systemName: it.symbol).font(Ed.icon(8, .semibold))
            if width > 46 { Text(verbatim: loc(it.label)).font(Ed.ui(9.5, .semibold)).lineLimit(1) }
            Spacer(minLength: 0)
            if on {
                Button { studio.appliedSelection = nil; store.run(it.command, .object(it.params)) } label: {
                    Image(systemName: "xmark").font(Ed.icon(8, .bold))
                }
                .buttonStyle(.plain).tip("Togli")
            }
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .padding(.horizontal, 4)
        .frame(width: max(width, on ? 34 : width), height: Self.lane - 3, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(it.color.opacity(on ? 1 : 0.85)))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? Color.white : .clear, lineWidth: 1.5))
        .offset(x: x)
        .onTapGesture { studio.appliedSelection = it.id; store.preview.seek(it.start) }
        .tip("\(loc(it.label)) · \(shortTime(it.start))–\(shortTime(it.end))")
    }

    private func frames(_ p: Project?, duration: Double, width W: CGFloat, height H: CGFloat) -> some View {
        Canvas { ctx, size in
            MainActor.assumeIsolated {
                guard let p, let track = p.tracks.first(where: { $0.kind == .video }) else { return }
                let pps = W / duration
                for clip in track.clips {
                    guard let a = p.asset(clip.assetID), let v = a.video else { continue }
                    let rect = CGRect(x: clip.start.seconds * pps, y: 0, width: clip.duration.seconds * pps, height: H)
                    let tw = H * CGFloat(v.width) / CGFloat(max(v.height, 1))
                    ctx.drawLayer { l in
                        l.clip(to: Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0), cornerRadius: 4))
                        var x = rect.minX
                        while x < rect.maxX {
                            if let img = media.thumbnail(a.path, at: clip.sourceIn.seconds + Double((x - rect.minX) / pps)) {
                                l.draw(Image(decorative: img, scale: 1), in: CGRect(x: x, y: 0, width: tw, height: H))
                            }
                            x += tw
                        }
                    }
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0), cornerRadius: 4), with: .color(Color.black.opacity(0.85)), lineWidth: 2)
                }
            }
        }
    }
}

// MARK: - Sample data for renders

/// The Semplice level in a given state from sample data, on top of the project the render shows (ui.screenshot `simple`):
/// midway (cut and captions done, two lines with retakes), done (every step in place), doall ("Fai tutto" on its third
/// step). No engine runs and no project is touched.
enum SimpleDemo {
    static let states = ["midway", "done", "doall"]

    static func value(_ state: String, open: SimpleStep?, live: SimpleSnapshot, lookup: (String) -> String = loc) -> SimpleDemoValue {
        var s = live
        func st(_ status: SimpleState.Status, _ line: String) -> SimpleState { SimpleState(status: status, line: line) }
        s.hasProject = true
        s.engines = .ready
        // l10n-ignore-begin: sample lines of a script stand for the user's own words (content, not UI)
        s.retakes = [Retake(line: 1, text: "Ciao, oggi vi mostro come si monta un reel.", takes: 3, chosen: 3),
                     Retake(line: 4, text: "Le pause spariscono da sole.", takes: 2, chosen: 2)]
        // l10n-ignore-end
        s.cutPreset = .medium
        s.pauses = true
        s.states[.cut] = st(.done, String(format: lookup("%d tagli · %@ di montaggio"), 9, "0:42"))
        s.states[.captions] = st(.done, String(format: lookup("%d blocchi · %d parole chiave"), 31, 7))
        s.captionsTrack = s.captionsTrack ?? "demo"
        s.keywords = 7
        s.states[.look] = st(.todo, lookup("Una luce più viva e, se vuoi, un colore per tutto il video."))
        s.states[.sound] = st(.notNeeded, lookup("Facoltativo: la musica di tendenza si aggiunge di solito su Instagram."))
        s.states[.voice] = st(.todo, lookup("Toglie il rumore e porta la voce a −15 LUFS."))
        s.states[.graphics] = st(.notNeeded, lookup("Facoltativo: un titolo, il logo o una scheda animata."))
        s.voiceOver = .ready
        s.jobs = [:]
        s.allJob = nil
        switch state {
        case "done":
            s.states[.look] = st(.done, lookup("Pellicola") + " · " + lookup("luce leggera"))
            s.light = true
            s.look = "film"
            s.states[.voice] = st(.done, lookup("Voce pulita, a −15 LUFS."))
            s.cleaned = true
        case "doall":
            s.states = s.states.mapValues { _ in st(.todo, "") }
            s.states[.cut] = st(.running, lookup("Toglie le pause e tiene la ripresa migliore di ogni frase."))
            s.states[.captions] = st(.todo, lookup("Parola per parola, con le parole chiave evidenziate."))
            s.states[.look] = st(.todo, lookup("Una luce più viva e, se vuoi, un colore per tutto il video."))
            s.states[.sound] = st(.notNeeded, lookup("Facoltativo: la musica di tendenza si aggiunge di solito su Instagram."))
            s.states[.voice] = st(.todo, lookup("Toglie il rumore e porta la voce a −15 LUFS."))
            s.states[.graphics] = st(.notNeeded, lookup("Facoltativo: un titolo, il logo o una scheda animata."))
            s.retakes = []
            s.captionsTrack = nil
            var all = JobCenter.Job(id: UUID(), kind: TextStep.allJobKind, title: lookup("Fai tutto"), detail: lookup("Taglio le pause e monto le riprese…"),
                                    progress: 0.34, cancellable: true, started: Date() - 52)
            all.steps = (SimpleCalls.doEverythingSteps(hasScriptText: false, engines: .ready).map { $0.title(lookup) }) + [SimpleStep.look.title(lookup)]
            all.stepIndex = 2
            s.allJob = all
        default:   // midway
            if open == .sound {   // the panel with a music bed and the whooshes in (sample values)
                s.music = SimpleMusic(trackID: "demo", name: "music-bed.wav", ducking: true, level: .medium)  // l10n-ignore
                s.effects = 4
                s.states[.sound] = st(.done, lookup("Musica sotto la voce") + " · " + String(format: lookup("%d effetti sonori"), 4))
            }
        }
        return SimpleDemoValue(snapshot: s, open: open)
    }
}
