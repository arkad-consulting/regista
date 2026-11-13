import Foundation

/// Beats and onsets of a music track (edit.beatSync, issue #16). Pure DSP on samples, no engine:
/// 1. onset strength every 10 ms: half-wave-rectified rise of the log energy in three bands (lows, mids, highs);
/// 2. tempo: autocorrelation of the onset strength between 70 and 180 BPM, weighted towards ~115 BPM;
/// 3. beats: dynamic programming over the onset strength with a penalty for straying from the tempo (Ellis 2007);
/// 4. onsets: local peaks of the onset strength well above its running level.
public enum BeatDetector {
    public struct Result: Sendable {
        public var tempo: Double
        /// Beat times, seconds.
        public var beats: [Double]
        /// Onset times (any hit, on or off the beat), seconds.
        public var onsets: [Double]
    }

    static let hop = 0.01

    public static func detect(_ audio: WAVAudio) -> Result {
        let ch = max(audio.channels, 1)
        var mono = [Float](repeating: 0, count: audio.frameCount)
        for i in mono.indices {
            var s: Float = 0
            for c in 0..<ch { s += audio.samples[i * ch + c] }
            mono[i] = s / Float(ch)
        }
        return detect(mono, rate: audio.sampleRate)
    }

    public static func detect(_ x: [Float], rate: Int) -> Result {
        let env = onsetStrength(x, rate: rate)
        guard env.count > 50 else { return Result(tempo: 0, beats: [], onsets: []) }
        let period = tempoPeriod(env)
        let beats = track(env, period: period).map { Double($0) * hop }
        return Result(tempo: 60 / (period * hop), beats: beats, onsets: onsets(env))
    }

    /// Onset strength per 10 ms hop.
    static func onsetStrength(_ x: [Float], rate: Int) -> [Double] {
        let h = max(Int(Double(rate) * hop), 1)
        let n = x.count / h
        guard n > 2 else { return [] }
        // One-pole low-passes split the signal into < 150 Hz, 150–2000 Hz, > 2000 Hz.
        func coeff(_ f: Double) -> Float { Float(1 - exp(-2 * Double.pi * f / Double(rate))) }
        let a1 = coeff(150), a2 = coeff(2000)
        var lp1: Float = 0, lp2: Float = 0
        var energy = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
        for i in 0..<(n * h) {
            let s = x[i]
            lp1 += a1 * (s - lp1)
            lp2 += a2 * (s - lp2)
            let bands = [lp1, lp2 - lp1, s - lp2]
            let k = i / h
            for b in 0..<3 { energy[b][k] += Double(bands[b] * bands[b]) }
        }
        var flux = [Double](repeating: 0, count: n)
        let weights = [1.0, 1.0, 0.8]
        for b in 0..<3 {
            var prev = log(1e-9 + energy[b][0] / Double(h))
            for k in 1..<n {
                let e = log(1e-9 + energy[b][k] / Double(h))
                flux[k] += weights[b] * max(0, e - prev)
                prev = e
            }
        }
        // Remove the slowly varying level (0.5 s moving mean) so only rises stand out.
        let w = 25
        var out = [Double](repeating: 0, count: n)
        var acc = 0.0
        var window: [Double] = []
        for k in 0..<n {
            window.append(flux[k]); acc += flux[k]
            if window.count > 2 * w { acc -= window.removeFirst() }
            out[k] = max(0, flux[k] - acc / Double(window.count))
        }
        return out
    }

    /// Beat period in hops (fractional), from the autocorrelation of the onset strength.
    static func tempoPeriod(_ env: [Double]) -> Double {
        let minLag = Int(60 / 180 / hop), maxLag = min(Int(60 / 70 / hop), env.count / 2)
        guard maxLag > minLag else { return 50 }
        var ac = [Double](repeating: 0, count: maxLag + 2)
        for lag in max(minLag - 1, 1)...(maxLag + 1) where lag < env.count {
            var s = 0.0
            for i in lag..<env.count { s += env[i] * env[i - lag] }
            ac[lag] = s / Double(env.count - lag)
        }
        var best = minLag, bestScore = -Double.infinity
        for lag in minLag...maxLag {
            let bpm = 60 / (Double(lag) * hop)
            let prior = exp(-0.5 * pow(log2(bpm / 115) / 0.9, 2))
            let score = ac[lag] * prior
            if score > bestScore { bestScore = score; best = lag }
        }
        // Parabolic refinement.
        let y0 = ac[best - 1], y1 = ac[best], y2 = ac[best + 1]
        let d = y0 - 2 * y1 + y2
        let shift = abs(d) > 1e-12 ? 0.5 * (y0 - y2) / d : 0
        return Double(best) + min(max(shift, -0.5), 0.5)
    }

    /// Beat positions (hop indices): best path through the onset strength with beats about one period apart.
    static func track(_ env: [Double], period: Double, tightness: Double = 120) -> [Int] {
        let n = env.count
        let peak = env.max() ?? 0
        guard peak > 0 else { return [] }
        let o = env.map { $0 / peak }
        var score = o
        var back = [Int](repeating: -1, count: n)
        let lo = Int((period / 2).rounded()), hi = Int((period * 2).rounded())
        for t in 0..<n {
            var best = 0.0, arg = -1
            if t >= lo {
                for prev in max(0, t - hi)...(t - lo) {
                    let penalty = -tightness * pow(log(Double(t - prev) / period), 2)
                    let s = score[prev] + penalty
                    if arg < 0 || s > best { best = s; arg = prev }
                }
            }
            if arg >= 0, best > 0 { score[t] = o[t] + best; back[t] = arg }
        }
        // End on the best score in the last period, then walk back.
        let tail = max(0, n - Int(period.rounded()))
        var t = (tail..<n).max { score[$0] < score[$1] } ?? n - 1
        var beats: [Int] = []
        while t >= 0 {
            beats.append(t)
            t = back[t]
        }
        beats.reverse()
        // The path runs on through silence at either end: drop leading/trailing beats with no onset near them.
        func strength(_ b: Int) -> Double { o[max(0, b - 3)...min(n - 1, b + 3)].max() ?? 0 }
        let sorted = beats.map(strength).sorted()
        let floor = 0.15 * (sorted.isEmpty ? 0 : sorted[sorted.count / 2])
        while let f = beats.first, strength(f) < floor { beats.removeFirst() }
        while let l = beats.last, strength(l) < floor { beats.removeLast() }
        return beats
    }

    /// Peaks of the onset strength above the running mean + 1.5 σ, at least 100 ms apart.
    static func onsets(_ env: [Double]) -> [Double] {
        let mean = env.reduce(0, +) / Double(env.count)
        let sd = sqrt(env.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(env.count))
        var out: [Double] = []
        var last = -1000
        for k in 1..<(env.count - 1) where env[k] > mean + 1.5 * sd && env[k] >= env[k - 1] && env[k] > env[k + 1] {
            if k - last >= 10 { out.append(Double(k) * hop); last = k }
        }
        return out
    }
}
