import Foundation

/// What captions need to know about the spoken language: the words a chunk must not end on
/// (articles, prepositions, conjunctions, determiners, clitic pronouns), how spoken numbers are
/// written as digits, and how sentences are segmented when the transcript has no punctuation.
/// Chosen from the transcript language (`it`, `fr`, `en`, `pt`); unknown languages get Italian
/// numerals off and an empty stop list.
public struct LanguageProfile: Sendable {
    public var code: String
    /// Uppercase display forms, accents kept.
    public var stopWords: Set<String>
    /// Spoken decimal separator ("virgola", "virgule", "point", "vírgula") and the written one.
    public var decimalWords: Set<String>
    public var decimalMark: String
    /// "nove su dieci", "neuf sur dix", "nine out of ten": both numbers become digits.
    public var ratioWords: [[String]]
    /// "dieci per cento" → "10%" ("10 %" in French, with a no-break space).
    public var percentWords: [[String]]
    public var percentSign: String
    /// Thousands separator for numbers ≥ 10 000 ("." it/pt, no-break space fr, "," en).
    public var groupSeparator: String
    /// Spelled-out number atoms (accent-free, lowercase) → value; multipliers and connectors below.
    var atoms: [String: Int]
    var hundred: Set<String>
    var thousand: Set<String>
    var million: Set<String>
    /// Words that may join two number words ("vingt et un", "vinte e cinco", "one hundred and five").
    var connectors: Set<String>

    public static func named(_ code: String?) -> LanguageProfile {
        switch code?.lowercased().prefix(2) {
        case "fr": french
        case "en": english
        case "pt": portuguese
        default: italian
        }
    }

    public static let supported = ["it", "fr", "en", "pt"]

    /// True when the display word (any case) is a stop word.
    public func isStopWord(_ display: String) -> Bool { stopWords.contains(display.uppercased()) }

    // MARK: - Numbers

    static func fold(_ s: String) -> String { TextNorm.stripAccents(s.lowercased()) }

    /// Value of the spelled-out number made of `words` (all of them), nil if they are not one number.
    public func number(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        var parts: [String] = []
        for w in words { parts += Self.fold(w).split(separator: "-").map(String.init) }
        guard let first = parts.first, !connectors.contains(first), let last = parts.last, !connectors.contains(last) else { return nil }
        var total = 0, current = 0, any = false
        var previous: String?
        for (k, part) in parts.enumerated() {
            if connectors.contains(part) {
                // A connector joins tens/hundreds to a smaller number: "vingt et un", "cento e vinte".
                guard current > 0 || total > 0, k + 1 < parts.count, let next = atoms[parts[k + 1]] else { return nil }
                let base = current > 0 ? current : total
                let soixanteEtOnze = code == "fr" && base % 100 == 60 && next == 11
                guard base % 10 == 0, next < Self.lowestMagnitude(base) || soixanteEtOnze else { return nil }
                previous = part
                continue
            }
            if let v = atoms[part] {
                if code == "fr", v == 20, current % 100 == 4, previous.flatMap({ atoms[$0] }) == 4 {
                    current += 76   // quatre-vingt(s)
                } else if code == "fr", (10...19).contains(v), [60, 80].contains(current % 100) {
                    current += v    // soixante-dix, quatre-vingt-quinze
                } else if current == 0 || v < Self.lowestMagnitude(current) || (code == "it" && current % 1000 == 0 && v < 1000) {
                    current += v
                } else {
                    return nil      // "deux trois" is two numbers, not five
                }
                any = true
            } else if hundred.contains(part) {
                guard current % 100 == 0 || current < 10 else { return nil }
                current = (current == 0 ? 1 : current) * 100
                any = true
            } else if thousand.contains(part) {
                total += (current == 0 ? 1 : current) * 1000
                current = 0
                any = true
            } else if million.contains(part) {
                total += (current == 0 ? 1 : current) * 1_000_000
                current = 0
                any = true
            } else {
                return nil
            }
            previous = part
        }
        return any ? total + current : nil
    }

    /// 10 for 20…90, 100 for 100, 900…, 1 for anything with units.
    static func lowestMagnitude(_ n: Int) -> Int {
        var m = 1
        var x = n
        while x > 0, x % 10 == 0 { m *= 10; x /= 10 }
        return m
    }

    /// Digits as captions show them: grouped from 10 000 up.
    public func digits(_ n: Int) -> String {
        guard n >= 10_000 else { return String(n) }
        var s = String(n), out = ""
        while s.count > 3 { out = groupSeparator + String(s.suffix(3)) + out; s = String(s.dropLast(3)) }
        return s + out
    }

