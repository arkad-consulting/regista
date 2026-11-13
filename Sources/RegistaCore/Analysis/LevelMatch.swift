import Foundation

/// Per-segment level matching before the voice chain (audio.clean): a second voice off the
/// microphone (the interviewer behind the phone, a partner in a skit) can sit 15–20 dB under the
/// speaker. Speech is cut into segments at short silences; each segment's level (power mean of its
/// speech frames, plus the gain its take already gets) is compared with the main speaker's (the
/// duration-weighted median of all segments); a segment more than `threshold` dB away is gained
/// toward it, by at most `cap` dB (raising further would lift the room as much as the voice). Gains
/// ramp in and out over 30 ms around the segment, in the silence that bounds it.
public enum LevelMatch {
    public struct Segment: Hashable, Sendable {
        public var start: Double
        public var end: Double
        /// Level against the main speaker, dB (negative = quieter).
        public var relative: Double
        /// Gain applied, dB.
        public var gain: Double
    }

    /// Speech segments of `ranges` (seconds) on a 10 ms envelope: runs above the speech threshold, gaps
    /// shorter than `gap` bridged, at least `minLength` long. Each comes with its level, dB.
    public static func segments(_ envelope: Envelope, ranges: [(start: Double, end: Double)], gap: Double = 0.25,
                                minLength: Double = 0.3) -> [(start: Double, end: Double, level: Double)] {
        let (threshold, _) = envelope.speechThreshold(aboveFloor: 6)   // low enough to keep a quiet voice
        var out: [(Double, Double, Double)] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            let f0 = max(envelope.frame(r.start), 0), f1 = min(envelope.frame(r.end), envelope.db.count)
            guard f0 < f1 else { continue }
            var runs: [(Int, Int)] = []
            var f = f0
            while f < f1 {
                guard envelope.db[f] >= threshold else { f += 1; continue }
                var g = f
                while g < f1, envelope.db[g] >= threshold { g += 1 }
                if let last = runs.last, Double(f - last.1) * Envelope.hop < gap { runs[runs.count - 1].1 = g } else { runs.append((f, g)) }
                f = g
            }
            for (a, b) in runs where Double(b - a) * Envelope.hop >= minLength {
                let loud = envelope.db[a..<b].filter { $0 >= threshold }
                let power = loud.map { pow(10, $0 / 10) }.reduce(0, +) / Double(max(loud.count, 1))
                out.append((Double(a) * Envelope.hop, Double(b) * Envelope.hop, 10 * log10(power + 1e-12)))
            }
        }
        return out
    }

    /// Gains for segments with levels (already including their take's gain): the main level is the
    /// duration-weighted median; segments beyond `threshold` dB get the difference, capped at `cap`.
    public static func match(_ segs: [(start: Double, end: Double, level: Double)], threshold: Double = 6, cap: Double = 12) -> (main: Double, segments: [Segment]) {
        guard !segs.isEmpty else { return (0, []) }
        let byLevel = segs.sorted { $0.level < $1.level }
        let total = segs.map { $0.end - $0.start }.reduce(0, +)
        var acc = 0.0, main = byLevel.last!.level
        for s in byLevel {
            acc += s.end - s.start
            if acc >= total / 2 { main = s.level; break }
        }
        return (main, segs.map { s in
            let d = main - s.level
            let gain = threshold > 0 && abs(d) > threshold ? (d > 0 ? min(d, cap) : max(d, -cap)) : 0
            return Segment(start: s.start, end: s.end, relative: (-d * 10).rounded() / 10, gain: (gain * 10).rounded() / 10)
        })
    }

    /// Linear gain per sample: the take gains (dB per range, switching halfway between ranges) plus the
    /// segment gains, ramped over `ramp` seconds just outside each segment.
    public static func curve(count: Int, rate: Int, ranges: [(start: Double, end: Double)], rangeGains: [Double],
                             segments: [Segment], ramp: Double = 0.03) -> [Float] {
        var db = [Float](repeating: 0, count: count)
        let order = ranges.indices.sorted { ranges[$0].start < ranges[$1].start }
        if !order.isEmpty {
            var from = 0
            for (k, idx) in order.enumerated() {
                let to = k + 1 < order.count
                    ? min(count, Int(((ranges[idx].end + ranges[order[k + 1]].start) / 2 * Double(rate)).rounded())) : count
                if from < to { for i in from..<to { db[i] = Float(rangeGains[idx]) } }
                from = max(from, to)
            }
        }
        let r = max(Int(ramp * Double(rate)), 1)
        for s in segments where s.gain != 0 {
            let a = Int(s.start * Double(rate)), b = Int(s.end * Double(rate))
            for i in max(a - r, 0)..<min(b + r, count) {
                let w: Float = i < a ? Float(i - (a - r)) / Float(r) : i >= b ? Float(b + r - i) / Float(r) : 1
                db[i] += Float(s.gain) * w
            }
        }
        return db.map { pow(10, $0 / 20) }
    }
}
