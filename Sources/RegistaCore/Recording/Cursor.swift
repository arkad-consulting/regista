import Foundation

// The drawn cursor (issue #42): a take recorded without the system cursor gets it back from session.json's 30 Hz log,
// drawn by the compositor on the screen layer (so it follows the crop and zoom keyframes): smoothed by a critically
// damped spring, bigger, hidden when idle, a ripple on each click. This file is the pure part: the style, the path
// and what to draw at a given instant (CursorOverlay); RegistaEngines/CursorRasterizer draws it.

/// The standard macOS cursor shapes logged while recording (NSCursor's), arrow for anything else.
public enum CursorKind: String, CaseIterable, Codable, Hashable, Sendable {
    case arrow, pointingHand, iBeam, crosshair, openHand, closedHand, resizeLeftRight, resizeUpDown, notAllowed,
         contextualMenu, dragCopy, dragLink

    public init(logged: String?) { self = logged.flatMap(CursorKind.init(rawValue:)) ?? .arrow }
}

/// How the drawn cursor looks (cursor.style), stored on the recording.
public struct CursorStyle: Codable, Hashable, Sendable {
    public var visible = true
    /// Size relative to the system cursor.
    public var scale = 1.5
    /// 0 = the raw path; up to 1 = very smooth (spring angular frequency 40 · 0.15^smoothing rad/s).
    public var smoothing = 0.5
    /// Fade out after `idleAfter` s without movement or click, back when it moves.
    public var hideWhenIdle = true
    /// An expanding ring at each click.
    public var clickRipple = true
    /// Ripple colour, hex (default white).
    public var color: String?

    public static let idleAfter = 2.0
    public static let fadeOut = 0.3
    /// The cursor reappears this long before it starts moving (the path is known in advance).
    public static let fadeIn = 0.15
    public static let rippleDuration = 0.4

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.5
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.5
        hideWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .hideWhenIdle) ?? true
        clickRipple = try c.decodeIfPresent(Bool.self, forKey: .clickRipple) ?? true
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    /// Angular frequency of the smoothing spring, rad/s (stiffness ω², critical damping 2ω); nil = no smoothing.
    public var springOmega: Double? { smoothing <= 0 ? nil : 40 * pow(0.15, min(smoothing, 1)) }
}

/// What the compositor draws over one screen frame. Positions are screen.mov pixels (top-left origin), so the cursor
/// is drawn on the source picture before its crop.
public struct CursorOverlay: Hashable, Sendable {
    public struct Ripple: Hashable, Sendable {
        public var x: Double
        public var y: Double
        /// 0 at the click → 1 when it has faded.
        public var progress: Double
    }

    /// Hot spot position.
    public var x: Double
    public var y: Double
    public var kind: CursorKind
    /// Source pixels per cursor point (the screen's pixels per point × style scale).
    public var size: Double
    public var opacity: Double
    public var ripples: [Ripple]
    public var color: String?
}

/// A take's cursor, ready to be sampled at any instant: the logged samples, the spring-smoothed path, the moments of
/// activity (for the idle fade) and the clicks.
public struct CursorPath: Sendable {
    public var style: CursorStyle
    /// Session time of screen.mov's first frame (screen time u = session time − offset).
    public var offset: Double
    public var pixelsPerPoint: Double
    let samples: [RecordingSession.CursorSample]
    let smoothed: [[Double]]
    let activity: [Double]
    let clicks: [(t: Double, x: Double, y: Double)]
    public static let rate = 120.0

    public init(session: RecordingSession, style: CursorStyle, offset: Double) {
        self.style = style
        self.offset = offset
        pixelsPerPoint = session.source("screen")?.scale ?? 2
        samples = (session.cursor ?? []).sorted { $0.t < $1.t }
        smoothed = Self.spring(samples, omega: style.springOmega, rate: Self.rate)
        clicks = session.events.filter { ($0.kind == "click" || $0.kind == "rightClick") && $0.x != nil && $0.y != nil }
            .map { (t: $0.t, x: $0.x!, y: $0.y!) }.sorted { $0.t < $1.t }
        activity = Self.activity(samples, threshold: 0.5 * pixelsPerPoint, clicks: clicks.map(\.t))
    }

    /// The raw path at session time `t` (linear between samples, held outside them).
    public static func raw(_ s: [RecordingSession.CursorSample], at t: Double) -> [Double] {
        guard let first = s.first else { return [0, 0] }
        if t <= first.t { return [first.x, first.y] }
        let n = upperBound(s.count) { s[$0].t <= t }
        guard n < s.count else { return [s[s.count - 1].x, s[s.count - 1].y] }
        let a = s[n - 1], b = s[n]
        let f = (t - a.t) / max(b.t - a.t, 1e-9)
        return [a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f]
    }

