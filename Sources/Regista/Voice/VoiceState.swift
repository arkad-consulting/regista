import Foundation
import RegistaCore

// The voice features as the app sees them (V1 #61, V2 #62): pure values read from voice.list, voice.enroll.status and
// profile.get, the Voce panel's state and the recording flow's step computed from them. No view, no engine: tested
// alone, and ui.screenshot draws any state from a value.

/// One language of the active profile's voice, from voice.list and voice.enroll.status.
struct VoiceLanguageState: Equatable, Identifiable {
    var code: String
    /// Usable now (voice.list ready: a neutral reference or a LoRA, and every file there).
    var ready = false
    var trained = false
    /// Tones it can say (voice.list).
    var tones: [String] = []
    var lexiconEntries = 0
    var lexiconPending = 0
    // From voice.enroll.status.
    var consent = false
    var zeroShotReady = false
    /// Recorded minutes per tone.
    var recorded: [String: Double] = [:]
    var seconds = 0.0
    var trainMinimumSeconds = 90.0
    var trainEstimateMinutes = 0.0
    var training: Training = .never

    var id: String { code }

    enum Training: Equatable {
        case never, done, failed
        case running(step: Int?, steps: Int?, minutesLeft: Double?)

        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    /// Clips missing before a training can start (0: enough).
    var missingSeconds: Double { max(0, trainMinimumSeconds - seconds) }
    var minutes: Double { seconds / 60 }

    /// A voice exists in this language: usable, with a neutral reference, or trained (a model made outside the app
    /// counts, even with no recorded minutes).
    var hasVoice: Bool { ready || zeroShotReady || trained }

    /// The tones this voice has: the ones it can say and the ones recorded (at least one once a voice exists).
    var voiceTones: [String] {
        let have = Set(tones).union(recorded.filter { $0.value > 0 }.keys)
        let list = VoiceTones.all.filter { have.contains($0) }
        return list.isEmpty && hasVoice ? [VoiceTone.neutral] : list
    }
}

/// Everything the Voce panel, the recording flow and Settings › Profilo e voce draw.
struct VoiceSnapshot: Equatable {
    var loaded = false
    var engineAvailable = false
    /// The engine's reason when unavailable ("needs the medium tier", a missing file…).
    var engineReason: String?
    var tier = "base"
    var profile: String?
    var profileLocked = false
    var languages: [VoiceLanguageState] = []
    var trainerAvailable = false
    /// "tier", "trainer" or "engine".
    var trainerReason: String?

    func language(_ code: String?) -> VoiceLanguageState? { languages.first { $0.code == code } }
    var readyLanguages: [VoiceLanguageState] { languages.filter(\.ready) }

    /// voice.list (+ voice.enroll.status when there is an unlocked profile).
    init(list: JSONValue, status: JSONValue? = nil) {
        loaded = true
        engineAvailable = list.value(at: "engine.available")?.boolValue ?? false
        engineReason = list.value(at: "engine.reason")?.stringValue
        tier = list.value(at: "engine.tier")?.stringValue ?? "base"
        profile = list.value(at: "profile.name")?.stringValue
        profileLocked = list.value(at: "profile.locked") != nil
        var byCode: [String: VoiceLanguageState] = [:]
        for l in list["languages"]?.arrayValue ?? [] {
            guard let code = l["language"]?.stringValue else { continue }
            var s = VoiceLanguageState(code: code)
            s.ready = l["ready"]?.boolValue ?? false
            s.trained = l["mode"]?.stringValue == "lora"
            s.tones = l["tones"]?.arrayValue?.compactMap(\.stringValue) ?? []
            s.lexiconEntries = Int(l.value(at: "lexicon.entries")?.doubleValue ?? 0)
            s.lexiconPending = Int(l.value(at: "lexicon.pending")?.doubleValue ?? 0)
            byCode[code] = s
        }
        for l in status?["languages"]?.arrayValue ?? [] {
            guard let code = l["language"]?.stringValue else { continue }
            var s = byCode[code] ?? VoiceLanguageState(code: code)
            s.consent = l["consent"]?.boolValue ?? false
            s.zeroShotReady = l["zeroShotReady"]?.boolValue ?? false
            for (tone, v) in l["tones"]?.objectValue ?? [:] { s.recorded[tone] = v["minutes"]?.doubleValue ?? 0 }
            s.seconds = l["seconds"]?.doubleValue ?? 0
            s.trainMinimumSeconds = l["trainMinimumSeconds"]?.doubleValue ?? 90
            s.trainEstimateMinutes = l["trainEstimateMinutes"]?.doubleValue ?? 0
            if l["lora"]?.stringValue != nil { s.trained = true }
            switch l.value(at: "training.state")?.stringValue {
            case "running":
                s.training = .running(step: l.value(at: "training.step")?.doubleValue.map { Int($0) },
                                      steps: l.value(at: "training.steps")?.doubleValue.map { Int($0) },
                                      minutesLeft: l.value(at: "training.minutesLeft")?.doubleValue)
            case "done": s.training = .done
            case "failed": s.training = .failed
            default: s.training = .never
            }
            byCode[code] = s
        }
        languages = byCode.values.sorted { VoiceLanguages.order($0.code) < VoiceLanguages.order($1.code) }
        trainerAvailable = status?.value(at: "trainer.available")?.boolValue ?? false
        trainerReason = status?.value(at: "trainer.reason")?.stringValue ?? (status == nil ? nil : "tier")
    }

