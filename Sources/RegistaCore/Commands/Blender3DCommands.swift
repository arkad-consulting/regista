import CryptoKit
import Foundation

// Blender 3D templates (issue #34): parametric scenes rendered headless by Blender. A template is ONE Python module in
// Resources/Blender/templates (build(K) -> (update, layers)) plus its spec below; Resources/Blender/regista3d.py is the
// shared runner. graphics.blender3d fills the fields (brand colours and fonts resolved, SVGs rasterized), renders each
// layer to a cached RGBA PNG sequence and places it through overlay.add — layer `back` behind the speaker.

public struct Blender3DSpec: Sendable {
    public var id: String
    /// Italian tile label (the app).
    public var label: String
    public var symbol: String
    public var category: EffectsCatalog.Category
    public var guide: CatalogGuide
    /// Fields with type and example (= default). Types: text, number, choice, boolean, color (hex or role), font (role or
    /// file), list (strings; entries that are image files become pictures), numbers, point, images.
    public var fields: [EffectsCatalog.Field]
    public var duration: Double
    public var width: Int
    public var height: Int
    /// Default band of a band-sized overlay; nil = full frame (1080 × 1920).
    public var band: String?
    /// Rendered layers in drawing order; `back` goes behind the speaker (needs matte.track).
    public var layers: [String]

    public var module: String { id.replacingOccurrences(of: "-", with: "_") }
    public func field(_ name: String) -> EffectsCatalog.Field? { fields.first { $0.name == name } }
    public var defaults: [String: JSONValue] { Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.example) }) }
}

public enum Blender3D {
    typealias F = EffectsCatalog.Field

