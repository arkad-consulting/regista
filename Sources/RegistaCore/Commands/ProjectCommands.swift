import Foundation

/// Reads and writes `<name>.regista/project.json`.
public enum ProjectStore {
    public static let fileExtension = "regista"
    public static let fileName = "project.json"

    /// Accepts the `.regista` folder or the project.json inside it.
    public static func folder(for path: String) -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        return url.lastPathComponent == fileName ? url.deletingLastPathComponent() : url
    }

    public static func load(from folder: URL) throws -> Project {
        let file = folder.appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw CommandError(.io, "No project at \(folder.path) (missing \(fileName))")
        }
        let project: Project
        do { project = try JSONDecoder().decode(Project.self, from: data) }
        catch { throw CommandError(.io, "Unreadable \(file.path): \(error)") }
        guard project.schema <= Project.currentSchema else {
            throw CommandError(.io, "\(file.path) has schema \(project.schema), this Regista reads up to \(Project.currentSchema)")
        }
        return project
    }

    public static func save(_ project: Project, to folder: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try e.encode(project).write(to: folder.appendingPathComponent(fileName), options: .atomic)
        } catch {
            throw CommandError(.io, "Cannot save to \(folder.path): \(error.localizedDescription)")
        }
    }
}

enum ProjectNew: Command {
    static let id = "project.new"
    static let summary = "Start a new edit: creates an empty project (1080×1920 30 fps by default). In the Regista app it goes in the active tab when that tab is empty, otherwise in a new tab, which becomes the active tab (the other open projects stay open); headless it replaces the open project. Pass directory so project.save writes <directory>/<name>.regista (use media.list's projectsDirectory). Returns the project summary (as project.state)."
    static let kind = CommandKind.session
    static let params: [ParamSpec] = [
        .required("name", .string, "Project name, also the folder name."),
        .optional("directory", .string, "Parent folder for <name>.regista. Omit to keep the project in memory until project.save gets a path."),
        .optional("width", .integer, "Output width in pixels (default 1080)."),
        .optional("height", .integer, "Output height in pixels (default 1920, vertical 9:16)."),
        .optional("fps", .number, "Timeline frame rate (default 30; 29.97 and 23.976 are understood)."),
        .optional("kind", .string, "Kind of video, which selects the editing rules: the recipe's name (talking-head-reel, screen-tutorial, voice-over-video, reel-graphics) or a kind of the user's (rules.list). Default: from the format (project.setKind changes it)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let name = p.requiredString("name").trimmingCharacters(in: .whitespaces)
        if let kind = p.string("kind"), !ctx.services.rules.kinds.contains(kind) {
            throw CommandError.notFound("project.new: no kind '\(kind)' (kinds: \(ctx.services.rules.kinds.joined(separator: ", ")))")
        }
        guard !name.isEmpty, !name.contains("/") else { throw CommandError.invalid("project.new: invalid name '\(name)'") }
        var settings = ProjectSettings()
        if let w = p.int("width") { settings.width = w }
        if let h = p.int("height") { settings.height = h }
        guard settings.width > 0, settings.height > 0 else { throw CommandError.invalid("project.new: width and height must be > 0") }
        if let fps = p.number("fps") { settings.frameRate = try frameRate(fps) }

        var url: URL?
        if let dir = p.string("directory") {
            let folder = ProjectStore.folder(for: dir).appendingPathComponent("\(name).\(ProjectStore.fileExtension)")
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(ProjectStore.fileName).path) {
                throw CommandError.conflict("project.new: \(folder.path) already exists — use project.open")
            }
            url = folder
        }
        ctx.project = Project(name: name, settings: settings)
        ctx.project?.kind = p.string("kind")
        ctx.projectURL = url
        ctx.history.reset()
        ctx.dirty = true
        return ProjectState.summary(ctx)
    }

    /// Exact rational for the usual NTSC rates.
    static func frameRate(_ fps: Double) throws -> Rational {
        guard fps > 0, fps <= 240 else { throw CommandError.invalid("project.new: fps must be in (0, 240], got \(fps)") }
        for (approx, exact) in [(23.976, Rational(24000, 1001)), (29.97, Rational(30000, 1001)), (59.94, Rational(60000, 1001))]
        where abs(fps - approx) < 0.01 {
            return exact
        }
        if fps.rounded() == fps { return Rational(Int64(fps)) }
        return Rational(Int64((fps * 1000).rounded()), 1000)
    }
}