    /// Is this word (lowercase, accent-free) able to start or continue a spelled number?
    func isNumberPart(_ word: String) -> Bool {
        let parts = Self.fold(word).split(separator: "-").map(String.init)
        return !parts.isEmpty && parts.allSatisfy { atoms[$0] != nil || hundred.contains($0) || thousand.contains($0) || million.contains($0) || connectors.contains($0) }
    }

    // MARK: - Profiles

    public static let italian: LanguageProfile = {
        // Compounds are one word in Italian ("duemilaventicinque"): the TextNorm dictionary is the atom table.
        var atoms: [String: Int] = [:]
        for (k, v) in TextNorm.spelled { atoms[fold(k)] = v }
        atoms["un"] = 1; atoms["una"] = 1
        return LanguageProfile(
            code: "it",
            stopWords: ["SE", "DA", "NON", "IL", "LO", "LA", "LE", "E", "O", "DI", "CHE", "UN", "IN", "A", "HA", "HO", "PER", "TI",
                        "DEL", "NEI", "PIÙ"],
            decimalWords: ["virgola"], decimalMark: ",", ratioWords: [["su"]], percentWords: [["per", "cento"]], percentSign: "%",
            groupSeparator: ".", atoms: atoms, hundred: [], thousand: [], million: ["milione", "milioni"], connectors: [])
    }()

    public static let french: LanguageProfile = {
        var atoms: [String: Int] = [:]
        let units = ["zero", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze", "douze", "treize",
                     "quatorze", "quinze", "seize"]
        for (i, u) in units.enumerated() { atoms[u] = i }
        atoms["une"] = 1
        for (u, v) in [("vingt", 20), ("vingts", 20), ("trente", 30), ("quarante", 40), ("cinquante", 50), ("soixante", 60)] { atoms[u] = v }
        return LanguageProfile(
            code: "fr",
            stopWords: ["LE", "LA", "LES", "L'", "UN", "UNE", "DES", "DE", "DU", "D'", "AU", "AUX", "À", "A", "ET", "OU", "EN", "CE", "CET",
                        "CETTE", "CES", "MON", "MA", "MES", "TON", "TA", "TES", "SON", "SA", "SES", "NOTRE", "NOS", "VOTRE", "VOS", "LEUR",
                        "LEURS", "QUE", "QU'", "QUI", "NE", "N'", "SE", "S'", "JE", "J'", "TU", "IL", "ILS", "ELLE", "ELLES", "ON", "NOUS",
                        "VOUS", "ME", "M'", "TE", "T'", "Y", "PAR", "POUR", "SUR", "DANS", "AVEC", "SANS", "SOUS", "CHEZ", "VERS", "ENTRE",
                        "MAIS", "DONC", "CAR", "NI", "SI", "COMME", "PLUS", "MOINS", "TRÈS", "C'EST", "QU'IL", "QU'ELLE", "QU'ON"],
            decimalWords: ["virgule"], decimalMark: ",", ratioWords: [["sur"]], percentWords: [["pour", "cent"], ["pourcent"]],
            percentSign: "\u{00A0}%", groupSeparator: "\u{00A0}", atoms: atoms, hundred: ["cent", "cents"], thousand: ["mille"],
            million: ["million", "millions"], connectors: ["et"])
    }()

    public static let english: LanguageProfile = {
        var atoms: [String: Int] = [:]
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
                     "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        for (i, u) in units.enumerated() { atoms[u] = i }
        for (i, u) in ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() { atoms[u] = 20 + 10 * i }
        return LanguageProfile(
            code: "en",
            stopWords: ["THE", "A", "AN", "OF", "TO", "IN", "ON", "AT", "FOR", "WITH", "BY", "FROM", "INTO", "ABOUT", "AND", "OR", "BUT",
                        "SO", "IF", "AS", "THAT", "THIS", "THESE", "THOSE", "MY", "YOUR", "OUR", "THEIR", "HIS", "HER", "ITS", "I", "WE",
                        "YOU", "THEY", "HE", "SHE", "NOT", "NO", "THAN", "MORE", "VERY", "I'M", "IT'S", "YOU'RE", "WE'RE", "THEY'RE"],
            decimalWords: ["point"], decimalMark: ".", ratioWords: [["out", "of"]], percentWords: [["percent"], ["per", "cent"]],
            percentSign: "%", groupSeparator: ",", atoms: atoms, hundred: ["hundred"], thousand: ["thousand"],
            million: ["million", "millions"], connectors: ["and"])
    }()

