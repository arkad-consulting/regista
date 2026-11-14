import Foundation

// Moving and resizing captions, titles, stickers, logos and overlays by hand (issue #21): the commands a drag on the
// preview runs (one drag = one command = one undo step) and the agent runs for "move the captions up and left".

enum Placing {
    static let unitsParam = ParamSpec.optional("units", .oneOf(["px", "fraction"]), "x/y/dx/dy in pixels of the project frame (px, default; 1080×1920 for a reel) or fractions of its width/height (fraction).")

    static func r1(_ v: Double) -> JSONValue { .number((v * 10).rounded() / 10) }

    static func placeJSON(_ p: CaptionPlace?) -> JSONValue {
        guard let p, !p.isEmpty else { return .null }
        var o: [String: JSONValue] = [:]
        if let x = p.x { o["x"] = r1(x) }
        if let y = p.y { o["y"] = r1(y) }
        if let s = p.scale { o["scale"] = .number((s * 1000).rounded() / 1000) }
        if let a = p.align { o["align"] = .string(a.rawValue) }
        return .object(o)
    }

    /// Anchor of a line box for an alignment (x of its left edge, centre or right edge).
    static func anchor(_ line: [Double], _ align: CaptionPlace.Align) -> Double {
        switch align {
        case .left: line[0]
        case .center: line[0] + line[2] / 2
        case .right: line[0] + line[2]
        }
    }
}

