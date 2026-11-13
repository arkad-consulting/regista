import Foundation

/// The house loudness targets: one source for audio.clean, export.render, the Audio panel, the meter and the Export
/// checks (the reel recipe's rule: a voice at −15 LUFS integrated, true peak at most −1.5 dBTP).
public enum LoudnessTarget {
    /// Integrated loudness, LUFS.
    public static let integrated = -15.0
    /// True-peak ceiling, dBTP.
    public static let truePeak = -1.5
    /// LU either side of `integrated` that still count as on target.
    public static let tolerance = 1.0

    public enum Verdict: String, Sendable {
        case unmeasured, ok, tooQuiet, tooLoud
    }

    /// The integrated level against the target (the peak is judged apart: `peakOver`).
    public static func verdict(integrated lufs: Double) -> Verdict {
        guard lufs.isFinite else { return .unmeasured }
        if lufs < integrated - tolerance { return .tooQuiet }
        if lufs > integrated + tolerance { return .tooLoud }
        return .ok
    }

    /// The true peak is over the ceiling (a tenth of a dB of rounding allowed).
    public static func peakOver(_ dBTP: Double) -> Bool { dBTP.isFinite && dBTP > truePeak + 0.05 }

    /// "-15", "-1.5": for command help text.
    public static func text(_ v: Double) -> String { String(format: "%g", v) }
}
