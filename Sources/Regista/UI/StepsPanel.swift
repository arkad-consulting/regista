import AppKit
import RegistaCore
import SwiftUI
import UniformTypeIdentifiers

// Testi e sottotitoli › Passi (E2 #54): the path from an imported clip to captions as a rail of steps, each with its
// state, its settings and one button that runs it as a job. "Fai tutto" on top runs them in order.

/// What the steps panel draws: the live tab, or sample data for a render (ui.screenshot `texts`).
struct StepsSnapshot {
    var steps: TextSteps
    /// The newest job of each step (running, failed or done) and of "Fai tutto".
    var jobs: [TextStep: JobCenter.Job] = [:]
    var allJob: JobCenter.Job?
    /// The RAM tier ("base", "medium", "pro"): which transcription engine runs, said in words.
    var tier: String?
    var hasTranscript = false
    var scriptLines: [String] = []
    /// The suggested caption keywords (captions.generate dryRun) and those accepted.
    var suggestions: [String] = []
    var accepted: [String]? = nil
    /// The keywords of the captions already made (the starting selection when captions are made again).
    var current: [String] = []
    /// The step job running in the tab (one at a time), if any.
    var busy: JobCenter.Job? { ([allJob] + jobs.values.map { Optional($0) }).compactMap { $0 }.first { $0.isRunning } }
}

private struct StepsDemoKey: EnvironmentKey { static let defaultValue: StepsSnapshot? = nil }

extension EnvironmentValues {
    /// Sample steps an offscreen render draws instead of the tab's (ui.screenshot `texts`).
    var stepsDemo: StepsSnapshot? {
        get { self[StepsDemoKey.self] }
        set { self[StepsDemoKey.self] = newValue }
    }
}

/// The steps of the active tab, following its project and its jobs.
struct StepsPanel: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.stepsDemo) private var demo

    var body: some View { Live(jobs: store.jobs, demo: demo) }

    private struct Live: View {
        @EnvironmentObject private var store: EditorStore
        @ObservedObject var jobs: JobCenter
        let demo: StepsSnapshot?
        @State private var suggestions: [String] = []
        @State private var suggestedFor: String?

        var body: some View {
            let snap = demo ?? live
            StepsList(snap: snap)
                .task(id: suggestionKey(snap)) { await loadSuggestions(snap) }
        }

        private var live: StepsSnapshot {
            let p = store.project
            var jobsByStep: [TextStep: JobCenter.Job] = [:]
            for s in TextStep.allCases { if let j = jobs.latest(s.jobKind) { jobsByStep[s] = j } }
            return StepsSnapshot(steps: store.textSteps, jobs: jobsByStep, allJob: jobs.latest(TextStep.allJobKind),
                                 tier: store.engineSummary?.tier, hasTranscript: TextSteps.mainAsset(p)?.analysis?.transcript != nil,
                                 scriptLines: p?.script?.lines ?? [], suggestions: suggestions,
                                 current: p?.tracks.first { $0.kind == .caption && $0.captions != nil }?.captions?.keywords ?? [])
        }

        /// Suggestions are asked again when the edit or the style changes, and only while captions can be made.
        private func suggestionKey(_ s: StepsSnapshot) -> String {
            guard demo == nil, s.steps[.captions].canRun else { return "" }
            return "\(store.projectVersion)-\(UserDefaults.standard.string(forKey: StepSettings.styleKey) ?? "")"  // l10n-ignore
        }

        private func loadSuggestions(_ s: StepsSnapshot) async {
            let key = suggestionKey(s)
            guard !key.isEmpty, key != suggestedFor else { return }
            suggestedFor = key
            suggestions = await store.suggestKeywords(style: StepSettings.saved(project: store.project).style)
        }
    }
}

