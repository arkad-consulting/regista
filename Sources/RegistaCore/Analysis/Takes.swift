import Foundation

// Automatic take selection, ported from the Python prototype's `takes.py` (validated on the 2026-10-26 take:
// 10/10 lines picked the same take as the manual edit, cuts within 70 ms).
// 1. Viterbi-align every transcribed token to a script position (continue / skip / restart / insertion costs).
// 2. Split the path where the reader went back or jumped ahead: each run touching a line is a TAKE of it.
// 3. Per line pick the LAST complete take (starts at the line start, reaches its end, WER ≤ maxWer);
//    if none is complete, the best covered one.
// 4. Cut points: first word start / last word end, moved to the speech onset/offset on the 10 ms
//    energy envelope, plus padding; pauses longer than maxPause inside a take are tightened.
// Pure and deterministic: no engine, no LLM.

public struct TakeOptions: Codable, Hashable, Sendable {
    /// A take with a word error rate up to this (rounded to 0.01) counts as complete.
    public var maxWer = 0.3
    /// Pauses longer than this inside a take are cut out (seconds).
    public var maxPause = 0.7
    /// Silence kept on each side of a tightened pause.
    public var keepPause = 0.12
    /// Lead-in before the speech onset and tail after the offset (0.10 / 0.20 match the hand cuts of the 2026-10-26 reel).
    public var pre = 0.10
    public var post = 0.20

    public init() {}
}

/// A source range to keep, in asset time.
public struct CutRange: Codable, Hashable, Sendable {
    public var start: MediaTime
    public var end: MediaTime
    public var note: String
}

public struct Take: Codable, Hashable, Sendable {
    /// First / last aligned token, before padding.
    public var start: MediaTime
    public var end: MediaTime
    public var text: String
    public var coverage: Double
    public var wer: Double
    public var substitutions: Int
    public var insertions: Int
    public var deletions: Int
    public var fromStart: Bool
    public var toEnd: Bool
    public var complete: Bool
    /// Pauses longer than maxPause: (end of a word, start of the next), seconds.
    public var longPauses: [[Double]]
    /// What a cut keeps of this take (one range, or several when long pauses are removed).
    public var parts: [CutRange]
}

public struct TakeLine: Codable, Hashable, Sendable {
    public var text: String
    /// In recording order.
    public var takes: [Take]
    /// Index into `takes` picked by the rules (nil: the line was never read).
    public var auto: Int?
    /// Index into `takes` used by edit.autoCut: `auto` unless takes.select overrode it.
    public var chosen: Int?
}

public struct TakeSet: Codable, Hashable, Sendable {
    public var assetID: String
    public var options: TakeOptions
    public var lines: [TakeLine]
    /// "live" when built from the teleprompter's markers, nil (transcript alignment) otherwise.
    public var source: String?

    public init(assetID: String, options: TakeOptions, lines: [TakeLine]) {
        self.assetID = assetID
        self.options = options
        self.lines = lines
    }

    /// The picks of `old` (takes.select) carried over to this set when a line still has the same takes (new cut points
    /// for the same readings).
    public mutating func keepPicks(of old: TakeSet) {
        for i in lines.indices where i < old.lines.count && old.lines[i].takes.count == lines[i].takes.count {
            lines[i].chosen = old.lines[i].chosen
        }
    }

    /// The chosen parts of every line in script order, each tagged with its 1-based line; a part
    /// never runs into the next part's speech.
    public func segments() -> [(line: Int, range: CutRange)] {
        var segs: [(line: Int, range: CutRange)] = []
        for (li, line) in lines.enumerated() {
            guard let c = line.chosen else { continue }
            for p in line.takes[c].parts { segs.append((li + 1, p)) }
        }
        for k in segs.indices.dropLast() where segs[k].range.end > segs[k + 1].range.start && segs[k + 1].range.start > segs[k].range.start {
            segs[k].range.end = segs[k + 1].range.start
        }
        return segs
    }
}

public enum TakeFinder {
    struct Token {
        var text: String
        var start: Double
        var end: Double
        var word: Int
    }

