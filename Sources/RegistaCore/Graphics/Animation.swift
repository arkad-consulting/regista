import Foundation

/// Shape of the move from one keyframe to the next (the curve belongs to the keyframe it leaves).
public enum Easing: String, Codable, CaseIterable, Sendable {
    case linear, easeIn, easeOut, easeInOut, expoOut, backOut, hold
    /// A critically damped spring released at rest, normalised to the move's duration: it starts at once, travels
    /// most of the way early and settles onto the target with no overshoot (camera moves, issue #43).
    case spring

    /// Progress 0…1 → eased progress (backOut overshoots above 1 before settling).
    public func apply(_ f: Double) -> Double {
        let x = min(max(f, 0), 1)
        switch self {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: return 1 - pow(1 - x, 3)
        case .easeInOut: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .expoOut: return x >= 1 ? 1 : 1 - pow(2, -10 * x)
        case .backOut:
            let c1 = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
        case .hold: return x >= 1 ? 1 : 0
        case .spring: return Self.spring(x)
        }
    }

    /// ω·T of the spring: the step response 1 − (1 + ωt)·e^(−ωt) is 99.3 % there at the end of the move, the rest is
    /// spread by dividing by the end value, so 0 → 0 and 1 → 1 exactly and the arrival speed is ~2 % of the peak.
    static let springOmega = 7.0

    static func spring(_ x: Double) -> Double {
        func y(_ u: Double) -> Double { let w = springOmega * u; return 1 - (1 + w) * exp(-w) }
        return y(x) / y(1)
    }

    static let names = allCases.map(\.rawValue)
}

/// A keyframed number (effect strength), clip-relative time.
public struct ScalarKey: Codable, Hashable, Sendable {
    public var time: MediaTime
    public var value: Double
    public var easing: Easing?

    public init(time: MediaTime, value: Double, easing: Easing? = nil) {
        self.time = time
        self.value = value
        self.easing = easing
    }

    /// Value of a sorted key list at `t` (held outside, eased in between).
    public static func value(_ keys: [ScalarKey], at t: MediaTime) -> Double {
        guard let first = keys.first else { return 0 }
        if t <= first.time { return first.value }
        guard let next = keys.firstIndex(where: { $0.time > t }) else { return keys.last!.value }
        let a = keys[next - 1], b = keys[next]
        let f = Double((t - a.time).ticks) / Double((b.time - a.time).ticks)
        return a.value + (b.value - a.value) * (a.easing ?? .linear).apply(f)
    }
}

/// Ready-made in/out animations, written as ordinary transform keyframes on the clip (so they can be
/// inspected, tweaked with clip.keyframe and undone). Times are clip-relative; the clip's static
/// transform is the resting state.
public enum AnimationPreset: String, CaseIterable, Sendable {
    /// Scale 0.6 → 1 with a small overshoot, fade in; out: shrink a little and fade.
    case pop
    /// Rise from 4% of the frame below, expo ease; out: drift up and fade.
    case slideUp
    /// Drop from 4% above; out: drift down and fade.
    case slideDown
    case fade
    /// Slow push-in over the whole clip (1 → 1.08) with a slight drift: stills and inserts.
    case kenBurns
    /// Drops in from above with two small bounces (stickers); out: fade.
    case bounce
    /// No animation (removes the keyframes).
    case none

    public static let names = allCases.map(\.rawValue)

    /// Default in/out durations, seconds (house motion: in ~0.35 s spring/expo, out ~0.25 s).
    public var defaultIn: Double { self == .fade ? 0.25 : self == .bounce ? 0.6 : 0.35 }
    public var defaultOut: Double { 0.25 }

    /// Keyframes for a clip of `duration` resting at `rest`. `inDuration`/`outDuration` 0 skip that side.
    public func keyframes(rest: Transform, duration: MediaTime, inDuration: Double? = nil, outDuration: Double? = nil) -> [Keyframe]? {
        let d = duration.seconds
        guard d > 0 else { return nil }
        var tin = min(max(inDuration ?? defaultIn, 0), d / 2), tout = min(max(outDuration ?? defaultOut, 0), d / 2)
        func k(_ s: Double, _ tr: Transform, _ e: Easing?) -> Keyframe { Keyframe(time: MediaTime(seconds: s), transform: tr, easing: e) }
        func with(_ body: (inout Transform) -> Void) -> Transform { var t = rest; body(&t); return t }
        switch self {
        case .none: return nil
        case .kenBurns:
            let end = with { $0.scale *= 1.08; $0.x += 0.01; $0.y -= 0.006 }
            return [k(0, rest, .easeInOut), k(d, end, nil)]
        case .bounce:
            if tin + tout > d { tin = d / 2; tout = d / 2 }
            var out = tin > 0 ? AnimationPreset.bounceIn(rest: rest, duration: d, tin: tin) : [k(0, rest, nil)]
            if tout > 0 {
                if d - tout > tin { out += [k(d - tout, rest, .easeIn)] } else { out[out.count - 1].easing = .easeIn }
                out += [k(d, with { $0.opacity = 0 }, nil)]
            }
            return out
        case .pop, .slideUp, .slideDown, .fade:
            var from = rest, to = rest
            let ease: Easing
            switch self {
            case .pop:
                from = with { $0.scale *= 0.6; $0.opacity = 0 }
                to = with { $0.scale *= 0.92; $0.opacity = 0 }
                ease = .backOut
            case .slideUp:
                from = with { $0.y += 0.04; $0.opacity = 0 }
                to = with { $0.y -= 0.015; $0.opacity = 0 }
                ease = .expoOut
            case .slideDown:
                from = with { $0.y -= 0.04; $0.opacity = 0 }
                to = with { $0.y += 0.015; $0.opacity = 0 }
                ease = .expoOut
            default:
                from = with { $0.opacity = 0 }
                to = from
                ease = .easeOut
            }
            if tin + tout > d { tin = d / 2; tout = d / 2 }
            var out: [Keyframe] = []
            if tin > 0 { out += [k(0, from, ease)] }
            out += [k(tin, rest, nil)]
            if tout > 0 {
                // Rest until the out move starts, then ease out.
                if d - tout > tin { out += [k(d - tout, rest, .easeIn)] } else { out[out.count - 1].easing = .easeIn }
                out += [k(d, to, nil)]
            }
            return out
        }
    }
}
