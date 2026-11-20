import AVFoundation
import AppKit
import RegistaCore

/// One command call (id + params): what a control of the Voce panel or the recording flow runs. Built here, pure, so a
/// test can replay exactly the calls the UI makes.
struct VoiceCall: Equatable {
    var id: String
    var params: JSONValue
}

enum VoiceCalls {
    enum Placement: String, CaseIterable { case playhead, afterVoice }

    static let profile = VoiceCall(id: "profile.get", params: [:])
    static let list = VoiceCall(id: "voice.list", params: [:])
    static let status = VoiceCall(id: "voice.enroll.status", params: [:])
    static func createProfile(_ name: String) -> VoiceCall { .init(id: "profile.create", params: ["name": .string(name.trimmingCharacters(in: .whitespaces))]) }
    static func script(_ language: String) -> VoiceCall { .init(id: "voice.enroll.script", params: ["language": .string(language)]) }
    static func addTake(_ path: String, language: String, tone: String) -> VoiceCall {
        .init(id: "voice.enroll.add", params: ["path": .string(path), "language": .string(language), "tone": .string(tone)])
    }
    static func train(_ language: String) -> VoiceCall { .init(id: "voice.enroll.train", params: ["language": .string(language)]) }

    /// Ascolta: one paragraph (or the selected words) rendered without touching the edit.
    static func preview(_ text: String, language: String, tone: String, paragraph: Int? = nil, estimate: Bool = false) -> VoiceCall {
        var o: [String: JSONValue] = ["text": .string(text), "language": .string(language)]
        if tone != VoiceTone.neutral { o["tone"] = .string(tone) }
        if let paragraph { o["paragraph"] = .number(Double(paragraph)) }
        if estimate { o["estimate"] = true }
        return .init(id: "voice.preview", params: .object(o))
    }

    /// Metti in timeline: at the playhead, or after the last voice clip (voice.say's default). `replace`: the clips this
    /// panel placed for its text before, one per paragraph (#100): «Dopo l'ultima voce» places the text again over them
    /// (a changed paragraph replaces its clip in place, the others stay); «Al cursore» always places a new copy.
    static func say(_ text: String, language: String, tone: String, placement: Placement, playhead: Double, replace: [String]? = nil) -> VoiceCall {
        var o: [String: JSONValue] = ["text": .string(text), "language": .string(language)]
        if tone != VoiceTone.neutral { o["tone"] = .string(tone) }
        if placement == .playhead { o["at"] = .number(playhead) }
        else if let replace, !replace.isEmpty { o["replace"] = .array(replace.map { .string($0) }) }
        return .init(id: "voice.say", params: .object(o))
    }

    /// What placing the text again did (#100), in words: «1 paragrafo rifatto, 1 invariato».
    static func replaced(_ r: JSONValue) -> String {
        func n(_ key: String) -> Int { Int(r[key]?.doubleValue ?? 0) }
        let remade = n("remade"), added = n("added"), removed = n("removed"), kept = n("unchanged")
        var parts = [remade == 0 ? loc("Nessun paragrafo rifatto") : Plural.text(remade, "1 paragrafo rifatto", "%d paragrafi rifatti")]
        if added > 0 { parts.append(Plural.text(added, "1 aggiunto", "%d aggiunti")) }
        if removed > 0 { parts.append(Plural.text(removed, "1 tolto", "%d tolti")) }
        if kept > 0 { parts.append(Plural.text(kept, "1 invariato", "%d invariati")) }
        return parts.joined(separator: ", ")
    }

    static func captions(trackId: String) -> VoiceCall { .init(id: "captions.generate", params: ["sourceTrackId": .string(trackId)]) }
    static func lexicon(_ language: String) -> VoiceCall { .init(id: "voice.lexicon", params: ["language": .string(language)]) }
    static func lexiconAdd(_ language: String, word: String, say: String, confirmed: Bool) -> VoiceCall {
        .init(id: "voice.lexicon", params: ["language": .string(language), "add": ["word": .string(word), "say": .string(say)],
                                            "status": .string(confirmed ? "confirmed" : "pending")])
    }
    static func lexiconRemove(_ language: String, word: String) -> VoiceCall {
        .init(id: "voice.lexicon", params: ["language": .string(language), "remove": .string(word)])
    }