    public static func find(script: Script, words: [Word], envelope: Envelope?, assetID: String,
                            options: TakeOptions = TakeOptions()) -> TakeSet {
        // Script tokens with their line.
        var S: [String] = [], sLine: [Int] = [], lineStart: [Int] = [], lineEnd: [Int] = []
        for (li, l) in script.lines.enumerated() {
            let tk = TextNorm.tokens(l)
            lineStart.append(S.count)
            S += tk
            sLine += Array(repeating: li, count: tk.count)
            lineEnd.append(S.count - 1)
        }
        let N = S.count
        var lines = script.lines.map { TakeLine(text: $0, takes: [], auto: nil, chosen: nil) }

        // Transcript tokens: a multi-token word ("9,2" → nove virgola due) shares its span by character length.
        var T: [Token] = []
        for (wi, w) in words.enumerated() {
            let tk = TextNorm.tokens(w.text)
            let total = max(tk.reduce(0) { $0 + $1.count }, 1)
            var t0 = w.start.seconds
            let span = w.end.seconds - w.start.seconds
            for t in tk {
                let d = span * Double(t.count) / Double(total)
                T.append(Token(text: t, start: t0, end: t0 + d, word: wi))
                t0 += d
            }
        }
        let M = T.count
        guard M > 0, N > 0 else { return TakeSet(assetID: assetID, options: options, lines: lines) }

        // Costs.
        var E = [[Double]](repeating: [Double](repeating: 0, count: N), count: M)
        var simCache: [String: Double] = [:]
        for i in 0..<M {
            for j in 0..<N {
                let key = T[i].text + "\u{1}" + S[j]
                let sim = simCache[key] ?? SequenceSimilarity.ratio(T[i].text, S[j])
                simCache[key] = sim
                E[i][j] = 3 * (1 - sim)
            }
        }
        let insertion = 2.0
        var isLineStart = [Bool](repeating: false, count: N)
        for s in lineStart where s < N { isLineStart[s] = true }
        var Tm = [[Double]](repeating: [Double](repeating: 6, count: N), count: N)
        for p in 0..<N {
            for j in 0..<N {
                if j == p + 1 { Tm[p][j] = 0 }
                else if j == p + 2 { Tm[p][j] = 1 }
                else if j == p + 3 { Tm[p][j] = 2 }
                else if j <= p, isLineStart[j] { Tm[p][j] = 2 }   // restart from a line start
                else if j <= p { Tm[p][j] = 3 }                    // restart mid-line
                else if isLineStart[j] { Tm[p][j] = 3 }            // jump forward to a later line
            }
        }

        // Viterbi with an insertion layer: D = token matched to j, I = token inserted while sitting at j.
        let inf = Double.infinity
        var D = [[Double]](repeating: [Double](repeating: inf, count: N), count: M)
        var I = D
        var bpD = [[Int]](repeating: [Int](repeating: 0, count: N), count: M)
        var bpDsrc = [[Bool]](repeating: [Bool](repeating: false, count: N), count: M)
        var bpI = bpDsrc
        for j in 0..<N { D[0][j] = E[0][j] + (isLineStart[j] ? 0 : 3) }
        for i in 1..<max(M, 1) {
            var B = [Double](repeating: inf, count: N), Bsrc = [Bool](repeating: false, count: N)
            for p in 0..<N { B[p] = min(D[i - 1][p], I[i - 1][p]); Bsrc[p] = I[i - 1][p] < D[i - 1][p] }
            for j in 0..<N {
                var best = inf, bp = 0
                for p in 0..<N {
                    let c = B[p] + Tm[p][j]
                    if c < best { best = c; bp = p }
                }
                D[i][j] = E[i][j] + best
                bpD[i][j] = bp
                bpDsrc[i][j] = Bsrc[bp]
                I[i][j] = B[j] + insertion
                bpI[i][j] = Bsrc[j]
            }
        }
        var j = 0, bestEnd = inf
        for k in 0..<N where min(D[M - 1][k], I[M - 1][k]) < bestEnd { bestEnd = min(D[M - 1][k], I[M - 1][k]); j = k }
        var ins = I[M - 1][j] < D[M - 1][j]
        var path = [(j: Int, ins: Bool)](repeating: (0, false), count: M)
        var i = M - 1
        while true {
            path[i] = (j, ins)
            if i == 0 { break }
            if ins { ins = bpI[i][j] } else { (j, ins) = (bpD[i][j], bpDsrc[i][j]) }
            i -= 1
        }

        // Runs: split where the reader went back or jumped to a new line.
        var runs: [[Int]] = [], cur: [Int] = []
        var lastJ: Int?
        for (i, step) in path.enumerated() {
            if let lj = lastJ, !step.ins, step.j <= lj || step.j > lj + 3 { runs.append(cur); cur = [] }
            cur.append(i)
            if !step.ins { lastJ = step.j }
        }
        runs.append(cur)

        // Takes per line.
        let (threshold, _) = envelope?.speechThreshold() ?? (0, 0)
        let onset = { (t: Double) in envelope?.onset(near: t, threshold: threshold) ?? t }
        let offset = { (t: Double) in envelope?.offset(near: t, threshold: threshold) ?? t }
        let round2 = { (x: Double) in (x * 100).rounded() / 100 }
        for run in runs {
            let touched = Set(run.filter { !path[$0].ins }.map { sLine[path[$0].j] }).sorted()
            for li in touched {
                let idx = run.filter { !path[$0].ins && sLine[path[$0].j] == li }
                let i0 = idx.first!, i1 = idx.last!
                let span = run.filter { i0 <= $0 && $0 <= i1 }
                let matched = span.filter { !path[$0].ins }
                let pos = matched.map { path[$0].j }
                let good = Set(matched.filter { E[$0][path[$0].j] <= 0.75 }.map { path[$0].j })
                let n = lineEnd[li] - lineStart[li] + 1
                let subs = matched.filter { E[$0][path[$0].j] > 0.75 }.count
                let inss = span.count - matched.count
                let dels = n - Set(pos).count
                let wordIdx = Set(span.map { T[$0].word }).sorted()
                let ws = wordIdx.map { words[$0] }
                let wer = round2(Double(subs + inss + dels) / Double(n))
                let fromStart = pos.min()! - lineStart[li] <= 1, toEnd = lineEnd[li] - pos.max()! <= 1

                lines[li].takes.append(Take(
                    start: MediaTime(seconds: T[i0].start), end: MediaTime(seconds: T[i1].end),
                    text: ws.map(\.text).joined(separator: " "), coverage: round2(Double(good.count) / Double(n)), wer: wer,
                    substitutions: subs, insertions: inss, deletions: dels, fromStart: fromStart, toEnd: toEnd,
                    complete: fromStart && toEnd && wer <= options.maxWer, longPauses: longPauses(ws, options),
                    parts: parts(ws, options, onset: onset, offset: offset)))
            }
        }

        for li in lines.indices where !lines[li].takes.isEmpty {
            lines[li].auto = pick(lines[li].takes)
            lines[li].chosen = lines[li].auto
        }
        return TakeSet(assetID: assetID, options: options, lines: lines)
    }

