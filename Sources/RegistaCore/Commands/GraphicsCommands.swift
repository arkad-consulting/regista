import Foundation

// Overlays, titles, keyframes, effects, transitions and brand kits (issue #5, X1). Everything is an ordinary
// clip on an overlay track (or a project-level transition), so timeline.move/trim/delete, undo and export work on it.

enum Graphics {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "tif", "tiff", "bmp", "heic", "gif"]

    /// Imports a still, SVG, PNG sequence (folder or printf pattern) or video (alpha video becomes a PNG sequence).
    /// Returns the asset id (an existing asset for the same path is reused).
    static func importVisual(_ rawPath: String, into project: inout Project, _ ctx: inout CommandContext, alpha: Bool? = nil,
                             svgWidth: Int = 1080, command: String) throws -> String {
        let before = project.assets.count
        let id = try importVisualAsset(rawPath, into: &project, &ctx, alpha: alpha, svgWidth: svgWidth, command: command)
        // New image asset: measure where its pixels are (up to 12 frames sampled) for the layout checks.
        if project.assets.count > before, let i = project.assets.firstIndex(where: { $0.id == id }), let im = project.assets[i].image,
           let images = ctx.services.images {
            let n = min(im.count, 12)
            let files = (0..<n).map { k in URL(fileURLWithPath: im.kind == .still ? im.path : String(format: im.path, im.first + k * max(im.count - 1, 0) / max(n - 1, 1))) }
            project.assets[i].image?.ink = try? images.alphaBounds(of: files)
        }
        return id
    }

    static func importVisualAsset(_ rawPath: String, into project: inout Project, _ ctx: inout CommandContext, alpha: Bool?,
                                  svgWidth: Int, command: String) throws -> String {
        let path = URL(fileURLWithPath: EngineConfig.expand(rawPath)).standardizedFileURL.path
        if let existing = project.assets.first(where: { $0.path == path }) { return existing.id }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let name = URL(fileURLWithPath: path).lastPathComponent

        // PNG sequence: a folder of numbered frames, or a printf pattern.
        if path.contains("%") || (fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue) {
            let seq = try sequence(path, command: command)
            let info = try ctx.prober.probe(URL(fileURLWithPath: String(format: seq.path, seq.first)))
            guard var video = info.video else { throw CommandError(.io, "\(command): \(name) has no readable frames") }
            video.frameRate = seq.frameRate
            video.alpha = true
            let rate = seq.frameRate
            let asset = MediaAsset(id: project.makeID("a"), name: name, path: path,
                                   duration: MediaTime(value: Int64(seq.count) * rate.den, timescale: rate.num),
                                   video: video, audio: nil, image: seq)
            project.assets.append(asset)
            return asset.id
        }
        guard fm.fileExists(atPath: path) else { throw CommandError.notFound("\(command): no file at \(path)") }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "svg" {
            guard let images = ctx.services.images else { throw CommandError(.io, "\(command): this host cannot rasterize SVG") }
            let png = try ctx.mediaDirectory().appendingPathComponent("\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)-\(svgWidth).png")
            let size = try images.rasterizeSVG(URL(fileURLWithPath: path), width: svgWidth, to: png)
            let asset = MediaAsset(id: project.makeID("a"), name: name, path: path, duration: ImageSource.stillDuration,
                                   video: VideoInfo(width: size.width, height: size.height, frameRate: project.settings.frameRate, codec: "svg", alpha: true),
                                   audio: nil, image: ImageSource(kind: .still, path: png.path))
            project.assets.append(asset)
            return asset.id
        }
        let info = try ctx.prober.probe(URL(fileURLWithPath: path))
        guard var video = info.video else { throw CommandError.conflict("\(command): \(name) has no picture") }
        if imageExtensions.contains(ext) {
            video.frameRate = project.settings.frameRate
            let asset = MediaAsset(id: project.makeID("a"), name: name, path: path, duration: ImageSource.stillDuration,
                                   video: video, audio: nil, image: ImageSource(kind: .still, path: path))
            project.assets.append(asset)
            return asset.id
        }
        if alpha ?? (video.alpha == true) {
            // Alpha video: decode once to RGBA PNGs (AVFoundation composition tracks would drop the alpha).
            let dir = try ctx.mediaDirectory().appendingPathComponent("\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)-rgba")
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let ffmpeg = ctx.services.config.url(ctx.services.config.ffmpeg)
            let decoder = ext == "webm" ? ["-c:v", "libvpx-vp9"] : []
            try Subprocess.check(ffmpeg, FFmpegAudio.quiet + decoder + ["-i", path, "-an", "-pix_fmt", "rgba", "-start_number", "1",
                                                                        dir.appendingPathComponent("%05d.png").path])
            let count = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".png") }.count
            guard count > 0 else { throw CommandError(.io, "\(command): no frames decoded from \(name)") }
            video.alpha = true
            let seq = ImageSource(kind: .sequence, path: dir.appendingPathComponent("%05d.png").path, first: 1, count: count, frameRate: video.frameRate)
            let asset = MediaAsset(id: project.makeID("a"), name: name, path: path,
                                   duration: MediaTime(value: Int64(count) * video.frameRate.den, timescale: video.frameRate.num),
                                   video: video, audio: nil, image: seq)
            project.assets.append(asset)
            return asset.id
        }
        let asset = MediaAsset(id: project.makeID("a"), name: name, path: path, duration: info.duration, video: video, audio: info.audio)
        project.assets.append(asset)
        return asset.id
    }

    /// Frames of a folder (numbered .png files) or a printf pattern.
    static func sequence(_ path: String, fps: Rational = Rational(30), command: String) throws -> ImageSource {
        let fm = FileManager.default
        if path.contains("%") {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            var first: Int?
            for i in 0...1 where fm.fileExists(atPath: String(format: path, i)) { first = i; break }
            guard let start = first else { throw CommandError.notFound("\(command): no frame \(String(format: path, 1)) in \(dir)") }
            var n = 0
            while fm.fileExists(atPath: String(format: path, start + n)) { n += 1 }
            return ImageSource(kind: .sequence, path: path, first: start, count: n, frameRate: fps)
        }
        let files = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { $0.lowercased().hasSuffix(".png") }.sorted()
        guard let firstFile = files.first else { throw CommandError.notFound("\(command): no .png frames in \(path)") }
        let stem = String(firstFile.dropLast(4))
        let digits = stem.reversed().prefix { $0.isNumber }.count
        guard digits > 0, let number = Int(stem.suffix(digits)) else { throw CommandError.invalid("\(command): frames must be numbered (0001.png…)") }
        let prefix = String(stem.dropLast(digits)).replacingOccurrences(of: "%", with: "%%")
        let pattern = URL(fileURLWithPath: path).appendingPathComponent("\(prefix)%0\(digits)d.png").path
        var n = 0
        while fm.fileExists(atPath: String(format: pattern, number + n)) { n += 1 }
        return ImageSource(kind: .sequence, path: pattern, first: number, count: n, frameRate: fps)
    }

    /// An overlay track (role `role`) free over [start, end), created when none is: overlays go under the titles.
    static func track(_ role: String, in project: inout Project, start: MediaTime, end: MediaTime, preferred: String?) throws -> Int {
        if let id = preferred {
            let t = try Timeline.trackIndex(id, in: project)
            guard project.tracks[t].kind == .overlay || project.tracks[t].kind == .video else {
                throw CommandError.conflict("track \(id) is not a video/overlay track")
            }
            try Timeline.checkFree(project.tracks[t], start: start, end: end)
            return t
        }
        if let t = project.tracks.firstIndex(where: { $0.kind == .overlay && $0.role == role && !$0.locked && $0.overlap(start: start, end: end) == nil }) {
            return t
        }
        let n = project.tracks.filter { $0.kind == .overlay }.count
        var track = Track(id: project.makeID("t"), kind: .overlay, name: role == "titles" ? "Titles" : role == "inserts" ? "Inserts" : role == "logo" ? "Logo" : "O\(n + 1)")
        if role == "titles", project.tracks.contains(where: { $0.role == "titles" }) { track.name = "Titles \(project.tracks.filter { $0.role == "titles" }.count + 1)" }
        track.role = role
        // Stack: inserts above the camera, then overlays, then titles on top.
        let index: Int
        switch role {
        case "titles": index = project.tracks.count
        case "inserts": index = project.tracks.firstIndex { $0.role == "overlays" || $0.role == "titles" } ?? project.tracks.count
        default: index = project.tracks.firstIndex { $0.role == "titles" } ?? project.tracks.count
        }
        project.tracks.insert(track, at: index)
        return index
    }

    // MARK: Shared params

    static let positionParams: [ParamSpec] = [
        .optional("band", .oneOf(SafeZones.bandNames), "Vertical band of a 9:16 reel: top (y 110–640, the default for titles and cards), middle, lower (980–1200, just above the captions). The caption band 1230–1460 is reserved."),
        .optional("position", .array(.number), "Centre [x, y] in pixels of a 1080×1920 frame (overrides band)."),
        .optional("top", .number, "Top edge, pixels of a 1080×1920 frame (instead of a centre)."),
        .optional("scale", .number, "Size factor (1 = native size)."),
        .optional("opacity", .number, "0…1 (default 1)."),
        .optional("rotation", .number, "Degrees clockwise."),
    ]

    static let animationParams: [ParamSpec] = [
        .optional("animIn", .oneOf(AnimationPreset.names), "Entrance: pop (scale with overshoot), slideUp, slideDown, fade, kenBurns (slow push over the whole clip), none."),
        .optional("animOut", .oneOf(AnimationPreset.names), "Exit (default: same as animIn; kenBurns has none)."),
        .optional("inDuration", .number, "Entrance seconds (default 0.35; fade 0.25)."),
        .optional("outDuration", .number, "Exit seconds (default 0.25)."),
    ]

    /// Static transform + placement from the position params, for content `size` (reference pixels, before scale).
    static func place(_ p: CommandParams, size: (Double, Double), defaultBand: String?, fit: Placement.Fit) throws -> (Placement, Transform) {
        var tr = Transform()
        if let s = p.number("scale") { guard s > 0 else { throw CommandError.invalid("\(p.commandID): scale must be > 0") }; tr.scale = s }
        if let o = p.number("opacity") { tr.opacity = min(max(o, 0), 1) }
        if let r = p.number("rotation") { tr.rotation = r }
        var placement = Placement(fit: fit)
        if let pos = p.numbers("position") {
            guard pos.count == 2 else { throw CommandError.invalid("\(p.commandID): position is [x, y]") }
            placement.x = pos[0] / SafeZones.referenceWidth
            placement.y = pos[1] / SafeZones.referenceHeight
        } else if let top = p.number("top") {
            placement.y = (top + size.1 * tr.scale / 2) / SafeZones.referenceHeight
        } else if let band = p.string("band") ?? defaultBand, let c = SafeZones.centre(of: band) {
            placement.y = c
        }
        return (placement, tr)
    }

    /// Keyframes for an entrance/exit pair of presets (the rest state is the clip's static transform).
    static func animate(_ p: CommandParams, rest: Transform, duration: MediaTime, defaultIn: AnimationPreset? = nil) -> [Keyframe]? {
        let a = p.string("animIn").flatMap(AnimationPreset.init(rawValue:)) ?? defaultIn
        let b = p.string("animOut").flatMap(AnimationPreset.init(rawValue:)) ?? (a == .kenBurns ? AnimationPreset.none : a)
        return AnimationPreset.combined(in: a, out: b, rest: rest, duration: duration, inDuration: p.number("inDuration"), outDuration: p.number("outDuration"))
    }

    /// Clip range from start + duration/end (frame-snapped).
    static func range(_ p: CommandParams, _ project: Project, defaultDuration: MediaTime?) throws -> (MediaTime, MediaTime) {
        let rate = project.settings.frameRate
        let start = p.requiredTime("start").snapped(to: rate)
        var end: MediaTime
        if let e = p.time("end") { end = e.snapped(to: rate) }
        else if let d = p.time("duration") { end = (start + d).snapped(to: rate) }
        else if let d = defaultDuration { end = (start + d).snapped(to: rate) }
        else { throw CommandError.invalid("\(p.commandID): pass duration or end") }
        guard end > start else { throw CommandError.invalid("\(p.commandID): end must be after start") }
        return (start, end)
    }

    /// Layout warnings for a box at rest (output pixels of the project size).
    static func zoneWarnings(_ box: [Double], project: Project, what: String) -> [JSONValue] {
        let H = Double(project.settings.height), W = Double(project.settings.width), k = H / SafeZones.referenceHeight
        let (c0, c1) = SafeZones.captionBand(height: project.settings.height)
        var w: [JSONValue] = []
        if box[1] < c1 && box[1] + box[3] > c0 { w.append(.string("\(what) enters the caption band (y \(Int(c0))–\(Int(c1))): move it to the top band")) }
        if box[1] < SafeZones.topLimit * k { w.append(.string("\(what) starts above y \(Int(SafeZones.topLimit * k)) (Instagram top bar)")) }
        if box[1] + box[3] > SafeZones.bottomLimit * k { w.append(.string("\(what) goes below y \(Int(SafeZones.bottomLimit * k)) (Instagram caption/UI zone)")) }
        if box[0] + box[2] > W - SafeZones.rightMargin * W / SafeZones.referenceWidth {
            w.append(.string("\(what) reaches the right \(Int(SafeZones.rightMargin)) px (Instagram buttons)"))
        }
        return w
    }

    static func boxJSON(_ b: [Double]) -> JSONValue { .array(b.map { .number(($0 * 10).rounded() / 10) }) }

    /// Rest-state box of a clip's layer at the project size.
    static func restBox(_ clip: Clip, track: Track, project: Project, renderer: VideoRenderer?) -> [Double]? {
        var job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: false)
        job.project.transitions = nil
        let mid = clip.start + MediaTime(seconds: clip.duration.seconds / 2)
        var c = clip
        c.keyframes = nil
        c.effects = nil
        guard let ti = job.project.trackIndex(track.id), let ci = job.project.tracks[ti].clips.firstIndex(where: { $0.id == clip.id }) else { return nil }
        job.project.tracks[ti].clips[ci] = c
        guard let layer = job.layers(at: mid.snapped(to: project.settings.frameRate)).first(where: { $0.clipID == clip.id }) else { return nil }
        return box(layer, job: job, renderer: renderer)
    }

    static func box(_ layer: VideoLayer, job: RenderJob, renderer: VideoRenderer?) -> [Double] {
        layer.box(width: job.width, height: job.height, content: content(layer, job: job, renderer: renderer))
    }

    /// Size of a generated layer's content at the job's output width (titles, stickers); nil for pictures.
    static func content(_ layer: VideoLayer, job: RenderJob, renderer: VideoRenderer?) -> (Double, Double)? {
        if case .title(let t) = layer.source {
            let r = renderer ?? EstimateRenderer()
            return (try? r.titleBox(t, outputWidth: job.width)) ?? (try? EstimateRenderer().titleBox(t, outputWidth: job.width))
        }
        if case .sticker(let s) = layer.source {
            let k = Double(job.width) / SafeZones.referenceWidth
            return (s.box * k, s.box * k)
        }
        return nil
    }
}

