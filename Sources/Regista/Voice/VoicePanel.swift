import RegistaCore
import SwiftUI

/// ui.screenshot's `voice` parameter: the voice screens drawn from a value (VoiceDemo), never from the owner's profile.
private struct VoiceDemoKey: EnvironmentKey { static let defaultValue: VoiceModel? = nil }

extension EnvironmentValues {
    var voiceDemo: VoiceModel? {
        get { self[VoiceDemoKey.self] }
        set { self[VoiceDemoKey.self] = newValue }
    }
}

/// The library's Voce tab (V2 #62): text → voice-over in the active profile's own cloned voice. It shows the right
/// thing for each state — engine missing (visible, disabled, with the reason), no profile (create it here), no voice
/// yet (into the recording flow), ready (the composer and the pronunciation lexicon).
struct VoiceTab: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.voiceDemo) private var demo

    var body: some View {
        VoicePanel(model: demo ?? store.voice, jobs: demo?.demoJobs ?? store.jobs)
    }
}

struct VoicePanel: View {
    @ObservedObject var model: VoiceModel
    @ObservedObject var jobs: JobCenter
    @EnvironmentObject private var store: EditorStore
    @Environment(\.openSettings) private var openSettings
    @State private var name = ""
    @State private var selection: TextSelection?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Ed.Space.xl) {
                    switch model.state {
                    case .engineMissing(let why):
                        StateCard(symbol: "waveform.slash", title: loc("Voce clonata non disponibile"), text: why) {
                            EdButton(title: "Installa…", symbol: "arrow.down.circle") { SettingsRoute.open(.engines, engine: "voxcpm", with: openSettings) }
                        }
                        VStack(alignment: .leading, spacing: Ed.Space.l) { composer; actions }
                            .disabled(true).opacity(0.38).allowsHitTesting(false)
                    case .noProfile: noProfile
                    case .locked(let who):
                        StateCard(symbol: "lock", title: loc("Profilo di un altro Mac"),
                                  text: String(format: loc("Il profilo di %@ è stato creato su un altro Mac: la sua voce si usa solo dopo averlo adottato in Impostazioni › Profilo e voce."), who)) {
                            EdButton(title: "Apri Impostazioni") { SettingsRoute.open(.voice, with: openSettings) }
                        }
                    case .noVoice(let who): noVoice(who)
                    case .ready:
                        RSegmented(items: [(VoiceModel.Pane.text, loc("Testo")), (.lexicon, loc("Pronuncia"))], selection: $model.pane)
                        if model.pane == .text { composer } else { VoiceLexiconPane(model: model) }
                    }
                    honesty
                }
                .padding(Ed.Space.l)
            }
            if model.state == .ready, model.pane == .text { footer }
        }
        .task { await model.refresh() }
    }

    /// The actions and the job stay in view at the bottom of the panel, whatever the scroll.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Ed.Space.m) {
            actions
            if let job = jobs.latest("voice") {
                JobCard(job: job, onCancel: { jobs.cancel(job.id) }, onDismiss: { jobs.dismiss(job.id) })
            }
            if let p = model.placed, jobs.latest("voice")?.isRunning != true { placedCard(p) }
        }
        .padding(Ed.Space.l)
        .background(Ed.header)
        .overlay(alignment: .top) { Ed.line.frame(height: 1) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Ed.Space.s) {
            Image(systemName: "person.wave.2").font(Ed.icon(Ed.TypeSize.small, .medium)).foregroundStyle(model.snapshot.profile == nil ? Ed.text3 : Ed.gold)
            Text(verbatim: model.snapshot.profile.map { String(format: loc("Voce di %@"), $0) } ?? loc("Nessun profilo"))
                .font(Ed.ui(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.text2).lineLimit(1)
            Spacer()
            if model.snapshot.profile != nil, !model.snapshot.profileLocked, model.snapshot.engineAvailable {
                EdButton(title: loc("Registra…"), symbol: "mic") { model.openSetup() }
                    .tip("Registra la tua voce, un altro tono o allenala")
            }
        }
        .padding(.horizontal, Ed.Space.m)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
    }

    // MARK: States

    private var noProfile: some View {
        StateCard(symbol: "person.crop.circle.badge.plus", title: loc("Prima, il tuo profilo"),
                  text: loc("La voce appartiene a una persona: il tuo profilo tiene le tue registrazioni e il modello della tua voce, solo su questo Mac. Scrivi il tuo nome: lo dirai nella frase di consenso.")) {
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                RTextField(placeholder: "Il tuo nome", text: $name)
                EdButton(title: loc("Crea il profilo"), symbol: "person.badge.plus", prominent: true, fill: true,
                         disabled: name.trimmingCharacters(in: .whitespaces).isEmpty) { model.createProfile(name) }
            }
        }
    }

    private func noVoice(_ who: String) -> some View {
        StateCard(symbol: "mic.badge.plus", title: String(format: loc("%@, registra la tua voce"), who),
                  text: loc("Leggi ad alta voce il blocco neutro del copione (circa 10 minuti, con la frase di consenso all'inizio): dopo, Regista parla con la tua voce. Gli altri toni e l'allenamento si aggiungono quando vuoi.")) {
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                EdButton(title: loc("Registra la tua voce…"), symbol: "mic.fill", prominent: true, fill: true) { model.openSetup() }
                Text(verbatim: loc("Puoi anche registrare col telefono e un microfono esterno, poi importare il file."))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: Ed.Space.l) {
            RSection(loc("Testo")) {
                RTextEditor(placeholder: "Scrivi qui il testo della voce. Una riga vuota separa i paragrafi: ognuno diventa una clip.",
                            text: $model.text, kind: .scrolls(min: 120, max: 240), selection: $selection)
                Text(verbatim: estimateLine).font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            }
            if let lang = model.activeLanguage {
                RSection(loc("Lingua")) {
                    RChips(items: model.snapshot.readyLanguages.map { .init(id: $0.code, title: VoiceLanguages.name($0.code)) },
                           selection: lang.code, columns: 2) { code in
                        model.language = code
                        Task { await model.loadLexicon(code) }
                    }
                }
                RSection(loc("Tono")) {
                    RChips(items: lang.tones.map { .init(id: $0, title: loc(VoiceTones.title($0))) }, selection: model.activeTone,
                           columns: min(3, max(lang.tones.count, 1))) { model.tone = $0 }
                    HStack(alignment: .firstTextBaseline, spacing: Ed.Space.xs) {
                        Text(verbatim: lang.trained ? loc("Altri toni: registra il loro blocco (circa 2 minuti) e allena di nuovo la voce.")
                                                    : loc("Altri toni: registra il loro blocco (circa 2 minuti ciascuno); allenando la voce diventano più fedeli."))
                            .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var busy: Bool { jobs.latest("voice")?.isRunning == true }
    private var hasText: Bool { !model.paragraphs.isEmpty }

    /// The placement choice sits with the buttons it applies to, in the pinned bar: never hidden by the scroll (issue #74).
    private var actions: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            RSection(loc("In timeline")) {
                RSegmented(items: [(VoiceCalls.Placement.afterVoice, loc("Dopo l'ultima voce")), (.playhead, loc("Al cursore"))],
                           selection: $model.placement)
            }
            HStack(spacing: Ed.Space.s) {
                if model.playing {
                    EdButton(title: loc("Ferma"), symbol: "stop.fill", large: true) { model.stopPlayback() }
                } else {
                    EdButton(title: loc("Ascolta"), symbol: "play.fill", large: true, disabled: !hasText || busy) {
                        model.listen(selection: selectionRange)
                    }
                    .tip("Ascolta la selezione, o il paragrafo dove sta il cursore, senza toccare il montaggio")
                }
                EdButton(title: loc("Metti in timeline"), symbol: "text.line.last.and.arrowtriangle.forward", prominent: true, large: true, fill: true,
                         disabled: !hasText || busy || (store.project == nil && !model.demo)) { model.place() }
                    .tip("Ogni paragrafo diventa una clip sulla pista Voce, con i tempi delle parole")
            }
            if store.project == nil && !model.demo {
                Text(verbatim: loc("Apri o crea un progetto per mettere la voce in timeline; Ascolta funziona anche senza."))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectionRange: Range<String.Index>? {
        guard case .selection(let r) = selection?.indices, r.upperBound <= model.text.endIndex else { return nil }
        return r
    }

    private var estimateLine: String {
        let n = model.paragraphs.count
        guard n > 0 else { return loc("Nessun testo") }
        let speech = model.estimatedSeconds
        let render = VoiceScript.estimatedRenderSeconds(speech: speech, paragraphs: n)
        let paragraphs = n == 1 ? loc("1 paragrafo") : String(format: loc("%d paragrafi"), n)
        return String(format: loc("%@ · circa %@ di voce · resa circa %@"), paragraphs, VoiceFormat.duration(speech), VoiceFormat.duration(render))
    }

    private func placedCard(_ p: VoiceModel.Placed) -> some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            HStack(spacing: Ed.Space.s) {
                Image(systemName: "checkmark.circle.fill").font(Ed.icon(Ed.TypeSize.body)).foregroundStyle(Ed.ok)
                Text(verbatim: String(format: loc("%d clip sulla pista Voce · %@"), p.clipIds.count, VoiceFormat.duration(p.seconds)))
                    .font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text)
            }
            Text(verbatim: loc("Le clip sono selezionate. Le parole hanno già i loro tempi: i sottotitoli non richiedono una trascrizione."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            EdButton(title: p.captioned ? loc("Sottotitoli creati") : loc("Sottotitoli da questo testo"), symbol: "captions.bubble",
                     disabled: p.captioned) { model.captionsFromText() }
        }
        .rCard()
    }

    private var honesty: some View {
        HStack(alignment: .top, spacing: Ed.Space.s) {
            Image(systemName: "info.circle").font(Ed.icon(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            Text(verbatim: loc("Voce sintetica, generata con l'IA a partire dalla tua. L'export aggiunge la nota «voce generata con IA» da riportare nella descrizione del post."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The pronunciation lexicon of the composer's language: how the model must read a word. The pending entries the
/// engine proposed wait for the person's ear: confirm or discard.
struct VoiceLexiconPane: View {
    @ObservedObject var model: VoiceModel
    @State private var word = ""
    @State private var say = ""
    @State private var editing: String?

    var body: some View {
        let lang = model.lexiconLanguage ?? model.activeLanguage?.code ?? ""
        let pending = model.lexicon.filter(\.pending), confirmed = model.lexicon.filter { !$0.pending }
        VStack(alignment: .leading, spacing: Ed.Space.l) {
            Text(verbatim: String(format: loc("Come il modello deve leggere una parola, in %@. Testo, copione e sottotitoli restano scritti come sono."),
                                  VoiceLanguages.name(lang)))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            if !pending.isEmpty {
                RSection(loc("Da confermare")) {
                    VStack(spacing: 0) {
                        ForEach(pending) { e in
                            row(e) {
                                EdButton(title: loc("Conferma")) { model.lexiconAdd(word: e.word, say: e.say, confirmed: true) }
                                EdButton(title: loc("Scarta"), quiet: true) { model.lexiconRemove(e.word) }
                            }
                        }
                    }
                    .rCard(padding: 0)
                    Text(verbatim: loc("Proposte dal controllo automatico della pronuncia: confermale solo dopo averle ascoltate."))
                        .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            RSection(loc("Parole")) {
                if confirmed.isEmpty {
                    Text(verbatim: loc("Nessuna parola ancora. Aggiungi i nomi che la voce sbaglia, ad esempio un marchio.")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                } else {
                    VStack(spacing: 0) {
                        ForEach(confirmed) { e in
                            row(e) {
                                IconButton(symbol: "pencil", help: "Modifica") { editing = e.word; word = e.word; say = e.say }
                                IconButton(symbol: "xmark", help: "Togli dal lessico") { model.lexiconRemove(e.word) }
                            }
                        }
                    }
                    .rCard(padding: 0)
                }
            }
            RSection(editing == nil ? loc("Aggiungi") : loc("Modifica")) {
                // One field per line: the placeholders stay whole in every language.
                RTextField(placeholder: "Parola (com'è scritta)", text: $word)
                RTextField(placeholder: "Si legge", text: $say, symbol: "arrow.turn.down.right")
                HStack(spacing: Ed.Space.s) {
                    EdButton(title: editing == nil ? loc("Aggiungi") : loc("Salva"), symbol: "plus", prominent: true,
                             disabled: word.trimmingCharacters(in: .whitespaces).isEmpty || say.trimmingCharacters(in: .whitespaces).isEmpty) {
                        if let old = editing, old != word { model.lexiconRemove(old) }
                        model.lexiconAdd(word: word, say: say)
                        word = ""; say = ""; editing = nil
                    }
                    if editing != nil { EdButton(title: loc("Annulla"), quiet: true) { word = ""; say = ""; editing = nil } }
                }
            }
        }
    }

    private func row<T: View>(_ e: VoiceModel.LexiconEntry, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: Ed.Space.s) {
            Text(verbatim: e.word).font(Ed.ui(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.text).lineLimit(1)
            Image(systemName: "arrow.right").font(Ed.icon(Ed.TypeSize.tiny, .semibold)).foregroundStyle(Ed.text3)
            Text(verbatim: e.say).font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(e.pending ? Ed.warn : Ed.text2).lineLimit(1)
            Spacer(minLength: Ed.Space.xs)
            trailing()
        }
        .padding(.horizontal, Ed.Space.s)
        .frame(minHeight: 32)
        .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
    }
}

enum VoiceFormat {
    /// "24 s", "1 min 10 s", "2 h 05 min".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return String(format: "%d h %02d min", s / 3600, (s % 3600) / 60)
    }

    static func minutes(_ m: Double) -> String {
        let n = m < 10 ? m.formatted(.number.precision(.fractionLength(1))) : String(Int(m.rounded()))
        return n + " min"
    }
}
