import Foundation

// Colour looks and Photos-style adjustments (issue #16). Pure colour math on gamma-encoded R'G'B' (the compositor
// does not manage colour), baked by the compositor into one 3D LUT per (look, amount, adjustments) state.
// Sharpness and vignette are spatial: the compositor applies them as Core Image filters after the LUT.

/// A colour look: a few tone/colour moves with a mix amount. Ids are stable (projects store them); `label` is the
/// Italian name the app shows.
public struct Look: Hashable, Sendable {
    public var id: String
    public var label: String
    /// One line for the gallery and look.list.
    public var summary: String
    /// The same line in Italian, for the app.
    public var line: String = ""
    var exposure = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var warmth = 0.0
    var tint = 0.0
    /// Black lift (faded film blacks), 0…0.2.
    var fade = 0.0
    var highlights = 0.0
    var shadows = 0.0
    /// Colour pushed into the shadows / highlights (R'G'B' offsets, split toning).
    var shadowTone: (Double, Double, Double) = (0, 0, 0)
    var highlightTone: (Double, Double, Double) = (0, 0, 0)
    var mono = false

    public static func == (a: Look, b: Look) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    /// The look at full strength on one pixel.
    func apply(_ c: RGB) -> RGB {
        var p = c
        if exposure != 0 { p = Tone.exposure(p, exposure) }
        if shadows != 0 || highlights != 0 { p = Tone.shadowsHighlights(p, shadows: shadows, highlights: highlights) }
        if contrast != 0 { p = Tone.contrast(p, contrast) }
        if mono { let l = p.luma; p = RGB(l, l, l) }
        if saturation != 0 { p = Tone.saturation(p, saturation) }
        if warmth != 0 || tint != 0 { p = Tone.temperature(p, warmth: warmth, tint: tint) }
        if shadowTone != (0, 0, 0) || highlightTone != (0, 0, 0) {
            let l = p.luma
            let ws = pow(1 - l, 2), wh = pow(l, 2)
            p = RGB(p.r + shadowTone.0 * ws + highlightTone.0 * wh, p.g + shadowTone.1 * ws + highlightTone.1 * wh,
                    p.b + shadowTone.2 * ws + highlightTone.2 * wh)
        }
        if fade > 0 { p = RGB(fade + p.r * (1 - fade), fade + p.g * (1 - fade), fade + p.b * (1 - fade)) }
        return p.clamped
    }

    /// The built-in looks, in the order the filter strip shows them. Original names; tasteful by default.
    static let lines: [String: String] = [
        "golden": "Caldo e morbido: la pelle del tardo pomeriggio.", "frost": "Freddo e pulito, un po' smorzato.",
        "film": "Neri sbiaditi, ombre verde-acqua, luci calde.", "graphite": "Bianco e nero neutro.",
        "ink": "Bianco e nero deciso: neri profondi, bianchi pieni.", "vivid": "Più colore e contrasto per i video piatti del telefono.",
        "velvet": "Poco contrasto, toni pastello.", "riviera": "Verde-acqua e arancio, cinematografico.",
        "archive": "Ingiallito e sbiadito, come una vecchia stampa.", "matte": "Neri opachi, colori sobri.",
        "sunset": "Calore rosato e ambrato.", "fjord": "Freddo verde-blu, colori quieti.",
        "night": "Scuro, freddo, contrastato.", "airy": "Luminoso e arioso, bianchi puliti.",
    ]