/// Title size estimate when the host has no Core Text renderer.
struct EstimateRenderer: VideoRenderer {
    func export(_ job: RenderJob, audio: URL?, to output: URL, bitrate: Int) throws -> ExportReport { throw CommandError(.io, "no renderer") }
    func renderFrames(_ job: RenderJob, at times: [MediaTime], to outputs: [URL]) throws { throw CommandError(.io, "no renderer") }
    func captionLayout(_ job: RenderJob) throws -> [[[Double]]] { [] }
    func captionStates(_ job: RenderJob, downscale: Int) throws -> [CaptionRaster] { [] }
    func writeCaptionImages(_ job: RenderJob, to directory: URL) throws -> [URL] { [] }
}

extension AnimationPreset {
    /// Entrance keyframes of `a` followed by the exit keyframes of `b`.
    public static func combined(in a: AnimationPreset?, out b: AnimationPreset?, rest: Transform, duration: MediaTime,
                                inDuration: Double?, outDuration: Double?) -> [Keyframe]? {
        if a == .kenBurns || b == .kenBurns { return AnimationPreset.kenBurns.keyframes(rest: rest, duration: duration) }
        let first = (a ?? .none) == .none ? nil : a!.keyframes(rest: rest, duration: duration, inDuration: inDuration, outDuration: 0)
        let last = (b ?? .none) == .none ? nil : b!.keyframes(rest: rest, duration: duration, inDuration: 0, outDuration: outDuration)
        guard var out = first else { return last }
        guard let last else { return out }
        // Entrance [from@0, rest@tin] + exit [rest@0, rest@(d−tout), to@d] without the exit's leading rest keys.
        let tail = last.filter { $0.time > out.last!.time }
        if tail.first?.transform != rest { out[out.count - 1].easing = last.first(where: { $0.transform == rest && $0.easing != nil })?.easing ?? .easeIn }
        return out + tail
    }
}

