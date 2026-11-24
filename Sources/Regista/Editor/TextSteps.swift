import Foundation
import RegistaCore

// E2 (#54): the path from an imported clip to captions, by hand. Each step runs existing commands as a job of the tab;
// its state (to do / done / out of date / blocked with the reason and the missing step) is computed from the project,
// so it is the same whether the user, "Fai tutto" or Claude did the work.

/// One step of Testi e sottotitoli (and Pulisci la voce, also in the Audio panel), in the order they run.
enum TextStep: String, CaseIterable, Identifiable {
    case transcribe, faces, script, takes, cut, clean, captions
    var id: String { rawValue }

    /// The job kind of the step (the panels find their job by it).
    var jobKind: String { "step." + rawValue }
    static let allJobKind = "step.all"

    func title(_ lookup: (String) -> String = loc) -> String {
        switch self {
        case .transcribe: lookup("Trascrivi")
        case .faces: lookup("Trova il volto")
        case .script: lookup("Copione")
        case .takes: lookup("Scegli le riprese")
        case .cut: lookup("Taglia le pause")
        case .clean: lookup("Pulisci la voce")
        case .captions: lookup("Sottotitoli")
        }
    }

    var symbol: String {
        switch self {
        case .transcribe: "waveform.and.mic"
        case .faces: "person.crop.rectangle"
        case .script: "doc.text"
        case .takes: "list.number"
        case .cut: "scissors"
        case .clean: "waveform.badge.magnifyingglass"
        case .captions: "captions.bubble"
        }
    }

    /// The copione is optional: without one the lines come from the speech.
    var optional: Bool { self == .script }
}

/// What a step shows: its status, one line in words, and when it cannot run, what is missing.
struct StepState: Equatable {
    /// notNeeded: nothing to do here (a clip without a face for «Trova il volto»), said with the reason.
    enum Status: String, Equatable { case todo, done, stale, running, blocked, notNeeded }
    var status: Status
    var line: String
    /// The step to do first (blocked).
    var needs: TextStep? = nil
    /// Blocked because there is nothing to work on: the offer is "Importa un video…".
    var needsImport = false

    var canRun: Bool { status != .blocked && status != .running }
    /// Done, or nothing to do: «Fai tutto» goes on.
    var settled: Bool { status == .done || status == .notNeeded }
}

/// The last framing check of the edit (#152): faces.checkFraming at the end of «Fai tutto» and after its fix. It holds
/// while the picture's clips and crops stay as they were checked; any change to them leaves it behind.
struct FramingCheck: Equatable {
    var signature: Int
    /// Timeline time of the first frame that cuts a head, nil when every head is in frame.
    var firstCut: Double?

    /// The output size and every clip of the video tracks (source range, crop, keyframes): what a framing depends on.
    static func signature(_ p: Project) -> Int {
        var h = Hasher()
        h.combine(p.settings.width)
        h.combine(p.settings.height)
        for t in p.tracks where t.kind == .video { h.combine(t.clips) }
        return h.finalize()
    }

    /// The check's result on `p`: the time of its first cut head.
    init(_ p: Project, result: JSONValue) {
        signature = Self.signature(p)
        firstCut = result["pass"]?.boolValue == false ? result["cuts"]?.arrayValue?.first?["time"]?.doubleValue ?? 0 : nil
    }

    /// The edit has a picture with a face to check: a clip of a video track whose asset has a face track with faces.
    static func applies(_ p: Project) -> Bool {
        p.tracks.contains { t in
            t.kind == .video && t.clips.contains { (p.asset($0.assetID)?.analysis?.faces?.detected ?? 0) > 0 }
        }
    }
}

/// The settings people understand, kept between launches (UserDefaults keys `steps.*`).
struct StepSettings: Equatable {
    /// "it", "fr", "en", "pt" or "auto".
    var language: String
    /// Pauses longer than this are cut out, seconds (edit.autoCut maxPause); the default pace's.
    var minPause = SimplePace.pauses(SimplePace.spec.defaultOption).maxPause
    /// Breath kept before and after a removed pause, seconds (edit.autoCut keepPause); the default pace's.
    var breath = SimplePace.pauses(SimplePace.spec.defaultOption).keepPause
    /// The caption style; the caption style choice's default.
    var style = RuleChoiceSpec.named("captions")!.defaultOption
    /// The keywords the user accepted (nil: the suggestions are taken as they are).
    var keywords: [String]? = nil

