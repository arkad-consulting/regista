import AppKit
import RegistaCore
import SwiftUI
import UniformTypeIdentifiers

// The Audio activity (E3 #55): the mix — the level of the edit against the house target, the music on its own lane with
// ducking under the voice, the voice clean-up, the tracks — and the sound-effect browser over the shipped bank. Every
// control runs a command through the tab's store; previews play on their own and never touch the edit.

/// Sample state for ui.screenshot `audio` (renders only): the sub-tab, the open group, a search, the level and a
/// ducking check to draw instead of the live ones.
struct AudioDemo {
    var tab: Navigation.SoundTab?
    var group: String?
    var query: String?
    var integrated: Double?
    var truePeak: Double?
    var check: MusicCheck?
    var playing: String?

    static func from(_ v: JSONValue?) -> AudioDemo? {
        guard let v, v.objectValue != nil else { return nil }
        var d = AudioDemo()
        d.tab = v["tab"]?.stringValue.flatMap(Navigation.SoundTab.init(rawValue:))
        d.group = v["group"]?.stringValue
        d.query = v["query"]?.stringValue
        d.integrated = v["loudness"]?.arrayValue?.first?.doubleValue
        d.truePeak = v["loudness"]?.arrayValue?.dropFirst().first?.doubleValue
        if let c = v["check"], c.objectValue != nil { d.check = AudioCalls.duckingResult(c) }
        d.playing = v["playing"]?.stringValue
        return d
    }
}

private struct AudioDemoKey: EnvironmentKey { static let defaultValue: AudioDemo? = nil }

extension EnvironmentValues {
    var audioDemo: AudioDemo? {
        get { self[AudioDemoKey.self] }
        set { self[AudioDemoKey.self] = newValue }
    }
}

struct AudioPanel: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.audioDemo) private var demo
    let tab: Navigation.SoundTab

    var body: some View {
        let shown = demo?.tab ?? tab
        VStack(spacing: 0) {
            RSegmented(items: [(.mix, "Mix"), (.sfx, "Effetti sonori")], selection: Binding(get: { shown }, set: { store.nav.soundTab = $0 }),
                       tips: [.mix: "Livello, musica, voce e piste", .sfx: "Sfoglia, ascolta e metti gli effetti sulla pista Effetti"])
                .padding(.horizontal, Ed.Space.m).padding(.vertical, 10)
            switch shown {
            case .mix: AudioMixTab()
            case .sfx: SoundBrowser()
            }
        }
    }
}

// MARK: - Mix