// MARK: - Commands

enum OverlayAdd: Command {
    static let id = "overlay.add"
    static let summary = "Put a picture over the video: a still (PNG/JPG, SVG rasterized), a PNG sequence with alpha (folder or %04d pattern: Blender, HyperFrames), an alpha video (ProRes 4444 / HEVC-alpha / VP9-alpha, decoded to RGBA frames) or a full-frame insert (fullFrame: true, e.g. an AI B-roll shot that replaces the picture for a moment). Imports the file, places it on an overlay track (one is created; overlays sit under titles), with position (band / position / top), scale, opacity, blend mode and entrance/exit animation presets. Captions are always drawn on top. Returns the clip, its asset and its box with layout warnings."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("path", .string, "Image, SVG, folder of numbered PNGs, %04d pattern, or video."),
        .required("start", .time, "Timeline start."),
        .optional("duration", .time, "Seconds on screen (default: the media length; stills 3 s)."),
        .optional("end", .time, "Timeline end instead of duration."),
        .optional("sourceIn", .time, "Start inside a video/sequence (default 0)."),
        .optional("fullFrame", .boolean, "Fill the whole frame (cropped to 9:16) instead of keeping the native size: inserts."),
        .optional("fit", .oneOf(["native", "contain", "fill"]), "native (own pixel size at 1080 wide), contain (whole picture fitted in the frame) or fill (= fullFrame)."),
        .optional("blend", .oneOf(BlendMode.names), "normal (default), screen (light leaks, glows on black), multiply (paper textures)."),
        .optional("alpha", .boolean, "Force (true) or skip (false) alpha decoding of a video; detected from the pixel format by default."),
        .optional("svgWidth", .integer, "Raster width of an SVG, px (default 1080)."),
        .optional("trackId", .string, "Overlay track to use (default: a free overlay track, created if needed)."),
        .optional("behindSubject", .boolean, "Draw it behind the speaker (between the background and the person; needs matte.track over its window)."),
    ] + Graphics.positionParams + Graphics.animationParams

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let assetID = try Graphics.importVisual(p.requiredString("path"), into: &project, &ctx, alpha: p.bool("alpha"),
                                                svgWidth: p.int("svgWidth") ?? 1080, command: id)
        let asset = project.asset(assetID)!
        let still = asset.image?.kind == .still
        let sourceIn = (p.time("sourceIn") ?? .zero)
        let available = still ? MediaTime(seconds: 3) : asset.duration - sourceIn
        guard available > .zero else { throw CommandError.invalid("\(id): sourceIn is past the end of \(asset.name)") }
        let (start, end) = try Graphics.range(p, project, defaultDuration: available)
        let length = end - start
        guard still || sourceIn + length <= asset.duration + MediaTime.frameDuration(at: project.settings.frameRate) else {
            throw CommandError.invalid("\(id): \(asset.name) has \(asset.duration.displaySeconds)s; \(length.displaySeconds)s from \(sourceIn.displaySeconds)s is too long")
        }
        let fit: Placement.Fit = p.bool("fullFrame") == true ? .fill : p.string("fit").flatMap(Placement.Fit.init(rawValue:)) ?? .native
        let video = asset.video!
        let (placement, rest) = try Graphics.place(p, size: (Double(video.width), Double(video.height)), defaultBand: nil, fit: fit)
        // Full-frame inserts get their own track ("inserts"), native-size overlays share "overlays" tracks.
        let t = try Graphics.track(fit == .fill ? "inserts" : "overlays", in: &project, start: start, end: end, preferred: p.string("trackId"))
        var clip = Clip(id: project.makeID("c"), assetID: assetID, sourceIn: sourceIn, sourceOut: sourceIn + length, start: start)
        clip.placement = fit == .fill ? nil : placement
        clip.transform = rest == Transform() ? nil : rest
        clip.blend = p.string("blend").flatMap(BlendMode.init(rawValue:)).flatMap { $0 == .normal ? nil : $0 }
        clip.keyframes = Graphics.animate(p, rest: rest, duration: length)
        if p.bool("behindSubject") == true { clip.behindSubject = true }
        project.tracks[t].clips.append(clip)
        project.tracks[t].sortClips()
        ctx.project = project
        var result: [String: JSONValue] = ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id),
                                           "asset": ProjectState.summary(of: asset)]
        if fit != .fill, let box = Graphics.restBox(clip, track: project.tracks[t], project: project, renderer: ctx.services.renderer) {
            result["box"] = Graphics.boxJSON(box)
            result["warnings"] = .array(Graphics.zoneWarnings(box, project: project, what: "overlay") + Matte.warnings(clip, project))
        } else if clip.behindSubject == true {
            result["warnings"] = .array(Matte.warnings(clip, project))
        }
        return .object(result)
    }
}

