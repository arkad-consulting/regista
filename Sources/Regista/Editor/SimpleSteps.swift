import Foundation
import RegistaCore

// E5 (#4): the Semplice level as six guided steps — Taglio e riprese, Sottotitoli, Aspetto, Musica e suoni, Voce,
// Grafica. Each step's state is computed from the project (and the engines this Mac has), so it is the same whatever
// did the work: the Simple controls, the Pro panels, "Fai tutto" or Claude. Every control runs ordinary commands
// through the tab's store (`SimpleCalls`: the same calls a test replays), one undo step each.

/// One guided step of the Semplice level, in the order they are offered.
enum SimpleStep: String, CaseIterable, Identifiable {
    case cut, captions, look, sound, voice, graphics
    var id: String { rawValue }

    func title(_ lookup: (String) -> String = loc) -> String {
        switch self {
        case .cut: lookup("Taglio e riprese")
        case .captions: lookup("Sottotitoli")
        case .look: lookup("Aspetto")
        case .sound: lookup("Musica e suoni")
        case .voice: lookup("Voce")
        case .graphics: lookup("Grafica")
        }
    }

    var symbol: String {
        switch self {
        case .cut: "scissors"
        case .captions: "captions.bubble"
        case .look: "camera.filters"
        case .sound: "music.note"
        case .voice: "waveform"
        case .graphics: "sparkles"
        }
    }

    /// The job kinds whose work belongs to this step (its own and the Pro steps it shares).
    var jobKinds: [String] {
        switch self {
        case .cut: ["simple.cut", TextStep.transcribe.jobKind, TextStep.faces.jobKind, TextStep.takes.jobKind, TextStep.cut.jobKind]
        case .captions: ["simple.captions", TextStep.captions.jobKind]
        case .look: []
        case .sound: [AudioCalls.musicJob]
        case .voice: [TextStep.clean.jobKind, "voice"]
        case .graphics: []
        }
    }

    /// The step a "Fai tutto" sub-step works on.
    static func of(_ step: TextStep) -> SimpleStep {
        switch step {
        case .transcribe, .faces, .script, .takes, .cut: .cut
        case .clean: .voice
        case .captions: .captions
        }
    }
}

/// What a step shows on the rail: its status and one line in words; when it cannot run, why and the way on.
struct SimpleState: Equatable {
    enum Status: String, Equatable { case todo, done, notNeeded, unavailable, running, blocked }
    var status: Status
    var line: String
    /// Blocked because there is nothing to work on: the offer is "Importa un video…".
    var needsImport = false
    /// Blocked until another step is done.
    var needs: SimpleStep? = nil
    /// Unavailable: the engine to install (its id in Impostazioni › Motori).
    var install: String? = nil
    /// The line is a warning (a head cut by the framing, #152).
    var warning = false

    var canAct: Bool { status != .blocked && status != .unavailable && status != .running }
}

/// The engines the steps need, nil when ready, else why not (a lookup key).
struct SimpleEngines: Equatable {
    var transcribe: String?
    var clean: String?

    static let ready = SimpleEngines(transcribe: nil, clean: nil)
    static let transcribeMissing = "Manca il motore che trascrive il parlato: si installa da Impostazioni › Motori."
    static let cleanMissing = "Manca il motore che pulisce la voce: si installa da Impostazioni › Motori."

    /// What this Mac can run: the default transcriber (the tier's, or whisper.cpp when that one is not installed, #112)
    /// and the voice cleaner.
    static func of(_ s: EngineServices) -> SimpleEngines {
        let engine = s.defaultTranscription().engine
        let transcriber = s.transcribers[engine]
        let canTranscribe = transcriber != nil && s.tier >= EngineServices.minimumTier(transcriber: engine) && transcriber?.unavailableReason() == nil
        return SimpleEngines(transcribe: canTranscribe ? nil : transcribeMissing, clean: s.cleaner.unavailableReason() == nil ? nil : cleanMissing)
    }
}

// MARK: - Presets