struct AudioMixTab: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var meter: LoudnessMeter
    @Environment(\.audioDemo) private var demo

    var body: some View {
        let tracks = store.project?.tracks.filter { $0.kind == .audio } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(loc("audio.level")) { LevelSection(integrated: demo?.integrated ?? meter.curve.integrated,
                                                      truePeak: demo?.truePeak ?? meter.curve.truePeak,
                                                      measuring: demo == nil && meter.measuring) }
                section(loc("Musica")) { MusicSection() }
                section(loc("Voce")) {
                    // Pulisci la voce as a job with its state (E2 #54): to do, done, to redo after a new cut, or what is missing.
                    StepOffer(step: .clean, compact: true)
                }
                section(loc("Piste")) {
                    if tracks.isEmpty { Text(verbatim: loc("Nessuna pista audio.")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3) }
                    ForEach(tracks, id: \.id) { t in
                        HStack(spacing: Ed.Space.s) {
                            Circle().fill(ClipPalette.edge(t.role == "music" ? .music : t.role == "sfx" ? .sfx : .voice)).frame(width: 6, height: 6)
                            Text(verbatim: trackName(t)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text).lineLimit(1)
                            Text(verbatim: t.clips.count == 1 ? loc("1 clip") : String(format: loc("%d clip"), t.clips.count)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                            if store.project?.asset(t.clips.first?.assetID ?? "")?.origin != nil {
                                Text(verbatim: loc("voce pulita")).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.ok)
                            }
                            if t.ducking != nil {
                                Image(systemName: "arrow.down.right").font(Ed.icon(Ed.TypeSize.micro, .semibold)).foregroundStyle(Ed.musicWave)
                                    .tip("Si abbassa sotto la voce")
                            }
                            Spacer()
                            IconButton(symbol: t.muted ? "speaker.slash.fill" : "speaker.wave.2", help: t.muted ? "Riattiva l'audio" : "Muto", active: t.muted) {
                                store.setTrack(t.id, "muted", !t.muted)
                            }
                        }
                    }
                }
            }
            .padding(Ed.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The track as its timeline lane names it (#92: never «A1»), in the user's language; a name of the user's own stays.
    private func trackName(_ t: Track) -> String { Self.trackName(t, in: store.project) }

    static func trackName(_ t: Track, in project: Project?) -> String {
        loc(LaneRow.rows(project).first { $0.track?.id == t.id }?.title ?? t.name)
    }
}

/// The edit's loudness against the target: the value, a verdict, a strip with the target band, the true peak and what
/// to do about it.
struct LevelSection: View {
    @EnvironmentObject private var store: EditorStore
    let integrated: Double
    let truePeak: Double
    let measuring: Bool

    private static let range = -30.0 ... -6.0

    var body: some View {
        let verdict = LoudnessTarget.verdict(integrated: integrated)
        let peakOver = LoudnessTarget.peakOver(truePeak)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: Ed.Space.xs) {
                Text(verbatim: integrated.isFinite ? Fmt.number(integrated) : (measuring ? "…" : "–"))
                    .font(Ed.mono(Ed.TypeSize.large, .medium)).foregroundStyle(Ed.text).monospacedDigit()
                Text(verbatim: "LUFS").font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3)
                Spacer(minLength: 6)
                VerdictChip(verdict: verdict)
            }
            strip(verdict)
            HStack(spacing: 6) {
                Text(verbatim: loc("Picco reale")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                Text(verbatim: truePeak.isFinite ? "\(Fmt.number(truePeak)) dBTP" : "–")
                    .font(Ed.mono(Ed.TypeSize.small, .medium)).foregroundStyle(peakOver ? Ed.warn : Ed.text2)
                Spacer()
            }
            Text(verbatim: String(format: loc("Obiettivo: %@ LUFS, picco fino a %@ dBTP."),
                                  Fmt.number(LoudnessTarget.integrated), Fmt.number(LoudnessTarget.truePeak)))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            if peakOver && verdict != .tooLoud {
                hint(loc("Qualche picco supera il limite: all'esportazione il limitatore lo contiene."))
            }
            advice(verdict)
        }
    }

    /// −30 … −6 LUFS: the ±1 LU target band in the accent, the edit's level as a marker in its verdict's colour.
    private func strip(_ verdict: LoudnessTarget.Verdict) -> some View {
        let lo = Self.range.lowerBound, span = Self.range.upperBound - lo
        let x = { (v: Double) in CGFloat(min(max((v - lo) / span, 0), 1)) }
        return VStack(spacing: 3) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Ed.well).overlay(Capsule().strokeBorder(Ed.line2))
                    Rectangle().fill(Ed.goldSoft)
                        .frame(width: w * (x(LoudnessTarget.integrated + LoudnessTarget.tolerance) - x(LoudnessTarget.integrated - LoudnessTarget.tolerance)))
                        .offset(x: w * x(LoudnessTarget.integrated - LoudnessTarget.tolerance))
                    Rectangle().fill(Ed.gold.opacity(0.7)).frame(width: 1).offset(x: w * x(LoudnessTarget.integrated))
                    if integrated.isFinite {
                        RoundedRectangle(cornerRadius: Ed.Radius.xs).fill(VerdictChip.color(verdict))
                            .frame(width: 3, height: 14).offset(x: w * x(integrated) - 3 / 2)
                    }
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            HStack {
                Text(verbatim: Fmt.number(lo)).font(Ed.mono(Ed.TypeSize.tiny)).foregroundStyle(Ed.text3)
                Spacer()
                Text(verbatim: Fmt.number(Self.range.upperBound)).font(Ed.mono(Ed.TypeSize.tiny)).foregroundStyle(Ed.text3)
            }
        }
    }

    @ViewBuilder private func advice(_ verdict: LoudnessTarget.Verdict) -> some View {
        if verdict == .tooQuiet || verdict == .tooLoud {
            let clean = store.textSteps[.clean]
            let music = AudioCalls.musicTrack(store.project) != nil
            if clean.status == .done {
                hint(verdict == .tooLoud && music ? loc("La voce è già a posto: è la musica ad alzare il mix. Abbassane il volume qui sotto.")
                                                  : loc("La voce è già pulita: controlla il volume delle altre piste."))
            } else {
                EdButton(title: String(format: loc("Porta a %@ LUFS"), Fmt.number(LoudnessTarget.integrated)), symbol: "dial.medium",
                         prominent: clean.canRun, disabled: !clean.canRun || store.runningStepJob != nil) {
                    store.runStep(.clean, settings: StepSettings.saved(project: store.project))
                }
                .tip("Pulisce la voce e la porta al livello giusto (un passo annullabile)")
                if !clean.canRun { hint(clean.line) }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(verbatim: text).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
    }
}

struct VerdictChip: View {
    let verdict: LoudnessTarget.Verdict

    static func color(_ v: LoudnessTarget.Verdict) -> Color {
        switch v {
        case .ok: Ed.ok
        case .tooQuiet: Ed.warn
        case .tooLoud: Ed.danger
        case .unmeasured: Ed.text3
        }
    }

    var body: some View {
        let (title, symbol): (String, String) = switch verdict {
        case .ok: (loc("OK"), "checkmark")
        case .tooQuiet: (loc("Troppo basso"), "arrow.down")
        case .tooLoud: (loc("Troppo alto"), "arrow.up")
        case .unmeasured: (loc("Da misurare"), "ellipsis")
        }
        let c = Self.color(verdict)
        HStack(spacing: Ed.Space.xs) {
            Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.tiny, .bold))
            Text(verbatim: title).font(Ed.ui(Ed.TypeSize.caption, .semibold))
        }
        .foregroundStyle(c)
        .padding(.horizontal, Ed.Space.s).frame(height: 20)
        .background(Capsule().fill(c.opacity(0.14)))
        .overlay(Capsule().strokeBorder(c.opacity(0.35)))
    }
}

