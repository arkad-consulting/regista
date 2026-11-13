import Foundation

// Screen + camera recordings (issue #6): a session folder becomes a timeline (recording.import), layouts put the
// face where it belongs on a time range (layout.apply, layout.presets), and clicks become smooth zooms
// (edit.autoZoom).

public enum Recording {
    /// The role of the key badges' overlay track (keys.overlay).
    public static let keysTrackRole = "keys"

    static let roles = ["screen": "Schermo", "camera": "Camera", "mic": "Microfono", "system": "Audio di sistema"]

    static func link(_ p: CommandParams, _ project: Project, command: String) throws -> (index: Int, link: RecordingLink) {
        guard let all = project.recordings, !all.isEmpty else {
            throw CommandError.conflict("\(command): no screen recording in this project: call recording.import first")
        }
        if let id = p.string("recordingId") {
            guard let i = all.firstIndex(where: { $0.id == id }) else {
                throw CommandError.notFound("\(command): no recording '\(id)' (recordings: \(all.map(\.id).joined(separator: ", ")))")
            }
            return (i, all[i])
        }
        return (all.count - 1, all[all.count - 1])
    }

    static let recordingParam = ParamSpec.optional("recordingId", .string, "Recording (default: the last imported).")

    /// After the screen box changed (a new layout, a new output format): the recording's automatic zoom and the key
    /// badges are computed again with the options they were made with, inside the same command (one undo step).
    static func refreshDerived(link index: Int, _ ctx: inout CommandContext) throws {
        guard let link = ctx.project?.recordings?[index] else { return }
        if var zoom = link.autoZoom {
            zoom["recordingId"] = .string(link.id)
            _ = try EditAutoZoom.run(try CommandParams(validating: .object(zoom), for: EditAutoZoom.descriptor), &ctx)
        }
        if ctx.project?.tracks.contains(where: { $0.role == KeysOverlay.role && $0.kind == .overlay }) == true,
           link.keys != nil || index == (ctx.project?.recordings?.count ?? 0) - 1 {
            var keys = link.keys ?? [:]
            keys["recordingId"] = .string(link.id)
            _ = try KeysOverlay.run(try CommandParams(validating: .object(keys), for: KeysOverlay.descriptor), &ctx)
        }
    }

    /// (track, clip) of every clip of `asset` on the picture tracks, in timeline order.
    public static func clips(of asset: String?, in project: Project) -> [(track: Int, clip: Int)] {
        guard let asset else { return [] }
        var out: [(Int, Int)] = []
        for (t, track) in project.tracks.enumerated() where track.kind == .video || track.kind == .overlay {
            for (c, clip) in track.clips.enumerated() where clip.assetID == asset { out.append((t, c)) }
        }
        return out.sorted { project.tracks[$0.0].clips[$0.1].start < project.tracks[$1.0].clips[$1.1].start }
    }

    /// Timeline extent of the recording's picture clips.
    public static func extent(_ link: RecordingLink, _ project: Project) -> (MediaTime, MediaTime)? {
        let all = (clips(of: link.screen, in: project) + clips(of: link.camera, in: project)).map { project.tracks[$0.track].clips[$0.clip] }
        guard let a = all.map(\.start).min(), let b = all.map(\.end).max() else { return nil }
        return (a, b)
    }

    /// Cuts every clip of the recording's assets that strictly contains `at` (the right parts of clips that shared a
    /// link share a new one, like timeline.cut).
    static func cut(_ link: RecordingLink, at: MediaTime, _ project: inout Project) {
        let assets = Set([link.screen, link.camera, link.mic, link.system].compactMap { $0 })
        var newLinks: [String: String] = [:]
        for t in project.tracks.indices where !project.tracks[t].locked {
            guard let c = project.tracks[t].clips.firstIndex(where: { assets.contains($0.assetID) && $0.start < at && at < $0.end }) else { continue }
            let clip = project.tracks[t].clips[c]
            var (left, right) = clip.split(at: at - clip.start, rightID: project.makeID("c"))
            if let l = left.link {
                if newLinks[l] == nil { newLinks[l] = project.makeID("l") }
                right.link = newLinks[l]
            }
            project.tracks[t].clips[c] = left
            project.tracks[t].clips.insert(right, at: c + 1)
        }
    }

    /// The face box of the camera over the source window it shows in [from, to) (faces.track sidecar), nil when
    /// the camera was not face-tracked.
    static func face(camera asset: MediaAsset, in project: Project, from: MediaTime, to: MediaTime) -> [Double]? {
        guard let path = asset.analysis?.faces?.path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let track = try? JSONDecoder().decode(FaceTrack.self, from: data) else { return nil }
        var lo = Double.infinity, hi = -Double.infinity
        for (t, c) in clips(of: asset.id, in: project) {
            let clip = project.tracks[t].clips[c]
            guard clip.start < to, from < clip.end else { continue }
            lo = min(lo, (clip.sourceIn + (max(clip.start, from) - clip.start)).seconds)
            hi = max(hi, (clip.sourceIn + (min(clip.end, to) - clip.start)).seconds)
        }
        return lo < hi ? Layouts.medianFace(track, from: lo, to: hi) : Layouts.medianFace(track, from: 0, to: .infinity)
    }

