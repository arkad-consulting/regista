import Foundation

/// The teleprompter's live take markers for one recording, saved next to the movie as
/// `<name>.takes.json` and copied into the asset when it is imported. takes.list prefers them to
/// transcript alignment (the speaker's restarts were seen live), as long as they were logged
/// against the same script.
public struct LiveTakeLog: Codable, Hashable, Sendable {
    /// The script lines the markers' 1-based `sentence` refers to.
    public var sentences: [String]
    public var markers: [LiveTakeMarker]
    /// Which recognizer produced them ("SpeechTranscriber", "SFSpeechRecognizer", "simulation"…).
    public var recognizer: String?
    public var language: String?

    public init(sentences: [String], markers: [LiveTakeMarker], recognizer: String? = nil, language: String? = nil) {
        self.sentences = sentences
        self.markers = markers
        self.recognizer = recognizer
        self.language = language
    }

    /// `Registrazione 1.mov` → `Registrazione 1.takes.json`.
    public static func sidecar(for movie: URL) -> URL {
        movie.deletingPathExtension().appendingPathExtension("takes.json")
    }

    public static func read(_ url: URL) throws -> LiveTakeLog {
        try JSONDecoder().decode(LiveTakeLog.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Logged against this script: same lines, compared as words.
    public func matches(_ script: Script) -> Bool {
        sentences.count == script.lines.count && zip(sentences, script.lines).allSatisfy { TextNorm.tokens($0) == TextNorm.tokens($1) }
    }
}

extension TakeFinder {
    /// Takes from live markers: one take per marker, in recording order. With a transcript the take's
    /// words are the ones inside the marker (never past the neighbouring markers), scored against the
    /// line like `find` (WER, coverage) and cut on the envelope; without one the marker times are the cut.
    /// A take is complete when the teleprompter saw it complete and, with a transcript, its WER is low.
    public static func fromMarkers(script: Script, log: LiveTakeLog, words: [Word]?, envelope: Envelope?, assetID: String,
                                   options: TakeOptions = TakeOptions()) -> TakeSet {
        var lines = script.lines.map { TakeLine(text: $0, takes: [], auto: nil, chosen: nil) }
        let markers = log.markers.filter { lines.indices.contains($0.sentence - 1) }.sorted { $0.start < $1.start }
        let (threshold, _) = envelope?.speechThreshold() ?? (0, 0)
        let onset = { (t: Double) in envelope?.onset(near: t, threshold: threshold) ?? t }
        let offset = { (t: Double) in envelope?.offset(near: t, threshold: threshold) ?? t }
        let slack = 0.25

        for (k, m) in markers.enumerated() {
            let li = m.sentence - 1
            let target = TextNorm.tokens(script.lines[li])
            let lo = max(m.start - slack, k > 0 ? markers[k - 1].end : -Double.infinity)
            let hi = min(m.end + slack, k + 1 < markers.count ? markers[k + 1].start : Double.infinity)
            let ws = (words ?? []).filter { w in
                let mid = (w.start.seconds + w.end.seconds) / 2
                return mid >= lo && mid <= hi
            }
            let take: Take
            if !ws.isEmpty {
                let heard = ws.flatMap { TextNorm.tokens($0.text) }
                let (subs, ins, dels, good) = wordErrors(heard, target)
                let wer = round2(Double(subs + ins + dels) / Double(max(target.count, 1)))
                take = Take(start: ws.first!.start, end: ws.last!.end, text: ws.map(\.text).joined(separator: " "),
                            coverage: round2(Double(good) / Double(max(target.count, 1))), wer: wer,
                            substitutions: subs, insertions: ins, deletions: dels, fromStart: m.fromStart, toEnd: m.complete,
                            complete: m.complete && wer <= options.maxWer, longPauses: longPauses(ws, options),
                            parts: parts(ws, options, onset: onset, offset: offset))
            } else {
                let s = onset(m.start) - options.pre, e = offset(m.end) + options.post
                take = Take(start: MediaTime(seconds: m.start), end: MediaTime(seconds: m.end), text: "", coverage: m.complete ? 1 : 0,
                            wer: m.complete ? 0 : 1, substitutions: 0, insertions: 0, deletions: 0, fromStart: m.fromStart,
                            toEnd: m.complete, complete: m.complete, longPauses: [],
                            parts: [CutRange(start: MediaTime(seconds: max(s, 0)), end: MediaTime(seconds: e), note: "")])
            }
            lines[li].takes.append(take)
        }
        for li in lines.indices where !lines[li].takes.isEmpty {
            lines[li].auto = pick(lines[li].takes)
            lines[li].chosen = lines[li].auto
        }
        var set = TakeSet(assetID: assetID, options: options, lines: lines)
        set.source = "live"
        return set
    }

    /// Word-level edit distance of a reading against its line: substitutions, insertions, deletions and
    /// how many line words were read well (similar enough to count, like `find`'s "good" positions).
    static func wordErrors(_ heard: [String], _ target: [String]) -> (Int, Int, Int, Int) {
        let n = heard.count, m = target.count
        // Fewest edits; among equal edit counts, the most words read well.
        struct Cell: Comparable {
            var cost: Int, good: Int
            static func < (a: Cell, b: Cell) -> Bool { a.cost != b.cost ? a.cost < b.cost : a.good > b.good }
        }
        let same = { (i: Int, j: Int) in SequenceSimilarity.ratio(heard[i], target[j]) >= 0.75 }
        var d = [[Cell]](repeating: [Cell](repeating: Cell(cost: 0, good: 0), count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = Cell(cost: i, good: 0) }
        for j in 0...m { d[0][j] = Cell(cost: j, good: 0) }
        func diag(_ i: Int, _ j: Int) -> Cell {
            let s = same(i - 1, j - 1)
            return Cell(cost: d[i - 1][j - 1].cost + (s ? 0 : 1), good: d[i - 1][j - 1].good + (s ? 1 : 0))
        }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = min(diag(i, j), Cell(cost: d[i - 1][j].cost + 1, good: d[i - 1][j].good),
                                  Cell(cost: d[i][j - 1].cost + 1, good: d[i][j - 1].good))
                }
            }
        }
        var i = n, j = m, subs = 0, ins = 0, dels = 0, good = 0
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == diag(i, j) {
                if same(i - 1, j - 1) { good += 1 } else { subs += 1 }
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == Cell(cost: d[i - 1][j].cost + 1, good: d[i - 1][j].good) {
                ins += 1; i -= 1
            } else {
                dels += 1; j -= 1
            }
        }
        return (subs, ins, dels, good)
    }
}
