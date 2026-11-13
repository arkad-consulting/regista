import Foundation

/// One update of a streaming speech recognizer, as the teleprompter's take tracker consumes it.
public struct SpeechHypothesis: Codable, Sendable {
    /// Everything heard in this epoch, finalized words first (with times), then the volatile tail.
    public var words: [HeardWord]
    /// Changes when the recognizer starts over (a new recognition task): the word list restarts.
    public var epoch: Int
    /// Stream seconds of audio fed when this update arrived: "now" for the tracker.
    public var audioTime: Double

    public init(words: [HeardWord], epoch: Int, audioTime: Double) {
        self.words = words
        self.epoch = epoch
        self.audioTime = audioTime
    }
}

public struct SpeechStreamResult: Sendable {
    /// "DictationTranscriber", "SpeechTranscriber" or "SFSpeechRecognizer".
    public var engine: String
    public var locale: String
    /// The finalized words with their times (stream seconds).
    public var words: [Word]
    public var audioSeconds: Double
    public var wallSeconds: Double

    public init(engine: String, locale: String, words: [Word], audioSeconds: Double, wallSeconds: Double) {
        self.engine = engine
        self.locale = locale
        self.words = words
        self.audioSeconds = audioSeconds
        self.wallSeconds = wallSeconds
    }
}

/// A live recognizer driven from a file: what teleprompter.simulate uses to replay a take as if the
/// speaker were in front of the teleprompter.
public protocol SpeechStreamer: Sendable {
    /// Feeds `file` to the live recognizer in short buffers at `speed`× real time (1 = live) and calls
    /// `onUpdate` for every hypothesis; returns the finalized transcript. `engine` picks a recognizer
    /// by name (nil: the one the teleprompter uses).
    func stream(file: URL, locale: String, engine: String?, speed: Double, contextualStrings: [String],
                onUpdate: @escaping @Sendable (SpeechHypothesis) -> Void) throws -> SpeechStreamResult
}