enum CaptionsPlace: Command {
    static let id = "captions.place"
    static let summary = "Move or resize the captions by hand, like text in an Instagram story: the whole track (default) or only some chunks (chunk index, chunks, the chunk showing at time, or every chunk starting in from…to). x is the line's left edge, centre or right edge (align), y the vertical centre of the line, in pixels of the frame (1080×1920) — or dx/dy to move from where it is now; scale resizes (1 = the style's size). A chunk's own placement wins over the track's; a chunk placed by hand stays there (automatic face avoidance leaves it alone; captions.checkFaces reports a face under it as a warning). reset goes back to automatic. Lines are kept inside the frame. Returns where each line now is and warnings for the Instagram zones."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Caption track (default: the first one with captions)."),
        .optional("chunk", .integer, "Only this chunk (index from captions.get)."),
        .optional("chunks", .array(.integer), "Only these chunks."),
        .optional("time", .time, "Only the chunk showing at this timeline time (seconds)."),
        .optional("from", .time, "Only the chunks starting at or after this time (with to)."),
        .optional("to", .time, "…and before this time."),
        .optional("x", .number, "Horizontal position: the line's left edge (align left), centre (center, default) or right edge (right)."),
        .optional("y", .number, "Vertical centre of the line."),
        .optional("dx", .number, "Move right by this much from the current position (negative = left)."),
        .optional("dy", .number, "Move down by this much (negative = up)."),
        Placing.unitsParam,
        .optional("scale", .number, "Size factor, 0.3…4 (1 = the style's size)."),
        .optional("align", .oneOf(CaptionPlace.alignNames), "What x refers to: left, center or right edge of the line."),
        .optional("reset", .boolean, "Back to automatic (the track: every chunk too). With other fields: start from automatic, then apply them."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let t = try CaptionsCommon.trackIndex(p, project, command: id)
        var c = try CaptionsCommon.require(project.tracks[t], command: id)
        guard !c.chunks.isEmpty else { throw CommandError.conflict("\(id): the captions have no chunks") }
        let fields = ["x", "y", "dx", "dy", "scale", "align"].filter(p.has)
        guard !fields.isEmpty || p.bool("reset") == true else { throw CommandError.invalid("\(id): pass x, y, dx, dy, scale, align or reset") }
        let style = c.style
        let fraction = p.string("units") == "fraction"
        let kx = fraction ? style.referenceWidth : style.referenceWidth / Double(project.settings.width)
        let ky = fraction ? style.referenceHeight : style.referenceHeight / Double(project.settings.height)
        if let s = p.number("scale"), !(0.3...4).contains(s) { throw CommandError.invalid("\(id): scale must be 0.3…4") }
        let align = p.string("align").flatMap(CaptionPlace.Align.init(rawValue:))

        // Which chunks (nil = the track).
        var selected: [Int]?
        if let i = p.int("chunk") { selected = [i] }
        if let list = p.json("chunks")?.arrayValue { selected = (selected ?? []) + list.compactMap { $0.doubleValue.map { Int($0) } } }
        if let at = p.time("time") {
            guard let i = c.chunk(at: at) ?? c.chunks.lastIndex(where: { ($0.words.first?.start ?? $0.end) <= at }) else {
                throw CommandError.notFound("\(id): no chunk at \(at.displaySeconds) s")
            }
            selected = (selected ?? []) + [i]
        }
        if p.has("from") || p.has("to") {
            let from = p.time("from") ?? .zero, to = p.time("to") ?? MediaTime(seconds: 1e9)
            let range = c.chunks.indices.filter { i in let s = c.chunks[i].words.first?.start ?? c.chunks[i].end; return s >= from && s < to }
            guard !range.isEmpty else { throw CommandError.notFound("\(id): no chunk starts between \(from.displaySeconds) and \(to.displaySeconds) s") }
            selected = (selected ?? []) + range
        }
        if let s = selected {
            if let bad = s.first(where: { !c.chunks.indices.contains($0) }) {
                throw CommandError.invalid("\(id): chunk \(bad) does not exist (0…\(c.chunks.count - 1))")
            }
            selected = Array(Set(s)).sorted()
        }

        // Where the lines are now (reference pixels): to move by dx/dy and to tell when the frame edge stopped one.
        var job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project))
        job.captions = c
        let toRefX = style.referenceWidth / Double(job.width), toRefY = style.referenceHeight / Double(job.height)
        let renderer = ctx.services.renderer
        lazy var words = CaptionPlacement.wordBoxes(job, renderer: renderer)
        lazy var band = (try? (renderer ?? EstimateRenderer()).captionBands(job)) ?? []
        func current(_ i: Int, _ a: CaptionPlace.Align) -> (x: Double, y: Double) {
            let line = (words.indices.contains(i) ? FaceFraming.union(words[i]) : nil) ?? [Double(job.width) / 2, 0, 0, 0]
            let y = band.indices.contains(i) ? band[i][1] + band[i][3] / 2 : job.captionBandTop(chunk: i) + style.bandHeight * job.captionScale / 2
            return (Placing.anchor(line, a) * toRefX, y * toRefY)
        }
        let dx = p.number("dx").map { $0 * kx }, dy = p.number("dy").map { $0 * ky }
        if let selected {
            for i in selected {
                var pl = p.bool("reset") == true ? CaptionPlace() : (c.chunks[i].place ?? CaptionPlace())
                if let align { pl.align = align }
                let a = c.manualPlace(chunk: i).align ?? .center
                let a2 = pl.align ?? c.place?.align ?? .center
                if let x = p.number("x") { pl.x = x * kx }
                if let dx {
                    pl.x = ((a == a2 ? c.manualPlace(chunk: i).x : nil) ?? current(i, a2).x) + dx
                }
                if let y = p.number("y") { pl.y = y * ky }
                if let dy { pl.y = (c.manualPlace(chunk: i).y ?? current(i, a2).y) + dy }
                if let s = p.number("scale") { pl.scale = s }
                c.chunks[i].place = pl.isEmpty ? nil : pl
            }
        } else {
            if p.bool("reset") == true, fields.isEmpty { for i in c.chunks.indices { c.chunks[i].place = nil } }
            var pl = p.bool("reset") == true ? CaptionPlace() : (c.place ?? CaptionPlace())
            if let align { pl.align = align }
            let ref = p.time("time").flatMap(c.chunk(at:)) ?? 0
            if let x = p.number("x") { pl.x = x * kx }
            if let dx {
                pl.x = (pl.x ?? current(ref, pl.align ?? .center).x) + dx
                for i in c.chunks.indices where c.chunks[i].place?.x != nil { c.chunks[i].place!.x! += dx }
            }
            if let y = p.number("y") { pl.y = y * ky }
            if let dy {
                pl.y = (pl.y ?? style.bandY + style.bandHeight / 2) + dy
                for i in c.chunks.indices where c.chunks[i].place?.y != nil { c.chunks[i].place!.y! += dy }
            }
            if let s = p.number("scale") { pl.scale = s }
            c.place = pl.isEmpty ? nil : pl
        }
        let placement = CaptionsCommon.place(&c, project, renderer: ctx.services.renderer)
        project.tracks[t].captions = c
        ctx.project = project

        // Where every affected line ended up.
        job.captions = c
        let placedWords = CaptionPlacement.wordBoxes(job, renderer: renderer)
        let affected = selected ?? Array(c.chunks.indices)
        var rows: [JSONValue] = [], warnings: [String] = [], clamped = 0
        var zoneCount: [String: Int] = [:]
        for i in affected where i < placedWords.count {
            guard let line = FaceFraming.union(placedWords[i]) else { continue }
            let m = c.manualPlace(chunk: i)
            var edge = false
            if let x = m.x, abs(Placing.anchor(line, m.align ?? .center) * toRefX - x) > 1.5 { edge = true }
            if let y = m.y, abs((line[1] + line[3] / 2) * toRefY - y) > style.bandHeight * c.scale(chunk: i) * 0.25 + 2 { edge = true }
            if edge { clamped += 1 }
            let hits = SafeZones.instagramHits(line, width: job.width, height: job.height)
            for h in hits { zoneCount[h, default: 0] += 1 }
            if selected != nil {
                warnings += SafeZones.instagramWarnings(line, width: job.width, height: job.height, what: "chunk \(i) \"\(c.chunks[i].text)\"")
                rows.append(["chunk": .number(Double(i)), "text": .string(c.chunks[i].text), "line": .array(line.map(Placing.r1)),
                             "center": .array([Placing.r1(line[0] + line[2] / 2), Placing.r1(line[1] + line[3] / 2)]),
                             "scale": .number(c.scale(chunk: i)), "place": Placing.placeJSON(c.chunks[i].place), "clamped": .bool(edge)])
            }
        }
        if selected == nil {
            for (zone, n) in zoneCount.sorted(by: { $0.key < $1.key }) {
                warnings.append("\(n) of \(affected.count) chunks enter \(SafeZones.instagramLabel(zone))")
            }
            rows = affected.prefix(3).compactMap { i in
                guard i < placedWords.count, let line = FaceFraming.union(placedWords[i]) else { return nil }
                return ["chunk": .number(Double(i)), "text": .string(c.chunks[i].text), "line": .array(line.map(Placing.r1))]
            }
        }
        if clamped > 0 { warnings.append("\(clamped) line(s) kept inside the frame (they would have gone past the edge)") }
        return ["trackId": .string(project.tracks[t].id), "scope": .string(selected == nil ? "track" : "chunks"),
                "trackPlace": Placing.placeJSON(c.place), "chunks": .array(rows), "clamped": .number(Double(clamped)),
                "placedChunks": .number(Double(c.chunks.filter { $0.place != nil }.count)),
                "warnings": .array(warnings.map { .string($0) }), "placement": CaptionsCommon.placementJSON(placement)]
    }
}

