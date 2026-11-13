import AVFoundation
import Foundation
import RegistaCore
import Speech

/// Live, on-device speech recognition for the teleprompter: microphone buffers in, growing
/// hypotheses (words with times when the recognizer knows them) out.
///
/// Three engines behind one session, best first:
/// - `DictationTranscriber` (SpeechAnalyzer, macOS 26+): on-device, a new hypothesis every word
///   (~0.2-0.3 s), word times, no task length limit, no speech-recognition permission prompt; the
///   language model is downloaded once by the system. The teleprompter default.
/// - `SpeechTranscriber` (SpeechAnalyzer, macOS 26+): more accurate, but even with fast results it
///   reports about once a second, so the highlight trails by ~0.6 s.
/// - `SFSpeechRecognizer` (fallback, macOS 15): needs the speech-recognition permission; its tasks
///   are restarted every ~50 s (the ~1 min limit) without losing the position (a new epoch).
public final class LiveSpeechSession: @unchecked Sendable {
    public enum EngineKind: String, Sendable, CaseIterable {
        case dictation = "DictationTranscriber", transcriber = "SpeechTranscriber", sfSpeech = "SFSpeechRecognizer"
    }

    public let locale: Locale
    public private(set) var engine: EngineKind
    private let contextualStrings: [String]
    private let onUpdate: @Sendable (SpeechHypothesis) -> Void
    private var backend: SpeechBackend?

    /// The engine a new session uses on this Mac.
    public static var preferredEngine: EngineKind {
        if #available(macOS 26.0, *) { return .dictation }
        return .sfSpeech
    }

    public init(locale: Locale, contextualStrings: [String] = [], engine: EngineKind? = nil,
                onUpdate: @escaping @Sendable (SpeechHypothesis) -> Void) {
        self.locale = locale
        self.contextualStrings = contextualStrings
        self.engine = engine ?? Self.preferredEngine
        self.onUpdate = onUpdate
    }

    /// Whether this Mac can recognize `locale` without sending audio anywhere.
    public enum OnDeviceSupport: String, Sendable {
        /// The on-device model is installed.
        case installed
        /// Supported on device; the system downloads the model the first time.
        case downloadable
        /// Not on this Mac (only server recognition would work).
        case unavailable
    }

    public static func onDeviceSupport(for locale: Locale) async -> OnDeviceSupport {
        let wanted = locale.identifier(.bcp47)
        if #available(macOS 26.0, *) {
            if await DictationTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == wanted }) { return .installed }
            if await DictationTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == wanted }) { return .downloadable }
        }
        return SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true ? .installed : .unavailable
    }

    /// Prepares the recognizer (may download the on-device model the first time). Throws a message
    /// meant for the user when recognition is not possible.
    public func start() async throws {
        if engine != .sfSpeech, #available(macOS 26.0, *) {
            do {
                backend = try await AnalyzerBackend.make(kind: engine, locale: locale, contextualStrings: contextualStrings, emit: onUpdate)
                return
            } catch {
                // Fall back to SFSpeechRecognizer (e.g. the language is not supported on-device).
                NSLog("Regista: %@ unavailable (%@), using SFSpeechRecognizer", engine.rawValue, "\(error)")
            }
        }
        engine = .sfSpeech
        backend = try await SFSpeechBackend.make(locale: locale, contextualStrings: contextualStrings, emit: onUpdate)
    }

    /// Audio at stream time `time` (seconds; continuous buffers may pass increasing times).
    public func append(_ buffer: AVAudioPCMBuffer, at time: Double) {
        backend?.append(buffer, at: time)
    }

    /// A capture buffer (microphone): converted to PCM, timed by its presentation time minus `origin`.
    public func append(_ sample: CMSampleBuffer, origin: Double = 0) {
        guard let pcm = Self.pcm(from: sample) else { return }
        append(pcm, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds - origin)
    }

    /// Flushes the last words and stops. Returns the finalized transcript.
    public func finish() async -> [Word] {
        await backend?.finish() ?? []
    }

    public func cancel() {
        backend?.cancel()
        backend = nil
    }

    /// A capture sample buffer as an AVAudioPCMBuffer in its own format.
    public static func pcm(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

protocol SpeechBackend: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer, at time: Double)
    func finish() async -> [Word]
    func cancel()
}

struct SpeechError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Splits recognized text into words; words without their own time range are spread over `span`
/// in proportion to their length (volatile results only carry one range for the whole segment).
private func spread(_ items: [(text: String, range: (Double, Double)?)], over span: (Double, Double)) -> [HeardWord] {
    var out: [HeardWord] = []
    var pending: [String] = []
    func flush(until end: Double) {
        guard !pending.isEmpty else { return }
        let from = out.last?.end ?? span.0
        let to = max(end, from)
        let total = Double(pending.reduce(0) { $0 + max($1.count, 1) })
        var t = from
        for w in pending {
            let d = (to - from) * Double(max(w.count, 1)) / total
            out.append(HeardWord(w, start: nil, end: nil))
            out[out.count - 1].start = t
            out[out.count - 1].end = t + d
            t += d
        }
        pending = []
    }
    for item in items {
        let words = item.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { continue }
        if let r = item.range {
            flush(until: r.0)
            // Several words in one timed run: share its range.
            let total = Double(words.reduce(0) { $0 + max($1.count, 1) })
            var t = r.0
            for w in words {
                let d = (r.1 - r.0) * Double(max(w.count, 1)) / total
                out.append(HeardWord(w, start: t, end: t + d))
                t += d
            }
        } else {
            pending += words
        }
    }
    flush(until: span.1)
    return out
}

