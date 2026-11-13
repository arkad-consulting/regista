import Foundation

/// Pitch-preserving time stretch for retimed clips (clip.speed): WSOLA driven by an explicit time map, so every
/// output instant plays the source instant the picture shows, within the alignment search (±2.7 ms at 48 kHz).
/// ffmpeg's atempo drifts by tens of milliseconds and only knows constant rates; this one also does ramps.
public enum TimeStretch {
    /// Stretches interleaved `samples` (`channels`) so output sample i plays source position `map(i)` (samples, fractional).
    /// `length` output samples.
    public static func stretch(_ samples: [Float], channels: Int, length: Int, rate: Int, map: (Int) -> Double) -> [Float] {
        let ch = max(channels, 1)
        let frames = samples.count / ch
        guard length > 0, frames > 0 else { return [Float](repeating: 0, count: max(length, 0) * ch) }
        let n = max(Int(Double(rate) * 0.02) & ~1, 64)        // 20 ms frames
        let hop = n / 2
        let search = max(Int(Double(rate) * 0.0027), 4)       // ±2.7 ms alignment
        // Periodic Hann: overlapping halves sum to 1.
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames { var s: Float = 0; for c in 0..<ch { s += samples[i * ch + c] }; mono[i] = s / Float(ch) }
        func at(_ i: Int) -> Float { i >= 0 && i < frames ? mono[i] : 0 }

        var out = [Float](repeating: 0, count: (length + n) * ch)
        var prev: Int?
        var k = -1   // starts half a frame early so the first samples get both window halves
        while k * hop < length {
            let o = k * hop
            // Frame centre on the mapped source position.
            let nominal = Int(map(min(max(o + hop, 0), length - 1)).rounded()) - hop
            var best = nominal
            if let p = prev {
                // Natural continuation of the previous frame; pick the candidate that overlaps it best.
                let target = p + hop
                var bestScore = -Float.infinity
                for d in -search...search {
                    let c = nominal + d
                    var s: Float = 0
                    var j = 0
                    while j < hop { s += at(c + j) * at(target + j); j += 2 }
                    if s > bestScore { bestScore = s; best = c }
                }
            }
            for j in 0..<n where o + j >= 0 && o + j < length + n {
                let src = best + j
                guard src >= 0, src < frames else { continue }
                let w = window[j]
                for c in 0..<ch { out[(o + j) * ch + c] += samples[src * ch + c] * w }
            }
            prev = best
            k += 1
        }
        return Array(out[0..<(length * ch)])
    }
}
