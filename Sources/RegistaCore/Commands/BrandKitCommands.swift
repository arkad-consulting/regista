import CryptoKit
import Foundation

// Brand kits (issue #17): list, apply, create/update, import/export as .registakit, logos and fonts, the logo
// overlay, a live preview rendered by the compositor and a check of the applied kit on rendered frames.

enum BrandKits {
    static func find(_ id: String, command: String) throws -> BrandKit {
        let all = BrandKit.all()
        guard let k = all[id] else { throw CommandError.notFound("\(command): no kit \"\(id)\" (kits: \(all.keys.sorted().joined(separator: ", ")))") }
        return k
    }

    static func fontsJSON(_ k: BrandKit) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: k.fontReport().map { r in
            (r.role, ["font": .string(r.spec), "resolved": .string(r.resolved), "fallback": .bool(r.fallback)] as JSONValue)
        }))
    }

    static func summary(_ k: BrandKit) -> JSONValue {
        let store = BrandKitStore()
        let user = FileManager.default.fileExists(atPath: store.folder(k.id).appendingPathComponent("kit.json").path)
        var logos: [String: JSONValue] = [:]
        for v in BrandKit.logoVariants { if let p = k.logos?[v] { let f = k.assetPath(p); logos[v] = ["path": .string(f), "found": .bool(FileManager.default.fileExists(atPath: f))] } }
        if logos.isEmpty, let p = k.logo { let f = k.assetPath(p); logos["default"] = ["path": .string(f), "found": .bool(FileManager.default.fileExists(atPath: f))] }
        let placement = k.logoPlacement ?? LogoPlacement()
        return ["id": .string(k.id), "name": .string(k.name), "source": .string(user ? "user" : "builtIn"),
                "folder": user ? .string(store.folder(k.id).path) : .null,
                "colors": .object(k.colors.mapValues { .string($0) }), "fonts": fontsJSON(k), "logos": .object(logos),
                "logo": k.logoPath().map { .string($0) } ?? .null,
                "logoPlacement": (try? JSONValue.from(placement)) ?? .null, "watermark": .bool(k.watermark ?? false),
                "caption": .object(k.captionOverrides()), "titles": .array(k.titles.keys.sorted().map { .string($0) }),
                "notes": k.notes.map { .string($0) } ?? .null]
    }

    /// Restyles the project with `kit`: captions recoloured (their style otherwise kept, #17), preset titles rebuilt, logo overlays swapped
    /// (and laid over the whole video for a watermark kit). Returns what changed.
    static func apply(_ kit: BrandKit, to project: inout Project, _ ctx: inout CommandContext, captions: Bool, command: String) throws -> [String: JSONValue] {
        let stored = try holdingFiles(kit, &ctx, command: command)
        project.brand = stored
        var restyled: [JSONValue] = []
        if captions {
            for t in project.tracks.indices where project.tracks[t].captions != nil {
                project.tracks[t].captions!.style = try stored.captionColors(over: project.tracks[t].captions!.style)
                restyled.append(.string(project.tracks[t].id))
            }
        }
        var titles = 0
        for t in project.tracks.indices {
            for c in project.tracks[t].clips.indices {
                guard let old = project.tracks[t].clips[c].title, let name = project.tracks[t].clips[c].titlePreset, let preset = stored.titles[name] else { continue }
                var n = preset
                n.text = old.text
                n.highlight = old.highlight
                project.tracks[t].clips[c].title = stored.resolve(n)
                titles += 1
            }
        }
        // A styled screen frame on the brand's default background, and the key badges, follow the new kit (issue #44).
        if (project.recordings ?? []).contains(where: { ($0.layouts ?? []).contains { $0.layout.frame != nil && $0.layout.frame?.background == nil } }) {
            project.settings.backdrop = Backdrop.brand(stored)
        }
        KeysOverlay.restyle(&project)
        var warnings: [JSONValue] = []
        var logos = 0
        for t in project.tracks.indices where project.tracks[t].role == "logo" {
            let clips = project.tracks[t].clips
            project.tracks[t].clips.removeAll()
            for old in clips {
                guard stored.logoPath() != nil else { warnings.append(.string("\(kit.name) has no logo: removed logo clip \(old.id)")); continue }
                var made = try LogoOverlay.clip(kit: stored, project: &project, &ctx, start: old.start, end: old.end, placement: stored.logoPlacement ?? LogoPlacement(),
                                                variant: nil, path: nil, command: command)
                made.clip.id = old.id
                project.tracks[t].clips.append(made.clip)
                warnings += made.warnings
                logos += 1
            }
            project.tracks[t].sortClips()
        }
        if stored.watermark == true, logos == 0, project.duration > .zero, stored.logoPath() != nil {
            let made = try LogoOverlay.clip(kit: stored, project: &project, &ctx, start: .zero, end: project.duration,
                                            placement: stored.logoPlacement ?? LogoPlacement(), variant: nil, path: nil, command: command)
            let t = try Graphics.track("logo", in: &project, start: .zero, end: project.duration, preferred: nil)
            project.tracks[t].clips.append(made.clip)
            warnings += made.warnings
            logos = 1
        }
        let missing = stored.fontReport().filter(\.fallback).map { JSONValue.string("\($0.role): \($0.spec) → \($0.resolved)") }
        return ["kit": .string(kit.id), "name": .string(kit.name), "titles": .array(kit.titles.keys.sorted().map { .string($0) }),
                "colors": .object(kit.colors.mapValues { .string($0) }), "captionTracks": .array(restyled), "titlesRestyled": .number(Double(titles)),
                "logos": .number(Double(logos)), "fonts": fontsJSON(stored), "missingFonts": .array(missing), "warnings": .array(warnings),
                "notes": kit.notes.map { .string($0) } ?? .null]
    }

    /// The project's copy of `kit` (#101): every asset path absolute, and the kit's own files — font files, the logo and
    /// its variants — copied into the project's media folder (`media/brandkit-<id>/`), the copy pointing at them, so
    /// deleting or changing the kit does not change the video. Not copied: the files Regista ships (`bundle:`), font
    /// files installed on the Mac, files already in the project's media folder and files that are not there. A file
    /// already copied with the same content is used again; another one of the same name gets the content's hash in its
    /// name. `originals` keeps the kit's path of each copy.
    static func holdingFiles(_ kit: BrandKit, _ ctx: inout CommandContext, command: String) throws -> BrandKit {
        var copy = kit.absolutized()
        var originals: [String: String] = [:]
        var folder: URL?
        let fm = FileManager.default
        let installed = ["/System/Library/Fonts/", "/Library/Fonts/", fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts").path + "/"]
        func own(_ spec: String) throws -> String? {
            guard !spec.hasPrefix("bundle:") else { return nil }
            let source = URL(fileURLWithPath: kit.assetPath(spec)).standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), !isDir.boolValue,
                  !installed.contains(where: source.path.hasPrefix) else { return nil }
            let media = try ctx.mediaDirectory().standardizedFileURL
            guard !source.path.hasPrefix(media.path + "/") else { return nil }
            let dir = try folder ?? {
                let d = media.appendingPathComponent("brandkit-\(kit.id)")
                do { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
                catch { throw CommandError(.io, "\(command): cannot create \(d.path): \(error.localizedDescription)") }
                return d
            }()
            folder = dir
            var target = dir.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: target.path), !fm.contentsEqual(atPath: target.path, andPath: source.path) {
                let data = (try? Data(contentsOf: source)) ?? Data()
                let hash = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
                let name = source.deletingPathExtension().lastPathComponent + "-" + hash
                target = dir.appendingPathComponent(source.pathExtension.isEmpty ? name : name + "." + source.pathExtension)
            }
            if !fm.fileExists(atPath: target.path) {
                do { try fm.copyItem(at: source, to: target) }
                catch { throw CommandError(.io, "\(command): cannot copy \(source.lastPathComponent) into the project: \(error.localizedDescription)") }
            }
            originals[target.path] = kit.assetPath(spec)   // as the kit itself names it (compared with its absolutized paths)
            return target.path
        }
        for role in kit.fonts.keys.sorted() {
            if let spec = kit.fonts[role], BrandKit.isFontFile(spec), let mine = try own(spec) { copy.fonts[role] = mine }
        }
        if let spec = kit.logo, let mine = try own(spec) { copy.logo = mine }
        for v in (kit.logos ?? [:]).keys.sorted() {
            if let spec = kit.logos?[v], let mine = try own(spec) { copy.logos?[v] = mine }
        }
        copy.originals = originals.isEmpty ? nil : originals
        return copy
    }

    static func merge(_ dict: [String: String], _ patch: JSONValue?, command: String, field: String) throws -> [String: String] {
        guard let patch else { return dict }
        guard let o = patch.objectValue else { throw CommandError.invalid("\(command): \(field) is an object {role: value}") }
        var out = dict
        for (k, v) in o {
            if v == .null { out[k] = nil; continue }
            guard let s = v.stringValue else { throw CommandError.invalid("\(command): \(field).\(k) must be a string") }
            if field == "colors" {
                let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                guard h.count == 6, UInt32(h, radix: 16) != nil else { throw CommandError.invalid("\(command): colors.\(k) must be #RRGGBB (got \(s))") }
                out[k] = "#" + h.uppercased()
            } else { out[k] = s }
        }
        return out
    }

    /// Fields shared by brandkit.create and brandkit.update.
    static func edit(_ kit: inout BrandKit, _ p: CommandParams, command: String) throws {
        if let n = p.string("name") { kit.name = n }
        kit.colors = try merge(kit.colors, p.json("colors"), command: command, field: "colors")
        kit.fonts = try merge(kit.fonts, p.json("fonts"), command: command, field: "fonts")
        if let n = p.string("notes") { kit.notes = n }
        if let w = p.bool("watermark") { kit.watermark = w }
        if let cs = p.json("captionStyle") {
            guard let o = cs.objectValue else { throw CommandError.invalid("\(command): captionStyle is an object") }
            var cur = kit.captionStyle ?? [:]
            for (k, v) in o { cur[k] = v == .null ? nil : v }
            kit.captionStyle = cur.isEmpty ? nil : cur
        }
        if let lp = p.json("logoPlacement") {
            guard case .object(var cur) = try JSONValue.from(kit.logoPlacement ?? LogoPlacement()), let o = lp.objectValue else {
                throw CommandError.invalid("\(command): logoPlacement is an object")
            }
            for (k, v) in o { cur[k] = v }
            let placement = try JSONDecoder().decode(LogoPlacement.self, from: JSONValue.object(cur).data())
            guard LogoPlacement.corners.contains(placement.corner) else { throw CommandError.invalid("\(command): corner is one of \(LogoPlacement.corners.joined(separator: ", "))") }
            guard placement.width > 0 else { throw CommandError.invalid("\(command): logo width must be > 0") }
            kit.logoPlacement = placement
        }
        if let ts = p.json("titles") {
            guard let o = ts.objectValue else { throw CommandError.invalid("\(command): titles is an object {preset: title}") }
            for (k, v) in o {
                if v == .null { kit.titles[k] = nil; continue }
                kit.titles[k] = try JSONDecoder().decode(Title.self, from: v.data())
            }
        }
    }

    static let editParams: [ParamSpec] = [
        .optional("name", .string, "Display name."),
        .optional("colors", .object, "Colour roles to set {role: #RRGGBB} (null removes): primary, accent, ink, paper, surface, success, highlight (caption keyword box, highlighted words), onHighlight (text on it)."),
        .optional("fonts", .object, "Font roles {display, text, textBold, mono: font name or file} (files: prefer brandkit.setFont, which copies them into the kit)."),
        .optional("captionStyle", .object, "Caption style fields to override (captions.setStyle names; colours may be roles), null removes one."),
        .optional("logoPlacement", .object, "{corner: topLeft|topRight|topCenter|bottomLeft|bottomRight, width (px at 1080), margin, opacity, animation, variant}."),
        .optional("titles", .object, "Title presets to add or replace {name: title fields as in project.state}, null removes one."),
        .optional("watermark", .boolean, "brandkit.apply also lays the logo over the whole video."),
        .optional("notes", .string, "How the brand moves and what to avoid."),
    ]
}