    init() {}
}

/// The languages a voice can be recorded in (the shipped scripts).
enum VoiceLanguages {
    static let all = ["it", "fr", "en", "pt"]
    static func order(_ code: String) -> Int { all.firstIndex(of: code) ?? all.count }

    /// The language's own name (as the teleprompter shows it).
    static func name(_ code: String) -> String {
        switch code {
        case "it": "Italiano"
        case "fr": "Français"
        case "en": "English"
        case "pt": "Português"
        default: code.uppercased()
        }
    }

    /// The language a first voice starts from: the app's language when a voice can be recorded in it, else Italian.
    static var preferred: String {
        Bundle.main.preferredLocalizations.lazy.map { String($0.prefix(2)) }.first { all.contains($0) } ?? "it"
    }
}

/// The tones of the recording script (RecordingScript.tones), with their Italian names (looked up).
enum VoiceTones {
    static let all = RecordingScript.tones

    static func title(_ tone: String) -> String {
        switch tone {
        case "neutral": "Neutro"
        case "enthusiastic": "Entusiasta"
        case "serious": "Serio"
        case "calm": "Calmo"
        case "playful": "Ironico"
        case "alarmed": "Allarmato"
        case "sad": "Triste"
        default: tone
        }
    }
}

/// What the Voce panel shows: never a dead end, never "ask Claude".
enum VoicePanelState: Equatable {
    /// The engine cannot run here (tier or missing install): the feature stays visible, disabled, with the reason.
    case engineMissing(String)
    /// No profile: create it here.
    case noProfile
    /// The active profile was copied from another Mac: it is adopted in Settings.
    case locked(String)
    /// A profile without a usable voice: into the recording flow.
    case noVoice(String)
    case ready

    /// No profile, or a profile without a usable voice: the panel is the way into cloning.
    var leadsToCloning: Bool {
        switch self {
        case .noProfile, .noVoice: true
        default: false
        }
    }

    static func from(_ s: VoiceSnapshot, lookup: (String) -> String = { $0 }) -> VoicePanelState {
        if !s.engineAvailable { return .engineMissing(engineReason(s, lookup: lookup)) }
        guard let name = s.profile else { return .noProfile }
        if s.profileLocked { return .locked(name) }
        return s.readyLanguages.isEmpty ? .noVoice(name) : .ready
    }

    /// The engine's reason in plain words.
    static func engineReason(_ s: VoiceSnapshot, lookup: (String) -> String) -> String {
        if MachineTier(rawValue: s.tier).map({ $0 < .medium }) ?? true {
            return String(format: lookup("La voce clonata richiede un Mac con almeno 16 GB di RAM (livello Medio). Questo Mac è al livello %@."),
                          VoiceTraining.tierName(s.tier, lookup: lookup))
        }
        return lookup("Il motore della voce (VoxCPM2) non è installato su questo Mac: arriva con l'installazione del livello Medio di Regista.")
    }
}

/// Whether this Mac can train, in plain words.
enum VoiceTraining {
    static func tierName(_ tier: String, lookup: (String) -> String) -> String {
        switch tier {
        case "pro": lookup("Pro")
        case "medium": lookup("Medio")
        default: lookup("Base")
        }
    }

