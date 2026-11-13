import Foundation

// Graphics model (issue #5, X1): overlays, titles, effects and transitions. Pure data; the compositor
// (RegistaEngines) draws it. Pixel sizes are at a 1080-wide reference and scale with the output width,
// like the captions; positions are fractions of the output frame.

public enum BlendMode: String, Codable, CaseIterable, Sendable {
    case normal, screen, multiply
    public static let names = allCases.map(\.rawValue)
}

/// Where a picture that does not fill the frame sits. `native`: drawn at its own pixel size (scaled with the
/// output width) with its centre at (`x`, `y`); `contain`: the whole picture fitted inside the frame;
/// `fill`: cropped to fill the frame (the default for video); `box`: cropped to fill a `width`×`height` box of the
/// frame (screen-recording layouts: the face bubble, the halves of a split). The clip transform then applies
/// around the picture's own centre (scale, rotation) and moves it (x/y offsets).
public struct Placement: Codable, Hashable, Sendable {
    public enum Fit: String, Codable, CaseIterable, Sendable { case fill, contain, native, box }
    public var fit: Fit
    /// Centre, fractions of the output frame (0.5, 0.5 = middle).
    public var x: Double
    public var y: Double
    /// `box` only: size of the box, fractions of the output width and height.
    public var width: Double?
    public var height: Double?

    public init(fit: Fit = .native, x: Double = 0.5, y: Double = 0.5) {
        self.fit = fit
        self.x = x
        self.y = y
    }
}

/// Shape of a boxed layer (layout presets): rectangle, rounded rectangle or circle (the shorter side of the box),
/// optionally the person only (`cutout`, from the asset's person matte), with a thin border and a soft shadow.
public struct LayerMask: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case rect, rounded, circle }
    public var shape: Shape
    /// rounded: corner radius, fraction of the box's shorter side (0.5 = pill).
    public var radius: Double?
    /// Keep only the person (matte.track on the asset); frames without a matte are drawn whole.
    public var cutout: Bool?
    public var borderColor: String?
    /// Border width, px per 1080 px of the output's shorter side (0 or nil = none).
    public var borderWidth: Double?
    public var borderOpacity: Double?
    /// Opacity of a soft drop shadow under the layer (0 or nil = none).
    public var shadow: Double?
    /// Card styling around the box (layout.speaker inset-frame): `neon` (a glowing border in `glowColor`, corner
    /// brackets just outside the card), `glass` (a frosted translucent rim), `plain` (the border and shadow only).
    public var frame: String?
    /// neon: the glow and bracket colour (default the brand accent written by the command).
    public var glowColor: String?
    /// A small chip inside the top-left corner ("● PREVIEW"); nil = none.
    public var label: String?
    /// A small chip inside the top-right corner ("9:16"); nil = none.
    public var badge: String?

    public init(shape: Shape = .rect) { self.shape = shape }

    public static let frames = ["neon", "glass", "plain"]

    public static let names = Shape.allCases.map(\.rawValue)
}

/// Layout bands of a 9:16 reel at 1080×1920 (the reel templates' `_common.md`): graphics live in the top
/// band, the caption band stays clean, nothing important in the Instagram UI zones.
public enum SafeZones {
    public static let referenceWidth = 1080.0
    public static let referenceHeight = 1920.0
    /// Top card band.
    public static let top = (110.0, 640.0)
    /// Between the face and the captions (used sparingly).
    public static let lower = (980.0, 1200.0)
    /// Reserved for captions: no title or card may enter it.
    public static let caption = (1230.0, 1460.0)
    /// Instagram chrome: nothing important above, below, or in the right margin.
    public static let topLimit = 110.0
    public static let bottomLimit = 1540.0
    public static let rightMargin = 120.0

    public static let bandNames = ["top", "middle", "lower"]

    /// Centre (fraction of the height) of a named band.
    public static func centre(of band: String) -> Double? {
        switch band {
        case "top": (top.0 + top.1) / 2 / referenceHeight
        case "middle": 0.5
        case "lower": (lower.0 + lower.1) / 2 / referenceHeight
        default: nil
        }
    }

    /// The caption band in output pixels for an output height (fraction of the height kept).
    public static func captionBand(height: Int) -> (Double, Double) {
        (caption.0 / referenceHeight * Double(height), caption.1 / referenceHeight * Double(height))
    }

    /// Instagram Reels interface on a 1080×1920 frame, [x, y, w, h] reference pixels: the account bar at the top, the
    /// buttons and the post caption at the bottom, the action rail (like, comment, share) on the right — the limits
    /// above (`topLimit`, `bottomLimit`, `rightMargin`), drawn red on the preview while something is dragged.
    public static let instagram: [(name: String, rect: [Double])] = [
        ("top", [0, 0, referenceWidth, topLimit]),
        ("bottom", [0, bottomLimit, referenceWidth, referenceHeight - bottomLimit]),
        ("right", [referenceWidth - rightMargin, topLimit, rightMargin, bottomLimit - topLimit]),
    ]

