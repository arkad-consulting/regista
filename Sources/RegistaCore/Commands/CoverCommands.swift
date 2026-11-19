import Foundation

// #42: the cover of a reel. One still per project — the timeline's frame at a chosen time, without captions, and an
// optional title drawn by the title engine with the brand kit's preset — checked against the band that survives the
// two crops a vertical video's cover goes through: the centred 3:4 of the Instagram profile grid and the centred 2:3 of
// the YouTube Shorts shelf. Regista owns the format, the crops and the check; which words and which style are the
// person's (and their kit's).

/// The project's cover (`Project.cover`), set with cover.set and rendered with cover.make.
public struct Cover: Codable, Hashable, Sendable {
    /// Where the title sits on the frame.
    public enum Place: String, Codable, CaseIterable, Sendable {
        case top, center, bottom

        /// Centre of the title, pixels of a 1080×1920 frame: top in the title band (y 110–640, title.add's default),
        /// bottom as far from the bottom edge, center in the middle.
        public var centreY: Double {
            switch self {
            case .top: (SafeZones.top.0 + SafeZones.top.1) / 2
            case .center: SafeZones.referenceHeight / 2
            case .bottom: SafeZones.referenceHeight - (SafeZones.top.0 + SafeZones.top.1) / 2
            }
        }
    }

    /// The timeline time of the frame (snapped to the frame grid).
    public var time: MediaTime
    /// The title's words (nil: no title, the frame alone).
    public var title: String?
    /// The brand kit's title preset (nil: the kit's "hook", or Regista's plain title without a kit).
    public var preset: String?
    public var place: Place

    public init(time: MediaTime = .zero, title: String? = nil, preset: String? = nil, place: Place = .center) {
        self.time = time
        self.title = title
        self.preset = preset
        self.place = place
    }

    public var json: JSONValue {
        ["time": ProjectState.seconds(time), "title": title.map { .string($0) } ?? .null, "preset": preset.map { .string($0) } ?? .null,
         "place": .string(place.rawValue)]
    }

    /// Covers are made for vertical videos only (9:16, the Shorts and Reels format).
    public static func isVertical(_ s: ProjectSettings) -> Bool { (0.55...0.58).contains(Double(s.width) / Double(max(s.height, 1))) }

    static func requireVertical(_ project: Project, command: String) throws {
        guard isVertical(project.settings) else {
            throw CommandError.conflict("\(command): covers are for vertical videos (9:16, Shorts and Reels); this project is \(project.settings.width)×\(project.settings.height)")
        }
    }

    /// Frames of the cover held at the end of an export with `appendCover` (the thumbnail frame a phone app can pick).
    public static let appendedFrames = 3

    /// The side margin the title keeps, pixels per 1080 of the frame's width.
    public static let sideMargin = 60.0

    /// The band of a `width`×`height` frame that survives both crops, [x0, y0, x1, y1]: the centred 3:4 of the
    /// Instagram grid (1080×1440 of a 1080×1920 cover) and the centred 2:3 of the Shorts shelf (1080×1620), inside the
    /// side margin.
    public static func band(width: Int, height: Int) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        let W = Double(width), H = Double(height)
        let grid = W * 4 / 3, shelf = W * 3 / 2   // the visible heights of the two crops
        let visible = min(grid, shelf, H)
        let m = sideMargin * W / SafeZones.referenceWidth
        return (m, (H - visible) / 2, W - m, (H + visible) / 2)
    }
}

/// The result of the cover's check: where the title's ink is (measured on the rendered pixels) and by how much it leaves
/// the band, side by side.
public struct CoverCheck: Equatable, Sendable {
    public struct Overflow: Equatable, Sendable {
        public var side: String   // top, bottom, left, right
        public var pixels: Int
    }
    /// The title's box [x, y, w, h], output pixels, top-left origin (nil: no title, or it drew nothing).
    public var box: [Double]?
    public var band: (x0: Double, y0: Double, x1: Double, y1: Double)
    public var overflows: [Overflow]
    /// The place that would fit (a title too high or too low), nil when the place is not the way (too wide, too tall).
    public var fixPlace: Cover.Place?
    public var pass: Bool { overflows.isEmpty }

    public static func == (a: CoverCheck, b: CoverCheck) -> Bool {
        a.box == b.box && a.overflows == b.overflows && a.fixPlace == b.fixPlace
            && [a.band.x0, a.band.y0, a.band.x1, a.band.y1] == [b.band.x0, b.band.y0, b.band.x1, b.band.y1]
    }

