import Foundation

/// A clip's retiming (clip.speed, issue #16): a constant rate, a ramp of rates, a reversed play, or a frozen frame.
/// The clip still names the source range it uses (`sourceIn`…`sourceOut`); `duration` is how long that range lasts on
/// the timeline once retimed (frame-snapped, stored so `Clip.duration` stays cheap).
public struct Speed: Codable, Hashable, Sendable {
    public enum AudioMode: String, Codable, CaseIterable, Sendable {
        /// Time-stretched with the pitch kept (ffmpeg atempo on export, spectral time-pitch in the preview).
        case pitch
        /// Silent while retimed.
        case mute
    }

    /// Source seconds played per timeline second (0.5 = half speed, 2 = double). Ignored with `ramp` or `freeze`.
    public var rate: Double
    /// Rate keyframes over source time (seconds from `sourceIn`), eased between keys, held outside.
    public var ramp: [ScalarKey]?
    /// Plays the range backwards (from a reversed proxy of the range, `proxy`).
    public var reverse: Bool?
    /// The clip shows the frame at `sourceIn` for its whole duration.
    public var freeze: Bool?
    public var audio: AudioMode?
    /// Reversed copy of the source range (ffmpeg, in the project's media folder): what a reversed clip reads.
    public var proxy: String?
    /// Where this clip's part starts inside the proxy, seconds (the right half of a split reversed clip).
    public var proxyStart: Double?
    /// Timeline duration of the retimed range.
    public var duration: MediaTime

    public init(rate: Double = 1, duration: MediaTime) {
        self.rate = rate
        self.duration = duration
    }

    public static let minRate = 0.1
    public static let maxRate = 16.0
    /// Outside this range the sound is muted by default (time-stretch artefacts).
    public static let audibleRates = 0.25...4.0

    public var isRamp: Bool { ramp?.isEmpty == false && freeze != true }

    /// What the sound does: muted when reversed, frozen, asked to, or played too far from normal speed.
    public var effectiveAudio: AudioMode {
        if freeze == true || reverse == true { return .mute }
        if let a = audio { return a }
        if isRamp {
            let rates = ramp!.map(\.value)
            return rates.allSatisfy { Self.audibleRates.contains($0) } ? .pitch : .mute
        }
        return Self.audibleRates.contains(rate) ? .pitch : .mute
    }

    /// Rate at source offset `s` seconds.
    func rate(atSource s: Double) -> Double {
        guard isRamp else { return rate }
        let r = ScalarKey.value(ramp!, at: MediaTime(seconds: s))
        return min(max(r, Self.minRate), Self.maxRate)
    }

    /// Timeline seconds to play `span` source seconds (unsnapped).
    public func timelineSeconds(forSource span: Double) -> Double {
        if freeze == true { return duration.seconds }
        guard isRamp else { return span / min(max(rate, Self.minRate), Self.maxRate) }
        return table(span: span).t.last ?? 0
    }

    /// Source offset (seconds from `sourceIn`, playback direction applied) shown at timeline offset `t` seconds.
    public func sourceOffset(atTimeline t: Double, span: Double) -> Double {
        if freeze == true { return 0 }
        let s: Double
        if isRamp {
            let tab = table(span: span)
            s = Self.interpolate(t, xs: tab.t, ys: tab.s)
        } else {
            s = t * min(max(rate, Self.minRate), Self.maxRate)
        }
        let forward = min(max(s, 0), span)
        return reverse == true ? span - forward : forward
    }

    /// Source seconds already played (in playback order) at timeline offset `t`.
    public func consumed(atTimeline t: Double, span: Double) -> Double {
        if freeze == true { return 0 }
        let s = sourceOffset(atTimeline: t, span: span)
        return reverse == true ? span - s : s
    }

    /// Timeline offset (seconds from the clip start) at which forward source offset `s` plays (nil: never shown, e.g.
    /// frozen). For a reversed clip the mirrored position.
    public func timelineOffset(atSource s: Double, span: Double) -> Double? {
        if freeze == true { return nil }
        let x = reverse == true ? span - s : s
        if isRamp {
            let tab = table(span: span)
            return Self.interpolate(x, xs: tab.s, ys: tab.t)
        }
        return x / min(max(rate, Self.minRate), Self.maxRate)
    }

    /// (timeline, source) samples of a ramp: dt = ds / rate(s), integrated on a fine source grid.
    func table(span: Double) -> (t: [Double], s: [Double]) {
        let n = max(Int(span * 240), 16)
        let ds = span / Double(n)
        var t = [0.0], s = [0.0]
        t.reserveCapacity(n + 1); s.reserveCapacity(n + 1)
        var acc = 0.0
        for i in 0..<n {
            let mid = (Double(i) + 0.5) * ds
            acc += ds / rate(atSource: mid)
            t.append(acc)
            s.append(Double(i + 1) * ds)
        }
        return (t, s)
    }

    static func interpolate(_ x: Double, xs: [Double], ys: [Double]) -> Double {
        guard let last = xs.last, xs.count > 1 else { return ys.first ?? 0 }
        if x <= xs[0] { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 {
            let m = (lo + hi) / 2
            if xs[m] <= x { lo = m } else { hi = m }
        }
        let f = (x - xs[lo]) / max(xs[hi] - xs[lo], 1e-12)
        return ys[lo] + (ys[hi] - ys[lo]) * f
    }

    /// Pieces of the timeline with a constant rate each: (timeline start, timeline end, source start, source end),
    /// seconds from the clip start / `sourceIn`, forward source direction. One piece for a constant rate; a ramp is
    /// cut every `step` timeline seconds (video: a frame or two; audio: ~0.1 s).
    public func pieces(span: Double, step: Double) -> [(t0: Double, t1: Double, s0: Double, s1: Double)] {
        let total = duration.seconds
        guard isRamp else { return [(0, total, 0, freeze == true ? span : span)] }
        let tab = table(span: span)
        var out: [(Double, Double, Double, Double)] = []
        var t0 = 0.0
        let end = min(total, tab.t.last ?? total)
        while t0 < end - 1e-9 {
            let t1 = min(t0 + step, end)
            out.append((t0, t1, Self.interpolate(t0, xs: tab.t, ys: tab.s), Self.interpolate(t1, xs: tab.t, ys: tab.s)))
            t0 = t1
        }
        return out
    }
}

extension Clip {
    /// Length of the source range used (equal to `duration` unless the clip is retimed).
    public var sourceDuration: MediaTime { sourceOut - sourceIn }

    /// Source time shown at clip-relative timeline time `local`.
    public func sourceTime(atLocal local: MediaTime) -> MediaTime {
        guard let s = speed else { return sourceIn + local }
        return sourceIn + MediaTime(seconds: s.sourceOffset(atTimeline: local.seconds, span: sourceDuration.seconds))
    }

    /// Timeline time at which source time `source` plays (nil when it is outside the range or never shown).
    public func timelineTime(ofSource source: MediaTime) -> MediaTime? {
        guard source >= sourceIn, source <= sourceOut else { return nil }
        guard let s = speed else { return start + (source - sourceIn) }
        return s.timelineOffset(atSource: (source - sourceIn).seconds, span: sourceDuration.seconds).map { start + MediaTime(seconds: $0) }
    }
}