/// "Fai tutto", then the rail of steps; one step open at a time (the running one, else the next to do).
struct StepsList: View {
    @EnvironmentObject private var store: EditorStore
    let snap: StepsSnapshot
    /// The step the user opened (or closed: nil) by hand; until then the running step, else the next one to do.
    @State private var opened: TextStep?
    @State private var chosen = false

    var body: some View {
        let start: TextStep = snap.steps[.transcribe].status == .blocked ? .transcribe : .captions   // nothing to work on yet: Importa
        let open = chosen ? opened : (snap.busy.flatMap(runningStep) ?? snap.steps.next ?? start)
        ScrollView {
            VStack(alignment: .leading, spacing: Ed.Space.l) {
                DoAllCard(snap: snap)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(TextStep.allCases.enumerated()), id: \.element) { i, step in
                        StepRow(step: step, number: i + 1, state: snap.steps[step], open: open == step,
                                last: i == TextStep.allCases.count - 1, onToggle: { chosen = true; opened = open == step ? nil : step }) {
                            StepBody(step: step, snap: snap) { chosen = true; opened = $0 }
                        }
                    }
                }
            }
            .padding(.horizontal, Ed.Space.m).padding(.top, Ed.Space.xxs).padding(.bottom, Ed.Space.l)
        }
    }

    private func runningStep(_ job: JobCenter.Job) -> TextStep? {
        if job.kind == TextStep.allJobKind {
            return job.steps.indices.contains(job.stepIndex) ? TextStep.allCases.first { $0.title() == job.steps[job.stepIndex] } : nil
        }
        return TextStep.allCases.first { $0.jobKind == job.kind }
    }
}

/// The automatic edit as one button: the steps in order, stoppable; its job (with the sub-steps) under it.
private struct DoAllCard: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var prompter = TeleprompterController.shared
    let snap: StepsSnapshot

    var body: some View {
        let ready = snap.steps[.transcribe].status != .blocked
        let pending = TextStep.allCases.filter { !$0.optional && snap.steps[$0].status != .done }
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            if let job = snap.allJob, job.isRunning || !(job.state == .done) {
                JobCard(job: job, onCancel: { store.jobs.cancel(job.id) }, onDismiss: { store.jobs.dismiss(job.id) })
            }
            if snap.allJob?.isRunning != true {
                EdButton(title: pending.isEmpty ? loc("Tutto fatto") : loc("Fai tutto"), symbol: "wand.and.stars", prominent: ready && !pending.isEmpty,
                         large: true, fill: true, disabled: !ready || pending.isEmpty || snap.busy != nil) {
                    store.runAll(settings: StepSettings.saved(project: store.project), script: prompter.text)
                }
                .tip("Trascrive, sceglie le riprese, taglia le pause, pulisce la voce e mette i sottotitoli, in ordine", shortcut: "⇧⌘M")
                Text(verbatim: caption(ready: ready, pending: pending)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func caption(ready: Bool, pending: [TextStep]) -> String {
        if !ready { return snap.steps[.transcribe].line }
        if pending.isEmpty { return loc("Ogni passo è fatto. Dopo una modifica, i passi da rifare tornano qui.") }
        if let busy = snap.busy, busy.kind != TextStep.allJobKind { return String(format: loc("Aspetta: «%@» è in corso."), busy.title) }
        return String(format: loc("Fa in ordine i passi che mancano (%@). Puoi fermarlo quando vuoi."),
                      pending.map { $0.title() }.joined(separator: ", "))
    }
}

/// One step on the rail: the state glyph, the title and its line; open, the settings and the button.
private struct StepRow<Body: View>: View {
    let step: TextStep
    let number: Int
    let state: StepState
    let open: Bool
    let last: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Body
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                StateGlyph(state.status.rawValue, number: number, size: 20).padding(.vertical, 1)
                if !last { Rectangle().fill(state.status == .done ? Ed.ok.opacity(0.35) : Ed.line2).frame(width: 1).frame(maxHeight: .infinity) }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                Button(action: onToggle) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                            HStack(spacing: 5) {
                                Text(verbatim: step.title()).font(Ed.ui(Ed.TypeSize.control, .semibold))
                                    .foregroundStyle(state.status == .blocked ? Ed.text2 : Ed.text)
                                if step.optional { RTag("facoltativo") }
                            }
                            Text(verbatim: state.line).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(lineColor)
                                .lineLimit(open ? nil : 2).fixedSize(horizontal: false, vertical: open)
                        }
                        Spacer(minLength: Ed.Space.xs)
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(Ed.icon(Ed.TypeSize.tiny, .semibold))
                            .foregroundStyle(hover ? Ed.text2 : Ed.text3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                if open { content().padding(.bottom, Ed.Space.xs) }
            }
            .padding(.bottom, last ? 0 : Ed.Space.m)
        }
    }

    private var lineColor: Color {
        switch state.status {
        case .stale: Ed.warn
        case .done: Ed.ok.opacity(0.9)
        case .running: Ed.gold
        default: Ed.text3
        }
    }
}