    public static let all: [Look] = {
        func look(_ id: String, _ label: String, _ summary: String, _ body: (inout Look) -> Void) -> Look {
            var l = Look(id: id, label: label, summary: summary)
            l.line = lines[id] ?? ""
            body(&l)
            return l
        }
        return [
            look("golden", "Dorato", "Warm, gently lifted: late-afternoon skin.") { $0.warmth = 0.35; $0.saturation = 0.08; $0.shadows = 0.12; $0.highlightTone = (0.025, 0.012, -0.02) },
            look("frost", "Brina", "Cool and clean, slightly muted.") { $0.warmth = -0.35; $0.saturation = -0.12; $0.contrast = 0.06; $0.highlights = -0.1 },
            look("film", "Pellicola", "Faded blacks, teal shadows, warm highlights, soft contrast.") {
                $0.fade = 0.06; $0.contrast = 0.1; $0.saturation = -0.1; $0.shadowTone = (-0.02, 0.012, 0.03); $0.highlightTone = (0.03, 0.012, -0.02)
            },
            look("graphite", "Grafite", "Neutral black and white.") { $0.mono = true; $0.contrast = 0.08 },
            look("ink", "Inchiostro", "Hard black and white: deep blacks, bright whites.") { $0.mono = true; $0.contrast = 0.45; $0.shadows = -0.12 },
            look("vivid", "Vivido", "More colour and contrast, for flat phone footage.") { $0.contrast = 0.2; $0.saturation = 0.28; $0.highlights = -0.08 },
            look("velvet", "Velluto", "Low contrast, lifted and pastel.") { $0.contrast = -0.22; $0.fade = 0.05; $0.saturation = -0.08; $0.shadows = 0.15 },
            look("riviera", "Riviera", "Teal and orange, cinematic.") {
                $0.contrast = 0.14; $0.saturation = 0.05; $0.shadowTone = (-0.04, 0.02, 0.05); $0.highlightTone = (0.05, 0.015, -0.04)
            },
            look("archive", "Archivio", "Yellowed and faded, like an old print.") {
                $0.fade = 0.09; $0.saturation = -0.35; $0.warmth = 0.25; $0.contrast = -0.05; $0.highlightTone = (0.03, 0.02, -0.03)
            },
            look("matte", "Opaco", "Matte blacks, muted colour.") { $0.fade = 0.1; $0.saturation = -0.15; $0.contrast = 0.05 },
            look("sunset", "Tramonto", "Rose and amber warmth.") { $0.warmth = 0.3; $0.tint = 0.15; $0.saturation = 0.1; $0.highlightTone = (0.03, 0, 0.01) },
            look("fjord", "Fiordo", "Cool green-blue, quiet colour.") { $0.warmth = -0.25; $0.tint = -0.12; $0.saturation = -0.2; $0.shadowTone = (-0.02, 0.01, 0.02) },
            look("night", "Notte", "Dark, cool, contrasty.") { $0.exposure = -0.15; $0.contrast = 0.25; $0.warmth = -0.2; $0.saturation = -0.1; $0.shadows = -0.1 },
            look("airy", "Luce", "Bright and airy, clean whites.") { $0.exposure = 0.15; $0.shadows = 0.2; $0.highlights = -0.15; $0.contrast = -0.08; $0.saturation = 0.04 },
        ]
    }()

    public static func named(_ id: String) -> Look? { all.first { $0.id == id } }
    public static var ids: [String] { all.map(\.id) }
}

/// Photos-style adjustments. Each slider is −1…1 (0 = untouched) except sharpness and vignette, 0…1.
public struct Adjustments: Codable, Hashable, Sendable {
    public var exposure = 0.0
    public var brilliance = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var contrast = 0.0
    public var saturation = 0.0
    public var warmth = 0.0
    public var tint = 0.0
    public var sharpness = 0.0
    public var vignette = 0.0

    public init() {}

    /// Property names in the order the Adjust panel lists them, with the Italian label and the allowed range.
    public static let properties: [(name: String, label: String, range: ClosedRange<Double>)] = [
        ("exposure", "Esposizione", -1...1), ("brilliance", "Brillantezza", -1...1), ("highlights", "Luci", -1...1),
        ("shadows", "Ombre", -1...1), ("contrast", "Contrasto", -1...1), ("saturation", "Saturazione", -1...1),
        ("warmth", "Calore", -1...1), ("tint", "Tinta", -1...1), ("sharpness", "Nitidezza", 0...1), ("vignette", "Vignettatura", 0...1),
    ]
    public static var names: [String] { properties.map(\.name) }

    public static func range(of name: String) -> ClosedRange<Double>? { properties.first { $0.name == name }?.range }

    public subscript(name: String) -> Double {
        get {
            switch name {
            case "exposure": exposure
            case "brilliance": brilliance
            case "highlights": highlights
            case "shadows": shadows
            case "contrast": contrast
            case "saturation": saturation
            case "warmth": warmth
            case "tint": tint
            case "sharpness": sharpness
            case "vignette": vignette
            default: 0
            }
        }
        set {
            let v = Adjustments.range(of: name).map { min(max(newValue, $0.lowerBound), $0.upperBound) } ?? newValue
            switch name {
            case "exposure": exposure = v
            case "brilliance": brilliance = v
            case "highlights": highlights = v
            case "shadows": shadows = v
            case "contrast": contrast = v
            case "saturation": saturation = v
            case "warmth": warmth = v
            case "tint": tint = v
            case "sharpness": sharpness = v
            case "vignette": vignette = v
            default: break
            }
        }
    }

    public var isIdentity: Bool { self == Adjustments() }
    /// The per-pixel part (everything but sharpness and vignette) is untouched.
    public var colorIsIdentity: Bool {
        exposure == 0 && brilliance == 0 && highlights == 0 && shadows == 0 && contrast == 0 && saturation == 0 && warmth == 0 && tint == 0
    }