enum ProjectFormat: Command {
    static let id = "project.format"
    static let summary = "Change the output format of the open project (9:16, 4:5, 1:1, 16:9, or any width × height): full-frame clips reframe by crop around their centre; screen recordings lay their face layouts out again for the new frame (a side-by-side becomes the vertical stack in a portrait frame and back), with their automatic zoom and key badges recomputed. One undo step. Returns the new size and the layouts applied."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("preset", .oneOf(ExportPreset.all.map(\.id)), "9:16 (1080×1920), 4:5 (1080×1350), 1:1 (1080×1080) or 16:9 (1920×1080)."),
        .optional("width", .integer, "Output width in pixels (instead of preset; with height)."),
        .optional("height", .integer, "Output height in pixels (instead of preset; with width)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let size: (Int, Int)
        if let id = p.string("preset"), let preset = ExportPreset.all.first(where: { $0.id == id }) {
            size = (preset.width, preset.height)
        } else if let w = p.int("width"), let h = p.int("height") {
            guard w >= 16, h >= 16, w <= 8192, h <= 8192 else { throw CommandError.invalid("\(id): width and height must be 16…8192") }
            size = (w / 2 * 2, h / 2 * 2)
        } else {
            throw CommandError.invalid("\(id): pass preset, or width and height")
        }
        project.settings.width = size.0
        project.settings.height = size.1
        let portrait = size.1 > size.0, landscape = size.0 > size.1
        var applied: [JSONValue] = []
        for index in (project.recordings ?? []).indices {
            let link = project.recordings![index]
            guard link.screen != nil else { continue }
            for (k, l) in (link.layouts ?? []).enumerated() {
                var spec = l.layout
                // Side by side needs width, the vertical stack needs height.
                if portrait, spec.kind == .split { spec = LayoutSpec(kind: .stack, side: spec.side == "left" ? "top" : nil) }
                if landscape, spec.kind == .stack { spec = LayoutSpec(kind: .split, side: spec.side == "top" ? "left" : nil) }
                try Recording.apply(spec, link: index, from: l.from, to: l.to, transition: k == 0 ? 0 : 0.3, &project)
                applied.append(["recordingId": .string(link.id), "from": ProjectState.seconds(l.from), "to": ProjectState.seconds(l.to),
                                "layout": .string(spec.label)])
            }
            ctx.project = project
            try Recording.refreshDerived(link: index, &ctx)
            project = ctx.project!
        }
        ctx.project = project
        return ["width": .number(Double(size.0)), "height": .number(Double(size.1)), "layouts": .array(applied)]
    }
}

enum ProjectOpen: Command {
    static let id = "project.open"
    static let summary = "Reopen a saved project folder (<name>.regista) to continue an edit. In the Regista app it opens in a new tab (or in the active tab when that is empty) and becomes the active tab; a project already open in a tab is not reloaded: its tab is selected. Headless it replaces the open project and clears undo. Returns the project summary (as project.state)."
    static let kind = CommandKind.session
    static let params: [ParamSpec] = [
        .required("path", .string, "Path of the .regista folder (or its project.json)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let folder = ProjectStore.folder(for: p.requiredString("path"))
        ctx.project = try ProjectStore.load(from: folder)
        ctx.projectURL = folder
        ctx.history.reset()
        ctx.dirty = false
        return ProjectState.summary(ctx)
    }
}

enum ProjectSave: Command {
    static let id = "project.save"
    static let summary = "Write the project to its .regista folder (do it at the end, and before long experiments). Pass path to save somewhere else (save as). Returns the saved path."
    static let kind = CommandKind.session
    static let params: [ParamSpec] = [
        .optional("path", .string, "Target .regista folder; defaults to where the project was created or opened."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        guard let folder = p.string("path").map(ProjectStore.folder(for:)) ?? ctx.projectURL else {
            throw CommandError.invalid("project.save: the project has no folder yet — pass path")
        }
        try ProjectStore.save(project, to: folder)
        ctx.projectURL = folder
        ctx.dirty = false
        return ["path": .string(folder.path), "file": .string(folder.appendingPathComponent(ProjectStore.fileName).path)]
    }
}

enum ProjectClose: Command {
    static let id = "project.close"
    static let summary = "Close the project (in the Regista app: the active tab's, or the tab named by project; the tab goes away) and clear undo. Refuses while there are unsaved changes unless discard is true: project.save first. Returns {closed}."
    static let kind = CommandKind.session
    static let params: [ParamSpec] = [
        .optional("discard", .boolean, "Close even with unsaved changes, losing them (default false)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        guard let project = ctx.project else { return ["closed": .null] }
        if ctx.dirty, p.bool("discard") != true {
            throw CommandError.conflict("project.close: '\(project.name)' has unsaved changes — project.save first, or pass discard: true")
        }
        ctx.project = nil
        ctx.projectURL = nil
        ctx.history.reset()
        ctx.dirty = false
        return ["closed": .string(project.name)]
    }
}

enum ProjectState: Command {
    static let id = "project.state"
    static let summary = "See the timeline: settings, assets (ids, duration, size, analysis done), tracks with their clips (ids, timeline and source times in seconds, crops, links) and the undo history. Call it whenever you need clip or track ids. Returns a compact JSON summary."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        _ = try ctx.requireProject()
        return summary(ctx)
    }

