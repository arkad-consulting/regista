import Foundation

// Stickers, callouts, progress bars and logo motions (issue #16): generated layers the compositor draws itself.

/// An emoji or an SF Symbol drawn as an overlay (sticker.add).
public struct Sticker: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case emoji, symbol }
    public var kind: Kind
    /// The emoji, or the SF Symbol name ("checkmark.seal.fill").
    public var value: String
    /// Symbol colour (#RRGGBB, default white); emoji keep their own colours.
    public var color: String?
    /// Height of the glyph, px at 1080 wide.
    public var size: Double
    /// A round badge behind the glyph (#RRGGBB), nil = none.
    public var badge: String?

    public init(kind: Kind, value: String, size: Double = 160, color: String? = nil) {
        self.kind = kind
        self.value = value
        self.size = size
        self.color = color
    }

    /// Box of the drawn sticker, px at 1080 wide (badge included).
    public var box: Double { badge == nil ? size * 1.15 : size * 1.6 }
}

/// The built-in sticker set: a short, curated list (no stock clip-art). Labels are Italian (the app shows them).
public enum StickerLibrary {
    public struct Item: Hashable, Sendable {
        public var id: String
        public var label: String
        public var sticker: Sticker
    }

    public static let items: [Item] = {
        func e(_ id: String, _ label: String, _ v: String) -> Item { Item(id: id, label: label, sticker: Sticker(kind: .emoji, value: v)) }
        func s(_ id: String, _ label: String, _ v: String, _ color: String = "#FFFFFF") -> Item {
            Item(id: id, label: label, sticker: Sticker(kind: .symbol, value: v, size: 140, color: color))
        }
        return [
            e("fire", "Fuoco", "🔥"), e("sparkles", "Scintille", "✨"), e("eyes", "Occhi", "👀"), e("idea", "Idea", "💡"),
            e("check", "Fatto", "✅"), e("cross", "No", "❌"), e("rocket", "Razzo", "🚀"), e("point", "Indica", "👉"),
            e("laugh", "Risata", "😂"), e("target", "Obiettivo", "🎯"), e("heart", "Cuore", "❤️"), e("clap", "Applauso", "👏"),
            s("seal", "Sigillo", "checkmark.seal.fill", "#7FC8A9"), s("star", "Stella", "star.fill", "#F4BD56"),
            s("bolt", "Fulmine", "bolt.fill", "#F4BD56"), s("arrowDown", "Freccia giù", "arrow.down"),
            s("tap", "Tocca", "hand.tap.fill"), s("warning", "Attenzione", "exclamationmark.triangle.fill", "#D89528"),
            s("bulb", "Lampadina", "lightbulb.fill", "#F4BD56"), s("click", "Clic", "cursorarrow.click.2"),
            s("bell", "Campanella", "bell.fill"), s("thumbsUp", "Pollice su", "hand.thumbsup.fill"),
        ]
    }()

    public static func named(_ id: String) -> Item? { items.first { $0.id == id } }
}

/// A vector shape drawn on with a stroke animation (callout.add) or a filling bar (progress.add).
public struct ShapeLayer: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// From (x, y) to (x + w, y + h) with an arrowhead.
        case arrow
        /// An ellipse around the rect, hand-drawn (slightly open, overshooting the start).
        case circle
        /// A line under the rect.
        case underline
        /// A rounded rectangle around the rect.
        case box
        /// A translucent marker band over the rect (drawn left to right).
        case highlight
        /// A bar across the rect filling from left to right over the clip.
        case progressBar
        /// A soft glowing ellipse ring in the rect, seen in perspective (under an object held in the hand: clip.follow halo).
        case halo
        /// The top status row: a REC pill with `label` and a running timer on the left, the current chapter badge on the right.
        case statusBar
        /// Stereo L/R segmented level meters (green → orange) driven by `levels`, the left pair at the rect's left edge, the
        /// right pair at its right edge.
        case audioMeters
    }
    public var kind: Kind
    /// Frame fractions [x, y, w, h], top-left origin.
    public var rect: [Double]
    public var color: String
    /// Stroke width (bar thickness for progressBar), px at 1080 wide.
    public var width: Double
    /// Seconds to draw the shape on (0 = shown whole).
    public var drawOn: Double
    /// progressBar: the unfilled part's colour (nil = none).
    public var trackColor: String?
    /// statusBar: the text after the REC dot ("EDITING LIVE").
    public var label: String?
    /// statusBar: numbered chapters, clip-relative start times; the badge shows the last one started.
    public var chapters: [ShapeChapter]?
    /// statusBar: the timer reads timerStart + clip time × timerRate seconds (a fast "live session" clock with rate > 1).
    public var timerStart: Double?
    public var timerRate: Double?
    /// audioMeters: per sample [rms L, rms R, peak L, peak R], 0…1 (−48…0 dBFS), at `levelRate` samples a second from the clip start.
    public var levels: [[Double]]?
    public var levelRate: Double?

    public init(kind: Kind, rect: [Double], color: String, width: Double = 10, drawOn: Double = 0.4) {
        self.kind = kind
        self.rect = rect
        self.color = color
        self.width = width
        self.drawOn = drawOn
    }

    public static let names = Kind.allCases.map(\.rawValue)

    /// The HUD kinds are drawn from the clip time itself (timer, chapters, levels), not from a 0…1 progress.
    public var isLive: Bool { kind == .statusBar || kind == .audioMeters }

    /// Drawn fraction 0…1 at clip-relative `t` of a clip lasting `duration` (the clip-relative seconds for `isLive` kinds).
    public func progress(at t: MediaTime, duration: MediaTime) -> Double {
        if isLive { return max(t.seconds, 0) }
        if kind == .progressBar { return min(max(t.seconds / max(duration.seconds, 1e-6), 0), 1) }
        guard drawOn > 0 else { return 1 }
        return Easing.easeOut.apply(t.seconds / drawOn)
    }
}