/// How tight the cut is: the pauses longer than `maxPause` go, `keepPause` of breath stays on each side.
enum CutPreset: String, CaseIterable, Identifiable {
    case natural, medium, tight
    var id: String { rawValue }
    var maxPause: Double { switch self { case .natural: 1.0; case .medium: 0.7; case .tight: 0.4 } }
    var keepPause: Double { switch self { case .natural: 0.2; case .medium: 0.12; case .tight: 0.06 } }
    var title: String { switch self { case .natural: "Naturale"; case .medium: "Medio"; case .tight: "Serrato" } }

    /// Pauses kept (the switch off): no pause inside a take is long enough to go.
    static let keepAll = 30.0

    static func matching(maxPause: Double, keepPause: Double) -> CutPreset? {
        allCases.first { abs($0.maxPause - maxPause) < 0.005 && abs($0.keepPause - keepPause) < 0.005 }
    }
}

/// The music's level before the ducking, LUFS (the bed under a −15 LUFS voice).
enum MusicLevel: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var lufs: Double { switch self { case .low: -28; case .medium: -22; case .high: -18 } }
    var title: String { switch self { case .low: "Bassa"; case .medium: "musicLevel.medium"; case .high: "Alta" } }   // "Media" is the Media activity

    static func nearest(_ lufs: Double) -> MusicLevel { allCases.min { abs($0.lufs - lufs) < abs($1.lufs - lufs) }! }
}

/// The looks offered in Semplice (Grafica › Filtri in Pro has them all) and how strong.
enum SimpleLooks {
    static let ids = ["none", "film", "golden", "airy", "vivid", "graphite"]
    static let amounts: [(id: Double, title: String)] = [(0.4, "Leggero"), (0.6, "Medio"), (0.85, "Forte")]

    static func title(_ id: String) -> String { id == "none" ? "Nessuno" : Look.named(id)?.label ?? id }

    static func nearestAmount(_ a: Double) -> Double { amounts.map(\.id).min { abs($0 - a) < abs($1 - a) }! }
}

/// The house light grade (recipe: brightness 0.02, contrast 1.06, saturation 1.08).
enum LightGrade {
    static let brightness = 0.02, contrast = 1.06, saturation = 1.08

    static func isOn(_ c: ColorAdjust?) -> Bool {
        guard let c else { return false }
        return abs(c.brightness - brightness) < 0.001 && abs(c.contrast - contrast) < 0.001 && abs(c.saturation - saturation) < 0.001
    }
}

/// The motion templates offered in Semplice (Grafica › Motion in Pro has them all).
enum SimpleGraphics {
    static let templates = ["kicker-headline", "checklist", "counter"]
}

// MARK: - The commands behind the controls

/// What each Simple control runs: the same calls whether the user clicks, "Fai tutto" runs, or a test replays them.
enum SimpleCalls {
    /// The first cut: the Pro steps it needs, as one job (those already done are skipped), with the preset's pauses.
    static let cutSteps: [TextStep] = [.transcribe, .takes, .cut]
    static func cutSettings(_ preset: CutPreset, pauses: Bool, base: StepSettings) -> StepSettings {
        var s = base
        s.minPause = pauses ? preset.maxPause : CutPreset.keepAll
        s.breath = preset.keepPause
        return s
    }
    /// Captions on: the transcription when it is missing, then the captions in `style` with the suggested keywords.
    static let captionSteps: [TextStep] = [.transcribe, .captions]
    static func captionSettings(style: String, base: StepSettings) -> StepSettings {
        var s = base
        s.style = style
        return s
    }