    static let languages = ["it", "fr", "en", "pt", "auto"]
    static let languageKey = "steps.language", minPauseKey = "steps.minPause", breathKey = "steps.breath", styleKey = "steps.style"

    /// The app's language when it is one the engines speak, else Italian.
    static var appLanguage: String {
        let code = String((Locale.preferredLanguages.first ?? "it").prefix(2))
        return languages.contains(code) ? code : "it"
    }

    /// The Pro steps' settings: the language defaults to the project's (a transcript already made), then the app's; the
    /// pauses and the caption style are the person's own (the Pro step's sliders and chips), else the project's choices.
    static func saved(_ d: UserDefaults = .standard, project: Project? = nil, choices: ProjectChoices? = nil) -> StepSettings {
        var s = regia(choices ?? ProjectChoices(project, book: nil), project: project, d)
        if d.object(forKey: minPauseKey) != nil { s.minPause = d.double(forKey: minPauseKey) }
        if d.object(forKey: breathKey) != nil { s.breath = d.double(forKey: breathKey) }
        if let st = d.string(forKey: styleKey), CaptionStyle.presets[st] != nil { s.style = st }
        return s
    }

    /// What the Simple steps and «Fai tutto» run with: the language as saved (else the project's, then the app's), the
    /// pauses of the project's pace and its caption style (none: the default style, for captions made on request).
    static func regia(_ choices: ProjectChoices, project: Project?, _ d: UserDefaults = .standard) -> StepSettings {
        let projectLanguage = project?.assets.compactMap { $0.analysis?.transcript?.language }.first { languages.contains($0) }
        var s = StepSettings(language: d.string(forKey: languageKey) ?? projectLanguage ?? appLanguage)
        (s.minPause, s.breath) = choices.pace
        if CaptionStyle.presets[choices.value("captions")] != nil { s.style = choices.value("captions") }
        return s
    }

    static func languageName(_ code: String, _ lookup: (String) -> String = loc) -> String {
        switch code {
        case "it": "Italiano"
        case "fr": "Français"
        case "en": "English"
        case "pt": "Português"
        default: lookup("Automatica")
        }
    }
}

/// One command a step button runs.
struct StepCall: Equatable {
    let id: String
    let params: JSONValue
}

/// The commands behind each button: the same calls whether the user clicks, "Fai tutto" runs, or a test replays them.
enum StepCalls {
    static func extractAudio(_ asset: String) -> StepCall { .init(id: "media.extractAudio", params: ["assetId": .string(asset)]) }
    static func transcribe(_ asset: String, language: String) -> StepCall {
        .init(id: "transcript.run", params: ["assetId": .string(asset), "language": .string(language)])
    }
    static func scriptText(_ text: String) -> StepCall { .init(id: "script.set", params: ["text": .string(text)]) }
    static func scriptFile(_ path: String) -> StepCall { .init(id: "script.set", params: ["path": .string(path)]) }
    static func scriptFromSpeech(_ asset: String) -> StepCall { .init(id: "script.fromTranscript", params: ["assetId": .string(asset)]) }
    static func takes(_ asset: String) -> StepCall { .init(id: "takes.list", params: ["assetId": .string(asset)]) }
    static func select(line: Int, take: Int) -> StepCall {
        .init(id: "takes.select", params: ["line": .number(Double(line)), "take": .number(Double(take))])
    }
    static func cut(minPause: Double, breath: Double) -> StepCall {
        .init(id: "edit.autoCut", params: ["replace": true, "maxPause": .number(round2(minPause)), "keepPause": .number(round2(breath))])
    }
    static let clean = StepCall(id: "audio.clean", params: ["target": -15])
    static func faces(_ asset: String) -> StepCall { .init(id: "faces.track", params: ["assetId": .string(asset)]) }
    static let checkFraming = StepCall(id: "faces.checkFraming", params: [:])
    /// The fix of a failing check: the camera clips framed on the face again, at the project's own size (project.format).
    static func reframe(_ p: Project) -> StepCall {
        .init(id: "project.format", params: ["width": .number(Double(p.settings.width)), "height": .number(Double(p.settings.height))])
    }
    static func suggestKeywords(style: String) -> StepCall {
        .init(id: "captions.generate", params: ["style": .string(style), "dryRun": true])
    }
    static func captions(style: String, keywords: [String]) -> StepCall {
        .init(id: "captions.generate", params: ["style": .string(style), "keywords": .array(keywords.map { .string($0) })])
    }