enum ClipPlace: Command {
    static let id = "clip.place"
    static let summary = "Move, resize or rotate anything drawn on the frame by hand (what a drag on the preview does): a title, sticker, logo or overlay; the full-frame picture (a camera take, a full-frame insert: the first move turns \"fills the frame\" into a box exactly as large as the frame, then moves it; smaller than the frame, the background shows around it); a box of a recording layout (screen, camera bubble: a box placed by hand, until layout.apply is run again on it); a callout, progress bar, status row or level meters (their own rectangle moves and grows). x/y = where its centre goes, in pixels of the frame (1080×1920) — or dx/dy from where it is now — scale (titles, stickers, logos, overlays: 1 = native size; the others: 1 = the size it had before it was first moved by hand), rotation in degrees (not a callout). Its animation moves with it: entrance/exit, punch-ins and auto zoom (the crop is kept: the same part of the picture shows), follow. Kept inside the frame (a full-frame picture: its centre). reset puts it back exactly as it was before it was first moved. A motion template or a halo cannot be placed by hand. Returns its box and warnings (caption band, Instagram zones)."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("clipId", .string, "The clip: a title, sticker, logo, overlay, full-frame picture, layout box, callout, progress bar, status row or meters (frame.elements lists them)."),
        .optional("x", .number, "Horizontal centre."),
        .optional("y", .number, "Vertical centre."),
        .optional("dx", .number, "Move right by this much (negative = left)."),
        .optional("dy", .number, "Move down by this much (negative = up)."),
        Placing.unitsParam,
        .optional("scale", .number, "Size factor, 0.05…20 (titles, stickers, logos, overlays: 1 = native size; pictures, layout boxes, callouts: 1 = their size before the first move by hand)."),
        .optional("rotation", .number, "Degrees clockwise (not callouts, progress bars, status rows or meters)."),
        .optional("reset", .boolean, "Back to exactly how it was before it was first moved by hand."),
    ]

    /// What the clip is, in the words of the results and errors.
    static func what(_ clip: Clip, _ track: Track, _ project: Project) -> String {
        if let s = clip.shape {
            switch s.kind {
            case .progressBar: return "progress bar"
            case .statusBar: return "status row"
            case .audioMeters: return "level meters"
            case .halo: return "halo"
            default: return "callout"
            }
        }
        if clip.title != nil { return "title" }
        if clip.sticker != nil { return "sticker" }
        if clip.isFullFramePicture { return "picture" }
        if clip.placement?.fit == .box, project.asset(clip.assetID)?.image == nil { return "layout box" }
        return track.role == "logo" ? "logo" : "overlay"
    }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let cid = try p.requiredString("clipId")
        let (t, c) = try Timeline.locate(clip: cid, in: project)
        guard !project.tracks[t].locked else { throw CommandError.conflict("\(id): track \(project.tracks[t].name) is locked") }
        guard project.tracks[t].kind == .video || project.tracks[t].kind == .overlay else {
            throw CommandError.conflict("\(id): \(cid) is not drawn on the frame (a clip of the \(project.tracks[t].kind.rawValue) track \(project.tracks[t].name))")
        }
        var clip = project.tracks[t].clips[c]
        if clip.motion != nil {
            throw CommandError.conflict("\(id): \(cid) is a motion template: it is drawn from its own fields (motion.add), not placed by hand")
        }
        if clip.shape?.kind == .halo {
            throw CommandError.conflict("\(id): \(cid) is a halo that follows the object above it (clip.follow): move that object instead")
        }
        let what = what(clip, project.tracks[t], project)
        let fields = ["x", "y", "dx", "dy", "scale", "rotation"].filter(p.has)
        guard !fields.isEmpty || p.bool("reset") == true else { throw CommandError.invalid("\(id): pass x, y, dx, dy, scale, rotation or reset") }
        if p.has("rotation"), clip.shape != nil { throw CommandError.invalid("\(id): a \(what) does not turn: pass x, y, dx, dy or scale") }
        if let s = p.number("scale"), !(0.05...20).contains(s) { throw CommandError.invalid("\(id): scale must be 0.05…20") }
        let W = Double(project.settings.width), H = Double(project.settings.height)
        let fraction = p.string("units") == "fraction"
        let fx = fraction ? 1 : 1 / W, fy = fraction ? 1 : 1 / H
        if p.bool("reset") == true {
            if let o = clip.placeOrigin {
                clip.placement = o.placement
                clip.transform = o.transform
                clip.keyframes = o.keyframes
                if let r = o.rect { clip.shape?.rect = r }
                clip.placeOrigin = nil
            }
        }
        if !fields.isEmpty {
            if clip.placeOrigin == nil {
                clip.placeOrigin = PlaceOrigin(placement: clip.placement, transform: clip.transform, keyframes: clip.keyframes, rect: clip.shape?.rect)
            }
            if var shape = clip.shape {
                // A callout is drawn in frame coordinates from its own rectangle (fractions of the frame): it moves and
                // grows around its centre; its fade keyframes do not change.
                var r = shape.rect
                var cx = r[0] + r[2] / 2, cy = r[1] + r[3] / 2
                if let x = p.number("x") { cx = x * fx }
                if let y = p.number("y") { cy = y * fy }
                if let dx = p.number("dx") { cx += dx * fx }
                if let dy = p.number("dy") { cy += dy * fy }
                if let s = p.number("scale") {
                    let o = clip.placeOrigin?.rect ?? r
                    let base = max(abs(o[2]), abs(o[3])), now = max(abs(r[2]), abs(r[3]))
                    if base > 0, now > 0 { r[2] *= s * base / now; r[3] *= s * base / now }
                }
                r[0] = cx - r[2] / 2
                r[1] = cy - r[3] / 2
                shape.rect = r
                clip.shape = shape
            } else {
                // A picture that fills the frame becomes a box exactly as large as the frame: the same picture (the crop
                // fitted to the box's aspect, which is the frame's), now placeable.
                if clip.placement == nil || clip.placement?.fit == .fill {
                    var box = Placement(fit: .box)
                    box.width = 1
                    box.height = 1
                    clip.placement = box
                }
                var pl = clip.placement!
                var rest = clip.transform ?? Transform()
                // The centre at rest = placement + the rest offset; keyframes are relative to the placement, so they follow.
                var cx = pl.x + rest.x, cy = pl.y + rest.y
                if let x = p.number("x") { cx = x * fx }
                if let y = p.number("y") { cy = y * fy }
                if let dx = p.number("dx") { cx += dx * fx }
                if let dy = p.number("dy") { cy += dy * fy }
                pl.x = cx - rest.x
                pl.y = cy - rest.y
                if let s = p.number("scale") {
                    if let base = clip.boxBase {
                        // A box grows itself (its crop, keyframes and decorations stay as they are).
                        pl.width = base.width * s
                        pl.height = base.height * s
                    } else {
                        let ratio = s / max(rest.scale, 1e-6)
                        rest.scale = s
                        if let ks = clip.keyframes { clip.keyframes = ks.map { var k = $0; k.transform.scale *= ratio; return k } }
                    }
                }
                if let r = p.number("rotation") {
                    let delta = r - rest.rotation
                    rest.rotation = r
                    if let ks = clip.keyframes { clip.keyframes = ks.map { var k = $0; k.transform.rotation += delta; return k } }
                }
                clip.placement = pl
                clip.transform = rest == Transform() ? nil : rest
            }
        }
        project.tracks[t].clips[c] = clip
        // Keep it inside the frame (when it fits); a full-frame picture keeps its centre inside the frame.
        var clamped = false
        if !fields.isEmpty {
            if var shape = clip.shape {
                let r = shape.rect
                let x0 = min(r[0], r[0] + r[2]), y0 = min(r[1], r[1] + r[3]), w = abs(r[2]), h = abs(r[3])
                let sx = w <= 1 ? min(max(x0, 0), 1 - w) - x0 : 0, sy = h <= 1 ? min(max(y0, 0), 1 - h) - y0 : 0
                if abs(sx * W) > 0.25 || abs(sy * H) > 0.25 {
                    clamped = true
                    shape.rect[0] += sx
                    shape.rect[1] += sy
                    project.tracks[t].clips[c].shape = shape
                }
            } else if let box = Graphics.restBox(clip, track: project.tracks[t], project: project, renderer: ctx.services.renderer) {
                var sx = 0.0, sy = 0.0
                if clip.isFullFramePicture {
                    let mx = box[0] + box[2] / 2, my = box[1] + box[3] / 2
                    sx = min(max(mx, 0), W) - mx
                    sy = min(max(my, 0), H) - my
                } else {
                    if box[2] <= W { sx = min(max(box[0], 0), W - box[2]) - box[0] }
                    if box[3] <= H { sy = min(max(box[1], 0), H - box[3]) - box[1] }
                }
                if abs(sx) > 0.25 || abs(sy) > 0.25 {
                    clamped = true
                    project.tracks[t].clips[c].placement!.x += sx / W
                    project.tracks[t].clips[c].placement!.y += sy / H
                }
            }
            clip = project.tracks[t].clips[c]
        }
        ctx.project = project
        var result: [String: JSONValue] = ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id), "kind": .string(what),
                                           "clamped": .bool(clamped), "manual": .bool(clip.placeOrigin != nil)]
        let box = clip.shape.map { CanvasLayout.shapeBox($0, width: project.settings.width, height: project.settings.height) }
            ?? Graphics.restBox(clip, track: project.tracks[t], project: project, renderer: ctx.services.renderer)
        if let box {
            result["box"] = Graphics.boxJSON(box)
            result["center"] = .array([Placing.r1(box[0] + box[2] / 2), Placing.r1(box[1] + box[3] / 2)])
            // A picture or a layout box covers the zones by design: no zone warnings for them.
            var w = what == "picture" || what == "layout box" ? [] : Graphics.zoneWarnings(box, project: project, what: what)
            if clamped { w.append(.string(what == "picture" ? "picture kept with its centre inside the frame" : "\(what) kept inside the frame")) }
            result["warnings"] = .array(w)
        }
        return .object(result)
    }
}