    static func cut(_ preset: CutPreset, pauses: Bool) -> StepCall {
        StepCall(id: "edit.autoCut", params: ["replace": true, "maxPause": .number(pauses ? preset.maxPause : CutPreset.keepAll),
                                              "keepPause": .number(preset.keepPause)])
    }
    /// Another take for a line, and the cut that uses it: one undo step.
    static func pick(line: Int, take: Int) -> StepCall {
        StepCall(id: "edit.autoCut", params: ["replace": true, "picks": [["line": .number(Double(line)), "take": .number(Double(take))]]])
    }
    static func captionsOff(trackID: String) -> StepCall { StepCall(id: "track.delete", params: ["trackId": .string(trackID), "force": true]) }
    static func captionStyle(_ style: String) -> StepCall { StepCall(id: "captions.setStyle", params: ["style": .string(style)]) }
    static func light(_ on: Bool, trackID: String) -> StepCall {
        StepCall(id: "clip.set", params: ["trackId": .string(trackID), "brightness": .number(on ? LightGrade.brightness : 0),
                                          "contrast": .number(on ? LightGrade.contrast : 1), "saturation": .number(on ? LightGrade.saturation : 1)])
    }
    static func look(_ id: String, amount: Double) -> StepCall {
        id == "none" ? StepCall(id: "look.apply", params: ["look": "none"])
            : StepCall(id: "look.apply", params: ["look": .string(id), "amount": .number(amount)])
    }
    /// The music's level: every clip of its track, from the loudness its file measures.
    static func musicLevel(_ level: MusicLevel, trackID: String, measured: Double) -> StepCall {
        AudioCalls.musicVolume(trackID: trackID, gain: min(max(level.lufs - measured, -60), 24))
    }
    static func removeMusic(_ track: Track) -> StepCall {
        StepCall(id: "timeline.delete", params: ["clipIds": .array(track.clips.map { .string($0.id) })])
    }
    static func soundEffects(_ on: Bool) -> StepCall { StepCall(id: "sfx.onCuts", params: on ? [:] : ["remove": true]) }
    static func clean(_ on: Bool) -> StepCall { on ? StepCalls.clean : StepCall(id: "audio.clean", params: ["restore": true]) }
    static func logo(_ p: LogoPlacement) -> StepCall {
        StepCall(id: "logo.add", params: ["replace": true, "corner": .string(p.corner), "width": .number(p.width),
                                          "opacity": .number(p.opacity ?? 1), "animation": .string(p.animation ?? "fade")])
    }
    static func removeClips(_ ids: [String]) -> StepCall { StepCall(id: "timeline.delete", params: ["clipIds": .array(ids.map { .string($0) })]) }

    /// What "Fai tutto" adds after the Pro steps: the light grade, when the picture has neither a look nor a grade yet.
    static func lookExtras(_ p: Project?) -> [StepCall] {
        guard let p, let track = SimpleSnapshot.mainVideo(p), !SimpleSnapshot.hasLook(p) else { return [] }
        return [light(true, trackID: track.id)]
    }

    /// The Pro steps "Fai tutto" runs here: the voice cleaning only when this Mac can clean.
    static func doEverythingSteps(hasScriptText: Bool, engines: SimpleEngines) -> [TextStep] {
        EditorStore.allSteps(hasScriptText: hasScriptText).filter { $0 != .clean || engines.clean == nil }
    }
}

// MARK: - The snapshot the views draw

/// A line read more than once: its takes, the one used.
struct Retake: Equatable, Identifiable {
    var line: Int
    var text: String
    var takes: Int
    var chosen: Int?
    var id: Int { line }
}

/// The music bed as the Sound step shows it.
struct SimpleMusic: Equatable {
    var trackID: String
    var name: String
    var ducking: Bool
    /// nil until the music file's loudness is known.
    var level: MusicLevel?
}