    /// What a step's button runs on `project`, in order (a step of several commands shows them as one job).
    static func plan(_ step: TextStep, project: Project, settings: StepSettings, keywords: [String]) -> [StepCall] {
        guard let asset = TextSteps.mainAsset(project) else { return [] }
        switch step {
        case .transcribe:
            return (asset.analysis?.audio == nil ? [extractAudio(asset.id)] : []) + [transcribe(asset.id, language: settings.language)]
        case .faces: return asset.video == nil ? [] : [faces(asset.id)]
        case .script: return [scriptFromSpeech(asset.id)]
        case .takes: return (project.script == nil ? [scriptFromSpeech(asset.id)] : []) + [takes(asset.id)]
        case .cut: return [cut(minPause: settings.minPause, breath: settings.breath)]
        case .clean: return [clean]
        case .captions: return [captions(style: settings.style, keywords: keywords)]
        }
    }

    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

/// The state of every step, computed from the project (and the steps running now).
struct TextSteps: Equatable {
    var states: [TextStep: StepState]

    subscript(_ s: TextStep) -> StepState { states[s]! }

    /// The clip the steps work on: the first imported (not generated) asset with sound, a video first.
    static func mainAsset(_ p: Project?) -> MediaAsset? {
        let sources = p?.assets.filter { $0.origin == nil && $0.generated == nil && $0.audio != nil } ?? []
        return sources.first { $0.video != nil } ?? sources.first
    }

    /// The first step to do (to do or out of date, and runnable), the copione aside: the panel opens it.
    var next: TextStep? {
        TextStep.allCases.first { !$0.optional && (self[$0].status == .todo || self[$0].status == .stale) }
    }

    /// `framing`: the last framing check (a failing one, still about this edit, puts «Trova il volto» out of date).
    static func compute(_ p: Project?, running: Set<TextStep> = [], framing: FramingCheck? = nil, lookup: (String) -> String = loc) -> TextSteps {
        var out: [TextStep: StepState] = [:]
        for step in TextStep.allCases {
            var s = state(step, p, framing, lookup)
            if running.contains(step) { s.status = .running }
            out[step] = s
        }
        return TextSteps(states: out)
    }