    public static let portuguese: LanguageProfile = {
        var atoms: [String: Int] = [:]
        let units = ["zero", "um", "dois", "tres", "quatro", "cinco", "seis", "sete", "oito", "nove", "dez", "onze", "doze", "treze",
                     "catorze", "quinze", "dezasseis", "dezassete", "dezoito", "dezanove"]
        for (i, u) in units.enumerated() { atoms[u] = i }
        for (u, v) in [("uma", 1), ("duas", 2), ("quatorze", 14), ("dezesseis", 16), ("dezessete", 17), ("dezenove", 19), ("vinte", 20),
                       ("trinta", 30), ("quarenta", 40), ("cinquenta", 50), ("sessenta", 60), ("setenta", 70), ("oitenta", 80),
                       ("noventa", 90), ("cem", 100), ("cento", 100), ("duzentos", 200), ("duzentas", 200), ("trezentos", 300),
                       ("quatrocentos", 400), ("quinhentos", 500), ("seiscentos", 600), ("setecentos", 700), ("oitocentos", 800),
                       ("novecentos", 900)] { atoms[u] = v }
        return LanguageProfile(
            code: "pt",
            stopWords: ["O", "A", "OS", "AS", "UM", "UMA", "UNS", "UMAS", "DE", "DO", "DA", "DOS", "DAS", "EM", "NO", "NA", "NOS", "NAS", "AO",
                        "AOS", "À", "ÀS", "POR", "PELO", "PELA", "PELOS", "PELAS", "PARA", "COM", "SEM", "E", "OU", "MAS", "QUE", "SE",
                        "NÃO", "MEU", "MINHA", "MEUS", "MINHAS", "SEU", "SUA", "SEUS", "SUAS", "NOSSO", "NOSSA", "EU", "TU", "ELE", "ELA",
                        "VOCÊ", "VOCÊS", "ELES", "ELAS", "ME", "TE", "LHE", "MAIS", "MUITO"],
            decimalWords: ["virgula"], decimalMark: ",", ratioWords: [["em"]], percentWords: [["por", "cento"]], percentSign: "%",
            groupSeparator: ".", atoms: atoms, hundred: [], thousand: ["mil"], million: ["milhao", "milhoes"], connectors: ["e"])
    }()
}

/// Sentence ends for transcripts with or without punctuation: a terminal mark ends a sentence; a
/// pause of at least `pause` seconds after a few words ends it too, and so does a shorter one
/// (`capitalPause`) before a capitalised word the transcriber started a new segment with
/// ("répétitives [0.4 s] Tu as…"); a run-on longer than `maxWords` is split at its longest pause.
public enum SentenceSegmenter {
    static let terminal = Set(".?!…")

    /// Index ranges of `words` (inclusive bounds), in order, covering every word.
    public static func split(_ words: [(text: String, start: Double, end: Double)], pause: Double = 0.6, minWords: Int = 2,
                             maxWords: Int = 30, capitalPause: Double = 0.35) -> [ClosedRange<Int>] {
        guard !words.isEmpty else { return [] }
        var out: [ClosedRange<Int>] = []
        var start = 0
        func close(_ end: Int) { out.append(start...end); start = end + 1 }
        for i in words.indices {
            let last = i == words.count - 1
            if last { close(i); break }
            let t = words[i].text.trimmingCharacters(in: .whitespaces)
            let gap = words[i + 1].start - words[i].end
            let ends = t.last.map { terminal.contains($0) } ?? false
            let enough = i - start + 1 >= minWords
            let capital = words[i + 1].text.first?.isUppercase == true && !(t.last.map { ",;:".contains($0) } ?? false)
            if ends || (gap >= pause && enough) || (capital && gap >= capitalPause && enough) { close(i); continue }
            if i - start + 1 >= maxWords {
                // Split the run-on at its longest pause (the first one on ties), never leaving a 1-word piece.
                let lo = start + 1, hi = i - 1
                var best = i, bestGap = -1.0
                if lo <= hi {
                    for k in lo...hi {
                        let g = words[k + 1].start - words[k].end
                        if g > bestGap { bestGap = g; best = k }
                    }
                }
                close(best)
            }
        }
        if start < words.count { out.append(start...(words.count - 1)) }
        return out
    }
}