    /// The per-pixel adjustments on one pixel (sharpness and vignette are spatial: not here).
    func apply(_ c: RGB) -> RGB {
        var p = c
        if exposure != 0 { p = Tone.exposure(p, exposure) }
        if brilliance != 0 { p = Tone.brilliance(p, brilliance) }
        if shadows != 0 || highlights != 0 { p = Tone.shadowsHighlights(p, shadows: shadows, highlights: highlights) }
        if contrast != 0 { p = Tone.contrast(p, contrast) }
        if saturation != 0 { p = Tone.saturation(p, saturation) }
        if warmth != 0 || tint != 0 { p = Tone.temperature(p, warmth: warmth, tint: tint) }
        return p.clamped
    }
}

/// A clip's (or the whole picture's) colour: a look mixed by `amount`, then the adjustments. `keys` animate any
/// adjustment or the look amount ("amount") over clip-relative time (project grade: timeline time).
public struct Grade: Codable, Hashable, Sendable {
    public var look: String?
    /// Look intensity 0…1 (default 1).
    public var amount: Double?
    public var adjust: Adjustments?
    public var keys: [String: [ScalarKey]]?

    public init(look: String? = nil, amount: Double? = nil, adjust: Adjustments? = nil) {
        self.look = look
        self.amount = amount
        self.adjust = adjust
    }

    public var isEmpty: Bool { look == nil && (adjust?.isIdentity ?? true) && (keys?.isEmpty ?? true) }

    /// The grade's values at time `t` (keyframes interpolated, held outside).
    public func resolved(at t: MediaTime) -> ResolvedGrade? {
        var a = adjust ?? Adjustments()
        var amt = min(max(amount ?? 1, 0), 1)
        for (name, k) in keys ?? [:] where !k.isEmpty {
            if name == "amount" { amt = min(max(ScalarKey.value(k, at: t), 0), 1) } else { a[name] = ScalarKey.value(k, at: t) }
        }
        let lookID = look.flatMap { Look.named($0) != nil ? $0 : nil }
        let r = ResolvedGrade(look: amt > 0 ? lookID : nil, amount: lookID == nil ? 0 : amt, adjust: a)
        return r.isIdentity ? nil : r
    }
}

/// A grade at one instant: what the compositor draws (and caches its LUT by).
public struct ResolvedGrade: Hashable, Sendable {
    public var look: String?
    public var amount: Double
    public var adjust: Adjustments

    public init(look: String?, amount: Double, adjust: Adjustments) {
        self.look = look
        self.amount = amount
        self.adjust = adjust
    }

    public var isIdentity: Bool { (look == nil || amount <= 0) && adjust.isIdentity }
    /// The LUT part is the identity (only sharpness/vignette, or nothing).
    public var colorIsIdentity: Bool { (look == nil || amount <= 0) && adjust.colorIsIdentity }

    /// Rounded to steps fine enough to be invisible, so animated grades reuse cached LUTs.
    public var cacheKey: ResolvedGrade {
        func q(_ v: Double) -> Double { (v * 200).rounded() / 200 }
        var a = adjust
        for n in Adjustments.names { a[n] = q(a[n]) }
        return ResolvedGrade(look: look, amount: q(amount), adjust: a)
    }

    /// One pixel through the look (mixed by amount) and the adjustments.
    public func apply(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let c = RGB(r, g, b)
        var p = c
        if let id = look, amount > 0, let l = Look.named(id) {
            let full = l.apply(c)
            p = RGB(c.r + (full.r - c.r) * amount, c.g + (full.g - c.g) * amount, c.b + (full.b - c.b) * amount)
        }
        p = adjust.apply(p)
        return (p.r, p.g, p.b)
    }

    /// RGBA float cube for Core Image's CIColorCube (red fastest, then green, then blue), `size`³ entries.
    public func cube(size n: Int = 33) -> [Float] {
        var out = [Float](repeating: 1, count: n * n * n * 4)
        let k = 1 / Double(n - 1)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let p = apply(r: Double(r) * k, g: Double(g) * k, b: Double(b) * k)
                    out[i] = Float(p.0); out[i + 1] = Float(p.1); out[i + 2] = Float(p.2)
                    i += 4
                }
            }
        }
        return out
    }
}

// MARK: - Tone primitives

struct RGB: Equatable {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var clamped: RGB { RGB(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1)) }
    func map(_ f: (Double) -> Double) -> RGB { RGB(f(r), f(g), f(b)) }
}

