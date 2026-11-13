import CryptoKit
import Foundation

/// A/V sync of a processed audio file against the original: cross-correlation of the two signals
/// over a few speech windows. The original is locked to the picture, so the lag is the drift
/// the processing introduced.
public enum SyncCheck {
    public struct Result: Sendable {
        /// Positive: the processed audio is late.
        public var lagSeconds: Double
        /// Normalized correlation at that lag (0…1).
        public var correlation: Double
    }

    /// `windows` in seconds of both files; lags searched within ±maxLag.
    public static func lag(original: [Float], processed: [Float], sampleRate: Int,
                           windows: [(start: Double, end: Double)], maxLag: Double = 0.1) -> Result {
        // Decimate to ~8 kHz (box average): plenty for speech, 36× fewer operations.
        let factor = max(sampleRate / 8000, 1)
        let rate = Double(sampleRate) / Double(factor)
        func decimate(_ x: [Float]) -> [Double] {
            stride(from: 0, to: x.count - factor + 1, by: factor).map { i in
                var s: Float = 0
                for k in 0..<factor { s += x[i + k] }
                return Double(s) / Double(factor)
            }
        }
        let a = decimate(original), b = decimate(processed)
        let maxL = Int(maxLag * rate)
        var sums = [Double](repeating: 0, count: 2 * maxL + 1)
        var used = 0
        for w in windows {
            let lo = Int(w.start * rate), hi = Int(w.end * rate)
            guard lo - maxL >= 0, hi + maxL <= min(a.count, b.count), hi > lo else { continue }
            let ref = Array(a[lo..<hi])
            let refNorm = ref.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard refNorm > 0 else { continue }
            for l in -maxL...maxL {
                var dot = 0.0, norm = 0.0
                for i in 0..<ref.count {
                    let v = b[lo + i + l]
                    dot += ref[i] * v
                    norm += v * v
                }
                if norm > 0 { sums[l + maxL] += dot / (refNorm * norm.squareRoot()) }
            }
            used += 1
        }
        guard used > 0, let best = sums.indices.max(by: { sums[$0] < sums[$1] }) else { return Result(lagSeconds: 0, correlation: 0) }
        return Result(lagSeconds: Double(best - maxL) / rate, correlation: sums[best] / Double(used))
    }
}

public enum FileDigest {
    /// SHA-256 of a file, hex, streamed in 4 MB chunks.
    public static func sha256(_ url: URL) throws -> String {
        guard let h = FileHandle(forReadingAtPath: url.path) else { throw CommandError(.io, "Cannot read \(url.path)") }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