    public static let templates: [Blender3DSpec] = [
        Blender3DSpec(
            id: "stat-3d", label: "Statistica 3D", symbol: "chart.bar.xaxis", category: .templates,
            guide: CatalogGuide("A big extruded 3D number that counts up (\"+40 %\", \"3×\"), a label under it, and bevelled bars that rise (or a tube curve that grows) from the values; brand gold by default.",
                                useWhen: "The line says a figure — a gain, a saving, a multiple. One per reel, on the number.",
                                avoid: "Figures nobody says out loud; more than one stat per reel; over the face (it sits in a band)."),
            fields: [F("value", "text", "+40 %", "The figure; its number counts up, prefix and suffix stay."),
                     F("label", "text", "de temps gagné", "One short line under the figure."),
                     F("chart", "choice", "bars", "bars, curve or none.", choices: ["bars", "curve", "none"]),
                     F("values", "numbers", [2, 3, 5, 8], "2–8 values for the bars/curve (the last is highlighted)."),
                     F("material", "choice", "gold", "gold (metal) or flat (coated colour).", choices: ["gold", "flat"]),
                     F("color", "color", "primary", "Figure and bars."),
                     F("accent", "color", "accent", "The last bar / the curve's tip."),
                     F("labelColor", "color", "paper", "The label."),
                     F("pillColor", "color", "surface", "The pill under the label."),
                     F("font", "font", "text", "Figure font (role or file)."),
                     F("labelFont", "font", "text", "Label font.")],
            duration: 3, width: 1080, height: 600, band: "top", layers: ["main"]),
        Blender3DSpec(
            id: "orbit-ring-3d", label: "Anello 3D", symbol: "circle.dashed", category: .templates,
            guide: CatalogGuide("Words, logos or photos travelling on a tilted gold ring around the speaker's head in real 3D: the far half passes behind the head, the near half in front (perspective, metal reflections).",
                                useWhen: "Listing 3–6 services, clients or tools while the speaker talks to camera; the head stays still-ish. Needs matte.track over the window.",
                                avoid: "Shots where the head moves a lot or leaves the frame; long phrases (one or two words per item); with other graphics around the head."),
            fields: [F("items", "list", ["APPLICATIONS", "IA", "AUTOMATISATION", "INTÉGRATION"], "3–8 entries: short words, or image files (PNG/JPG/SVG logos, photos)."),
                     F("center", "point", [540, 640], "Ring centre [x, y] on the 1080×1920 frame (forehead height looks best)."),
                     F("radius", "number", 340, "Ring radius, px."),
                     F("tilt", "number", 24, "Degrees the ring leans toward the camera."),
                     F("speed", "number", 0.18, "Turns per second."),
                     F("direction", "choice", "ccw", "ccw or cw.", choices: ["ccw", "cw"]),
                     F("material", "choice", "flat", "flat (coated colour, default), gold (metal) or metal (silver).", choices: ["flat", "gold", "metal"]),
                     F("color", "color", "primary", "Ring (and text unless textColor)."),
                     F("textColor", "color", "paper", "Words (paper on most footage; ink on a light wall)."),
                     F("ring", "boolean", true, "Draw the ring line."),
                     F("textSize", "number", 82, "Word size, px."),
                     F("imageHeight", "number", 150, "Picture height, px."),
                     F("font", "font", "textBold", "Font of the words.")],
            duration: 4, width: 1080, height: 1920, band: nil, layers: ["back", "front"]),
        Blender3DSpec(
            id: "infinite-triangle-3d", label: "Triangolo infinito Arkad", symbol: "triangle", category: .logo,
            guide: CatalogGuide("The Arkad intro: the endless (Penrose) triangle in dark graphite, corners always joined, makes one full turn and lands as a solid dark triangle shaped like the mark; two sparks of Arkad yellow draw its outline from the base corners, it flares, goes out, and the yellow Arkad logo is left in its place. 7 s, transparent.",
                                useWhen: "Opening or closing an Arkad video (intro, end card before the contact line); once per video.",
                                avoid: "Client videos (it is Arkad's own mark); over the speaker's face; more than once."),
            fields: [F("size", "number", 640, "Width of the mark (and of the solid triangle), px."),
                     F("depth", "number", 70, "Thickness of the solid triangle, px."),
                     F("hole", "number", 1.7, "How much wider than the logo's the triangle's hole is."),
                     F("color", "color", "#34322F", "The triangle's graphite."),
                     F("glow", "color", "#F4BD56", "The light: sparks, outline, edge glints (Arkad yellow)."),
                     F("glowAmount", "number", 1.0, "Yellow glints on the endless triangle's edges at the start (0 = none)."),
                     F("direction", "choice", "cw", "Way of the full turn.", choices: ["cw", "ccw"]),
                     F("colorLeft", "color", "#F6CF6B", "Logo gradient, left (the logo's own)."),
                     F("colorRight", "color", "#BE8602", "Logo gradient, right."),
                     F("svg", "svg", "bundle:Brand/arkad-symbol-gold.svg", "The mark's SVG (outer outline + inner triangle).")],
            duration: 7, width: 1080, height: 1080, band: "middle", layers: ["main"]),
    ]

    public static func spec(_ id: String) -> Blender3DSpec? { templates.first { $0.id == id } }

