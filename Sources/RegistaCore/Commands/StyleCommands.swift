import Foundation

// The effects gallery's catalogue, one-click styles and beat sync (issue #16). The gallery (app) and Claude (MCP)
// read the same catalogue: each tile resolves to one ordinary command with its params.

/// Where a gallery tile is applied: a clip, a time range, or the whole picture.
public struct EffectTarget: Sendable {
    public var clipID: String?
    public var start: MediaTime
    public var end: MediaTime?

    public init(clipID: String? = nil, start: MediaTime, end: MediaTime? = nil) {
        self.clipID = clipID
        self.start = start
        self.end = end
    }
}

public enum EffectsCatalog {
    public enum Category: String, CaseIterable, Sendable {
        case filters, adjust, zoom, motion, text, stickers, transitions, speed, logo, captions, layouts, styles, templates
        /// Categories the gallery deck shows as chips (styles have their own deck).
        public static var gallery: [Category] { allCases.filter { $0 != .styles } }
        /// Tab label in the app (Italian).
        public var label: String {
            switch self {
            case .filters: "Filtri"
            case .adjust: "Regola"
            case .zoom: "Zoom"
            case .motion: "Movimento"
            case .text: "Testo"
            case .stickers: "Sticker"
            case .transitions: "Transizioni"
            case .speed: "Velocità"
            case .logo: "Logo"
            case .captions: "Sottotitoli"
            case .layouts: "Layout"
            case .styles: "Stili"
            case .templates: "Motion"
            }
        }
    }

    /// What a tile needs: a clip (speed, chroma key), a moment (sticker, transition), or nothing (filters on the picture).
    public enum Needs: String, Sendable { case clip, moment, picture }

    /// A value the agent (or the app's form) can set on an item: a param of the command it runs, or `intensity`.
    public struct Field: Sendable {
        public var name: String
        /// text, number, time, color, boolean, choice, list (of strings), numbers, rect, point, image, images, clip.
        public var type: String
        public var example: JSONValue
        public var description: String
        public var choices: [String]?

        public init(_ name: String, _ type: String, _ example: JSONValue, _ description: String, choices: [String]? = nil) {
            self.name = name
            self.type = type
            self.example = example
            self.description = description
            self.choices = choices
        }

        var json: JSONValue {
            var o: [String: JSONValue] = ["name": .string(name), "type": .string(type), "example": example, "description": .string(description)]
            if let c = choices { o["choices"] = .array(c.map { .string($0) }) }
            return .object(o)
        }
    }

    public struct Item: Sendable {
        public var id: String
        public var category: Category
        /// Italian tile label.
        public var label: String
        /// One line for the tooltip.
        public var summary: String
        /// For the agent (English): what it looks like, when to propose it, when not to.
        public var guide: CatalogGuide
        /// What can be set, with example values.
        public var fields: [Field]
        public var command: String
        public var needs: Needs
        /// Symbol shown on tiles that cannot preview on a still (and in lists).
        public var symbol: String
        /// An optional engine the tile needs ("blender"): the app hides the tile when it is not installed.
        public var engine: String?
        /// The command params for a target and an intensity 0…1 (0.5 = the tasteful default).
        let build: @Sendable (EffectTarget, Double, Project) -> JSONValue
    }

    /// The command and params a tile runs.
    public static func resolve(_ item: Item, target: EffectTarget, intensity: Double, project: Project) -> (command: String, params: JSONValue) {
        (item.command, item.build(target, min(max(intensity, 0), 1), project))
    }

    /// The command and params with the agent's field values: `start`/`end`/`clipId` move the target, `intensity` scales,
    /// every other field overrides the command param of the same name (`fields.<name>`, a template's field: that name
    /// inside the `fields` param).
    public static func resolve(_ item: Item, fields: [String: JSONValue], target: EffectTarget, intensity: Double, project: Project) -> (command: String, params: JSONValue) {
        var target = target
        let rate = project.settings.frameRate
        if let s = fields["start"]?.doubleValue ?? fields["at"]?.doubleValue { target.start = MediaTime(seconds: max(s, 0)).snapped(to: rate) }
        if let e = fields["end"]?.doubleValue { target.end = MediaTime(seconds: max(e, 0)).snapped(to: rate) }
        if let c = fields["clipId"]?.stringValue { target.clipID = c }
        let i = fields["intensity"]?.doubleValue ?? intensity
        var (command, params) = resolve(item, target: target, intensity: i, project: project)
        if case .object(var o) = params {
            for (k, v) in fields where k != "intensity" {
                // A template's field is listed as `fields.<name>` (#89): it goes inside the object named before the dot.
                if let dot = k.firstIndex(of: "."), dot > k.startIndex {
                    let head = String(k[..<dot])
                    var inner = o[head]?.objectValue ?? [:]
                    inner[String(k[k.index(after: dot)...])] = v
                    o[head] = .object(inner)
                } else {
                    o[k] = v
                }
            }
            params = .object(o)
        }
        return (command, params)
    }