/// The brand logo as an overlay clip: imported (SVG rasterised at twice the drawn size, so it stays sharp),
/// sized and placed by `LogoPlacement` inside the safe area, faded in and out.
enum LogoOverlay {
    static func clip(kit: BrandKit, project: inout Project, _ ctx: inout CommandContext, start: MediaTime, end: MediaTime, placement: LogoPlacement,
                     variant: String?, path: String?, command: String) throws -> (clip: Clip, warnings: [JSONValue]) {
        guard let file = path.map(EngineConfig.expand) ?? kit.logoPath(variant) else { throw noLogo(kit, command: command) }
        let k = Double(project.settings.width) / SafeZones.referenceWidth
        let assetID = try Graphics.importVisual(file, into: &project, &ctx, svgWidth: max(Int((placement.width * 2 * k).rounded()), 64), command: command)
        guard let video = project.asset(assetID)?.video, video.width > 0, video.height > 0 else { throw CommandError(.io, "\(command): the logo has no picture") }
        let f = placement.frame(aspect: Double(video.width) / Double(video.height))
        var rest = Transform()
        rest.scale = f.width / Double(video.width)
        rest.opacity = min(max(placement.opacity ?? 1, 0), 1)
        var clip = Clip(id: project.makeID("c"), assetID: assetID, sourceIn: .zero, sourceOut: end - start, start: start)
        clip.placement = Placement(fit: .native, x: f.x / SafeZones.referenceWidth, y: f.y / SafeZones.referenceHeight)
        clip.transform = rest
        if let motion = LogoMotion(rawValue: placement.animation ?? "") {
            // The logo motions of the effects gallery (#16): spin, orbit, pulse, sting.
            clip.keyframes = motion.keyframes(rest: rest, duration: end - start)
        } else {
            let anim = AnimationPreset(rawValue: placement.animation ?? "fade") ?? .fade
            clip.keyframes = AnimationPreset.combined(in: anim, out: anim == .kenBurns || anim == .pop ? .fade : anim, rest: rest, duration: end - start,
                                                      inDuration: nil, outDuration: nil)
        }
        var warnings: [JSONValue] = []
        if f.width < placement.width - 0.5 { warnings.append(.string("logo shrunk to \(Int(f.width)) px wide to stay inside the safe area")) }
        return (clip, warnings)
    }