    /// The layout spec from the params (preset + options).
    static func spec(_ p: CommandParams, kind: String?) throws -> LayoutSpec? {
        guard let k = kind else { return nil }
        guard let kind = LayoutSpec.Kind(rawValue: k) else {
            throw CommandError.invalid("layout: unknown preset \"\(k)\" (presets: \(LayoutSpec.Kind.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        let s = LayoutSpec(kind: kind, corner: p.string("corner"), shape: p.string("shape"), size: p.string("size"), side: p.string("side"),
                           frame: try frame(p))
        try s.validate()
        return s
    }

    /// The styled frame from the params: `frame: true` or any of its options; nil when none is given (or frame: false).
    static func frame(_ p: CommandParams) throws -> ScreenFrame? {
        let options = ["background", "gradient", "gradientKind", "angle", "padding", "radius", "shadow"]
        if p.bool("frame") == false { return nil }
        guard p.bool("frame") == true || options.contains(where: p.has) else { return nil }
        var f = ScreenFrame(padding: p.number("padding"), radius: p.number("radius"), shadow: p.number("shadow"))
        if let colors = p.strings("gradient") {
            let kind: Backdrop.Kind = p.string("gradientKind") == "radial" ? .radial : .linear
            f.background = Backdrop(kind: kind, colors: colors.map { $0.uppercased() }, angle: kind == .linear ? (p.number("angle") ?? 180) : nil,
                                    center: kind == .radial ? [0.5, 0.4] : nil)
        } else if let b = p.string("background"), b != "brand" {
            if let preset = Backdrop.preset(b) {
                f.background = preset
                if let a = p.number("angle"), preset.kind == .linear { f.background?.angle = a }
            } else if b.hasPrefix("#") {
                f.background = Backdrop(kind: .solid, colors: [b.uppercased()])
            } else {
                let path = URL(fileURLWithPath: EngineConfig.expand(b)).standardizedFileURL.path
                guard FileManager.default.fileExists(atPath: path) else {
                    throw CommandError.notFound("layout: background \"\(b)\" is neither a preset (\(Backdrop.presetNames.joined(separator: ", ")), brand), a #RRGGBB colour nor an image file")
                }
                f.background = Backdrop(kind: .image, path: path)
            }
        }
        return f
    }

    static let layoutParams: [ParamSpec] = [
        .optional("corner", .oneOf(LayoutSpec.corners), "bubble: corner of the face (default bottomRight); cutout: bottomLeft or bottomRight."),
        .optional("shape", .oneOf(LayoutSpec.shapes), "bubble: circle (default) or rounded (rounded square)."),
        .optional("size", .oneOf(LayoutSpec.sizes), "bubble / cutout: S, M (default) or L."),
        .optional("side", .oneOf(LayoutSpec.sides), "split: face on the right (default) or left; stack: face at the bottom (default) or top."),
        .optional("frame", .boolean, "screen / bubble: a styled frame — the whole screen (never cropped) on a background with padding, rounded corners and a soft shadow. Implied by any of the frame options below; false removes it."),
        .optional("background", .string, "Frame background: a built-in gradient (\(Backdrop.presetNames.joined(separator: ", ")); layout.presets describes them), brand (the applied kit's colours: the default when a kit is applied, else graphite), a colour #RRGGBB, or an image file (aspect fill)."),
        .optional("gradient", .array(.string), "Frame background: a custom gradient of 2–3 colours #RRGGBB (instead of background)."),
        .optional("gradientKind", .oneOf(["linear", "radial"]), "Custom gradient: linear (default) or radial (from the centre)."),
        .optional("angle", .number, "Linear gradient direction, degrees: 0 towards the top, 90 towards the right, 180 towards the bottom (default)."),
        .optional("padding", .number, "Frame: space around the screen, fraction of the frame's shorter side (default 0.06; 0–0.3)."),
        .optional("radius", .number, "Frame: screen corner radius, fraction of the frame's shorter side (default 0.016; 0 = square corners)."),
        .optional("shadow", .number, "Frame: opacity of the soft shadow under the screen, 0–1 (default 0.5; 0 = none)."),
    ]

    /// Keyframes bringing the face of `clip` in after `prev`: a glide when both have the same shape and size (another
    /// corner), a short pop when the shape changes; nil when either is hidden.
    static func entrance(from prev: Clip, to clip: Clip, _ transition: Double) -> [Keyframe]? {
        let tr = clip.transform ?? Transform()
        guard tr.opacity > 0, (prev.transform ?? Transform()).opacity > 0 else { return nil }
        let before = prev.transform(at: prev.duration)
        if prev.placement?.fit == clip.placement?.fit, prev.placement?.width == clip.placement?.width,
           prev.placement?.height == clip.placement?.height, prev.mask?.shape == clip.mask?.shape, prev.mask?.cutout == clip.mask?.cutout {
            guard prev.placement != clip.placement || before.cropLeft != tr.cropLeft || before.cropTop != tr.cropTop else { return nil }
            var start = before
            start.x += (prev.placement?.x ?? 0.5) - (clip.placement?.x ?? 0.5)
            start.y += (prev.placement?.y ?? 0.5) - (clip.placement?.y ?? 0.5)
            return [Keyframe(time: .zero, transform: start, easing: .easeInOut), Keyframe(time: MediaTime(seconds: min(transition, clip.duration.seconds / 2)), transform: tr)]
        }
        var start = tr
        start.scale = 0.9
        start.opacity = 0
        return [Keyframe(time: .zero, transform: start, easing: .expoOut), Keyframe(time: MediaTime(seconds: min(0.3, clip.duration.seconds / 2)), transform: tr)]
    }

    /// Writes `spec` on the recording's screen and camera clips over [from, to): cuts at the edges, sets placement,
    /// crop, mask and visibility; a switch between two layouts of the same shape moves the face, a switch to a new
    /// shape brings it in with a short pop. Returns the camera clips written.
    @discardableResult
    static func apply(_ spec: LayoutSpec, link index: Int, from: MediaTime, to: MediaTime, transition: Double,
                      _ project: inout Project) throws -> [String] {
        let link = project.recordings![index]
        cut(link, at: from, &project)
        cut(link, at: to, &project)
        let W = project.settings.width, H = project.settings.height
        let screenAsset = link.screen.flatMap { project.asset($0) }
        let cameraAsset = link.camera.flatMap { project.asset($0) }
        let sv = screenAsset?.video, cv = cameraAsset?.video
        let faceBox = cameraAsset.flatMap { Recording.face(camera: $0, in: project, from: from, to: to) }
        let g = Layouts.geometry(spec, width: W, height: H, screen: (sv?.width ?? W, sv?.height ?? H),
                                 camera: (cv?.width ?? 1080, cv?.height ?? 1920), face: faceBox)
        if let bg = g.background { project.settings.background = bg }
        if let f = spec.frame { project.settings.backdrop = f.resolvedBackground(kit: project.brand) }

        for (t, c) in clips(of: link.screen, in: project) {
            var clip = project.tracks[t].clips[c]
            guard clip.start >= from, clip.end <= to else { continue }
            clip.placement = g.screen.placement
            clip.mask = g.screen.mask
            var tr = clip.transform ?? Transform()
            (tr.scale, tr.x, tr.y, tr.rotation, tr.opacity) = (1, 0, 0, 0, g.screen.visible ? 1 : 0)
            clip.transform = tr == Transform() ? nil : tr
            // Zoom keyframes keep their crop; the rest follows the layout.
            clip.keyframes = clip.keyframes?.map { k in
                var k = k
                (k.transform.scale, k.transform.x, k.transform.y, k.transform.rotation, k.transform.opacity) = (1, 0, 0, 0, tr.opacity)
                return k
            }
            project.tracks[t].clips[c] = clip
        }
        var written: [String] = []
        for (t, c) in clips(of: link.camera, in: project) {
            var clip = project.tracks[t].clips[c]
            guard clip.start >= from, clip.end <= to, let cv else { continue }
            let previous = project.tracks[t].clips.last { $0.end == clip.start && $0.assetID == clip.assetID }
            var tr = g.camera.crop.map { Transform(crop: $0, sourceWidth: cv.width, sourceHeight: cv.height) } ?? Transform()
            tr.opacity = g.camera.visible ? 1 : 0
            clip.transform = tr
            clip.placement = g.camera.placement
            clip.mask = g.camera.mask
            clip.keyframes = nil
            if transition > 0, clip.start == from, let prev = previous { clip.keyframes = entrance(from: prev, to: clip, transition) }
            project.tracks[t].clips[c] = clip
            written.append(clip.id)
        }
        // The layout after the range comes back with the same kind of move.
        if transition > 0 {
            for (t, c) in clips(of: link.camera, in: project) {
                let clip = project.tracks[t].clips[c]
                guard clip.start == to, clip.keyframes == nil,
                      let prev = project.tracks[t].clips.last(where: { $0.end == clip.start && $0.assetID == clip.assetID }) else { continue }
                project.tracks[t].clips[c].keyframes = entrance(from: prev, to: clip, transition)
            }
        }
        var layouts = (project.recordings![index].layouts ?? []).compactMap { old -> [AppliedLayout] in
            // Keep what is outside the new range.
            var parts: [AppliedLayout] = []
            if old.from < from { parts.append(AppliedLayout(from: old.from, to: min(old.to, from), layout: old.layout)) }
            if old.to > to { parts.append(AppliedLayout(from: max(old.from, to), to: old.to, layout: old.layout)) }
            return parts
        }.flatMap { $0 }
        layouts.append(AppliedLayout(from: from, to: to, layout: spec))
        project.recordings![index].layouts = layouts.sorted { $0.from < $1.from }
        // The frame's background goes when no framed layout is left on any recording.
        if spec.frame == nil, !(project.recordings ?? []).contains(where: { ($0.layouts ?? []).contains { $0.layout.frame != nil } }) {
            project.settings.backdrop = nil
        }
        return written
    }
}

enum RecordingImport: Command {
    static let id = "recording.import"
    static let summary = "Turn a screen recording session (the folder Regista's Registra workspace or recording.synthesize writes: session.json + screen.mov, camera.mov, mic.wav) into a timeline: screen on a video track (Schermo), camera above it (Camera), mic on an audio track, all on the session's common clock (sub-frame offsets kept exactly) and linked, then the layout chosen at recording time (or `layout`) applied, including the switches made while recording. Camera and mic are optional: a screen-only take (no camera.mov) gets the `screen` layout. A take recorded without the system cursor (session cursorInVideo false) gets the cursor drawn by the compositor from the logged path (cursor.style). Returns the recording id, assets, tracks, the common window and the per-source offsets."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("path", .string, "session.json, or the session folder."),
        .optional("layout", .oneOf(LayoutSpec.Kind.allCases.map(\.rawValue)), "Layout over the whole recording (default: the one chosen when recording, else bubble)."),
        .optional("start", .time, "Timeline time where the recording starts (default: the end of the timeline, 0 when empty)."),
        .optional("faces", .boolean, "Face-track the camera first (Apple Vision, every frame: ~1 s per 10 s of video) so the layouts frame the face (default false: a centred upper framing)."),
    ] + Recording.layoutParams

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        var url = URL(fileURLWithPath: EngineConfig.expand(p.requiredString("path"))).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            url = url.appendingPathComponent(RecordingSession.fileName)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw CommandError.notFound("\(id): no session at \(url.path)") }
        let session = try RecordingSession.load(url)
        let folder = url.deletingLastPathComponent()
        let order = ["screen", "camera", "mic", "system"]
        let sources = order.compactMap { session.source($0) }
        guard sources.contains(where: { $0.id == "screen" || $0.id == "camera" }) else {
            throw CommandError.invalid("\(id): the session has neither a screen nor a camera source")
        }
        // Assets.
        var assetIDs: [String: String] = [:]
        var durations: [MediaTime] = []
        for s in sources {
            let path = session.path(of: s, sessionFolder: folder)
            guard FileManager.default.fileExists(atPath: path) else { throw CommandError.notFound("\(id): \(s.id) file missing: \(path)") }
            if let existing = project.assets.first(where: { $0.path == path }) {
                assetIDs[s.id] = existing.id
                durations.append(existing.duration)
                continue
            }
            let info = try ctx.prober.probe(URL(fileURLWithPath: path))
            if s.id == "screen" || s.id == "camera", info.video == nil { throw CommandError.invalid("\(id): \(s.file) has no video") }
            if s.id == "mic" || s.id == "system", info.audio == nil { throw CommandError.invalid("\(id): \(s.file) has no audio") }
            let asset = MediaAsset(id: project.makeID("a"), name: "\(Recording.roles[s.id] ?? s.id) — \(folder.lastPathComponent)", path: path,
                                   duration: info.duration, video: info.video, audio: info.audio)
            project.assets.append(asset)
            assetIDs[s.id] = asset.id
            durations.append(info.duration)
        }
        // The common window, then clips at `start`.
        let placements = SessionSync.placements(offsets: sources.map(\.offset), durations: durations, frameRate: project.settings.frameRate)
        guard let window = placements.first?.duration, window > .zero else { throw CommandError.invalid("\(id): the sources do not overlap in time") }
        let start = (p.time("start")?.snapped(to: project.settings.frameRate)) ?? project.duration
        let link = project.makeID("l")
        var trackIDs: [String: String] = [:]
        var clipIDs: [String: String] = [:]
        // Picture tracks bottom to top (screen under the camera), sound after them.
        for (s, pl) in zip(sources, placements) {
            let kind: TrackKind = (s.id == "screen" || s.id == "camera") ? .video : .audio
            let t: Int
            if let existing = project.tracks.firstIndex(where: { $0.role == s.id && $0.kind == kind }) {
                t = existing
            } else {
                let track = Track(id: project.makeID("t"), kind: kind, name: Recording.roles[s.id] ?? s.id, role: s.id)
                if kind == .video {
                    // The camera right above the screen; both above the existing video tracks.
                    if s.id == "camera", let screen = project.tracks.firstIndex(where: { $0.role == "screen" && $0.kind == .video }) { t = screen + 1 }
                    else { t = project.tracks.lastIndex { $0.kind == .video }.map { $0 + 1 } ?? 0 }
                } else {
                    t = project.tracks.count
                }
                project.tracks.insert(track, at: t)
            }
            var clip = Clip(id: project.makeID("c"), assetID: assetIDs[s.id]!, sourceIn: pl.sourceIn, sourceOut: pl.sourceOut, start: start)
            clip.link = link
            try Timeline.checkFree(project.tracks[t], start: clip.start, end: clip.end)
            project.tracks[t].clips.append(clip)
            project.tracks[t].sortClips()
            trackIDs[s.id] = project.tracks[t].id
            clipIDs[s.id] = clip.id
        }
        var rec = RecordingLink(id: project.makeID("r"), session: url.path, offsets: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.offset) }))
        rec.screen = assetIDs["screen"]; rec.camera = assetIDs["camera"]; rec.mic = assetIDs["mic"]; rec.system = assetIDs["system"]
        if !session.hasCursorInVideo { rec.cursorInVideo = false }   // the compositor draws the cursor (cursor.style)
        project.recordings = (project.recordings ?? []) + [rec]
        let index = project.recordings!.count - 1
        ctx.project = project

        // Faces first (optional), so the layout frames the face.
        if p.bool("faces") == true, let cam = rec.camera {
            _ = try FacesTrack.run(try CommandParams(validating: ["assetId": .string(cam)], for: FacesTrack.descriptor), &ctx)
            project = ctx.project!
        }
        // Layouts: the requested one over everything, else the recording's own choice and its live switches.
        let end = start + window
        var applied: [JSONValue] = []
        if rec.screen != nil {
            let origin = SessionSync.origin(offsets: sources.map(\.offset))
            var plan: [(MediaTime, LayoutSpec)] = []
            if rec.camera == nil {
                // Screen-only take (issue #39): no face to place, the screen fills the frame.
                plan = [(start, LayoutSpec(kind: .screen))]
            } else if let requested = try Recording.spec(p, kind: p.string("layout")) {
                plan = [(start, requested)]
            } else {
                plan = [(start, session.layout ?? LayoutSpec(kind: .bubble))]
                for change in session.layoutChanges ?? [] {
                    let t = (start + MediaTime(seconds: change.t - origin)).snapped(to: project.settings.frameRate)
                    if t > start, t < end { plan.append((t, change.layout)) }
                }
            }
            // A side-by-side chosen while recording becomes the vertical stack in a 9:16 project.
            if project.settings.height > project.settings.width, p.string("layout") == nil {
                plan = plan.map { ($0.0, $0.1.kind == .split ? LayoutSpec(kind: .stack) : $0.1) }
            }
            // A styled frame asked for at import goes on every screen / bubble range.
            if let frame = try Recording.frame(p) {
                plan = plan.map { t, spec in
                    var spec = spec
                    if LayoutSpec.framed.contains(spec.kind), spec.frame == nil { spec.frame = frame }
                    return (t, spec)
                }
            }
            for (k, (t, spec)) in plan.enumerated() {
                let to = k + 1 < plan.count ? plan[k + 1].0 : end
                try Recording.apply(spec, link: index, from: t, to: to, transition: k == 0 ? 0 : 0.3, &project)
                applied.append(["from": ProjectState.seconds(t), "to": ProjectState.seconds(to), "layout": .string(spec.label)])
            }
        }
        ctx.project = project
        let origin = SessionSync.origin(offsets: sources.map(\.offset))
        return [
            "recordingId": .string(rec.id), "session": .string(url.path), "synthetic": .bool(session.synthetic == true),
            "start": ProjectState.seconds(start), "duration": ProjectState.seconds(window), "origin": Analysis.seconds(origin, places: 1_000_000),
            "assets": .object(assetIDs.mapValues { .string($0) }), "tracks": .object(trackIDs.mapValues { .string($0) }),
            "clips": .object(clipIDs.mapValues { .string($0) }),
            "sources": .array(zip(sources, placements).map { s, pl in
                ["id": .string(s.id), "offset": Analysis.seconds(s.offset, places: 1_000_000), "sourceIn": .number(pl.sourceIn.displaySeconds),
                 "device": s.device.map { .string($0) } ?? .null]
            }),
            "events": ["clicks": .number(Double(session.clicks.count)), "keys": .number(Double(session.events.filter { $0.kind == "key" }.count)),
                       "cursorSamples": .number(Double(session.cursor?.count ?? 0)), "drags": .number(Double(session.drags.count))],
            "cursorInVideo": .bool(session.hasCursorInVideo),
            "layouts": .array(applied),
        ]
    }
}

