import Foundation

/// How captions look and break. Sizes are pixels on a `referenceWidth`×`referenceHeight` frame and
/// scale with the output width; `bandY` is the top of the caption band (the block is centred in it).
public struct CaptionStyle: Codable, Hashable, Sendable {
    public var id: String
    /// PostScript font name.
    public var font: String
    public var fontSize: Double
    public var uppercase: Bool
    public var textColor: String
    public var strokeColor: String
    /// Outline width as drawn (centred on the glyph edge, so half of it shows outside).
    public var strokeWidth: Double
    public var keywordBoxColor: String
    public var keywordTextColor: String
    /// Keyword box padding around the ink of the word.
    public var boxPadX: Double
    public var boxPadY: Double
    /// Space between words.
    public var gap: Double
    public var bandY: Double
    public var bandHeight: Double
    public var referenceWidth: Double
    public var referenceHeight: Double
    public var maxWords: Int
    public var maxChars: Int
    /// A chunk stays this long after its last word ends (unless the next chunk starts first), seconds.
    public var hold: Double
    /// Extra words a chunk never ends on, on top of the spoken language's own list (`LanguageProfile`);
    /// a sentence end (punctuation or pause) still ends a chunk on them.
    public var stopWords: [String]
    /// "word": words appear one by one; "chunk": the whole chunk at its first word.
    public var reveal: String
    /// Show spoken numbers as digits ("nove virgola due" → 9,2; "nove su dieci" → 9 su 10; numbers ≥ 10 →
    /// 2025, 11.000); small standalone numbers stay words. Transcribers that spell numbers out need it.
    public var numerals: Bool?
    /// Language of the stop words and numerals (`it`, `fr`, `en`, `pt`); nil: the transcript's language.
    public var language: String?
    /// "box" (nil): a keyword is drawn in `keywordTextColor` on a box of `keywordBoxColor`; "color": the keyword is
    /// drawn in `keywordBoxColor` (the accent), no box — so brand kits colour both the same way.
    public var keywordMode: String?
    /// Ghost karaoke: the whole chunk shows from its first word, words not yet spoken at this opacity (nil or 0:
    /// hidden until spoken, the plain word-by-word reveal).
    public var upcomingOpacity: Double?
    /// Soft drop shadow under the line: opacity 0…1 (nil or 0: none), blur radius and downward offset, reference pixels.
    public var shadowOpacity: Double?
    public var shadowBlur: Double?
    public var shadowY: Double?
    /// Lines wrap so none is wider than this, reference pixels (nil: one line); two lines are balanced.
    public var maxLineWidth: Double?
    /// Space between wrapped lines, reference pixels (default 0.12 × fontSize).
    public var lineSpacing: Double?
    /// "center" (nil): each word centred in the band by its own ink height (captions.py); "baseline": words share a
    /// baseline (mixed-case text with descenders, serif italics).
    public var wordAlign: String?

    /// The approved WeSites talking-head look (reel 2026-10-26, captions.py): Impact 100 uppercase,
    /// 9 px black outline, keyword on a pink #FF2D6F box, word-by-word, ≤ 3 words / 17 characters,
    /// band 1244–1444 on 1080×1920.
    public static let talkingHeadV1 = CaptionStyle(
        id: "talking-head-v1", font: "Impact", fontSize: 100, uppercase: true, textColor: "#FFFFFF", strokeColor: "#000000",
        strokeWidth: 9, keywordBoxColor: "#FF2D6F", keywordTextColor: "#FFFFFF", boxPadX: 18, boxPadY: 14, gap: 24,
        bandY: 1244, bandHeight: 200, referenceWidth: 1080, referenceHeight: 1920, maxWords: 3, maxChars: 17, hold: 0.4,
        stopWords: [], reveal: "word", numerals: true)

    /// The Italian list the style carried before stop words came from the language (projects saved then still have it).
    static let legacyItalianStopWords: Set<String> = ["SE", "DA", "NON", "IL", "LO", "LA", "LE", "E", "O", "DI", "CHE", "UN", "IN", "A",
                                                       "HA", "HO", "PER", "TI", "DEL", "NEI", "PIÙ"]

