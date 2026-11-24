import Foundation
import Testing
@testable import RegistaCore

/// Returns fixed metadata: no ffprobe in unit tests.
struct FakeProber: MediaProber {
    var media = ProbedMedia(
        duration: MediaTime(value: 56822, timescale: 600),   // 94.703 s, like the test take
        video: VideoInfo(width: 1080, height: 1920, frameRate: Rational(30), codec: "h264", rotation: -90),
        audio: AudioInfo(sampleRate: 48000, channels: 2, codec: "aac"))

    func probe(_ url: URL) throws -> ProbedMedia {
        if url.lastPathComponent.hasSuffix(".wav") { return ProbedMedia(duration: media.duration, audio: media.audio) }
        return media
    }
}

/// The user brand kits folder of the whole test process (#18): `$REGISTA_BRANDKITS` points at one scratch folder,
/// set before any test reads a kit, so no test sees (or writes) the kits of the person running the suite. Touched by
/// `tempDir()` and `editingEngine()`, which nearly every test calls first, and by the brand kit tests. Named after the
/// pid, so RegistaEnginesTests (same process, no access to this file) sets the very same value.
let testKitsDirectory: URL = {
    let url = TemporaryFolder.url.appendingPathComponent("regista-tests-kits-\(ProcessInfo.processInfo.processIdentifier)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    setenv("REGISTA_BRANDKITS", url.path, 1)
    // The editing-rule sheets (#31) live in `rules/` of the support folder: a scratch one too, unless the app's rig
    // already set its own (RigIsolation.swift).
    if (ProcessInfo.processInfo.environment["REGISTA_SUPPORT_DIR"] ?? "").isEmpty {
        let support = TemporaryFolder.url.appendingPathComponent("regista-tests-support-\(ProcessInfo.processInfo.processIdentifier)")
        setenv("REGISTA_SUPPORT_DIR", support.path, 1)
    }
    return url
}()

/// A fresh temporary directory per call.
func tempDir() -> URL {
    _ = testKitsDirectory
    let url = TemporaryFolder.url.appendingPathComponent("regista-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An empty file that media.import can find (the fake prober supplies the metadata).
func fakeMedia(_ name: String = "take.mov", in dir: URL = tempDir()) -> String {
    let url = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data())
    return url.path
}

func t(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

/// Engine with a project, one imported 94.7 s asset (a1), tracks V1 (t1) and A1 (t2).
func editingEngine(directory: URL? = nil) throws -> Engine {
    _ = testKitsDirectory
    let e = Engine(prober: FakeProber())
    var params: JSONValue = ["name": "test"]
    if let directory { params = ["name": "test", "directory": .string(directory.path)] }
    try e.execute("project.new", params: params)
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    return e
}

extension Engine {
    func clips(_ track: Int = 0) -> [Clip] { project!.tracks[track].clips }

    /// Runs an edit, then checks undo restores the exact previous project and redo the result.
    @discardableResult
    func checkUndoRedo(_ id: String, _ params: JSONValue, sourceLocation: SourceLocation = #_sourceLocation) throws -> JSONValue {
        let before = project
        let result = try execute(id, params: params)
        let after = project
        #expect(before != after, "\(id) changed nothing", sourceLocation: sourceLocation)
        try execute("history.undo")
        #expect(project == before, "undo of \(id) did not restore the project", sourceLocation: sourceLocation)
        try execute("history.redo")
        #expect(project == after, "redo of \(id) did not restore the result", sourceLocation: sourceLocation)
        return result
    }
}

// MARK: - Fake engines

/// Records calls; writes small real wav files so the pure code paths (envelope, sync check) run.
final class FakeAudio: AudioToolkit {
    var measured = Loudness(integrated: -15.1, truePeak: -2.0, range: 3, threshold: -25)
    var spans: [[AudioSpan]] = []
    /// What extractAudio writes as the speech wav (16 kHz mono).
    var speech: WAVAudio

    init(speech: WAVAudio = syntheticSpeech([(1.0, 2.0), (3.0, 4.5)], duration: 6)) { self.speech = speech }

    func extractAudio(from source: URL, channels: Int, speech: URL, working: URL) throws {
        try self.speech.write16(to: speech)
        try WAVAudio(sampleRate: 48000, channels: 1, samples: upsample3(self.speech.samples)).write16(to: working)
    }

    func loudness(of spans: [AudioSpan]) throws -> Loudness {
        self.spans.append(spans)
        return measured
    }

    var mixes: [(clips: [AudioMixClip], length: Int, ceiling: Double)] = []
    func mix(_ clips: [AudioMixClip], length: Int, rate: Int, gain: Double, ceiling: Double, to output: URL) throws {
        mixes.append((clips, length, ceiling))
        try WAVAudio(sampleRate: rate, channels: 2, samples: [Float](repeating: 0, count: 2 * length)).write16(to: output)
    }
}

/// 16 kHz mono noise bursts at `speech` (seconds), near-silence elsewhere.
func syntheticSpeech(_ speech: [(Double, Double)], duration: Double, rate: Int = 16000) -> WAVAudio {
    var g = SystemRandomNumberGenerator()
    var samples = [Float](repeating: 0, count: Int(duration * Double(rate)))
    for i in samples.indices {
        let t = Double(i) / Double(rate)
        let loud = speech.contains { t >= $0.0 && t < $0.1 }
        samples[i] = Float.random(in: -1...1, using: &g) * (loud ? 0.3 : 0.001)
    }
    return WAVAudio(sampleRate: rate, channels: 1, samples: samples)
}

func upsample3(_ x: [Float]) -> [Float] { x.flatMap { [$0, $0, $0] } }

struct FakeTranscriber: Transcriber {
    var id = WhisperCppTranscriber.engineID
    var model = "fake"
    var words: [Word]
    var reason: String?
    let calls = Counter()

    func unavailableReason() -> String? { reason }
    func transcribe(_ speech16k: URL, language: String) throws -> Transcript {
        calls.n += 1
        return Transcript(engine: id, model: model, language: language, words: words)
    }
}

final class Counter { var n = 0 }

/// No ffmpeg in unit tests: the picture checks read no frames unless a test hands its own.
struct NoFrames: FrameSampler {
    func greyFrames(of video: URL, width: Int, height: Int) throws -> [[UInt8]] { throw CommandError(.io, "no frames in the unit tests' stand-in") }
}

/// Copies the working wav as dual-mono stereo: perfectly in sync by construction.
final class FakeCleaner: VoiceCleaner {
    var requests: [VoiceCleanRequest] = []
    func unavailableReason() -> String? { nil }
    func clean(_ r: VoiceCleanRequest) throws -> VoiceCleanReport {
        requests.append(r)
        let input = try WAVAudio.read(r.input)
        try WAVAudio(sampleRate: input.sampleRate, channels: 2, samples: input.samples.flatMap { [$0, $0] }).write16(to: r.output)
        return VoiceCleanReport(rangeGains: r.ranges.map { _ in 1.5 }, measured: Loudness(integrated: -30, truePeak: -12, range: 3, threshold: -40),
                                gain: 15, mode: "linear", denoiseSeconds: 0)
    }
}

/// A face drifting right 1 px per frame with ±3 px alternating noise, cut at frame 50.
struct FakeFaces: FaceTracker {
    func track(_ video: URL, options: FaceTrackOptions) throws -> FaceTrack {
        let frames = (0..<100).map { i -> FaceTrack.Frame in
            let noise = i % 2 == 0 ? 3.0 : -3.0
            let x = (i < 50 ? 400.0 : 200.0) + Double(i) + noise
            return FaceTrack.Frame(t: Double(i) / 30, raw: i == 10 ? nil : [x, 600 + noise, 300, 400])
        }
        return FaceTrack(video: video.path, engine: "fake", width: 1080, height: 1920, fps: 30,
                         minCutoff: options.minCutoff, beta: options.beta, cuts: [50], frames: frames)
    }
}

/// Returns a given face track (any video).
struct FixedFaces: FaceTracker {
    var track: FaceTrack
    func track(_ video: URL, options: FaceTrackOptions) throws -> FaceTrack { track }
}

struct FakeServices {
    let audio = FakeAudio()
    let cleaner = FakeCleaner()
    var words: [Word] = [Word("uno", 1.0, 1.4), Word("due", 1.5, 2.0), Word("tre", 3.0, 3.5), Word("quattro", 3.6, 4.5)]
    var tier = MachineTier.pro
    let cache = tempDir()
    /// A fixed face track instead of FakeFaces' drifting one.
    var faceTrack: FaceTrack?

    func make() -> EngineServices {
        var config = EngineConfig()
        config.cacheDirectory = cache.path
        var s = EngineServices(config: config, tier: tier, audio: audio,
                               transcribers: [FakeTranscriber(words: words), FakeTranscriber(id: WhisperXTranscriber.engineID, words: words)],
                               cleaner: cleaner, faces: faceTrack.map { FixedFaces(track: $0) as FaceTracker } ?? FakeFaces())
        s.frames = NoFrames()
        return s
    }
}

/// Engine on fakes with a project saved in a temp folder and one imported 94.7 s asset (a1).
func analysisEngine(_ fakes: FakeServices = FakeServices()) throws -> Engine {
    let e = Engine(prober: FakeProber(), services: fakes.make())
    try e.execute("project.new", params: ["name": "an", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    return e
}