enum LayoutPresets: Command {
    static let id = "layout.presets"
    static let summary = "List the face layouts for screen recordings — bubble (corner, circle or rounded square, S/M/L), split (screen 2/3 + face 1/3), stack (9:16: screen top, face bottom), face (full screen), cutout (the person without background over the screen, needs matte.track on the camera), screen (no face) — with the boxes they produce at this project's size (output pixels [x, y, w, h]); and the styled frame for screen and bubble (background gradients, padding, rounded corners, shadow) with its built-in backgrounds."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [Recording.recordingParam]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let W = project.settings.width, H = project.settings.height
        var screen = (1920, 1080), camera = (1080, 1920)
        var face: [Double]?
        if let link = project.recordings?.last {
            if let v = link.screen.flatMap({ project.asset($0)?.video }) { screen = (v.width, v.height) }
            if let a = link.camera.flatMap({ project.asset($0) }), let v = a.video {
                camera = (v.width, v.height)
                face = Recording.face(camera: a, in: project, from: .zero, to: project.duration)
            }
        }
        func box(_ l: LayerLayout) -> JSONValue {
            guard l.visible else { return "hidden" }
            guard let pl = l.placement, pl.fit == .box else { return .array([0, 0, .number(Double(W)), .number(Double(H))]) }
            let (w, h) = l.boxSize(width: W, height: H)
            return .array([pl.x * Double(W) - w / 2, pl.y * Double(H) - h / 2, w, h].map { .number(($0 * 10).rounded() / 10) })
        }
        let examples: [(LayoutSpec, String)] = [
            (LayoutSpec(kind: .bubble), "Face in a circle in a corner over the full screen (corner, shape circle|rounded, size S|M|L)."),
            (LayoutSpec(kind: .split), "Screen in two thirds (never cropped) and the face in the last third, on a dark backdrop (side left|right)."),
            (LayoutSpec(kind: .stack), "Vertical reel: screen on top (cropped to the half; edit.autoZoom follow: true keeps the cursor in view), face below (side top|bottom)."),
            (LayoutSpec(kind: .face), "The face full screen (to talk to camera between demos)."),
            (LayoutSpec(kind: .cutout), "The person without background standing in a bottom corner over the screen (needs matte.track on the camera; corner, size)."),
            (LayoutSpec(kind: .screen), "The screen alone."),
        ]
        return ["width": .number(Double(W)), "height": .number(Double(H)),
                "presets": .array(examples.map { spec, text in
                    let g = Layouts.geometry(spec, width: W, height: H, screen: screen, camera: camera, face: face)
                    return ["preset": .string(spec.kind.rawValue), "description": .string(text),
                            "screen": box(g.screen), "camera": box(g.camera),
                            "mask": g.camera.mask.map { .string($0.cutout == true ? "cutout" : $0.shape.rawValue) } ?? "rect"]
                }),
                "frame": [
                    "description": "screen and bubble take a styled frame (frame: true, or any of background, gradient, padding, radius, shadow): the whole screen on a background, padded, rounded, with a soft shadow. Default background: the applied kit's colours (brand), else graphite.",
                    "screen": box(Layouts.geometry(LayoutSpec(kind: .screen, frame: ScreenFrame()), width: W, height: H, screen: screen, camera: camera, face: face).screen),
                    "bubble": box(Layouts.geometry(LayoutSpec(kind: .bubble, frame: ScreenFrame()), width: W, height: H, screen: screen, camera: camera, face: face).camera),
                    "brand": project.brand.map { .string(Backdrop.brand($0).colors?.joined(separator: " → ") ?? "") } ?? .null,
                    "backgrounds": .array(Backdrop.presets.map { name, b, text in
                        ["name": .string(name), "kind": .string(b.kind.rawValue), "colors": .array((b.colors ?? []).map { .string($0) }),
                         "description": .string(text)]
                    }),
                ]]
    }
}