/// The music bed: add it (audio.addMusic: on the Musica lane, fitted to the edit, ducked under the voice), its volume,
/// its ducking, and the check under the voice.
struct MusicSection: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.audioDemo) private var demo

    var body: some View { Content(jobs: store.jobs) }

    private struct Content: View {
        @EnvironmentObject private var store: EditorStore
        @Environment(\.audioDemo) private var demo
        @ObservedObject var jobs: JobCenter
        @State private var volumeDraft: Double?
        @State private var depthDraft: Double?

        var body: some View {
            let p = store.project
            let job = jobs.latest(AudioCalls.musicJob)
            VStack(alignment: .leading, spacing: 10) {
                if let music = AudioCalls.musicTrack(p), let p {
                    let asset = p.asset(music.clips[0].assetID)
                    HStack(spacing: Ed.Space.s) {
                        Image(systemName: "music.note").font(Ed.icon(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.musicWave)
                            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(Ed.musicWave.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: asset?.name ?? loc("Musica")).font(Ed.ui(Ed.TypeSize.body, .medium)).foregroundStyle(Ed.text).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: String(format: loc("%@ sulla pista Musica"), clockTime(music.end.seconds - music.clips[0].start.seconds)))
                                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                        }
                        Spacer(minLength: 0)
                    }
                    InspectorSlider(label: loc("Volume"), value: volumeDraft ?? (music.clips[0].gain ?? 0), range: -30...12, step: 0.5,
                                    format: Fmt.decibels, parse: parse, onDrag: { volumeDraft = $0 },
                                    onCommit: { v in
                                        volumeDraft = nil
                                        guard abs(v - (music.clips[0].gain ?? 0)) > 0.05 else { return }
                                        store.changeMusic(AudioCalls.musicVolume(trackID: music.id, gain: v))
                                    })
                    RToggle(title: loc("Abbassa sotto la voce"), isOn: Binding(get: { music.ducking != nil }, set: { on in
                        store.changeMusic(AudioCalls.duck(trackID: music.id, depth: on ? AudioCalls.defaultDepth : 0))
                    }), subtitle: loc("La musica scende mentre qualcuno parla e risale nelle pause."))
                    if let d = music.ducking {
                        InspectorSlider(label: loc("Quanto scende"), value: depthDraft ?? d.depth, range: -30...(-3), step: 1,
                                        format: Fmt.wholeDecibels, parse: parse, onDrag: { depthDraft = $0 },
                                        onCommit: { v in
                                            depthDraft = nil
                                            guard abs(v - d.depth) >= 0.5 else { return }
                                            store.changeMusic(AudioCalls.duck(trackID: music.id, depth: v))
                                        })
                    }
                    checkLine(job, p)
                } else {
                    Text(verbatim: loc("Nessuna musica. Va sulla pista Musica, dura quanto il video e si abbassa da sola quando parli."))
                        .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                    if let job, job.isRunning || job.state != .done {
                        JobCard(job: job, onCancel: { jobs.cancel(job.id) }, onDismiss: { jobs.dismiss(job.id) })
                    }
                    EdButton(title: loc("Aggiungi musica…"), symbol: "music.note", prominent: p?.duration ?? .zero > .zero,
                             disabled: p == nil || p?.duration ?? .zero <= .zero || job?.isRunning == true) { Panels.addMusic(store) }
                    if let p, p.duration <= .zero { Text(verbatim: loc("Metti prima il video sulla timeline.")).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3) }
                    let unused = AudioCalls.projectMusic(p)
                    if !unused.isEmpty {
                        RSection("Dal progetto", rows: true) {
                            ForEach(unused, id: \.id) { a in
                                SideRow(symbol: "waveform", title: a.name, detail: clockTime(a.duration.seconds)) { store.addMusic(URL(fileURLWithPath: a.path)) }
                                    .tip("Usa questo audio come musica")
                            }
                        }
                        .padding(.top, Ed.Space.xxs)
                    }
                }
            }
        }

        /// The check under the voice: running, failed, its result while the audio is unchanged, or the button.
        @ViewBuilder private func checkLine(_ job: JobCenter.Job?, _ p: Project) -> some View {
            if let job, job.isRunning || (job.state != .done && job.state != .cancelled) {
                JobCard(job: job, onCancel: { jobs.cancel(job.id) }, onDismiss: { jobs.dismiss(job.id) })
            } else if let check = demo?.check ?? store.musicCheck.flatMap({ $0.signature == AudioCalls.signature(p) ? $0 : nil }) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: check.pass ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(Ed.icon(Ed.TypeSize.small)).foregroundStyle(check.pass ? Ed.ok : Ed.warn)
                    Text(verbatim: check.line).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
                }
            } else if AudioCalls.voiceTrack(p) != nil {
                EdButton(title: loc("Controlla sotto la voce"), symbol: "waveform.badge.magnifyingglass") { store.checkMusic() }
                    .tip("Misura quanto la musica sta sotto la voce mentre parli")
            }
        }

        private func parse(_ s: String) -> Double? {
            Double(s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-").filter { "0123456789.-".contains($0) })
        }
    }
}

