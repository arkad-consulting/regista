import Foundation

/// Text helpers for matching a transcript to a script (Italian by default, French with `language: "fr"`).
/// - `numbersToWords("9,2 su 10, nel 2025 più di 11.000")` → "nove virgola due su dieci, nel duemilaventicinque più di undicimila"
/// - `numbersToWords("9,2 sur 10 en 2025", language: "fr")` → "neuf virgule deux sur dix en deux mille vingt cinq"
/// - `tokens(text)` → lowercase, accent-free word tokens for matching a transcript to a script.
public enum TextNorm {
    static let units = ["zero", "uno", "due", "tre", "quattro", "cinque", "sei", "sette", "otto", "nove", "dieci",
                        "undici", "dodici", "tredici", "quattordici", "quindici", "sedici", "diciassette",
                        "diciotto", "diciannove"]
    static let tens = ["", "", "venti", "trenta", "quaranta", "cinquanta", "sessanta", "settanta", "ottanta", "novanta"]

    static func below100(_ n: Int) -> String {
        if n < 20 { return units[n] }
        let (t, u) = n.quotientAndRemainder(dividingBy: 10)
        var w = tens[t]
        if u == 1 || u == 8 { w.removeLast() }   // ventuno, ventotto
        return w + (u > 0 ? units[u] : "")
    }

    static func below1000(_ n: Int) -> String {
        let (h, r) = n.quotientAndRemainder(dividingBy: 100)
        var w = h == 0 ? "" : (h == 1 ? "cento" : units[h] + "cento")
        if r > 0 {
            let rw = below100(r)
            if !w.isEmpty, rw.hasPrefix("o") { w.removeLast() }   // centotto
            w += rw
        }
        return w.isEmpty ? "zero" : w
    }

    public static func integerWords(_ n: Int) -> String {
        if n < 1000 { return below1000(n) }
        if n < 1_000_000 {
            let (k, r) = n.quotientAndRemainder(dividingBy: 1000)
            return (k == 1 ? "mille" : below1000(k) + "mila") + (r > 0 ? below1000(r) : "")
        }
        let (m, r) = n.quotientAndRemainder(dividingBy: 1_000_000)
        return (m == 1 ? "un milione" : integerWords(m) + " milioni") + (r > 0 ? " " + integerWords(r) : "")
    }

    /// Value of a spelled-out Italian number ("undicimila" → 11000), up to 999 999; nil for other words.
    public static func number(_ word: String) -> Int? { spelled[word.lowercased()] }

    static let spelled: [String: Int] = {
        var d: [String: Int] = [:]
        for n in 0..<10_000 { d[integerWords(n)] = n }
        for k in 10..<1000 { d[integerWords(k * 1000)] = k * 1000 }
        return d
    }()