    /// The refusal of a logo from a kit that has none (a kit made with «Nuovo kit» before its logo is chosen, #99).
    static func noLogo(_ kit: BrandKit, command: String) -> CommandError {
        CommandError.conflict("\(command): kit \"\(kit.name)\" has no logo yet: add one with brandkit.setLogo (kit \(kit.id))")
    }

    /// Problems of a box (output pixels) against the logo safe area: inside the Instagram limits, out of the caption band.
    static func safeZoneProblems(_ b: [Double], width W: Double, height H: Double) -> [String] {
        let k = H / SafeZones.referenceHeight, kx = W / SafeZones.referenceWidth
        let (c0, c1) = (SafeZones.caption.0 * k, SafeZones.caption.1 * k)
        var out: [String] = []
        if b[1] < SafeZones.topLimit * k - 0.5 { out.append("above y \(Int(SafeZones.topLimit * k))") }
        if b[1] + b[3] > SafeZones.bottomLimit * k + 0.5 { out.append("below y \(Int(SafeZones.bottomLimit * k))") }
        if b[0] < -0.5 { out.append("off the left edge") }
        if b[0] + b[2] > W - SafeZones.rightMargin * kx + 0.5 { out.append("in the right \(Int(SafeZones.rightMargin)) px") }
        if b[1] < c1 && b[1] + b[3] > c0 { out.append("in the caption band") }
        return out
    }
}

// MARK: - Commands

enum BrandkitList: Command {
    static let id = "brandkit.list"
    static let summary = "List the brand kits: built-in arkad, wesites, cafe-atelier, plus the user's kits (folders in ~/Library/Application Support/Regista/brandkits). Each: colours by role, fonts (resolved or system fallback), logos (variants, found or not), logo placement, caption colours, title presets, motion notes, and whether it is built in or a user kit. Returns the kits and the project's active kit."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let kits = BrandKit.all().values.sorted { $0.id < $1.id }
        return ["kits": .array(kits.map(BrandKits.summary)), "active": ctx.project?.brand.map { .string($0.id) } ?? .null]
    }
}

enum BrandkitApply: Command {
    static let id = "brandkit.apply"
    static let summary = "Apply a brand kit to the project in one go: its title presets become available to title.add, colour/font roles (primary, ink, paper, accent, success, highlight; display, text, mono) resolve in title params, captions are recoloured (keyword box = the kit's highlight, its text = onHighlight; the caption style the user chose — preset, font, size — is kept), titles made from presets are rebuilt in the new kit, and logo overlays (logo.add) are swapped for the new kit's logo and placement. The project keeps its own copy of the kit, its font files and logos included (copied into the project's media folder): deleting or changing the kit later does not change the video. Missing font files fall back to system fonts (reported). Run it before adding titles, and again any time to switch kit. Returns what was restyled."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("kit", .string, "Kit id (arkad, wesites, cafe-atelier, or a user kit)."),
        .optional("path", .string, "A kit folder, kit.json or older kit JSON file instead."),
        .optional("captions", .boolean, "Restyle the caption tracks with the kit's caption style (default true)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let kit: BrandKit
        if let path = p.string("path") { kit = try BrandKit.load(path) }
        else if let name = p.string("kit") { kit = try BrandKits.find(name, command: id) }
        else { throw CommandError.invalid("\(id): pass kit or path") }
        let result = try BrandKits.apply(kit, to: &project, &ctx, captions: p.bool("captions") ?? true, command: id)
        ctx.project = project
        return .object(result)
    }
}

enum BrandkitCreate: Command {
    static let id = "brandkit.create"
    static let summary = "Create a brand kit for a client (e.g. a bakery, a studio): a copy of an existing kit (from) with a new id and name, or — without from — the default kit's colours, fonts and placement with no logo (a new brand never starts with another brand's logo), then the given colours, fonts, caption style, logo placement, title presets. Saved as a folder (kit.json + assets) in the user's brand kits. Add the logo with brandkit.setLogo and font files with brandkit.setFont. Returns the kit."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("name", .string, "Display name (\"Café Atelier\")."),
        .optional("id", .string, "Kit id (lowercase, digits, -; default from the name)."),
        .optional("from", .string, "Kit to copy whole, logos included. Without it, the new kit takes the arkad kit's colours, fonts and placement, with no logo."),
    ] + BrandKits.editParams.filter { $0.name != "name" }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let store = BrandKitStore()
        var kit = try BrandKits.find(p.string("from") ?? "arkad", command: id)
        if !p.has("from") {
            // A new brand: none of the default kit's logos (#99).
            kit.logo = nil
            kit.logos = nil
        }
        kit.id = p.string("id") ?? BrandKitStore.slug(p.requiredString("name"))
        guard BrandKitStore.validID(kit.id) else { throw CommandError.invalid("\(id): id \"\(kit.id)\": use lowercase letters, digits and -") }
        guard !FileManager.default.fileExists(atPath: store.folder(kit.id).path), !BrandKit.builtInIDs.contains(kit.id) else {
            throw CommandError.conflict("\(id): a kit \"\(kit.id)\" exists: use brandkit.update, or another id")
        }
        kit.notes = nil
        try BrandKits.edit(&kit, p, command: id)
        let (saved, change) = try KitChange.record(kit.id, in: store) { try store.save(kit) }
        ctx.kitChange = change
        return ["kit": BrandKits.summary(saved)]
    }
}