    /// Serif italic in cream, no outline and no box, one calm phrase at a time (round-2 reference ad, Didot Italic):
    /// keywords in a soft gold, a faint shadow for legibility on bright walls.
    public static let elegantSerif: CaptionStyle = {
        var s = CaptionStyle(
            id: "elegant-serif", font: "Didot-Italic", fontSize: 82, uppercase: false, textColor: "#F6EEDF", strokeColor: "#000000",
            strokeWidth: 0, keywordBoxColor: "#E9C987", keywordTextColor: "#F6EEDF", boxPadX: 0, boxPadY: 0, gap: 19,
            bandY: 1244, bandHeight: 200, referenceWidth: 1080, referenceHeight: 1920, maxWords: 5, maxChars: 28, hold: 0.4,
            stopWords: [], reveal: "chunk", numerals: true)
        s.keywordMode = "color"
        s.shadowOpacity = 0.55
        s.shadowBlur = 16
        s.shadowY = 3
        s.wordAlign = "baseline"
        return s
    }()

    /// Bold geometric sans, white, up to two balanced lines, the keyword in the brand accent (orange by default), no
    /// box, a soft shadow (round-2 reference ad: "Les super beaux / sous-titres").
    public static let boldKeyword: CaptionStyle = {
        var s = CaptionStyle(
            id: "bold-keyword", font: "AvenirNext-Bold", fontSize: 86, uppercase: false, textColor: "#FFFFFF", strokeColor: "#000000",
            strokeWidth: 0, keywordBoxColor: "#FF8A3D", keywordTextColor: "#FFFFFF", boxPadX: 0, boxPadY: 0, gap: 22,
            bandY: 1214, bandHeight: 250, referenceWidth: 1080, referenceHeight: 1920, maxWords: 6, maxChars: 26, hold: 0.4,
            stopWords: [], reveal: "chunk", numerals: true)
        s.keywordMode = "color"
        s.shadowOpacity = 0.5
        s.shadowBlur = 18
        s.shadowY = 4
        s.maxLineWidth = 860
        s.lineSpacing = 6
        s.wordAlign = "baseline"
        return s
    }()

    /// The whole phrase on screen, spoken words bright and the next ones ghosted at 28 %, revealed word by word
    /// (round-2 reference ad); a semibold sans a little smaller than the other styles, soft shadow, no box.
    public static let ghostKaraoke: CaptionStyle = {
        var s = CaptionStyle(
            id: "ghost-karaoke", font: "AvenirNext-DemiBold", fontSize: 66, uppercase: false, textColor: "#FFFFFF", strokeColor: "#000000",
            strokeWidth: 0, keywordBoxColor: "#FFD15C", keywordTextColor: "#FFFFFF", boxPadX: 0, boxPadY: 0, gap: 17,
            bandY: 1244, bandHeight: 200, referenceWidth: 1080, referenceHeight: 1920, maxWords: 4, maxChars: 24, hold: 0.4,
            stopWords: [], reveal: "word", numerals: true)
        s.keywordMode = "color"
        s.upcomingOpacity = 0.28
        s.shadowOpacity = 0.5
        s.shadowBlur = 14
        s.shadowY = 3
        s.wordAlign = "baseline"
        return s
    }()

    public static let presets: [String: CaptionStyle] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    /// The presets in the order the app lists them.
    public static let all: [CaptionStyle] = [talkingHeadV1, elegantSerif, boldKeyword, ghostKaraoke]

    /// Optional fields captions.setStyle may set although the current style leaves them out (nil fields are not
    /// encoded), with their JSON type.
    public static let optionalFields: [String: String] = [
        "numerals": "boolean", "language": "string", "keywordMode": "string", "upcomingOpacity": "number", "shadowOpacity": "number",
        "shadowBlur": "number", "shadowY": "number", "maxLineWidth": "number", "lineSpacing": "number", "wordAlign": "string",
    ]

    /// Every word of a chunk is on screen from the chunk's first word (whole-chunk reveal, or ghosted upcoming words):
    /// face placement and checks count all of them from the start.
    public var showsWholeChunk: Bool { reveal == "chunk" || (upcomingOpacity ?? 0) > 0 }
    /// Keywords are drawn as coloured words, not on a box.
    public var keywordColorOnly: Bool { keywordMode == "color" }
}