    /// Where an applied item shows on the timeline, seconds: its own start/end, the cut of a transition, the clip it
    /// added or retimed (the effect previews render frames inside it).
    public static func window(params: JSONValue, result: JSONValue, target: EffectTarget, project: Project) -> (Double, Double) {
        let end = max(project.duration.seconds - 1.0 / 30, 0)
        func clamp(_ a: Double, _ b: Double) -> (Double, Double) { (min(max(a, 0), end), min(max(b, a + 0.1), end)) }
        if let s = params["start"]?.doubleValue, let e = params["end"]?.doubleValue { return clamp(s - 0.1, e + 0.2) }
        if let at = result.value(at: "transition.at")?.doubleValue { return clamp(at - 0.4, at + 0.4) }
        if let s = result.value(at: "clip.start")?.doubleValue, let e = result.value(at: "clip.end")?.doubleValue { return clamp(s, min(e, s + 2.4)) }
        if let cid = target.clipID, let loc = project.locate(clip: cid) {
            let c = project.tracks[loc.track].clips[loc.clip]
            return clamp(c.start.seconds, min(c.end.seconds, c.start.seconds + 2.4))
        }
        return clamp(target.start.seconds, target.start.seconds + 1.5)
    }

    public static func named(_ id: String) -> Item? { items.first { $0.id == id } }

    /// The clip under `t` on the main picture track (where clip effects go when nothing is selected).
    public static func mainClip(at t: MediaTime, in project: Project) -> Clip? {
        project.tracks.first { $0.kind == .video && !$0.clips.isEmpty }?.clips.first { $0.start <= t && t < $0.end }
    }

    static func n(_ x: Double) -> JSONValue { .number((x * 1000).rounded() / 1000) }
    static func s(_ t: MediaTime) -> JSONValue { .number(t.displaySeconds) }

    /// Every item: the built-in effects plus the motion templates registered by the engines (MotionRegistry).
    public static var items: [Item] { builtIn + MotionRegistry.items + Blender3D.items }

    /// Common field descriptions.
    enum Fields {
        static let intensity = Field("intensity", "number", 0.5, "0…1, how strong (0.5 = the tasteful default); the catalog turns it into the command's own values.")
        static let clip = Field("clipId", "clip", "c3", "Clip to change (default: the clip under `start` on the main video track).")
        static let pictureClip = Field("clipId", "clip", "c3", "Only this clip (default: the whole picture).")
        static let start = Field("start", "time", 4.2, "Timeline second where it starts — land it on the word it illustrates.")
        static let end = Field("end", "time", 4.8, "Timeline second where it ends (default: a short window after start).")
        static let duration = Field("duration", "time", 1.4, "Seconds on screen.")
        static let color = Field("color", "color", "accent", "#RRGGBB or a brand colour role (primary, accent, ink, paper, highlight…).")
    }

