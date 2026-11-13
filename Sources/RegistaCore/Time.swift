import Foundation

/// An exact rational number (frame rates, ffprobe time bases).
public struct Rational: Codable, Hashable, Sendable, CustomStringConvertible {
    public var num: Int64
    public var den: Int64

    public init(_ num: Int64, _ den: Int64 = 1) {
        precondition(den != 0, "zero denominator")
        let g = Self.gcd(abs(num), abs(den))
        let sign: Int64 = den < 0 ? -1 : 1
        self.num = sign * num / max(g, 1)
        self.den = sign * den / max(g, 1)
    }

    /// Parses "30/1", "30000/1001" or "25" (ffprobe style). Nil for "0/0" or garbage.
    public init?(parsing s: String) {
        let parts = s.split(separator: "/").map { Int64($0.trimmingCharacters(in: .whitespaces)) }
        switch parts.count {
        case 1: guard let n = parts[0], n > 0 else { return nil }; self.init(n)
        case 2: guard let n = parts[0], let d = parts[1], n > 0, d > 0 else { return nil }; self.init(n, d)
        default: return nil
        }
    }

    public var doubleValue: Double { Double(num) / Double(den) }
    public var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? a : gcd(b, a % b) }
}

/// A point or a duration on a timeline, as an integer number of ticks.
///
/// One tick is 1/705 600 000 s (a "flick"): every common frame rate (23.976, 24, 25, 29.97,
/// 30, 50, 59.94, 60, 120) and audio rate (44.1, 48, 96 kHz) lands on a whole number of ticks,
/// so edits never drift. Seconds (Double) only exist at the edges: JSON params and summaries.
/// All conversions live here.
public struct MediaTime: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let ticksPerSecond: Int64 = 705_600_000

    public var ticks: Int64

    public init(ticks: Int64) { self.ticks = ticks }

    /// Nearest tick to a duration in seconds.
    public init(seconds: Double) {
        ticks = Int64((seconds * Double(Self.ticksPerSecond)).rounded())
    }

    /// `value` units of `1/timescale` s (ffprobe `duration_ts` × `time_base`), exact when the
    /// time scale divides the tick rate, rounded to the nearest tick otherwise.
    public init(value: Int64, timescale: Int64) {
        let (p, overflow) = value.multipliedReportingOverflow(by: Self.ticksPerSecond)
        if !overflow, p % timescale == 0 {
            self.init(ticks: p / timescale)
        } else {
            self.init(seconds: Double(value) / Double(timescale))
        }
    }

    public static let zero = MediaTime(ticks: 0)

    public var seconds: Double { Double(ticks) / Double(Self.ticksPerSecond) }

    /// Seconds rounded to the microsecond, for summaries meant to be read (and compared).
    public var displaySeconds: Double { (seconds * 1_000_000).rounded() / 1_000_000 }

    /// Duration of one frame at `rate`, in ticks (rounded for exotic rates).
    public static func frameDuration(at rate: Rational) -> MediaTime {
        let (p, overflow) = ticksPerSecond.multipliedReportingOverflow(by: rate.den)
        if !overflow, p % rate.num == 0 { return MediaTime(ticks: p / rate.num) }
        return MediaTime(seconds: 1 / rate.doubleValue)
    }

    /// Nearest frame boundary at `rate`.
    public func snapped(to rate: Rational) -> MediaTime {
        let frame = Self.frameDuration(at: rate).ticks
        guard frame > 0 else { return self }
        let frames = (ticks >= 0 ? ticks + frame / 2 : ticks - frame / 2) / frame
        return MediaTime(ticks: frames * frame)
    }

    public var description: String { String(format: "%.6fs", seconds) }

    public static func < (a: MediaTime, b: MediaTime) -> Bool { a.ticks < b.ticks }
    public static func + (a: MediaTime, b: MediaTime) -> MediaTime { MediaTime(ticks: a.ticks + b.ticks) }
    public static func - (a: MediaTime, b: MediaTime) -> MediaTime { MediaTime(ticks: a.ticks - b.ticks) }
    public static func += (a: inout MediaTime, b: MediaTime) { a.ticks += b.ticks }
    public static func -= (a: inout MediaTime, b: MediaTime) { a.ticks -= b.ticks }

    // Stored as a bare integer of ticks in project.json.
    public init(from decoder: Decoder) throws {
        ticks = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(ticks)
    }
}
