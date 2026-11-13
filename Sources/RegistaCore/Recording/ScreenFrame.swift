import Foundation

// Styled frame around a screen recording (issue #44): the whole screen sits on a background (a colour, a gradient
// or an image) with padding, rounded corners and a soft shadow. Part of the layout spec (screen and bubble
// layouts), turned into ordinary clip properties by layout.apply plus the project's backdrop, so the preview and
// the export draw the same thing. Pure data and geometry, unit-tested.

/// What is drawn behind every layer of the frame (`ProjectSettings.backdrop`): a solid colour, a linear or radial
/// gradient of 2–3 colours evenly spaced, or an image file filling the frame (aspect fill).
public struct Backdrop: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case solid, linear, radial, image }

    public var kind: Kind
    /// solid: one colour; linear / radial: 2–3 colours (#RRGGBB), first at the start (radial: the centre).
    public var colors: [String]?
    /// linear: direction in degrees, CSS-like (0 = towards the top, 90 = towards the right, 180 = towards the bottom).
    public var angle: Double?
    /// radial: centre [x, y], fractions of the frame (top-left origin); the gradient reaches the farthest corner.
    public var center: [Double]?
    /// image: absolute path of the picture.
    public var path: String?
    /// The built-in preset or "brand" it came from (informative).
    public var preset: String?

    public init(kind: Kind, colors: [String]? = nil, angle: Double? = nil, center: [Double]? = nil, path: String? = nil, preset: String? = nil) {
        self.kind = kind
        self.colors = colors
        self.angle = angle
        self.center = center
        self.path = path
        self.preset = preset
    }

    /// Short human description ("gradient dusk", "#101010", "image wall.jpg").
    public var label: String {
        switch kind {
        case .solid: colors?.first ?? "#000000"
        case .image: "image " + URL(fileURLWithPath: path ?? "").lastPathComponent
        case .linear, .radial: "\(kind.rawValue) " + (preset ?? (colors ?? []).joined(separator: "→"))
        }
    }

    // MARK: Built-in gradients

    /// Abstract, quiet backgrounds generated in code (no image assets). Dark ones first: product UI reads best on them.
    public static let presets: [(name: String, backdrop: Backdrop, description: String)] = [
        ("graphite", Backdrop(kind: .radial, colors: ["#2B2E34", "#0E0F12"], center: [0.5, 0.32], preset: "graphite"),
         "Neutral charcoal, lighter behind the screen: the safe default for any UI."),
        ("aurum", Backdrop(kind: .radial, colors: ["#3E2F18", "#14100A", "#070605"], center: [0.5, -0.05], preset: "aurum"),
         "Near-black with a faint gold glow from above (Arkad gold, never orange)."),
        ("dusk", Backdrop(kind: .linear, colors: ["#1E2540", "#2F2742", "#191522"], angle: 155, preset: "dusk"),
         "Deep indigo to muted plum, diagonal: calm and premium."),
        ("lagoon", Backdrop(kind: .linear, colors: ["#0F2E3A", "#123F49", "#0A1C24"], angle: 160, preset: "lagoon"),
         "Dark teal, diagonal: fresh, for tech and SaaS."),
        ("mist", Backdrop(kind: .linear, colors: ["#F4F5F8", "#DCE1E9"], angle: 180, preset: "mist"),
         "Pale cool grey, top to bottom: light and airy, for dark-mode screens."),
        ("sand", Backdrop(kind: .radial, colors: ["#FBF8F2", "#E9E0D0"], center: [0.3, 0.2], preset: "sand"),
         "Warm off-white: soft and editorial, for dark-mode screens."),
    ]

    public static let presetNames = presets.map(\.name)

    public static func preset(_ name: String) -> Backdrop? { presets.first { $0.name == name }?.backdrop }

    /// The brand kit's own background: its ink with a faint glow of its primary colour from above.
    public static func brand(_ kit: BrandKit) -> Backdrop {
        let base = kit.colors["ink"] ?? kit.colors["surface"] ?? "#0E0F12"
        let glow = mix(base, kit.colors["primary"] ?? kit.colors["accent"] ?? base, 0.2)
        return Backdrop(kind: .radial, colors: [glow, base], center: [0.5, -0.05], preset: "brand \(kit.id)")
    }

    /// RGB of #RRGGBB (0…1), nil when malformed.
    public static func rgb(_ hex: String) -> (Double, Double, Double)? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func hex(_ c: (Double, Double, Double)) -> String {
        func b(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.0), b(c.1), b(c.2))
    }

    /// `a` moved by `t` towards `b`.
    static func mix(_ a: String, _ b: String, _ t: Double) -> String {
        guard let x = rgb(a), let y = rgb(b) else { return a }
        return hex((x.0 + (y.0 - x.0) * t, x.1 + (y.1 - x.1) * t, x.2 + (y.2 - x.2) * t))
    }

    public func validate() throws {
        let c = colors ?? []
        switch kind {
        case .solid: guard c.count == 1 else { throw CommandError.invalid("background: a solid background has one colour") }
        case .linear, .radial: guard (2...3).contains(c.count) else { throw CommandError.invalid("background: a gradient has 2 or 3 colours") }
        case .image:
            guard let p = path, FileManager.default.fileExists(atPath: p) else { throw CommandError.notFound("background: no image at \(path ?? "")") }
        }
        if let bad = c.first(where: { Self.rgb($0) == nil }) { throw CommandError.invalid("background: \"\(bad)\" is not a #RRGGBB colour") }
        if let cc = center, cc.count != 2 { throw CommandError.invalid("background: center is [x, y]") }
    }
}