    /// Checks a measured box against the band of the frame; `place` is the cover's, `height` the frame's.
    static func of(box: [Double]?, width: Int, height: Int, place: Cover.Place) -> CoverCheck {
        let band = Cover.band(width: width, height: height)
        guard let b = box, b.count == 4 else { return CoverCheck(box: box, band: band, overflows: [], fixPlace: nil) }
        var out: [Overflow] = []
        func add(_ side: String, _ v: Double) { if v >= 1 { out.append(Overflow(side: side, pixels: Int(v.rounded(.up)))) } }
        add("top", band.y0 - b[1])
        add("bottom", b[1] + b[3] - band.y1)
        add("left", band.x0 - b[0])
        add("right", b[0] + b[2] - band.x1)
        // A place that fits: the same box height centred on another place's line lies inside the band.
        var fix: Cover.Place?
        let vertical = out.contains { $0.side == "top" || $0.side == "bottom" }
        if vertical, b[3] <= band.y1 - band.y0 {
            let k = Double(height) / SafeZones.referenceHeight
            fix = Cover.Place.allCases.filter { $0 != place }
                .first { p in let c = p.centreY * k; return c - b[3] / 2 >= band.y0 && c + b[3] / 2 <= band.y1 }
        }
        return CoverCheck(box: b, band: band, overflows: out, fixPlace: fix)
    }

    /// The check in one English sentence (the engine's words; the app says it in the interface language).
    public var sentence: String {
        guard !pass else { return box == nil ? "no title on the cover: nothing to check" : "the title lies inside the band that survives both crops" }
        let sides = overflows.map { "\($0.pixels) px at the \($0.side)" }.joined(separator: " and ")
        let crops = overflows.contains { $0.side == "top" || $0.side == "bottom" } ? " (the Instagram grid's 3:4 crop and the Shorts shelf's 2:3 crop keep y \(Int(band.y0))–\(Int(band.y1)))" : ""
        let fix: String
        if let p = fixPlace { fix = "cover.set {place: \"\(p.rawValue)\"} fits it" }
        else { fix = "a shorter title fits it: cover.set {title: …} with fewer words, or one on two lines" }
        return "the title leaves the band that survives both crops by \(sides)\(crops); \(fix)"
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "pass": .bool(pass), "sentence": .string(sentence),
            "band": .array([band.x0, band.y0, band.x1, band.y1].map { .number(($0 * 10).rounded() / 10) }),
            "overflows": .array(overflows.map { ["side": .string($0.side), "pixels": .number(Double($0.pixels))] }),
        ]
        o["box"] = box.map { .array($0.map { .number(($0 * 10).rounded() / 10) }) } ?? .null
        if let p = fixPlace { o["fix"] = ["command": "cover.set", "place": .string(p.rawValue)] }
        else if !pass { o["fix"] = ["command": "cover.set", "title": "shorter"] }
        return .object(o)
    }
}

enum CoverRender {
    /// The title the cover draws: the kit's preset (or its "hook"), else Regista's plain title — as title.add builds it.
    static func title(_ cover: Cover, kit: BrandKit?, command: String) throws -> Title? {
        guard let text = cover.title?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        var title: Title
        if let name = cover.preset {
            guard let kit else { throw CommandError.conflict("\(command): preset \"\(name)\" needs a brand kit: call brandkit.apply first") }
            guard let preset = kit.titles[name] else {
                throw CommandError.invalid("\(command): kit \(kit.id) has no preset \"\(name)\" (presets: \(kit.titles.keys.sorted().joined(separator: ", ")))")
            }
            title = preset
        } else if let hook = kit?.titles["hook"] {
            title = hook
        } else {
            title = Title(text: "", font: "Helvetica-Bold", size: 72, color: "#FFFFFF")
            title.shadow = TitleShadow()
        }
        title.text = text.replacingOccurrences(of: "\\n", with: "\n")
        if let kit { title = kit.resolve(title) }
        return title
    }

    /// The project as the cover draws it: the cover's title at rest on a track of its own above everything, for the one
    /// frame at the cover's time (no caption is drawn: the render job leaves them out).
    static func project(_ project: Project, _ cover: Cover, title: Title?) -> Project {
        guard let title else { return project }
        var p = project
        let frame = MediaTime.frameDuration(at: p.settings.frameRate)
        var track = Track(id: "cover-title", kind: .overlay, name: "Cover")
        var clip = Clip(id: "cover-title", assetID: "", sourceIn: .zero, sourceOut: frame, start: cover.time)
        clip.title = title
        clip.placement = Placement(fit: .native, x: 0.5, y: cover.place.centreY / SafeZones.referenceHeight)
        track.clips = [clip]
        p.tracks.append(track)
        return p
    }