    /// The Instagram zones on a `width`×`height` output (x scaled with the width, y with the height).
    public static func instagramZones(width: Int, height: Int) -> [(name: String, rect: [Double])] {
        let kx = Double(width) / referenceWidth, ky = Double(height) / referenceHeight
        return instagram.map { ($0.name, [$0.rect[0] * kx, $0.rect[1] * ky, $0.rect[2] * kx, $0.rect[3] * ky]) }
    }

    /// Names of the Instagram zones a box [x, y, w, h] (output pixels) enters.
    public static func instagramHits(_ box: [Double], width: Int, height: Int) -> [String] {
        instagramZones(width: width, height: height).filter { z in
            box[0] < z.rect[0] + z.rect[2] && z.rect[0] < box[0] + box[2] && box[1] < z.rect[1] + z.rect[3] && z.rect[1] < box[1] + box[3]
        }.map(\.name)
    }

    /// One warning per Instagram zone a box enters.
    public static func instagramWarnings(_ box: [Double], width: Int, height: Int, what: String) -> [String] {
        instagramHits(box, width: width, height: height).map { "\(what) enters \(instagramLabel($0))" }
    }

    public static func instagramLabel(_ zone: String) -> String {
        switch zone {
        case "top": "the Instagram account bar (top \(Int(topLimit)) px)"
        case "bottom": "the Instagram buttons and post caption (below y \(Int(bottomLimit)))"
        default: "the Instagram action rail (right \(Int(rightMargin)) px)"
        }
    }
}

/// A text layer drawn with Core Text by the compositor (title.add). Sizes in px at 1080 wide.
public struct Title: Codable, Hashable, Sendable {
    /// "\n" separates lines; long lines wrap at `maxWidth`.
    public var text: String
    /// PostScript name, family name, or a font file (.ttf/.otf/.woff2).
    public var font: String
    public var size: Double
    public var color: String
    public var uppercase: Bool?
    /// left | center | right (lines inside the block).
    public var align: String?
    /// Line height as a multiple of the size (default 1.15).
    public var lineHeight: Double?
    /// Extra space between letters, px.
    public var tracking: Double?
    public var maxWidth: Double?
    /// Words (as typed, case-insensitive) drawn in `highlightColor`.
    public var highlight: [String]?
    public var highlightColor: String?
    public var background: TitleBackground?
    public var stroke: TitleStroke?
    public var shadow: TitleShadow?

    public init(text: String, font: String, size: Double, color: String) {
        self.text = text
        self.font = font
        self.size = size
        self.color = color
    }

    /// The text as drawn.
    public var displayText: String { uppercase == true ? text.uppercased() : text }
}

public struct TitleBackground: Codable, Hashable, Sendable {
    /// box (rounded rectangle, `radius`) or pill (fully rounded ends).
    public var kind: String
    public var color: String
    public var opacity: Double?
    public var padX: Double
    public var padY: Double
    public var radius: Double?

    public init(kind: String = "pill", color: String, opacity: Double? = nil, padX: Double = 40, padY: Double = 20, radius: Double? = nil) {
        self.kind = kind
        self.color = color
        self.opacity = opacity
        self.padX = padX
        self.padY = padY
        self.radius = radius
    }
}

public struct TitleStroke: Codable, Hashable, Sendable {
    public var color: String
    public var width: Double
    public init(color: String, width: Double) { self.color = color; self.width = width }
}

public struct TitleShadow: Codable, Hashable, Sendable {
    public var color: String
    public var blur: Double
    public var x: Double
    public var y: Double
    public var opacity: Double
    public init(color: String = "#000000", blur: Double = 24, x: Double = 0, y: Double = 8, opacity: Double = 0.28) {
        self.color = color
        self.blur = blur
        self.x = x
        self.y = y
        self.opacity = opacity
    }
}