enum Tone {
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// ±1 = ±1.5 stops, in linear light (gamma 2.2 approximation), highlights rolled off instead of clipped.
    static func exposure(_ c: RGB, _ e: Double) -> RGB {
        let k = pow(2, 1.5 * e)
        return c.map { v in
            let lin = pow(max(v, 0), 2.2) * k
            let rolled = lin <= 0.8 ? lin : 0.8 + 0.2 * (1 - exp(-(lin - 0.8) / 0.2))
            return pow(min(rolled, 1), 1 / 2.2)
        }
    }

    /// Lift the shadows (+) or deepen them (−) and pull down (−) or brighten (+) the highlights, weighted by luma.
    static func shadowsHighlights(_ c: RGB, shadows s: Double, highlights h: Double) -> RGB {
        let l = c.luma
        let ws = 1 - smoothstep(0.0, 0.6, l), wh = smoothstep(0.4, 1.0, l)
        let dl = s * 0.25 * ws * (1 - l) + h * 0.25 * wh * (h < 0 ? l : 1 - l)
        return RGB(c.r + dl, c.g + dl, c.b + dl)
    }

    /// S-curve around mid grey; negative values flatten.
    static func contrast(_ c: RGB, _ k: Double) -> RGB {
        let f = 1 + k * (k > 0 ? 0.9 : 0.7)
        return c.map { v in
            let lin = 0.5 + (v - 0.5) * f
            // Soft shoulder/toe: blend towards a smoothstep for positive contrast.
            return k > 0 ? lin * (1 - 0.35 * k) + smoothstep(0, 1, lin) * 0.35 * k : lin
        }
    }

    static func saturation(_ c: RGB, _ s: Double) -> RGB {
        let l = c.luma
        let f = 1 + s * (s > 0 ? 0.9 : 1)
        return RGB(l + (c.r - l) * f, l + (c.g - l) * f, l + (c.b - l) * f)
    }

    /// Warmth (+ amber, − blue) and tint (+ magenta, − green), luma kept roughly constant.
    static func temperature(_ c: RGB, warmth w: Double, tint t: Double) -> RGB {
        RGB(c.r + 0.07 * w + 0.03 * t, c.g - 0.05 * t + 0.005 * w, c.b - 0.08 * w + 0.03 * t)
    }

    /// Photos-like brilliance: lifts shadows, protects highlights and adds midtone contrast (negative: the reverse).
    static func brilliance(_ c: RGB, _ b: Double) -> RGB {
        let lifted = shadowsHighlights(c, shadows: 0.6 * b, highlights: -0.5 * b)
        return contrast(lifted, 0.15 * b)
    }
}

/// Keyed colour (green/blue screen) as an RGBA cube: pixels near the key colour become transparent (premultiplied),
/// the rest keeps its colour with the key hue's spill pulled towards grey.
public enum ChromaKeyCube {
    /// Hue (0…1) and saturation of a colour.
    static func hueSat(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 1e-6 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    /// Alpha (0 = keyed out) of one pixel for a key colour; `tolerance` 0…1 widens the hue window.
    public static func alpha(r: Double, g: Double, b: Double, key: (Double, Double, Double), tolerance: Double) -> Double {
        let (kh, _, _) = hueSat(key.0, key.1, key.2)
        let (h, s, v) = hueSat(r, g, b)
        var dh = abs(h - kh)
        dh = min(dh, 1 - dh)
        let window = 0.04 + 0.14 * tolerance
        // Grey, dark or desaturated pixels are never keyed.
        let colourful = Tone.smoothstep(0.15, 0.35, s) * Tone.smoothstep(0.08, 0.2, v)
        let inKey = 1 - Tone.smoothstep(window, window * 1.6, dh)
        return 1 - inKey * colourful
    }

    public static func cube(key: (Double, Double, Double), tolerance: Double, spill: Double, size n: Int = 32) -> [Float] {
        var out = [Float](repeating: 1, count: n * n * n * 4)
        let k = 1 / Double(n - 1)
        let dominant = key.1 >= key.0 && key.1 >= key.2 ? 1 : (key.2 >= key.0 ? 2 : 0)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    var c = [Double(ri) * k, Double(gi) * k, Double(bi) * k]
                    let a = alpha(r: c[0], g: c[1], b: c[2], key: key, tolerance: tolerance)
                    // Spill: cap the key channel at the mean of the other two.
                    if spill > 0 {
                        let others = (0..<3).filter { $0 != dominant }.map { c[$0] }
                        let cap = others.reduce(0, +) / 2
                        if c[dominant] > cap { c[dominant] -= (c[dominant] - cap) * min(spill, 1) }
                    }
                    out[i] = Float(c[0] * a); out[i + 1] = Float(c[1] * a); out[i + 2] = Float(c[2] * a); out[i + 3] = Float(a)
                    i += 4
                }
            }
        }
        return out
    }
}