enum BrandkitUpdate: Command {
    static let id = "brandkit.update"
    static let summary = "Change a brand kit: name, colours by role (merged; null removes), fonts, caption style, logo placement (corner, width, margin, opacity, animation, variant), title presets, watermark, notes. Updating a built-in saves a user copy with the same id that replaces it. The project keeps its applied copy until brandkit.apply is run again. history.undo puts the kit back as it was. Returns the kit."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [.required("kit", .string, "Kit id.")] + BrandKits.editParams

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var kit = try BrandKits.find(p.requiredString("kit"), command: id)
        try BrandKits.edit(&kit, p, command: id)
        let store = BrandKitStore()
        let (saved, change) = try KitChange.record(kit.id, in: store) { try store.save(kit) }
        ctx.kitChange = change
        return ["kit": BrandKits.summary(saved)]
    }
}

enum BrandkitSetLogo: Command {
    static let id = "brandkit.setLogo"
    static let summary = "Give a brand kit its logo: an SVG (preferred: sharp at any size) or a PNG with transparency, copied into the kit folder as a variant — onDark (light-coloured logo for footage, the default), onLight (dark-coloured logo for pale backgrounds) or mark (symbol only). Returns the kit."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("kit", .string, "Kit id."),
        .required("path", .string, "The .svg or .png file."),
        .optional("variant", .oneOf(BrandKit.logoVariants), "onDark (default), onLight or mark."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let kit = try BrandKits.find(p.requiredString("kit"), command: id)
        let store = BrandKitStore()
        let (saved, change) = try KitChange.record(kit.id, in: store) {
            try store.setLogo(kit, file: URL(fileURLWithPath: EngineConfig.expand(p.requiredString("path"))), variant: p.string("variant") ?? "onDark")
        }
        ctx.kitChange = change
        return ["kit": BrandKits.summary(saved)]
    }
}

enum BrandkitSetFont: Command {
    static let id = "brandkit.setFont"
    static let summary = "Import a font file (.ttf, .otf, .woff2) into a brand kit folder and assign it to a role: display (titles), text, textBold, mono (labels). A kit whose font file goes missing falls back to a system font. Returns the kit with its fonts resolved."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("kit", .string, "Kit id."),
        .required("path", .string, "The font file."),
        .required("role", .string, "display, text, textBold or mono (or a new role)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let kit = try BrandKits.find(p.requiredString("kit"), command: id)
        let store = BrandKitStore()
        let (saved, change) = try KitChange.record(kit.id, in: store) {
            try store.setFont(kit, file: URL(fileURLWithPath: EngineConfig.expand(p.requiredString("path"))), role: p.requiredString("role"))
        }
        ctx.kitChange = change
        return ["kit": BrandKits.summary(saved)]
    }
}

enum BrandkitExport: Command {
    static let id = "brandkit.export"
    static let summary = "Export a brand kit as one .registakit file (a zip of kit.json + logos + fonts, self-contained) to send to a partner, who adds it with brandkit.import or the app's Importa button. Returns the file."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("kit", .string, "Kit id."),
        .required("path", .string, "Output file (.registakit added if missing) or folder."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let kit = try BrandKits.find(p.requiredString("kit"), command: id)
        var out = URL(fileURLWithPath: EngineConfig.expand(p.requiredString("path")))
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: out.path, isDirectory: &isDir), isDir.boolValue { out.appendPathComponent("\(kit.id).\(BrandKitStore.fileExtension)") }
        let file = try BrandKitStore().export(kit, to: out)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        return ["path": .string(file.path), "bytes": .number(Double(size ?? 0)), "kit": .string(kit.id)]
    }
}

enum BrandkitImport: Command {
    static let id = "brandkit.import"
    static let summary = "Add a brand kit from a .registakit file (from brandkit.export), a kit folder or a kit JSON. A kit with the id of an existing user kit gets a new id unless replace is true; a kit with a built-in's id replaces the built-in. Returns the kit."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("path", .string, "The .registakit file, kit folder or kit JSON."),
        .optional("replace", .boolean, "Replace a user kit with the same id (default false)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let store = BrandKitStore()
        // The kit's id is known only once the file is read: a new kit is one undo step (undo removes it); replacing a
        // user kit (replace: true) is not undoable.
        let existing = Set(store.userKits().map(\.id))
        let kit = try store.importKit(from: URL(fileURLWithPath: EngineConfig.expand(p.requiredString("path"))), replace: p.bool("replace") ?? false)
        if !existing.contains(kit.id) {
            ctx.kitChange = KitChange(kit: kit.id, folder: store.folder(kit.id), before: nil, after: try KitSnapshot.read(store.folder(kit.id)))
        }
        return ["kit": BrandKits.summary(kit)]
    }
}

enum BrandkitDelete: Command {
    static let id = "brandkit.delete"
    static let summary = "Delete a user brand kit folder (a built-in with the same id shows again). Built-ins cannot be deleted. Returns the id."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [.required("kit", .string, "Kit id.")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let kit = p.requiredString("kit")
        let store = BrandKitStore()
        let (_, change) = try KitChange.record(kit, in: store) { try store.delete(kit) }
        ctx.kitChange = change
        return ["deleted": .string(kit)]
    }
}

