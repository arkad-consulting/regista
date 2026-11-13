import Foundation

// Live take tracking for the teleprompter: follows the speaker through a `PromptScript`, notices
// when they start the current sentence again (jumps back to its start), and logs every reading of
// every sentence as a take marker with recording timestamps. The markers are saved next to the
// recording and preferred by takes.list over transcript alignment. Pure and deterministic: fed by
// any recognizer through `update(_:epoch:now:)`.

/// One recognized word; times in the caller's clock (recording seconds) when the recognizer knows them.
public struct HeardWord: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double?
    public var end: Double?

    public init(_ text: String, start: Double? = nil, end: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One reading of one script sentence, as the teleprompter saw it live.
public struct LiveTakeMarker: Codable, Hashable, Sendable {
    /// 1-based script line.
    public var sentence: Int
    /// 1-based, per sentence, in recording order.
    public var take: Int
    /// Recording seconds of the first and last word read.
    public var start: Double
    public var end: Double
    /// Started at the sentence start, reached its end and was not discarded.
    public var complete: Bool
    public var fromStart: Bool
    /// The speaker said the redo command ("rifaccio") during this take.
    public var discarded: Bool

    public init(sentence: Int, take: Int, start: Double, end: Double, complete: Bool, fromStart: Bool = true, discarded: Bool = false) {
        self.sentence = sentence
        self.take = take
        self.start = start
        self.end = end
        self.complete = complete
        self.fromStart = fromStart
        self.discarded = discarded
    }
}

public enum VoiceCommand: String, Codable, Sendable, CaseIterable {
    /// Discard the current take and go back to the start of its sentence.
    case redo
    /// Stop the recording.
    case stop
}

/// Spoken commands: a phrase fires when it is the newest thing heard and is not the script's next words.
public struct VoiceCommandSet: Codable, Hashable, Sendable {
    public var redo: [String]
    public var stop: [String]

    public init(redo: [String], stop: [String]) {
        self.redo = redo
        self.stop = stop
    }

    public static let italian = VoiceCommandSet(redo: ["rifaccio", "la rifaccio"], stop: ["stop"])
    public static let french = VoiceCommandSet(redo: ["je recommence", "je la refais"], stop: ["stop"])
    public static let english = VoiceCommandSet(redo: ["let me redo", "redo that"], stop: ["stop"])
    public static let portuguese = VoiceCommandSet(redo: ["vou refazer", "refaço"], stop: ["stop"])

    /// Defaults for a recognizer language ("it", "fr", "en", "pt", or a locale such as "fr-FR"); Italian otherwise.
    public static func defaults(language: String?) -> VoiceCommandSet {
        let l = (language ?? "").lowercased()
        if l.hasPrefix("fr") { return .french }
        if l.hasPrefix("en") { return .english }
        if l.hasPrefix("pt") { return .portuguese }
        return .italian
    }

    /// The command whose phrase ends `keys` (normalized heard words), longest phrase first, with its length in keys.
    public func match(_ keys: ArraySlice<String>) -> (command: VoiceCommand, length: Int)? {
        let candidates = [(VoiceCommand.redo, redo), (.stop, stop)].flatMap { cmd, phrases in
            phrases.map { (cmd, ScriptAligner.keys(of: $0)) }
        }.filter { !$0.1.isEmpty }.sorted { $0.1.count > $1.1.count }
        for (cmd, phrase) in candidates where keys.count >= phrase.count && Array(keys.suffix(phrase.count)) == phrase {
            return (cmd, phrase.count)
        }
        return nil
    }
}

/// Speaking pace from the cursor's progress: words per minute over the last seconds, pauses left out.
public struct PaceMeter: Sendable {
    public enum Band: String, Sendable { case slow, good, fast }

    /// The pace to aim at.
    public static let target: ClosedRange<Double> = 150...170
    /// Outside these the indicator changes colour (a gentle margin around the target).
    public static let slowBelow = 135.0, fastAbove = 185.0

    public var window = 12.0
    /// Gaps longer than this between two advances are pauses: they count as this much speaking time.
    public var maxGap = 1.0
    private var samples: [(t: Double, words: Int)] = []

    public init() {}

    public mutating func record(at t: Double, words: Int) {
        samples.append((t, words))
        samples.removeAll { $0.t < t - window }
    }

    public mutating func reset() { samples = [] }

    /// nil until there is enough speech in the window, or after a few seconds of silence.
    public func wordsPerMinute(at now: Double) -> Double? {
        let recent = samples.filter { $0.t >= now - window && $0.t <= now }
        guard let last = recent.last, now - last.t <= 4, recent.count >= 3 else { return nil }
        var time = 0.0, words = 0
        for i in recent.indices.dropFirst() {
            time += min(recent[i].t - recent[i - 1].t, maxGap)
            words += recent[i].words
        }
        guard time >= 2, words >= 5 else { return nil }
        return Double(words) / time * 60
    }

    public static func band(_ wpm: Double) -> Band {
        wpm < slowBelow ? .slow : wpm > fastAbove ? .fast : .good
    }
}

public struct TakeTracker: Sendable {
    public enum Event: Equatable, Sendable {
        /// The cursor (next token to read) moved.
        case moved(Int)
        /// The speaker started this sentence (0-based) again: the cursor went back to its start.
        case restart(sentence: Int)
        case command(VoiceCommand)
        /// A take ended (the next one started, a restart, a command, or `finish`).
        case take(LiveTakeMarker)
    }

    public let script: PromptScript
    public private(set) var aligner: ScriptAligner
    public private(set) var markers: [LiveTakeMarker] = []
    public private(set) var pace = PaceMeter()
    public var commands: VoiceCommandSet
    /// Words that restart a sentence must be this long together (or be three or more words): two
    /// short common words ("il sito") are not enough.
    public var minRestartChars = 7
    /// How long after a word is spoken a recognizer without word times reports it (seconds).
    public var assumedLatency = 0.35

    private struct OpenTake {
        var sentence: Int
        var fromStart: Bool
        var reachedEnd = false
        var discarded = false
        var startWord: Int
        var endWord: Int
        /// The words' match keys, to find them again after the recognizer revises its hypothesis.
        var startText = ""
        var endText = ""
        var start: Double
        var end: Double
        var epoch: Int
    }

    private var open: OpenTake?
    /// The words behind the last closed markers: their times are refined when the recognizer finalizes them.
    private var closed: [(marker: Int, take: OpenTake)] = []
    private var heard: [HeardWord] = []
    private var keys: [String] = []
    private var keyWord: [Int] = []
    private var firstSeen: [Double] = []
    private var epoch = 0
    /// Key indices (in the current epoch) already used by a restart / a command: never fire twice.
    private var restartUsed = -1
    private var commandUsed = -1

    /// Every key of the script: split recognitions ("P hp") are glued back when they make one.
    private let scriptKeys: Set<String>

    public init(script: PromptScript, commands: VoiceCommandSet = .italian) {
        self.script = script
        self.scriptKeys = Set(script.tokens.map(\.key))
        self.aligner = ScriptAligner(tokens: script.tokens)
        self.commands = commands
    }

    public var cursor: Int { aligner.cursor }
    public var state: ScriptAligner.State { aligner.state }
    /// Sentence (0-based) the speaker is in: the open take's, else the cursor's.
    public var currentSentence: Int? { open?.sentence ?? script.sentence(at: cursor) }

    // MARK: Recognition input

    /// Processes the recognizer's current hypothesis: every word heard so far in this recognition
    /// `epoch` (a new task restarts the list: pass a new epoch). `now` is the time the hypothesis
    /// arrived, in the same clock as the word times.
    @discardableResult
    public mutating func update(_ words: [HeardWord], epoch e: Int, now: Double) -> [Event] {
        if e != epoch {
            epoch = e
            firstSeen = []
            heard = []
            restartUsed = -1
            commandUsed = -1
        }
        firstSeen = Self.carryFirstSeen(old: heard, seen: firstSeen, new: words, now: now)
        heard = words
        (keys, keyWord) = Self.keys(of: words, scriptKeys: scriptKeys)
        guard !keys.isEmpty, !script.tokens.isEmpty else { return [] }

        var events: [Event] = []
        defer { refreshOpenTimes() }

        // Spoken commands.
        if let (cmd, len) = commands.match(keys[...]), keys.count - len > commandUsed, !isScriptNear(Array(keys.suffix(len))) {
            commandUsed = keys.count - 1
            restartUsed = max(restartUsed, keys.count - 1)
            events.append(.command(cmd))
            if cmd == .redo { events += restart(discard: true, at: startTime(ofWord: keyWord[keys.count - len])) }
            return events
        }

        // The speaker started the current (or just finished) sentence again.
        if let (sentence, k) = restartCandidate() {
            let first = keys.count - k
            restartUsed = first
            if let t = closeOpen() { events.append(.take(t)) }
            let range = script.sentences[sentence].tokens
            aligner.jump(to: range.lowerBound + k)
            open = OpenTake(sentence: sentence, fromStart: true, startWord: keyWord[first], endWord: keyWord[keys.count - 1],
                            start: startTime(ofWord: keyWord[first]), end: endTime(ofWord: keyWord[keys.count - 1]), epoch: epoch)
            labelOpen()
            events.append(.restart(sentence: sentence))
            events.append(.moved(aligner.cursor))
            return events
        }

        let before = aligner.cursor
        guard aligner.ingest(keys: keys), let match = aligner.lastMatch else { return events }
        let after = aligner.cursor
        let t = match.token
        let sentence = script.tokenSentence[t]
        let range = script.sentences[sentence].tokens
        let word = keyWord[match.heard]
        if open == nil || open!.sentence != sentence || after < before {
            if let m = closeOpen() { events.append(.take(m)) }
            // First token of this reading: the start of the matched run, not before where the cursor was.
            let first = max(range.lowerBound, t - max(match.run - 1, 0), after > before ? before : 0)
            let startKey = max(0, match.heard - (t - first))
            open = OpenTake(sentence: sentence, fromStart: first - range.lowerBound <= 1, startWord: keyWord[startKey], endWord: word,
                            start: startTime(ofWord: keyWord[startKey]), end: endTime(ofWord: word), epoch: epoch)
        }
        open!.endWord = word
        open!.end = endTime(ofWord: word)
        labelOpen()
        if t >= range.upperBound - 2 { open!.reachedEnd = true }
        if (1...3).contains(after - before) { pace.record(at: now, words: after - before) }
        events.append(.moved(after))
        return events
    }

    // MARK: Manual control (keyboard, pedal, clicks)

    /// Back to the start of the sentence being read ("rifaccio" with `discard`, the pedal without).
    @discardableResult
    public mutating func restart(discard: Bool, at now: Double) -> [Event] {
        guard let sentence = currentSentence else { return [] }
        if discard { open?.discarded = true }
        var events: [Event] = []
        if let m = closeOpen() { events.append(.take(m)) }
        aligner.jump(to: script.sentences[sentence].tokens.lowerBound)
        restartUsed = max(restartUsed, keys.count - 1)
        events.append(.restart(sentence: sentence))
        events.append(.moved(aligner.cursor))
        return events
    }

    /// Moves to the start of a sentence (0-based, clamped): next / previous with the pedal.
    @discardableResult
    public mutating func jump(toSentence index: Int) -> [Event] {
        guard !script.sentences.isEmpty else { return [] }
        let i = min(max(index, 0), script.sentences.count - 1)
        return jump(toToken: script.sentences[i].tokens.lowerBound)
    }

    /// Re-anchors on a token (a click on a word).
    @discardableResult
    public mutating func jump(toToken index: Int) -> [Event] {
        var events: [Event] = []
        if let m = closeOpen() { events.append(.take(m)) }
        aligner.jump(to: index)
        restartUsed = max(restartUsed, keys.count - 1)
        events.append(.moved(aligner.cursor))
        return events
    }

    /// Ends the session (recording stopped): closes the take being read. Returns every marker.
    @discardableResult
    public mutating func finish() -> [LiveTakeMarker] {
        _ = closeOpen()
        refreshOpenTimes()
        return markers
    }

    // MARK: Internals

    /// Sentence (0-based) whose first words are the newest words heard, and how many words matched.
    private func restartCandidate() -> (Int, Int)? {
        let cur = aligner.cursor
        guard let s = script.sentence(at: cur) else { return nil }
        let start = script.sentences[s].tokens.lowerBound
        // The sentence being read once a few words are in, or the one just finished.
        var candidates: [Int] = []
        if cur > start + 1 || cur >= script.tokens.count { candidates.append(s) }
        else if s > 0 { candidates.append(s - 1) }
        if let o = open?.sentence, !candidates.contains(o), o <= s { candidates.append(o) }
        for c in candidates {
            let range = script.sentences[c].tokens
            for k in 2...max(2, min(8, range.count)) where range.count >= k {
                let tail = Array(keys.suffix(k))
                guard keys.count - k > restartUsed, tail.count == k else { break }
                let prefix = range.lowerBound..<(range.lowerBound + k)
                guard zip(tail, prefix).allSatisfy({ ScriptAligner.similarity($0, script.tokens[$1].key) > 0 }) else { continue }
                let chars = tail.reduce(0) { $0 + $1.count }
                guard k >= 3 || chars >= minRestartChars else { continue }
                // Not a restart: still before those words, or the script itself continues with them.
                guard cur > prefix.upperBound, !isScriptAhead(tail) else { break }
                // Ambiguous with reading on into the next sentence: reading on wins.
                if c != s, matchesStart(of: s, tail) { break }
                return (c, k)
            }
        }
        return nil
    }

    private func matchesStart(of sentence: Int, _ tail: [String]) -> Bool {
        let range = script.sentences[sentence].tokens
        guard range.count >= tail.count else { return false }
        return zip(tail, range.lowerBound..<(range.lowerBound + tail.count)).allSatisfy { ScriptAligner.similarity($0, script.tokens[$1].key) > 0 }
    }

    /// The script's next words (from the cursor) are exactly these.
    private func isScriptAhead(_ tail: [String]) -> Bool {
        let cur = aligner.cursor
        guard cur + tail.count <= script.tokens.count else { return false }
        return zip(tail, cur..<(cur + tail.count)).allSatisfy { $0 == script.tokens[$1].key }
    }

    /// The script has these words right around the cursor: a command word that is part of the text.
    /// When each word of the new hypothesis was first heard: the unchanged prefix keeps its times, a
    /// revised tail keeps the times of the words it still has (looked up a few places around), new
    /// words are heard `now`.
    static func carryFirstSeen(old: [HeardWord], seen: [Double], new: [HeardWord], now: Double) -> [Double] {
        var prefix = 0
        while prefix < min(old.count, new.count, seen.count), old[prefix].text == new[prefix].text { prefix += 1 }
        var out = Array(seen.prefix(prefix))
        var next = prefix   // old words before this one are taken: keep the order
        for j in prefix..<new.count {
            let lo = max(next, j - 3), hi = min(min(old.count, seen.count) - 1, j + 3)
            if lo <= hi, let k = (lo...hi).first(where: { old[$0].text == new[j].text }) {
                next = k + 1
                out.append(seen[k])
            } else {
                out.append(now)
            }
        }
        return out
    }

    /// Match keys of the heard words, with the index of the word each comes from. Recognizers split
    /// some things the script writes as one word: "9" "," "2" (a number) and "P" "hp" (an acronym).
    static func keys(of words: [HeardWord], scriptKeys: Set<String>) -> ([String], [Int]) {
        var texts: [(String, Int)] = []
        var i = 0
        while i < words.count {
            var t = words[i].text
            let j = i
            while i + 2 < words.count, t.last?.isNumber == true, [",", "."].contains(words[i + 1].text),
                  words[i + 2].text.first?.isNumber == true {
                t += words[i + 1].text + words[i + 2].text
                i += 2
            }
            texts.append((t, j))
            i += 1
        }
        var keys: [String] = [], owner: [Int] = []
        for (t, w) in texts {
            let k = ScriptAligner.keys(of: t)
            keys += k
            owner += Array(repeating: w, count: k.count)
        }
        var k = 0
        while k + 1 < keys.count {
            if !scriptKeys.contains(keys[k]) || !scriptKeys.contains(keys[k + 1]) {
                if scriptKeys.contains(keys[k] + keys[k + 1]) {
                    keys[k] += keys[k + 1]
                    keys.remove(at: k + 1)
                    owner.remove(at: k + 1)
                    continue
                }
            }
            k += 1
        }
        return (keys, owner)
    }

    private func isScriptNear(_ tail: [String]) -> Bool {
        let cur = aligner.cursor
        let lo = max(0, cur - tail.count - 1), hi = min(script.tokens.count - tail.count, cur + 2)
        guard lo <= hi else { return false }
        return (lo...hi).contains { p in zip(tail, p..<(p + tail.count)).allSatisfy { $0 == script.tokens[$1].key } }
    }

    /// Remembers the open take's first and last words as text (indices shift when the recognizer revises).
    private mutating func labelOpen() {
        guard var o = open, o.epoch == epoch, o.startWord < heard.count, o.endWord < heard.count else { return }
        if o.startText.isEmpty { o.startText = ScriptAligner.keys(of: heard[o.startWord].text).joined() }
        o.endText = ScriptAligner.keys(of: heard[o.endWord].text).joined()
        open = o
    }

    private mutating func closeOpen() -> LiveTakeMarker? {
        guard let o = open else { return nil }
        open = nil
        let take = markers.filter { $0.sentence == o.sentence + 1 }.count + 1
        let m = LiveTakeMarker(sentence: o.sentence + 1, take: take, start: o.start, end: max(o.end, o.start),
                               complete: o.fromStart && o.reachedEnd && !o.discarded, fromStart: o.fromStart, discarded: o.discarded)
        markers.append(m)
        closed.append((markers.count - 1, o))
        if closed.count > 3 { closed.removeFirst() }
        return m
    }

    /// Word times improve as the recognizer finalizes: re-read them while the take is open, and for
    /// the last closed takes once their words carry the recognizer's own times.
    private mutating func refreshOpenTimes() {
        // A finalized result can merge or split words: find the same word near its old index.
        if var o = open, o.epoch == epoch {
            if let i = timedWord(near: o.startWord, like: o.startText, at: o.start) { o.startWord = i; o.start = heard[i].start! }
            if let i = timedWord(near: o.endWord, like: o.endText, at: o.end) { o.endWord = i; o.end = max(heard[i].end ?? heard[i].start!, o.start) }
            open = o
        }
        for (k, c) in closed.enumerated().reversed() where c.take.epoch == epoch {
            let s = timedWord(near: c.take.startWord, like: c.take.startText, at: markers[c.marker].start)
            let e = timedWord(near: c.take.endWord, like: c.take.endText, at: markers[c.marker].end)
            if let s { markers[c.marker].start = heard[s].start!; closed[k].take.startWord = s }
            if let e { markers[c.marker].end = max(heard[e].end ?? heard[e].start!, markers[c.marker].start); closed[k].take.endWord = e }
            if s != nil, e != nil { closed.remove(at: k) }
        }
    }

    /// The timed word with this text closest to `time`, within a few words of `index`.
    private func timedWord(near index: Int, like text: String, at time: Double) -> Int? {
        let lo = max(0, index - 6), hi = min(heard.count - 1, index + 6)
        guard lo <= hi else { return nil }
        return (lo...hi).filter { heard[$0].start != nil && ScriptAligner.keys(of: heard[$0].text).joined() == text }
            .min { abs(heard[$0].start! - time) < abs(heard[$1].start! - time) }
            .flatMap { abs(heard[$0].start! - time) < 3 ? $0 : nil }
    }

    private func startTime(ofWord i: Int) -> Double {
        heard[i].start ?? (firstSeen[i] - assumedLatency)
    }

    private func endTime(ofWord i: Int) -> Double {
        heard[i].end ?? (firstSeen[i] - assumedLatency + 0.25)
    }
}

/// Where to draw the highlight between two recognizer updates: the confirmed cursor trails the
/// voice by the recognizer's delay (~0.3-0.5 s), so while the speaker reads steadily the highlight
/// runs ahead at their pace — at most `maxWords`, never past a pause (breath mark, punctuation)
/// or the end of the sentence, and not at all once the cursor has stalled or they went off script.
public struct CursorLead: Sendable {
    public var maxWords = 2
    /// How far the recognizer typically trails the voice (seconds).
    public var latency = 0.35
    /// No lead when the cursor has not moved for this long (a pause).
    public var stall = 0.9

    public init() {}

    public func cursor(in script: PromptScript, confirmed: Int, movedAt: Double, now: Double, wpm: Double?, onScript: Bool) -> Int {
        guard onScript, let wpm, wpm > 0, confirmed > 0, confirmed < script.tokens.count, now - movedAt < stall else { return confirmed }
        let lead = min(maxWords, Int(((now - movedAt + latency) * wpm / 60).rounded(.down)))
        let sentence = script.tokenSentence[confirmed - 1]
        var c = confirmed
        let ns = script.display as NSString
        while c < confirmed + lead, c < script.tokens.count, script.tokenSentence[c] == sentence {
            // A pause between the last word and this one: wait for the voice.
            let prev = script.tokens[c - 1].range, next = script.tokens[c].range
            let gap = ns.substring(with: NSRange(location: NSMaxRange(prev), length: max(0, next.location - NSMaxRange(prev))))
            if gap.contains(where: { ",.;:!?·—–".contains($0) }) { break }
            c += 1
        }
        return c
    }
}