    /// The last complete take, else the best covered (then the lowest WER).
    static func pick(_ takes: [Take]) -> Int {
        if let lastComplete = takes.lastIndex(where: \.complete) { return lastComplete }
        var pick = 0
        for k in takes.indices.dropFirst()
        where takes[k].coverage > takes[pick].coverage || (takes[k].coverage == takes[pick].coverage && takes[k].wer < takes[pick].wer) {
            pick = k
        }
        return pick
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// Pauses longer than maxPause between consecutive words: (end of a word, start of the next).
    static func longPauses(_ ws: [Word], _ options: TakeOptions) -> [[Double]] {
        ws.indices.dropLast().filter { ws[$0 + 1].start.seconds - ws[$0].end.seconds > options.maxPause }
            .map { [round2(ws[$0].end.seconds), round2(ws[$0 + 1].start.seconds)] }
    }

    /// Cut ranges of a take's words, split at long pauses, moved to the speech onset/offset and padded.
    static func parts(_ ws: [Word], _ options: TakeOptions, onset: (Double) -> Double, offset: (Double) -> Double) -> [CutRange] {
        var parts: [[Word]] = [[ws[0]]]
        for w in ws.dropFirst() {
            if w.start.seconds - parts[parts.count - 1].last!.end.seconds > options.maxPause { parts.append([w]) }
            else { parts[parts.count - 1].append(w) }
        }
        return parts.enumerated().map { pi, p -> CutRange in
            let first = pi == 0, last = pi == parts.count - 1
            let s = onset(p.first!.start.seconds) - (first ? options.pre : options.keepPause)
            let e = offset(p.last!.end.seconds) + (last ? options.post : options.keepPause)
            let note = first ? "" : String(format: "pause %.2fs removed", p.first!.start.seconds - parts[pi - 1].last!.end.seconds)
            return CutRange(start: MediaTime(seconds: max(s, 0)), end: MediaTime(seconds: e), note: note)
        }
    }
}

/// Compares the timeline's cuts with a hand edit in the Python prototype's `segments.json` form
/// (`{"segments": [{"in", "out", "line": 3 | "4-5"}]}`): same take per line, in/out errors.
public enum TakeComparison {
    public struct Row: Sendable {
        public var line: Int
        public var autoTake: String?
        public var manualTake: String?
        public var autoIn: Double?, autoOut: Double?
        public var manualIn: Double?, manualOut: Double?
        public var inErrMs: Double? { autoIn.flatMap { a in manualIn.map { ((a - $0) * 1000).rounded() } } }
        public var outErrMs: Double? { autoOut.flatMap { a in manualOut.map { ((a - $0) * 1000).rounded() } } }
        public var sameTake: Bool { autoTake != nil && autoTake == manualTake }
    }