enum ClipKeyframe: Command {
    static let id = "clip.keyframe"
    static let summary = "Animate a clip's transform: apply an entrance/exit preset (pop, slideUp, slideDown, fade, kenBurns, none = remove) or set explicit keyframes with easing ({time (s from the clip start), scale, x, y, rotation, opacity, crop, easing: linear|easeIn|easeOut|easeInOut|expoOut|backOut|hold|spring — the curve towards the next keyframe}). The clip's static transform is the resting state. Returns the clip."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("clipId", .string, "Clip."),
        .optional("clipIds", .array(.string), "Several clips."),
        .optional("preset", .oneOf(AnimationPreset.names), "Entrance and exit preset (or animIn/animOut separately)."),
        .optional("keyframes", .array(.object), "Explicit keyframes (replace existing ones)."),
    ] + Graphics.animationParams

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        var ids = p.strings("clipIds") ?? []
        if let one = p.string("clipId") { ids.append(one) }
        guard !ids.isEmpty else { throw CommandError.invalid("\(id): pass clipId or clipIds") }
        var out: [JSONValue] = []
        for cid in ids {
            let (t, c) = try Timeline.locate(clip: cid, in: project)
            var clip = project.tracks[t].clips[c]
            let rest = clip.transform ?? Transform()
            if let ks = p.json("keyframes")?.arrayValue {
                clip.keyframes = try ClipSet.keyframes(ks, rest: rest, video: project.asset(clip.assetID)?.video, clip: cid, command: id)
            } else if let preset = p.string("preset").flatMap(AnimationPreset.init(rawValue:)) {
                clip.keyframes = AnimationPreset.combined(in: preset, out: preset == .kenBurns ? AnimationPreset.none : preset, rest: rest,
                                                          duration: clip.duration, inDuration: p.number("inDuration"), outDuration: p.number("outDuration"))
            } else if p.has("animIn") || p.has("animOut") {
                clip.keyframes = Graphics.animate(p, rest: rest, duration: clip.duration)
            } else {
                throw CommandError.invalid("\(id): pass preset, animIn/animOut or keyframes")
            }
            project.tracks[t].clips[c] = clip
            out.append(ProjectState.summary(of: clip))
        }
        ctx.project = project
        return ["clips": .array(out)]
    }
}

