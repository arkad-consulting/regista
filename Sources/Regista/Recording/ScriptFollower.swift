import AVFoundation
import QuartzCore
import RegistaCore
import RegistaEngines

/// What the recorder gives the teleprompter: every microphone buffer while the capture session runs.
/// The recorder calls it on its capture queue (`Recorder.speechSink`); implementations
/// must be thread-safe. Recording start/stop are read from `Recorder.isRecording`.
protocol SpeechAudioSink: AnyObject, Sendable {
    func speechAudio(_ buffer: CMSampleBuffer)
}

/// Listens to the speaker (same microphone as the recording), follows them through the script and
/// logs live take markers. On-device recognition (`LiveSpeechSession`: DictationTranscriber on
/// macOS 26, SFSpeechRecognizer before): free, offline, a new hypothesis every word.
@MainActor
final class ScriptFollower: ObservableObject {
    @Published private(set) var tracker = TakeTracker(script: PromptScript(""))
    @Published private(set) var isListening = false
    /// Last words heard, shown faintly in the teleprompter so the speaker can trust it.
    @Published private(set) var lastHeard = ""
    @Published private(set) var engine: String?
    /// Words per minute over the last seconds (nil while there is not enough speech).
    @Published private(set) var wpm: Double?
    /// The sentence just restarted (0-based), for a brief hint.
    @Published private(set) var restarted: Int?
    @Published var errorMessage: String?

    /// When the cursor last moved forward (CACurrentMediaTime): the canvas leads from there.
    private(set) var movedAt: CFTimeInterval = 0
    /// Called for a spoken "stop".
    var onStop: (() -> Void)?

    private var session: LiveSpeechSession?
    private let sink = FollowerSink()
    private var script = ""
    private var commands = VoiceCommandSet.italian
    /// Host-clock seconds when the recording started: markers are measured from it.
    private var recordingStart: Double?
    private var finishing: Task<Void, Never>?
    /// The recognizer locale of the last listening session (written into the take log).
    private var localeID = "it-IT"

    var cursor: Int { tracker.cursor }
    var state: ScriptAligner.State { tracker.state }
    var prompt: PromptScript { tracker.script }

    func load(script: String, commands: VoiceCommandSet) {
        guard script != self.script || commands != self.commands else { return }
        let sameText = script == self.script
        let cursor = tracker.cursor
        self.script = script
        self.commands = commands
        tracker = TakeTracker(script: PromptScript(script), commands: commands)
        if sameText { tracker.jump(toToken: cursor) }
    }

    func jump(to index: Int) { apply(tracker.jump(toToken: index)) }

    /// Back to the start of the script with a new take log (the recorder calls it when recording starts).
    func restart() {
        tracker = TakeTracker(script: PromptScript(script), commands: commands)
        restarted = nil
        wpm = nil
    }

    /// Pedal / keyboard: the next sentence.
    func nextSentence() {
        guard let s = tracker.currentSentence else { return }
        apply(tracker.jump(toSentence: s + 1))
    }

    /// Pedal / keyboard: inside a sentence back to its start (a new take), at its start the previous one.
    func previousSentence() {
        guard let s = tracker.currentSentence else { return }
        if tracker.cursor > prompt.sentences[s].tokens.lowerBound + 1 { apply(tracker.restart(discard: false, at: sink.streamNow ?? 0)) }
        else { apply(tracker.jump(toSentence: s - 1)) }
    }

    // MARK: Listening

    /// Starts listening to the recorder's microphone.
    func start(recorder: Recorder, language: String) async {
        guard !isListening else { return }
        errorMessage = nil
        await recorder.prepare()
        guard recorder.isReady else {
            errorMessage = recorder.errorMessage ?? loc("Microfono non disponibile")
            return
        }
        let locale = PrompterLanguage.locale(language)
        // On-device only: a language this Mac cannot recognize locally says so instead of failing silently.
        if await LiveSpeechSession.onDeviceSupport(for: locale) == .unavailable {
            errorMessage = String(format: loc("Il riconoscimento di %@ non è disponibile su questo Mac: usa Velocità o Manuale"), PrompterLanguage.name(language))
            return
        }
        localeID = locale.identifier(.bcp47)
        let s: LiveSpeechSession
        do {
            // Through the recorder's hardware, like the microphone it hears (a test's stand-in starts no recognition).
            s = try await recorder.hardware.listen(locale: locale, contextualStrings: Self.rareWords(in: prompt)) { [weak self] h in
                Task { @MainActor in self?.handle(h) }
            }
        } catch {
            errorMessage = loc("Il gobbo non riesce ad ascoltare: %@", "\(error)")
            return
        }
        session = s
        engine = s.engine.rawValue
        sink.begin(s)
        recorder.speechSink = sink
        isListening = true
    }

