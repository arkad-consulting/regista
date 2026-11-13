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

/// The recording flow's steps (V1). It always reopens on the right one, computed from voice.enroll.status.
enum VoiceSetupStep: String, CaseIterable {
    case profile, language, consent, record, check, overview, training

    /// - profile: no profile yet · language: none chosen · training: one runs for the language · check: a take was
    ///   just checked (until the person moves on) · consent: the language has no consent and the person has not read
    ///   the consent page in this session · record: the neutral block is missing, or another tone was asked for ·
    ///   overview: the voice is usable (more tones, training).
    static func compute(snapshot s: VoiceSnapshot, language: String?, consentRead: Bool, pendingTone: String?, hasCheck: Bool) -> VoiceSetupStep {
        guard s.profile != nil, !s.profileLocked else { return .profile }
        guard let language else { return .language }
        let l = s.language(language)
        if l?.training.isRunning == true { return .training }
        if hasCheck { return .check }
        if l?.consent != true { return consentRead ? .record : .consent }
        if pendingTone != nil { return .record }
        if l?.zeroShotReady != true { return .record }
        return .overview
    }

    /// The language to reopen the flow on: one in training, else the first one recorded.
    static func resumeLanguage(_ s: VoiceSnapshot) -> String? {
        s.languages.first { $0.training.isRunning }?.code ?? s.languages.first { $0.consent || $0.seconds > 0 }?.code
    }

    /// The tone the record step shows: the one asked for, else neutral.
    static func tone(pending: String?) -> String { pending ?? VoiceTone.neutral }
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