/// Everything the Semplice level draws, from the project (or sample data for a render: `SimpleDemo`).
struct SimpleSnapshot {
    var states: [SimpleStep: SimpleState]
    /// The newest job of each step (running, failed or done) and of "Fai tutto".
    var jobs: [SimpleStep: JobCenter.Job] = [:]
    var allJob: JobCenter.Job?
    var hasProject = false
    var engines = SimpleEngines.ready
    // Cut and takes
    var cutPreset: CutPreset? = .medium
    var pauses = true
    var retakes: [Retake] = []
    // Captions
    var captionsTrack: String?
    var captionStyle = CaptionStyle.talkingHeadV1.id
    var keywords = 0
    // Look
    var videoTrack: String?
    var light = false
    var look = "none"
    var lookAmount = 0.6
    // Music and sounds
    var music: SimpleMusic?
    var musicFiles: [MediaAsset] = []
    var effects = 0
    // Voice
    var cleaned = false
    var voiceOver: VoicePanelState?
    // Graphics
    var logoClips: [String] = []
    /// Why the logo cannot go in (a lookup key), nil when it can.
    var logoReason: String?
    var logoPlacement = LogoPlacement()
    /// The project's rules want the logo only at the end: the switch puts it in the closing seconds (#74).
    var logoAtEnd = false
    var graphics = 0
    var titleText = ""

    subscript(_ s: SimpleStep) -> SimpleState { states[s]! }

    /// The step job running in the tab (one at a time), if any.
    var busy: JobCenter.Job? { ([allJob] + jobs.values.map { Optional($0) }).compactMap { $0 }.first { $0.isRunning } }

    /// The step to do next: the first one still to do.
    var next: SimpleStep? { SimpleStep.allCases.first { self[$0].status == .todo } }

    /// "Fai tutto" can start: there is a clip with a voice and the speech can be (or was) transcribed.
    var canDoEverything: Bool { self[.cut].status != .blocked && self[.cut].status != .unavailable }

    static func mainVideo(_ p: Project) -> Track? { p.tracks.first { $0.kind == .video && !$0.clips.isEmpty } }

    static func hasLook(_ p: Project) -> Bool {
        p.grade?.look != nil || (mainVideo(p)?.clips.contains { LightGrade.isOn($0.color) } ?? false)
    }

    /// The snapshot of `p`: `running` steps from the tab's jobs, `musicLoudness` the measured level of music files by path.
    static func compute(_ p: Project?, engines: SimpleEngines, running: Set<SimpleStep> = [], musicLoudness: [String: Double] = [:],
                        voiceOver: VoicePanelState? = nil, framing: FramingCheck? = nil, lookup: (String) -> String = loc) -> SimpleSnapshot {
        let text = TextSteps.compute(p, framing: framing, lookup: lookup)
        var s = SimpleSnapshot(states: [:], hasProject: p != nil, engines: engines)
        s.voiceOver = voiceOver
        for step in SimpleStep.allCases {
            var st = state(step, p, text, engines, lookup)
            if running.contains(step) { st.status = .running }
            s.states[step] = st
        }
        guard let p else { return s }
        if let takes = p.takes {
            s.cutPreset = CutPreset.matching(maxPause: takes.options.maxPause, keepPause: takes.options.keepPause)
            s.pauses = takes.options.maxPause < CutPreset.keepAll - 0.5
            if !s.pauses { s.cutPreset = CutPreset.allCases.first { abs($0.keepPause - takes.options.keepPause) < 0.005 } }
            s.retakes = takes.lines.enumerated().compactMap { i, l in
                l.takes.count > 1 ? Retake(line: i + 1, text: l.text, takes: l.takes.count, chosen: l.chosen.map { $0 + 1 }) : nil
            }
        }
        if let track = p.tracks.first(where: { $0.kind == .caption && $0.captions != nil }), let c = track.captions {
            s.captionsTrack = track.id
            s.captionStyle = c.style.id
            s.keywords = c.keywords.count
        }
        let video = mainVideo(p)
        s.videoTrack = video?.id
        s.light = !(video?.clips.isEmpty ?? true) && video!.clips.allSatisfy { LightGrade.isOn($0.color) }
        s.look = p.grade?.look ?? "none"
        s.lookAmount = p.grade?.amount ?? 0.6
        if let m = AudioCalls.musicTrack(p), let asset = p.asset(m.clips[0].assetID) {
            let level = musicLoudness[asset.path].map { MusicLevel.nearest($0 + (m.clips[0].gain ?? 0)) }
            s.music = SimpleMusic(trackID: m.id, name: asset.name, ducking: m.ducking != nil, level: level)
        }
        s.musicFiles = AudioCalls.projectMusic(p)
        s.effects = p.tracks.filter { $0.role == "sfx" }.flatMap(\.clips).count
        s.cleaned = text[.clean].status == .done
        s.logoClips = p.tracks.filter { $0.role == "logo" }.flatMap(\.clips).map(\.id)
        s.logoReason = p.brand == nil ? "Scegli prima una marca (Marca, nella barra del montaggio)."
            : p.brand?.logoPath() == nil ? StepError.noLogoLine(p.brand?.name ?? "", lookup) : nil
        s.logoPlacement = p.brand?.logoPlacement ?? LogoPlacement()
        s.graphics = graphicClips(p)
        s.titleText = p.script?.lines.first.map(shortTitle) ?? ""
        return s
    }