enum LayoutApply: Command {
    static let id = "layout.apply"
    static let summary = "Put the face where a layout preset says on a time range of a screen recording (default: the whole recording): cuts the screen, camera and mic clips at the range edges and writes placement, crop around the face (faces.track on the camera makes it exact), mask and border on them — ordinary clip properties, editable with clip.set/clip.keyframe. Switching mid-video: call it again on a later range; a move between two layouts of the same shape glides (transition seconds), a new shape pops in. cutout needs matte.track {assetId: <camera>} over the range. screen and bubble take a styled frame (frame: true or background/gradient/padding/radius/shadow): the whole screen padded on a gradient, colour or image background with rounded corners and a soft shadow — the project's backdrop, default from the brand kit. Returns the camera clips written and the boxes."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("preset", .oneOf(LayoutSpec.Kind.allCases.map(\.rawValue)), "bubble, split, stack, face, cutout or screen (layout.presets)."),
        .optional("from", .time, "Timeline start (default: the start of the recording)."),
        .optional("to", .time, "Timeline end (default: the end of the recording)."),
        .optional("transition", .number, "Seconds of the move into this layout at `from` (default 0.35; 0 = a hard cut)."),
        Recording.recordingParam,
    ] + Recording.layoutParams

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let (index, link) = try Recording.link(p, project, command: id)
        guard let spec = try Recording.spec(p, kind: p.string("preset")) else { throw CommandError.invalid("\(id): preset is required") }
        guard let (a, b) = Recording.extent(link, project) else { throw CommandError.conflict("\(id): the recording has no clips on the timeline") }
        let rate = project.settings.frameRate
        let from = max(p.time("from")?.snapped(to: rate) ?? a, a), to = min(p.time("to")?.snapped(to: rate) ?? b, b)
        guard to > from else { throw CommandError.invalid("\(id): the range is empty (the recording spans \(a.displaySeconds)–\(b.displaySeconds) s)") }
        let written = try Recording.apply(spec, link: index, from: from, to: to, transition: p.number("transition") ?? 0.35, &project)
        ctx.project = project
        try Recording.refreshDerived(link: index, &ctx)
        project = ctx.project!
        var warnings: [JSONValue] = []
        if spec.kind == .cutout, let cam = link.camera.flatMap({ project.asset($0) }) {
            let fps = cam.analysis?.matte?.frameRate ?? cam.video?.frameRate.doubleValue ?? 30
            let need = Matte.frames(of: cam, in: project, from: from, to: to, fps: fps)
            let missing = cam.analysis?.matte.map { m in need.filter { !m.has($0) }.count } ?? need.count
            if missing > 0 {
                warnings.append(.string("cutout: \(missing) camera frames in this range have no person matte — run matte.track {assetId: \"\(cam.id)\", from: \(from.displaySeconds), to: \(to.displaySeconds)} (until then the camera is drawn whole)"))
            }
        }
        if link.camera.flatMap({ project.asset($0)?.analysis?.faces }) == nil, spec.kind != .screen {
            warnings.append(.string("the camera is not face-tracked: the framing assumes a centred face — faces.track {assetId: \"\(link.camera ?? "")\"} then layout.apply again for an exact crop"))
        }
        ctx.project = project
        let W = project.settings.width, H = project.settings.height
        let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: false)
        let mid = (from + MediaTime(seconds: (to - from).seconds / 2)).snapped(to: rate)
        let boxes = job.layers(at: mid).filter { $0.assetID == link.screen || $0.assetID == link.camera }.map { l -> JSONValue in
            ["role": .string(l.assetID == link.camera ? "camera" : "screen"), "box": Graphics.boxJSON(l.box(width: W, height: H)),
             "visible": .bool(l.opacity > 0)]
        }
        return ["layout": .string(spec.label), "from": ProjectState.seconds(from), "to": ProjectState.seconds(to),
                "cameraClips": .array(written.map { .string($0) }), "boxes": .array(boxes), "warnings": .array(warnings)]
    }
}