/// The open step: its job, its settings, the button (enabled only when it can run) or what is missing.
private struct StepBody: View {
    @EnvironmentObject private var store: EditorStore
    let step: TextStep
    let snap: StepsSnapshot
    let openStep: (TextStep) -> Void

    @AppStorage(StepSettings.languageKey) private var language = StepSettings.appLanguage
    @AppStorage(StepSettings.minPauseKey) private var minPause = 0.7
    @AppStorage(StepSettings.breathKey) private var breath = 0.12
    @AppStorage(StepSettings.styleKey) private var style = CaptionStyle.talkingHeadV1.id
    @State private var draft = ""
    @State private var editingScript = false
    @State private var accepted: [String]?
    @State private var newWord = ""

    private var state: StepState { snap.steps[step] }
    private var settings: StepSettings {
        StepSettings(language: language, minPause: minPause, breath: breath, style: style, keywords: keywords)
    }
    /// The keywords the captions will get: the user's choice, else those of the captions already made, else the
    /// suggestions as they are.
    private var keywords: [String] { accepted ?? snap.accepted ?? (snap.current.isEmpty ? snap.suggestions : snap.current) }

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.m) {
            if let job = snap.jobs[step], job.isRunning || isFailed(job) {
                JobCard(job: job, onCancel: { store.jobs.cancel(job.id) }, onDismiss: { store.jobs.dismiss(job.id) })
            }
            if state.status == .blocked {
                missing
            } else {
                controls
                primary
            }
        }
    }

    private func isFailed(_ j: JobCenter.Job) -> Bool { if case .failed = j.state { return true }; return false }

    /// Why the step cannot run, and the way to what is missing.
    @ViewBuilder private var missing: some View {
        ReasonNote(text: state.line) {
            if state.needsImport {
                EdButton(title: loc("Importa un video…"), symbol: "square.and.arrow.down") { Panels.importMedia(store) }
            } else if let need = state.needs {
                EdButton(title: String(format: loc("Vai a «%@»"), need.title()), symbol: "arrow.turn.left.up") { openStep(need) }
            }
        }
    }

    // MARK: Settings per step

    @ViewBuilder private var controls: some View {
        switch step {
        case .transcribe:
            label(loc("Lingua del parlato"))
            RChips(items: StepSettings.languages.map { .init(id: $0, title: StepSettings.languageName($0)) }, selection: language, columns: 3) {
                language = $0
            }
            Text(verbatim: engineLine).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        case .script: scriptControls
        case .takes:
            if state.status == .done {
                EdButton(title: loc("Rivedi e cambia le riprese"), symbol: "list.number") { store.nav.textsTab = .takes }
            }
        case .cut:
            RSlider(value: $minPause, range: 0.3...2.0, step: 0.1, label: loc("Pausa minima da togliere"), format: { seconds($0, 1) })
            RSlider(value: $breath, range: 0...0.4, step: 0.02, label: loc("Respiro lasciato prima e dopo"), format: { seconds($0, 2) })
            Text(verbatim: loc("Le pause più lunghe della pausa minima spariscono; resta un respiro su ogni lato perché il parlato non suoni tagliato."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        case .clean:
            EmptyView()
        case .captions: captionControls
        }
    }

    private var engineLine: String {
        switch snap.tier {
        case "medium", "pro": loc("Motore: trascrizione precisa, con i tempi delle parole più esatti (scelto per la memoria di questo Mac).")
        case "base": loc("Motore: trascrizione standard, adatta alla memoria di questo Mac.")
        default: loc("Il motore lo sceglie Regista in base alla memoria del Mac.")
        }
    }

    @ViewBuilder private var scriptControls: some View {
        if state.status == .done && !editingScript {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(snap.scriptLines.prefix(3).enumerated()), id: \.offset) { i, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(i + 1)").font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3).frame(width: 12, alignment: .trailing)
                        Text(verbatim: line).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).lineLimit(1)
                    }
                }
                if snap.scriptLines.count > 3 {
                    Text(verbatim: String(format: loc("e altre %d righe"), snap.scriptLines.count - 3)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                }
            }
            EdButton(title: loc("Cambia il copione"), symbol: "pencil") { editingScript = true }
        } else {
            RTextEditor(placeholder: "Incolla qui il copione, una frase per riga", text: $draft, kind: .grows(4...8))
            FlowLayout(spacing: 6, lineSpacing: 6) {
                EdButton(title: loc("Usa questo copione"), symbol: "checkmark", prominent: !trimmed.isEmpty,
                         disabled: trimmed.isEmpty || snap.busy != nil) {
                    store.runStepCall(StepCalls.scriptText(trimmed), step: .script)
                    editingScript = false
                }
                if !TeleprompterController.shared.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    EdButton(title: loc("Dal gobbo"), symbol: "text.viewfinder") { draft = TeleprompterController.shared.text }
                }
                EdButton(title: loc("Importa file…"), symbol: "doc", disabled: snap.busy != nil) { importScript() }
            }
        }
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func importScript() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        p.message = loc("Scegli il copione (testo o Markdown)")
        guard p.runModal() == .OK, let url = p.url else { return }
        store.runStepCall(StepCalls.scriptFile(url.path), step: .script)
        editingScript = false
    }

    @ViewBuilder private var captionControls: some View {
        label(loc("Stile"))
        RChips(items: CaptionStyle.all.map { .init(id: $0.id, title: styleName($0.id)) }, selection: style, columns: 2) { style = $0 }
        label(loc("Parole chiave"))
        if snap.suggestions.isEmpty && keywords.isEmpty {
            Text(verbatim: loc("Cerco le parole da evidenziare…")).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
        }
        FlowLayout(spacing: Ed.Space.xs, lineSpacing: Ed.Space.xs) {
            ForEach(Array(Set(snap.suggestions + keywords)).sorted { order($0) < order($1) }, id: \.self) { word in
                let on = keywords.contains(word)
                Button { toggle(word) } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: word).font(Ed.ui(Ed.TypeSize.caption, .semibold))
                        Image(systemName: on ? "xmark" : "plus").font(Ed.icon(Ed.TypeSize.tiny, .bold))
                    }
                    .foregroundStyle(on ? .white : Ed.text2)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: Ed.Radius.s).fill(on ? Ed.keyword.opacity(0.85) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(on ? .clear : Ed.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                .buttonStyle(.plain)
                .tip(on ? "Togli dalle parole chiave" : "Evidenzia questa parola")
            }
        }
        HStack(spacing: 6) {
            RTextField(placeholder: "Aggiungi una parola", text: $newWord)
                .onSubmit { addWord() }
            EdButton(title: loc("Aggiungi"), disabled: newWord.trimmingCharacters(in: .whitespaces).isEmpty) { addWord() }
        }
    }

    private func order(_ w: String) -> Int { snap.suggestions.firstIndex(of: w) ?? (1000 + (keywords.firstIndex(of: w) ?? 0)) }

    private func toggle(_ w: String) {
        var k = keywords
        if let i = k.firstIndex(of: w) { k.remove(at: i) } else { k.append(w) }
        accepted = k
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces).uppercased()
        guard !w.isEmpty else { return }
        var k = keywords
        if !k.contains(w) { k.append(w) }
        accepted = k
        newWord = ""
    }

    private func styleName(_ id: String) -> String {
        switch id {
        case "elegant-serif": loc("Serif elegante")
        case "bold-keyword": loc("Bold + parola chiave")
        case "ghost-karaoke": loc("Karaoke fantasma")
        default: loc("Talking head")
        }
    }

    // MARK: The button

    @ViewBuilder private var primary: some View {
        let busy = snap.busy
        let disabled = busy != nil || state.status == .running || (step == .script && !snap.hasTranscript)
        if state.status != .running, step != .script || state.status != .done || editingScript {
            VStack(alignment: .leading, spacing: Ed.Space.xs) {
                EdButton(title: actionTitle, symbol: step.symbol, prominent: state.status != .done, fill: true, disabled: disabled) {
                    store.runStep(step, settings: settings, keywords: keywords)
                }
                if let busy, state.status != .running {
                    Text(verbatim: String(format: loc("Aspetta: «%@» è in corso."), busy.title)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                } else if step == .script && !snap.hasTranscript {
                    Text(verbatim: loc("Per crearlo dal parlato serve prima la trascrizione.")).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                }
            }
        }
    }

    private var actionTitle: String {
        let again = state.status == .done || state.status == .stale
        switch step {
        case .transcribe: return again ? loc("Trascrivi di nuovo") : loc("Trascrivi")
        case .script: return loc("Crea dal parlato")
        case .takes: return again ? loc("Ricalcola le riprese") : loc("Scegli le riprese")
        case .cut: return again ? loc("Rifai il taglio") : loc("Taglia le pause")
        case .clean: return again ? loc("Pulisci di nuovo") : loc("Pulisci la voce")
        case .captions: return again ? loc("Rigenera i sottotitoli") : loc("Genera i sottotitoli")
        }
    }

    private func label(_ s: String) -> some View { SectionLabel(s) }

    private func seconds(_ v: Double, _ places: Int) -> String {
        v.formatted(.number.precision(.fractionLength(places))) + " s"
    }
}