// MARK: - Sound effects

/// The shipped bank (and the user's folder) by group, with a search: click a row to hear it, + (or a double click, or a
/// drag onto the timeline) to place it on the Effetti track at the playhead.
struct SoundBrowser: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.audioDemo) private var demo
    @ObservedObject private var player = SoundPreview.shared
    @AppStorage("audio.sfxGroup") private var savedGroup = "whoosh"
    @State private var query = ""

    var body: some View {
        let all = SoundLibrary.all(store.engine.context.services.config)
        let group = demo?.group ?? savedGroup
        let q = (demo?.query ?? query).trimmingCharacters(in: .whitespaces).lowercased()
        let shown = all.filter { s in
            q.isEmpty ? (group == "all" || (group == "user" ? s.source == "user" : s.group == group)) : SoundNames.matches(s, q)
        }
        let groups = SoundLibrary.groups + (all.contains { $0.source == "user" } ? ["user"] : [])
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                RTextField(placeholder: "Cerca un suono (whoosh, clic, ding…)", text: $query, symbol: "magnifyingglass", clearable: true)
                RChips(items: groups.map { .init(id: $0, title: SoundNames.group($0)) }, selection: q.isEmpty ? group : nil, flow: true) { g in
                    savedGroup = g
                    query = ""
                }
                Text(verbatim: String(format: loc("%d suoni · clic per ascoltare, + per metterlo al cursore"), shown.count))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            }
            .padding(.horizontal, Ed.Space.m).padding(.bottom, Ed.Space.s)
            Ed.rule2.frame(height: 1)
            if all.isEmpty {
                EmptyHint(symbol: "speaker.slash", text: loc("Nessun effetto sonoro: la libreria di Regista manca da questa installazione. Reinstalla l'app."))
            } else if shown.isEmpty {
                EmptyHint(symbol: "magnifyingglass", text: loc("Nessun suono con questo nome."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown, id: \.name) { s in
                            SoundRow(sound: s, playing: (demo?.playing ?? player.playing) == s.name, canAdd: store.project != nil,
                                     onPreview: { player.toggle(s) }, onAdd: { store.addSoundEffect(s.name) })
                        }
                    }
                    .padding(.vertical, Ed.Space.xs)
                }
            }
            Text(verbatim: loc("Suoni creati in codice da earshot (licenza MIT)."))
                .font(Ed.ui(Ed.TypeSize.micro)).foregroundStyle(Ed.text3).padding(.horizontal, Ed.Space.m).padding(.vertical, 6)
        }
        .onDisappear { player.stop() }
    }
}