enum TitleAdd: Command {
    static let id = "title.add"
    static let summary = "Add a text layer drawn with Core Text by the compositor: a hook title, a kicker label, a card, a stat, a chip. Start from a brand-kit preset (brandkit.apply first; wesites presets: hook, hookLight, question, kicker, card, stat, chipOK, chipWarn, word) and override font, size, colour, box/pill background, outline, shadow, alignment, wrap width, highlighted words. Placed in a band (top by default: y 110–640; never the caption band) with entrance/exit presets (default pop in, fade out). Returns the clip, its box (pixels) and layout warnings."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("text", .string, "Text; \\n starts a new line."),
        .required("start", .time, "Timeline start."),
        .optional("duration", .time, "Seconds on screen (default 2.5)."),
        .optional("end", .time, "Timeline end instead of duration."),
        .optional("preset", .string, "Title preset of the applied brand kit (e.g. hook, kicker, card, question)."),
        .optional("font", .string, "Font role of the kit (display, text, mono), a font name, or a .ttf/.otf/.woff2 file."),
        .optional("size", .number, "Font size, px at 1080 wide."),
        .optional("color", .string, "Text colour (#RRGGBB or a kit colour role)."),
        .optional("uppercase", .boolean, "Draw in capitals."),
        .optional("align", .oneOf(["left", "center", "right"]), "Line alignment (default center)."),
        .optional("maxWidth", .number, "Wrap width, px (box included)."),
        .optional("highlight", .array(.string), "Words drawn in highlightColor."),
        .optional("highlightColor", .string, "Colour of the highlighted words."),
        .optional("background", .oneOf(["none", "box", "pill"]), "Shape behind the text."),
        .optional("backgroundColor", .string, "Its colour."),
        .optional("padding", .array(.number), "[x, y] padding of the box, px."),
        .optional("radius", .number, "Box corner radius, px."),
        .optional("strokeColor", .string, "Outline colour."),
        .optional("strokeWidth", .number, "Outline width, px (0 = none)."),
        .optional("shadow", .boolean, "Soft drop shadow (default: the preset's)."),
        .optional("trackId", .string, "Track (default: the Titles overlay track, created if needed)."),
        .optional("behindSubject", .boolean, "Text behind the person: drawn between the background and the speaker, so the head can pass in front of big type (the hook title, once per reel). Needs matte.track over its window; a full-frame insert under it shows the text normally."),
    ] + Graphics.positionParams + Graphics.animationParams

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let kit = project.brand
        var title: Title
        var presetName: String?
        if let name = p.string("preset") {
            guard let kit else { throw CommandError.conflict("\(id): preset \"\(name)\" needs a brand kit: call brandkit.apply first") }
            guard let preset = kit.titles[name] else {
                throw CommandError.invalid("\(id): kit \(kit.id) has no preset \"\(name)\" (presets: \(kit.titles.keys.sorted().joined(separator: ", ")))")
            }
            title = preset
            presetName = name
        } else if let hook = kit?.titles["hook"] {
            title = hook
            presetName = "hook"
        } else {
            title = Title(text: "", font: "Helvetica-Bold", size: 72, color: "#FFFFFF")
            title.shadow = TitleShadow()
        }
        title.text = p.requiredString("text").replacingOccurrences(of: "\\n", with: "\n")
        guard !title.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommandError.invalid("\(id): text is empty") }
        if let v = p.string("font") { title.font = v }
        if let v = p.number("size") { guard v > 0 else { throw CommandError.invalid("\(id): size must be > 0") }; title.size = v }
        if let v = p.string("color") { title.color = v }
        if let v = p.bool("uppercase") { title.uppercase = v }
        if let v = p.string("align") { title.align = v }
        if let v = p.number("maxWidth") { title.maxWidth = v }
        if let v = p.strings("highlight") { title.highlight = v }
        if let v = p.string("highlightColor") { title.highlightColor = v }
        if let v = p.string("background") {
            if v == "none" { title.background = nil }
            else { title.background = TitleBackground(kind: v, color: title.background?.color ?? "#000000", padX: title.background?.padX ?? 40,
                                                      padY: title.background?.padY ?? 20, radius: title.background?.radius) }
        }
        if let v = p.string("backgroundColor") {
            if title.background == nil { title.background = TitleBackground(kind: "pill", color: v) } else { title.background?.color = v }
        }
        if let pad = p.numbers("padding") {
            guard pad.count == 2 else { throw CommandError.invalid("\(id): padding is [x, y]") }
            title.background?.padX = pad[0]; title.background?.padY = pad[1]
        }
        if let r = p.number("radius") { title.background?.radius = r }
        if let w = p.number("strokeWidth") { title.stroke = w > 0 ? TitleStroke(color: p.string("strokeColor") ?? title.stroke?.color ?? "#000000", width: w) : nil }
        else if let c = p.string("strokeColor") { title.stroke = TitleStroke(color: c, width: title.stroke?.width ?? 6) }
        if let s = p.bool("shadow") { title.shadow = s ? (title.shadow ?? TitleShadow()) : nil }
        if let kit { title = kit.resolve(title) }
        // Hand-styled titles keep their look when another kit is applied.
        let styleParams = ["font", "size", "color", "uppercase", "align", "maxWidth", "highlightColor", "background", "backgroundColor",
                           "padding", "radius", "strokeColor", "strokeWidth", "shadow"]
        if styleParams.contains(where: p.has) { presetName = nil }

        let (start, end) = try Graphics.range(p, project, defaultDuration: MediaTime(seconds: 2.5))
        let k = Double(project.settings.width) / SafeZones.referenceWidth
        let size = (try? (ctx.services.renderer ?? EstimateRenderer()).titleBox(title, outputWidth: project.settings.width)).map { ($0.width / k, $0.height / k) } ?? (600, 120)
        let (placement, rest) = try Graphics.place(p, size: size, defaultBand: "top", fit: .native)
        let t = try Graphics.track("titles", in: &project, start: start, end: end, preferred: p.string("trackId"))
        var clip = Clip(id: project.makeID("c"), assetID: "", sourceIn: .zero, sourceOut: end - start, start: start)
        clip.title = title
        clip.titlePreset = presetName
        clip.placement = placement
        clip.transform = rest == Transform() ? nil : rest
        // Default motion: pop in, fade out.
        let a = p.string("animIn").flatMap(AnimationPreset.init(rawValue:)) ?? .pop
        let b = p.string("animOut").flatMap(AnimationPreset.init(rawValue:)) ?? (p.has("animIn") ? a : .fade)
        clip.keyframes = AnimationPreset.combined(in: a, out: b, rest: rest, duration: end - start,
                                                  inDuration: p.number("inDuration"), outDuration: p.number("outDuration"))
        if p.bool("behindSubject") == true { clip.behindSubject = true }
        project.tracks[t].clips.append(clip)
        project.tracks[t].sortClips()
        ctx.project = project
        var result: [String: JSONValue] = ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id)]
        if let box = Graphics.restBox(clip, track: project.tracks[t], project: project, renderer: ctx.services.renderer) {
            result["box"] = Graphics.boxJSON(box)
            result["warnings"] = .array(Graphics.zoneWarnings(box, project: project, what: "title") + Matte.warnings(clip, project))
        }
        return .object(result)
    }
}

