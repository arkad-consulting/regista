import RegistaCore
import SwiftUI

/// The "Gestisci voci" window (V1 #61, V3): the four languages with their state on the left, the selected language on
/// the right — its overview (the seven tones, the training) when it has a voice, else its intro, consent, the neutral
/// tone and the check; recording another tone happens in place with a way back to the overview. Reachable from the
/// Voce panel and from Settings › Profilo e voce; it opens where the entry point said, and every action is a command.
struct VoiceSetupSheet: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.voiceDemo) private var demo

    var body: some View {
        VoiceSetupView(model: demo ?? store.voice, jobs: demo?.demoJobs ?? store.jobs) { store.showVoiceSetup = false }
    }
}

struct VoiceSetupView: View {
    @ObservedObject var model: VoiceModel
    @ObservedObject var jobs: JobCenter
    var onClose: () -> Void = {}
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var store: EditorStore
    @State private var name = ""

    static let size = CGSize(width: 880, height: 620)

    private var page: VoiceWindowPage { model.windowPage }
    private var code: String { model.windowLanguage }
    private var language: VoiceLanguageState? { model.snapshot.language(code) }
    private var live: Bool { recorder.isRecording || model.setup.recording }
    private var takeRunning: Bool { jobs.latest("voice-take")?.isRunning == true }

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 230)
            Ed.line.frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    content
                        .padding(.horizontal, Ed.Space.xxl)
                        .padding(.vertical, Ed.Space.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Ed.panel)
        .environment(\.colorScheme, .dark)
        .task { if !model.demo { await model.refresh(); await model.loadScript() } }
    }

    // MARK: Rail

    /// "Le tue voci": the profile, then the four languages, always all four, each with its state.
    private var rail: some View {
        let noProfile = page == .profile
        return VStack(alignment: .leading, spacing: Ed.Space.xxs) {
            Text(verbatim: loc("Le tue voci")).font(Ed.display(Ed.TypeSize.heading, .medium)).foregroundStyle(Ed.text)
                .padding(.horizontal, Ed.Space.s)
            Text(verbatim: model.snapshot.profile ?? loc("Nessun profilo"))
                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).lineLimit(1)
                .padding(.horizontal, Ed.Space.s).padding(.bottom, Ed.Space.m)
            ForEach(VoiceLanguages.all, id: \.self) { c in
                PickRow(title: VoiceLanguages.name(c), detail: VoiceRailState.of(model.snapshot.language(c)).label(loc),
                        selected: !noProfile && c == code, mark: .none) { model.chooseLanguage(c) }
            }
            .disabled(noProfile || live || takeRunning)
            .opacity(noProfile ? 0.4 : 1)
            Spacer()
            Text(verbatim: loc("Registrazioni e modello restano su questo Mac, nel tuo profilo."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Ed.Space.s)
        }
        .padding(.horizontal, Ed.Space.m).padding(.vertical, Ed.Space.l)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ed.header)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch page {
            case .profile: profilePage
            case .intro: introPage
            case .consent: consentPage
            case .record: recordPage
            case .check: checkPage
            case .overview: overviewPage
            }
        }
    }

    private func title(_ t: String, _ subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            Text(verbatim: t).font(Ed.display(Ed.TypeSize.large, .medium)).foregroundStyle(Ed.text).fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(verbatim: subtitle).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, Ed.Space.l)
    }

    @ViewBuilder
    private var profilePage: some View {
        if model.snapshot.profileLocked {
            title(loc("Questo profilo è di un altro Mac"),
                  loc("È stato copiato da un altro Mac: la sua voce si usa solo dopo averlo adottato. Se è tuo, adottalo in Impostazioni › Profilo e voce."))
        } else {
            title(loc("Di chi è questa voce?"),
                  loc("Il profilo è la persona che Regista può far parlare su questo Mac: tiene le sue registrazioni e il modello della sua voce. Scrivi il tuo nome: lo dirai nella frase di consenso."))
            VStack(alignment: .leading, spacing: Ed.Space.m) {
                RTextField(placeholder: "Il tuo nome", text: $name).frame(maxWidth: 320)
                EdButton(title: loc("Crea il profilo"), symbol: "person.badge.plus", prominent: true, large: true,
                         disabled: name.trimmingCharacters(in: .whitespaces).isEmpty) { model.createProfile(name) }
            }
        }
    }

    /// A language without a voice: what will happen for it (the panel's four facts), before consent.
    private var introPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(String(format: loc("Clona la tua voce in %@"), VoiceLanguages.name(code)),
                  loc("Leggi ad alta voce un testo che ti mostra Regista. Regista impara la tua voce su questo Mac e poi dice per te qualsiasi testo."))
            VoiceCloneSteps(times: model.cloneTimes, tier: model.snapshot.tier, language: code).frame(maxWidth: 560)
        }
    }

    private var consentPage: some View {
        VStack(alignment: .leading, spacing: Ed.Space.l) {
            title(loc("Prima di iniziare"), loc("Cosa succede alla tua voce, detto semplice."))
            point("quote.opening", loc("La prima registrazione inizia con una frase di consenso, letta ad alta voce:"),
                  quote: model.setup.consent.isEmpty ? nil : model.setup.consent)
            point("lock.laptopcomputer", loc("Registrazioni e modello della voce restano su questo Mac, nel tuo profilo. Non finiscono mai in un pacchetto condiviso con altri."))
            point("trash", loc("Puoi cancellarli quando vuoi: Impostazioni › Profilo e voce › Elimina il mio profilo e la mia voce. Vanno nel Cestino."))
            point("mic", loc("Una stanza silenziosa e morbida, sempre la stessa distanza dal microfono. Un telefono con un microfono esterno va benissimo: poi importi il file."))
        }
    }

    private func point(_ symbol: String, _ text: String, quote: String? = nil) -> some View {
        HStack(alignment: .top, spacing: Ed.Space.m) {
            Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.body, .medium)).foregroundStyle(Ed.gold)
                .frame(width: 28, height: 28).background(Circle().fill(Ed.goldSoft))
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                Text(verbatim: text).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                if let quote {
                    Text(verbatim: "«\(quote)»").font(Ed.display(Ed.TypeSize.title)).italic().foregroundStyle(Ed.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    // MARK: Record

    private var recordPage: some View {
        let tone = model.recordTone
        let lines = model.setup.lines[tone] ?? []
        let needsConsent = language?.consent != true
        return VStack(alignment: .leading, spacing: Ed.Space.l) {
            if language?.hasVoice == true {
                AccentLinkButton(title: String(format: loc("‹ %@, tutti i toni"), VoiceLanguages.name(code)), tip: "Torna ai toni di questa lingua") {
                    model.setup.pendingTone = nil
                }
                .disabled(live || takeRunning)
            }
            VStack(alignment: .leading, spacing: Ed.Space.xs) {
                Text(verbatim: String(format: loc("Tono «%@»"), loc(VoiceTones.title(tone))))
                    .font(Ed.display(Ed.TypeSize.large, .medium)).foregroundStyle(Ed.text)
                Text(verbatim: String(format: loc("%d righe · circa %d min · resta nel tono per tutto il blocco, un po' esagerato"),
                                      lines.count, max(1, Int(RecordingScript.minutes(lines: lines).rounded()))))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
            }
            recordingBar
            ScrollView {
                VStack(alignment: .leading, spacing: Ed.Space.m) {
                    if needsConsent, !model.setup.consent.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Inizia con", tint: Ed.gold)
                            Text(verbatim: model.setup.consent).font(Ed.display(Ed.TypeSize.heading)).foregroundStyle(Ed.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Ed.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.goldSoft))
                        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.gold.opacity(0.35)))
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .firstTextBaseline, spacing: Ed.Space.m) {
                            Text(verbatim: String(format: "%02d", i + 1)).font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).frame(width: 22, alignment: .trailing)
                            Text(verbatim: line).font(Ed.display(Ed.TypeSize.heading)).foregroundStyle(Ed.text.opacity(0.92)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Ed.Space.l)
            }
            .frame(height: language?.hasVoice == true ? 250 : 270)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.xl).fill(Ed.well))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.xl).strokeBorder(Ed.line2))
            Text(verbatim: loc("5 secondi di silenzio all'inizio, una pausa tra le righe. Se sbagli, fermati un attimo e rileggi tutta la riga."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            if let job = jobs.latest("voice-take"), job.isRunning { JobCard(job: job) }
        }
    }

    /// The microphone while recording: level, elapsed time, and why there is no pause for a voice-only take.
    private var recordingBar: some View {
        let live = recorder.isRecording || model.setup.recording
        return HStack(spacing: Ed.Space.m) {
            Circle().fill(live ? Ed.danger : Ed.text3.opacity(0.5)).frame(width: 8, height: 8)
            Text(verbatim: live ? loc("Registrazione in corso") : (recorder.microphoneDevice?.localizedName ?? recorder.deviceName(.microphone) ?? loc("Microfono")))
                .font(Ed.ui(Ed.TypeSize.small, .medium)).foregroundStyle(live ? Ed.text : Ed.text2).lineLimit(1)
            Group {
                if model.demo { RLevelMeter(value: 0.55, segments: 24, height: 6) }
                else { MicLevelMeter(level: recorder.level, segments: 24, height: 6) }
            }
            .frame(width: 150)
            Text(verbatim: timecode(live ? recorder.elapsed : 0)).font(Ed.mono(Ed.TypeSize.small, .medium)).foregroundStyle(live ? Ed.text : Ed.text3)
            Spacer(minLength: 0)
            if live {
                Text(verbatim: loc("Senza pausa: se serve, ferma e registra un altro file dello stesso tono"))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).lineLimit(2).frame(maxWidth: 200, alignment: .trailing)
            }
        }
        .padding(.horizontal, Ed.Space.m)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.header))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(live ? Ed.danger.opacity(0.4) : Ed.line2))
    }

    // MARK: Check

    @ViewBuilder
    private var checkPage: some View {
        if let c = model.setup.check {
            if let error = c.error {
                title(loc("Registrazione non accettata"), error)
            } else {
                let tone = loc(VoiceTones.title(c.tone))
                title(c.good ? String(format: loc("Fatto: %d righe su %d"), c.accepted, c.total)
                             : String(format: loc("Solo %d righe su %d"), c.accepted, c.total),
                      c.good ? String(format: loc("Il blocco «%@» è registrato."), tone)
                             : loc("Ne servono almeno 7 su 10. Rileggi le righe mancanti in una nuova registrazione dello stesso tono: si aggiunge a questa."))
                HStack(spacing: Ed.Space.m) {
                    fact(loc("Righe sentite"), "\(c.accepted)/\(c.total)", ok: c.good)
                    fact(loc("Clip tenute"), "\(c.accepted)", ok: c.accepted > 0)
                    fact(loc("Minuti registrati"), VoiceFormat.minutes(c.minutes), ok: true)
                    fact(loc("Consenso"), c.consent ? loc("riconosciuto") : loc("non sentito"), ok: c.consent)
                }
                .padding(.bottom, Ed.Space.l)
                if c.good, c.tone == VoiceTone.neutral, c.reference {
                    HStack(alignment: .top, spacing: Ed.Space.m) {
                        Image(systemName: "waveform").font(Ed.icon(Ed.TypeSize.control)).foregroundStyle(Ed.ok)
                        Text(verbatim: loc("La voce è già utilizzabile: Regista la imita da un riferimento di questa registrazione. Gli altri toni e l'allenamento la rendono più ricca e fedele."))
                            .font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Ed.Space.m)
                    .frame(maxWidth: 600, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.ok.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.ok.opacity(0.3)))
                }
                if !c.good, !c.missing.isEmpty {
                    RSection(loc("Righe da rileggere")) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(c.missing.prefix(5).enumerated()), id: \.offset) { _, line in
                                Text(verbatim: "— \(line)").font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
                            }
                            if c.missing.count > 5 {
                                Text(verbatim: String(format: loc("e altre %d"), c.missing.count - 5)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                            }
                        }
                    }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: Ed.Space.xs) {
            SectionLabel(label)
            Text(verbatim: value).font(Ed.mono(Ed.TypeSize.heading, .medium)).foregroundStyle(ok ? Ed.text : Ed.warn)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(Ed.Space.m)
        .frame(width: 138, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.header))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.line2))
    }

    // MARK: Overview

    /// A language with a voice: the seven tones as tiles, the training card.
    @ViewBuilder
    private var overviewPage: some View {
        if let l = language {
            title(String(format: loc("La tua voce in %@"), VoiceLanguages.name(l.code)), overviewLine(l))
            RSection(loc("Toni")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Ed.Space.s), count: 4), spacing: Ed.Space.s) {
                    ForEach(VoiceToneTile.tiles(l), id: \.tone) { toneTile($0) }
                }
                Text(verbatim: loc("I toni sono facoltativi: registra solo quelli che ti servono."))
                    .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.bottom, Ed.Space.l)
            trainCard(l)
        }
    }

    private func overviewLine(_ l: VoiceLanguageState) -> String {
        if l.trained { return loc("Allenata: la voce più fedele. Puoi registrare altri toni e allenarla di nuovo.") }
        guard l.seconds > 0 else { return loc("Pronta dal riferimento: si usa già nel pannello Voce. Altri toni e l'allenamento la rendono più fedele.") }
        return String(format: loc("Pronta: si usa già nel pannello Voce. %@ registrati, non ancora allenata."), VoiceFormat.minutes(l.minutes))
    }

    /// A recorded tone: a check and its minutes when the profile has them (a model made elsewhere has none: no "0 min").
    /// A tone to record: dashed, with its time; a click records it (a recorded one: one more take, added).
    private func toneTile(_ t: VoiceToneTile) -> some View {
        let minutes = t.tone == VoiceTone.neutral ? model.cloneTimes.neutralMinutes
            : (model.setup.lines[t.tone].map { RecordingScript.minutes(lines: $0) } ?? model.cloneTimes.toneMinutes)
        let shape = RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous)
        return Button { model.setup.pendingTone = t.tone } label: {
            VStack(alignment: .leading, spacing: Ed.Space.xs) {
                Text(verbatim: loc(VoiceTones.title(t.tone))).font(Ed.ui(Ed.TypeSize.body, .semibold)).foregroundStyle(Ed.text).lineLimit(1)
                Spacer(minLength: 0)
                if t.recorded {
                    HStack(spacing: Ed.Space.xs) {
                        Image(systemName: "checkmark").font(Ed.icon(Ed.TypeSize.caption, .bold))
                        if let m = t.minutes { Text(verbatim: VoiceFormat.minutes(m)).font(Ed.mono(Ed.TypeSize.small)) }
                    }
                    .foregroundStyle(Ed.ok)
                } else {
                    Text(verbatim: String(format: loc("Registra · ~%@"), VoiceFormat.rough(minutes)))
                        .font(Ed.ui(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.gold).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .padding(Ed.Space.s + Ed.Space.xxs)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(shape.fill(t.recorded ? Ed.raised : .clear))
            .overlay {
                if t.recorded { shape.strokeBorder(Ed.line2) } else { shape.strokeBorder(Ed.text4, style: .rDashed) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(t.recorded ? "Registra ancora questo tono (si aggiunge)" : "Registra questo tono")
    }

    /// The training: estimate and power note, Allena la voce (disabled with the reason), progress while it runs.
    private func trainCard(_ l: VoiceLanguageState) -> some View {
        let block = VoiceTraining.blockReason(model.snapshot, language: l, lookup: loc)
        return VStack(alignment: .leading, spacing: Ed.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
                Text(verbatim: loc("Allenamento")).font(Ed.ui(Ed.TypeSize.title, .semibold)).foregroundStyle(Ed.text)
                Text(verbatim: loc("facoltativo · voce più fedele")).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                Spacer()
            }
            if case .running(let step, let steps, let left) = l.training {
                Text(verbatim: loc("Puoi chiudere questa finestra e continuare a lavorare: l'allenamento va avanti in background. Tieni il Mac acceso e collegato alla corrente."))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                if let job = jobs.latest("voice-training") { JobCard(job: job) }
                else {
                    JobProgressBar(progress: (step != nil && steps != nil && steps! > 0) ? Double(step!) / Double(steps!) : nil)
                    if let step, let steps {
                        Text(verbatim: left.map { String(format: loc("Passo %d di %d · circa %d min"), step, steps, Int($0)) } ?? String(format: loc("Passo %d di %d"), step, steps))
                            .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text2)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: Ed.Space.l) {
                    Text(verbatim: String(format: loc("Circa %@. Tieni il Mac acceso e collegato alla corrente: l'allenamento continua anche se chiudi questa finestra."),
                                          VoiceFormat.rough(model.cloneTimes.trainMinutes)))
                        .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    EdButton(title: loc("Allena la voce"), symbol: "cpu", prominent: true, large: true, disabled: block != nil) { model.train() }
                        .fixedSize()
                }
                if let block {
                    Label { Text(verbatim: block).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.circle") }
                        .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.warn)
                }
            }
        }
        .padding(Ed.Space.l)
        .frame(maxWidth: 600, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.xl).fill(Ed.header))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.xl).strokeBorder(Ed.line2))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Ed.Space.s) {
            EdButton(title: loc("Chiudi"), action: onClose)
            Spacer()
            footerActions.fixedSize()
        }
        .padding(.horizontal, Ed.Space.xl)
        .frame(height: 60)
        .background(Ed.header)
        .overlay(alignment: .top) { Ed.line.frame(height: 1) }
    }

    @ViewBuilder
    private var footerActions: some View {
        switch page {
        case .profile:
            EmptyView()
        case .intro:
            EdButton(title: loc("Inizia"), symbol: "arrow.right", prominent: true, large: true) { model.setup.started = true }
        case .consent:
            EdButton(title: loc("Ho capito, registra"), symbol: "arrow.right", prominent: true, large: true) { model.setup.consentRead = true }
        case .record:
            HStack(spacing: Ed.Space.s) {
                EdButton(title: loc("Importa un file audio…"), symbol: "square.and.arrow.down", large: true, disabled: takeRunning || recorder.isRecording) { model.importTake() }
                EdButton(title: recorder.isRecording ? loc("Ferma") : loc("Registra"), symbol: recorder.isRecording ? "stop.fill" : "record.circle",
                         destructive: true, large: true, disabled: takeRunning) {
                    if recorder.isRecording { model.stopRecording(recorder) } else { model.startRecording(recorder) }
                }
                .tip("Registra solo il microfono: il file resta fuori dal montaggio")
            }
        case .check:
            if let c = model.setup.check {
                if c.good {
                    if c.tone == VoiceTone.neutral, c.reference {
                        EdButton(title: loc("Prova la voce"), symbol: "play.fill", large: true) { tryVoice() }
                    }
                    EdButton(title: loc("Continua"), symbol: "arrow.right", prominent: true, large: true) { model.continueAfterCheck(again: false) }
                } else {
                    EdButton(title: loc("Continua comunque"), large: true, disabled: c.error != nil && language?.hasVoice != true) { model.continueAfterCheck(again: false) }
                    EdButton(title: loc("Registra di nuovo"), symbol: "record.circle", prominent: true, large: true) { model.continueAfterCheck(again: true) }
                }
            }
        case .overview:
            EdButton(title: loc("Prova la voce"), symbol: "play.fill", large: true) { tryVoice() }
        }
    }

    /// "Prova la voce": the Voce panel in Monta, on this language.
    private func tryVoice() {
        model.language = code
        model.pane = .text
        store.workspace = .pro
        store.select(.voice)
        onClose()
    }
}

/// One line per language: how it is ready, its tones, the minutes recorded (Settings and the flow).
enum VoiceSummary {
    static func line(_ l: VoiceLanguageState) -> String {
        var parts: [String] = []
        if l.training.isRunning { parts.append(loc("allenamento in corso")) }
        else if l.trained { parts.append(loc("allenata")) }
        else if l.zeroShotReady || l.ready { parts.append(loc("pronta dal riferimento")) }
        else { parts.append(loc("da completare")) }
        let tones = (l.tones.isEmpty ? Array(l.recorded.keys) : l.tones).sorted { VoiceTones.all.firstIndex(of: $0) ?? 9 < VoiceTones.all.firstIndex(of: $1) ?? 9 }
        if !tones.isEmpty { parts.append(tones.map { loc(VoiceTones.title($0)).lowercased() }.joined(separator: ", ")) }
        if l.seconds > 0 { parts.append(String(format: loc("%@ registrati"), VoiceFormat.minutes(l.minutes))) }
        return parts.joined(separator: " · ")
    }
}