enum LogoAdd: Command {
    static let id = "logo.add"
    static let summary = "Put the brand logo over the video: the applied kit's logo (or kit / path), at the kit's placement — a corner inside the Instagram safe area, never in the caption band — sized in px at 1080 wide, faded in and out. By default it spans the whole timeline (a watermark) — unless the project's rules want the logo only at the end (logo-end, on in the default rules): then it goes in the closing seconds of the video (as many as the project's closing-logo choice says, 2 by default) and the result's timing says so; with the closing-logo choice off a call with no time is refused unless override: true (the person asked for the logo); pass start/duration for any other time (rules.check then judges it). clipId moves a logo already placed instead (the logo-end fix): to the closing seconds, or to start/end, keeping its look. brandkit.apply swaps it when the kit changes. Returns the clip, its box, warnings and fromChoices."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("start", .time, "Timeline start (default 0)."),
        .optional("duration", .time, "Seconds on screen (default: to the end of the timeline)."),
        .optional("end", .time, "Timeline end instead of duration."),
        .optional("kit", .string, "Kit whose logo to use (default: the applied kit)."),
        .optional("path", .string, "A logo file instead (.svg or .png)."),
        .optional("variant", .oneOf(BrandKit.logoVariants), "onDark (default), onLight or mark."),
        .optional("corner", .oneOf(LogoPlacement.corners), "Where (default: the kit's)."),
        .optional("width", .number, "Drawn width, px at 1080 wide (default: the kit's)."),
        .optional("margin", .number, "Distance from the edge of the safe area, px."),
        .optional("opacity", .number, "0…1 (default the kit's, else 1)."),
        .optional("animation", .oneOf(LogoPlacement.animations), "Entrance (exit fades) — fade, pop, slideUp, slideDown, none — or a logo motion: spin, orbit (slow drift), pulse (breathing), sting (pop-in hit, for a closing card). Default: the kit's, else fade."),
        .optional("trackId", .string, "Track (default: the Logo track, created if needed)."),
        .optional("replace", .boolean, "Remove the logo clips already on the timeline first (one undo step: move or resize the logo)."),
        .optional("clipId", .string, "Move this logo clip instead of adding one: to start/end when given, else to the closing seconds of the video. Keeps its corner, size and animation."),
        .optional("override", .boolean, "Add it with no time although the project's closing-logo choice is off: only when the person asked for the logo."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        var used = ChoicesUsed(ProjectChoices(project, book: ctx.services.rules))
        if let cid = p.string("clipId") { return try move(cid, p, &project, &ctx, &used) }
        let timed = p.has("start") || p.has("end") || p.has("duration")
        if !timed, p.bool("override") != true, used.value("closing-logo") == "off" {
            throw CommandError.conflict("\(id): the person's closing-logo choice is off (no logo at the end) — pass override: true only when the person asked for the logo, or start/duration for a logo elsewhere")
        }
        if p.bool("replace") == true {
            for t in project.tracks.indices where project.tracks[t].role == "logo" { project.tracks[t].clips.removeAll() }
        }
        let kit: BrandKit
        if let k = p.string("kit") { kit = try BrandKits.find(k, command: id).absolutized() }
        else if let b = project.brand { kit = b }
        else if p.has("path") { kit = BrandKit(id: "none", name: "—", colors: [:], fonts: [:], titles: [:]) }
        else { throw CommandError.conflict("\(id): apply a brand kit first (brandkit.apply), or pass kit or path") }
        var placement = kit.logoPlacement ?? LogoPlacement()
        if let v = p.string("corner") { placement.corner = v }
        if let v = p.number("width") { guard v > 0 else { throw CommandError.invalid("\(id): width must be > 0") }; placement.width = v }
        if let v = p.number("margin") { placement.margin = v }
        if let v = p.number("opacity") { placement.opacity = v }
        if let v = p.string("animation") { placement.animation = v }
        let rate = project.settings.frameRate
        var start = (p.time("start") ?? .zero).snapped(to: rate)
        var end: MediaTime
        var timing: String?
        if let e = p.time("end") { end = e.snapped(to: rate) }
        else if let d = p.time("duration") { end = (start + d).snapped(to: rate) }
        else if !p.has("start"), ctx.services.rules.logoOnlyAtEnd(project), let w = RuleCheck.closingWindow(project, seconds: closingSeconds(&used, p)) {
            // The project's rules want the logo only at the end (#74): the closing seconds of the video.
            (start, end) = w
            timing = closingLine(w)
        }
        else { end = project.duration > start ? project.duration : start + MediaTime(seconds: 3) }
        guard end > start else { throw CommandError.invalid("\(id): end must be after start") }
        let made = try LogoOverlay.clip(kit: kit, project: &project, &ctx, start: start, end: end, placement: placement, variant: p.string("variant"),
                                        path: p.string("path"), command: id)
        let t = try Graphics.track("logo", in: &project, start: start, end: end, preferred: p.string("trackId"))
        project.tracks[t].clips.append(made.clip)
        project.tracks[t].sortClips()
        ctx.project = project
        var result: [String: JSONValue] = ["clip": ProjectState.summary(of: made.clip), "trackId": .string(project.tracks[t].id),
                                           "warnings": .array(made.warnings)]
        if let box = Graphics.restBox(made.clip, track: project.tracks[t], project: project, renderer: ctx.services.renderer) {
            result["box"] = Graphics.boxJSON(box)
            let problems = LogoOverlay.safeZoneProblems(box, width: Double(project.settings.width), height: Double(project.settings.height))
            result["insideSafeZone"] = .bool(problems.isEmpty)
            result["warnings"] = .array(made.warnings + problems.map { .string("logo \($0)") })
        }
        if let timing { result["timing"] = .string(timing) }
        result["fromChoices"] = used.json
        return .object(result)
    }

    /// How long the closing logo stays: the project's closing-logo seconds (the person's own when they asked with
    /// override: true, without counting it as used).
    static func closingSeconds(_ used: inout ChoicesUsed, _ p: CommandParams) -> Double {
        (p.bool("override") == true ? used.choices.number("closing-logo") ?? [] : used.number("closing-logo")).first ?? RuleCheck.closingLogo.seconds
    }

    static func closingLine(_ w: (start: MediaTime, end: MediaTime)) -> String {
        "at the end of the video, as the project's rules want (logo-end): \(String(format: "%.2f", w.start.seconds))–\(String(format: "%.2f", w.end.seconds)) s"
    }

    /// clipId: the logo already placed, moved to start/end or to the closing seconds of the video, its look kept (its
    /// entrance stays at its start, its exit moves with its end). One undo step.
    static func move(_ clipID: String, _ p: CommandParams, _ project: inout Project, _ ctx: inout CommandContext,
                     _ used: inout ChoicesUsed) throws -> JSONValue {
        let (t, c) = try Timeline.locate(clip: clipID, in: project)
        var clip = project.tracks[t].clips[c]
        let rate = project.settings.frameRate
        var start: MediaTime, end: MediaTime
        var timing: String?
        if p.has("start") || p.has("end") || p.has("duration") {
            start = (p.time("start") ?? clip.start).snapped(to: rate)
            if let e = p.time("end") { end = e.snapped(to: rate) }
            else if let d = p.time("duration") { end = (start + d).snapped(to: rate) }
            else { end = start + clip.duration }
        } else {
            guard let w = RuleCheck.closingWindow(project, seconds: closingSeconds(&used, p)) else {
                throw CommandError.conflict("\(id): no video on the timeline to put the logo at the end of")
            }
            (start, end) = w
            timing = closingLine(w)
        }
        guard end > start else { throw CommandError.invalid("\(id): end must be after start") }
        clip.keyframes = retimed(clip.keyframes, from: clip.duration, to: end - start)
        clip.sourceOut = clip.sourceIn + (end - start)
        clip.start = start
        try Timeline.checkFree(project.tracks[t], start: start, end: end, except: clipID)
        project.tracks[t].clips[c] = clip
        project.tracks[t].sortClips()
        ctx.project = project
        var result: [String: JSONValue] = ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id), "fromChoices": used.json]
        if let timing { result["timing"] = .string(timing) }
        return .object(result)
    }

    /// Keyframes of a clip `old` long made `new` long: those of its first half (the entrance) keep their time, those of
    /// its second half (the exit) keep their distance from the end; none goes past the middle of the new length.
    static func retimed(_ keys: [Keyframe]?, from old: MediaTime, to new: MediaTime) -> [Keyframe]? {
        guard let keys else { return nil }
        let half = MediaTime(ticks: old.ticks / 2), newHalf = MediaTime(ticks: new.ticks / 2)
        return keys.map { k in
            var k = k
            k.time = k.time <= half ? min(k.time, newHalf) : min(max(k.time + new - old, newHalf), new)
            return k
        }.sorted { $0.time < $1.time }
    }
}