/// The styled frame of a screen layout. Every field is optional: nil takes the default.
public struct ScreenFrame: Codable, Hashable, Sendable {
    public static let defaultPadding = 0.06
    public static let defaultRadius = 0.016
    public static let defaultShadow = 0.5

    /// nil: the applied brand kit's background (`Backdrop.brand`), else the `graphite` gradient.
    public var background: Backdrop?
    /// Space around the screen on every side, fraction of the frame's shorter side.
    public var padding: Double?
    /// Corner radius of the screen, fraction of the frame's shorter side.
    public var radius: Double?
    /// Opacity of the soft drop shadow under the screen (0 = none).
    public var shadow: Double?

    public init(background: Backdrop? = nil, padding: Double? = nil, radius: Double? = nil, shadow: Double? = nil) {
        self.background = background
        self.padding = padding
        self.radius = radius
        self.shadow = shadow
    }

    /// The background drawn: the one asked for, else the kit's, else graphite.
    public func resolvedBackground(kit: BrandKit?) -> Backdrop {
        background ?? kit.map(Backdrop.brand) ?? Backdrop.preset("graphite")!
    }

    public func validate() throws {
        if let p = padding, !(0...0.3).contains(p) { throw CommandError.invalid("frame: padding must be 0…0.3 (fraction of the shorter side)") }
        if let r = radius, !(0...0.2).contains(r) { throw CommandError.invalid("frame: radius must be 0…0.2 (fraction of the shorter side)") }
        if let s = shadow, !(0...1).contains(s) { throw CommandError.invalid("frame: shadow must be 0…1") }
        try background?.validate()
    }

    /// The screen's box [cx, cy, w, h] (output pixels) in a `W`×`H` frame: the whole screen, never cropped, as large as
    /// fits inside the padding, centred.
    public func screenBox(width W: Double, height H: Double, screen: (Double, Double)) -> [Double] {
        let pad = ((padding ?? Self.defaultPadding) * min(W, H)).rounded()
        let rw = max(W - 2 * pad, 2), rh = max(H - 2 * pad, 2)
        let a = screen.0 / max(screen.1, 1)
        var w = rw, h = rw / a
        if h > rh { h = rh; w = h * a }
        return [W / 2, H / 2, w.rounded(), h.rounded()]
    }

    /// The screen layer's mask: rounded corners (radius as a fraction of the box's shorter side, as `LayerMask` wants)
    /// and the floating shadow.
    public func mask(box: [Double], width W: Double, height H: Double) -> LayerMask {
        let r = (radius ?? Self.defaultRadius) * min(W, H)
        var m = LayerMask(shape: r > 0.5 ? .rounded : .rect)
        if r > 0.5 { m.radius = r / max(min(box[2], box[3]), 1) }
        let s = shadow ?? Self.defaultShadow
        if s > 0 {
            m.frame = "float"
            m.shadow = s
        }
        return m
    }
}