    static func summary(_ ctx: CommandContext) -> JSONValue {
        guard let project = ctx.project else { return ["open": false] }
        let s = project.settings
        return [
            "open": true,
            "name": .string(project.name),
            "path": ctx.projectURL.map { .string($0.path) } ?? .null,
            "dirty": .bool(ctx.dirty),
            "settings": ["width": .number(Double(s.width)), "height": .number(Double(s.height)),
                         "fps": .number(s.frameRate.doubleValue), "frameRate": .string(s.frameRate.description),
                         "background": s.background.map { .string($0) } ?? .null, "backdrop": s.backdrop.map { .string($0.label) } ?? .null],
            "duration": seconds(project.duration),
            "assets": .array(project.assets.map(summary(of:))),
            "tracks": .array(project.tracks.map(summary(of:))),
            "script": project.script.map { ["lines": .number(Double($0.lines.count))] } ?? .null,
            "takes": project.takes.map { t in
                ["assetId": .string(t.assetID), "lines": .number(Double(t.lines.count)),
                 "chosen": .array(t.lines.map { l in l.chosen.map { .number(Double($0 + 1)) } ?? .null })]
            } ?? .null,
            "transitions": .array((project.transitions ?? []).map { t in
                ["id": .string(t.id), "kind": .string(t.kind.rawValue), "at": seconds(t.time(in: project)), "duration": seconds(t.duration)]
            }),
            "brand": project.brand.map { .string($0.id) } ?? .null,
            "kind": .string(ctx.services.rules.kind(of: project).kind), "kindSet": .bool(project.kind != nil),
            "grade": project.grade.map(EffectsJSON.grade) ?? .null,
            "recordings": .array((project.recordings ?? []).map { r in
                ["id": .string(r.id), "session": .string(r.session), "screen": r.screen.map { .string($0) } ?? .null,
                 "camera": r.camera.map { .string($0) } ?? .null, "mic": r.mic.map { .string($0) } ?? .null,
                 "cursorInVideo": .bool(r.cursorInVideo ?? true), "cursor": CursorStyleCommand.json(r.cursor ?? CursorStyle()),
                 "layouts": .array((r.layouts ?? []).map { l in
                     ["from": seconds(l.from), "to": seconds(l.to), "layout": .string(l.layout.label)] })]
            }),
            "markers": .array(project.markers.map { m in
                ["id": .string(m.id), "name": .string(m.name), "time": seconds(m.time), "duration": seconds(m.duration)]
            }),
            "history": [
                "undo": .number(Double(ctx.history.undoStack.count)),
                "redo": .number(Double(ctx.history.redoStack.count)),
                "nextUndo": ctx.history.undoStack.last.map { .string($0.command) } ?? .null,
                "nextRedo": ctx.history.redoStack.last.map { .string($0.command) } ?? .null,
            ],
        ]
    }

    static func summary(of a: MediaAsset) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(a.id), "name": .string(a.name), "path": .string(a.path), "duration": seconds(a.duration),
        ]
        if let v = a.video {
            o["video"] = ["width": .number(Double(v.width)), "height": .number(Double(v.height)),
                          "fps": .number(v.frameRate.doubleValue), "codec": .string(v.codec)]
        }
        if let au = a.audio {
            o["audio"] = ["sampleRate": .number(Double(au.sampleRate)), "channels": .number(Double(au.channels)),
                          "codec": .string(au.codec)]
        }
        if let origin = a.origin { o["origin"] = ["assetId": .string(origin.assetID), "process": .string(origin.process)] }
        if let im = a.image { o["image"] = ["kind": .string(im.kind.rawValue), "path": .string(im.path), "frames": .number(Double(im.count))] }
        if a.video?.alpha == true { o["alpha"] = true }
        if let an = a.analysis {
            var x: [String: JSONValue] = [:]
            if let audio = an.audio { x["audio"] = ["speech": .string(audio.speech), "working": .string(audio.working)] }
            if let t = an.transcript { x["transcript"] = ["engine": .string(t.engine), "words": .number(Double(t.words.count))] }
            if let f = an.faces {
                x["faces"] = ["sidecar": .string(f.path), "frames": .number(Double(f.frames)), "detected": .number(Double(f.detected)),
                              "jitterPx": .number(f.jitterPx)]
            }
            if let m = an.matte { x["matte"] = ["directory": .string(m.directory), "frames": .number(Double(m.frameCount))] }
            o["analysis"] = .object(x)
        }
        if let g = a.generated {
            o["generated"] = ["provider": .string(g.provider), "model": .string(g.model), "kind": .string(g.kind.rawValue),
                              "prompt": .string(g.prompt), "cost": .number(g.cost), "unit": .string(g.unit), "created": .string(g.created)]
        }
        return .object(o)
    }