enum BrandkitCheck: Command {
    static let id = "brandkit.check"
    static let summary = "Check the applied brand kit on the edit: fonts (each role resolved or its system fallback), captions (style keyword box colour = the kit's highlight, and the rendered keyword box pixels on the first keyword's frame), logo overlays inside their safe zone (Instagram limits, out of the caption band), and titles, cards and labels whose text, box or highlight colour is none of the kit's colours (each named with its clip and time). Optionally writes the checked frame. Returns pass and the details."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("path", .string, "Write the frame checked (the first keyword's) to this .png."),
        .optional("tolerance", .number, "Max RGB distance between rendered and expected keyword box colour (default 12)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        guard let kit = project.brand else { throw CommandError.conflict("\(id): no brand kit applied (brandkit.apply)") }
        var problems: [JSONValue] = []
        let expected = kit.captionOverrides()["keywordBoxColor"]?.stringValue?.uppercased()
        var captions: JSONValue = .null
        let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project))
        if let c = job.captions {
            var o: [String: JSONValue] = ["keywordBoxColor": .string(c.style.keywordBoxColor.uppercased()), "keywordTextColor": .string(c.style.keywordTextColor.uppercased()),
                                          "kitHighlight": kit.colors["highlight"].map { .string($0.uppercased()) } ?? .null, "expected": expected.map { .string($0) } ?? .null]
            let styleMatch = expected == nil || c.style.keywordBoxColor.uppercased() == expected
            o["styleMatch"] = .bool(styleMatch)
            if !styleMatch { problems.append(.string("caption keyword box \(c.style.keywordBoxColor) ≠ kit \(expected ?? "-")")) }
            // The rendered box: the first keyword word, on the frame where it appears.
            let rate = project.settings.frameRate
            let frame = MediaTime.frameDuration(at: rate)
            var hit: (chunk: Int, word: Int, time: MediaTime)?
            outer: for (ci, ch) in c.chunks.enumerated() {
                for (wi, w) in ch.words.enumerated() where w.keyword {
                    let shown = c.style.reveal == "chunk" ? ch.words[0].start : w.start
                    let t = (shown + frame).snapped(to: rate)
                    if t < (wi + 1 < ch.words.count ? ch.words[wi + 1].start : ch.end), t < project.duration { hit = (ci, wi, t); break outer }
                }
            }
            if let hit, let renderer = ctx.services.renderer, let images = ctx.services.images {
                let out = try p.string("path").map { try Render.output($0, command: id) }
                    ?? Previews.directory().appendingPathComponent("brandkit-check-\(UUID().uuidString.prefix(8)).png")
                try renderer.renderFrames(job, at: [hit.time], to: [out])
                let boxes = try renderer.captionLayout(job)
                let b = boxes[hit.chunk][hit.word]
                let k = Double(job.width) / c.style.referenceWidth
                let px = Int((b[0] + c.style.boxPadX * k * 0.5).rounded()), py = Int((b[1] + c.style.boxPadY * k * 0.5).rounded())
                let rgba = try images.rgba(of: out, width: job.width, height: job.height)
                var sum = [0.0, 0.0, 0.0], n = 0.0
                for dy in -1...1 { for dx in -1...1 {
                    let x = min(max(px + dx, 0), job.width - 1), y = min(max(py + dy, 0), job.height - 1), i = (y * job.width + x) * 4
                    for ch in 0..<3 { sum[ch] += Double(rgba[i + ch]) }
                    n += 1
                } }
                let rendered = sum.map { $0 / n }
                let hex = String(format: "#%02X%02X%02X", Int(rendered[0].rounded()), Int(rendered[1].rounded()), Int(rendered[2].rounded()))
                let want = BrandKit.rgb(expected ?? c.style.keywordBoxColor)
                var squares = 0.0
                for (a, b) in zip(rendered, want) { squares += (a - b) * (a - b) }
                let dist = squares.squareRoot()
                let ok = dist <= (p.number("tolerance") ?? 12)
                o["rendered"] = .string(hex)
                o["distance"] = .number((dist * 10).rounded() / 10)
                o["pixelMatch"] = .bool(ok)
                o["word"] = .string(c.chunks[hit.chunk].words[hit.word].text)
                o["time"] = ProjectState.seconds(hit.time)
                o["frame"] = .string(out.path)
                if !ok { problems.append(.string("rendered keyword box \(hex) is \(Int(dist)) away from \(expected ?? c.style.keywordBoxColor)")) }
            } else {
                o["pixelMatch"] = .null
                o["note"] = .string(hit == nil ? "no keyword on screen in the captions" : "this host cannot render frames")
            }
            captions = .object(o)
        }
        var logos: [JSONValue] = []
        for t in project.tracks where t.role == "logo" {
            for clip in t.clips {
                guard let box = Graphics.restBox(clip, track: t, project: project, renderer: ctx.services.renderer) else { continue }
                let pr = LogoOverlay.safeZoneProblems(box, width: Double(project.settings.width), height: Double(project.settings.height))
                logos.append(["clipId": .string(clip.id), "box": Graphics.boxJSON(box), "insideSafeZone": .bool(pr.isEmpty), "problems": .array(pr.map { .string($0) })])
                problems += pr.map { .string("logo \(clip.id) \($0)") }
            }
        }
        // Titles, cards and labels in a colour outside the kit (#97).
        let off = kit.offKitTitles(in: project)
        for t in off {
            problems.append(.string("title \(t.clipID) «\(t.text)» at \(String(format: "%.2f", t.start.seconds)) s: \(t.colors.joined(separator: ", ")) not a colour of the kit"))
        }
        let titles: [JSONValue] = off.map { ["clipId": .string($0.clipID), "time": ProjectState.seconds($0.start), "text": .string($0.text),
                                              "colors": .array($0.colors.map { .string($0) })] }
        let fonts = kit.fontReport()
        return ["pass": .bool(problems.isEmpty), "kit": .string(kit.id), "captions": captions, "logos": .array(logos), "titlesOutside": .array(titles),
                "logosInside": .bool(logos.allSatisfy { $0["insideSafeZone"] == .bool(true) }), "logoCount": .number(Double(logos.count)),
                "fonts": BrandKits.fontsJSON(kit), "fontsResolved": .number(Double(fonts.filter { !$0.fallback }.count)),
                "fontFallbacks": .array(fonts.filter(\.fallback).map { .string("\($0.role): \($0.resolved)") }), "problems": .array(problems)]
    }
}