enum EffectAdd: Command {
    static let id = "effect.add"
    static let summary = "Add a keyframable Core Image effect to a clip over a window (timeline times): lut (.cube file), blur, glow, vignette, sharpen, punchZoom (zoom bump on a beat, default 1.12×), shake (hand-held), flash (the frame washes to white/colour), glitch (RGB split + jittering blocks; a few frames on a hard cut, never a whole sentence), chromaKey (green/blue screen on an overlay clip: color, tolerance, spill). Strength = amount with attack/release ramps, or explicit keyframes [{time, value, easing}]. Use sparingly: one punch or flash on a strong beat, not on every line. Returns the effect id and the clip."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("kind", .oneOf(Effect.names), "Effect."),
        .optional("clipId", .string, "Clip (or trackId + at)."),
        .optional("trackId", .string, "Track whose clip at `at` (or `start`) gets the effect."),
        .optional("at", .time, "Timeline time used with trackId to find the clip."),
        .optional("start", .time, "Timeline start of the effect (default: the clip start)."),
        .optional("end", .time, "Timeline end (default: the clip end)."),
        .optional("amount", .number, "Peak strength 0…1 (default 1; flash 0.8)."),
        .optional("attack", .number, "Ramp in, seconds (punchZoom default 0.08)."),
        .optional("release", .number, "Ramp out, seconds (punchZoom default 0.25)."),
        .optional("easing", .oneOf(Easing.names), "Ramp curve (default easeOut)."),
        .optional("keyframes", .array(.object), "Strength curve [{time (timeline s), value, easing}] instead of amount/attack/release."),
        .optional("radius", .number, "blur/glow/sharpen radius px at 1080 wide; vignette size (0…1)."),
        .optional("zoom", .number, "punchZoom peak scale (default 1.12)."),
        .optional("path", .string, "lut: the .cube file."),
        .optional("color", .string, "flash colour (default #FFFFFF); chromaKey key colour (default #00FF00)."),
        .optional("frequency", .number, "shake Hz (default 7); glitch pattern changes per second (default 12)."),
        .optional("tolerance", .number, "chromaKey: width of the keyed colour range 0…1 (default 0.4)."),
        .optional("spill", .number, "chromaKey: key-colour fringe removed from the kept pixels 0…1 (default 0.5)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let rate = project.settings.frameRate
        let loc: (track: Int, clip: Int)
        if let cid = p.string("clipId") { loc = try Timeline.locate(clip: cid, in: project) }
        else if let tid = p.string("trackId"), let at = p.time("at") ?? p.time("start") {
            let t = try Timeline.trackIndex(tid, in: project)
            let at = at.snapped(to: rate)
            guard let c = project.tracks[t].clips.firstIndex(where: { $0.start <= at && at < $0.end }) else {
                throw CommandError.notFound("\(id): no clip of \(tid) at \(at.displaySeconds)s")
            }
            loc = (t, c)
        } else { throw CommandError.invalid("\(id): pass clipId, or trackId with at") }
        var clip = project.tracks[loc.track].clips[loc.clip]
        let kind = Effect.Kind(rawValue: p.requiredString("kind"))!
        var e = Effect(id: project.makeID("fx"), kind: kind, amount: min(max(p.number("amount") ?? (kind == .flash ? 0.8 : 1), 0), 4))
        func local(_ t: MediaTime) -> MediaTime { min(max(t.snapped(to: rate) - clip.start, .zero), clip.duration) }
        if let s = p.time("start") { e.start = local(s) }
        if let s = p.time("end") { e.end = local(s) }
        if let a = e.start, let b = e.end, b <= a { throw CommandError.invalid("\(id): end must be after start (inside clip \(clip.id))") }
        e.attack = p.number("attack") ?? (kind == .punchZoom ? 0.08 : kind == .flash ? 0.03 : nil)
        e.release = p.number("release") ?? (kind == .punchZoom ? 0.25 : kind == .flash ? 0.2 : nil)
        e.easing = p.string("easing").flatMap(Easing.init(rawValue:))
        e.radius = p.number("radius")
        e.zoom = p.number("zoom")
        e.color = p.string("color")
        e.frequency = p.number("frequency")
        e.tolerance = p.number("tolerance").map { min(max($0, 0), 1) }
        e.spill = p.number("spill").map { min(max($0, 0), 1) }
        if kind == .chromaKey, e.color == nil { e.color = "#00FF00" }
        if kind == .lut {
            guard let path = p.string("path") else { throw CommandError.invalid("\(id): lut needs path (.cube)") }
            let full = URL(fileURLWithPath: EngineConfig.expand(path)).standardizedFileURL.path
            _ = try CubeLUT.load(full)
            e.path = full
        }
        if let ks = p.json("keyframes")?.arrayValue {
            e.keyframes = try ks.map { k in
                guard let o = k.objectValue, let t = o["time"]?.doubleValue, let v = o["value"]?.doubleValue else {
                    throw CommandError.invalid("\(id): keyframes are {time, value, easing?}")
                }
                return ScalarKey(time: local(MediaTime(seconds: t)), value: v, easing: o["easing"]?.stringValue.flatMap(Easing.init(rawValue:)))
            }.sorted { $0.time < $1.time }
        }
        clip.effects = (clip.effects ?? []) + [e]
        project.tracks[loc.track].clips[loc.clip] = clip
        ctx.project = project
        return ["effectId": .string(e.id), "clip": ProjectState.summary(of: clip)]
    }
}