/// A caption line put by hand (captions.place, or a drag on the preview), on the style's reference frame
/// (1080×1920 for a reel). `x` is the line's left edge, centre or right edge (`align`), `y` the vertical centre
/// of its band; `scale` multiplies every size of the style. nil fields stay automatic.
public struct CaptionPlace: Codable, Hashable, Sendable {
    public enum Align: String, Codable, CaseIterable, Sendable { case left, center, right }
    public var x: Double?
    public var y: Double?
    public var scale: Double?
    public var align: Align?

    public init(x: Double? = nil, y: Double? = nil, scale: Double? = nil, align: Align? = nil) {
        self.x = x
        self.y = y
        self.scale = scale
        self.align = align
    }

    public var isEmpty: Bool { x == nil && y == nil && scale == nil && align == nil }

    public static let alignNames = Align.allCases.map(\.rawValue)
}

public struct CaptionWord: Codable, Hashable, Sendable {
    /// As displayed (case, fixes applied, edge punctuation removed).
    public var text: String
    /// Timeline times.
    public var start: MediaTime
    public var end: MediaTime
    public var keyword: Bool
}

public struct CaptionChunk: Codable, Hashable, Sendable {
    public var words: [CaptionWord]
    /// When the chunk disappears.
    public var end: MediaTime
    /// The chunk ends a sentence (punctuation or a pause).
    public var closed: Bool?
    /// Top of this chunk's caption band, reference pixels, when it was moved off a face (nil: the style's bandY).
    public var bandY: Double?
    /// Horizontal shift of the centred line, reference pixels, when it was moved beside a face (nil: centred).
    public var offsetX: Double?
    /// Where the user (or the agent) put this chunk by hand (captions.place); its fields win over the track's.
    public var place: CaptionPlace?

    public init(words: [CaptionWord], end: MediaTime, closed: Bool? = nil, bandY: Double? = nil, offsetX: Double? = nil) {
        self.words = words
        self.end = end
        self.closed = closed
        self.bandY = bandY
        self.offsetX = offsetX
    }

    public var text: String { words.map(\.text).joined(separator: " ") }
}

/// A caption track's content: built from the timeline transcript by `captions.generate`.
public struct Captions: Codable, Hashable, Sendable {
    public var style: CaptionStyle
    /// Display-form words drawn on the keyword box.
    public var keywords: [String]
    /// Display-form replacements; an empty replacement removes the word (its break and end time
    /// pass to the previous word).
    public var fixes: [String: String]
    /// Track the words came from, and its clips when they were read (to tell when they are stale).
    public var sourceTrack: String
    public var sourceSignature: String
    public var chunks: [CaptionChunk]
    /// Move chunks off faces (nil = yes, when the picture has a face track).
    public var avoidFaces: Bool?
    /// Where the user (or the agent) put the whole track by hand (captions.place); nil = automatic.
    public var place: CaptionPlace?

    public init(style: CaptionStyle, keywords: [String], fixes: [String: String], sourceTrack: String, sourceSignature: String,
                chunks: [CaptionChunk], avoidFaces: Bool? = nil) {
        self.style = style
        self.keywords = keywords
        self.fixes = fixes
        self.sourceTrack = sourceTrack
        self.sourceSignature = sourceSignature
        self.chunks = chunks
        self.avoidFaces = avoidFaces
    }

    /// One visible state: chunk `chunk` showing its first `count` words over [start, end).
    public struct State: Hashable, Sendable {
        public var chunk: Int
        public var count: Int
        public var start: MediaTime
        public var end: MediaTime
    }

    /// Every state in order (captions.py entries).
    public var states: [State] {
        var out: [State] = []
        for (ci, ch) in chunks.enumerated() {
            if style.reveal == "chunk" {
                if let first = ch.words.first { out.append(State(chunk: ci, count: ch.words.count, start: first.start, end: ch.end)) }
                continue
            }
            for k in ch.words.indices {
                let end = k + 1 < ch.words.count ? ch.words[k + 1].start : ch.end
                out.append(State(chunk: ci, count: k + 1, start: ch.words[k].start, end: end))
            }
        }
        return out
    }