    static func lines(of v: JSONValue?) -> [Int] {
        if let n = v?.doubleValue { return [Int(n)] }
        let parts = (v?.stringValue ?? "").split(separator: "-").compactMap { Int($0) }
        guard let lo = parts.first else { return [] }
        return Array(lo...(parts.last ?? lo))
    }

    /// `kept`: the timeline's source ranges in order, each with the line it belongs to.
    public static func compare(takes: TakeSet, kept: [(line: Int, start: Double, end: Double)], reference: JSONValue) -> [Row] {
        var manual: [Int: [JSONValue]] = [:]
        for s in reference["segments"]?.arrayValue ?? [] {
            for ln in lines(of: s["line"]) { manual[ln, default: []].append(s) }
        }
        return takes.lines.indices.map { li -> Row in
            let ln = li + 1
            let line = takes.lines[li]
            let label = { (k: Int) in "\(k + 1)/\(line.takes.count)" }
            let auto = kept.filter { $0.line == ln }
            var row = Row(line: ln, autoTake: line.chosen.map(label), manualTake: nil,
                          autoIn: auto.first?.start, autoOut: auto.last?.end, manualIn: nil, manualOut: nil)
            if let segs = manual[ln], let first = segs.first, let last = segs.last {
                // A boundary inside a multi-line segment ("4-5") has no manual cut to compare with.
                if lines(of: first["line"]).first == ln { row.manualIn = first["in"]?.doubleValue }
                if lines(of: last["line"]).last == ln { row.manualOut = last["out"]?.doubleValue }
                let lo = segs.compactMap { $0["in"]?.doubleValue }.min() ?? 0
                let hi = segs.compactMap { $0["out"]?.doubleValue }.max() ?? 0
                let overlaps = line.takes.map { max(0, min($0.end.seconds, hi) - max($0.start.seconds, lo)) }
                if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 {
                    // First maximum, like numpy.argmax.
                    row.manualTake = label(overlaps.firstIndex(of: overlaps[best])!)
                }
            }
            return row
        }
    }
}
