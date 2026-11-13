import Foundation

/// One word of the teleprompter script.
public struct ScriptToken: Hashable, Sendable {
    /// Normalized form used for matching (lowercase, no accents, no punctuation).
    public let key: String
    /// Range in the original script (UTF-16 offsets, ready for NSString / TextKit).
    public let range: NSRange
}

/// Follows a speaker through a script from live speech-recognition hypotheses.
///
/// Feed it the words recognized so far (the whole current hypothesis, as the recognizer
/// reports it): it finds where the most recent words sit in the script and moves `cursor`
/// forward. When the latest words don't belong to the script the state becomes `.offScript`
/// and the cursor stays put until the speaker picks the text up again, even further ahead.
public struct ScriptAligner: Sendable {
    public enum State: Sendable, Equatable { case waiting, onScript, offScript }

    public let tokens: [ScriptToken]
    /// Number of script words already read: the next word to read is `tokens[cursor]`.
    public private(set) var cursor = 0
    public private(set) var state: State = .waiting

    /// How many trailing unmatched words make a digression.
    public var offScriptWords = 3

    private let tailLength = 8
    private let lookBehind = 12
    private let lookAhead = 40

    /// The heard word (index into the keys of the last `ingest`) and the script token it matched when
    /// the cursor last moved, with the number of consecutive matched words ending there: lets a caller
    /// timestamp what was read and see where the reading started.
    public private(set) var lastMatch: (heard: Int, token: Int, run: Int)?

    public init(script: String) {
        tokens = Self.tokenize(script)
    }

    public init(tokens: [ScriptToken]) {
        self.tokens = tokens
    }

    public var isFinished: Bool { cursor >= tokens.count }

    /// Manual re-anchoring (e.g. the user clicks a word).
    public mutating func jump(to index: Int) {
        cursor = min(max(0, index), tokens.count)
        state = .waiting
    }

    /// Processes the current recognition hypothesis. Returns true if the cursor moved.
    @discardableResult
    public mutating func ingest(heard words: [String]) -> Bool {
        ingest(keys: words.flatMap(Self.keys(of:)))
    }

    /// Same as `ingest(heard:)` on already normalized keys (`keys(of:)`).
    @discardableResult
    public mutating func ingest(keys heard: [String]) -> Bool {
        guard !heard.isEmpty, !tokens.isEmpty else { return false }
        let tail = Array(heard.suffix(tailLength))

        guard let best = bestAlignment(tail) else {
            if tail.count >= offScriptWords { state = .offScript }
            return false
        }

        let trailingUnmatched = tail.count - 1 - best.tailEnd
        state = trailingUnmatched >= offScriptWords ? .offScript : .onScript

        // Only the freshest words may move the cursor: an alignment that ends early in the
        // tail is old speech, already accounted for.
        guard trailingUnmatched <= 1 else { return false }
        let target = best.scriptEnd + 1
        let delta = target - cursor
        let accept: Bool
        if delta > 12 {
            accept = best.matches >= 3 && best.run >= 2   // skipped ahead: be sure
        } else if delta > 0 {
            accept = best.run >= 2
        } else if delta < -1 {
            accept = best.matches >= 4          // went back to re-read: be very sure
        } else {
            accept = false
        }
        guard accept else { return false }
        cursor = target
        lastMatch = (heard.count - tail.count + best.tailEnd, best.scriptEnd, best.run)
        return true
    }

    // MARK: - Local alignment (Smith-Waterman on words, fuzzy match)

    private struct Alignment {
        var score: Double
        var matches: Int
        /// Consecutive matched words at the end of the alignment.
        var run: Int
        var tailEnd: Int
        var scriptEnd: Int
    }