enum EditAutoZoom: Command {
    static let id = "edit.autoZoom"
    static let summary = "Screen Studio-style zooms on the recording's clicks: the screen clip zooms in smoothly onto each click (zoom), holds, pans to the next click when clicks come close together, then zooms back out — crop keyframes on the screen clips, one undo step (re-running replaces them). follow: true also keeps the resting framing on the smoothed cursor (vertical reels showing a slice of a wide screen), holding still while the cursor stays inside the central safeZone of the frame. A drag (press, move, release) keeps the zoom and carries the camera along with it instead of zooming out mid-drag. Camera moves get a motion blur proportional to their speed (motionBlur). Returns the clicks with their timeline times and the zoom reached, and the drags found."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("zoom", .number, "Magnification at a click (default 1.8; 1.3–2.5 reads well)."),
        .optional("hold", .number, "Seconds held after the last click of a group (default 1.0)."),
        .optional("easeIn", .number, "Seconds of the zoom-in, ending on the click (default 0.45)."),
        .optional("easeOut", .number, "Seconds of the zoom-out (default 0.6)."),
        .optional("easing", .oneOf(["smooth", "spring", "linear", "easeIn", "easeOut", "easeInOut", "expoOut"]),
                  "Curve of the moves (default smooth = easeInOut; spring: a critically damped spring fitted to the same durations, it leaves at once and settles softly onto the click)."),
        .optional("follow", .boolean, "Resting framing follows the smoothed cursor (default false: centred)."),
        .optional("safeZone", .number, "Follow only: central fraction of the frame the cursor may wander in before the camera moves, just enough to bring it back (default 0.6; 0 = follow every move, dense keyframes)."),
        .optional("motionBlur", .number, "Blur of the camera moves, proportional to their speed, as a shutter fraction 0…1 (default 0.5; 0 = none). Written on the screen clips."),
        .optional("drags", .boolean, "Hold the zoom through drags and follow them (default true). Drags come from the session's mouse-up log (Drags.detect); older sessions without it: a click whose cursor keeps moving ≥ 0.16 s over > 1.5% of the screen diagonal."),
        .optional("from", .time, "Only clicks from this timeline time (default 0)."),
        .optional("to", .time, "Only clicks before this timeline time (default: the end)."),
        .optional("clear", .boolean, "Remove the automatic zoom instead: the zoom keyframes and the motion blur of the screen clips (in from…to)."),
        Recording.recordingParam,
    ]

    /// Options kept on the recording (RecordingLink.autoZoom) so a new layout or format re-runs the same zoom.
    static let kept = ["zoom", "hold", "easeIn", "easeOut", "easing", "follow", "safeZone", "motionBlur", "drags"]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let (linkIndex, link) = try Recording.link(p, project, command: id)
        guard let screenID = link.screen, let screen = project.asset(screenID), let sv = screen.video else {
            throw CommandError.conflict("\(id): the recording has no screen")
        }
        if p.bool("clear") == true {
            let from = p.time("from") ?? .zero, to = p.time("to") ?? project.duration
            var cleared: [String] = []
            for (t, c) in Recording.clips(of: screenID, in: project) {
                let clip = project.tracks[t].clips[c]
                guard clip.end > from, clip.start < to, clip.keyframes != nil || clip.motionBlur != nil else { continue }
                project.tracks[t].clips[c].keyframes = nil
                project.tracks[t].clips[c].motionBlur = nil
                cleared.append(clip.id)
            }
            project.recordings![linkIndex].autoZoom = nil
            ctx.project = project
            return ["cleared": .array(cleared.map { .string($0) }), "clicks": .array([]), "keyframes": 0]
        }
        let session = try RecordingSession.load(URL(fileURLWithPath: link.session))
        var o = ZoomOptions()
        if let v = p.number("zoom") { guard v >= 1.05, v <= 4 else { throw CommandError.invalid("\(id): zoom must be 1.05…4") }; o.zoom = v }
        if let v = p.number("hold") { o.hold = max(v, 0) }
        if let v = p.number("easeIn") { o.easeIn = max(v, 0.05) }
        if let v = p.number("easeOut") { o.easeOut = max(v, 0.05) }
        if let e = p.string("easing") { o.easing = e == "smooth" ? .easeInOut : Easing(rawValue: e) ?? o.easing }
        o.follow = p.bool("follow") ?? false
        if let v = p.number("safeZone") { guard v >= 0, v <= 0.9 else { throw CommandError.invalid("\(id): safeZone must be 0…0.9") }; o.safeZone = v }
        if let v = p.number("motionBlur") { guard v >= 0, v <= 1 else { throw CommandError.invalid("\(id): motionBlur must be 0…1") }; o.motionBlur = v }
        let offset = link.offsets["screen"] ?? 0
        let from = p.time("from") ?? .zero, to = p.time("to") ?? project.duration
        var clicks: [ZoomClick] = []
        var clickRows: [(ZoomClick, MediaTime)] = []
        // Drags: the release of each press that moved, and the smoothed cursor in between (screen time).
        let sessionClicks = session.clicks.map { (t: $0.t, x: $0.x!, y: $0.y!) }
        var releases: [Int: Double] = [:]
        if p.bool("drags") ?? true, let cursor = session.cursor, !cursor.isEmpty {
            releases = DragHold.releases(clicks: sessionClicks, events: session.events, cursor: cursor, width: Double(sv.width), height: Double(sv.height))
        }
        for (i, e) in sessionClicks.enumerated() {
            guard let tl = SessionSync.timelineTime(session: e.t, offset: offset, asset: screenID, in: project), tl >= from, tl < to else { continue }
            var c = ZoomClick(t: e.t - offset, x: e.x, y: e.y)
            if let r = releases[i], let cursor = session.cursor {
                let times = stride(from: c.t, to: r - offset, by: 1.0 / 30).map { $0 } + [r - offset]
                let path = AutoZoom.smoothedCursor(cursor, offset: offset, times: times, tau: 0.12)
                c.drag = zip(times, path).map { ZoomClick(t: $0, x: $1[0], y: $1[1]) }
            }
            clicks.append(c)
            clickRows.append((c, tl))
        }
        let keys = AutoZoom.keys(clicks, o)
        // Resting centre: the screen area's middle, or the smoothed cursor (tabulated at 30 Hz over the file).
        var restTable: [[Double]] = [], rawTable: [[Double]] = []
        let tableRate = 30.0
        if o.follow, let cursor = session.cursor, !cursor.isEmpty {
            let n = Int(screen.duration.seconds * tableRate) + 2
            let times = (0..<n).map { Double($0) / tableRate }
            restTable = AutoZoom.smoothedCursor(cursor, offset: offset, times: times, tau: o.followSmoothing)
            if o.safeZone > 0 { rawTable = AutoZoom.smoothedCursor(cursor, offset: offset, times: times, tau: 0) }
        }
        let W = Double(project.settings.width), H = Double(project.settings.height)
        // The face's box over each screen clip, so clicks land where the face does not cover them (a cut-out person).
        let before = RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: false)
        var changed: [String] = []
        var keyframeCount = 0
        var restWidth: [String: Double] = [:]
        for (t, c) in Recording.clips(of: screenID, in: project) {
            var clip = project.tracks[t].clips[c]
            guard clip.end > from, clip.start < to else { continue }
            let rest = clip.transform ?? Transform()
            let area = rest.cropRect(sourceWidth: sv.width, sourceHeight: sv.height)
            let aspect: Double
            if let pl = clip.placement, pl.fit == .box { aspect = ((pl.width ?? 1) * W) / max((pl.height ?? 1) * H, 1) } else { aspect = W / H }
            let centre = [area[2] + area[0] / 2, area[3] + area[1] / 2]
            restWidth[clip.id] = AutoZoom.crop(zoom: 1, centre: centre, aspect: aspect, area: area)[0]
            let mid = (clip.start + MediaTime(seconds: clip.duration.seconds / 2)).snapped(to: project.settings.frameRate)
            let layers = before.layers(at: mid)
            var band = [0.0, 0, 1, 1]
            if let sl = layers.first(where: { $0.clipID == clip.id }) {
                let occluder = layers.first { $0.assetID == link.camera && $0.opacity > 0.01 }.map { $0.box(width: Int(W), height: Int(H)) }
                band = AutoZoom.freeBand(screen: sl.box(width: Int(W), height: Int(H)), occluder: occluder)
            }
            let anchor = [(band[0] + band[2]) / 2, (band[1] + band[3]) / 2]
            // Safe zone: the camera centre holds while the cursor wanders inside the central part of the visible band.
            var clipRest = restTable
            if !restTable.isEmpty, o.safeZone > 0 {
                let r = AutoZoom.crop(zoom: 1, centre: centre, aspect: aspect, area: area)
                let frame = [(band[2] - band[0]) * r[0] / 2, (band[3] - band[1]) * r[1] / 2]
                let bounds = [area[2] + anchor[0] * r[0], area[3] + anchor[1] * r[1],
                              area[2] + area[0] - r[0] + anchor[0] * r[0], area[3] + area[1] - r[1] + anchor[1] * r[1]]
                clipRest = AutoZoom.safeZoneCentres(restTable, raw: rawTable, dt: 1 / tableRate, zone: frame.map { $0 * o.safeZone }, frame: frame, bounds: bounds)
            }
            let restAt: (Double) -> [Double] = { u in
                guard !clipRest.isEmpty else { return centre }
                let i = min(max(Int((u * tableRate).rounded()), 0), clipRest.count - 1)
                return clipRest[i]
            }
            let clipKeys = AutoZoom.raisedForBand(keys, band: band, aspect: aspect, area: area)
            var crops = AutoZoom.keyframeCrops(keys: clipKeys, sourceIn: clip.sourceIn.seconds, sourceOut: clip.sourceOut.seconds, aspect: aspect,
                                               area: area, rest: restAt, dense: o.follow && !restTable.isEmpty, anchor: anchor)
            if o.follow, o.safeZone > 0 { crops = AutoZoom.simplified(crops) }
            let frames = crops.map { k -> Keyframe in
                var tr = Transform(crop: k.crop, sourceWidth: sv.width, sourceHeight: sv.height)
                (tr.scale, tr.x, tr.y, tr.rotation, tr.opacity) = (rest.scale, rest.x, rest.y, rest.rotation, rest.opacity)
                return Keyframe(time: min(MediaTime(seconds: k.t), clip.duration), transform: tr, easing: k.easing)
            }
            let new = frames.isEmpty ? nil : frames
            let blur: Double? = new == nil || o.motionBlur == 0 ? nil : o.motionBlur
            if new != clip.keyframes || blur != clip.motionBlur {
                clip.keyframes = new
                clip.motionBlur = blur
                project.tracks[t].clips[c] = clip
                changed.append(clip.id)
            }
            keyframeCount += frames.count
        }
        project.recordings![linkIndex].autoZoom = p.values.filter { kept.contains($0.key) }
        ctx.project = project
        let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: false)
        let rows: [JSONValue] = clickRows.map { c, tl in
            let snapped = tl.snapped(to: project.settings.frameRate)
            // Reached magnification: resting crop width / crop width at the click.
            let zoom: Double = job.layers(at: snapped).first { $0.assetID == screenID }.map { l in
                (restWidth[l.clipID] ?? l.crop[0]) / max(l.crop[0], 1)
            } ?? 1
            return ["time": ProjectState.seconds(tl), "x": .number(c.x.rounded()), "y": .number(c.y.rounded()), "zoom": Analysis.seconds(zoom, places: 100)]
        }
        return ["clicks": .array(rows), "groups": .number(Double(AutoZoom.groups(clicks, o).count)), "keys": .number(Double(keys.count)),
                "keyframes": .number(Double(keyframeCount)), "clips": .array(changed.map { .string($0) }), "follow": .bool(o.follow),
                "zoom": .number(o.zoom), "easing": .string(o.easing.rawValue), "safeZone": .number(o.follow ? o.safeZone : 0),
                "motionBlur": .number(o.motionBlur),
                "drags": .array(clicks.compactMap { c -> JSONValue? in
                    // Timeline times of the press and the release.
                    guard let end = c.drag?.last,
                          let a = SessionSync.timelineTime(session: c.t + offset, offset: offset, asset: screenID, in: project),
                          let b = SessionSync.timelineTime(session: end.t + offset, offset: offset, asset: screenID, in: project) else { return nil }
                    return ["from": ProjectState.seconds(a), "to": ProjectState.seconds(b)]
                })]
    }
}