// MARK: - SpeechAnalyzer modules (macOS 26)

/// One result of either transcriber module.
private struct AnalyzerResult: Sendable {
    var text: AttributedString
    var range: CMTimeRange
    var isFinal: Bool
}

@available(macOS 26.0, *)
final class AnalyzerBackend: SpeechBackend, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let emit: @Sendable (SpeechHypothesis) -> Void
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var finals: [HeardWord] = []
    private var volatile: [HeardWord] = []
    private var fed = 0.0
    private var started = false
    private var results: Task<Void, Never>?

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat,
                 input: AsyncStream<AnalyzerInput>.Continuation, emit: @escaping @Sendable (SpeechHypothesis) -> Void) {
        self.analyzer = analyzer
        self.format = format
        self.input = input
        self.emit = emit
    }

    static func make(kind: LiveSpeechSession.EngineKind, locale: Locale, contextualStrings: [String],
                     emit: @escaping @Sendable (SpeechHypothesis) -> Void) async throws -> AnalyzerBackend {
        let wanted = locale.identifier(.bcp47)
        let module: any SpeechModule
        let results: AsyncThrowingStream<AnalyzerResult, Error>
        switch kind {
        case .dictation:
            guard await DictationTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == wanted }) else {
                throw SpeechError("DictationTranscriber does not support \(wanted)")
            }
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [],
                                         reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange])
            module = t
            results = AsyncThrowingStream { c in
                Task { do { for try await r in t.results { c.yield(AnalyzerResult(text: r.text, range: r.range, isFinal: r.isFinal)) }; c.finish() }
                       catch { c.finish(throwing: error) } }
            }
        default:
            guard await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == wanted }) else {
                throw SpeechError("SpeechTranscriber does not support \(wanted)")
            }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                                      attributeOptions: [.audioTimeRange])
            module = t
            results = AsyncThrowingStream { c in
                Task { do { for try await r in t.results { c.yield(AnalyzerResult(text: r.text, range: r.range, isFinal: r.isFinal)) }; c.finish() }
                       catch { c.finish(throwing: error) } }
            }
        }
        // The on-device model for the language: downloaded by the system the first time.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw SpeechError("\(kind.rawValue) has no audio format")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let backend = AnalyzerBackend(analyzer: analyzer, format: format, input: continuation, emit: emit)
        try await analyzer.start(inputSequence: stream)
        backend.results = Task { [weak backend] in
            do {
                for try await r in results { backend?.handle(r) }
            } catch {
                NSLog("Regista: speech results ended: %@", "\(error)")
            }
        }
        return backend
    }

    private func handle(_ r: AnalyzerResult) {
        var items: [(text: String, range: (Double, Double)?)] = []
        for run in r.text.runs {
            let text = String(r.text[run.range].characters)
            let range = run.audioTimeRange.map { ($0.start.seconds, $0.end.seconds) }
            items.append((text, range))
        }
        let hypothesis: SpeechHypothesis = lock.withLock {
            let span = (r.range.start.seconds, min(r.range.end.seconds.isFinite ? r.range.end.seconds : fed, fed))
            // Volatile words stay untimed: their one time range covers the whole segment, silence included,
            // so the tracker dates them by arrival until the final result brings per-word times.
            let words = r.isFinal
                ? spread(items, over: span)
                : items.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map { HeardWord(String($0)) } }
            if r.isFinal {
                finals += words
                volatile = []
            } else {
                volatile = words
            }
            return SpeechHypothesis(words: finals + volatile, epoch: 0, audioTime: fed)
        }
        emit(hypothesis)
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: Double) {
        guard let converted = convert(buffer) else { return }
        let first: Bool = lock.withLock {
            defer { started = true; fed = time + Double(buffer.frameLength) / buffer.format.sampleRate }
            return !started
        }
        input.yield(AnalyzerInput(buffer: converted, bufferStartTime: first ? CMTime(seconds: time, preferredTimescale: 48_000) : nil))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    func finish() async -> [Word] {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results?.value
        return lock.withLock { finals.compactMap { w in w.start.map { Word(w.text, $0, w.end ?? $0) } } }
    }

    func cancel() {
        input.finish()
        results?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}

// MARK: - SFSpeechRecognizer (fallback)

final class SFSpeechBackend: SpeechBackend, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let contextualStrings: [String]
    private let emit: @Sendable (SpeechHypothesis) -> Void
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var epoch = 0
    private var requestStart = 0.0
    private var fed = 0.0
    private var lastWords: [Word] = []
    private var done: [Word] = []
    /// Tasks are restarted before Apple's ~1 minute limit.
    private let taskLength = 50.0

    private init(recognizer: SFSpeechRecognizer, contextualStrings: [String], emit: @escaping @Sendable (SpeechHypothesis) -> Void) {
        self.recognizer = recognizer
        self.contextualStrings = contextualStrings
        self.emit = emit
    }

    static func make(locale: Locale, contextualStrings: [String], emit: @escaping @Sendable (SpeechHypothesis) -> Void) async throws -> SFSpeechBackend {
        // Asking without a usage description kills a command-line process: only an app bundle may ask.
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined, Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil {
            status = await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) } }
        }
        guard status == .authorized else {
            throw SpeechError("Consenti il riconoscimento vocale in Impostazioni di Sistema → Privacy e sicurezza → Riconoscimento vocale.")
        }
        guard let r = SFSpeechRecognizer(locale: locale), r.isAvailable else {
            throw SpeechError("Riconoscimento vocale non disponibile per \(locale.identifier)")
        }
        let backend = SFSpeechBackend(recognizer: r, contextualStrings: contextualStrings, emit: emit)
        backend.startTask(at: 0)
        return backend
    }

    private func startTask(at time: Double) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
        let (old, myEpoch, start): (SFSpeechAudioBufferRecognitionRequest?, Int, Double) = lock.withLock {
            let old = self.request
            epoch += 1
            requestStart = time
            self.request = request
            done += lastWords
            lastWords = []
            return (old, epoch, time)
        }
        old?.endAudio()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let current: Bool = self.lock.withLock { self.epoch == myEpoch }
            guard current else { return }
            if let result {
                let words = result.bestTranscription.segments.map { seg -> HeardWord in
                    // Partial results often carry no timing (0/0): leave it unknown.
                    let timed = seg.timestamp > 0 || seg.duration > 0
                    return HeardWord(seg.substring, start: timed ? start + seg.timestamp : nil,
                                     end: timed ? start + seg.timestamp + seg.duration : nil)
                }
                let audio: Double = self.lock.withLock {
                    self.lastWords = words.compactMap { w in w.start.map { Word(w.text, $0, w.end ?? $0) } }
                    return self.fed
                }
                self.emit(SpeechHypothesis(words: words, epoch: myEpoch, audioTime: audio))
            }
            // The task ends on its own after a long silence or an error: open a new one.
            if (result?.isFinal ?? false) || error != nil {
                let now: Double = self.lock.withLock { self.fed }
                self.startTask(at: now)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: Double) {
        let (request, restart): (SFSpeechAudioBufferRecognitionRequest?, Bool) = lock.withLock {
            fed = time + Double(buffer.frameLength) / buffer.format.sampleRate
            return (self.request, time - requestStart > taskLength)
        }
        if restart { startTask(at: time) }
        (restart ? lock.withLock { self.request } : request)?.append(buffer)
    }

    func finish() async -> [Word] {
        let request: SFSpeechAudioBufferRecognitionRequest? = lock.withLock { self.request }
        request?.endAudio()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return lock.withLock {
            epoch += 1
            return done + lastWords
        }
    }

    func cancel() {
        lock.withLock { epoch += 1 }
        task?.cancel()
        request?.endAudio()
    }
}