    private func bestAlignment(_ tail: [String]) -> Alignment? {
        let lo = max(0, cursor - lookBehind)
        let hi = min(tokens.count, cursor + lookAhead)
        guard lo < hi else { return nil }
        let window = tokens[lo..<hi].map(\.key)

        let rows = tail.count + 1, cols = window.count + 1
        var score = [Double](repeating: 0, count: rows * cols)
        var matches = [Int](repeating: 0, count: rows * cols)
        var run = [Int](repeating: 0, count: rows * cols)
        let gap = 1.0, mismatch = 1.5

        var best: Alignment?
        var bestRank = -Double.infinity
        for i in 1..<rows {
            for j in 1..<cols {
                let s = Self.similarity(tail[i - 1], window[j - 1])
                let diagIdx = (i - 1) * cols + (j - 1)
                let diag = score[diagIdx] + (s > 0 ? 2 * s : -mismatch)
                let up = score[(i - 1) * cols + j] - gap      // extra heard word
                let left = score[i * cols + (j - 1)] - gap    // skipped script word
                let idx = i * cols + j
                if diag >= up, diag >= left, diag > 0 {
                    score[idx] = diag
                    matches[idx] = matches[diagIdx] + (s > 0 ? 1 : 0)
                    run[idx] = s > 0 ? run[diagIdx] + 1 : 0
                } else if up >= left, up > 0 {
                    score[idx] = up
                    matches[idx] = matches[(i - 1) * cols + j]
                } else if left > 0 {
                    score[idx] = left
                    matches[idx] = matches[i * cols + (j - 1)]
                }
                // A valid end point is a real match of this heard word with this script word.
                guard s > 0, matches[idx] >= 2 else { continue }
                let scriptEnd = lo + j - 1
                // Prefer recent words, then the position closest to where we are.
                let rank = score[idx] + Double(i) * 0.5 - 0.03 * Double(abs(scriptEnd + 1 - cursor))
                if rank > bestRank {
                    bestRank = rank
                    best = Alignment(score: score[idx], matches: matches[idx], run: run[idx], tailEnd: i - 1, scriptEnd: scriptEnd)
                }
            }
        }
        return best
    }

    // MARK: - Text normalization

    /// Splits the script into words keeping their position in the original text.
    public static func tokenize(_ script: String) -> [ScriptToken] {
        let ns = script as NSString
        var out: [ScriptToken] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { sub, range, _, _ in
            guard let sub else { return }
            // "dell'azienda" is one word for the enumerator: keep each part as its own token.
            var offset = 0
            for part in sub.split(separator: "'", omittingEmptySubsequences: false).flatMap({ $0.split(separator: "’", omittingEmptySubsequences: false) }) {
                let len = (String(part) as NSString).length
                // "9,2" is read "nove virgola due": three tokens on the same characters.
                for key in partKeys(String(part)) {
                    out.append(ScriptToken(key: key, range: NSRange(location: range.location + offset, length: len)))
                }
                offset += len + 1
            }
        }
        return out
    }

    /// Normalized match keys for one recognized word (it may contain apostrophes).
    public static func keys(of word: String) -> [String] {
        word.split(whereSeparator: { $0 == "'" || $0 == "’" || $0.isWhitespace })
            .flatMap { partKeys(String($0)) }
    }

    /// Match keys of one apostrophe-free word: digits are spelled out (recognizers write "9,2" and
    /// "11.000", scripts often spell them), so both sides compare as words.
    static func partKeys(_ part: String) -> [String] {
        if part.contains(where: \.isNumber) { return TextNorm.tokens(part) }
        let key = normalize(part)
        return key.isEmpty ? [] : [key]
    }

    public static func normalize(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// 1 = identical, 0 = different. Short words must match exactly; longer ones tolerate
    /// recognition slips ("perché"/"perche", "fatturato"/"fatturati").
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard min(a.count, b.count) >= 4 else { return 0 }
        let d = levenshtein(Array(a), Array(b))
        let sim = 1 - Double(d) / Double(max(a.count, b.count))
        return sim >= 0.72 ? sim : 0
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