    /// nil when training can start for `language`; otherwise why not (the RAM, the install, or the minutes missing).
    static func blockReason(_ s: VoiceSnapshot, language: VoiceLanguageState, lookup: (String) -> String = { $0 }) -> String? {
        if !s.trainerAvailable {
            switch s.trainerReason {
            case "tier", nil:
                return String(format: lookup("L'allenamento richiede un Mac con almeno 32 GB di RAM (livello Pro); questo Mac è al livello %@. La voce funziona lo stesso dal riferimento."),
                              tierName(s.tier, lookup: lookup))
            default:
                return lookup("L'allenamento non è installato su questo Mac (manca il programma di training della voce).")
            }
        }
        if language.training.isRunning { return lookup("Un allenamento è già in corso") }
        if !language.consent { return lookup("Prima registra il blocco neutro, che inizia con la frase di consenso") }
        if language.missingSeconds > 0 {
            return String(format: lookup("Servono ancora %d secondi di registrazione utile (ne servono almeno %d)."),
                          Int(language.missingSeconds.rounded(.up)), Int(language.trainMinimumSeconds))
        }
        return nil
    }
}

/// What the main area of the "Gestisci voci" window shows for the language selected in its rail (V3). Computed from
/// voice.enroll.status and the window's own state, so it always opens where the entry point said.
enum VoiceWindowPage: String, CaseIterable {
    case profile, intro, consent, record, check, overview

    /// - profile: no profile yet (or one from another Mac) · check: a take was just checked (until the person moves on)
    ///   · overview: the language has a voice (its tones, its training) · record: a tone asked for from the overview, or
    ///   a language whose neutral block is missing once its consent was given or read · consent: the intro was passed ·
    ///   intro: a language without a voice, what will happen.
    static func compute(snapshot s: VoiceSnapshot, language: String?, started: Bool, consentRead: Bool, pendingTone: String?,
                        hasCheck: Bool) -> VoiceWindowPage {
        guard s.profile != nil, !s.profileLocked else { return .profile }
        let l = s.language(language)
        if hasCheck { return .check }
        if l?.hasVoice == true { return pendingTone == nil ? .overview : .record }
        if l?.consent == true || consentRead { return .record }
        return started ? .consent : .intro
    }

    /// The language to open the window on when no entry point names one: one in training, else the first with a voice,
    /// else the first one recorded.
    static func resumeLanguage(_ s: VoiceSnapshot) -> String? {
        s.languages.first { $0.training.isRunning }?.code ?? s.languages.first(where: \.hasVoice)?.code
            ?? s.languages.first { $0.consent || $0.seconds > 0 }?.code
    }

    /// "+ Lingua": the first language (in the rail's order) without a voice; nil when all four have one.
    static func firstWithoutVoice(_ s: VoiceSnapshot) -> String? {
        VoiceLanguages.all.first { s.language($0)?.hasVoice != true }
    }

    /// The tone the record page shows: the one asked for, else neutral.
    static func tone(pending: String?) -> String { pending ?? VoiceTone.neutral }
}

/// A language's state in the window's rail: always one of these four.
enum VoiceRailState: Equatable {
    case toRecord
    case ready(tones: Int)
    case trained(tones: Int)
    case training

    static func of(_ l: VoiceLanguageState?) -> VoiceRailState {
        guard let l else { return .toRecord }
        if l.training.isRunning { return .training }
        guard l.hasVoice else { return .toRecord }
        return l.trained ? .trained(tones: l.voiceTones.count) : .ready(tones: l.voiceTones.count)
    }