/// An empty panel that offers its step instead of naming a command (Trascrizione, Riprese, Sottotitoli, Audio): the
/// step's line and its button with the saved settings, or what is missing first; "Tutti i passi" opens the rail.
struct StepOffer: View {
    @EnvironmentObject private var store: EditorStore
    let step: TextStep
    var symbol: String? = nil
    var compact = false

    var body: some View { Content(jobs: store.jobs, step: step, symbol: symbol, compact: compact) }

    private struct Content: View {
        @EnvironmentObject private var store: EditorStore
        @ObservedObject var jobs: JobCenter
        let step: TextStep
        let symbol: String?
        let compact: Bool

        var body: some View {
            let steps = store.textSteps
            let state = steps[step]
            let busy = store.runningStepJob
            VStack(alignment: compact ? .leading : .center, spacing: 10) {
                if !compact {
                    Image(systemName: symbol ?? step.symbol).font(Ed.icon(Ed.TypeSize.large, .light)).foregroundStyle(Ed.text3)
                }
                Text(verbatim: state.line).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                    .multilineTextAlignment(compact ? .leading : .center).frame(maxWidth: compact ? .infinity : 240, alignment: compact ? .leading : .center)
                    .fixedSize(horizontal: false, vertical: true)
                if let job = jobs.latest(step.jobKind), job.isRunning || job.state != .done {
                    JobCard(job: job, onCancel: { jobs.cancel(job.id) }, onDismiss: { jobs.dismiss(job.id) }).frame(maxWidth: 280)
                }
                if state.needsImport {
                    EdButton(title: loc("Importa un video…"), symbol: "square.and.arrow.down") { Panels.importMedia(store) }
                } else if let need = state.needs {
                    let first = steps[need]
                    EdButton(title: String(format: loc("Prima: %@"), need.title()), symbol: need.symbol, prominent: first.canRun,
                             disabled: !first.canRun || busy != nil) {
                        store.runStep(need, settings: StepSettings.saved(project: store.project))
                    }
                } else if state.status != .running {
                    EdButton(title: state.status == .done ? String(format: loc("%@ di nuovo"), step.title()) : step.title(), symbol: step.symbol,
                             prominent: state.status != .done, disabled: busy != nil) {
                        if step == .captions {
                            Task {
                                let s = StepSettings.saved(project: store.project)
                                store.runStep(.captions, settings: s, keywords: await store.suggestKeywords(style: s.style))
                            }
                        } else {
                            store.runStep(step, settings: StepSettings.saved(project: store.project))
                        }
                    }
                }
                AccentLinkButton(title: loc("Tutti i passi"), tip: "Testi e sottotitoli › Passi: dal video ai sottotitoli, un passo alla volta") {
                    store.nav.textsTab = .steps
                    store.select(.texts)
                }
            }
            .padding(compact ? 0 : 16)
            .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: compact ? .leading : .center)
        }
    }
}

