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

/// The library's Voce tab (V2 #62, V3): text → voice-over in the active profile's own cloned voice. Cloning is done once,
/// typing a text and generating the audio every time: with a usable voice the panel is the text tool and cloning is one
/// header button, a "+ Lingua" and a "+ Tono" chip and one dismissible hint, all opening the "Gestisci voci" window;
/// with no profile or no usable voice the panel is the way into cloning (the four steps with their times). Engine
/// missing and a profile from another Mac show the reason.
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
                    case .noProfile, .noVoice: VoiceCloneIntro(model: model)
                    case .locked(let who):
                        StateCard(symbol: "lock", title: loc("Profilo di un altro Mac"),
                                  text: String(format: loc("Il profilo di %@ è stato creato su un altro Mac: la sua voce si usa solo dopo averlo adottato in Impostazioni › Profilo e voce."), who)) {
                            EdButton(title: "Apri Impostazioni") { SettingsRoute.open(.voice, with: openSettings) }
                        }
                    case .ready:
                        RSegmented(items: [(VoiceModel.Pane.text, loc("Testo")), (.lexicon, loc("Pronuncia"))], selection: $model.pane)
                        if model.pane == .text { composer } else { VoiceLexiconPane(model: model) }
                    }
                    if model.state.leadsToCloning { privacy } else { honesty }
                }
                .padding(Ed.Space.l)
            }
            .continuesCue()
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
            if model.state == .ready {
                EdButton(title: loc("Gestisci voci…")) { model.manageVoices() }
                    .tip("Le tue voci: lingue, toni e allenamento")
            }
        }
        .padding(.horizontal, Ed.Space.m)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
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
                           selection: lang.code, flow: true,
                           add: VoiceWindowPage.firstWithoutVoice(model.snapshot) == nil ? nil
                               : .init(title: "Lingua", tip: "Clona la tua voce in un'altra lingua", action: model.addLanguage)) { code in
                        model.language = code
                        Task { await model.loadLexicon(code) }
                    }
                }
                RSection(loc("Tono")) {
                    RChips(items: lang.tones.map { .init(id: $0, title: loc(VoiceTones.title($0))) }, selection: model.activeTone, flow: true,
                           add: lang.voiceTones.count >= VoiceTones.all.count ? nil
                               : .init(title: "Tono", tip: "Registra un altro tono di questa voce", action: model.addTone)) { model.tone = $0 }
                }
                if model.showsTrainHint { trainHint }
            }
        }
    }

    /// The one hint about training (dismissible, for this language): an untrained voice on a Mac that can train.
    private var trainHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
            VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                Text(verbatim: loc("La voce non è ancora allenata: dopo è più fedele."))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
                AccentLinkButton(title: "Allena…", tip: "Apri l'allenamento di questa voce", action: model.openTraining)
            }
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Nascondi questo consiglio", size: Ed.Height.icon, action: model.dismissTrainHint)
        }
        .rCard(.well, padding: Ed.Space.s)
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
        let paragraphs = Plural.text(n, "1 paragrafo", "%d paragrafi")
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

    /// Under the way into cloning: where the voice stays.
    private var privacy: some View {
        HStack(alignment: .top, spacing: Ed.Space.s) {
            Image(systemName: "lock").font(Ed.icon(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            Text(verbatim: loc("Registrazioni e modello restano su questo Mac, nel tuo profilo."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var honesty: some View {
        HStack(alignment: .top, spacing: Ed.Space.s) {
            Image(systemName: "info.circle").font(Ed.icon(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            Text(verbatim: loc("Voce sintetica, generata con l'IA a partire dalla tua. In Esporta trovi la nota «voce generata con IA» da riportare nella descrizione del post, con «Copia»."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The panel when there is no profile or no usable voice yet: the way into cloning — what it is, the four steps with
/// their times, one button that opens the "Gestisci voci" window.
struct VoiceCloneIntro: View {
    @ObservedObject var model: VoiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.l) {
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                Text(verbatim: loc("Clona la tua voce")).font(Ed.display(Ed.TypeSize.large, .medium)).foregroundStyle(Ed.text)
                Text(verbatim: loc("Leggi ad alta voce un testo che ti mostra Regista. Regista impara la tua voce su questo Mac e poi dice per te qualsiasi testo."))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            RSection(loc("Come funziona")) {
                VoiceCloneSteps(times: model.cloneTimes, tier: model.snapshot.tier)
            }
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                EdButton(title: loc("Inizia a clonare la tua voce"), symbol: "mic.fill", prominent: true, large: true, fill: true) {
                    model.openWindow(language: nil)
                }
                Text(verbatim: loc("Puoi anche registrare col telefono e importare il file."))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The four steps of cloning with their times, from the model (VoiceCloneTimes): the panel's way in, and the window's
/// intro of a language, where `language` marks the first step done.
struct VoiceCloneSteps: View {
    let times: VoiceCloneTimes
    /// This Mac's tier (voice.list).
    let tier: String
    var language: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            step(1, loc("Scegli la lingua"), nil,
                 language.map { String(format: loc("Hai scelto %@. Un'altra lingua si sceglie a sinistra, ora o dopo."), VoiceLanguages.name($0)) }
                    ?? loc("Ogni lingua ha la sua voce. Comincia da quella dei tuoi video, le altre si aggiungono dopo."),
                 done: language != nil)
            step(2, loc("Leggi il tono neutro"), "~" + VoiceFormat.rough(times.neutralMinutes), loc("Appena finito, la voce si può già usare."))
            step(3, loc("Aggiungi altri toni"), String(format: loc("~%@ l'uno"), VoiceFormat.rough(times.toneMinutes)),
                 String(format: loc("Facoltativo. %@: registri solo quelli che ti servono."), otherTones))
            step(4, loc("voice.step.train"), "~" + VoiceFormat.rough(times.trainMinutes), trainText)
        }
    }

    /// "Entusiasta, serio, calmo…": the tones after the neutral one, in the app's language.
    private var otherTones: String {
        let list = VoiceTones.all.filter { $0 != VoiceTone.neutral }.map { loc(VoiceTones.title($0)).lowercased(with: Locale.current) }
            .joined(separator: ", ")
        return list.prefix(1).uppercased(with: Locale.current) + list.dropFirst()
    }

    private var trainText: String {
        let need = String(format: loc("Facoltativo. La rende più fedele. Il Mac lavora da solo, tu non devi fare niente. Serve un Mac con almeno %d GB (livello %@)."),
                          times.trainRAM, VoiceTraining.tierName(times.trainTier.rawValue, lookup: loc))
        guard let mac = MachineTier(rawValue: tier), mac < times.trainTier else { return need }
        return need + " " + String(format: loc("Questo Mac è al livello %@."), VoiceTraining.tierName(tier, lookup: loc))
    }

    private func step(_ n: Int, _ title: String, _ time: String?, _ text: String, done: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Ed.Space.m) {
            StateGlyph(done ? "done" : "todo", number: n)
            VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
                    Text(verbatim: title).font(Ed.ui(Ed.TypeSize.control, .semibold)).foregroundStyle(Ed.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let time { Text(verbatim: time).font(Ed.mono(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize() }
                }
                Text(verbatim: text).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
            }
        }
        .rCard(.raised)
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

    /// A rough length in whole minutes: "10 min", "1 h 47 min" (the times of cloning).
    static func rough(_ minutes: Double) -> String {
        minutes < 60 ? String(format: "%d min", max(1, Int(minutes.rounded()))) : duration(minutes.rounded() * 60)
    }

    static func minutes(_ m: Double) -> String {
        let n = m < 10 ? m.formatted(.number.precision(.fractionLength(1))) : String(Int(m.rounded()))
        return n + " min"
    }
}