    static let builtIn: [Item] = {
        var out: [Item] = []
        func add(_ id: String, _ c: Category, _ label: String, _ summary: String, _ command: String, _ needs: Needs, _ symbol: String,
                 engine: String? = nil, fields: [Field] = [], _ build: @escaping @Sendable (EffectTarget, Double, Project) -> [String: JSONValue]) {
            out.append(Item(id: id, category: c, label: label, summary: summary, guide: CatalogGuide.of(id), fields: fields, command: command,
                            needs: needs, symbol: symbol, engine: engine, build: { t, i, p in .object(build(t, i, p)) }))
        }
        let F = Fields.self
        /// clipId when the target has one.
        @Sendable func clip(_ t: EffectTarget, _ o: [String: JSONValue]) -> [String: JSONValue] {
            var o = o
            if let c = t.clipID { o["clipId"] = .string(c) }
            return o
        }
        // Filters: on the whole picture unless a clip is chosen.
        for look in Look.all {
            add("look-\(look.id)", .filters, look.label, look.summary, "look.apply", .picture, "camera.filters", fields: [F.intensity, F.pictureClip]) { t, i, _ in
                clip(t, ["look": .string(look.id), "amount": n(i)])
            }
        }
        add("look-none", .filters, "Originale", "Remove the look.", "look.apply", .picture, "circle.slash", fields: [F.pictureClip]) { t, _, _ in clip(t, ["look": "none"]) }
        // Quick adjustments (the Adjust panel has every slider).
        let adjust: [(String, String, String, String, Double)] = [
            ("adjust-light", "Più luce", "Lift exposure and shadows.", "exposure", 0.5), ("adjust-warm", "Caldo", "Warmer colour.", "warmth", 0.6),
            ("adjust-cool", "Freddo", "Cooler colour.", "warmth", -0.6), ("adjust-contrast", "Contrasto", "More contrast.", "contrast", 0.6),
            ("adjust-vignette", "Vignettatura", "Darker edges.", "vignette", 0.8), ("adjust-sharp", "Nitidezza", "Crisper detail.", "sharpness", 0.8),
            ("adjust-mono", "Bianco e nero", "No colour.", "saturation", -1),
        ]
        for (id, label, summary, prop, scale) in adjust {
            add(id, .adjust, label, summary, "adjust.set", .picture, "slider.horizontal.3", fields: [F.intensity, F.pictureClip]) { t, i, _ in
                var o: [String: JSONValue] = [prop: n(prop == "saturation" ? -min(1, 2 * i) : scale * i)]
                if prop == "exposure" { o["shadows"] = n(0.4 * i) }
                return clip(t, o)
            }
        }
        // Zoom.
        let window = [F.start, F.end, F.intensity]
        add("zoom-punch", .zoom, "Punch-in", "A quick zoom bump on the beat.", "effect.add", .moment, "plus.magnifyingglass", fields: window) { t, i, _ in
            clip(t, ["kind": "punchZoom", "start": s(t.start), "end": s(t.end ?? t.start + MediaTime(seconds: 0.5)), "zoom": n(1 + 0.24 * i)])
        }
        add("zoom-slow", .zoom, "Zoom lento", "A slow push-in over the clip.", "clip.keyframe", .clip, "arrow.up.left.and.arrow.down.right", fields: [F.clip]) { t, _, _ in
            clip(t, ["preset": "kenBurns"])
        }
        add("zoom-shake", .zoom, "Scossa", "A short hand-held shake.", "effect.add", .moment, "waveform.path", fields: window) { t, i, _ in
            clip(t, ["kind": "shake", "start": s(t.start), "end": s(t.end ?? t.start + MediaTime(seconds: 0.6)), "amount": n(0.3 + 1.2 * i), "attack": 0.05, "release": 0.2])
        }
        // Motion / FX.
        add("fx-glitch", .motion, "Glitch", "RGB split and jittering blocks for a few frames.", "effect.add", .moment, "rectangle.split.3x3", fields: window) { t, i, _ in
            clip(t, ["kind": "glitch", "start": s(t.start), "end": s(t.end.map { min($0, t.start + MediaTime(seconds: 1)) } ?? t.start + MediaTime(seconds: 0.35)),
                     "amount": n(0.3 + 1.2 * i)])
        }
        add("fx-flash", .motion, "Lampo", "The frame flashes white on a beat.", "effect.add", .moment, "bolt.fill", fields: [F.start, F.intensity]) { t, i, _ in
            clip(t, ["kind": "flash", "start": s(t.start), "end": s(t.start + MediaTime(seconds: 0.25)), "amount": n(0.3 + 0.7 * i)])
        }
        add("fx-blur", .motion, "Sfocatura", "Soft blur in and out.", "effect.add", .moment, "drop", fields: window) { t, i, _ in
            clip(t, ["kind": "blur", "start": s(t.start), "end": s(t.end ?? t.start + MediaTime(seconds: 1)), "radius": n(4 + 30 * i), "attack": 0.2, "release": 0.2])
        }
        add("fx-glow", .motion, "Bagliore", "Highlights bloom softly.", "effect.add", .moment, "sun.max", fields: window) { t, i, _ in
            clip(t, ["kind": "glow", "start": s(t.start), "end": s(t.end ?? t.start + MediaTime(seconds: 1.5)), "amount": n(0.2 + 0.8 * i), "attack": 0.2, "release": 0.3])
        }
        add("fx-chroma", .motion, "Chroma key", "Remove a green screen from an overlay clip.", "effect.add", .clip, "person.crop.rectangle",
            fields: [F.clip, F.intensity, Field("color", "color", "#00FF00", "Screen colour to key out.")]) { t, i, _ in
            clip(t, ["kind": "chromaKey", "color": "#00FF00", "tolerance": n(0.2 + 0.6 * i), "spill": 0.6])
        }
        // Text & callouts. Callouts default to the middle of the frame: drag them after with the agent or the inspector.
        let titleFields = [Field("text", "text", "Il tuo sito lavora per te?", "The words, ≤ 7; \\n starts a new line."), F.start,
                           Field("duration", "time", 2.5, "Seconds on screen."),
                           Field("preset", "text", "hook", "Title preset of the applied brand kit (hook, hookLight, question, kicker, card, stat…).")]
        add("text-hook", .text, "Titolo", "A hook title in the brand style.", "title.add", .moment, "textformat", fields: titleFields) { t, _, p in
            var o: [String: JSONValue] = ["text": "Il tuo titolo", "start": s(t.start)]
            if p.brand?.titles["hook"] != nil { o["preset"] = "hook" }
            return o
        }
        add("text-kicker", .text, "Etichetta", "A small label.", "title.add", .moment, "tag", fields: titleFields) { t, _, p in
            var o: [String: JSONValue] = ["text": "Novità", "start": s(t.start), "size": 34]
            if p.brand?.titles["kicker"] != nil { o["preset"] = "kicker" }
            return o
        }
        // Optional 3D (Blender installed, Medium tier+): an extruded title for the hook; the 2D titles above are the fallback.
        add("text-3d", .text, "Titolo 3D", "A real 3D title (Blender, ~1–2 min the first time, cached); for the hook only.", "graphics.blenderTitle",
            .moment, "cube", engine: "blender",
            fields: [Field("line1", "text", "AGGIORNATO", "First line."), Field("line2", "text", "= SICURO?", "Second line."), F.start,
                     Field("duration", "time", 3, "Seconds on screen.")]) { t, _, _ in
            ["line1": "IL TUO", "line2": "TITOLO", "start": s(t.start), "duration": 3]
        }
        let geometry: @Sendable (Project) -> (Double, Double) = { p in (Double(p.settings.width), Double(p.settings.height)) }
        let calloutFields = [F.start, Field("duration", "time", 2, "Seconds on screen."),
                             Field("rect", "rect", [300, 680, 480, 160], "[x, y, w, h] of the thing to mark, pixels of the project frame."), F.color,
                             Field("width", "number", 10, "Stroke width, px at 1080 wide.")]
        for (kind, label, symbol) in [("circle", "Cerchio", "circle"), ("underline", "Sottolinea", "underline"), ("box", "Riquadro", "rectangle"),
                                      ("highlight", "Evidenzia", "highlighter")] {
            add("callout-\(kind)", .text, label, "A hand-drawn \(kind) that draws itself on.", "callout.add", .moment, symbol, fields: calloutFields) { t, i, p in
                let (W, H) = geometry(p)
                return ["kind": .string(kind), "start": s(t.start), "rect": .array([n(W * 0.28), n(H * 0.36), n(W * 0.44), n(H * 0.08)]),
                        "width": n(6 + 10 * i)]
            }
        }
        add("callout-arrow", .text, "Freccia", "An arrow that draws itself towards a point.", "callout.add", .moment, "arrow.up.right",
            fields: [F.start, Field("duration", "time", 2, "Seconds on screen."), Field("from", "point", [240, 1100], "Tail [x, y], pixels."),
                     Field("to", "point", [500, 840], "Head [x, y], pixels."), F.color]) { t, i, p in
            let (W, H) = geometry(p)
            return ["kind": "arrow", "start": s(t.start), "from": .array([n(W * 0.22), n(H * 0.58)]), "to": .array([n(W * 0.46), n(H * 0.44)]), "width": n(6 + 10 * i)]
        }
        add("progress-bar", .text, "Barra di avanzamento", "A thin bar filling while the video plays.", "progress.add", .picture, "minus",
            fields: [Field("position", "choice", "top", "Edge.", choices: ["top", "bottom"]), Field("thickness", "number", 8, "Bar height, px at 1080 wide."),
                     F.color]) { _, i, _ in
            ["thickness": n(5 + 10 * i)]
        }
        // Stickers.
        let stickerFields = [F.start, F.duration, Field("size", "number", 160, "Glyph height, px at 1080 wide."),
                             Field("position", "point", [540, 380], "Centre [x, y] on a 1080×1920 frame (default: the top band).")]
        for st in StickerLibrary.items {
            add("sticker-\(st.id)", .stickers, st.label, "Pops in on a moment.", "sticker.add", .moment, st.sticker.kind == .symbol ? st.sticker.value : "face.smiling",
                fields: stickerFields) { t, i, _ in
                ["sticker": .string(st.id), "start": s(t.start), "size": n(110 + 120 * i), "animIn": i > 0.66 ? "bounce" : "pop"]
            }
        }
        // Transitions at a cut.
        let cutFields = [Field("at", "time", 6.4, "Time of the cut (default: the nearest cut within 1 s of start)."),
                         Field("duration", "time", 0.3, "Seconds, centred on the cut.")]
        for (kind, label, symbol) in [("flash", "Lampo bianco", "sun.max.fill"), ("whip", "Frustata", "wind"), ("dip", "Dissolvenza al nero", "circle.lefthalf.filled")] {
            add("transition-\(kind)", .transitions, label, "A \(kind) transition on the cut.", "transition.add", .moment, symbol, fields: cutFields) { t, i, p in
                // On the nearest cut of the main track when there is one within a second, else at the moment.
                let cuts = p.tracks.first { $0.kind == .video }?.clips.dropFirst().map(\.start) ?? []
                let at = cuts.min { abs(($0 - t.start).seconds) < abs(($1 - t.start).seconds) }.flatMap { abs(($0 - t.start).seconds) <= 1 ? $0 : nil } ?? t.start
                let base = kind == "flash" ? 0.2 : kind == "whip" ? 0.3 : 0.5
                return ["kind": .string(kind), "at": s(at), "duration": n(base * (0.6 + 0.8 * i))]
            }
        }
        // Speed.
        let speeds: [(String, String, String, String)] = [
            ("slowmo", "Rallenty", "Half speed.", "tortoise"), ("superSlowmo", "Super rallenty", "Quarter speed (sound muted).", "tortoise.fill"),
            ("fast", "Veloce", "Double speed.", "hare"), ("timelapse", "Timelapse", "Four times faster.", "hare.fill"),
            ("hero", "Rampa eroica", "Normal, slow motion in the middle, normal.", "chart.line.downtrend.xyaxis"),
            ("rampIn", "Rampa in", "Fast, then slow.", "arrow.down.right"), ("rampOut", "Rampa out", "Slow, then fast.", "arrow.up.right"),
            ("reverse", "Al contrario", "Plays backwards (sound muted).", "backward.fill"), ("normal", "Normale", "Original speed.", "play"),
        ]
        for (preset, label, summary, symbol) in speeds {
            add("speed-\(preset)", .speed, label, summary, "clip.speed", .clip, symbol, fields: [F.clip]) { t, _, _ in clip(t, ["preset": .string(preset)]) }
        }
        add("speed-freeze", .speed, "Fermo immagine", "Holds the frame for a moment.", "clip.speed", .clip, "pause.rectangle",
            fields: [F.clip, Field("freezeAt", "time", 5.2, "Timeline second of the frame to hold (default: start)."),
                     Field("freezeDuration", "time", 0.8, "How long the frame holds, seconds.")]) { t, i, _ in
            clip(t, ["freezeAt": s(t.start), "freezeDuration": n(0.5 + 1.5 * i)])
        }
        // Logo.
        for (motion, label, summary, symbol) in [("sting", "Sting finale", "A short logo hit at the end.", "seal"), ("spin", "Giro", "One turn growing in.", "arrow.clockwise"),
                                                 ("pulse", "Pulsazione", "Gentle breathing.", "dot.radiowaves.left.and.right"), ("orbit", "Orbita", "Slow drift on a circle.", "circle.dashed")] {
            add("logo-\(motion)", .logo, label, summary, "logo.animate", .picture, symbol,
                fields: [Field("start", "time", 12, "Timeline start (sting default: the last 1.6 s = outro)."), Field("duration", "time", 1.6, "Seconds.")]) { t, _, _ in
                var o: [String: JSONValue] = ["motion": .string(motion)]
                if motion != "sting" { o["start"] = s(t.start) }
                return o
            }
        }
        // Caption styles, speaker layouts, following, HUD, the blur transition (LooksCatalog).
        out += LooksCatalog.items
        // One-click styles (the app's Stili deck).
        for (style, label, symbol) in [("energico", "Reel energico", "bolt.fill"), ("pulito", "Pulito", "sparkles"), ("tutorial", "Tutorial", "cursorarrow.click"),
                                       ("console", "Console", "rectangle.inset.filled")] {
            add("style-\(style)", .styles, label, "One-click style \(style).", "style.apply", .picture, symbol, fields: [F.intensity]) { _, i, _ in
                ["style": .string(style), "intensity": n(i)]
            }
        }
        return out
    }()