enum EffectRemove: Command {
    static let id = "effect.remove"
    static let summary = "Remove one effect (effectId) or all effects of a clip. Returns the clip."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("clipId", .string, "Clip."),
        .optional("effectId", .string, "Effect id from effect.add (default: all)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let (t, c) = try Timeline.locate(clip: p.requiredString("clipId"), in: project)
        var clip = project.tracks[t].clips[c]
        if let e = p.string("effectId") {
            guard clip.effects?.contains(where: { $0.id == e }) == true else { throw CommandError.notFound("\(id): clip \(clip.id) has no effect \(e)") }
            clip.effects?.removeAll { $0.id == e }
        } else { clip.effects = nil }
        if clip.effects?.isEmpty == true { clip.effects = nil }
        project.tracks[t].clips[c] = clip
        ctx.project = project
        return ["clip": ProjectState.summary(of: clip)]
    }
}

enum TransitionRemove: Command {
    static let id = "transition.remove"
    static let summary = "Remove a transition (transitionId from transition.add or project.state). Returns the remaining count."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [.required("transitionId", .string, "Transition id.")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let tid = p.requiredString("transitionId")
        guard let i = project.transitions?.firstIndex(where: { $0.id == tid }) else { throw CommandError.notFound("\(id): no transition \(tid)") }
        project.transitions?.remove(at: i)
        if project.transitions?.isEmpty == true { project.transitions = nil }
        ctx.project = project
        return ["remaining": .number(Double(project.transitions?.count ?? 0))]
    }
}

