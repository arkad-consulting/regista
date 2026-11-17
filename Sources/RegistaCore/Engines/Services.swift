import Foundation

// The analysis engines are external processes (or Apple frameworks) behind these protocols, like
// `MediaProber`: commands only see the protocols, unit tests plug in fakes, and the real adapters
// read their paths from `EngineConfig`.

/// A stretch of an audio file, in its own time (nil = from the start / to the end).
public struct AudioSpan: Hashable, Sendable {
    public var url: URL
    public var start: MediaTime?
    public var end: MediaTime?
    /// Channel count of the file: mono is measured as dual-mono stereo, the way it will be exported.
    public var channels: Int

    public init(url: URL, start: MediaTime? = nil, end: MediaTime? = nil, channels: Int) {
        self.url = url
        self.start = start
        self.end = end
        self.channels = channels
    }
}

/// EBU R128 measurement.
public struct Loudness: Hashable, Sendable {
    public var integrated: Double
    public var truePeak: Double
    public var range: Double
    public var threshold: Double

    public init(integrated: Double, truePeak: Double, range: Double, threshold: Double) {
        (self.integrated, self.truePeak, self.range, self.threshold) = (integrated, truePeak, range, threshold)
    }

    public var json: JSONValue {
        ["integrated": .number(Self.round1(integrated)), "truePeak": .number(Self.round1(truePeak)),
         "range": .number(Self.round1(range)), "threshold": .number(Self.round1(threshold))]
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}

/// ffmpeg-level audio operations.
public protocol AudioToolkit {
    /// Writes the 16 kHz speech wav and the 48 kHz working wav (both mono), sample-aligned with the video.
    func extractAudio(from source: URL, channels: Int, speech: URL, working: URL) throws
    /// Loudness of the spans played one after the other (what a track sounds like).
    func loudness(of spans: [AudioSpan]) throws -> Loudness
    /// Mixes clips (edge fades, gain, gain envelope) into a 48 kHz stereo wav of `length` samples, applies the master
    /// `gain` (dB), then a limiter whose sample-peak ceiling is `ceiling` dBFS (no lookahead delay).
    func mix(_ clips: [AudioMixClip], length: Int, rate: Int, gain: Double, ceiling: Double, to output: URL) throws
}

/// Speech to words with timings.
public protocol Transcriber {
    var id: String { get }
    /// Model name recorded with the transcript (and in the cache key).
    var model: String { get }
    /// Why it cannot run, nil when it can.
    func unavailableReason() -> String?
    func transcribe(_ speech16k: URL, language: String) throws -> Transcript
}

public struct VoiceCleanRequest: Sendable {
    /// 48 kHz mono working wav of the source.
    public var input: URL
    /// Source ranges the timeline uses, in playback order (per-take level match, loudness measured on them).
    public var ranges: [(start: MediaTime, end: MediaTime)]
    public var output: URL
    /// DeepFilterNet attenuation limit, dB.
    public var attenuation: Double
    public var targetLUFS: Double
    public var truePeak: Double
    public var gate: Bool
    public var workDirectory: URL
    /// Segments further than this from the main speaker's level are gained toward it, dB (0 = off). See `LevelMatch`.
    public var levelMatch: Double = 6
    /// Largest level-match gain, dB.
    public var levelMatchMax: Double = 12
}

public struct VoiceCleanReport: Sendable {
    /// Gain applied to each range before the chain, dB.
    public var rangeGains: [Double]
    /// Timeline loudness after the chain, before normalization.
    public var measured: Loudness
    /// Normalization gain, dB.
    public var gain: Double
    /// "linear" (static gain, the loudnorm linear=true case) or "limited" (gain + true-peak limiter).
    public var mode: String
    public var denoiseSeconds: Double
    /// Main speaker level (dB, on the take-gained signal) and the speech segments with their level against it and gain.
    public var mainLevel: Double = 0
    public var levelMatch: [LevelMatch.Segment] = []

    public init(rangeGains: [Double], measured: Loudness, gain: Double, mode: String, denoiseSeconds: Double) {
        (self.rangeGains, self.measured, self.gain, self.mode, self.denoiseSeconds) = (rangeGains, measured, gain, mode, denoiseSeconds)
    }
}

/// Denoise + voice chain, producing a full-length file aligned sample for sample with the input.
public protocol VoiceCleaner {
    func unavailableReason() -> String?
    func clean(_ request: VoiceCleanRequest) throws -> VoiceCleanReport
}

public struct FaceTrackOptions: Hashable, Sendable {
    /// One-Euro filter parameters (px, Hz).
    public var minCutoff = 0.3
    public var beta = 0.01
    public var landmarks = false

