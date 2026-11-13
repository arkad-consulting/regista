import Foundation

/// Caption keywords to propose to the person editing by hand (captions.generate dryRun): the house rule — numbers,
/// brand and product names, the point of each line; one or two per sentence, never a stop word. Deterministic and
/// local (no model): the person accepts, removes or adds words before the captions are generated.
public enum KeywordSuggest {
    /// - sentences: the raw words of each spoken sentence, in order.
    /// - display: a raw word in the captions' display form ("tutti," → "TUTTI").
    /// - first: keywords that lead the list (the script's, flagged in the teleprompter).
    public static func suggest(sentences: [[String]], language: String?, display: (String) -> String,
                               first: [String] = [], limit: Int = 12) -> [String] {
        let profile = LanguageProfile.named(language)
        var out: [String] = []
        func add(_ w: String) {
            guard !w.isEmpty, out.count < limit, !out.contains(where: { $0.uppercased() == w.uppercased() }) else { return }
            out.append(w)
        }
        first.forEach(add)
        for words in sentences {
            var scored: [(word: String, score: Double)] = []
            for (k, raw) in words.enumerated() {
                let d = display(raw)
                let letters = d.filter(\.isLetter).count
                guard !d.isEmpty, !profile.isStopWord(d) else { continue }
                var score = 0.0
                if d.contains(where: \.isNumber) { score = 3 }
                else if k > 0, raw.first?.isUppercase == true { score = 2 }   // a name or a brand mid-sentence
                else if letters >= 6 { score = 1 + Double(letters) / 100 }    // the longer word carries the point
                if score > 0 { scored.append((d, score)) }
            }
            let ranked = scored.sorted { $0.score > $1.score }
            if let best = ranked.first { add(best.word) }
            if words.count >= 12, ranked.count > 1, ranked[1].score >= 2 { add(ranked[1].word) }
        }
        return out
    }

    /// Words split into sentences at a closing mark (. ? ! …) or after `maxWords`.
    public static func sentences(_ words: [String], maxWords: Int = 18) -> [[String]] {
        var out: [[String]] = [], cur: [String] = []
        for w in words {
            cur.append(w)
            if w.last.map({ ".?!…".contains($0) }) == true || cur.count >= maxWords { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