    /// What shows at timeline time `t` (frame-exact from absolute times: the first state with start ≤ t < end).
    public func state(at t: MediaTime) -> State? {
        states.first { $0.start <= t && t < $0.end }
    }

    /// Frame (at `rate`) on which each word first appears, in reading order.
    public func revealFrames(rate: Rational) -> [(word: CaptionWord, frame: Int)] {
        let frame = MediaTime.frameDuration(at: rate).ticks
        return chunks.flatMap { ch in
            ch.words.enumerated().map { k, w in
                let s = style.reveal == "chunk" ? ch.words[0].start : w.start
                return (w, Int((s.ticks + frame - 1) / frame))   // first frame whose time ≥ start
            }
        }
    }

    /// Placement of chunk `i`: its own manual fields over the track's (nil fields stay automatic).
    public func manualPlace(chunk i: Int) -> CaptionPlace {
        let own = chunks.indices.contains(i) ? chunks[i].place : nil
        return CaptionPlace(x: own?.x ?? place?.x, y: own?.y ?? place?.y, scale: own?.scale ?? place?.scale, align: own?.align ?? place?.align)
    }

    /// Size factor of chunk `i` (1 = the style's size).
    public func scale(chunk i: Int) -> Double { manualPlace(chunk: i).scale ?? 1 }

    /// The chunk was put somewhere by hand: automatic face avoidance leaves it where it is.
    public func isPinned(chunk i: Int) -> Bool {
        let m = manualPlace(chunk: i)
        return m.x != nil || m.y != nil
    }

    /// The chunk is drawn by the manual path (any manual field), else exactly as before captions.place existed.
    public func isManual(chunk i: Int) -> Bool { !manualPlace(chunk: i).isEmpty }

    /// Chunk showing at timeline time `t` (between its first word and its end).
    public func chunk(at t: MediaTime) -> Int? {
        chunks.firstIndex { ch in (ch.words.first?.start ?? ch.end) <= t && t < ch.end }
    }

    public static func signature(of track: Track) -> String {
        let s = track.clips.map { "\($0.id):\($0.start.ticks):\($0.sourceIn.ticks):\($0.sourceOut.ticks)" }.joined(separator: ",")
        var h: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }
}

/// Captions from transcript words (after captions.py, the first approved talking-head reel): merge
/// sub-word tokens, apply fixes, break into chunks of ≤ maxWords / maxChars (a punctuation mark or a
/// sentence pause ends a chunk), never end a chunk on a stop word of the spoken language.
public enum CaptionBuilder {
    struct W { var t: String; var s: MediaTime; var e: MediaTime; var brk = false; var pause = false; var d = "" }

    static let punctuation = Set(".,:;?!…")