    public init(minCutoff: Double = 0.3, beta: Double = 0.01, landmarks: Bool = false) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.landmarks = landmarks
    }
}

/// Per-frame face boxes of a video.
public protocol FaceTracker {
    func track(_ video: URL, options: FaceTrackOptions) throws -> FaceTrack
}

/// Person mattes of video frames (Apple Vision person segmentation in RegistaEngines).
public struct MatteRequest: Sendable {
    public var video: URL
    /// Source frame indices to segment (at `frameRate`), sorted.
    public var frames: [Int]
    public var frameRate: Double
    /// Where `%06d.png` (8-bit grey, display orientation, 255 = person) goes; existing files are kept.
    public var directory: URL

    public init(video: URL, frames: [Int], frameRate: Double, directory: URL) {
        self.video = video
        self.frames = frames
        self.frameRate = frameRate
        self.directory = directory
    }
}

public struct MatteReport: Sendable {
    public var width: Int
    public var height: Int
    /// Frames segmented now (the others were already there).
    public var segmented: Int
    /// Mean share of the frame covered by the person (0…1) over the segmented frames.
    public var coverage: Double
    public var engine: String

    public init(width: Int, height: Int, segmented: Int, coverage: Double, engine: String) {
        self.width = width
        self.height = height
        self.segmented = segmented
        self.coverage = coverage
        self.engine = engine
    }
}

public protocol PersonSegmenter {
    func segment(_ request: MatteRequest) throws -> MatteReport
}

/// Still images for a client to look at: downscaled previews and contact sheets (JPEG). Lives in
/// RegistaEngines (Core Graphics / Core Text), like the compositor.
public protocol ImageToolkit {
    /// A JPEG copy of an image scaled down to fit maxWidth × maxHeight (never enlarged). Returns its pixel size.
    func writePreview(of image: URL, maxWidth: Int, maxHeight: Int, to output: URL) throws -> (width: Int, height: Int)
    /// The images tiled in a grid, each with its label underneath, on a dark background, scaled so the
    /// sheet fits maxWidth × maxHeight (columns chosen for the largest cells); JPEG. Returns the sheet size.
    func writeContactSheet(_ images: [URL], labels: [String], maxWidth: Int, maxHeight: Int, to output: URL) throws -> (width: Int, height: Int)
    /// An SVG drawn to a PNG `width` pixels wide (height from its aspect). Returns the pixel size.
    func rasterizeSVG(_ svg: URL, width: Int, to output: URL) throws -> (width: Int, height: Int)
    /// Union of the non-transparent pixels of the images, [x, y, w, h] top-left origin (nil: all transparent).
    func alphaBounds(of images: [URL]) throws -> [Double]?
    /// The image drawn into a `width`×`height` 8-bit RGBA buffer (sRGB, alpha ignored), top-left origin (pixel checks).
    func rgba(of image: URL, width: Int, height: Int) throws -> [UInt8]
}

extension ImageToolkit {
    public func rasterizeSVG(_ svg: URL, width: Int, to output: URL) throws -> (width: Int, height: Int) {
        throw CommandError(.io, "this host cannot rasterize SVG")
    }

    public func alphaBounds(of images: [URL]) throws -> [Double]? { nil }

    public func rgba(of image: URL, width: Int, height: Int) throws -> [UInt8] {
        throw CommandError(.io, "this host cannot read image pixels")
    }
}

