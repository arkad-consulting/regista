import Foundation

// Motion templates (issue #22): animated graphics drawn natively by the compositor (Core Text / Core Image) —
// orbit carousel, checklist card, counter, swing tag, marquee, device frame, card stack, HUD, charts…
//
// A template is ONE file in RegistaEngines/Motion/Templates (its `MotionSpec` + its drawing) plus one line in
// `MotionLibrary.templates`. The engines register the specs here at start-up (`EngineServices.live`), so the
// catalog (effects.catalog, the app's gallery), motion.add and the MCP descriptions all read the same list.

/// What a template is, for the catalog, the form and motion.add. Pure data (the drawing lives in RegistaEngines).
public struct MotionSpec: Sendable {
    /// Stable id ("orbit-carousel").
    public var id: String
    /// Italian tile label (the app).
    public var label: String
    /// SF Symbol of the tile.
    public var symbol: String
    public var guide: CatalogGuide
    /// Every field with its type, example (= default value) and description.
    public var fields: [EffectsCatalog.Field]
    /// The 3–5 fields the app's form shows.
    public var form: [String]
    /// Default seconds on screen.
    public var duration: Double
    /// Default band (top, middle, lower) of templates that sit in a band; nil = full frame.
    public var band: String?
    /// Where the layer goes relative to the person matte.
    public var layering: MotionLayer.Layering
    /// The template re-draws the picture under it (device frame: the shot shrinks into a phone); the compositor hands
    /// it everything drawn below and uses its output instead.
    public var consumesBelow: Bool
    /// Field (a list of strings) whose entries can be timed to the transcript (`sync: true` on motion.add): each entry's
    /// time is when its first word is spoken inside the clip window.
    public var syncField: String?
    /// The template fills the frame by design (backgrounds, device frame, HUD): the caption-band check skips it.
    public var coversFrame: Bool

    public init(id: String, label: String, symbol: String, guide: CatalogGuide, fields: [EffectsCatalog.Field], form: [String],
                duration: Double = 3, band: String? = "top", layering: MotionLayer.Layering = .front, consumesBelow: Bool = false,
                syncField: String? = nil, coversFrame: Bool = false) {
        self.coversFrame = coversFrame
        self.id = id
        self.label = label
        self.symbol = symbol
        self.guide = guide
        self.fields = fields
        self.form = form
        self.duration = duration
        self.band = band
        self.layering = layering
        self.consumesBelow = consumesBelow
        self.syncField = syncField
    }

    public func field(_ name: String) -> EffectsCatalog.Field? { fields.first { $0.name == name } }

    /// Every field at its default (the example).
    public var defaults: [String: JSONValue] { Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.example) }) }
}

/// The templates the engines registered. Thread-safe; registering an id again replaces it.
public enum MotionRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var specs: [MotionSpec] = []

    public static func register(_ new: [MotionSpec]) {
        lock.lock(); defer { lock.unlock() }
        for s in new {
            if let i = specs.firstIndex(where: { $0.id == s.id }) { specs[i] = s } else { specs.append(s) }
        }
    }

    public static var all: [MotionSpec] {
        lock.lock(); defer { lock.unlock() }
        return specs
    }

    public static func spec(_ id: String) -> MotionSpec? { all.first { $0.id == id } }

    /// Catalog items (category templates): each runs motion.add with the template's defaults at the moment.
    static var items: [EffectsCatalog.Item] {
        all.map { spec in
            let common: [EffectsCatalog.Field] = [
                EffectsCatalog.Fields.start,
                EffectsCatalog.Field("duration", "time", .number(spec.duration), "Seconds on screen (default \(spec.duration))."),
            ] + (spec.band == nil ? [] : [EffectsCatalog.Field("band", "choice", .string(spec.band!), "Vertical band of a 9:16 reel.", choices: SafeZones.bandNames)])
            let id = spec.id
            return EffectsCatalog.Item(id: id, category: .templates, label: spec.label, summary: spec.guide.description, guide: spec.guide,
                                       fields: common + spec.fields.map { f in
                                           var f = f
                                           f.name = "fields.\(f.name)"
                                           return f
                                       },
                                       command: "motion.add", needs: .moment, symbol: spec.symbol, engine: nil,
                                       build: { t, _, _ in ["template": .string(id), "start": EffectsCatalog.s(t.start)] })
        }
    }
}