    /// Stops listening; the last words are finalized in the background (`finishedMarkers()` waits for them).
    func stop(recorder: Recorder?) {
        guard isListening else { return }
        isListening = false
        recorder?.speechSink = nil
        sink.end()
        let s = session
        session = nil
        finishing = Task { [weak self] in
            _ = await s?.finish()
            self?.finishing = nil
        }
    }

    /// Recording started now: from here on marker times are recording seconds.
    func recordingDidStart() {
        // The capture session stamps its buffers on the host clock: listening may start a moment later.
        recordingStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    /// The markers of the recording that just ended, in recording seconds (waits for the last words).
    func finishedMarkers() async -> LiveTakeLog? {
        await finishing?.value
        tracker.finish()
        guard let start = recordingStart, let streamOrigin = sink.origin else { return nil }
        recordingStart = nil
        // Stream seconds of the recording's first instant.
        let origin = start - streamOrigin
        let markers = tracker.markers.compactMap { m -> LiveTakeMarker? in
            var m = m
            m.start = max(0, m.start - origin)
            m.end -= origin
            return m.end > 0 ? m : nil
        }
        guard !markers.isEmpty else { return nil }
        return LiveTakeLog(sentences: prompt.sentences.map(\.text), markers: markers, recognizer: engine,
                           language: localeID)
    }

    private func handle(_ h: SpeechHypothesis) {
        guard isListening || finishing != nil else { return }
        apply(tracker.update(h.words, epoch: h.epoch, now: h.audioTime))
        lastHeard = h.words.suffix(6).map(\.text).joined(separator: " ")
        wpm = tracker.pace.wordsPerMinute(at: h.audioTime)
    }

    private func apply(_ events: [TakeTracker.Event]) {
        var before = Int.max
        for e in events {
            switch e {
            case .moved(let c):
                if before == .max || c > before { movedAt = CACurrentMediaTime() }
                before = c
            case .restart(let s):
                restarted = s
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if self?.restarted == s { self?.restarted = nil }
                }
            case .command(.stop):
                onStop?()
            case .command(.redo), .take:
                break
            }
        }
    }

    /// Long, distinctive words help the recognizer with names and jargon.
    private static func rareWords(in prompt: PromptScript) -> [String] {
        var seen = Set<String>()
        return prompt.sentences.flatMap { $0.text.split(separator: " ") }
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 7 && seen.insert($0.lowercased()).inserted }
            .prefix(100).map { $0 }
    }
}

/// Hands microphone buffers from the capture queue to the current recognition session, timed on the
/// capture clock from the first buffer (stream seconds).
final class FollowerSink: SpeechAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var session: LiveSpeechSession?
    private var firstPTS: Double?
    private var last: Double?

    func begin(_ s: LiveSpeechSession) {
        lock.withLock { session = s; firstPTS = nil; last = nil }
    }

    func end() {
        lock.withLock { session = nil }
    }

    /// The stream time of the newest buffer's end (nil before the first one).
    var streamNow: Double? { lock.withLock { last } }

    /// Presentation time (capture clock, seconds) of the first buffer: stream time 0.
    var origin: Double? { lock.withLock { firstPTS } }

    func speechAudio(_ buffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        let duration = CMSampleBufferGetDuration(buffer).seconds
        let (s, o): (LiveSpeechSession?, Double) = lock.withLock {
            let o = firstPTS ?? pts
            firstPTS = o
            last = pts - o + (duration.isFinite ? duration : 0)
            return (session, o)
        }
        s?.append(buffer, origin: o)
    }
}