    static func json(_ item: Item, full: Bool = true) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(item.id), "category": .string(item.category.rawValue), "label": .string(item.label),
                                      "description": .string(item.guide.description), "command": .string(item.command), "needs": .string(item.needs.rawValue)]
        if full {
            o["categoryLabel"] = .string(item.category.label)
            o["useWhen"] = .string(item.guide.useWhen)
            o["avoid"] = .string(item.guide.avoid)
            o["fields"] = .array(item.fields.map(\.json))
            o["engine"] = item.engine.map { .string($0) } ?? .null
        }
        return .object(o)
    }
}

enum EffectsCatalogList: Command {
    static let id = "effects.catalog"
    static let summary = "Everything the user can add from the app's Graphics panel, and the way to recommend it: looks (filters), adjustments, zooms, FX, text and callouts, stickers, transitions, speed, logo motions, one-click styles and motion templates (animated cards, checklists, counters, carousels, device frames, charts… category templates). Each item has an English description (what it looks like), useWhen (when to propose it), avoid (when not to), its fields with example values, what it needs (a clip, a moment, or the whole picture) and the ordinary command it runs. Read it before dressing a reel: pick 1–3 items that fit a line, tell the user why, show one with effects.preview on request, then apply it. With item (+ clipId/start/end/intensity/fields) it also returns the exact command and params to run. brief: true lists only id, label and description. Returns the items."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("category", .oneOf(EffectsCatalog.Category.allCases.map(\.rawValue)), "Only this category."),
        .optional("item", .string, "One item id: also resolve its command."),
        .optional("clipId", .string, "Target clip for item."),
        .optional("start", .time, "Target moment for item (default: the clip start, else 0)."),
        .optional("end", .time, "Target range end for item."),
        .optional("intensity", .number, "0…1 (default 0.5)."),
        .optional("fields", .object, "Field values for item (names from its fields); they override the resolved params."),
        .optional("brief", .boolean, "Only id, category, label and description per item (a quick overview)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        if let id = p.string("item") {
            guard let item = EffectsCatalog.named(id) else { throw CommandError.notFound("\(Self.id): no item \(id) (call effects.catalog without item for the list)") }
            let project = try ctx.requireProject()
            let r = try EffectsPreview.resolve(item, p, project)
            return ["item": EffectsCatalog.json(item), "command": .string(r.command), "params": r.params]
        }
        let cat = p.string("category")
        let full = !(p.bool("brief") ?? false)
        return ["items": .array(EffectsCatalog.items.filter { cat == nil || $0.category.rawValue == cat }.map { EffectsCatalog.json($0, full: full) }),
                "categories": .array(EffectsCatalog.Category.allCases.map { ["id": .string($0.rawValue), "label": .string($0.label)] })]
    }
}