    /// The path through a critically damped spring of angular frequency `omega` chasing the raw path, sampled at
    /// `rate` from the first sample (exact step solution: stable at any stiffness). nil omega = the raw path.
    public static func spring(_ s: [RecordingSession.CursorSample], omega: Double?, rate: Double) -> [[Double]] {
        guard let first = s.first, let last = s.last else { return [] }
        let n = Int(((last.t - first.t) * rate).rounded(.up)) + 1
        let dt = 1 / rate
        guard let w = omega else { return (0..<n).map { raw(s, at: first.t + Double($0) * dt) } }
        var p = [first.x, first.y], v = [0.0, 0.0]
        var out: [[Double]] = [p]
        out.reserveCapacity(n)
        let decay = exp(-w * dt)
        for i in 1..<max(n, 1) {
            let target = raw(s, at: first.t + Double(i) * dt)
            for k in 0..<2 {
                // x(t) = target + (e0 + (v0 + ω e0) t) e^{−ωt}
                let e = p[k] - target[k], c = v[k] + w * e
                p[k] = target[k] + (e + c * dt) * decay
                v[k] = (c - w * (e + c * dt)) * decay
            }
            out.append(p)
        }
        return out
    }

    /// Session times when the cursor moved (more than `threshold` pixels since the previous sample) or clicked, sorted.
    /// The first sample counts as activity (the cursor shows at the start).
    public static func activity(_ s: [RecordingSession.CursorSample], threshold: Double, clicks: [Double]) -> [Double] {
        var out: [Double] = s.first.map { [$0.t] } ?? []
        for i in s.indices.dropFirst() where hypot(s[i].x - s[i - 1].x, s[i].y - s[i - 1].y) > threshold { out.append(s[i].t) }
        return (out + clicks).sorted()
    }

    /// Cursor opacity at `t`: 1 up to `idleAfter` s after the last activity, fading out over `fadeOut` s, fading back
    /// in over the `fadeIn` s before the next activity.
    public static func idleOpacity(at t: Double, activity: [Double]) -> Double {
        guard !activity.isEmpty else { return 1 }
        let n = upperBound(activity.count) { activity[$0] <= t }
        var out = 0.0
        if n > 0 {
            let idle = t - activity[n - 1]
            out = idle <= CursorStyle.idleAfter ? 1 : max(0, 1 - (idle - CursorStyle.idleAfter) / CursorStyle.fadeOut)
        }
        if n < activity.count { out = max(out, min(1, max(0, 1 - (activity[n] - t) / CursorStyle.fadeIn))) }
        return out
    }

    /// What to draw at screen time `u` (seconds of screen.mov); nil when nothing shows.
    public func overlay(atScreen u: Double) -> CursorOverlay? {
        guard style.visible, let first = samples.first, !smoothed.isEmpty else { return nil }
        let t = u + offset
        let x = (t - first.t) * Self.rate
        let i = min(max(Int(x.rounded(.down)), 0), smoothed.count - 1), j = min(i + 1, smoothed.count - 1)
        let f = min(max(x - Double(i), 0), 1)
        let pos = [smoothed[i][0] + (smoothed[j][0] - smoothed[i][0]) * f, smoothed[i][1] + (smoothed[j][1] - smoothed[i][1]) * f]
        let n = Self.upperBound(samples.count) { samples[$0].t <= t }
        let kind = CursorKind(logged: samples[max(n - 1, 0)].kind)
        let opacity = style.hideWhenIdle ? Self.idleOpacity(at: t, activity: activity) : 1
        let ripples: [CursorOverlay.Ripple] = style.clickRipple ? clicks.compactMap { c in
            let p = (t - c.t) / CursorStyle.rippleDuration
            return p >= 0 && p < 1 ? CursorOverlay.Ripple(x: c.x, y: c.y, progress: p) : nil
        } : []
        guard opacity > 0.001 || !ripples.isEmpty else { return nil }
        return CursorOverlay(x: pos[0], y: pos[1], kind: kind, size: pixelsPerPoint * style.scale, opacity: opacity,
                             ripples: ripples, color: style.color)
    }

    /// First index in 0..<count where `pred` is false (pred true on a prefix).
    static func upperBound(_ count: Int, _ pred: (Int) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pred(mid) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// Parsed and smoothed cursor paths shared by every RenderJob (a frame render builds one per call): keyed by the
/// session file, its modification date and the style.
public enum CursorPaths {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CursorPath] = [:]

    /// Screen asset id → its drawn cursor, for every recording of `project` recorded without the system cursor.
    public static func paths(for project: Project) -> [String: CursorPath] {
        var out: [String: CursorPath] = [:]
        for link in project.recordings ?? [] where link.cursorInVideo == false {
            guard let screen = link.screen, (link.cursor ?? CursorStyle()).visible, let path = path(for: link) else { continue }
            out[screen] = path
        }
        return out
    }

    static func path(for link: RecordingLink) -> CursorPath? {
        let style = link.cursor ?? CursorStyle()
        let date = (try? FileManager.default.attributesOfItem(atPath: link.session)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(link.session)|\(date)|\(style.hashValue)|\(link.offsets["screen"] ?? 0)"
        if let hit = lock.withLock({ cache[key] }) { return hit }
        guard let session = try? RecordingSession.load(URL(fileURLWithPath: link.session)) else { return nil }
        let path = CursorPath(session: session, style: style, offset: link.offsets["screen"] ?? 0)
        lock.withLock {
            if cache.count > 16 { cache.removeAll() }
            cache[key] = path
        }
        return path
    }
}