// MARK: - Replaying a file through the live recognizer (teleprompter.simulate)

public struct AppleSpeechStreamer: SpeechStreamer {
    public init() {}

    public func stream(file: URL, locale: String, engine: String?, speed: Double, contextualStrings: [String],
                       onUpdate: @escaping @Sendable (SpeechHypothesis) -> Void) throws -> SpeechStreamResult {
        // Off Swift's cooperative pool: a synchronous caller holding a pool thread cannot starve it (#80).
        try BlockingBridge.run("regista.speech-stream") {
            let kind = engine.flatMap(LiveSpeechSession.EngineKind.init(rawValue:))
            let session = LiveSpeechSession(locale: Locale(identifier: locale), contextualStrings: contextualStrings, engine: kind, onUpdate: onUpdate)
            try await session.start()
            let audio = try AVAudioFile(forReading: file)
            let format = audio.processingFormat
            let chunk = AVAudioFrameCount(format.sampleRate * 0.1)
            let t0 = Date()
            var position = 0.0
            while audio.framePosition < audio.length, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) {
                try audio.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                let duration = Double(buffer.frameLength) / format.sampleRate
                // Live, a buffer exists once its last sample was spoken.
                let wait = (position + duration) / max(speed, 0.01) - Date().timeIntervalSince(t0)
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                session.append(buffer, at: position)
                position += duration
            }
            // A second of silence, as a live recording has after the last word: lets the recognizer finalize it.
            if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
                silence.frameLength = silence.frameCapacity
                try await Task.sleep(nanoseconds: UInt64(1e9 / max(speed, 0.01)))
                session.append(silence, at: position)
            }
            let words = await session.finish()
            return SpeechStreamResult(engine: session.engine.rawValue, locale: locale, words: words,
                                      audioSeconds: position, wallSeconds: Date().timeIntervalSince(t0))
        }.get()
    }
}
