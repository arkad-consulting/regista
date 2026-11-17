import Foundation

/// layout.speaker: the speaker layouts of `SpeakerLayout` on a time range of any project.
enum LayoutSpeaker: Command {
    static let id = "layout.speaker"
    static let summary = "Frame the speaker (any project, not only screen recordings) on a time range: letterbox-headline (9:16: black top band with a persistent headline, the 16:9 picture in the middle, the bottom band empty for Instagram's buttons — captions land under the picture), split-card (the speaker in a rounded card on one side, a free area on the other for a graphic; light canvas), pip-bubble (the speaker in a circle in a corner over a full-frame graphic or B-roll: brollAssetId fills the frame under it), inset-frame (the whole shot shrinks into a styled card on a dark backdrop — frame neon (glow + corner brackets + PREVIEW chip, brand accent), glass or plain; position center, topLeft or left of a panel; animates in from full frame and back out), full (removes the layout). Cuts the main video at the range edges and writes ordinary clip properties (box placement, crop around the face — faces.track makes it exact —, mask), so clip.set and history.undo work. A pip-bubble without B-roll over a face-tracked speaker goes to the first corner that leaves the face free (a corner given is kept, with a warning when it covers the face). Returns the clips written, the speaker box, the free area for a graphic, the bubble's corner, faceCheck (whether the corner was checked against a face, or why not) and warnings."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("preset", .oneOf(SpeakerLayout.names), "letterbox-headline, split-card, pip-bubble, inset-frame or full."),
        .optional("from", .time, "Timeline start (default 0)."),
        .optional("to", .time, "Timeline end (default: the end of the speaker track)."),
        .optional("trackId", .string, "The speaker's video track (default: the first video track with clips)."),
        .optional("headline", .string, "letterbox-headline: the text of the top band (sentence case, ≤ 6 words reads best)."),
        .optional("side", .oneOf(["left", "right"]), "split-card: side of the card (default left)."),
        .optional("corner", .oneOf(LayoutSpec.corners), "pip-bubble: corner (default bottomRight, kept clear of the Instagram rail and the caption band; without B-roll and over a face-tracked speaker, the first corner of bottomRight, bottomLeft, topRight, topLeft that leaves the face free). A corner given is kept, with a warning when the bubble covers the face."),
        .optional("size", .oneOf(LayoutSpec.sizes), "pip-bubble: S, M or L (default M)."),
        .optional("brollAssetId", .string, "pip-bubble: a video or image asset filling the frame under the bubble over the range."),
        .optional("brollIn", .time, "pip-bubble: start inside the B-roll (default 0)."),
        .optional("position", .oneOf(SpeakerLayout.positions), "inset-frame: center (default), topLeft or left (a panel on the right)."),
        .optional("frame", .oneOf(LayerMask.frames), "inset-frame: neon (default), glass or plain."),
        .optional("label", .string, "inset-frame: chip in the card's top-left corner (default PREVIEW; empty string = none)."),
        .optional("badge", .string, "inset-frame: chip in the top-right corner (e.g. \"9:16\")."),
        .optional("animate", .number, "inset-frame: seconds of the zoom from full frame into the card at `from` and back out at `to` (default 0.5; 0 = none)."),
        .optional("accent", .string, "Glow / accent colour (#RRGGBB or a brand role; default the kit's highlight, else #FF7A1A)."),
        .optional("background", .string, "Frame background around the box (#RRGGBB or a brand role; defaults per preset)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let layout = SpeakerLayout(rawValue: p.requiredString("preset"))!
        let t0: Int
        if let tid = p.string("trackId") { t0 = try Timeline.trackIndex(tid, in: project) }
        else {
            guard let v = project.tracks.firstIndex(where: { $0.kind == .video && !$0.clips.isEmpty }) else {
                throw CommandError.conflict("\(id): no video on the timeline")
            }
            t0 = v
        }
        let trackID = project.tracks[t0].id
        let rate = project.settings.frameRate
        let from = (p.time("from") ?? .zero).snapped(to: rate), to = (p.time("to") ?? project.tracks[t0].end).snapped(to: rate)
        guard to > from else { throw CommandError.invalid("\(id): the range is empty") }
        let brand = project.brand
        func role(_ v: String?) -> String? { v.map { brand?.color($0) ?? $0 } }
        let accent = role(p.string("accent")) ?? brand?.colors["highlight"] ?? brand?.colors["accent"] ?? "#FF7A1A"
        var options = SpeakerLayout.Options(side: p.string("side"), corner: p.string("corner"), size: p.string("size"), position: p.string("position"),
                                            frame: p.string("frame"), label: p.string("label").flatMap { $0.isEmpty ? nil : $0 },
                                            badge: p.string("badge"), accent: accent, background: role(p.string("background")))
        var log: [JSONValue] = []
        var warnings: [JSONValue] = []
        // Captions that match the timeline now are rebuilt and placed again afterwards (the cuts at the range edges
        // change no word; the picture under them did change).
        let freshCaptions = project.tracks.indices.filter { i in
            guard let c = project.tracks[i].captions, let src = project.tracks.first(where: { $0.id == c.sourceTrack }) else { return false }
            return Captions.signature(of: src) == c.sourceSignature
        }
        // Cut the speaker at the range edges (its sound follows: linked clips are cut together).
        for at in [from, to] where project.tracks[t0].clips.contains(where: { $0.start < at && at < $0.end }) {
            try ctx.perform(TimelineCut.self, ["at": .number(at.seconds), "trackId": .string(trackID)], log: &log)
        }
        project = try ctx.requireProject()
        let inRange = project.tracks[t0].clips.indices.filter { project.tracks[t0].clips[$0].start >= from && project.tracks[t0].clips[$0].end <= to }
        guard !inRange.isEmpty else { throw CommandError.conflict("\(id): no speaker clip inside \(from.displaySeconds)–\(to.displaySeconds) s") }
        let W = project.settings.width, H = project.settings.height
        var written: [String] = []
        var bubbleTrack: JSONValue = .null
        var geometry = SpeakerGeometry()
        var label = options.label
        if layout == .insetFrame, !p.has("label") { label = "PREVIEW" }

        /// The geometry for one clip (its own source size and face).
        func geometryFor(_ clip: Clip) -> SpeakerGeometry? {
            guard let asset = project.asset(clip.assetID), let v = asset.video else { return nil }
            let face = Recording.face(camera: asset, in: project, from: clip.start, to: clip.end)
            if face == nil, asset.image == nil, layout != .full, layout != .insetFrame { warnings.append(.string("\(asset.name) is not face-tracked: the framing assumes a centred face — faces.track {assetId: \"\(asset.id)\"} then layout.speaker again")) }
            var o = options
            o.label = label
            return layout.geometry(width: W, height: H, source: (v.width, v.height), face: face, options: o)
        }
        /// Writes a geometry onto a clip: box, crop (into its transform), mask; layouts replace keyframes (punch-ins).
        func apply(_ g: SpeakerGeometry, to clip: inout Clip, source: VideoInfo) {
            var tr = clip.transform ?? Transform()
            let crop = g.crop ?? [Double(source.width), Double(source.height), 0, 0]
            let c = Transform(crop: crop, sourceWidth: source.width, sourceHeight: source.height)
            tr.cropLeft = c.cropLeft; tr.cropTop = c.cropTop; tr.cropRight = c.cropRight; tr.cropBottom = c.cropBottom
            if g.placement != nil { tr.scale = 1; tr.x = 0; tr.y = 0; tr.rotation = 0 }
            if clip.keyframes != nil { warnings.append(.string("clip \(clip.id): its keyframes (punch-ins, zooms) were replaced by the layout")) }
            clip.keyframes = nil
            clip.transform = tr
            clip.placement = g.placement
            clip.mask = g.mask
        }

        // The bubble over the speaker himself (no B-roll) stays off his face (#16): the first free corner, unless one was given.
        var faceCheck: String?
        if layout == .pipBubble, !p.has("brollAssetId") {
            let what = "the pip-bubble"
            if let under = FaceClear.untracked(project, from: from, to: to) {
                if !under.tracked {
                    faceCheck = FaceClear.notChecked(asset: under.asset)
                } else {
                    let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project))
                    var faces = OutputFaces(job: job)
                    /// When the face first meets the bubble in `corner`, nil when never.
                    func overlap(_ corner: String) -> MediaTime? {
                        var o = options
                        o.corner = corner
                        for i in inRange {
                            let clip = project.tracks[t0].clips[i]
                            guard let v = project.asset(clip.assetID)?.video, let pl = layout.geometry(width: W, height: H, source: (v.width, v.height),
                                  face: Recording.face(camera: project.asset(clip.assetID)!, in: project, from: clip.start, to: clip.end), options: o).placement,
                                  pl.fit == .box else { continue }
                            let w = (pl.width ?? 1) * Double(job.width), h = (pl.height ?? 1) * Double(job.height)
                            let box = [pl.x * Double(job.width) - w / 2, pl.y * Double(job.height) - h / 2, w, h]
                            if let at = faces.firstOverlap(box, from: clip.start, to: clip.end) { return at }
                        }
                        return nil
                    }
                    faceCheck = FaceClear.checked(covers: false)
                    if let corner = options.corner {
                        if let at = overlap(corner) {
                            warnings.append(.string(FaceClear.placedOverFace(what, at: at)))
                            faceCheck = FaceClear.checked(covers: true)
                        }
                    } else {
                        let corners = ["bottomRight", "bottomLeft", "topRight", "topLeft"]
                        var first: MediaTime?
                        for (k, c) in corners.enumerated() {
                            guard let at = overlap(c) else { options.corner = c; break }
                            if k == 0 { first = at }
                        }
                        if options.corner == nil, let first {
                            warnings.append(.string(FaceClear.noFreePlace(what, at: first, places: corners)))
                            faceCheck = FaceClear.checked(covers: true)
                        }
                    }
                }
            }
        }

        switch layout {
        case .pipBubble:
            // The speaker stays full frame underneath (captions and the transcript read it); a copy of each clip goes into
            // the bubble on a new top track, and the B-roll (if any) fills the frame between them.
            if let broll = p.string("brollAssetId") {
                guard let a = project.asset(broll) else { throw CommandError.notFound("\(id): no asset \(broll)") }
                try ctx.perform(TrackAdd.self, ["kind": "overlay", "name": "B-roll"], log: &log)
                let bt = try ctx.requireProject().tracks.last!.id
                let bin = p.time("brollIn") ?? .zero
                let length = a.image != nil ? (to - from) : min(to - from, a.duration - bin)
                try ctx.perform(TimelinePlace.self, ["assetId": .string(broll), "trackId": .string(bt), "start": .number(from.seconds),
                                                     "sourceIn": .number(bin.seconds), "sourceOut": .number((bin + length).seconds)], log: &log)
                if length < to - from { warnings.append(.string("the B-roll is shorter than the range: the speaker shows full frame after \((from + length).displaySeconds) s")) }
            } else {
                let covered = project.tracks.indices.contains { i in
                    i > t0 && project.tracks[i].kind != .audio && project.tracks[i].clips.contains { $0.start < to && from < $0.end && ($0.placement == nil || $0.placement?.fit == .fill) }
                }
                if !covered { warnings.append(.string("nothing covers the frame under the bubble: add a full-frame graphic or B-roll over the range (brollAssetId, overlay.add fullFrame: true, a motion template), else the speaker shows twice")) }
            }
            try ctx.perform(TrackAdd.self, ["kind": "overlay", "name": "PiP"], log: &log)
            project = try ctx.requireProject()
            let pip = project.tracks.count - 1
            bubbleTrack = .string(project.tracks[pip].id)
            for i in inRange {
                var copy = project.tracks[t0].clips[i]
                guard let v = project.asset(copy.assetID)?.video, let g = geometryFor(copy) else { continue }
                copy.id = project.makeID("c")
                copy.link = nil
                copy.effects = nil
                apply(g, to: &copy, source: v)
                project.tracks[pip].clips.append(copy)
                written.append(copy.id)
                geometry = g
            }
        default:
            for i in inRange {
                var clip = project.tracks[t0].clips[i]
                guard let v = project.asset(clip.assetID)?.video, let g = geometryFor(clip) else { continue }
                apply(g, to: &clip, source: v)
                if layout == .full { clip.transform = nil }
                if layout == .insetFrame, let pl = g.placement, let a = p.number("animate") ?? Optional(0.5), a > 0 {
                    // From full frame into the card at the range start, back out at its end (expo ease).
                    let w = (pl.width ?? 1) * Double(W), h = (pl.height ?? 1) * Double(H)
                    let cover = max(Double(W) / w, Double(H) / h)
                    var big = clip.transform ?? Transform()
                    big.scale = cover; big.x = 0.5 - pl.x; big.y = 0.5 - pl.y
                    let rest = clip.transform ?? Transform()
                    let d = clip.duration, move = MediaTime(seconds: a)
                    let entrance = clip.start == from, exit = clip.end == to
                    var keys: [Keyframe] = []
                    if d.seconds > a * (entrance && exit ? 2 : 1) {
                        if entrance { keys += [Keyframe(time: .zero, transform: big, easing: .expoOut), Keyframe(time: move, transform: rest)] }
                        if exit { keys += [Keyframe(time: d - move, transform: rest, easing: .easeIn), Keyframe(time: d - MediaTime.frameDuration(at: rate), transform: big)] }
                    }
                    if !keys.isEmpty {
                        if keys.first!.time > .zero { keys.insert(Keyframe(time: .zero, transform: rest), at: 0) }
                        clip.keyframes = keys
                    }
                }
                project.tracks[t0].clips[i] = clip
                written.append(clip.id)
                geometry = g
            }
        }
        if let bg = geometry.background { project.settings.background = bg }
        if layout == .full, !project.tracks.contains(where: { $0.clips.contains { $0.placement?.fit == .box } }) { project.settings.background = nil }
        for i in freshCaptions {
            guard var c = project.tracks[i].captions else { continue }
            if (try? CaptionsCommon.rebuild(&c, project, command: id)) != nil {
                CaptionsCommon.place(&c, project, renderer: ctx.services.renderer)
                project.tracks[i].captions = c
            }
        }
        ctx.project = project
        var headlineClip: JSONValue = .null
        if layout == .letterboxHeadline, let text = p.string("headline"), !text.isEmpty, let hp = geometry.headline {
            let r = try ctx.perform(TitleAdd.self, [
                "text": .string(text), "start": .number(from.seconds), "end": .number(to.seconds),
                "font": .string(brand?.fonts["text"] != nil ? "text" : "HelveticaNeue"), "size": 52, "color": "#FFFFFF",
                "position": .array([.number(hp.x / Double(W) * SafeZones.referenceWidth), .number(hp.y / Double(H) * SafeZones.referenceHeight)]),
                "maxWidth": 960, "shadow": false,
            ], log: &log)
            headlineClip = r["clip"]?["id"] ?? r["clipId"] ?? .null
        } else if layout == .letterboxHeadline, !p.has("headline") {
            warnings.append(.string("no headline: pass headline (the reel's promise in a few words) for the top band"))
        }
        func px(_ b: [Double]?) -> JSONValue { b.map { .array($0.map { .number(($0 * 10).rounded() / 10) }) } ?? .null }
        var speakerBox: [Double]?
        if let pl = geometry.placement, pl.fit == .box {
            let w = (pl.width ?? 1) * Double(W), h = (pl.height ?? 1) * Double(H)
            speakerBox = [pl.x * Double(W) - w / 2, pl.y * Double(H) - h / 2, w, h]
        }
        return ["layout": .string(layout.rawValue), "from": ProjectState.seconds(from), "to": ProjectState.seconds(to),
                "clips": .array(written.map { .string($0) }), "speakerBox": px(speakerBox), "freeArea": px(geometry.free),
                "background": project.settings.background.map { .string($0) } ?? .null, "headlineClip": headlineClip,
                "pipTrack": bubbleTrack, "corner": layout == .pipBubble ? .string(options.corner ?? "bottomRight") : .null,
                "faceCheck": faceCheck.map { .string($0) } ?? .null,
                "commands": .array(log), "warnings": .array(warnings)]
    }
}