    /// The cover's time on the frame grid, inside the timeline.
    static func time(_ cover: Cover, in project: Project) -> MediaTime {
        let rate = project.settings.frameRate
        let frame = MediaTime.frameDuration(at: rate)
        return min(max(cover.time.snapped(to: rate), .zero), max(project.duration - frame, .zero))
    }

    /// Renders the cover to `output` (a PNG at the project's size) and checks its title: the title's box is measured on
    /// the rendered pixels, as media.checkOverlay measures an element — the same frame drawn without it, compared.
    static func render(_ project: Project, _ cover: Cover, to output: URL, _ ctx: CommandContext, command: String) throws -> CoverCheck {
        let renderer = try Render.renderer(ctx, command: command)
        guard project.duration > .zero else { throw CommandError.conflict("\(command): the timeline is empty") }
        var cover = cover
        cover.time = time(cover, in: project)
        let title = try title(cover, kit: project.brand, command: command)
        let preset = ExportPreset.named(nil, project: project)
        let drawn = RenderJob(project: Self.project(project, cover, title: title), preset: preset, captions: false)
        try renderer.renderFrames(drawn, at: [cover.time], to: [output])
        let (W, H) = (project.settings.width, project.settings.height)
        guard title != nil else { return CoverCheck.of(box: nil, width: W, height: H, place: cover.place) }
        guard let images = ctx.services.images else { throw CommandError(.io, "\(command): no image toolkit in this host (use regista-engine / regista-mcp)") }
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("regista-cover-bare-\(UUID().uuidString.prefix(8)).png")
        defer { try? FileManager.default.removeItem(at: bare) }
        try renderer.renderFrames(RenderJob(project: project, preset: preset, captions: false), at: [cover.time], to: [bare])
        let a = try images.rgba(of: output, width: W, height: H), b = try images.rgba(of: bare, width: W, height: H)
        return CoverCheck.of(box: difference(a, b, width: W, height: H), width: W, height: H, place: cover.place)
    }

    /// The box [x, y, w, h] of the pixels that differ between two RGBA buffers by more than `threshold` in a channel.
    static func difference(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, threshold: Int = 24) -> [Double]? {
        guard a.count == b.count, a.count >= width * height * 4 else { return nil }
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for y in 0..<height {
                    let row = y * width * 4
                    for x in 0..<width {
                        let o = row + x * 4
                        if abs(Int(pa[o]) - Int(pb[o])) > threshold || abs(Int(pa[o + 1]) - Int(pb[o + 1])) > threshold
                            || abs(Int(pa[o + 2]) - Int(pb[o + 2])) > threshold {
                            if x < x0 { x0 = x }; if x > x1 { x1 = x }
                            if y < y0 { y0 = y }; if y > y1 { y1 = y }
                        }
                    }
                }
            }
        }
        guard x1 >= x0, y1 >= y0 else { return nil }
        return [Double(x0), Double(y0), Double(x1 - x0 + 1), Double(y1 - y0 + 1)]
    }

    /// Where the cover goes by default: next to the exports, named after the project.
    static func defaultOutput(_ project: Project, _ ctx: CommandContext) -> URL {
        let folder = ctx.services.library.exportsDirectory ?? ctx.projectURL?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        return folder.appendingPathComponent("\(project.name)-cover.png")
    }

    /// The project with the cover held for the last `Cover.appendedFrames` frames (export.render appendCover): the
    /// rendered cover as a full-frame still after the end of the timeline, with no sound under it.
    static func appended(_ project: Project, cover png: URL) -> Project {
        var p = project
        let rate = p.settings.frameRate
        let frame = MediaTime.frameDuration(at: rate)
        let end = p.duration
        let length = MediaTime(ticks: frame.ticks * Int64(Cover.appendedFrames))
        let asset = MediaAsset(id: "cover-still", name: png.lastPathComponent, path: png.path, duration: ImageSource.stillDuration,
                               video: VideoInfo(width: p.settings.width, height: p.settings.height, frameRate: rate, codec: "png"),
                               audio: nil, image: ImageSource(kind: .still, path: png.path))
        p.assets.append(asset)
        var track = Track(id: "cover-frames", kind: .overlay, name: "Cover")
        track.clips = [Clip(id: "cover-frames", assetID: asset.id, sourceIn: .zero, sourceOut: length, start: end)]
        p.tracks.append(track)
        return p
    }
}