    static func summary(of t: Track) -> JSONValue {
        [
            "id": .string(t.id), "kind": .string(t.kind.rawValue), "name": .string(t.name),
            "locked": .bool(t.locked), "muted": .bool(t.muted), "hidden": .bool(t.hidden),
            "clips": .array(t.clips.map(summary(of:))),
            "captions": t.captions.map { c in ["style": .string(c.style.id), "chunks": .number(Double(c.chunks.count)), "place": Placing.placeJSON(c.place),
                                              "placedChunks": .number(Double(c.chunks.filter { $0.place != nil }.count))] } ?? .null,
            "role": t.role.map { .string($0) } ?? .null,
            "ducking": t.ducking.map { ["sourceTrack": .string($0.sourceTrack), "depth": .number($0.depth), "attack": .number($0.attack),
                                        "release": .number($0.release)] } ?? .null,
        ]
    }

    static func summary(of c: Clip) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(c.id), "asset": .string(c.assetID),
            "start": seconds(c.start), "end": seconds(c.end), "duration": seconds(c.duration),
            "sourceIn": seconds(c.sourceIn), "sourceOut": seconds(c.sourceOut),
        ]
        if let l = c.link { o["link"] = .string(l) }
        if let f = c.fadeIn { o["fadeIn"] = seconds(f) }
        if let f = c.fadeOut { o["fadeOut"] = seconds(f) }
        if let f = c.pictureFadeIn { o["pictureFadeIn"] = seconds(f) }
        if let f = c.pictureFadeOut { o["pictureFadeOut"] = seconds(f) }
        if let tr = c.transform { o["transform"] = summary(of: tr) }
        if let k = c.keyframes { o["keyframes"] = .number(Double(k.count)) }
        if let col = c.color {
            o["color"] = ["brightness": .number(col.brightness), "contrast": .number(col.contrast), "saturation": .number(col.saturation)]
        }
        if let t = c.title { o["title"] = ["text": .string(t.text), "font": .string(t.font), "size": .number(t.size), "color": .string(t.color)] }
        if let pl = c.placement {
            var po: [String: JSONValue] = ["fit": .string(pl.fit.rawValue), "x": .number(pl.x), "y": .number(pl.y)]
            if let w = pl.width, let h = pl.height { po["width"] = .number((w * 10000).rounded() / 10000); po["height"] = .number((h * 10000).rounded() / 10000) }
            o["placement"] = .object(po)
        }
        if let m = c.mask {
            var mo: [String: JSONValue] = ["shape": .string(m.shape.rawValue)]
            if let r = m.radius { mo["radius"] = .number(r) }
            if m.cutout == true { mo["cutout"] = true }
            if let b = m.borderWidth, b > 0 { mo["border"] = .number(b) }
            if let s = m.shadow, s > 0 { mo["shadow"] = .number(s) }
            o["mask"] = .object(mo)
        }
        if let b = c.blend { o["blend"] = .string(b.rawValue) }
        if let e = c.effects, !e.isEmpty {
            o["effects"] = .array(e.map { ["id": .string($0.id), "kind": .string($0.kind.rawValue), "amount": .number($0.amount)] })
        }
        if let g = c.gain { o["gain"] = .number((g * 100).rounded() / 100) }
        if c.behindSubject == true { o["behindSubject"] = true }
        if let sp = c.speed { o["speed"] = EffectsJSON.speed(sp) }
        if let g = c.grade { o["grade"] = EffectsJSON.grade(g) }
        if let st = c.sticker { o["sticker"] = ["kind": .string(st.kind.rawValue), "value": .string(st.value), "size": .number(st.size)] }
        if let sh = c.shape { o["shape"] = ["kind": .string(sh.kind.rawValue), "rect": .array(sh.rect.map { .number(($0 * 10000).rounded() / 10000) }),
                                            "color": .string(sh.color)] }
        if let m = c.motion { o["motion"] = ["template": .string(m.template), "layering": .string(m.layering.rawValue)] }
        if let sw = c.behindSwitches { o["behindSwitches"] = .array(sw.map { ["time": seconds($0.time), "behind": .bool($0.behind)] }) }
        return .object(o)
    }

    static func summary(of t: Transform) -> JSONValue {
        func r(_ x: Double) -> JSONValue { .number((x * 1_000_000).rounded() / 1_000_000) }
        var o: [String: JSONValue] = ["crop": .array([t.cropLeft, t.cropTop, t.cropRight, t.cropBottom].map(r)), "scale": r(t.scale),
                                      "x": r(t.x), "y": r(t.y), "rotation": r(t.rotation), "opacity": r(t.opacity)]
        if t.isSpatial || t.perspective != Transform.defaultPerspective {
            o["anchorX"] = r(t.anchorX); o["anchorY"] = r(t.anchorY); o["rotationX"] = r(t.rotationX); o["rotationY"] = r(t.rotationY)
            o["perspective"] = r(t.perspective)
        }
        return .object(o)
    }

    static func seconds(_ t: MediaTime) -> JSONValue { .number(t.displaySeconds) }
}