/// Colours and fonts a template draws with, resolved from the brand kit when it was added (roles → values).
public struct MotionStyle: Codable, Hashable, Sendable {
    /// Colour roles: ink, paper, primary, accent, highlight, onHighlight, success, surface, text (+ the kit's own).
    public var colors: [String: String]
    /// Font roles: display, text, textBold, mono (names or files).
    public var fonts: [String: String]

    public init(colors: [String: String] = [:], fonts: [String: String] = [:]) {
        self.colors = colors
        self.fonts = fonts
    }

    /// Neutral defaults when no kit is applied: ink / paper, a warm gold accent, system fonts.
    public static let neutral = MotionStyle(
        colors: ["ink": "#141414", "paper": "#F7F4EC", "primary": "#141414", "accent": "#C9A045", "highlight": "#C9A045", "onHighlight": "#141414",
                 "success": "#3E8E5E", "surface": "#FFFFFF", "text": "#141414"],
        fonts: ["display": "HelveticaNeue-Bold", "text": "HelveticaNeue", "textBold": "HelveticaNeue-Bold", "mono": "Menlo-Regular",
                "serif": "Georgia-Italic"])

    /// The neutral style overlaid with the kit's roles.
    public static func from(_ kit: BrandKit?) -> MotionStyle {
        var s = neutral
        guard let kit else { return s }
        for (k, v) in kit.colors { s.colors[k] = v }
        if s.colors["highlight"] == nil, let a = kit.colors["accent"] { s.colors["highlight"] = a }
        for (k, _) in kit.fonts { s.fonts[k] = kit.font(k) }
        return s
    }

    public func color(_ role: String, _ fallback: String = "#FFFFFF") -> String {
        if role.hasPrefix("#") { return role }
        return colors[role] ?? fallback
    }

    public func font(_ role: String) -> String { fonts[role] ?? MotionStyle.neutral.fonts[role] ?? role }
}

/// A motion-template layer on a clip (motion.add). The compositor's template draws it from these values.
public struct MotionLayer: Codable, Hashable, Sendable {
    public enum Layering: String, Codable, CaseIterable, Sendable {
        /// Drawn over the picture (and the person).
        case front
        /// Drawn behind the person (needs matte.track).
        case behind
        /// The template draws a back part behind the person and a front part over it (orbit carousel, marquee rows).
        case split
    }

    public var template: String
    /// Every field of the template, defaults filled in (brand roles kept as roles: the style resolves them).
    public var fields: [String: JSONValue]
    public var style: MotionStyle
    public var layering: Layering
    /// The template re-draws the picture under it (MotionSpec.consumesBelow).
    public var consumesBelow: Bool?

    public init(template: String, fields: [String: JSONValue], style: MotionStyle, layering: Layering = .front) {
        self.template = template
        self.fields = fields
        self.style = style
        self.layering = layering
    }

    // Typed field access for the drawing code.
    public func string(_ k: String, _ d: String = "") -> String { fields[k]?.stringValue ?? d }
    public func number(_ k: String, _ d: Double = 0) -> Double { fields[k]?.doubleValue ?? d }
    public func bool(_ k: String, _ d: Bool = false) -> Bool { fields[k]?.boolValue ?? d }
    public func strings(_ k: String) -> [String] { fields[k]?.arrayValue?.compactMap { $0.stringValue ?? $0.doubleValue.map { String($0) } } ?? [] }
    public func numbers(_ k: String) -> [Double] { fields[k]?.arrayValue?.compactMap(\.doubleValue) ?? [] }
    /// A colour field: a hex, or a role of the style.
    public func color(_ k: String, _ d: String) -> String { style.color(fields[k]?.stringValue ?? d, style.color(d)) }
}

/// Which part of a split layer a VideoLayer draws.
public enum MotionPart: String, Hashable, Sendable { case whole, back, front }
