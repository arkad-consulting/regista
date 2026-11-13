import Foundation

// Results of the analysis engines, stored in the project next to the asset they describe.
// Small results live in project.json (transcript, takes); bulky ones (per-frame face boxes)
// live in a sidecar file the project references.

public struct AssetAnalysis: Codable, Hashable, Sendable {
    public var audio: ExtractedAudio?
    public var transcript: Transcript?
    public var faces: FaceTrackSummary?
    /// Person matte frames (matte.track): behind-the-subject layers are drawn under them.
    public var matte: MatteTrack?
    /// Hand poses over a range (hands.track): overlays can follow a palm (clip.follow).
    public var hands: HandTrackSummary?
    /// The teleprompter's live take markers for this recording (its `.takes.json` sidecar, or takes.live).
    public var liveTakes: LiveTakeLog?

    public init(audio: ExtractedAudio? = nil, transcript: Transcript? = nil, faces: FaceTrackSummary? = nil) {
        self.audio = audio
        self.transcript = transcript
        self.faces = faces
    }
}

/// Reference to the person-matte frames of a video asset: one 8-bit grey PNG per source frame (display
/// orientation, 255 = person), smoothed over neighbouring frames, in a sidecar folder of the project.
public struct MatteTrack: Codable, Hashable, Sendable {
    /// Folder with `%06d.png` frames.
    public var directory: String
    public var width: Int
    public var height: Int
    /// The asset's frame rate (frame index = source seconds × frameRate).
    public var frameRate: Double
    /// Inclusive source frame ranges that have a matte, merged and sorted.
    public var ranges: [[Int]]
    public var engine: String

    public var frameCount: Int { ranges.reduce(0) { $0 + $1[1] - $1[0] + 1 } }

    /// Frame index shown at a source time.
    public func index(at t: MediaTime) -> Int { Int((t.seconds * frameRate + 1e-3).rounded(.down)) }

    public func has(_ i: Int) -> Bool { ranges.contains { $0[0] <= i && i <= $0[1] } }

    /// The matte file of the frame shown at source time `t`, nil when it was not tracked.
    public func file(at t: MediaTime) -> String? {
        let i = index(at: t)
        return has(i) ? URL(fileURLWithPath: directory).appendingPathComponent(String(format: "%06d.png", i)).path : nil
    }

    /// Ranges of a set of indices.
    public static func ranges(_ indices: Set<Int>) -> [[Int]] {
        var out: [[Int]] = []
        for i in indices.sorted() {
            if let last = out.last, last[1] + 1 == i { out[out.count - 1][1] = i } else { out.append([i, i]) }
        }
        return out
    }
}

/// Audio pulled out of a media file, sample-aligned with its video (t = 0 is the first video frame).
public struct ExtractedAudio: Codable, Hashable, Sendable {
    /// 16 kHz mono 16-bit wav: what speech engines and the energy envelope read.
    public var speech: String
    /// 48 kHz mono 16-bit wav (0.5 L + 0.5 R): what the voice chain reads.
    public var working: String
}

/// How a derived asset was made (cleaned voice from a camera file…).
public struct AssetOrigin: Codable, Hashable, Sendable {
    public var assetID: String
    public var process: String
}

/// Words with timings, in the time base of the asset (seconds from its start).
public struct Transcript: Codable, Hashable, Sendable {
    public var engine: String
    public var model: String
    public var language: String
    public var words: [Word]

    public init(engine: String, model: String, language: String, words: [Word]) {
        self.engine = engine
        self.model = model
        self.language = language
        self.words = words
    }

    public var text: String { words.map(\.text).joined(separator: " ") }
}

public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var start: MediaTime
    public var end: MediaTime
    /// Engine confidence 0…1 when it reports one.
    public var probability: Double?

    public init(text: String, start: MediaTime, end: MediaTime, probability: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }

    public init(_ text: String, _ start: Double, _ end: Double) {
        self.init(text: text, start: MediaTime(seconds: start), end: MediaTime(seconds: end))
    }
}

/// The script the speaker read, one line per take ("una riga = una ripresa").
public struct Script: Codable, Hashable, Sendable {
    public var lines: [String]

    /// The text given to script.set / script.prepare, markup included: what the teleprompter shows
    /// (`PromptScript`). nil for scripts saved before it existed.
    public var prompt: String?
    /// Keywords flagged in the prompt (`*word*`), display form: the teleprompter emphasizes them and
    /// captions.generate highlights them when given no keywords of its own.
    public var keywords: [String]?

    public init(lines: [String], prompt: String? = nil, keywords: [String]? = nil) {
        self.lines = lines
        self.prompt = prompt
        self.keywords = keywords
    }
}

/// Reference to a face-track sidecar plus the numbers worth seeing without opening it.
public struct FaceTrackSummary: Codable, Hashable, Sendable {
    /// Sidecar JSON with one entry per frame (see `FaceTrack`).
    public var path: String
    public var frames: Int
    public var detected: Int
    public var cuts: Int
    /// Smoothed box centre, RMS of the frame-to-frame second difference (px): the shake.
    public var jitterPx: Double
    public var rawJitterPx: Double
}