    private static func state(_ step: TextStep, _ p: Project?, _ framing: FramingCheck?, _ lookup: (String) -> String) -> StepState {
        guard let p else { return StepState(status: .blocked, line: lookup("Apri un progetto o importa un video per cominciare."), needsImport: true) }
        guard let asset = mainAsset(p) else {
            return StepState(status: .blocked, line: lookup("Importa un video con la voce di chi parla."), needsImport: true)
        }
        let transcript = asset.analysis?.transcript
        let noTranscript = StepState(status: .blocked, line: lookup("Prima serve la trascrizione."), needs: .transcribe)
        switch step {
        case .transcribe:
            guard let t = transcript else { return StepState(status: .todo, line: lookup("Il parlato diventa testo, con il tempo di ogni parola.")) }
            return StepState(status: .done, line: String(format: lookup("%d parole · %@"), t.words.count, StepSettings.languageName(t.language, lookup)))
        case .faces:
            // #152: the face found once, so the captions keep clear of it; skipped with its reason when there is none.
            guard asset.video != nil else { return StepState(status: .notNeeded, line: lookup("Solo audio: nessun volto da cercare.")) }
            guard let f = asset.analysis?.faces else {
                return StepState(status: .todo, line: lookup("Trova il volto in ogni fotogramma: i sottotitoli e le inquadrature lo lasciano libero."))
            }
            guard f.detected > 0 else { return StepState(status: .notNeeded, line: lookup("Nessun volto nel video: l'inquadratura resta al centro.")) }
            if let framing, let cut = framing.firstCut, framing.signature == FramingCheck.signature(p) {
                return StepState(status: .stale, line: String(format: lookup("Una testa è tagliata a %@: rifai l'inquadratura sul volto."), clockTime(cut)))
            }
            return StepState(status: .done, line: String(format: lookup("Volto trovato in %@ fotogrammi su %@"), "\(f.detected)", "\(f.frames)"))
        case .script:
            if let s = p.script { return StepState(status: .done, line: String(format: lookup("%d righe"), s.lines.count)) }
            return StepState(status: .todo, line: lookup("Facoltativo: senza copione le righe vengono dal parlato."))
        case .takes:
            guard transcript != nil || asset.analysis?.liveTakes != nil else { return noTranscript }
            if let t = p.takes {
                return StepState(status: .done, line: String(format: lookup("%d righe su %d con una ripresa scelta"), t.lines.filter { $0.chosen != nil }.count, t.lines.count))
            }
            return StepState(status: .todo, line: p.script == nil ? lookup("Senza copione, le righe vengono dal parlato.")
                                                                  : lookup("Trova ogni lettura delle righe e sceglie la migliore."))
        case .cut:
            guard transcript != nil || asset.analysis?.liveTakes != nil else { return noTranscript }
            guard let takes = p.takes else { return StepState(status: .blocked, line: lookup("Prima scegli le riprese."), needs: .takes) }
            switch cutState(p, takes) {
            case .none: return StepState(status: .todo, line: lookup("Toglie le pause lunghe e tiene le riprese scelte."))
            case .matches(let n):
                return StepState(status: .done, line: String(format: lookup("%d tagli · %@ di montaggio"), n, clockTime(p.duration.seconds)))
            case .differs: return StepState(status: .stale, line: lookup("La timeline non segue più le riprese scelte: rifai il taglio."))
            }
        case .clean:
            guard let track = p.tracks.first(where: { $0.kind == .audio }), !track.clips.isEmpty else {
                return StepState(status: .blocked, line: lookup("Prima metti il video in timeline: taglia le pause."), needs: .cut)
            }
            let sources = Set(track.clips.map { p.asset($0.assetID)?.origin?.assetID ?? $0.assetID })
            guard sources.count == 1, let source = sources.first else {
                return StepState(status: .blocked, line: lookup("La prima pista audio mescola più file: la voce si pulisce da un file solo."))
            }
            let cleaned = track.clips.allSatisfy { p.asset($0.assetID)?.origin?.process == "audio.clean" }
            if cleaned { return StepState(status: .done, line: lookup("Voce pulita, a −15 LUFS.")) }
            if p.assets.contains(where: { $0.origin?.assetID == source && $0.origin?.process == "audio.clean" }) {
                return StepState(status: .stale, line: lookup("Il taglio è cambiato: la voce va ripulita."))
            }
            return StepState(status: .todo, line: lookup("Toglie il rumore e porta la voce a −15 LUFS."))
        case .captions:
            guard transcript != nil else { return noTranscript }
            guard let source = TimelineTranscript.defaultTrack(in: p), !TimelineTranscript.words(of: source, in: p).isEmpty else {
                return StepState(status: .blocked, line: lookup("Prima metti il video in timeline: taglia le pause."), needs: .cut)
            }
            guard let track = p.tracks.first(where: { $0.kind == .caption && $0.captions != nil }), let c = track.captions else {
                return StepState(status: .todo, line: lookup("Parola per parola, con le parole chiave evidenziate."))
            }
            if let src = p.tracks.first(where: { $0.id == c.sourceTrack }), RegistaCore.Captions.signature(of: src) != c.sourceSignature {
                return StepState(status: .stale, line: lookup("Il montaggio è cambiato: rigenera i sottotitoli."))
            }
            return StepState(status: .done, line: CommandLines.count(c.chunks.count, "1 blocco", "%@ blocchi") + " · "
                             + CommandLines.count(c.keywords.count, "1 parola chiave", "%@ parole chiave"))
        }
    }

    enum CutMatch: Equatable { case none, matches(Int), differs }

    /// Whether the first video track holds the cut of the chosen takes: nothing cut yet (empty, or the whole clip as
    /// imported), exactly the chosen ranges (within a frame), or something else (a pick changed after the cut).
    static func cutState(_ p: Project, _ takes: TakeSet) -> CutMatch {
        guard let asset = p.asset(takes.assetID), let track = p.tracks.first(where: { $0.kind == .video }) else { return .none }
        let clips = track.clips.filter { $0.assetID == asset.id }
        let whole = clips.count == 1 && clips[0].sourceIn == .zero && clips[0].sourceOut >= asset.duration - MediaTime(seconds: 0.05)
        if clips.isEmpty || whole { return .none }
        let rate = asset.video?.frameRate ?? p.settings.frameRate
        let frame = 1.01 / rate.doubleValue
        let expected = takes.segments().compactMap { seg -> (Double, Double)? in
            let a = seg.range.start.snapped(to: rate), b = min(seg.range.end.snapped(to: rate), asset.duration)
            return b > a ? (a.seconds, b.seconds) : nil
        }
        let actual = clips.map { ($0.sourceIn.seconds, $0.sourceOut.seconds) }
        guard expected.count == actual.count,
              zip(expected, actual).allSatisfy({ abs($0.0 - $1.0) <= frame && abs($0.1 - $1.1) <= frame }) else { return .differs }
        return .matches(actual.count)
    }
}