struct SoundRow: View {
    let sound: SoundEffect
    let playing: Bool
    let canAdd: Bool
    let onPreview: () -> Void
    let onAdd: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: Ed.Space.s) {
            Image(systemName: playing ? "stop.fill" : "play.fill")
                .font(Ed.icon(Ed.TypeSize.tiny, .bold))
                .foregroundStyle(playing ? Accent.on : (hover ? Ed.text : Ed.text2))
                .frame(width: 22, height: 22)
                .background(Circle().fill(playing ? Ed.gold : (hover ? Ed.hover : Ed.raised)))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: SoundNames.title(sound)).font(Ed.ui(Ed.TypeSize.body, .medium)).foregroundStyle(Ed.text).lineLimit(1)
                HStack(spacing: 5) {
                    Text(verbatim: SoundNames.member(sound)).font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3).lineLimit(1)
                    if let d = sound.duration {
                        Text(verbatim: "· " + String(format: loc("%@ s"), Fmt.number(d, decimals: d < 1 ? 2 : 1)))
                            .font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3)
                    }
                }
            }
            Spacer(minLength: Ed.Space.xs)
            IconButton(symbol: "plus", help: "Aggiungi al cursore (pista Effetti)", size: 22) { onAdd() }
                .disabled(!canAdd)
                .opacity(canAdd ? (hover || playing ? 1 : 0.55) : 0.25)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(playing ? Ed.goldSoft : (hover ? Ed.hover.opacity(0.5) : .clear)).padding(.horizontal, Ed.Space.xs))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if canAdd { onAdd() } }
        .onTapGesture { onPreview() }
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(object: (SFXDrop.prefix + sound.name) as NSString) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // The row is one element (a press plays it): its + is offered as a named action, or no assistive client could
        // add the sound (#73).
        .accessibilityAction(named: Text(verbatim: loc("Aggiungi al cursore (pista Effetti)"))) { if canAdd { onAdd() } }
    }
}

