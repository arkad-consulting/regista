import Foundation

/// A script rebuilt from the transcript, for takes recorded without one (a skit, an interview, an
/// improvised spot): sentences (punctuation, or pauses when there is none), and repeated readings of
/// the same sentence (a restart, a second take, a false start) folded into ONE line, so takes.list
/// finds them as takes of that line and edit.autoCut keeps the best one. Pure: no engine, no LLM.
public enum ScriptFromTranscript {
    public struct Reading: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        /// Word index range in the transcript.
        public var words: ClosedRange<Int>
    }

    public struct Line: Hashable, Sendable {
        /// The line as the script states it: the last full reading.
        public var text: String
        /// Every reading, in recording order.
        public var readings: [Reading]
    }

    /// - pause: a silence this long ends a sentence (default: 0.6 s without punctuation, 1.0 s with).
    /// - window: how many previous lines a sentence is compared with to find a repeat.
    public static func lines(_ words: [Word], language: String? = nil, pause: Double? = nil, maxWords: Int = 30,
                             window: Int = 3) -> [Line] {
        guard !words.isEmpty else { return [] }
        let marks = words.filter { $0.text.last.map { ".?!…".contains($0) } ?? false }.count
        let punctuated = words.count < 12 || marks * 30 >= words.count
        let ranges = SentenceSegmenter.split(words.map { ($0.text, $0.start.seconds, $0.end.seconds) },
                                             pause: pause ?? (punctuated ? 1.0 : 0.6), maxWords: maxWords)
        var lines: [Line] = []
        var tokens: [[String]] = []   // per line, of its current text
        for r in ranges {
            let text = words[r].map(\.text).joined(separator: " ")
            let tk = TextNorm.tokens(text, language: language)
            guard !tk.isEmpty else { continue }
            let reading = Reading(start: words[r.lowerBound].start.seconds, end: words[r.upperBound].end.seconds, text: text, words: r)
            // A repeat of one of the last lines (most recent first)?
            var match: Int?
            for li in lines.indices.reversed().prefix(window) where isRepeat(tk, tokens[li]) { match = li; break }
            if let li = match {
                lines[li].readings.append(reading)
                // The line reads like its last full reading (a false start never shortens it).
                let longest = lines[li].readings.map { TextNorm.tokens($0.text, language: language).count }.max() ?? tk.count
                if Double(tk.count) >= 0.8 * Double(longest) {
                    lines[li].text = text
                    tokens[li] = tk
                }
            } else {
                lines.append(Line(text: text, readings: [reading]))
                tokens.append(tk)
            }
        }
        for i in lines.indices { lines[i].text = clean(lines[i].text) }
        return lines
    }

    /// Two readings of the same sentence: similar overall (token LCS ratio ≥ 0.6), or one is the
    /// beginning of the other (a false start of ≥ 2 words), or one contains ≥ 80% of the other (≥ 4 words).
    static func isRepeat(_ a: [String], _ b: [String]) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard !short.isEmpty else { return false }
        if short.count >= 2, Array(long.prefix(short.count)) == short { return true }
        let l = lcs(a, b)
        if 2 * Double(l) / Double(a.count + b.count) >= 0.6 { return true }
        return short.count >= 4 && Double(l) / Double(short.count) >= 0.8
    }

    static func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() { cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j]) }
            prev = cur
        }
        return prev[b.count]
    }

    /// A script line: single spaces, capital first letter, closing punctuation kept.
    static func clean(_ text: String) -> String {
        var t = text.split(separator: " ").joined(separator: " ")
        if let f = t.first, f.isLowercase { t = f.uppercased() + t.dropFirst() }
        return t
    }

    /// Loudness of each line's readings against the take's speech (median dB of the speech frames,
    /// relative to all the speech): a voice far below 0 is off-mic — another speaker, or chatter.
    public static func relativeLevels(_ lines: [Line], envelope: Envelope) -> [Double] {
        let (threshold, _) = envelope.speechThreshold(aboveFloor: 6)   // low enough to keep a quiet second voice
        func speech(_ a: Double, _ b: Double) -> [Double] {
            let f0 = max(envelope.frame(a), 0), f1 = min(envelope.frame(b), envelope.db.count)
            return f0 < f1 ? envelope.db[f0..<f1].filter { $0 >= threshold } : []
        }
        let all = lines.flatMap { $0.readings.flatMap { speech($0.start, $0.end) } }
        let reference = Envelope.percentile(all, 50)
        return lines.map { l in
            let v = l.readings.flatMap { speech($0.start, $0.end) }
            return v.isEmpty ? 0 : ((Envelope.percentile(v, 50) - reference) * 10).rounded() / 10
        }
    }
}