enum BrandkitPreview: Command {
    static let id = "brandkit.preview"
    static let summary = "Render a 9:16 preview of a brand kit through the real compositor: a caption with its keyword box, a hook title in the kit's display font, the logo at its placement, over a frame of the open project (or a backdrop in the kit's colours). Does not change the project. Returns the PNG, the fonts used and the caption's words drawn (sample, keyword)."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("kit", .string, "Kit id (default: the applied kit)."),
        .optional("definition", .object, "A whole kit as JSON (unsaved edits, absolute asset paths) instead of an id."),
        .optional("path", .string, "Output .png (default: a temporary file)."),
        .optional("width", .integer, "Width in px (default 540; height 16:9 of it)."),
        .optional("time", .time, "Project time for the backdrop frame (default: a third in)."),
        .optional("title", .string, "Title text (default: the kit's name)."),
        .optional("sample", .string, "The caption's words, the last one boxed as the keyword (default: IL TUO BRAND; the app passes its own, in the interface language)."),
        .optional("backdrop", .boolean, "Use a frame of the open project behind (default true)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let kit: BrandKit
        if let d = p.json("definition") {
            do { kit = try JSONDecoder().decode(BrandKit.self, from: d.data()) } catch { throw CommandError.invalid("\(id): definition is not a kit: \(error)") }
        } else if let k = p.string("kit") { kit = try BrandKits.find(k, command: id) }
        else if let b = ctx.project?.brand { kit = b }
        else { throw CommandError.invalid("\(id): pass kit") }
        let w = min(max(p.int("width") ?? 540, 120), 2160)
        let out = try p.string("path").map { try Render.output($0, command: id) }
            ?? Previews.directory().appendingPathComponent("brandkit-\(kit.id)-\(UUID().uuidString.prefix(8)).png")
        let r = try BrandKitPreview.render(kit, project: (p.bool("backdrop") ?? true) ? ctx.project : nil, services: ctx.services, prober: ctx.prober,
                                           width: w, time: p.time("time"), title: p.string("title"), sample: p.string("sample"), to: out)
        return ["path": .string(out.path), "width": .number(Double(r.width)), "height": .number(Double(r.height)), "kit": .string(kit.id),
                "fonts": BrandKits.fontsJSON(kit), "logo": r.logo.map { .string($0) } ?? .null,
                "sample": .array(r.sample.map { .string($0) }), "keyword": .string(r.sample.last ?? "")]
    }
}

/// The in-memory project brandkit.preview renders: backdrop, hook title, logo, a caption with a keyword.
public enum BrandKitPreview {
    static let time0 = MediaTime(seconds: 1)
    /// The caption's words when the caller passes none (an agent's call without `sample`).
    public static let defaultSample = "IL TUO BRAND"