enum EffectsPreview: Command {
    static let id = "effects.preview"
    static let summary = "Show the user what a catalog item would look like before applying it (\"show me that effect\"): applies the item (effects.catalog id, with optional field values) to a throwaway copy of the project and renders it with the export compositor at a moment — one still at the moment it shows best, or `frames` (2–12) evenly over its animation as one contact sheet. The edit and the undo history are not touched. Returns the image(s) inline, their paths, the command and params that would apply it, and the time window."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("item", .string, "Catalog item id (effects.catalog)."),
        .optional("fields", .object, "Field values (names from the item's fields), e.g. {\"title\": \"…\", \"rows\": [\"…\"]}."),
        .optional("at", .time, "Timeline moment to apply it at (default: one third into the timeline)."),
        .optional("clipId", .string, "Target clip (items that need a clip; default: the clip under `at`)."),
        .optional("intensity", .number, "0…1 (default 0.5)."),
        .optional("frames", .integer, "1 = one still (default); 2–12 = a contact sheet across the item's animation."),
        .optional("captions", .boolean, "Draw the captions too (default true)."),
        Render.presetParam,
    ]

    /// The item's command and params for a request (item resolve of effects.catalog, and the preview).
    static func resolve(_ item: EffectsCatalog.Item, _ p: CommandParams, _ project: Project, at: MediaTime? = nil) throws -> (command: String, params: JSONValue, target: EffectTarget) {
        // Read from the raw values: effects.catalog names the moment `start`, effects.preview `at`.
        let v = p.values
        func time(_ k: String) -> MediaTime? { v[k]?.doubleValue.map { MediaTime(seconds: max($0, 0)) } }
        var start = time("start") ?? time("at") ?? at
        let given = v["clipId"]?.stringValue
        let clipID = given ?? (item.needs == .clip ? start.flatMap { EffectsCatalog.mainClip(at: $0, in: project)?.id } : nil)
        if start == nil, let cid = clipID { let (t, c) = try Timeline.locate(clip: cid, in: project); start = project.tracks[t].clips[c].start }
        let target = EffectTarget(clipID: item.needs == .picture ? given : clipID, start: (start ?? .zero).snapped(to: project.settings.frameRate),
                                  end: time("end"))
        let r = EffectsCatalog.resolve(item, fields: v["fields"]?.objectValue ?? [:], target: target, intensity: v["intensity"]?.doubleValue ?? 0.5, project: project)
        return (r.command, r.params, target)
    }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let id = p.requiredString("item")
        guard let item = EffectsCatalog.named(id) else { throw CommandError.notFound("\(Self.id): no item \(id) (effects.catalog lists them)") }
        let project = try ctx.requireProject()
        guard project.duration > .zero else { throw CommandError.conflict("\(Self.id): the timeline is empty — place a clip first") }
        let renderer = try Render.renderer(ctx, command: Self.id)
        let r = try resolve(item, p, project, at: p.has("clipId") ? nil : MediaTime(seconds: project.duration.seconds / 3))
        guard let command = Commands.all.first(where: { $0.id == r.command }) else { throw CommandError(.io, "\(Self.id): unknown command \(r.command)") }
        // A throwaway copy of the context: nothing below reaches the engine, the project or the history.
        var scratch = ctx
        let result = try command.run(try CommandParams(validating: r.params, for: command.descriptor), &scratch)
        let edited = try scratch.requireProject()
        let (a, b) = EffectsCatalog.window(params: r.params, result: result, target: r.target, project: edited)
        let rate = edited.settings.frameRate
        let n = min(max(p.int("frames") ?? 1, 1), 12)
        let times: [MediaTime] = n == 1 ? [MediaTime(seconds: a + (b - a) * (item.category == .templates ? 0.7 : 0.5)).snapped(to: rate)]
            : (0..<n).map { MediaTime(seconds: a + (b - a) * (Double($0) + 0.5) / Double(n)).snapped(to: rate) }
        let base = try ctx.projectURL?.appendingPathComponent("previews") ?? Previews.directory()
        let folder = base.appendingPathComponent("preview-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pngs = times.indices.map { folder.appendingPathComponent(String(format: "%@-%02d.png", id, $0)) }
        let job = RenderJob(project: edited, preset: ExportPreset.named(p.string("preset"), project: edited), captions: p.bool("captions") ?? true)
        try renderer.renderFrames(job, at: times, to: pngs)
        var out: [String: JSONValue] = ["item": .string(id), "command": .string(r.command), "params": r.params,
                                        "window": .array([.number(a), .number(b)]), "times": .array(times.map { ProjectState.seconds($0) })]
        if n == 1 {
            out["path"] = .string(pngs[0].path)
            out["images"] = .array(try Previews.frames(pngs, ctx))
        } else if let images = ctx.services.images {
            let sheet = folder.appendingPathComponent("\(id)-sheet.jpg")
            let size = try images.writeContactSheet(pngs, labels: times.map { String(format: "%.2f s", $0.seconds) }, maxWidth: Previews.sheetSize,
                                                    maxHeight: Previews.sheetSize, to: sheet)
            out["path"] = .string(sheet.path)
            out["images"] = [Previews.entry(sheet, size)]
        } else {
            out["paths"] = .array(pngs.map { .string($0.path) })
        }
        if let w = result["warnings"] { out["warnings"] = w }
        return .object(out)
    }
}