    /// - language: the transcript language (`it`, `fr`, `en`, `pt`); `style.language` wins when set.
    /// - pauses: indices of `input` words followed by a sentence pause (see `SentenceSegmenter`): they end
    ///   a chunk like punctuation does, for transcripts without punctuation.
    public static func build(words input: [(text: String, start: MediaTime, end: MediaTime)], style: CaptionStyle,
                             keywords: [String], fixes: [String: String], language: String? = nil,
                             pauses: Set<Int> = []) -> [CaptionChunk] {
        let profile = LanguageProfile.named(style.language ?? language)
        // Sub-word tokens (no letters, or after an apostrophe) belong to the previous word.
        var words: [W] = []
        for (i, w) in input.enumerated() {
            let t = w.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let spoken = t.contains { $0.isLetter || $0.isNumber }
            if let last = words.last, !spoken || last.t.hasSuffix("'") || last.t.hasSuffix("’") || t.hasPrefix("'") || t.hasPrefix("’") {
                words[words.count - 1].t += t
                words[words.count - 1].e = max(last.e, w.end)
                words[words.count - 1].pause = pauses.contains(i)
            } else {
                words.append(W(t: t, s: w.start, e: w.end, pause: pauses.contains(i)))
            }
        }
        if style.numerals == true { words = numerals(words, profile) }
        for i in words.indices {
            words[i].brk = (words[i].t.last.map { punctuation.contains($0) } ?? false) || words[i].pause
            var d = String(words[i].t.drop { punctuation.contains($0) }.reversed().drop { punctuation.contains($0) }.reversed())
            d = d.replacingOccurrences(of: "’", with: "'")
            if style.uppercase { d = d.uppercased() }
            words[i].d = fixes[d] ?? d
        }
        var kept: [W] = []
        for w in words {
            if !w.d.isEmpty { kept.append(w) }
            else if !kept.isEmpty {   // removed by a fix: keeps its break and end time
                kept[kept.count - 1].brk = kept[kept.count - 1].brk || w.brk
                kept[kept.count - 1].e = w.e
            }
        }
        func length(_ ws: [W]) -> Int { ws.map(\.d).joined(separator: " ").count }
        let extra = Set(style.stopWords.map { $0.uppercased() }).subtracting(CaptionStyle.legacyItalianStopWords)
        func stop(_ w: W) -> Bool { !w.brk && (profile.isStopWord(w.d) || extra.contains(w.d.uppercased())) }

        var chunks: [[W]] = [], cur: [W] = []
        for w in kept {
            if !cur.isEmpty, cur.count >= style.maxWords || length(cur + [w]) > style.maxChars {
                chunks.append(cur); cur = []
            }
            cur.append(w)
            if w.brk { chunks.append(cur); cur = [] }
        }
        if !cur.isEmpty { chunks.append(cur) }

        // A chunk ending on a stop word: give the word to the next chunk, else take the next chunk's first
        // word, else give it anyway and spill the next chunk's tail into a new chunk. Lines stay ≤ maxChars + 4.
        let limit = style.maxChars + 4
        var i = 0
        while i < chunks.count - 1 {
            guard let last = chunks[i].last, stop(last) else { i += 1; continue }
            // Words to pull back: up to the next chunk's first word that is not a stop word.
            let next = chunks[i + 1]
            let pull = (next.firstIndex { !stop($0) } ?? (next.count - 1)) + 1
            if length([last] + next) <= limit {
                chunks[i + 1].insert(chunks[i].removeLast(), at: 0)
            } else if length(chunks[i] + next.prefix(pull)) <= limit {
                chunks[i] += next.prefix(pull)
                chunks[i + 1].removeFirst(pull)
                if chunks[i + 1].isEmpty { chunks.remove(at: i + 1) }
                i += 1
                continue
            } else {
                chunks[i + 1].insert(chunks[i].removeLast(), at: 0)
                var spill: [W] = []
                while chunks[i + 1].count > 1, length(chunks[i + 1]) > limit || chunks[i + 1].count > style.maxWords + 1
                        || (!spill.isEmpty && stop(chunks[i + 1].last!)) {
                    spill.insert(chunks[i + 1].removeLast(), at: 0)
                }
                if !spill.isEmpty { chunks.insert(spill, at: i + 2) }
            }
            if chunks[i].isEmpty { chunks.remove(at: i) } else if let l = chunks[i].last, stop(l) { continue } else { i += 1 }
        }
        // Keywords match whatever the case (a mixed-case style keeps the keywords typed for an uppercase one).
        let keys = Set(keywords.map { $0.uppercased() })
        let hold = MediaTime(seconds: style.hold)
        return chunks.enumerated().map { ci, ch in
            let tail = ch.last!.e + hold
            let end = ci + 1 < chunks.count ? min(chunks[ci + 1][0].s, tail) : tail
            var chunk = CaptionChunk(words: ch.map { CaptionWord(text: $0.d, start: $0.s, end: $0.e, keyword: keys.contains($0.d.uppercased())) }, end: end)
            if ch.last!.brk { chunk.closed = true }
            return chunk
        }
    }

    /// Chunks whose last word is a stop word of `language` and no sentence end (for checks and reports).
    public static func stopWordEnds(_ captions: Captions, language: String?) -> [String] {
        let profile = LanguageProfile.named(captions.style.language ?? language)
        let extra = Set(captions.style.stopWords.map { $0.uppercased() }).subtracting(CaptionStyle.legacyItalianStopWords)
        return captions.chunks.filter { ch in
            guard ch.closed != true, let last = ch.words.last else { return false }
            return profile.isStopWord(last.text) || extra.contains(last.text.uppercased())
        }.map(\.text)
    }