    /// Titles, motion templates, stickers and the logo on the timeline.
    static func graphicClips(_ p: Project) -> Int {
        p.tracks.filter { $0.kind == .overlay }.flatMap(\.clips).filter { $0.isGenerated || $0.titlePreset != nil }.count
            + p.tracks.filter { $0.role == "logo" }.flatMap(\.clips).filter { !$0.isGenerated }.count
    }

    /// The first words of the first line, as an opening title (at most six words).
    static func shortTitle(_ line: String) -> String {
        let words = line.split(separator: " ")
        return words.prefix(6).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
    }

    private static func state(_ step: SimpleStep, _ p: Project?, _ text: TextSteps, _ engines: SimpleEngines,
                              _ lookup: (String) -> String) -> SimpleState {
        var s = baseState(step, p, text, engines, lookup)
        // A head cut by the framing (#152) shows on Taglio e riprese, the step «Fai tutto» finds the face in.
        if step == .cut, text[.faces].status == .stale, s.status != .running {
            s.line = text[.faces].line
            s.warning = true
        }
        return s
    }

    private static func baseState(_ step: SimpleStep, _ p: Project?, _ text: TextSteps, _ engines: SimpleEngines,
                                  _ lookup: (String) -> String) -> SimpleState {
        guard let p, let asset = TextSteps.mainAsset(p) else {
            return SimpleState(status: .blocked, line: text[.transcribe].line, needsImport: true)
        }
        let transcribed = asset.analysis?.transcript != nil
        let video = mainVideo(p)
        switch step {
        case .cut:
            let cut = text[.cut]
            if cut.status == .done { return SimpleState(status: .done, line: cut.line) }
            if !transcribed, let why = engines.transcribe {
                return SimpleState(status: .unavailable, line: lookup(why), install: WhisperCppTranscriber.engineID)
            }
            if cut.status == .stale { return SimpleState(status: .todo, line: cut.line) }
            return SimpleState(status: .todo, line: lookup("Toglie le pause e tiene la ripresa migliore di ogni frase."))
        case .captions:
            let c = text[.captions]
            switch c.status {
            case .done: return SimpleState(status: .done, line: c.line)
            case .stale: return SimpleState(status: .todo, line: c.line)
            default: break
            }
            if !transcribed, let why = engines.transcribe {
                return SimpleState(status: .unavailable, line: lookup(why), install: WhisperCppTranscriber.engineID)
            }
            if c.status == .blocked, c.needs == .cut { return SimpleState(status: .blocked, line: c.line, needs: .cut) }
            return SimpleState(status: .todo, line: lookup("Parola per parola, con le parole chiave evidenziate."))
        case .look:
            guard video != nil else { return SimpleState(status: .blocked, line: lookup("Prima metti il video in timeline: taglia le pause."), needs: .cut) }
            guard hasLook(p) else { return SimpleState(status: .todo, line: lookup("Una luce più viva e, se vuoi, un colore per tutto il video.")) }
            var parts: [String] = []
            if let l = p.grade?.look, let look = Look.named(l) { parts.append(lookup(look.label)) }
            if video?.clips.contains(where: { LightGrade.isOn($0.color) }) == true { parts.append(lookup("luce leggera")) }
            return SimpleState(status: .done, line: parts.joined(separator: " · "))
        case .sound:
            guard p.duration > .zero else { return SimpleState(status: .blocked, line: lookup("Prima metti il video in timeline: taglia le pause."), needs: .cut) }
            let music = AudioCalls.musicTrack(p) != nil
            let effects = p.tracks.filter { $0.role == "sfx" }.flatMap(\.clips).count
            guard music || effects > 0 else {
                return SimpleState(status: .notNeeded, line: lookup("Facoltativo: la musica di tendenza si aggiunge di solito su Instagram."))
            }
            var parts: [String] = []
            if music { parts.append(lookup("Musica sotto la voce")) }
            if effects > 0 { parts.append(Plural.text(effects, "1 effetto sonoro", "%d effetti sonori", lookup: lookup)) }
            return SimpleState(status: .done, line: parts.joined(separator: " · "))
        case .voice:
            let c = text[.clean]
            switch c.status {
            case .done: return SimpleState(status: .done, line: c.line)
            case .blocked: return SimpleState(status: .blocked, line: c.line, needs: c.needs == nil ? nil : .cut)
            default: break
            }
            if let why = engines.clean { return SimpleState(status: .unavailable, line: lookup(why), install: "deepfilternet") }
            return SimpleState(status: .todo, line: c.line)
        case .graphics:
            guard p.duration > .zero else { return SimpleState(status: .blocked, line: lookup("Prima metti il video in timeline: taglia le pause."), needs: .cut) }
            let n = graphicClips(p)
            guard n > 0 else { return SimpleState(status: .notNeeded, line: lookup("Facoltativo: un titolo, il logo o una scheda animata.")) }
            return SimpleState(status: .done, line: Plural.text(n, "1 grafica nel video", "%d grafiche nel video", lookup: lookup))
        }
    }
}