    func label(_ lookup: (String) -> String) -> String {
        switch self {
        case .toRecord: lookup("da registrare")
        case .training: lookup("allenamento in corso")
        case .ready(let n): n == 1 ? lookup("pronta · 1 tono") : String(format: lookup("pronta · %d toni"), n)
        case .trained(let n): n == 1 ? lookup("allenata · 1 tono") : String(format: lookup("allenata · %d toni"), n)
        }
    }
}

/// One tone tile of a language's overview: recorded (a check, and the minutes when the profile has them: never "0 min")
/// or still to record.
struct VoiceToneTile: Equatable {
    var tone: String
    var recorded: Bool
    var minutes: Double?

    static func tiles(_ l: VoiceLanguageState) -> [VoiceToneTile] {
        let have = Set(l.voiceTones)
        return VoiceTones.all.map { t in
            let m = l.recorded[t].flatMap { $0 > 0 ? $0 : nil }
            return VoiceToneTile(tone: t, recorded: have.contains(t) || m != nil, minutes: m)
        }
    }
}

/// How long each part of cloning takes, from the model: the loaded script's lines (the shipped scripts' lengths until
/// one is loaded), the language's own training estimate (RegistaCore's estimate for a neutral block until there is one)
/// and the tier the training needs (the engine manifest).
struct VoiceCloneTimes: Equatable {
    var neutralMinutes: Double
    var toneMinutes: Double
    var trainMinutes: Double
    var trainTier: MachineTier
    var trainRAM: Int

    /// The shipped scripts: a neutral block of about 10 minutes, about 2 minutes for each other tone (voice.enroll.script).
    static let scriptNeutralMinutes = 10.0, scriptToneMinutes = 2.0

    static func from(lines: [String: [String]], language: VoiceLanguageState?) -> VoiceCloneTimes {
        let neutral = lines[VoiceTone.neutral].map { RecordingScript.minutes(lines: $0) } ?? scriptNeutralMinutes
        let others = lines.filter { $0.key != VoiceTone.neutral }.values.map { RecordingScript.minutes(lines: $0) }
        let tone = others.isEmpty ? scriptToneMinutes : others.reduce(0, +) / Double(others.count)
        let train = language.flatMap { $0.seconds > 0 && $0.trainEstimateMinutes > 0 ? $0.trainEstimateMinutes : nil }
            ?? VoiceEnrollment.estimatedTrainingMinutes(seconds: neutral * 60)
        let tier = EngineManifest.shared.minimumTier("voice-training")
        return VoiceCloneTimes(neutralMinutes: neutral, toneMinutes: tone, trainMinutes: train, trainTier: tier,
                               trainRAM: Int(EngineManifest.shared.info(tier).ramGB))
    }
}

/// The panel's one hint about training: only for a usable, untrained voice on a Mac that can train, until dismissed for
/// that language.
enum VoiceTrainHint {
    static func key(profile: String?, language: String) -> String { (profile ?? "") + "/" + language }

    static func shows(_ s: VoiceSnapshot, language l: VoiceLanguageState?, dismissed: Set<String>) -> Bool {
        guard let l, l.ready, !l.trained, !l.training.isRunning, s.trainerAvailable else { return false }
        return !dismissed.contains(key(profile: s.profile, language: l.code))
    }
}

/// What voice.enroll.add said about a take, for the check step.
struct VoiceTakeCheck: Equatable {
    var tone: String
    var accepted = 0
    var total = 0
    var missing: [String] = []
    var consent = false
    var minutes = 0.0
    var reference = false
    /// The command refused the take (consent not heard, no speech…): the readable reason.
    var error: String?

    init(tone: String, result: JSONValue) {
        self.tone = tone
        accepted = Int(result["accepted"]?.doubleValue ?? 0)
        total = Int(result["total"]?.doubleValue ?? 0)
        missing = result["missing"]?.arrayValue?.compactMap(\.stringValue) ?? []
        consent = result["consent"]?.boolValue ?? false
        minutes = result["languageMinutes"]?.doubleValue ?? 0
        reference = result["reference"]?.stringValue != nil
    }

    init(tone: String, error: String) {
        self.tone = tone
        self.error = error
    }

    /// At least 70% of the lines heard (the command's own threshold).
    var good: Bool { error == nil && total > 0 && accepted * 10 >= total * 7 }
}