/// A Core Image effect on a clip, with a strength envelope over a clip-relative window.
public struct Effect: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// 3D LUT from a .cube file, mixed by strength.
        case lut
        /// Gaussian blur, `radius` px.
        case blur
        /// Bloom: bright parts bleed light, `radius` px.
        case glow
        /// Darkened edges.
        case vignette
        /// Luma sharpening (AI inserts upscaled from 464 px).
        case sharpen
        /// Quick zoom bump to `zoom` (default 1.12) on a beat.
        case punchZoom
        /// Hand-held shake, `frequency` Hz.
        case shake
        /// The frame flashes to `color` (default white).
        case flash
        /// Digital glitch: RGB split and jittering blocks, re-rolled `frequency` times a second (default 12).
        case glitch
        /// Green/blue screen: pixels near `color` (default #00FF00) become transparent; `tolerance`, `spill`.
        case chromaKey
    }

    public var id: String
    public var kind: Kind
    /// Clip-relative window (nil = the whole clip).
    public var start: MediaTime?
    public var end: MediaTime?
    /// Peak strength 0…1.
    public var amount: Double
    /// Ramp in/out at the window edges, seconds.
    public var attack: Double?
    public var release: Double?
    public var easing: Easing?
    /// Explicit strength curve (clip-relative); replaces amount/attack/release.
    public var keyframes: [ScalarKey]?
    public var radius: Double?
    public var zoom: Double?
    public var path: String?
    public var color: String?
    public var frequency: Double?
    /// chromaKey: width of the keyed hue window 0…1 (default 0.4).
    public var tolerance: Double?
    /// chromaKey: how much of the key colour's spill is removed from the kept pixels 0…1 (default 0.5).
    public var spill: Double?

    public init(id: String, kind: Kind, amount: Double = 1) {
        self.id = id
        self.kind = kind
        self.amount = amount
    }

    public static let names = Kind.allCases.map(\.rawValue)

    /// Strength at clip-relative time `t` (0 outside the window).
    public func strength(at t: MediaTime, clipDuration: MediaTime) -> Double {
        if let k = keyframes, !k.isEmpty { return ScalarKey.value(k, at: t) }
        let a = start ?? .zero, b = end ?? clipDuration
        guard t >= a, t < b else { return 0 }
        let e = easing ?? .easeOut
        let x = (t - a).seconds, y = (b - t).seconds
        var s = amount
        if let up = attack, up > 0, x < up { s *= e.apply(x / up) }
        if let down = release, down > 0, y < down { s *= e.apply(y / down) }
        return s
    }
}

/// A frame-wide transition at a cut: `flash` (to white and back), `whip` (the picture slides out and the next
/// one in, motion-blurred), `dip` (through black), `blur` (defocus out and back into focus on the next shot). Anchored to a clip edge when `clipId` is set (it follows
/// edits), else at `at`. Captions are never affected.
public struct Transition: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case flash, whip, dip, blur }
    public var id: String
    public var kind: Kind
    public var at: MediaTime
    public var duration: MediaTime
    /// whip: where the picture leaves to (left, right, up, down; default left).
    public var direction: String?
    public var color: String?
    public var clipID: String?
    /// "start" or "end" of `clipID`.
    public var edge: String?

    public init(id: String, kind: Kind, at: MediaTime, duration: MediaTime) {
        self.id = id
        self.kind = kind
        self.at = at
        self.duration = duration
    }

    public static let names = Kind.allCases.map(\.rawValue)

    /// The cut time, following the anchor clip when there is one.
    public func time(in project: Project) -> MediaTime {
        if let cid = clipID, let loc = project.locate(clip: cid) {
            let c = project.tracks[loc.track].clips[loc.clip]
            return edge == "end" ? c.end : c.start
        }
        return at
    }
}

/// Whole-frame modifiers at one time: transitions and flash effects. Applied to the picture under the captions.
public struct FrameFX: Hashable, Sendable {
    /// Opacity of a colour wash over the picture.
    public var flash = 0.0
    public var flashColor = "#FFFFFF"
    /// Opacity of black over the picture.
    public var dip = 0.0
    /// Offset of the picture, fractions of the frame (whip).
    public var shiftX = 0.0
    public var shiftY = 0.0
    /// Motion blur along the shift, px at the output size.
    public var blur = 0.0
    /// Gaussian defocus of the whole picture, px at the output size (blur transition).
    public var defocus = 0.0

    public init() {}
    public var isIdentity: Bool { flash == 0 && dip == 0 && shiftX == 0 && shiftY == 0 && blur == 0 && defocus == 0 }
}

/// Effects the compositor applies to one layer (punch zoom and shake are already folded into its transform).
public struct LayerEffect: Hashable, Sendable {
    public var kind: Effect.Kind
    public var strength: Double
    /// Output pixels (radius × output width / 1080).
    public var radius: Double
    public var path: String?
    /// chromaKey colour.
    public var color: String?
    public var tolerance: Double?
    public var spill: Double?
    /// glitch: the random pattern of this instant (changes `frequency` times a second).
    public var seed: Int = 0

    public init(kind: Effect.Kind, strength: Double, radius: Double, path: String? = nil) {
        self.kind = kind
        self.strength = strength
        self.radius = radius
        self.path = path
    }
}

extension Effect {
    /// Hand-held shake offsets at `t` seconds: (dx, dy fractions of the frame, rotation degrees) for strength 1.
    /// Deterministic sums of incommensurate sines, so a frame always renders the same.
    static func shake(at t: Double, frequency f: Double) -> (Double, Double, Double) {
        let w = 2 * Double.pi * f
        let dx = 0.6 * sin(w * t + 0.3) + 0.4 * sin(1.73 * w * t + 1.9)
        let dy = 0.6 * sin(1.21 * w * t + 2.2) + 0.4 * sin(2.07 * w * t + 0.7)
        let r = sin(0.87 * w * t + 1.1)
        return (dx * 0.012, dy * 0.009, r * 0.6)
    }
}
