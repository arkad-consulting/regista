import Foundation

/// A script as the teleprompter shows it and the take tracker follows it.
///
/// Markup (what script.prepare writes; editable by hand, plain text works too):
/// - `1. ` a numbered line starts a sentence, i.e. one take ("una riga = una ripresa"); the lines
///   right below it (no blank line in between) continue the same sentence on new display lines;
/// - ` / ` a breath mark: a short pause, drawn as a subtle gap;
/// - `*word*` a keyword: subtly emphasized (the same keywords the captions highlight).
///
/// Without numbered lines every non-empty line is a sentence. In a prototype-era script.md only the
/// "## Testo" section counts. `Script.parse` uses the same rules, so the teleprompter's sentences
/// and the project's script lines always agree.
public struct PromptScript: Sendable {
    public struct Sentence: Sendable, Hashable {
        /// Plain text, markup removed (a `Script` line).
        public var text: String
        /// Display lines with markup, as written.
        public var lines: [String]
        /// Script tokens of this sentence.
        public var tokens: Range<Int>
    }

    /// What the teleprompter draws: sentences are paragraphs ("\n"), display lines inside a sentence
    /// are separated by U+2028, breath marks are a faint "·" between en spaces.
    public let display: String
    public let tokens: [ScriptToken]
    public let sentences: [Sentence]
    /// Sentence index of every token.
    public let tokenSentence: [Int]
    /// The breath-mark glyphs in `display` (UTF-16 ranges).
    public let breathRanges: [NSRange]
    /// Tokens inside a `*keyword*`.
    public let keywordTokens: Set<Int>
    /// Keywords in display form, in script order, without duplicates.
    public let keywords: [String]

    public static let lineSeparator = "\u{2028}"
    static let breathGlyph = "\u{2002}·\u{2002}"

    public init(_ text: String) {
        var display = "", breaths: [NSRange] = [], keywordRanges: [NSRange] = [], keywords: [String] = []
        var sentenceRanges: [NSRange] = [], sentences: [Sentence] = []
        for block in Self.blocks(text) {
            if !display.isEmpty { display += "\n" }
            let sentenceStart = (display as NSString).length
            for (li, line) in block.enumerated() {
                if li > 0 { display += Self.lineSeparator }
                var keywordRun = false
                for piece in Self.pieces(line) {
                    switch piece {
                    case .breath:
                        keywordRun = false
                        breaths.append(NSRange(location: (display as NSString).length, length: (Self.breathGlyph as NSString).length))
                        display += Self.breathGlyph
                    case .word(let w, let keyword):
                        let ns = display as NSString
                        if ns.length > sentenceStart, !display.hasSuffix(Self.lineSeparator), !display.hasSuffix(Self.breathGlyph) { display += " " }
                        let loc = (display as NSString).length
                        display += w
                        if keyword {
                            keywordRanges.append(NSRange(location: loc, length: (w as NSString).length))
                            let k = w.trimmingCharacters(in: .punctuationCharacters)
                            // "*nove virgola due*" is one keyword.
                            if keywordRun, let last = keywords.popLast() { keywords.append(last + " " + k) }
                            else { keywords.append(k) }
                        }
                        keywordRun = keyword && !w.hasSuffix(",") && !w.hasSuffix(".")
                    }
                }
            }
            sentenceRanges.append(NSRange(location: sentenceStart, length: (display as NSString).length - sentenceStart))
            keywords = keywords.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            sentences.append(Sentence(text: Self.plain(block.joined(separator: " ")), lines: block, tokens: 0..<0))
        }
        let tokens = ScriptAligner.tokenize(display)
        var tokenSentence = [Int](repeating: 0, count: tokens.count)
        var cursor = 0
        for (si, r) in sentenceRanges.enumerated() {
            let first = cursor
            while cursor < tokens.count, tokens[cursor].range.location < NSMaxRange(r) {
                tokenSentence[cursor] = si
                cursor += 1
            }
            sentences[si].tokens = first..<cursor
        }
        self.display = display
        self.tokens = tokens
        self.sentences = sentences
        self.tokenSentence = tokenSentence
        self.breathRanges = breaths
        self.keywordTokens = Set(tokens.indices.filter { i in keywordRanges.contains { NSIntersectionRange($0, tokens[i].range).length > 0 } })
        self.keywords = keywords
    }

    /// Sentence of the token at `cursor` (the next one to read); the last sentence once the script is finished.
    public func sentence(at cursor: Int) -> Int? {
        guard !tokens.isEmpty else { return nil }
        return tokenSentence[min(max(cursor, 0), tokens.count - 1)]
    }

    // MARK: Parsing (shared with Script.parse)