/// Everything a command may call outside the process. One value per engine host.
public struct EngineServices {
    public var config: EngineConfig
    public var configWarning: String?
    public var tier: MachineTier
    public var audio: AudioToolkit
    public var transcribers: [String: Transcriber]
    public var cleaner: VoiceCleaner
    /// nil when the host has no face engine (RegistaCore alone: Vision lives in RegistaEngines).
    public var faces: FaceTracker?
    /// nil when the host has no compositor (it lives in RegistaEngines, like Vision).
    public var renderer: VideoRenderer?
    /// nil when the host cannot draw still images (no inline previews, no contact sheets).
    public var images: ImageToolkit?
    /// The folders media.list and text.read may look into (an agent without file tools finds its footage there).
    public var library: MediaLibrary
    /// The running app's window and preview player (ui.screenshot, preview.frame); nil when headless.
    public var ui: UIHost?
    /// The app's open project tabs (project.list); nil when headless (the engine lists its one project).
    public var tabs: ProjectTabs?
    /// nil when the host has no person segmentation (it lives in RegistaEngines, like Vision faces).
    public var segmenter: PersonSegmenter?
    /// nil when the host has no hand pose engine (Apple Vision lives in RegistaEngines): hands.track.
    public var hands: HandTracker?
    /// nil when the host has no streaming speech recognizer (Apple Speech lives in RegistaEngines): teleprompter.simulate.
    public var speech: SpeechStreamer?
    /// Draws synthetic screen recordings (recording.synthesize); nil without RegistaEngines.
    public var screenSynth: ScreenSynthesizer?
    /// Generation providers by id (generate.*): ComfyUI, Higgsfield and VoxCPM in the standard set.
    public var generators: [String: GeneratorProvider] = [:]
    /// Where budget.json and approvals.json live (`~/Library/Application Support/Regista` in the standard set;
    /// a throwaway folder otherwise, so tests never touch the real budget).
    public var generationState = FileManager.default.temporaryDirectory.appendingPathComponent("regista-generation-\(UUID().uuidString.prefix(8))")
    /// Voice profiles (#41): `~/Library/Application Support/Regista/profiles` in the standard set; a throwaway folder
    /// otherwise, so tests never see a real voice.
    public var profiles = ProfileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("regista-profiles-\(UUID().uuidString.prefix(8))"))
    /// The editing-rule sheets (#31): `rules/` of the support folder in the standard set (`RuleBook.defaultDirectory`); a
    /// throwaway folder otherwise, so tests never write the user's sheets.
    public var rules = RuleBook(directory: FileManager.default.temporaryDirectory.appendingPathComponent("regista-rules-\(UUID().uuidString.prefix(8))"))
    /// The engines folder whose helper scripts engines.status compares with the app's copy (#61): the installer's
    /// (`EngineCatalog.enginesDirectory`) in the standard set; nil otherwise, so nothing is reported.
    public var enginesFolder: URL?
    /// The host's Cancel for waited-for generation runs (the app's jobs engine has one; nil elsewhere).
    public var cancellation: GenerationCancellation?
    /// The local ComfyUI server's node list (`/object_info`; nil when it is off), read by generate.check and before a
    /// ComfyUI run.
    public var comfyServer: () -> Data? = { ComfyCheck.fetchObjectInfo() }

    public init(config: EngineConfig, configWarning: String? = nil, tier: MachineTier, audio: AudioToolkit,
                transcribers: [Transcriber], cleaner: VoiceCleaner, faces: FaceTracker?, renderer: VideoRenderer? = nil,
                images: ImageToolkit? = nil, library: MediaLibrary = MediaLibrary()) {
        self.config = config
        self.configWarning = configWarning
        self.tier = tier
        self.audio = audio
        self.transcribers = Dictionary(uniqueKeysWithValues: transcribers.map { ($0.id, $0) })
        self.cleaner = cleaner
        self.faces = faces
        self.renderer = renderer
        self.images = images
        self.library = library
    }

    /// The process-based engines from the config file. Faces need RegistaEngines (`EngineServices.live`).
    public static func standard(faces: FaceTracker? = nil, renderer: VideoRenderer? = nil, images: ImageToolkit? = nil,
                                library: MediaLibrary = MediaLibrary()) -> EngineServices {
        let (config, warning) = EngineConfig.loadOrDefault()
        let ffmpeg = FFmpegAudio(config: config)
        var s = EngineServices(config: config, configWarning: warning, tier: MachineTier.resolve(config), audio: ffmpeg,
                               transcribers: [WhisperCppTranscriber(config: config), WhisperXTranscriber(config: config)],
                               cleaner: DeepFilterVoiceCleaner(config: config, audio: ffmpeg), faces: faces, renderer: renderer,
                               images: images, library: library)
        let generators: [GeneratorProvider] = [ComfyUIProvider(config: config), HiggsfieldProvider(config: config),
                                             VoxCPMProvider(config: config, profiles: ProfileStore(directory: ProfileStore.defaultDirectory))]
        for g in generators { s.generators[g.id] = g }
        s.generationState = Generation.defaultStateDirectory
        s.profiles = ProfileStore(directory: ProfileStore.defaultDirectory)
        s.rules = RuleBook(directory: RuleBook.defaultDirectory)
        s.enginesFolder = EngineCatalog.enginesDirectory
        return s
    }

    /// The minimum tier per transcription engine (the engine ids are manifest ids).
    public static func minimumTier(transcriber id: String) -> MachineTier {
        EngineManifest.shared.minimumTier(id)
    }
}