    /// The caption's words: `sample` split on spaces, the default when it has none.
    public static func words(_ sample: String?) -> [String] {
        let w = (sample ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        return w.isEmpty ? words(defaultSample) : w
    }

    /// Renders the preview of `kit` to `out` (PNG, `width` × 16:9) with the compositor of `services`, over a frame
    /// of `project`'s picture when it has one (else a backdrop in the kit's colours). The app calls this off the
    /// engine queue; brandkit.preview calls it on the engine. `sample`: the caption's words (the last one is the keyword);
    /// the result's `sample` is the words drawn.
    public static func render(_ kit: BrandKit, project source: Project?, services: EngineServices, prober: MediaProber, width w: Int,
                              time: MediaTime? = nil, title: String? = nil, sample: String? = nil,
                              to out: URL) throws -> (width: Int, height: Int, logo: String?, sample: [String]) {
        guard let renderer = services.renderer else { throw CommandError(.io, "brandkit.preview: this host cannot render frames") }
        guard let images = services.images else { throw CommandError(.io, "brandkit.preview: this host cannot draw images") }
        let h = Int((Double(w) * 16 / 9).rounded())
        let cache = try Previews.directory().appendingPathComponent("brandkit-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let fm = FileManager.default

        // Backdrop: a frame of the project's picture (no captions or graphics), else the kit's colours.
        var backdrop: URL?
        var temporary: URL?
        if var project = source, project.tracks.contains(where: { $0.kind == .video && !$0.clips.isEmpty }) {
            project.tracks = project.tracks.filter { $0.kind == .video }
            project.transitions = nil
            let job = RenderJob(project: project, preset: ExportPreset(id: "preview", width: w, height: h), captions: false)
            let rate = project.settings.frameRate
            let t = min((time ?? MediaTime(seconds: project.duration.seconds / 3)).snapped(to: rate),
                        max(project.duration - MediaTime.frameDuration(at: rate), .zero))
            let f = cache.appendingPathComponent("backdrop-\(UUID().uuidString.prefix(8)).png")
            if (try? renderer.renderFrames(job, at: [t], to: [f])) != nil { backdrop = f; temporary = f }
        }
        defer { if let temporary { try? fm.removeItem(at: temporary) } }
        if backdrop == nil {
            let svg = cache.appendingPathComponent("backdrop-\(hash(backdropSVG(kit))).svg")
            let png = svg.deletingPathExtension().appendingPathExtension("\(w).png")
            if !fm.fileExists(atPath: png.path) {
                try backdropSVG(kit).write(to: svg, atomically: true, encoding: .utf8)
                _ = try images.rasterizeSVG(svg, width: w, to: png)
            }
            backdrop = png
        }
        var logo: (path: String, width: Int, height: Int)?
        if let lp = kit.logoPath(), fm.fileExists(atPath: lp) {
            let placement = kit.logoPlacement ?? LogoPlacement()
            if lp.lowercased().hasSuffix(".svg") {
                let stamp = (try? fm.attributesOfItem(atPath: lp)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let png = cache.appendingPathComponent("logo-\(hash("\(lp)|\(stamp)|\(Int(placement.width))")).png")
                let s = try images.rasterizeSVG(URL(fileURLWithPath: lp), width: max(Int(placement.width * 2), 64), to: png)
                logo = (png.path, s.width, s.height)
            } else if let v = try? prober.probe(URL(fileURLWithPath: lp)).video {
                logo = (lp, v.width, v.height)
            }
        }
        // The compositor needs one streamed video under the stills: a 2 s black clip made once with ffmpeg.
        let blank = cache.appendingPathComponent("blank-2s.mp4")
        if !fm.fileExists(atPath: blank.path) {
            try Subprocess.check(services.config.url(services.config.ffmpeg),
                                 FFmpegAudio.quiet + ["-f", "lavfi", "-i", "color=c=black:s=108x192:r=30:d=2", "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p", blank.path])
        }
        let words = Self.words(sample)
        let project = Self.project(kit, blank: blank.path, backdrop: (backdrop!.path, w, h), logo: logo, title: title ?? kit.name, sample: words)
        let job = RenderJob(project: project, preset: ExportPreset(id: "preview", width: w, height: h))
        try renderer.renderFrames(job, at: [time0], to: [out])
        return (w, h, logo?.path, words)
    }

    /// FNV-1a, hex (stable cache names).
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    static func project(_ kit: BrandKit, blank: String, backdrop: (path: String, width: Int, height: Int), logo: (path: String, width: Int, height: Int)?, title text: String,
                        sample: [String] = words(nil)) -> Project {
        var project = Project(name: "preview-\(kit.id)")
        project.assets.append(MediaAsset(id: "a0", name: "blank", path: blank, duration: MediaTime(seconds: 2),
                                         video: VideoInfo(width: 108, height: 192, frameRate: Rational(30), codec: "h264", alpha: false), audio: nil))
        var v0 = Track(id: "t0", kind: .video, name: "V0")
        v0.clips = [Clip(id: "c0", assetID: "a0", sourceIn: .zero, sourceOut: MediaTime(seconds: 2), start: .zero)]
        project.tracks.append(v0)
        let still = ImageSource(kind: .still, path: backdrop.path)
        project.assets.append(MediaAsset(id: "a1", name: "backdrop", path: backdrop.path, duration: ImageSource.stillDuration,
                                         video: VideoInfo(width: backdrop.width, height: backdrop.height, frameRate: Rational(30), codec: "png", alpha: false), audio: nil, image: still))
        var v = Track(id: "t1", kind: .video, name: "V1")
        v.clips = [Clip(id: "c1", assetID: "a1", sourceIn: .zero, sourceOut: MediaTime(seconds: 2), start: .zero)]
        project.tracks.append(v)
        if let logo {
            project.assets.append(MediaAsset(id: "a2", name: "logo", path: logo.path, duration: ImageSource.stillDuration,
                                             video: VideoInfo(width: logo.width, height: logo.height, frameRate: Rational(30), codec: "png", alpha: true),
                                             audio: nil, image: ImageSource(kind: .still, path: logo.path)))
            let f = (kit.logoPlacement ?? LogoPlacement()).frame(aspect: Double(logo.width) / Double(max(logo.height, 1)))
            var c = Clip(id: "c2", assetID: "a2", sourceIn: .zero, sourceOut: MediaTime(seconds: 2), start: .zero)
            c.placement = Placement(fit: .native, x: f.x / SafeZones.referenceWidth, y: f.y / SafeZones.referenceHeight)
            var tr = Transform()
            tr.scale = f.width / Double(logo.width)
            tr.opacity = kit.logoPlacement?.opacity ?? 1
            c.transform = tr
            var lt = Track(id: "t2", kind: .overlay, name: "Logo")
            lt.role = "logo"
            lt.clips = [c]
            project.tracks.append(lt)
        }
        if var t = kit.titles["hook"] {
            t.text = text
            t.maxWidth = t.maxWidth ?? 860
            var c = Clip(id: "c3", assetID: "", sourceIn: .zero, sourceOut: MediaTime(seconds: 2), start: .zero)
            c.title = kit.resolve(t)
            // Under a top logo, in the top band.
            c.placement = Placement(fit: .native, x: 0.5, y: (SafeZones.top.0 + SafeZones.top.1) / 2 / SafeZones.referenceHeight + 0.03)
            var tt = Track(id: "t3", kind: .overlay, name: "Titles")
            tt.role = "titles"
            tt.clips = [c]
            project.tracks.append(tt)
        }
        let style = (try? kit.captionStyle(over: .talkingHeadV1)) ?? .talkingHeadV1
        let keyword = sample.count - 1
        let words = sample.enumerated().map { i, w in
            CaptionWord(text: w, start: MediaTime(seconds: 0.1 * Double(i)), end: MediaTime(seconds: 0.1 * Double(i + 1)), keyword: i == keyword)
        }
        var ct = Track(id: "t4", kind: .caption, name: "Sottotitoli")
        ct.captions = Captions(style: style, keywords: [sample[keyword]], fixes: [:], sourceTrack: "t1", sourceSignature: "",
                               chunks: [CaptionChunk(words: words, end: MediaTime(seconds: 2))])
        project.tracks.append(ct)
        return project
    }

    /// A stand-in for footage: a mid-tone vertical gradient (titles and captions are made to read on video, not on
    /// flat ink) with a soft glow of the kit's primary colour.
    public static func backdropSVG(_ kit: BrandKit) -> String {
        let primary = kit.colors["primary"] ?? "#808080", accent = kit.colors["accent"] ?? primary
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1080 1920">
          <defs>
            <linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="#77716B"/><stop offset="0.55" stop-color="#4A4541"/><stop offset="1" stop-color="#211E1C"/>
            </linearGradient>
            <radialGradient id="r" gradientUnits="userSpaceOnUse" cx="560" cy="980" r="760">
              <stop offset="0" stop-color="\(primary)" stop-opacity="0.55"/><stop offset="0.6" stop-color="\(accent)" stop-opacity="0.18"/>
              <stop offset="1" stop-color="\(accent)" stop-opacity="0"/>
            </radialGradient>
          </defs>
          <rect width="1080" height="1920" fill="url(#g)"/>
          <rect width="1080" height="1920" fill="url(#r)"/>
        </svg>
        """
    }
}