    /// The sentences of a script, each as its display lines with markup.
    static func blocks(_ text: String) -> [[String]] {
        var body = text
        if let r = text.range(of: "## Testo") {
            body = String(text[r.upperBound...])
            // Skip the rest of the heading line.
            if let nl = body.firstIndex(of: "\n") { body = String(body[nl...]) } else { body = "" }
            if let next = body.range(of: "\n## ") { body = String(body[..<next.lowerBound]) }
        }
        let all = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let numbered = { (line: String) -> String? in
            guard let m = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) else { return nil }
            return String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if all.contains(where: { numbered($0) != nil }) {
            var out: [[String]] = []
            var open = false
            for line in all {
                if let n = numbered(line) {
                    out.append([n])
                    open = true
                } else if line.isEmpty || line.hasPrefix("#") {
                    open = false
                } else if open {
                    out[out.count - 1].append(line)
                }
            }
            return out.filter { !plain($0.joined(separator: " ")).isEmpty }
        }
        return all.filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { [$0] }
    }

    enum Piece: Equatable { case word(String, keyword: Bool), breath }

    /// Words and breath marks of one display line; `*a b*` marks every word inside as a keyword.
    static func pieces(_ line: String) -> [Piece] {
        var out: [Piece] = []
        var inKeyword = false
        for raw in line.split(whereSeparator: \.isWhitespace).map(String.init) {
            if raw == "/" { out.append(.breath); continue }
            var w = raw
            var keyword = inKeyword
            if w.hasPrefix("*"), w.count > 1 { w.removeFirst(); keyword = true; inKeyword = true }
            // "*sicuro*," or "*sicuro,*": the closing star may sit before trailing punctuation.
            if let star = w.lastIndex(of: "*"), keyword {
                w.remove(at: star)
                inKeyword = false
            }
            if !w.isEmpty { out.append(.word(w, keyword: keyword)) }
        }
        return out
    }

    /// Markup removed: keyword stars and breath marks, whitespace collapsed.
    static func plain(_ text: String) -> String {
        pieces(text).compactMap { if case .word(let w, _) = $0 { return w } else { return nil } }.joined(separator: " ")
    }
}

extension Script {
    /// Numbered lines of the "## Testo" section when there is one (script.md), else every numbered
    /// line (with the lines directly below it as continuation), else every non-empty line. Markup
    /// (breath marks, `*keywords*`) is removed; see `PromptScript`.
    public static func parse(_ text: String) -> Script {
        Script(lines: PromptScript.blocks(text).map { PromptScript.plain($0.joined(separator: " ")) })
    }
}

// MARK: - Preparing a script for speaking (script.prepare)

extension PromptScript {
    /// Words a line may start with when a phrase is too long (Italian and French): conjunctions and
    /// prepositions first, articles only when there is none.
    static let breakBefore: Set<String> = [
        "che", "e", "ed", "ma", "o", "per", "di", "da", "a", "in", "con", "su", "tra", "fra", "se", "non", "quando",
        "perche", "come", "mentre", "del", "della", "nel", "nella",
        "et", "mais", "ou", "pour", "de", "du", "des", "dans", "avec", "sur", "si", "ne", "qui", "que", "quand",
    ]
    static let breakBeforeArticle: Set<String> = ["il", "lo", "la", "i", "gli", "le", "un", "una", "uno", "les", "une"]