enum FrameElements: Command {
    static let id = "frame.elements"
    static let summary = "Everything drawn on the frame at a time, from the render plan (where the compositor draws it), with a kind each: caption (the chunk showing), title, sticker, logo, overlay, picture (a clip that fills the frame: a camera take, a full-frame insert), layoutBox (a box of a recording layout: screen, camera bubble), callout, progress, status, meters, halo and motion (a motion template). Each with its box, centre, size, rotation and scale in pixels of the frame, whether it was placed by hand (manual) and whether it can be moved (movable: false for a halo, which follows an object, and a motion template, drawn from its own fields — a click on the preview only selects their clip). Use it before captions.place / clip.place to know where things are. Returns the list, bottom to top."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("time", .time, "Timeline time (seconds)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let t = p.requiredTime("time").snapped(to: project.settings.frameRate)
        let elements = CanvasLayout.elements(project, at: t, renderer: ctx.services.renderer)
        return ["time": ProjectState.seconds(t), "frame": .array([.number(Double(project.settings.width)), .number(Double(project.settings.height))]),
                "elements": .array(elements.map(\.json))]
    }
}

enum MediaCheckPlacement: Command {
    static let id = "media.checkPlacement"
    static let summary = "Verify where a caption chunk, title, sticker, logo or overlay really is in an exported mp4: the frame decoded from the file is compared with the same frame rendered without that element; the box of the pixels that differ is where the element was drawn. Compared with the render plan's box (frame.elements) — pass when the centres agree within the tolerance. Returns the found box, the planned box and the error."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("path", .string, "Rendered video (export.render output, project size)."),
        .optional("clipId", .string, "A title, sticker, logo or overlay clip."),
        .optional("chunk", .integer, "A caption chunk (instead of clipId)."),
        .optional("trackId", .string, "Caption track (default: the first one with captions)."),
        .optional("time", .time, "Frame to check (default: a chunk's last frame, when every word shows; a clip's middle)."),
        .optional("tolerance", .number, "Pixels of centre error still passing (default 4)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let renderer = try Render.renderer(ctx, command: id)
        guard let images = ctx.services.images else { throw CommandError(.io, "\(id): this host cannot read images") }
        let url = try MediaCheck.file(p, "path", command: id)
        let rate = project.settings.frameRate
        let frame = MediaTime.frameDuration(at: rate)
        var without = project
        var captionsInBase = true
        let time: MediaTime
        let elementID: String
        if let cid = p.string("clipId") {
            let (t, c) = try Timeline.locate(clip: cid, in: project)
            let clip = project.tracks[t].clips[c]
            time = (p.time("time") ?? clip.start + MediaTime(seconds: clip.duration.seconds / 2)).snapped(to: rate)
            without.tracks[t].clips.remove(at: c)
            elementID = cid
        } else if let ci = p.int("chunk") {
            let t = try CaptionsCommon.trackIndex(p, project, command: id)
            let c = try CaptionsCommon.require(project.tracks[t], command: id)
            guard c.chunks.indices.contains(ci) else { throw CommandError.invalid("\(id): chunk \(ci) does not exist") }
            time = (p.time("time") ?? c.chunks[ci].end - frame).snapped(to: rate)
            captionsInBase = false
            elementID = "caption:\(project.tracks[t].id):\(ci)"
        } else {
            throw CommandError.invalid("\(id): pass clipId or chunk")
        }
        guard let plan = CanvasLayout.elements(project, at: time, renderer: renderer).first(where: { $0.id == elementID }) else {
            throw CommandError.notFound("\(id): \(elementID) is not on the frame at \(time.displaySeconds) s")
        }
        let preset = ExportPreset.named(nil, project: project)
        let W = preset.width, H = preset.height
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-place-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("base.png"), full = dir.appendingPathComponent("full.png"), decoded = dir.appendingPathComponent("file.png")
        try renderer.renderFrames(RenderJob(project: without, preset: preset, captions: captionsInBase), at: [time], to: [base])
        try renderer.renderFrames(RenderJob(project: project, preset: preset), at: [time], to: [full])
        try Subprocess.check(MediaCheck.ffmpeg(ctx), FFmpegAudio.quiet + ["-ss", String(format: "%.6f", max(time.seconds - frame.seconds / 4, 0)), "-i", url.path,
                                                                          "-frames:v", "1", "-vf", "scale=\(W):\(H)", decoded.path])
        let a = try images.rgba(of: decoded, width: W, height: H), b = try images.rgba(of: base, width: W, height: H)
        let f = try images.rgba(of: full, width: W, height: H)
        func dist(_ p: [UInt8], _ i: Int, _ q: [UInt8], _ j: Int) -> Int {
            abs(Int(p[4 * i]) - Int(q[4 * j])) + abs(Int(p[4 * i + 1]) - Int(q[4 * j + 1])) + abs(Int(p[4 * i + 2]) - Int(q[4 * j + 2]))
        }
        // The element's pixels: where the render with it differs clearly from the render without it (both exact).
        var mask: [Int] = []
        var mx0 = W, my0 = H, mx1 = -1, my1 = -1
        for y in 0..<H {
            for x in 0..<W where dist(f, y * W + x, b, y * W + x) > 60 {
                mask.append(y * W + x)
                mx0 = min(mx0, x); mx1 = max(mx1, x); my0 = min(my0, y); my1 = max(my1, y)
            }
        }
        guard !mask.isEmpty else { throw CommandError.conflict("\(id): \(elementID) draws nothing at \(time.displaySeconds) s") }
        // Where those pixels are in the file: the shift (±12 px) that best matches the file to the render with the element,
        // against the hypothesis that the element is not there at all (the render without it).
        let sample = stride(from: 0, to: mask.count, by: max(mask.count / 6000, 1)).map { mask[$0] }
        let absent = Double(sample.map { dist(a, $0, b, $0) }.reduce(0, +)) / Double(sample.count)
        var best = (dx: 0, dy: 0, score: Double.infinity)
        for dy in -12...12 {
            for dx in -12...12 {
                var sum = 0, n = 0
                for k in sample {
                    let x = k % W + dx, y = k / W + dy
                    guard x >= 0, y >= 0, x < W, y < H else { continue }
                    sum += dist(a, y * W + x, f, k)
                    n += 1
                }
                let score = n > 0 ? Double(sum) / Double(n) : .infinity
                if score < best.score { best = (dx, dy, score) }
            }
        }
        let present = best.score < absent * 0.5
        let x0 = mx0 + best.dx, y0 = my0 + best.dy, x1 = mx1 + best.dx, y1 = my1 + best.dy
        let found = [Double(x0), Double(y0), Double(x1 - x0 + 1), Double(y1 - y0 + 1)]
        let fc = [found[0] + found[2] / 2, found[1] + found[3] / 2], pc = [plan.box[0] + plan.box[2] / 2, plan.box[1] + plan.box[3] / 2]
        let tol = p.number("tolerance") ?? 4
        return ["pass": .bool(present && Double(abs(best.dx)) <= tol && Double(abs(best.dy)) <= tol), "time": ProjectState.seconds(time),
                "found": .array(found.map(Placing.r1)), "foundCenter": .array(fc.map(Placing.r1)),
                "planned": .array(plan.box.map(Placing.r1)), "plannedCenter": .array(pc.map(Placing.r1)),
                "shift": .array([.number(Double(best.dx)), .number(Double(best.dy))]),
                "match": ["withElement": .number((best.score * 10).rounded() / 10), "without": .number((absent * 10).rounded() / 10),
                          "pixels": .number(Double(mask.count))],
                "tolerance": .number(tol)]
    }
}
