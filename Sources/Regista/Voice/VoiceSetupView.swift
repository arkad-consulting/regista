import RegistaCore
import SwiftUI

/// The guided flow (V1 #61): profile → language → consent → record one block per tone (neutral first) → check the
/// take → the voice and its optional training. Reachable from the Voce panel and from Settings › Profilo e voce; it
/// always reopens on the step voice.enroll.status says, and every action is a command.
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
    @State private var pickedLanguage: String?

    static let size = CGSize(width: 880, height: 620)

    private var step: VoiceSetupStep { model.setupStep }
    private var language: VoiceLanguageState? { model.snapshot.language(model.setup.language) }

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 210)
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

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: loc("La tua voce")).font(Ed.display(Ed.TypeSize.title + 2, .medium)).foregroundStyle(Ed.text)
                .padding(.bottom, 2)
            Text(verbatim: model.snapshot.profile.map { p in model.setup.language.map { "\(p) · \(VoiceLanguages.name($0))" } ?? p } ?? loc("Nessun profilo"))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).padding(.bottom, Ed.Space.l)
            ForEach(Array(railSteps.enumerated()), id: \.offset) { i, item in
                HStack(spacing: Ed.Space.s) {
                    ZStack {
                        Circle().fill(item.current ? Ed.gold : (item.done ? Ed.goldSoft : Ed.well))
                        Circle().strokeBorder(item.current ? .clear : (item.done ? Ed.gold.opacity(0.4) : Ed.line2))
                        if item.done && !item.current {
                            Image(systemName: "checkmark").font(Ed.icon(8, .bold)).foregroundStyle(Ed.gold)
                        } else {
                            Text(verbatim: "\(i + 1)").font(Ed.mono(9, .semibold)).foregroundStyle(item.current ? Accent.on : Ed.text3)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(verbatim: loc(item.title)).font(Ed.ui(Ed.TypeSize.small, item.current ? .semibold : .regular))
                        .foregroundStyle(item.current ? Ed.text : (item.done ? Ed.text2 : Ed.text3))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Ed.Space.s)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(item.current ? Ed.raised : .clear))
            }
            Spacer()
            if model.setup.language != nil, step != .language, step != .profile, !(recorder.isRecording || model.setup.recording) {
                EdButton(title: loc("Cambia lingua"), symbol: "globe") { model.setup.language = nil; pickedLanguage = nil; model.setup.check = nil }
                    .padding(.bottom, Ed.Space.m)
            }
            Text(verbatim: loc("Registrazioni e modello restano su questo Mac, nel tuo profilo."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Ed.Space.l)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ed.header)
    }

    private var railSteps: [(title: String, done: Bool, current: Bool)] {
        let l = language
        let s = step
        return [
            (loc("Profilo"), model.snapshot.profile != nil, s == .profile),
            (loc("Lingua"), model.setup.language != nil, s == .language),
            (loc("Consenso"), l?.consent == true, s == .consent),
            (loc("Registra"), l?.zeroShotReady == true, s == .record),
            (loc("Controllo"), l?.zeroShotReady == true, s == .check),
            (loc("Voce e allenamento"), l?.trained == true, s == .overview || s == .training),
        ]
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .profile: profileStep
            case .language: languageStep
            case .consent: consentStep
            case .record: recordStep
            case .check: checkStep
            case .overview: overviewStep
            case .training: trainingStep
            }
        }
    }

    private func title(_ t: String, _ subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            Text(verbatim: t).font(Ed.display(Ed.TypeSize.display - 4, .medium)).foregroundStyle(Ed.text).fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(verbatim: subtitle).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, Ed.Space.l)
    }

    @ViewBuilder
    private var profileStep: some View {
        if model.snapshot.profileLocked {
            title(loc("Questo profilo è di un altro Mac"),
                  loc("È stato copiato da un altro Mac: la sua voce si usa solo dopo averlo adottato. Se è tuo, adottalo in Impostazioni › Profilo e voce."))
        } else {
            title(loc("Di chi è questa voce?"),
                  loc("Il profilo è la persona che Regista può far parlare su questo Mac: tiene le sue registrazioni e il modello della sua voce. Scrivi il tuo nome: lo dirai nella frase di consenso."))
            VStack(alignment: .leading, spacing: Ed.Space.m) {
                RTextField(placeholder: loc("Il tuo nome"), text: $name).frame(maxWidth: 320)
                EdButton(title: loc("Crea il profilo"), symbol: "person.badge.plus", prominent: true, large: true,
                         disabled: name.trimmingCharacters(in: .whitespaces).isEmpty) { model.createProfile(name) }
            }
        }
    }

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: Ed.Space.l) {
            title(loc("In che lingua registri?"),
                  loc("Ogni lingua ha il suo copione e la sua voce. Comincia da quella in cui farai più video; le altre si aggiungono dopo."))
            RChips(items: VoiceLanguages.all.map { .init(id: $0, title: VoiceLanguages.name($0)) }, selection: pickedLanguage ?? model.setup.language,
                   columns: 4, height: 44) { pickedLanguage = $0 }
            .frame(maxWidth: 520)
            if !model.snapshot.languages.isEmpty {
                InspectorSection(title: loc("Già registrate")) {
                    VStack(spacing: 0) {
                        ForEach(model.snapshot.languages) { l in
                            HStack {
                                Text(verbatim: VoiceLanguages.name(l.code)).font(Ed.ui(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.text)
                                Spacer()
                                Text(verbatim: VoiceSummary.line(l)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                            }
                            .padding(.horizontal, Ed.Space.m).frame(height: 32)
                            .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
                        }
                    }
                    .modifier(ListBox())
                    .frame(maxWidth: 520)
                }
            }
        }
    }

    private var consentStep: some View {
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
            Image(systemName: symbol).font(Ed.icon(12, .medium)).foregroundStyle(Ed.gold)
                .frame(width: 28, height: 28).background(Circle().fill(Ed.goldSoft))
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                Text(verbatim: text).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                if let quote {
                    Text(verbatim: "«\(quote)»").font(Ed.display(Ed.TypeSize.title + 1)).italic().foregroundStyle(Ed.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    // MARK: Record

    private var recordStep: some View {
        let tone = model.recordTone
        let lines = model.setup.lines[tone] ?? []
        let needsConsent = language?.consent != true
        let minutes = Double(lines.joined(separator: " ").split(separator: " ").count) / 2.4 / 60 + Double(lines.count) * 1.5 / 60
        return VStack(alignment: .leading, spacing: Ed.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(format: loc("Blocco «%@»"), loc(VoiceTones.title(tone))))
                        .font(Ed.display(Ed.TypeSize.display - 6, .medium)).foregroundStyle(Ed.text)
                    Text(verbatim: String(format: loc("%d righe · circa %d min · resta nel tono per tutto il blocco, un po' esagerato"),
                                          lines.count, max(1, Int(minutes.rounded()))))
                        .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                }
                Spacer()
            }
            recordingBar
            if language?.zeroShotReady == true {
                RChips(items: VoiceTones.all.map { .init(id: $0, title: loc(VoiceTones.title($0))) }, selection: tone, columns: 7, height: 26) {
                    model.setup.pendingTone = $0
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Ed.Space.m) {
                    if needsConsent, !model.setup.consent.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Inizia con", tint: Ed.gold)
                            Text(verbatim: model.setup.consent).font(Ed.display(19)).foregroundStyle(Ed.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Ed.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.goldSoft))
                        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.gold.opacity(0.35)))
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .firstTextBaseline, spacing: Ed.Space.m) {
                            Text(verbatim: String(format: "%02d", i + 1)).font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).frame(width: 22, alignment: .trailing)
                            Text(verbatim: line).font(Ed.display(19)).foregroundStyle(Ed.text.opacity(0.92)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Ed.Space.l)
            }
            .frame(height: 270)
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
    private var checkStep: some View {
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
                        Image(systemName: "waveform").font(Ed.icon(13)).foregroundStyle(Ed.ok)
                        Text(verbatim: loc("La voce è già utilizzabile: Regista la imita da un riferimento di questa registrazione. Gli altri toni e l'allenamento la rendono più ricca e fedele."))
                            .font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Ed.Space.m)
                    .frame(maxWidth: 600, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.ok.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.ok.opacity(0.3)))
                }
                if !c.good, !c.missing.isEmpty {
                    InspectorSection(title: loc("Righe da rileggere")) {
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
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(label)
            Text(verbatim: value).font(Ed.mono(17, .medium)).foregroundStyle(ok ? Ed.text : Ed.warn)
        }
        .padding(Ed.Space.m)
        .frame(width: 138, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.header))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.line2))
    }

    // MARK: Overview and training

    @ViewBuilder
    private var overviewStep: some View {
        if let l = language {
            title(String(format: loc("La tua voce in %@"), VoiceLanguages.name(l.code)),
                  l.trained ? loc("Allenata: la voce più fedele. Puoi registrare altri toni e allenarla di nuovo.")
                            : loc("Pronta dal riferimento: si usa già nel pannello Voce. Altri toni e l'allenamento la rendono più fedele."))
            InspectorSection(title: loc("Toni")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(VoiceTones.all, id: \.self) { t in toneTile(t, l) }
                }
                .frame(maxWidth: 600)
            }
            .padding(.bottom, Ed.Space.l)
            trainCard(l)
        }
    }

    private func toneTile(_ tone: String, _ l: VoiceLanguageState) -> some View {
        let minutes = l.recorded[tone]
        return Button { model.setup.pendingTone = tone } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: loc(VoiceTones.title(tone))).font(Ed.ui(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.text)
                Text(verbatim: minutes.map { VoiceFormat.minutes($0) } ?? loc("da registrare"))
                    .font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(minutes == nil ? Ed.text3 : Ed.gold)
            }
            .padding(Ed.Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(minutes == nil ? Ed.well : Ed.goldSoft))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.m).strokeBorder(minutes == nil ? Ed.line2 : Ed.gold.opacity(0.35)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(minutes == nil ? "Registra questo tono" : "Registra ancora questo tono (si aggiunge)")
    }

    private func trainCard(_ l: VoiceLanguageState) -> some View {
        let block = VoiceTraining.blockReason(model.snapshot, language: l, lookup: loc)
        return VStack(alignment: .leading, spacing: Ed.Space.s) {
            HStack {
                Text(verbatim: loc("Allenamento")).font(Ed.ui(Ed.TypeSize.title, .semibold)).foregroundStyle(Ed.text)
                Text(verbatim: loc("facoltativo · qualità migliore")).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                Spacer()
            }
            Text(verbatim: String(format: loc("Registrati %@ (ne servono almeno %@). Durata stimata: circa %@. Tieni il Mac acceso e collegato alla corrente: l'allenamento continua anche se chiudi questa finestra."),
                                  VoiceFormat.minutes(l.minutes), VoiceFormat.minutes(l.trainMinimumSeconds / 60), VoiceFormat.duration(l.trainEstimateMinutes * 60)))
                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            if let block {
                Label { Text(verbatim: block).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.warn)
            }
        }
        .padding(Ed.Space.l)
        .frame(maxWidth: 600, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.xl).fill(Ed.header))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.xl).strokeBorder(Ed.line2))
    }

    @ViewBuilder
    private var trainingStep: some View {
        let job = jobs.latest("voice-training")
        title(loc("La voce si sta allenando"),
              loc("Puoi chiudere questa finestra e continuare a lavorare: l'allenamento va avanti in background. Tieni il Mac acceso e collegato alla corrente."))
        if let job { JobCard(job: job).frame(maxWidth: 600) }
        else if case .running(let step, let steps, let left) = language?.training {
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                JobProgressBar(progress: (step != nil && steps != nil && steps! > 0) ? Double(step!) / Double(steps!) : nil)
                if let step, let steps {
                    Text(verbatim: left.map { String(format: loc("Passo %d di %d · circa %d min"), step, steps, Int($0)) } ?? String(format: loc("Passo %d di %d"), step, steps))
                        .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text2)
                }
            }
            .frame(maxWidth: 600)
        }
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
        switch step {
        case .profile:
            EmptyView()
        case .language:
            EdButton(title: loc("Continua"), symbol: "arrow.right", prominent: true, large: true, disabled: (pickedLanguage ?? model.setup.language) == nil) {
                if let l = pickedLanguage ?? model.setup.language { model.chooseLanguage(l) }
            }
        case .consent:
            EdButton(title: loc("Ho capito, registra"), symbol: "arrow.right", prominent: true, large: true) { model.setup.consentRead = true }
        case .record:
            let busy = jobs.latest("voice-take")?.isRunning == true
            HStack(spacing: Ed.Space.s) {
                EdButton(title: loc("Importa un file audio…"), symbol: "square.and.arrow.down", large: true, disabled: busy || recorder.isRecording) { model.importTake() }
                EdButton(title: recorder.isRecording ? loc("Ferma") : loc("Registra"), symbol: recorder.isRecording ? "stop.fill" : "record.circle",
                         destructive: true, large: true, disabled: busy) {
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
                    EdButton(title: loc("Continua comunque"), large: true, disabled: c.error != nil && language?.zeroShotReady != true) { model.continueAfterCheck(again: false) }
                    EdButton(title: loc("Registra di nuovo"), symbol: "record.circle", prominent: true, large: true) { model.continueAfterCheck(again: true) }
                }
            }
        case .overview:
            if let l = language {
                EdButton(title: loc("Prova la voce"), symbol: "play.fill", large: true) { tryVoice() }
                EdButton(title: loc("Allena la voce"), symbol: "cpu", prominent: true, large: true,
                         disabled: VoiceTraining.blockReason(model.snapshot, language: l) != nil) { model.train() }
            }
        case .training:
            EdButton(title: loc("Continua a lavorare"), prominent: true, large: true, action: onClose)
        }
    }

    /// "Prova la voce": the Voce panel in Monta, on this language.
    private func tryVoice() {
        model.language = model.setup.language
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