enum TransitionAdd: Command {
    static let id = "transition.add"
    static let summary = "Add a frame-wide transition at a cut: flash (white wash peaking on the cut, 0.2 s), whip (the picture flies out and the next one in with motion blur, 0.3 s) dip (through black, 0.5 s) or blur (the picture defocuses into the cut and the next shot comes back into focus, 0.6 s; also into or out of a full-frame graphic). Anchor it to a clip edge (clipId + edge: it follows later edits) or a timeline time. Captions are not affected. Taste: one or two per reel, on real section changes. Returns the transition."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("kind", .oneOf(Transition.names), "flash, whip, dip or blur."),
        .optional("at", .time, "Cut time on the timeline."),
        .optional("clipId", .string, "Anchor clip (its start, or its end with edge: end)."),
        .optional("edge", .oneOf(["start", "end"]), "Edge of clipId (default start)."),
        .optional("duration", .time, "Total length centred on the cut (defaults: flash 0.2, whip 0.3, dip 0.5, blur 0.6)."),
        .optional("direction", .oneOf(["left", "right", "up", "down"]), "whip: where the picture leaves to (default left)."),
        .optional("color", .string, "flash colour (default #FFFFFF)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let kind = Transition.Kind(rawValue: p.requiredString("kind"))!
        let def = switch kind { case .flash: 0.2; case .whip: 0.3; case .dip: 0.5; case .blur: 0.6 }
        var tr = Transition(id: project.makeID("tr"), kind: kind, at: .zero, duration: p.time("duration") ?? MediaTime(seconds: def))
        guard tr.duration > .zero else { throw CommandError.invalid("\(id): duration must be > 0") }
        if let cid = p.string("clipId") {
            _ = try Timeline.locate(clip: cid, in: project)
            tr.clipID = cid
            tr.edge = p.string("edge") ?? "start"
        } else if let at = p.time("at") {
            tr.at = at.snapped(to: project.settings.frameRate)
        } else { throw CommandError.invalid("\(id): pass at, or clipId (+ edge)") }
        tr.at = tr.time(in: project)
        tr.direction = p.string("direction")
        tr.color = p.string("color")
        project.transitions = (project.transitions ?? []) + [tr]
        ctx.project = project
        return ["transition": ["id": .string(tr.id), "kind": .string(kind.rawValue), "at": ProjectState.seconds(tr.at),
                               "duration": ProjectState.seconds(tr.duration)]]
    }
}

enum GraphicsCheckLayout: Command {
    static let id = "graphics.checkLayout"
    static let summary = "Check the graphics layout frame by frame: every title and native-size overlay box (animations included) against the caption band (1230–1460 on 1080×1920: must stay clean) and the Instagram zones (top 110, bottom 1540, right 120 px: warnings). Full-frame inserts are skipped (captions draw over them). Returns pass (caption band clear), per-clip extents and the violations."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("step", .integer, "Check every n-th frame (default 1)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: false)
        let rate = project.settings.frameRate
        let frame = MediaTime.frameDuration(at: rate)
        let step = max(p.int("step") ?? 1, 1)
        let (c0, c1) = SafeZones.captionBand(height: job.height)
        let k = Double(job.height) / SafeZones.referenceHeight
        var extents: [String: [Double]] = [:], kinds: [String: String] = [:]
        var band: [String: (Double, Double)] = [:]
        var zones: [String: Set<String>] = [:]
        var boxCache: [Title: (Double, Double)] = [:]
        for f in stride(from: 0, to: job.frameCount, by: step) {
            let t = MediaTime(ticks: frame.ticks * Int64(f))
            for layer in job.layers(at: t) where layer.placement != nil && layer.placement?.fit != .fill && layer.opacity > 0.01 {
                var content: (Double, Double)?
                if case .title(let title) = layer.source {
                    if boxCache[title] == nil { boxCache[title] = (try? (ctx.services.renderer ?? EstimateRenderer()).titleBox(title, outputWidth: job.width)) ?? (0, 0) }
                    content = boxCache[title]
                    kinds[layer.clipID] = "title"
                } else if case .sticker(let s) = layer.source {
                    content = (s.box * Double(job.width) / SafeZones.referenceWidth, s.box * Double(job.width) / SafeZones.referenceWidth)
                    kinds[layer.clipID] = "sticker"
                } else { kinds[layer.clipID] = "overlay" }
                let b = layer.box(width: job.width, height: job.height, content: content)
                let e = extents[layer.clipID] ?? [b[0], b[1], b[0] + b[2], b[1] + b[3]]
                extents[layer.clipID] = [min(e[0], b[0]), min(e[1], b[1]), max(e[2], b[0] + b[2]), max(e[3], b[1] + b[3])]
                if b[1] < c1 && b[1] + b[3] > c0 {
                    let r = band[layer.clipID] ?? (t.seconds, t.seconds)
                    band[layer.clipID] = (min(r.0, t.seconds), max(r.1, t.seconds))
                }
                if b[1] < SafeZones.topLimit * k { zones[layer.clipID, default: []].insert("top") }
                if b[1] + b[3] > SafeZones.bottomLimit * k { zones[layer.clipID, default: []].insert("bottom") }
                if b[0] + b[2] > Double(job.width) - SafeZones.rightMargin * Double(job.width) / SafeZones.referenceWidth { zones[layer.clipID, default: []].insert("right") }
            }
        }
        let violations: [JSONValue] = band.keys.sorted().map { cid in
            ["clipId": .string(cid), "kind": .string(kinds[cid] ?? "?"), "from": .number(band[cid]!.0), "to": .number(band[cid]!.1)]
        }
        let clips: [JSONValue] = extents.keys.sorted().map { cid in
            let e = extents[cid]!
            return ["clipId": .string(cid), "kind": .string(kinds[cid] ?? "?"), "extent": Graphics.boxJSON(e),
                    "zones": .array((zones[cid] ?? []).sorted().map { .string($0) })]
        }
        return ["pass": .bool(band.isEmpty), "captionBand": .array([.number(c0), .number(c1)]), "checked": .number(Double(extents.count)),
                "clips": .array(clips), "violations": .array(violations),
                "zoneWarnings": .number(Double(zones.values.map(\.count).reduce(0, +)))]
    }
}