// MARK: - Nested command helper

enum Nested {
    /// Runs another command inside this one (same context: one undo step for the whole bundle).
    @discardableResult
    static func run(_ command: any Command.Type, _ params: [String: JSONValue], _ ctx: inout CommandContext) throws -> JSONValue {
        try command.run(try CommandParams(validating: .object(params), for: command.descriptor), &ctx)
    }
}

// MARK: - Styles

enum StyleApply: Command {
    static let id = "style.apply"
    static let summary = "One-click style: a bundle of ordinary edits, undone as one step, in the active brand kit's colours. energico (Reel energico): a vivid look, alternating punch-in framing per sentence (clip), a soft whoosh on a few cuts (≥ 3 s apart, max 6), word-by-word pop captions. pulito (Pulito): a light airy look, gentle contrast and sharpness, calm chunk captions, no sound effects. tutorial: auto-zoom on the recording's clicks with a circle callout on each (screen recordings), a progress bar, crisp picture. console (Console): the whole reel as a 'live editing console' — dark grid + glow backdrop (background-scene), the speaker in a neon inset card (PREVIEW chip, brand accent glow), the status row with REC timer and numbered chapters (pass chapters, one per script section), bold-keyword captions in the accent. intensity scales every move (default 0.6). Returns what was applied and what was skipped (and why)."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("style", .oneOf(["energico", "pulito", "tutorial", "console"]), "Style."),
        .optional("intensity", .number, "0…1 (default 0.6)."),
        .optional("chapters", .array(.object), "console: [{at: seconds, label}] for the status row's chapter badge (status.add)."),
        .optional("label", .string, "console: text after the REC dot (default EDITING LIVE)."),
        .optional("trackId", .string, "Main video track (default: the first one)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let i = min(max(p.number("intensity") ?? 0.6, 0), 1)
        let main: Track
        if let tid = p.string("trackId") { main = project.tracks[try Timeline.trackIndex(tid, in: project)] }
        else {
            guard let v = project.tracks.first(where: { $0.kind == .video && !$0.clips.isEmpty }) else { throw CommandError.conflict("\(id): no video on the timeline") }
            main = v
        }
        var applied: [JSONValue] = [], skipped: [JSONValue] = []
        func step(_ what: String, _ body: (inout CommandContext) throws -> Void) {
            do { try body(&ctx); applied.append(.string(what)) } catch { skipped.append(.string("\(what): \(error)")) }
        }
        let hasCaptions = project.tracks.contains { $0.captions != nil }
        switch p.requiredString("style") {
        case "energico":
            step("look vivid \(Int(i * 60)) %") { try Nested.run(LookApply.self, ["look": "vivid", "amount": .number(0.6 * i)], &$0) }
            step("punch-in on every other clip") { ctx in
                var pr = try ctx.requireProject()
                let t = pr.trackIndex(main.id)!
                for (k, c) in pr.tracks[t].clips.enumerated() where k % 2 == 1 && c.keyframes == nil {
                    var tr = c.transform ?? Transform()
                    tr.scale *= 1 + 0.12 * i
                    pr.tracks[t].clips[k].transform = tr
                }
                ctx.project = pr
            }
            // sfx.onCuts places the bank's whoosh with its loudest moment on each cut (≥ 3 s apart, max 6).
            step("whoosh on cuts") { try Nested.run(SFXOnCuts.self, ["volume": .number(0.12 + 0.12 * i)], &$0) }
            if hasCaptions { step("pop captions (word by word)") { try Nested.run(CaptionsSetStyle.self, ["overrides": ["reveal": "word"]], &$0) } }
            else { skipped.append("pop captions: no captions yet (captions.generate, then style.apply again)") }
        case "pulito":
            step("look airy \(Int(i * 50)) %") { try Nested.run(LookApply.self, ["look": "airy", "amount": .number(0.5 * i)], &$0) }
            step("gentle contrast and sharpness") { try Nested.run(AdjustSet.self, ["contrast": .number(0.12 * i), "sharpness": .number(0.25 * i)], &$0) }
            if hasCaptions { step("calm captions (whole lines)") { try Nested.run(CaptionsSetStyle.self, ["overrides": ["reveal": "chunk"]], &$0) } }
        case "tutorial":
            if project.recordings?.isEmpty == false {
                var zoom: JSONValue = .null
                step("auto-zoom on clicks") { zoom = try Nested.run(EditAutoZoom.self, ["zoom": .number(1.4 + 0.6 * i)], &$0) }
                step("circle callouts on clicks") { ctx in
                    let pr = try ctx.requireProject()
                    var last = -10.0, n = 0
                    let W = Double(pr.settings.width), H = Double(pr.settings.height), r = min(W, H) * 0.07
                    for row in zoom.value(at: "clicks")?.arrayValue ?? [] {
                        guard let t = row["time"]?.doubleValue, t - last >= 2, n < 8 else { continue }
                        // The zoom lands each click near the frame centre.
                        try Nested.run(CalloutAdd.self, ["kind": "circle", "start": .number(t), "duration": 1.4,
                                                         "rect": .array([.number(W / 2 - r), .number(H / 2 - r), .number(2 * r), .number(2 * r)])], &ctx)
                        last = t; n += 1
                    }
                    if n == 0 { throw CommandError.conflict("no clicks") }
                }
            } else {
                skipped.append("auto-zoom and click callouts: not a screen recording (recording.import)")
            }
            step("progress bar") { try Nested.run(ProgressAdd.self, ["thickness": .number(6 + 6 * i)], &$0) }
            step("crisp picture") { try Nested.run(AdjustSet.self, ["sharpness": .number(0.3 * i), "contrast": .number(0.06 * i)], &$0) }
        case "console":
            // Round-3 reference ad: one theme for the whole reel, in the kit's accent.
            let accent = project.brand?.colors["highlight"] ?? project.brand?.colors["accent"] ?? "#FF7A1A"
            step("neon inset card") { try Nested.run(LayoutSpeaker.self, ["preset": "inset-frame", "trackId": .string(main.id), "accent": .string(accent)], &$0) }
            step("dark backdrop") { ctx in
                var pr = try ctx.requireProject()
                pr.settings.background = "#0B0B0D"
                ctx.project = pr
            }
            if MotionRegistry.spec("background-scene") != nil {
                // The dark grid + glow scene on a track under the speaker, for the whole picture.
                step("grid + glow backdrop under the card") { ctx in
                    try Nested.run(TrackAdd.self, ["kind": "overlay", "name": "Backdrop", "index": 0], &ctx)
                    let pr = try ctx.requireProject()
                    try Nested.run(MotionAdd.self, ["template": "background-scene", "start": 0, "end": .number(pr.pictureEnd.seconds),
                                                    "trackId": .string(pr.tracks[0].id), "fields": ["style": "dark-grid", "color": .string(accent)]], &ctx)
                }
            } else {
                skipped.append("grid + glow backdrop: needs the background-scene motion template (not in this host)")
            }
            var status: [String: JSONValue] = ["color": .string(accent), "timerRate": 8, "timerStart": 64]
            if let c = p.json("chapters") { status["chapters"] = c } else { skipped.append("chapter badge: pass chapters [{at, label}] (one per script section)") }
            if let l = p.string("label") { status["label"] = .string(l) }
            step("status row (REC timer\(p.has("chapters") ? " + chapters" : ""))") { try Nested.run(StatusAdd.self, status, &$0) }
            if hasCaptions {
                step("bold-keyword captions in the accent") {
                    try Nested.run(CaptionsSetStyle.self, ["style": "bold-keyword", "overrides": ["keywordBoxColor": .string(accent)]], &$0)
                }
            } else { skipped.append("captions: none yet (captions.generate style bold-keyword, then they sit under the card)") }
        default: break
        }
        return ["style": .string(p.requiredString("style")), "applied": .array(applied), "skipped": .array(skipped),
                "brand": ctx.project?.brand.map { .string($0.id) } ?? .null]
    }
}