// MARK: - Tabs (S2 #76)

/// The app's open projects, one tab each (`EngineServices.tabs`): what project.list answers in the app.
public protocol ProjectTabs: AnyObject {
    /// {tabs: [{id, name, path, dirty, active, recording}], active}.
    func list() -> JSONValue
}

/// The optional `project` parameter every project-scoped command accepts at the routing layer (the app's tabs, the
/// headless engine): a tab id from project.list or the project's path. It is taken out of the params before the
/// command itself runs, so no command declares it.
public enum ProjectTarget {
    public static let param = "project"
    /// The headless engine's one project.
    public static let headlessTabID = "tab-1"
    public static let description = "Which open project to act on: a tab id from project_list (\"tab-2\") or the project's .regista path. Default: the active tab (the one the user sees). A command on another tab runs there without switching the user's view."

    /// Every command but those that create, open or list tabs.
    public static func accepts(_ commandID: String) -> Bool {
        !["project.new", "project.open", "project.list"].contains(commandID)
    }

    /// The target (nil when absent or null) and the params without it.
    public static func split(_ params: JSONValue) throws -> (target: String?, rest: JSONValue) {
        guard case .object(var o) = params, let v = o.removeValue(forKey: param) else { return (nil, params) }
        switch v {
        case .null: return (nil, .object(o))
        case .string(let s) where !s.trimmingCharacters(in: .whitespaces).isEmpty: return (s, .object(o))
        default: throw CommandError.invalid("parameter 'project': expected a tab id from project.list or a .regista path, got \(v.typeName)")
        }
    }

    /// Whether `target` names the tab `tabID` or the project saved at `path`.
    public static func matches(_ target: String, tabID: String, path: URL?) -> Bool {
        let t = target.trimmingCharacters(in: .whitespaces)
        if t == tabID { return true }
        guard let path, t.contains("/") || t.hasSuffix(".\(ProjectStore.fileExtension)") || t.hasPrefix("~") else { return false }
        return ProjectStore.folder(for: t).path == path.standardizedFileURL.path
    }

    /// The MCP input schema of a command that accepts `project`.
    public static func adding(to schema: JSONValue) -> JSONValue {
        guard case .object(var s) = schema, case .object(var props)? = s["properties"] else { return schema }
        props[param] = ["type": "string", "description": .string(description)]
        s["properties"] = .object(props)
        return .object(s)
    }
}

enum ProjectList: Command {
    static let id = "project.list"
    static let summary = "The open projects. The Regista app holds several, one tab each, and commands act on the active tab (the one the user sees) unless they pass project (a tab id from here or the project path). Returns {tabs: [{id, name, path, dirty, active, recording}], active}. The headless engine lists its one project as tab-1."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        if let tabs = ctx.services.tabs { return tabs.list() }
        guard let project = ctx.project else { return ["tabs": [], "active": .null] }
        let tab: JSONValue = ["id": .string(ProjectTarget.headlessTabID), "name": .string(project.name),
                              "path": ctx.projectURL.map { .string($0.path) } ?? .null, "dirty": .bool(ctx.dirty),
                              "active": true, "recording": false]
        return ["tabs": [tab], "active": .string(ProjectTarget.headlessTabID)]
    }
}