    /// What Ascolta says: the selected words when there are some, else the paragraph the cursor is in (blank lines
    /// separate paragraphs, as voice.say splits them). nil when there is nothing to say there.
    static func listenText(_ text: String, selection: Range<String.Index>?) -> String? {
        if let r = selection, !r.isEmpty {
            let s = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        let cursor = selection?.lowerBound ?? text.startIndex
        var start = text.startIndex, found: String?
        for block in text.components(separatedBy: "\n\n") {
            let end = text.index(start, offsetBy: block.count)
            if cursor >= start, cursor <= end { found = block; break }
            start = text.index(end, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
        }
        let p = (found ?? text.components(separatedBy: "\n\n").first ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return p.isEmpty ? nil : p
    }
}

/// The voice features' live state and actions (V1 #61, V2 #62), owned by the store. Every action is a command
/// (logged, as the MCP tool); reads go through the silent path. A demo model (ui.screenshot) is filled from a value
/// and never calls anything.
@MainActor
final class VoiceModel: ObservableObject {
    struct LexiconEntry: Equatable, Identifiable {
        var word: String
        var say: String
        var pending: Bool
        var id: String { word }
    }

    struct Placed: Equatable {
        var trackId: String
        var clipIds: [String]
        var seconds: Double
        var text: String
        var captioned = false
    }

    /// The "Gestisci voci" window's own state (its page is computed: VoiceWindowPage.compute).
    struct Setup: Equatable {
        /// The language selected in the rail.
        var language: String?
        /// The intro of a language without a voice was passed (on to consent).
        var started = false
        var consentRead = false
        var pendingTone: String?
        var check: VoiceTakeCheck?
        /// The script of the language: consent (with the name) and lines per tone.
        var consent = ""
        var lines: [String: [String]] = [:]
        var recording = false
    }

    weak var store: EditorStore?
    let demo: Bool
    @Published var snapshot = VoiceSnapshot()
    @Published var loadError: String?

    // Composer
    @Published var text = ""
    @Published var language: String?
    @Published var tone = VoiceTone.neutral
    @Published var placement = VoiceCalls.Placement.afterVoice
    @Published var placed: Placed?
    @Published var playing = false
    @Published var pane = Pane.text
    enum Pane: Hashable { case text, lexicon }

    // Lexicon
    @Published var lexicon: [LexiconEntry] = []
    @Published var lexiconLanguage: String?

    // The "Gestisci voci" window
    @Published var setup = Setup()
    /// Languages whose training hint was dismissed (VoiceTrainHint.key), kept in `defaults` when there is one.
    @Published private(set) var dismissedHints: Set<String> = []
    private let defaults: UserDefaults?
    private static let hintsKey = "voice.trainHintDismissed"

    /// Jobs of a demo render (the live model uses the store's).
    let demoJobs: JobCenter?
    private var player: AVAudioPlayer?
    private var queue: [URL] = []
    private var savedSources: RecordingSources?

    init(store: EditorStore?, demo: Bool = false, jobs: JobCenter? = nil, defaults: UserDefaults? = nil) {
        self.store = store
        self.demo = demo
        self.demoJobs = jobs
        self.defaults = defaults
        dismissedHints = Set(defaults?.stringArray(forKey: Self.hintsKey) ?? [])
    }

    var jobs: JobCenter? { demoJobs ?? store?.jobs }
    var state: VoicePanelState { VoicePanelState.from(snapshot, lookup: loc) }

    /// The composer's language: the chosen one while the voice speaks it, else the first ready one.
    var activeLanguage: VoiceLanguageState? {
        snapshot.readyLanguages.first { $0.code == language } ?? snapshot.readyLanguages.first
    }

    var activeTone: String {
        let tones = activeLanguage?.tones ?? [VoiceTone.neutral]
        return tones.contains(tone) ? tone : VoiceTone.neutral
    }

    /// The language the window shows: the one selected, else where the voice stands, else the app's language.
    var windowLanguage: String { setup.language ?? VoiceWindowPage.resumeLanguage(snapshot) ?? VoiceLanguages.preferred }

    var windowPage: VoiceWindowPage {
        VoiceWindowPage.compute(snapshot: snapshot, language: windowLanguage, started: setup.started, consentRead: setup.consentRead,
                                pendingTone: setup.pendingTone, hasCheck: setup.check != nil)
    }

    /// How long cloning takes, for the panel's steps, the intro and the tiles.
    var cloneTimes: VoiceCloneTimes { VoiceCloneTimes.from(lines: setup.lines, language: snapshot.language(windowLanguage)) }

    /// The panel's training hint for the composer's language.
    var showsTrainHint: Bool { VoiceTrainHint.shows(snapshot, language: activeLanguage, dismissed: dismissedHints) }

    func dismissTrainHint() {
        guard let l = activeLanguage?.code else { return }
        dismissedHints.insert(VoiceTrainHint.key(profile: snapshot.profile, language: l))
        defaults?.set(dismissedHints.sorted(), forKey: Self.hintsKey)
    }

    // MARK: Loading

    func refresh() async {
        guard !demo, let store else { return }
        do {
            let list = try await store.silent(VoiceCalls.list.id)
            var status: JSONValue?
            if list["profile"]?.objectValue != nil, list.value(at: "profile.locked") == nil {
                status = try? await store.silent(VoiceCalls.status.id)
            }
            snapshot = VoiceSnapshot(list: list, status: status)
            loadError = nil
        } catch {
            loadError = JobCenter.message(error)
        }
        if setup.language == nil { setup.language = VoiceWindowPage.resumeLanguage(snapshot) }
        if let l = activeLanguage?.code, lexiconLanguage != l { await loadLexicon(l) }
        watchTraining()
    }

    func loadLexicon(_ language: String) async {
        guard !demo, let store else { return }
        let c = VoiceCalls.lexicon(language)
        guard let r = try? await store.silent(c.id, c.params) else { return }
        lexiconLanguage = language
        lexicon = (r["entries"]?.arrayValue ?? []).compactMap { e in
            guard let w = e["word"]?.stringValue, let s = e["say"]?.stringValue else { return nil }
            return LexiconEntry(word: w, say: s, pending: e["status"]?.stringValue == "pending")
        }
    }

    // MARK: Profile

    func createProfile(_ name: String) {
        guard !demo, let store, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            let c = VoiceCalls.createProfile(name)
            do { try await store.perform(c.id, c.params) } catch { store.errorMessage = VoiceErrors.readable(error) }
            await refresh()
            await loadScript()
        }
    }

    // MARK: Composer

    var paragraphs: [String] { VoiceScript.paragraphs(text) }
    var estimatedSeconds: Double { VoiceScript.estimatedSeconds(paragraphs.joined(separator: " ")) }

    /// Ascolta: renders what `selection` points at (no change to the edit) and plays it.
    func listen(selection: Range<String.Index>?) {
        guard !demo, let store, let jobs, let lang = activeLanguage?.code,
              let say = VoiceCalls.listenText(text, selection: selection) else { return }
        stopPlayback()
        let tone = activeTone
        let estimate = VoiceScript.estimatedRenderSeconds(speech: VoiceScript.estimatedSeconds(say), paragraphs: 1)
        jobs.start(kind: "voice", title: loc("Ascolto della voce"), onCancel: { [weak store] in store?.cancelAside() }) { [weak self] h in
            h.update(progress: 0, detail: loc("Carico il modello della voce…"))
            let c = VoiceCalls.preview(say, language: lang, tone: tone)
            let r = try await self?.timed(h, from: 0, to: 1, seconds: estimate) { try await Self.inWords { try await store.aside(c.id, c.params) } }
            let files = (r?["paragraphs"]?.arrayValue ?? []).compactMap { $0["file"]?.stringValue }.map { URL(fileURLWithPath: $0) }
            h.update(progress: 1, detail: loc("Pronta: la ascolti ora"))
            self?.play(files)
        }
    }

    /// Metti in timeline: renders every paragraph as a job (progress per paragraph, Cancel stops the render), then
    /// voice.say places them (cached renders: quick) and the clips are selected.
    func place() {
        guard !demo, let store, let jobs, let lang = activeLanguage?.code, !paragraphs.isEmpty else { return }
        stopPlayback()
        let text = self.text, tone = activeTone, placement = self.placement, n = paragraphs.count
        let title = Plural.text(n, "Voce: 1 paragrafo", "Voce: %d paragrafi")
        jobs.start(kind: "voice", title: title, onCancel: { [weak store] in store?.cancelAside() }) { [weak self] h in
            guard let self else { return }
            for (i, p) in VoiceScript.paragraphs(text).enumerated() {
                h.update(detail: String(format: loc("Paragrafo %d di %d"), i + 1, n))
                let c = VoiceCalls.preview(text, language: lang, tone: tone, paragraph: i)
                let estimate = VoiceScript.estimatedRenderSeconds(speech: VoiceScript.estimatedSeconds(p), paragraphs: 1)
                _ = try await self.timed(h, from: Double(i) / Double(n + 1), to: Double(i + 1) / Double(n + 1), seconds: estimate) {
                    try await Self.inWords { try await store.aside(c.id, c.params) }
                }
            }
            try Task.checkCancellation()
            h.update(progress: Double(n) / Double(n + 1), detail: loc("Metto le clip sulla pista Voce e calcolo i tempi delle parole…"))
            // The text this panel placed before, its clips all still on their track: placed again over them (#100).
            let before = self.placed.flatMap { p -> [String]? in
                let onTrack = Set(store.project?.tracks.first { $0.id == p.trackId }?.clips.map(\.id) ?? [])
                return !p.clipIds.isEmpty && p.clipIds.allSatisfy(onTrack.contains) ? p.clipIds : nil
            }
            let say = VoiceCalls.say(text, language: lang, tone: tone, placement: placement, playhead: store.preview.time, replace: before)
            let r = try await Self.inWords { try await store.perform(say.id, say.params) }
            let ids = (r["clips"]?.arrayValue ?? []).compactMap { $0["clipId"]?.stringValue }
            let trackId = r["trackId"]?.stringValue ?? ""
            let end = r["end"]?.doubleValue ?? 0, start = r["clips"]?.arrayValue?.first?["start"]?.doubleValue ?? 0
            store.selection = Set(ids)
            if let s = r["clips"]?.arrayValue?.first?["start"]?.doubleValue { store.preview.seek(s) }
            self.placed = Placed(trackId: trackId, clipIds: ids, seconds: max(0, end - start), text: text)
            h.update(progress: 1, detail: say.params["replace"] != nil ? VoiceCalls.replaced(r) : String(format: loc("%d clip sulla pista Voce"), ids.count))
        }
    }

    /// Captions from the same text: the clips carry word timings, no transcription needed.
    func captionsFromText() {
        guard !demo, let store, let p = placed else { return }
        Task {
            let c = VoiceCalls.captions(trackId: p.trackId)
            do {
                try await store.perform(c.id, c.params)
                placed?.captioned = true
            } catch { store.errorMessage = VoiceErrors.readable(error) }
        }
    }

    /// A refused command as the panel's sentence (#94): the job shows it, never the engine's text written for Claude.
    private static func inWords<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch is CancellationError { throw CancellationError() }
        catch { throw StepError(message: VoiceErrors.readable(error)) }
    }

    /// Progress that moves with time while one long call runs (the model gives no progress of its own).
    private func timed<T>(_ h: JobCenter.Handle, from: Double, to: Double, seconds: Double, _ work: () async throws -> T) async throws -> T {
        let ticker = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                let f = min(0.95, Date().timeIntervalSince(start) / max(seconds, 1))
                h.update(progress: from + (to - from) * f)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { ticker.cancel() }
        let r = try await work()
        h.update(progress: to)
        return r
    }

    func play(_ files: [URL]) {
        queue = files
        playNext()
    }

    private func playNext() {
        guard !queue.isEmpty else { playing = false; player = nil; return }
        let url = queue.removeFirst()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return playNext() }
        player = p
        playing = true
        p.play()
        let d = p.duration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(d + 0.05))
            guard let self, self.player === p else { return }
            self.playNext()
        }
    }

    func stopPlayback() {
        queue = []
        player?.stop()
        player = nil
        playing = false
    }

    // MARK: Lexicon

    func lexiconAdd(word: String, say: String, confirmed: Bool = true) {
        guard let l = lexiconLanguage ?? activeLanguage?.code else { return }
        let w = word.trimmingCharacters(in: .whitespaces), s = say.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !s.isEmpty else { return }
        run(VoiceCalls.lexiconAdd(l, word: w, say: s, confirmed: confirmed)) { [weak self] in await self?.loadLexicon(l) }
    }

    func lexiconRemove(_ word: String) {
        guard let l = lexiconLanguage ?? activeLanguage?.code else { return }
        run(VoiceCalls.lexiconRemove(l, word: word)) { [weak self] in await self?.loadLexicon(l) }
    }

    private func run(_ c: VoiceCall, then: @escaping @MainActor () async -> Void) {
        guard !demo, let store else { return }
        Task {
            do { try await store.perform(c.id, c.params) } catch { store.errorMessage = VoiceErrors.readable(error) }
            await then()
        }
    }

    // MARK: The "Gestisci voci" window

    /// Opens the window on `language` (its overview when it has a voice, else its intro); nil: where the voice stands.
    func openWindow(language: String?) {
        select(language ?? windowLanguage)
        store?.showVoiceSetup = true
        Task { await refresh(); await loadScript() }
    }

    /// The panel's entries: Gestisci voci… (the composer's language), + Lingua (the first language without a voice),
    /// + Tono and Allena… (the composer's language, its overview).
    func manageVoices() { openWindow(language: activeLanguage?.code) }
    func addLanguage() { openWindow(language: VoiceWindowPage.firstWithoutVoice(snapshot)) }
    func addTone() { openWindow(language: activeLanguage?.code) }
    func openTraining() { openWindow(language: activeLanguage?.code) }

    /// A language picked in the rail.
    func chooseLanguage(_ code: String) {
        select(code)
        Task { await loadScript() }
    }

    private func select(_ code: String) {
        if setup.language != code { setup.lines = [:]; setup.consent = "" }
        setup.language = code
        setup.started = false
        setup.consentRead = false
        setup.check = nil
        setup.pendingTone = nil
    }

    /// voice.enroll.script for the chosen language (it also writes script.md in the profile, to read from a phone).
    func loadScript() async {
        let lang = windowLanguage
        guard !demo, let store, snapshot.profile != nil else { return }
        let c = VoiceCalls.script(lang)
        guard let r = try? await store.perform(c.id, c.params) else { return }
        setup.consent = r["consent"]?.stringValue ?? ""
        var lines: [String: [String]] = [:]
        for b in r["blocks"]?.arrayValue ?? [] {
            if let t = b["tone"]?.stringValue { lines[t] = b["lines"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        }
        setup.lines = lines
    }

    var recordTone: String { VoiceWindowPage.tone(pending: setup.pendingTone) }

    /// Starts a microphone-only take with the app's recorder (the "Solo voce" sources, no teleprompter: the text is on
    /// this sheet); the choices the person had come back when the take ends.
    func startRecording(_ recorder: Recorder) {
        guard !demo, !recorder.isRecording else { return }
        savedSources = recorder.sources
        recorder.sources.apply(.voice)
        recorder.sources.prompter = false
        let tone = recordTone
        recorder.nextTakeHandler = { [weak self, weak recorder] url in
            guard let self else { return }
            if let s = self.savedSources { recorder?.sources = s }
            self.savedSources = nil
            self.setup.recording = false
            self.addTake(url, tone: tone)
        }
        setup.recording = true
        Task {
            await recorder.prepare()
            recorder.start()
            if !recorder.isRecording {
                recorder.nextTakeHandler = nil
                if let s = savedSources { recorder.sources = s }
                savedSources = nil
                setup.recording = false
                store?.errorMessage = recorder.errorMessage ?? loc("La registrazione non è partita")
            }
        }
    }

    func stopRecording(_ recorder: Recorder) { recorder.stop() }

    /// Importa un file audio: a take recorded elsewhere (a phone with an external microphone).
    func importTake() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie]
        p.message = loc("Scegli la registrazione del blocco (un file per tono)")
        guard p.runModal() == .OK, let url = p.url else { return }
        addTake(url, tone: recordTone)
    }

    /// voice.enroll.add as a job: transcription, consent check, one clip per line heard.
    func addTake(_ url: URL, tone: String) {
        let lang = windowLanguage
        guard !demo, let store, let jobs else { return }
        setup.check = nil
        jobs.start(kind: "voice-take", title: String(format: loc("Controllo della registrazione · %@"), loc(VoiceTones.title(tone))),
                   cancellable: false) { [weak self] h in
            h.update(detail: loc("Trascrivo e cerco le righe del copione…"))
            let c = VoiceCalls.addTake(url.path, language: lang, tone: tone)
            do {
                let r = try await store.aside(c.id, c.params)
                self?.setup.check = VoiceTakeCheck(tone: tone, result: r)
            } catch {
                self?.setup.check = VoiceTakeCheck(tone: tone, error: VoiceErrors.readable(error))
                throw error
            }
            self?.setup.pendingTone = nil
            await self?.refresh()
        }
    }

    /// After the check: on to the overview (or another take of the same tone).
    func continueAfterCheck(again: Bool) {
        let tone = setup.check?.tone
        setup.check = nil
        setup.pendingTone = again ? tone : nil
    }

    /// voice.enroll.train: the training runs in the background; a job follows it from voice.enroll.status.
    func train() {
        let lang = windowLanguage
        guard !demo, let store else { return }
        Task {
            let c = VoiceCalls.train(lang)
            do { try await store.perform(c.id, c.params) } catch { store.errorMessage = VoiceErrors.readable(error) }
            await refresh()
        }
    }

    /// While a language trains, a job polls voice.enroll.status (every 30 s) until it ends; it survives the panel and
    /// the sheet closing. On relaunch it comes back the first time the voice state is read.
    private func watchTraining() {
        guard !demo, let jobs, jobs.latest("voice-training")?.isRunning != true,
              let running = snapshot.languages.first(where: { $0.training.isRunning }) else { return }
        let lang = running.code
        jobs.start(kind: "voice-training", title: String(format: loc("Allenamento della voce · %@"), VoiceLanguages.name(lang)),
                   cancellable: false) { [weak self] h in
            while let self {
                guard case .running(let step, let steps, let left) = self.snapshot.language(lang)?.training else { break }
                if let step, let steps, steps > 0 {
                    h.update(progress: Double(step) / Double(steps),
                             detail: left.map { String(format: loc("Passo %d di %d · circa %d min"), step, steps, Int($0)) }
                                 ?? String(format: loc("Passo %d di %d"), step, steps))
                } else {
                    h.update(detail: loc("Preparo i dati e carico il modello…"))
                }
                try await Task.sleep(for: .seconds(30))
                await self.refresh()
            }
            if self?.snapshot.language(lang)?.training == .failed { throw VoiceErrors.trainingFailed }
        }
    }
}

/// Error messages in plain words (never the raw engine message alone).
enum VoiceErrors: Error, CustomStringConvertible {
    case trainingFailed

    var description: String { loc("L'allenamento non è riuscito: la voce resta quella dal riferimento. Riprova più tardi.") }

    static func readable(_ error: Error) -> String {
        let raw = JobCenter.message(error)
        if raw.contains("consent sentence") {
            return loc("Non ho sentito la frase di consenso all'inizio della registrazione. Ricomincia leggendola per prima, con calma.")
        }
        if raw.contains("is occupied at") {
            return loc("La pista Voce è già occupata al cursore: scegli «Dopo l'ultima voce» o sposta il cursore.")
        }
        if raw.contains("no project") || raw.contains("No project") {
            return loc("Apri o crea prima un progetto: la voce va sulla sua timeline.")
        }
        if raw.contains("cancelled") { return loc("Annullato.") }
        // The other failed-step sentences (#88: a voice in a language the profile has no voice in…), the same fallback.
        return StepError.readable(error)
    }
}