// MARK: - Beat sync

enum EditBeatSync: Command {
    static let id = "edit.beatSync"
    static let summary = "Cut or punch on the music: finds the beats of the music track (tempo + beat grid from the onsets, local DSP) and adds, every `every` beats inside [from, to), a punch-in zoom (mode punch, default every 4 beats = once a bar), a cut with alternating framing (mode cuts: the main clip is cut on the beat and every other segment is zoomed in) or a marker (mode markers). Taste: punches on downbeats of the chorus, not on every beat of the reel. Returns the tempo, the beats and what was added."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("mode", .oneOf(["punch", "cuts", "markers"]), "What to do on the beats (default punch)."),
        .optional("musicTrackId", .string, "Music track (default: the track with role music, else the second audio track)."),
        .optional("trackId", .string, "Video track to cut or punch (default: the first one)."),
        .optional("every", .integer, "One event every n beats (default: punch 4, cuts 2, markers 1)."),
        .optional("offset", .integer, "Skip this many beats first (default 0)."),
        .optional("from", .time, "Timeline start of the range (default 0)."),
        .optional("to", .time, "Timeline end (default: the end of the picture)."),
        .optional("zoom", .number, "Punch / cut zoom (default 1.08 punch, 1.12 cuts)."),
        .optional("beats", .array(.number), "Use these beat times (timeline s) instead of detecting them."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let mode = p.string("mode") ?? "punch"
        var tempo = 0.0
        var beats: [Double]
        if let given = p.numbers("beats") { beats = given.sorted() }
        else {
            let music: Track
            if let tid = p.string("musicTrackId") { music = project.tracks[try Timeline.trackIndex(tid, in: project)] }
            else if let m = project.tracks.first(where: { $0.kind == .audio && $0.role == "music" && !$0.clips.isEmpty }) { music = m }
            else if let m = project.tracks.filter({ $0.kind == .audio && !$0.clips.isEmpty }).dropFirst().first { music = m }
            else { throw CommandError.conflict("\(id): no music track (audio.addMusic first, or pass musicTrackId / beats)") }
            let audio = ctx.services.audio
            let rate = 22_050
            let length = Int((project.duration.seconds * Double(rate)).rounded())
            let wav = try ctx.mediaDirectory().appendingPathComponent("beats-\(UUID().uuidString.prefix(6)).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            var mute = project
            for t in mute.tracks.indices where mute.tracks[t].kind == .audio { mute.tracks[t].ducking = nil }
            try audio.mix(AudioPlan.clips(mute, rate: rate, tracks: [music.id]), length: length, rate: rate, gain: 0, ceiling: 0, to: wav)
            let r = BeatDetector.detect(try WAVAudio.read(wav))
            tempo = r.tempo
            beats = r.beats
        }
        let rate = project.settings.frameRate
        let from = p.time("from")?.seconds ?? 0, to = p.time("to")?.seconds ?? project.pictureEnd.seconds
        let every = max(p.int("every") ?? (mode == "punch" ? 4 : mode == "cuts" ? 2 : 1), 1)
        let picked = beats.filter { $0 >= from && $0 < to }.enumerated().filter { ($0.offset - (p.int("offset") ?? 0)) % every == 0 && $0.offset >= (p.int("offset") ?? 0) }
            .map { MediaTime(seconds: $0.element).snapped(to: rate) }
        guard !picked.isEmpty else { throw CommandError.conflict("\(id): no beats in [\(from), \(to)) s") }
        let vt: Int
        if let tid = p.string("trackId") { vt = try Timeline.trackIndex(tid, in: project) }
        else {
            guard let v = project.tracks.firstIndex(where: { $0.kind == .video && !$0.clips.isEmpty }) else { throw CommandError.conflict("\(id): no video clip to sync") }
            vt = v
        }
        var added = 0
        switch mode {
        case "markers":
            for b in picked { project.markers.append(Marker(id: project.makeID("m"), time: b, name: "beat")); added += 1 }
            ctx.project = project
        case "cuts":
            ctx.project = project
            let trackID = project.tracks[vt].id
            for b in picked where (try? Nested.run(TimelineCut.self, ["at": .number(b.seconds), "trackId": .string(trackID)], &ctx)) != nil { added += 1 }
            var pr = try ctx.requireProject()
            let z = p.number("zoom") ?? 1.12
            var parity = false
            for k in pr.tracks[vt].clips.indices {
                let c = pr.tracks[vt].clips[k]
                guard c.end.seconds > from, c.start.seconds < to else { continue }
                if parity, c.keyframes == nil { var tr = c.transform ?? Transform(); tr.scale *= z; pr.tracks[vt].clips[k].transform = tr }
                parity.toggle()
            }
            ctx.project = pr
        default:
            ctx.project = project
            let z = p.number("zoom") ?? 1.08
            for b in picked {
                guard let c = project.tracks[vt].clips.first(where: { $0.start <= b && b < $0.end }) else { continue }
                let end = min(b + MediaTime(seconds: 0.45), c.end)
                guard end > b else { continue }
                try Nested.run(EffectAdd.self, ["kind": "punchZoom", "clipId": .string(c.id), "start": .number(b.seconds), "end": .number(end.seconds),
                                                "zoom": .number(z), "attack": 0.05, "release": 0.3], &ctx)
                added += 1
            }
        }
        return ["mode": .string(mode), "tempo": .number((tempo * 10).rounded() / 10), "beats": .number(Double(beats.count)),
                "times": .array(picked.prefix(64).map { ProjectState.seconds($0) }), "added": .number(Double(added))]
    }
}