/// The bank's groups and categories in the interface's language (the files keep earshot's ids).
enum SoundNames {
    static func group(_ id: String) -> String {
        switch id {
        case "whoosh": loc("Whoosh e passaggi")
        case "ui": loc("Clic e tocchi")
        case "pop": loc("Pop")
        case "impact": loc("Colpi e impatti")
        case "rise": loc("Salite e discese")
        case "chime": loc("Campanelli e scintille")
        case "logo": loc("Logo")
        case "glitch": loc("Glitch")
        case "typing": loc("Tastiera")
        case "user": loc("I tuoi suoni")
        default: loc("Tutti")
        }
    }

    /// The category's name ("Whoosh veloce"); the user's sounds keep their file name.
    static func title(_ s: SoundEffect) -> String {
        guard s.source == "bank", let c = s.category else { return s.name }
        if c == "fit" { return fit(s.name.split(separator: "/").dropFirst().first.map(String.init) ?? "") }
        return category(c)
    }

    /// The member's name ("crisp", "small bell"): what tells two sounds of a category apart.
    static func member(_ s: SoundEffect) -> String {
        guard s.source == "bank" else { return s.description ?? "" }
        return (s.name.split(separator: "/").last.map(String.init) ?? s.name).replacingOccurrences(of: "_", with: " ")
    }

    static func matches(_ s: SoundEffect, _ q: String) -> Bool {
        [s.name, title(s), member(s), s.description ?? "", s.group.map(group) ?? ""].contains { $0.lowercased().contains(q) }
    }

    static func category(_ c: String) -> String {
        switch c {
        case "click": loc("Clic")
        case "pro_click": loc("Clic brillante")
        case "hover_tick": loc("Tic leggero")
        case "pro_hover_tick": loc("Tic digitale")
        case "tap": loc("Tocco")
        case "pro_tap": loc("Tocco morbido")
        case "toggle": loc("Interruttore")
        case "pop": loc("Pop")
        case "pro_pop": loc("Pop tonale")
        case "pro_pop_in": loc("Comparsa")
        case "notify": loc("Campanello")
        case "pro_notify": loc("Ding")
        case "shimmer": loc("Scintillio")
        case "pro_shimmer": loc("Scintillio granulare")
        case "pluck": loc("Kalimba")
        case "whoosh_fast": loc("Whoosh veloce")
        case "whoosh_big": loc("Whoosh ampio")
        case "pro_whoosh_big": loc("Onda bassa")
        case "swish": loc("Swish")
        case "swipe": loc("Swipe")
        case "riser": loc("Salita")
        case "pro_riser": loc("Salita breve")
        case "downlifter": loc("Discesa")
        case "pro_zip": loc("Zip")
        case "impact": loc("Impatto cinematografico")
        case "pro_impact": loc("Impatto sub")
        case "sub_drop": loc("Sub drop")
        case "pro_sub_drop": loc("Drop dopo il taglio")
        case "logo_sting": loc("Sigla del logo")
        case "pro_logo_sting": loc("Sigla di lancio")
        case "glitch": loc("Glitch")
        case "pro_glitch": loc("Stutter")
        case "typing_key": loc("Tasto meccanico")
        case "pro_typing_key": loc("Tasto per testo animato")
        case "pro_typing_run": loc("Digitazione")
        default: c.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Fitted from a CC0 recording, by role.
    static func fit(_ role: String) -> String {
        switch role {
        case "bell": loc("Campanellino")
        case "click": loc("Clic")
        case "hit": loc("Colpo")
        case "key": loc("Tasto")
        case "key.space": loc("Barra spaziatrice")
        case "land.light": loc("Tocco leggero")
        case "pop": loc("Pop")
        case "snap": loc("Scatto")
        case "tick": loc("Tic")
        case "whoosh.short": loc("Whoosh corto")
        default: role
        }
    }
}
