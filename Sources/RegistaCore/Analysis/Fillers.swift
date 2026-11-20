import Foundation

/// The candidate filler words of a timeline's transcript (transcript.fillers, #59), per transcription language:
/// - `sure`: pure hesitations, never a word of a sentence («ehm», «euh», «um», «hã»…);
/// - `maybe`: words that are fillers only when they stand alone («allora», «so», «du coup», «né»…): listed only when
///   they open a take or a pause (or a take's edge) separates them from the words on both sides, never inside a clause;
/// - `repeat`: a word said twice in a row («il il», «the the»): the first of the two.
/// What the engines write (2026-11): whisper.cpp and WhisperX with large-v3-turbo leave most hesitations out of the
/// text altogether, so the list is often empty for them; an engine or a transcript corrected by hand that keeps them is
/// read the same way.
public enum Fillers {
    public enum Kind: String, Sendable, CaseIterable { case sure, maybe, `repeat` }

    /// Pure hesitations, each written with every run of one letter collapsed («ehmm» → «ehm», «mmm» → «m»).
    static let sure: [String: Set<String>] = [
        "it": ["ehm", "eh", "em", "ahm", "uhm", "um", "uh", "m", "hm", "mh"],
        "en": ["um", "uhm", "uh", "er", "erm", "ehm", "m", "hm", "mh"],
        "fr": ["euh", "euhm", "heu", "hum", "m", "hm", "mh"],
        "pt": ["hã", "ã", "ãh", "ahn", "hum", "uhm", "ehm", "m", "hm", "mh"],
    ]

    /// A language without a table: only the hesitations that are a word in no language. The tables' other entries are
    /// words elsewhere («er» and «um» in German, «em» in Catalan), and a `sure` one is removed without being read out.
    static let anyLanguage: Set<String> = ["ehm", "uhm", "euh", "euhm", "erm", "ahm", "hm", "mh", "m"]

    /// Words and phrases that are fillers only when they stand alone (lowercase, as spelled).
    static let maybe: [String: [[String]]] = [
        "it": [["allora"], ["cioè"], ["tipo"], ["ecco"], ["diciamo"], ["praticamente"], ["insomma"], ["come", "dire"]],
        "en": [["so"], ["like"], ["well"], ["basically"], ["actually"], ["you", "know"], ["i", "mean"]],
        "fr": [["bon"], ["alors"], ["ben"], ["bah"], ["enfin"], ["voilà"], ["genre"], ["quoi"], ["du", "coup"], ["en", "fait"]],
        "pt": [["então"], ["tipo"], ["né"], ["pronto"], ["bem"], ["assim"], ["olha"], ["quer", "dizer"]],
    ]

    /// Words a sentence says twice on purpose: never a `repeat` («nous nous sommes», «no no», «piano piano», «that that»).
    static let doubled: Set<String> = ["nous", "vous", "no", "non", "sì", "si", "oui", "yes", "sim", "não", "very", "molto",
                                       "muito", "très", "piano", "via", "bye", "ciao", "tchau", "that", "had"]

    public static var languages: [String] { sure.keys.sorted() }

    /// One candidate: the words `from`…`to` (one word, or a phrase of `maybe`).
    public struct Candidate: Sendable, Hashable {
        public var from: Int
        public var to: Int
        public var text: String
        public var kind: Kind
        public var start: MediaTime
        public var end: MediaTime
        public var pauseBefore: MediaTime
        public var pauseAfter: MediaTime
    }

    /// The word as the tables spell it: lowercase, punctuation around it removed (accents kept: «né» is not «ne»).
    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    /// Every run of one letter collapsed to one: «ehmmm» → «ehm», «euhhh» → «euh».
    static func collapsed(_ s: String) -> String {
        var out = ""
        for c in s where c != out.last { out.append(c) }
        return out
    }

    /// The candidates of `words` (as TimelineTranscript.words gives them, on `track`), in timeline order. A pause is a
    /// silence of at least `pause` between two words of one clip; a clip's edge counts as one (the take stops there).
    public static func candidates(_ words: [TimelineWord], track: Track, language: String, pause: MediaTime) -> [Candidate] {
        let lang = String(language.lowercased().prefix(2))
        // A language without a table: the hesitations no language uses as a word, no `maybe` (words of their language).
        let sureSet = sure[lang] ?? anyLanguage
        let phrases = (maybe[lang] ?? []).sorted { $0.count > $1.count }
        let tokens = words.map { normalized($0.text) }
        let clips = Dictionary(track.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func opensTake(_ i: Int) -> Bool { i == 0 || words[i - 1].clipID != words[i].clipID }
        func closesTake(_ i: Int) -> Bool { i + 1 == words.count || words[i + 1].clipID != words[i].clipID }
        func before(_ i: Int) -> MediaTime {
            opensTake(i) ? max(words[i].start - (clips[words[i].clipID]?.start ?? words[i].start), .zero) : max(words[i].start - words[i - 1].end, .zero)
        }
        func after(_ i: Int) -> MediaTime {
            closesTake(i) ? max((clips[words[i].clipID]?.end ?? words[i].end) - words[i].end, .zero) : max(words[i + 1].start - words[i].end, .zero)
        }
        func candidate(_ from: Int, _ to: Int, _ kind: Kind) -> Candidate {
            Candidate(from: from, to: to, text: words[from...to].map(\.text).joined(separator: " "), kind: kind,
                      start: words[from].start, end: words[to].end, pauseBefore: before(from), pauseAfter: after(to))
        }
        var out: [Candidate] = []
        var i = 0
        while i < words.count {
            let t = tokens[i]
            if t.isEmpty { i += 1; continue }
            // A lone «m» is the letter («taglia M»); the hesitation is written «mm» or longer.
            if t != "m", sureSet.contains(collapsed(t)) { out.append(candidate(i, i, .sure)); i += 1; continue }
            if i + 1 < words.count, tokens[i + 1] == t, !doubled.contains(t) { out.append(candidate(i, i, .repeat)); i += 1; continue }
            if let phrase = phrases.first(where: { p in i + p.count <= words.count && Array(tokens[i..<(i + p.count)]) == p }) {
                let last = i + phrase.count - 1
                // A phrase inside one clip only, standing alone: it opens a take, or a pause sets it apart on both sides
                // (the end of a take counts as one).
                let oneClip = Set(words[i...last].map(\.clipID)).count == 1
                let alone = before(i) >= pause && (closesTake(last) || after(last) >= pause)
                if oneClip, opensTake(i) || alone {
                    out.append(candidate(i, last, .maybe))
                    i = last + 1
                    continue
                }
            }
            i += 1
        }
        return out
    }
}