    static let frUnits = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze", "douze",
                          "treize", "quatorze", "quinze", "seize", "dix sept", "dix huit", "dix neuf"]
    static let frTens = ["", "", "vingt", "trente", "quarante", "cinquante", "soixante"]

    /// French number words, words separated by spaces (aligners have no hyphen): 71 → "soixante et onze", 2025 → "deux mille vingt cinq".
    public static func frenchWords(_ n: Int) -> String {
        if n < 20 { return frUnits[n] }
        if n < 70 {
            let (t, u) = n.quotientAndRemainder(dividingBy: 10)
            return frTens[t] + (u == 1 ? " et un" : u > 0 ? " " + frUnits[u] : "")
        }
        if n < 80 { return "soixante" + (n == 71 ? " et onze" : " " + frUnits[n - 60]) }
        if n < 100 { return n == 80 ? "quatre vingts" : "quatre vingt " + frUnits[n - 80] }
        if n < 1000 {
            let (h, r) = n.quotientAndRemainder(dividingBy: 100)
            let head = h == 1 ? "cent" : frUnits[h] + " cent" + (r == 0 ? "s" : "")
            return head + (r > 0 ? " " + frenchWords(r) : "")
        }
        if n < 1_000_000 {
            let (k, r) = n.quotientAndRemainder(dividingBy: 1000)
            return (k == 1 ? "mille" : frenchWords(k) + " mille") + (r > 0 ? " " + frenchWords(r) : "")
        }
        let (m, r) = n.quotientAndRemainder(dividingBy: 1_000_000)
        return frenchWords(m) + (m == 1 ? " million" : " millions") + (r > 0 ? " " + frenchWords(r) : "")
    }

    /// Spells out digits: aligners and script matching work on words, not "9,2". Italian unless `language` is "fr".
    public static func numbersToWords(_ text: String, language: String? = nil) -> String {
        let french = language?.lowercased().hasPrefix("fr") == true
        let words: (Int) -> String = french ? frenchWords : integerWords
        let comma = french ? " virgule " : " virgola "
        let digit: (Int) -> String = { french ? frUnits[$0] : units[$0] }
        // Thousands groups: "11.000" (Italian), "11 000" / "11 000" (French).
        var s = replace(french ? #"\b\d{1,3}(?:[ \u00A0\u202F]\d{3})+\b"# : #"\b\d{1,3}(?:\.\d{3})+\b"#, in: text) { m in
            Int(m[0].filter(\.isNumber)).map(words) ?? m[0]
        }
        s = replace(#"\b(\d+),(\d+)\b"#, in: s) { m in
            guard let a = Int(m[1]) else { return m[0] }
            let b = m[2]
            if b.count > 1, b.hasPrefix("0") {
                return words(a) + comma + b.compactMap { $0.wholeNumberValue.map(digit) }.joined(separator: " ")
            }
            return words(a) + comma + (Int(b).map(words) ?? b)
        }
        if french { s = replace(#"(\d)\s?%"#, in: s) { m in m[1] + " pour cent" } }
        return replace(#"\b\d+\b"#, in: s) { m in Int(m[0]).map(words) ?? m[0] }
    }

    public static func stripAccents(_ s: String) -> String {
        s.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !CharacterSet.nonBaseCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    public static func tokens(_ text: String, language: String? = nil) -> [String] {
        let t = stripAccents(numbersToWords(text, language: language).lowercased())
            .replacingOccurrences(of: "'", with: " ").replacingOccurrences(of: "’", with: " ")
        var out: [String] = [], cur = ""
        for ch in t.unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) { cur.unicodeScalars.append(ch) }
            else if !cur.isEmpty { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Regex replace with a closure over the capture groups (group 0 = whole match).
    private static func replace(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            out = (out as NSString).replacingCharacters(in: m.range, with: transform(groups))
        }
        return out
    }
}

/// `difflib.SequenceMatcher(None, a, b).ratio()` for short strings (no junk heuristics: they
/// only kick in at 200+ elements). Used to score near-miss words ("chiede" vs "chiedi").
public enum SequenceSimilarity {
    public static func ratio(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return 2 * Double(matches(x, 0, x.count, y, 0, y.count)) / Double(x.count + y.count)
    }

    /// Total size of the matching blocks: longest common substring, then recurse on both sides
    /// (difflib's get_matching_blocks; ties go to the earliest match in a, then in b).
    static func matches(_ x: [Unicode.Scalar], _ alo: Int, _ ahi: Int, _ y: [Unicode.Scalar], _ blo: Int, _ bhi: Int) -> Int {
        var best = (i: alo, j: blo, k: 0)
        var lengths = [Int: Int]()   // j -> length of the match ending at (i-1, j)
        for i in alo..<ahi {
            var next = [Int: Int]()
            for j in blo..<bhi where x[i] == y[j] {
                let k = (lengths[j - 1] ?? 0) + 1
                next[j] = k
                if k > best.k { best = (i - k + 1, j - k + 1, k) }
            }
            lengths = next
        }
        guard best.k > 0 else { return 0 }
        return best.k + matches(x, alo, best.i, y, blo, best.j) + matches(x, best.i + best.k, ahi, y, best.j + best.k, bhi)
    }
}