    /// Catalog tiles (engine blender: the app hides them when Blender is missing).
    static var items: [EffectsCatalog.Item] {
        templates.map { spec in
            let common: [F] = [EffectsCatalog.Fields.start,
                               F("duration", "time", .number(spec.duration), "Seconds on screen (default \(spec.duration)).")]
            let id = spec.id
            return EffectsCatalog.Item(id: id, category: spec.category, label: spec.label, summary: spec.guide.description, guide: spec.guide,
                                       fields: common + spec.fields.map { f in
                                           var f = f
                                           f.name = "fields.\(f.name)"
                                           return f
                                       },
                                       command: GraphicsBlender3D.id, needs: .moment, symbol: spec.symbol, engine: "blender",
                                       build: { t, _, _ in ["template": .string(id), "start": EffectsCatalog.s(t.start)] })
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "svg", "webp", "heic"]
}

enum GraphicsBlender3D: Command {
    static let id = "graphics.blender3d"
    static let summary = "Add a Blender 3D template — a real 3D graphic rendered headless (EEVEE, separate process, Medium tier+): stat-3d (an extruded figure that counts up over rising bars), orbit-ring-3d (words or logos on a ring around the head, far half behind the speaker), infinite-triangle-3d (the Arkad intro: the endless triangle turns, its outline lights up in yellow and leaves the logo)… effects.catalog {category: \"templates\"} lists them with their fields (ids ending in -3d). Colours accept #RRGGBB or brand roles (primary, accent, paper, ink…), fonts a role (display, text, mono) or a file; list entries that are image files become pictures (SVGs rasterized). ~0.3 s per frame the first time, cached afterwards. Templates with a back layer go behind the speaker: run matte.track over the window first. Returns the overlay clips (one per layer), render time and whether it came from the cache."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("template", .string, "Template id (stat-3d, orbit-ring-3d, …)."),
        .required("start", .time, "Timeline start (land it on the word)."),
        .optional("duration", .time, "Seconds on screen (default: the template's)."),
        .optional("fields", .object, "Template fields (names from effects.catalog; omitted ones keep their default)."),
        .optional("samples", .integer, "EEVEE samples (default 32; 8 for drafts)."),
    ] + Graphics.positionParams + Graphics.animationParams

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let name = p.requiredString("template")
        guard let spec = Blender3D.spec(name) else {
            throw CommandError.invalid("\(id): no template \"\(name)\" (templates: \(Blender3D.templates.map(\.id).joined(separator: ", ")))")
        }
        let given = p.json("fields")?.objectValue ?? [:]
        for k in given.keys.sorted() where spec.field(k) == nil {
            throw CommandError.invalid("\(id): \(name) has no field \"\(k)\" (fields: \(spec.fields.map(\.name).joined(separator: ", ")))")
        }
        var fields = spec.defaults
        for (k, v) in given {
            if let f = spec.field(k), let problem = check(v, f) { throw CommandError.invalid("\(id): field \(k): \(problem)") }
            fields[k] = v
        }
        let kit = project.brand ?? BrandKit.wesites
        // Resolve roles, fonts and pictures so the Python side only sees hex colours and absolute paths.
        for f in spec.fields {
            guard let v = fields[f.name] else { continue }
            switch f.type {
            case "color":
                // A role the kit lacks (WeSites has no "surface") falls back to the Arkad kit, which defines every role.
                let raw = v.stringValue ?? ""
                guard let hex = raw.hasPrefix("#") ? raw : kit.colors[raw] ?? BrandKit.arkad.colors[raw] else {
                    throw CommandError.invalid("\(id): field \(f.name): \(raw) is neither #RRGGBB nor a brand colour role")
                }
                fields[f.name] = .string(hex)
            case "font":
                let path = EngineConfig.expand(kit.font(v.stringValue ?? ""))
                guard FileManager.default.fileExists(atPath: path) else { throw CommandError.notFound("\(id): font \(v.stringValue ?? "") is not a file (\(path))") }
                fields[f.name] = .string(path)
            case "svg":
                let raw = v.stringValue ?? ""
                let path = raw.hasPrefix("bundle:") ? BrandKit.bundled(String(raw.dropFirst(7))) : EngineConfig.expand(raw)
                guard FileManager.default.fileExists(atPath: path) else { throw CommandError.notFound("\(id): no SVG at \(raw)") }
                fields[f.name] = .string(path)
            case "list", "images":
                fields[f.name] = .array(try (v.arrayValue ?? []).map { .string(try picture($0.stringValue ?? "", &ctx)) })
            default: break
            }
        }
        let blender = GraphicsEngines.blender(ctx.services.config)
        if let why = GraphicsEngines.unavailable(ctx, engine: "Blender", id: "blender", path: blender) { throw CommandError(.io, "\(id): \(why)") }
        let fps = Int(project.settings.frameRate.doubleValue.rounded())
        let seconds = (p.time("duration") ?? MediaTime(seconds: spec.duration)).seconds
        let runner = URL(fileURLWithPath: BrandKit.bundled("Blender/regista3d.py"))
        let module = URL(fileURLWithPath: BrandKit.bundled("Blender/templates/\(spec.module).py"))
        guard FileManager.default.fileExists(atPath: module.path) else { throw CommandError.notFound("\(id): no script \(module.path)") }
        var job: [String: JSONValue] = ["template": .string(spec.module), "width": .number(Double(spec.width)), "height": .number(Double(spec.height)),
                                        "fps": .number(Double(fps)), "seconds": .number(seconds), "samples": .number(Double(p.int("samples") ?? 32)),
                                        "fields": .object(fields)]
        // Cache key: both scripts' text + the job (fields, size, timing).
        let scripts = (try? String(contentsOf: runner, encoding: .utf8)) ?? ""
        let template = (try? String(contentsOf: module, encoding: .utf8)) ?? ""
        let digest = SHA256.hash(data: Data((scripts + template).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let dir = GraphicsEngines.cacheDir(ctx, "blender3d", key: digest + "|" + String(decoding: JSONValue.object(job).data(), as: UTF8.self))
        let marker = dir.appendingPathComponent("done.json")
        var renderSeconds = 0.0
        let cached = FileManager.default.fileExists(atPath: marker.path)
        if !cached {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            job["out"] = .string(dir.path)
            let jobFile = dir.appendingPathComponent("job.json")
            try JSONValue.object(job).data().write(to: jobFile)
            let started = Date()
            let r = try Subprocess.run(blender, ["-b", "--factory-startup", "-P", runner.path, "--", jobFile.path])
            renderSeconds = Date().timeIntervalSince(started)
            guard r.status == 0, r.stdoutText.contains("RESULT ") else {
                let tail = (r.stdoutText + r.stderrText).split(separator: "\n").suffix(12).joined(separator: "\n")
                throw CommandError(.io, "\(id): Blender failed (exit \(r.status)):\n\(tail)")
            }
            try JSONValue.object(["seconds": .number(renderSeconds)]).data().write(to: marker)
        }
        var clips: [JSONValue] = []
        for layer in spec.layers {
            var extra: [String: JSONValue] = ["duration": .number(seconds)]
            if spec.band == nil { extra["fullFrame"] = true }
            else if !p.has("band") && !p.has("position") && !p.has("top") { extra["band"] = .string(spec.band!) }
            if layer == "back" { extra["behindSubject"] = true }
            if !p.has("animIn") { extra["animIn"] = "none" }
            if !p.has("animOut") { extra["animOut"] = "none" }
            clips.append(try GraphicsEngines.place(dir.appendingPathComponent(layer), p, extra: extra, &ctx))
        }
        return .object(["template": .string(name), "layers": .array(clips), "cached": .bool(cached),
                        "renderSeconds": .number((renderSeconds * 10).rounded() / 10), "frames": .string(dir.path),
                        "fields": .object(fields)])
    }

    static func check(_ v: JSONValue, _ f: EffectsCatalog.Field) -> String? {
        switch f.type {
        case "font", "svg": return v.stringValue == nil ? "expected a string" : nil
        case "point": return v.arrayValue?.count == 2 && v.arrayValue!.allSatisfy({ $0.doubleValue != nil }) ? nil : "expected [x, y]"
        default: return MotionAdd.check(v, f)
        }
    }

    /// A list entry: an image file (expanded; SVG rasterized next to the media) or plain text, unchanged.
    static func picture(_ s: String, _ ctx: inout CommandContext) throws -> String {
        let ext = (s as NSString).pathExtension.lowercased()
        guard Blender3D.imageExtensions.contains(ext) else { return s }
        let path = EngineConfig.expand(s)
        guard FileManager.default.fileExists(atPath: path) else { throw CommandError.notFound("\(id): no image at \(s)") }
        guard ext == "svg" else { return path }
        guard let images = ctx.services.images else { throw CommandError(.io, "\(id): this host cannot rasterize SVG") }
        let png = try ctx.mediaDirectory().appendingPathComponent("\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)-3d.png")
        _ = try images.rasterizeSVG(URL(fileURLWithPath: path), width: 600, to: png)
        return png.path
    }
}