/// The steps panel in each state from sample data, for ui.screenshot `texts: {state}` (no engine runs, no project is
/// touched): fresh (a clip just imported), transcribing, transcribed, cut, keywords (captions to make, the suggested
/// keywords shown), captions (all done), stale (a take changed after the cut), doall ("Fai tutto" on its third
/// step), failed (the voice cleaning failed, the error in words).
enum StepsDemo {
    static let states = ["fresh", "transcribing", "transcribed", "cut", "keywords", "captions", "stale", "doall", "failed"]

    static func snapshot(_ state: String, tier: String = "medium", lookup: (String) -> String = loc) -> StepsSnapshot {
        func s(_ status: StepState.Status, _ line: String, needs: TextStep? = nil) -> StepState { StepState(status: status, line: line, needs: needs) }
        let noTranscript = s(.blocked, lookup("Prima serve la trascrizione."), needs: .transcribe)
        var st: [TextStep: StepState] = [
            .transcribe: s(.todo, lookup("Il parlato diventa testo, con il tempo di ogni parola.")),
            .script: s(.todo, lookup("Facoltativo: senza copione le righe vengono dal parlato.")),
            .takes: noTranscript, .cut: noTranscript,
            .clean: s(.todo, lookup("Toglie il rumore e porta la voce a −15 LUFS.")),
            .captions: noTranscript,
        ]
        let transcribed = s(.done, String(format: lookup("%d parole · %@"), 312, StepSettings.languageName("it")))
        let script = s(.done, String(format: lookup("%d righe"), 9))
        let takes = s(.done, String(format: lookup("%d righe su %d con una ripresa scelta"), 9, 9))
        let cut = s(.done, String(format: lookup("%d tagli · %@ di montaggio"), 14, "0:48"))
        let clean = s(.done, lookup("Voce pulita, a −15 LUFS."))
        let captionsTodo = s(.todo, lookup("Parola per parola, con le parole chiave evidenziate."))
        var snap = StepsSnapshot(steps: TextSteps(states: st), tier: tier)
        // l10n-ignore-begin: a sample script and its keywords stand for the user's own words (content, not UI)
        let lines = ["Ciao, oggi vi mostro Regista.", "Si monta un reel in tre minuti.", "Prima si importa il video.",
                     "Poi si trascrive il parlato.", "Le pause spariscono da sole.", "La voce esce pulita a meno quindici.",
                     "I sottotitoli arrivano parola per parola.", "Le parole chiave si scelgono con un clic.", "E il reel è pronto."]
        // l10n-ignore-end
        func job(_ step: TextStep, _ detail: String, _ p: Double?, _ state: JobCenter.State = .running, ago: Double) -> JobCenter.Job {
            JobCenter.Job(id: UUID(), kind: step.jobKind, title: step.title(lookup), detail: detail, progress: p, state: state, cancellable: true,
                          started: Date() - ago)
        }
        switch state {
        case "transcribing":
            st[.transcribe] = s(.running, lookup("Il parlato diventa testo, con il tempo di ogni parola."))
            snap.jobs[.transcribe] = job(.transcribe, String(format: lookup("Trascrivo il parlato (%@)…"), StepSettings.languageName("it")), 0.37, ago: 41)
        case "transcribed":
            st[.transcribe] = transcribed
            st[.takes] = s(.todo, lookup("Senza copione, le righe vengono dal parlato."))
            st[.cut] = s(.blocked, lookup("Prima scegli le riprese."), needs: .takes)
            st[.captions] = captionsTodo
            snap.hasTranscript = true
        case "cut", "keywords", "captions", "failed":
            st[.transcribe] = transcribed; st[.script] = script; st[.takes] = takes; st[.cut] = cut
            st[.captions] = captionsTodo
            snap.hasTranscript = true
            snap.scriptLines = lines
            if state == "keywords" || state == "captions" { st[.clean] = clean }
            if state == "keywords" {  // l10n-ignore-begin
                snap.suggestions = ["REGISTA", "REEL", "TRE", "MINUTI", "TRASCRIVE", "PAUSE", "QUINDICI", "SOTTOTITOLI", "CLIC"]
                snap.accepted = ["REGISTA", "TRE", "MINUTI", "PAUSE", "QUINDICI", "SOTTOTITOLI"]
            }
            if state == "captions" {
                st[.captions] = s(.done, String(format: lookup("%d blocchi · %d parole chiave"), 38, 6))
                snap.suggestions = ["REGISTA", "TRE", "MINUTI", "PAUSE", "QUINDICI", "SOTTOTITOLI", "REEL", "CLIC"]
                snap.accepted = ["REGISTA", "TRE", "MINUTI", "PAUSE", "QUINDICI", "SOTTOTITOLI"]
            }  // l10n-ignore-end
            if state == "failed" {
                snap.jobs[.clean] = job(.clean, "", nil, .failed(lookup("Il motore che serve non è installato su questo Mac: Impostazioni › Motori dice come installarlo.")), ago: 12)
            }
        case "stale":
            st[.transcribe] = transcribed; st[.script] = script; st[.takes] = takes
            st[.cut] = s(.stale, lookup("La timeline non segue più le riprese scelte: rifai il taglio."))
            st[.clean] = s(.stale, lookup("Il taglio è cambiato: la voce va ripulita."))
            st[.captions] = s(.stale, lookup("Il montaggio è cambiato: rigenera i sottotitoli."))
            snap.hasTranscript = true
            snap.scriptLines = lines
        case "doall":
            st[.transcribe] = transcribed; st[.script] = script
            st[.takes] = s(.running, lookup("Senza copione, le righe vengono dal parlato."))
            st[.cut] = s(.blocked, lookup("Prima scegli le riprese."), needs: .takes)
            st[.captions] = captionsTodo
            snap.hasTranscript = true
            var all = JobCenter.Job(id: UUID(), kind: TextStep.allJobKind, title: lookup("Fai tutto"), detail: lookup("Cerco le letture di ogni riga…"),
                                    progress: 0.3, cancellable: true, started: Date() - 64)
            all.steps = EditorStore.allSteps(hasScriptText: true).map { $0.title(lookup) }
            all.stepIndex = 2
            snap.allJob = all
        default: break   // fresh
        }
        snap.steps = TextSteps(states: st)
        return snap
    }
}