    /// Formats a script for reading aloud: one numbered sentence per take, display lines of at most
    /// `maxChars` characters (broken at breath marks, else before a function word), a breath mark
    /// after every mid-sentence comma, colon, semicolon or dash, and keywords flagged `*like this*`.
    /// `keywords` are matched as words (multi-word ones too); nil keeps the ones already flagged in
    /// `text`, else picks numbers, acronyms and names (at most two per sentence).
    public static func prepare(_ text: String, maxChars: Int = 32, keywords: [String]? = nil) -> String {
        let existing = PromptScript(text).keywords
        let wanted = keywords ?? (existing.isEmpty ? nil : existing)
        let sentences = Script.parse(text).lines
        return sentences.enumerated().map { si, sentence in
            let words = sentence.split(separator: " ").map(String.init)
            let flagged = wanted.map { keywordMask(words, $0) } ?? autoKeywords(words)
            var pieces: [Piece] = []
            for (i, w) in words.enumerated() {
                pieces.append(.word(w, keyword: flagged[i]))
                let last = i == words.count - 1
                if !last, w.last.map({ ",;:".contains($0) }) == true || words[i + 1] == "–" || words[i + 1] == "—" { pieces.append(.breath) }
            }
            let lines = layout(pieces, maxChars: maxChars)
            return "\(si + 1). " + lines.map(render).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Which words are keywords: a keyword's keys must match a run of consecutive words.
    static func keywordMask(_ words: [String], _ keywords: [String]) -> [Bool] {
        var mask = [Bool](repeating: false, count: words.count)
        let wordKeys = words.map { ScriptAligner.keys(of: $0).joined(separator: " ") }
        for k in keywords {
            let target = ScriptAligner.keys(of: k).joined(separator: " ")
            guard !target.isEmpty else { continue }
            for i in words.indices {
                var acc = ""
                for j in i..<words.count {
                    acc = acc.isEmpty ? wordKeys[j] : acc + " " + wordKeys[j]
                    if acc == target { for x in i...j { mask[x] = true }; break }
                    if acc.count >= target.count { break }
                }
            }
        }
        return mask
    }

    /// Numbers, acronyms and names (capitalized, not first), else the longest long word: at most two.
    static func autoKeywords(_ words: [String]) -> [Bool] {
        let bare = words.map { $0.trimmingCharacters(in: .punctuationCharacters) }
        func score(_ i: Int) -> Int {
            let w = bare[i]
            guard w.count >= 2 else { return 0 }
            if w.contains(where: \.isNumber) { return 3 }
            if w.count >= 2, w == w.uppercased(), w.contains(where: \.isLetter) { return 3 }
            if i > 0, w.first?.isUppercase == true { return 2 }
            return 0
        }
        var picked = words.indices.filter { score($0) > 0 }.sorted { score($0) > score($1) }.prefix(2).map { $0 }
        if picked.isEmpty, let long = words.indices.filter({ bare[$0].count >= 8 }).max(by: { bare[$0].count < bare[$1].count }) {
            picked = [long]
        }
        return words.indices.map { picked.contains($0) }
    }

    /// Lines of at most `maxChars` (a single longer word stays whole).
    static func layout(_ pieces: [Piece], maxChars: Int) -> [[Piece]] {
        func length(_ line: [Piece]) -> Int {
            line.reduce(0) { n, p in
                if case .word(let w, _) = p { return n + (n > 0 ? 1 : 0) + w.count }
                return n + 2
            }
        }
        // Phrases between breath marks, each ending with its breath mark if it has one.
        var phrases: [[Piece]] = [[]]
        for p in pieces {
            phrases[phrases.count - 1].append(p)
            if p == .breath { phrases.append([]) }
        }
        phrases.removeAll(where: \.isEmpty)

        var lines: [[Piece]] = []
        var line: [Piece] = []
        for phrase in phrases {
            if length(line + phrase) <= maxChars { line += phrase; continue }
            if length(phrase) <= maxChars {
                if !line.isEmpty { lines.append(line) }
                line = phrase
                continue
            }
            // A long phrase: keep filling the current line word by word, then move the tail from the
            // last good break to the next line.
            for p in phrase {
                if case .word = p, !line.isEmpty, length(line + [p]) > maxChars {
                    let half = line.count / 2
                    let candidate = { (set: Set<String>) in
                        line.indices.last { i in
                            guard i >= max(1, half), case .word(let w, _) = line[i] else { return false }
                            return set.contains(ScriptAligner.normalize(w))
                        }
                    }
                    let breakAt = candidate(breakBefore) ?? candidate(breakBeforeArticle) ?? line.count
                    lines.append(Array(line[..<breakAt]))
                    line = Array(line[breakAt...])
                }
                line.append(p)
            }
        }
        if !line.isEmpty { lines.append(line) }
        // No lonely short word on the last line.
        if lines.count >= 2, lines.last!.count == 1, case .word(let w, _) = lines.last![0], w.count <= 6,
           length(lines[lines.count - 2] + lines.last!) <= maxChars + 4 {
            let last = lines.removeLast()
            lines[lines.count - 1] += last
        }
        return lines
    }

    /// One display line with markup: consecutive keywords share one pair of stars.
    static func render(_ line: [Piece]) -> String {
        var out: [String] = []
        var i = 0
        while i < line.count {
            switch line[i] {
            case .breath:
                out.append("/")
                i += 1
            case .word(let w, let keyword):
                guard keyword else { out.append(w); i += 1; continue }
                var run = [w]
                var j = i + 1
                while j < line.count, case .word(let next, true) = line[j] { run.append(next); j += 1 }
                // Trailing punctuation stays outside the stars: "*sicuro*,".
                var last = run.removeLast()
                var tail = ""
                while let c = last.last, c.isPunctuation, last.count > 1 { tail = String(c) + tail; last.removeLast() }
                out.append("*" + (run + [last]).joined(separator: " ") + "*" + tail)
                i = j
            }
        }
        return out.joined(separator: " ")
    }
}