/// A chapter of a status bar: from `at` (clip-relative seconds) the badge reads "<number> <label>".
public struct ShapeChapter: Codable, Hashable, Sendable {
    public var at: Double
    public var label: String

    public init(at: Double, label: String) {
        self.at = at
        self.label = label
    }
}

/// Motions for a logo (an image overlay), written as transform keyframes (logo.animate). House taste: one short
/// motion, not a spinning logo for the whole reel; `sting` is a ~1 s intro/outro hit.
public enum LogoMotion: String, CaseIterable, Sendable {
    /// One turn while growing in, then rest; fades out.
    case spin
    /// Drifts on a small circle around its place (slow, continuous).
    case orbit
    /// Breathes: scale 1 → 1.06 → 1 every 1.2 s.
    case pulse
    /// Intro/outro hit: pops in past full size and settles, holds, then lifts away and fades.
    case sting
    case none

    public static let names = allCases.map(\.rawValue)

    public func keyframes(rest: Transform, duration: MediaTime) -> [Keyframe]? {
        let d = duration.seconds
        guard d > 0 else { return nil }
        func k(_ s: Double, _ e: Easing?, _ body: (inout Transform) -> Void = { _ in }) -> Keyframe {
            var t = rest
            body(&t)
            return Keyframe(time: MediaTime(seconds: min(max(s, 0), d)), transform: t, easing: e)
        }
        let fadeOut = min(0.3, d / 4)
        switch self {
        case .none: return nil
        case .spin:
            let tin = min(0.8, d / 2)
            return [k(0, .expoOut) { $0.rotation -= 360; $0.scale *= 0.3; $0.opacity = 0 }, k(tin, nil), k(d - fadeOut, .easeIn),
                    k(d, nil) { $0.opacity = 0 }]
        case .orbit:
            let period = 3.0, steps = 16, r = 0.012
            var out: [Keyframe] = []
            var s = 0.0
            while s < d - 1e-6 {
                let a = 2 * Double.pi * s / period
                let fade = min(s / 0.3, 1, (d - s) / fadeOut)
                out.append(k(s, .linear) { $0.x += r * cos(a); $0.y += r * sin(a) * 0.7; $0.opacity *= max(fade, 0) })
                s += period / Double(steps)
            }
            let a = 2 * Double.pi * d / period
            out.append(k(d, nil) { $0.x += r * cos(a); $0.y += r * sin(a) * 0.7; $0.opacity = 0 })
            return out
        case .pulse:
            var out = [k(0, .easeOut) { $0.opacity = 0; $0.scale *= 0.94 }]
            var s = 0.25
            var up = true
            while s < d - fadeOut {
                out.append(k(s, .easeInOut) { if up { $0.scale *= 1.06 } })
                up.toggle()
                s += 0.6
            }
            out.append(k(d - fadeOut, .easeIn))
            out.append(k(d, nil) { $0.opacity = 0 })
            return out
        case .sting:
            let hit = min(0.18, d / 5), settle = min(0.45, d / 3), out = min(0.35, d / 4)
            return [k(0, .expoOut) { $0.scale *= 0.4; $0.opacity = 0; $0.rotation -= 8 }, k(hit, .easeOut) { $0.scale *= 1.12 }, k(settle, nil),
                    k(d - out, .easeIn), k(d, nil) { $0.scale *= 1.25; $0.opacity = 0 }]
        }
    }
}

extension AnimationPreset {
    /// Drop in from above with two small bounces (stickers).
    static func bounceIn(rest: Transform, duration d: Double, tin: Double) -> [Keyframe] {
        func k(_ f: Double, _ e: Easing?, _ body: (inout Transform) -> Void = { _ in }) -> Keyframe {
            var t = rest
            body(&t)
            return Keyframe(time: MediaTime(seconds: min(f * tin, d)), transform: t, easing: e)
        }
        return [k(0, .easeIn) { $0.y -= 0.07; $0.opacity = 0; $0.scale *= 0.9 }, k(0.5, .easeOut) { $0.y += 0.008; $0.scale *= 1.05 },
                k(0.72, .easeIn) { $0.y -= 0.014 }, k(0.88, .easeOut) { $0.y += 0.003 }, k(1, nil)]
    }
}

extension String {
    /// FNV-1a: a hash that stays the same across runs (Swift's `hashValue` is seeded per process), for deterministic
    /// random patterns (glitch blocks).
    public var hashValueStable: Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h >> 1)
    }
}