// MARK: - The store's side

extension EditorStore {
    /// The engines the steps need, from this tab's engine (file checks: cheap).
    var simpleEngines: SimpleEngines { SimpleEngines.of(engine.context.services) }

    /// The Semplice level as it is now: the project, the running jobs, the music's measured level, the voice-over state.
    var simpleSnapshot: SimpleSnapshot {
        var running = Set<SimpleStep>()
        var jobsByStep: [SimpleStep: JobCenter.Job] = [:]
        for step in SimpleStep.allCases {
            let latest = step.jobKinds.compactMap { jobs.latest($0) }.max { $0.started < $1.started }
            if let latest { jobsByStep[step] = latest; if latest.isRunning { running.insert(step) } }
        }
        let all = jobs.latest(TextStep.allJobKind)
        if let all, all.isRunning, all.steps.indices.contains(all.stepIndex) {
            let title = all.steps[all.stepIndex]
            if let t = TextStep.allCases.first(where: { $0.title() == title }) { running.insert(SimpleStep.of(t)) }
            else if title == SimpleStep.look.title() { running.insert(.look) }
        }
        var s = SimpleSnapshot.compute(project, engines: simpleEngines, running: running, musicLoudness: musicLoudness,
                                       voiceOver: voice.state, framing: framing)
        s.jobs = jobsByStep
        s.allJob = all
        s.logoAtEnd = project.map(engine.context.services.rules.logoOnlyAtEnd) ?? false
        return s
    }

    /// Runs one Simple control's command (instant, one undo step); its error shows in the window.
    func runSimple(_ call: StepCall) { run(call.id, call.params) }