enum CoverSet: Command {
    static let id = "cover.set"
    static let summary = "Set the reel's cover (vertical 9:16 projects only), saved with the project and undoable: the timeline time of its frame, an optional title (3–5 words read best; empty removes it), the brand kit's title preset it is drawn with (default: the kit's hook) and the title's place (top, center, bottom). Any subset; the rest is kept. Then cover.make renders it and checks that the title survives both crops (the Instagram grid's 3:4 and the Shorts shelf's 2:3). Returns the cover."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("time", .time, "Timeline time of the frame (snapped to the frame grid; default 0 for a new cover)."),
        .optional("title", .string, "The title's words; \\n starts a new line; empty: no title."),
        .optional("preset", .string, "Title preset of the applied brand kit (e.g. hook, kicker); empty: the default."),
        .optional("place", .oneOf(Cover.Place.allCases.map(\.rawValue)), "Where the title sits: top, center (default) or bottom."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        try Cover.requireVertical(project, command: id)
        var cover = project.cover ?? Cover()
        if let t = p.time("time") {
            guard t >= .zero else { throw CommandError.invalid("\(id): time must be ≥ 0") }
            cover.time = t
            cover.time = CoverRender.time(cover, in: project)
        }
        if let t = p.string("title") {
            let text = t.replacingOccurrences(of: "\\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            cover.title = text.isEmpty ? nil : text
        }
        if let s = p.string("preset") {
            if s.isEmpty { cover.preset = nil } else {
                guard let kit = project.brand else { throw CommandError.conflict("\(id): preset \"\(s)\" needs a brand kit: call brandkit.apply first") }
                guard kit.titles[s] != nil else {
                    throw CommandError.invalid("\(id): kit \(kit.id) has no preset \"\(s)\" (presets: \(kit.titles.keys.sorted().joined(separator: ", ")))")
                }
                cover.preset = s
            }
        }
        if let s = p.string("place") { cover.place = Cover.Place(rawValue: s) ?? cover.place }
        project.cover = cover
        ctx.project = project
        return ["cover": cover.json]
    }
}

enum CoverMake: Command {
    static let id = "cover.make"
    static let summary = "Render the reel's cover (cover.set first; vertical 9:16 projects only) to a PNG at the project's size: the timeline's frame at the cover's time as frame.render draws it but without captions, and the cover's title drawn by the title engine with the brand kit's preset. Then the check (as cover.check): the title's box, measured on the rendered pixels, must lie inside the band that survives the Instagram grid's centred 3:4 crop and the Shorts shelf's centred 2:3 crop, with the side margin; a title that leaves it fails with by how many pixels, on which side, and the cover.set that fits. Returns the file, the cover and the check, and the cover as an image you can see."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("output", .string, "Output .png (default: <project>-cover.png next to the exports)."),
        .optional("inline", .boolean, "Return the cover as an image (default true)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        try Cover.requireVertical(project, command: id)
        guard let cover = project.cover else { throw CommandError.conflict("\(id): the project has no cover yet: cover.set {time, title} first") }
        let output = try Render.output(p.string("output") ?? CoverRender.defaultOutput(project, ctx).path, command: id)
        let check = try CoverRender.render(project, cover, to: output, ctx, command: id)
        var result: [String: JSONValue] = ["path": .string(output.path), "width": .number(Double(project.settings.width)),
                                           "height": .number(Double(project.settings.height)), "cover": cover.json, "check": check.json]
        if p.bool("inline") ?? true { result["images"] = .array(try Previews.frames([output], ctx)) }
        return .object(result)
    }
}

enum CoverCheckCommand: Command {
    static let id = "cover.check"
    static let summary = "Check the reel's cover without saving it (cover.make returns the same check): its title's box, measured on the rendered pixels, against the band that survives both crops of a vertical cover — the Instagram grid's centred 3:4 (1080×1440) and the Shorts shelf's centred 2:3 (1080×1620) — with the side margin. Returns pass, the box, the band, each side it leaves by how many pixels, a sentence and the fix (cover.set with a place that fits, or a shorter title)."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        try Cover.requireVertical(project, command: id)
        guard let cover = project.cover else { throw CommandError.conflict("\(id): the project has no cover yet: cover.set {time, title} first") }
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("regista-cover-check-\(UUID().uuidString.prefix(8)).png")
        defer { try? FileManager.default.removeItem(at: png) }
        return ["cover": cover.json, "check": try CoverRender.render(project, cover, to: png, ctx, command: id).json]
    }
}