    /// Spoken numbers to digits, keeping each word's timing (a multi-word number spans all its words):
    /// numbers ≥ 10, decimals ("nove virgola due" → 9,2), ratios ("neuf sur dix" → 9 sur 10) and
    /// percentages ("dix pour cent" → 10 %); small standalone numbers stay words.
    static func numerals(_ words: [W], _ profile: LanguageProfile) -> [W] {
        func split(_ t: String) -> (core: String, tail: String) {
            let core = String(t.reversed().drop { punctuation.contains($0) }.reversed())
            return (core, String(t.dropFirst(core.count)))
        }
        func core(_ i: Int) -> String { i < words.count ? split(words[i].t).core : "" }
        func tail(_ i: Int) -> String { i < words.count ? split(words[i].t).tail : "" }
        func lower(_ i: Int) -> String { LanguageProfile.fold(core(i)) }
        /// The longest spelled number starting at i: (value, word count); digits count too ("10").
        func number(at i: Int) -> (value: Int, count: Int)? {
            guard i < words.count else { return nil }
            if let n = Int(core(i)), core(i).count <= 7 { return (n, 1) }
            guard profile.isNumberPart(core(i)) else { return nil }
            var j = i
            while j + 1 < words.count, tail(j).isEmpty, profile.isNumberPart(core(j + 1)) { j += 1 }
            while j >= i {
                if let v = profile.number((i...j).map(core)) { return (v, j - i + 1) }
                j -= 1
            }
            return nil
        }
        func phrase(_ i: Int, _ ps: [[String]]) -> Int? {
            for p in ps where (0..<p.count).allSatisfy({ i + $0 < words.count && lower(i + $0) == p[$0] && ($0 == p.count - 1 || tail(i + $0).isEmpty) }) {
                return p.count
            }
            return nil
        }
        var out: [W] = []
        var i = 0
        var previousRatio = false
        while i < words.count {
            guard let (n, c) = number(at: i) else { out.append(words[i]); previousRatio = false; i += 1; continue }
            let last = i + c - 1
            var w = words[i]
            w.e = words[last].e
            w.pause = words[last].pause
            // Decimal: N <virgola> M.
            if tail(last).isEmpty, profile.decimalWords.contains(lower(last + 1)), tail(last + 1).isEmpty, let (m, mc) = number(at: last + 2) {
                let end = last + 1 + mc
                let frac = (last + 2...end).map(core).joined()
                w.t = profile.digits(n) + profile.decimalMark + (Int(frac) != nil ? frac : String(m)) + tail(end)
                w.e = words[end].e
                w.pause = words[end].pause
                out.append(w)
                i = end + 1
                previousRatio = false
                continue
            }
            // Percent: N <per cento>.
            if tail(last).isEmpty, let pc = phrase(last + 1, profile.percentWords) {
                let end = last + pc
                w.t = profile.digits(n) + profile.percentSign + tail(end)
                w.e = words[end].e
                w.pause = words[end].pause
                out.append(w)
                i = end + 1
                previousRatio = false
                continue
            }
            let nextIsRatio = tail(last).isEmpty && phrase(last + 1, profile.ratioWords).map { number(at: last + 1 + $0) != nil } == true
            if n >= 10 || nextIsRatio || previousRatio {
                w.t = profile.digits(n) + tail(last)
                out.append(w)
            } else {
                out.append(contentsOf: words[i...last])
            }
            previousRatio = false
            i = last + 1
            if nextIsRatio, let rc = phrase(i, profile.ratioWords) {
                out.append(contentsOf: words[i..<i + rc])
                i += rc
                previousRatio = true
            }
        }
        return out
    }

    /// SubRip text: one cue per chunk.
    public static func srt(_ captions: Captions) -> String {
        func stamp(_ t: MediaTime) -> String {
            let ms = Int((t.seconds * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return captions.chunks.enumerated().compactMap { i, ch -> String? in
            guard let first = ch.words.first else { return nil }
            return "\(i + 1)\n\(stamp(first.start)) --> \(stamp(ch.end))\n\(ch.text)\n"
        }.joined(separator: "\n")
    }
}