    /// Taglio e riprese: the first time a job that transcribes, finds the takes and cuts with the preset (the steps
    /// already done are skipped); afterwards, the cut again with the new preset (one undo step). The choice is saved for
    /// the Pro steps too.
    func simpleCut(_ preset: CutPreset, pauses: Bool) {
        let d = UserDefaults.standard
        d.set(pauses ? preset.maxPause : CutPreset.keepAll, forKey: StepSettings.minPauseKey)
        d.set(preset.keepPause, forKey: StepSettings.breathKey)
        if TextSteps.compute(project)[.cut].status == .done || project?.takes != nil {
            return runSimple(SimpleCalls.cut(preset, pauses: pauses))
        }
        runSimpleSteps(SimpleCalls.cutSteps, kind: "simple.cut", title: SimpleStep.cut.title(),
                       settings: SimpleCalls.cutSettings(preset, pauses: pauses, base: StepSettings.saved(project: project)))
    }

    /// Sottotitoli on: a job that transcribes when needed, then makes the captions in the chosen style with the
    /// suggested keywords. Off: the caption track goes (one undo step).
    func simpleCaptions(on: Bool, style: String) {
        UserDefaults.standard.set(style, forKey: StepSettings.styleKey)
        if !on {
            if let id = simpleSnapshot.captionsTrack { runSimple(SimpleCalls.captionsOff(trackID: id)) }
            return
        }
        runSimpleSteps(SimpleCalls.captionSteps, kind: "simple.captions", title: SimpleStep.captions.title(),
                       settings: SimpleCalls.captionSettings(style: style, base: StepSettings.saved(project: project)))
    }

    /// A caption style: on the captions already made (one undo step), and the one the next captions get.
    func simpleCaptionStyle(_ style: String) {
        UserDefaults.standard.set(style, forKey: StepSettings.styleKey)
        if simpleSnapshot.captionsTrack != nil { runSimple(SimpleCalls.captionStyle(style)) }
    }

    /// Pulisci la voce on (the Pro step's job), off (the original sound back, one undo step).
    func simpleClean(_ on: Bool) {
        if on { runStep(.clean, settings: StepSettings.saved(project: project)) } else { runSimple(SimpleCalls.clean(false)) }
    }

    /// The music's level preset (measures the music file first when its level is not known yet).
    func simpleMusicLevel(_ level: MusicLevel) {
        guard let p = project, let m = AudioCalls.musicTrack(p), let asset = p.asset(m.clips[0].assetID) else { return }
        Task {
            guard let measured = await measureMusic(asset) else { return }
            runSimple(SimpleCalls.musicLevel(level, trackID: m.id, measured: measured))
        }
    }

    /// The loudness of a music file (media.measureLoudness, a query: stays out of the history), remembered by path.
    @discardableResult
    func measureMusic(_ asset: MediaAsset) async -> Double? {
        if let known = musicLoudness[asset.path] { return known }
        guard let r = try? await silent("media.measureLoudness", ["assetId": .string(asset.id)]),
              let v = r["integrated"]?.doubleValue, v.isFinite else { return nil }
        musicLoudness[asset.path] = v
        return v
    }

    /// Steps of the Pro rail as one job of the Semplice level (the steps already done are skipped).
    private func runSimpleSteps(_ steps: [TextStep], kind: String, title: String, settings: StepSettings) {
        guard runningStepJob == nil, jobs.jobs.allSatisfy({ !$0.isRunning || !$0.kind.hasPrefix("simple.") }), project != nil else { return }
        startJob(kind: kind, title: title) { [weak self] h, job in
            guard let self else { return }
            try await self.driver(h, job).runAll(steps, settings: settings, script: nil)
            h.update(detail: title)
        }
    }

    /// "Fai tutto" of the Semplice level: the Pro steps this Mac can run (the teleprompter's text as the script), then
    /// the light grade; the steps already done are skipped, so a second run adds nothing.
    func doEverything(script: String?) {
        let text = project?.script == nil ? script?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let steps = SimpleCalls.doEverythingSteps(hasScriptText: !(text ?? "").isEmpty, engines: simpleEngines)
        runAll(settings: StepSettings.saved(project: project), script: script, steps: steps, extras: { SimpleCalls.lookExtras($0) },
               extrasTitle: SimpleStep.look.title())
    }
}
