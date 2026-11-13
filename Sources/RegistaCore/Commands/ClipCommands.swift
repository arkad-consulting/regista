import Foundation

enum ClipSet: Command {
    static let id = "clip.set"
    static let summary = "Set clip properties on one clip, several, or every clip of a track (trackId): crop (source pixels [w, h, x, y], scaled to fill the frame), scale/x/y/rotation/opacity, keyframes (animated transform), grade (ffmpeg eq brightness/contrast/saturation; the house light grade is 0.02 / 1.06 / 1.08), audio edge fades and gain, picture fades (from / to black or transparent), a title's text, a motion template's fields and the amount of an applied effect. Unset properties are kept. Returns the changed clips."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("clipId", .string, "One clip."),
        .optional("clipIds", .array(.string), "Several clips."),
        .optional("trackId", .string, "Every clip of this track."),
        .optional("crop", .array(.number), "Crop [w, h, x, y] in source display pixels (rotation applied, origin top-left)."),
        .optional("scale", .number, "Extra zoom after filling the frame (1 = fill)."),
        .optional("x", .number, "Horizontal offset of the centre, fraction of the output width."),
        .optional("y", .number, "Vertical offset of the centre, fraction of the output height (down is positive)."),
        .optional("rotation", .number, "Degrees clockwise."),
        .optional("opacity", .number, "0…1."),
        .optional("anchorX", .number, "2.5D: pivot of scale and rotations, fraction of the picture width (default 0.5 = centre; the picture does not move)."),
        .optional("anchorY", .number, "2.5D: pivot, fraction of the picture height (0 = top edge: a card hanging from its top)."),
        .optional("rotationX", .number, "2.5D: tilt in degrees around the horizontal axis (positive = the top goes away)."),
        .optional("rotationY", .number, "2.5D: turn in degrees around the vertical axis (positive = the right side goes away)."),
        .optional("perspective", .number, "2.5D: camera distance, px at 1080 wide (default 2000; 800 = strong perspective)."),
        .optional("behindSwitches", .array(.object), "Switch the layer behind / in front of the person over time: [{time (s from the clip start), behind: true|false}] (needs matte.track); [] removes them."),
        .optional("keyframes", .array(.object), "Animated transform: [{time (s from clip start), crop?, scale?, x?, y?, rotation?, opacity?, anchorX?, anchorY?, rotationX?, rotationY?, perspective?, easing?}], each starting from the clip's transform; easing (linear, easeIn, easeOut, easeInOut, expoOut, backOut, hold, spring) shapes the move to the next keyframe. Replaces existing keyframes (clip.keyframe has presets)."),
        .optional("clearKeyframes", .boolean, "Remove the keyframes."),
        .optional("brightness", .number, "eq brightness −1…1 (0 = none)."),
        .optional("contrast", .number, "eq contrast (1 = none)."),
        .optional("saturation", .number, "eq saturation (1 = none)."),
        .optional("fadeIn", .time, "Audio fade-in at the clip start, seconds (0 removes)."),
        .optional("fadeOut", .time, "Audio fade-out at the clip end, seconds (0 removes)."),
        .optional("pictureFadeIn", .time, "Picture fade-in at the clip start, seconds (0 removes): from black on a full-frame clip of a video track, from transparent on an overlay track or a boxed picture. In a list mixing picture and sound clips (a clip with its linked sound), picture fades go to the picture clips and audio fades to the sound clips, so one call fades both."),
        .optional("pictureFadeOut", .time, "Picture fade-out at the clip end, seconds (0 removes): to black, or to transparent (as pictureFadeIn)."),
        .optional("gain", .number, "Audio gain in dB (−60…24; 0 removes)."),
        .optional("text", .string, "New text of a title clip (title.add); \\n starts a new line. Style, timing and position stay."),
        .optional("fields", .object, "Motion template clip (motion.add): fields to change (names from effects.catalog); the others stay."),
        .optional("effectId", .string, "An effect of the clip (effect.add) whose effectAmount changes."),
        .optional("effectAmount", .number, "New peak strength 0…1 of effectId."),
        .optional("reset", .boolean, "Clear transform, keyframes and grade first."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        var ids = p.strings("clipIds") ?? []
        if let one = p.string("clipId") { ids.append(one) }
        if let tid = p.string("trackId") { ids += project.tracks[try Timeline.trackIndex(tid, in: project)].clips.map(\.id) }
        guard !ids.isEmpty else { throw CommandError.invalid("\(id): pass clipId, clipIds or trackId") }
        // Picture and sound clips together (a clip and its linked sound): each kind of fade goes to its own clips.
        let onSound = try ids.map { project.tracks[try Timeline.locate(clip: $0, in: project).0].kind == .audio }
        let mixed = onSound.contains(true) && onSound.contains(false)
        if p.has("pictureFadeIn") || p.has("pictureFadeOut"), !onSound.contains(false) {
            throw CommandError.conflict("\(id): picture fades are for video and overlay clips — for sound use fadeIn / fadeOut")
        }
        for cid in ids {
            let (t, c) = try Timeline.locate(clip: cid, in: project)
            var clip = project.tracks[t].clips[c]
            let video = project.asset(clip.assetID)?.video
            if p.bool("reset") == true { clip.transform = nil; clip.keyframes = nil; clip.color = nil }
            var tr = clip.transform ?? Transform()
            try apply(p.values, to: &tr, video: video, clip: cid)
            let isIdentity = tr == Transform()
            clip.transform = isIdentity && clip.transform == nil ? nil : tr
            if p.bool("clearKeyframes") == true { clip.keyframes = nil }
            if let sw = p.json("behindSwitches")?.arrayValue {
                let keys = try sw.map { v -> BehindSwitch in
                    guard let o = v.objectValue, let tm = o["time"]?.doubleValue, let b = o["behind"]?.boolValue else {
                        throw CommandError.invalid("\(id): behindSwitches are [{time, behind}]")
                    }
                    return BehindSwitch(time: MediaTime(seconds: max(tm, 0)), behind: b)
                }.sorted { $0.time < $1.time }
                clip.behindSwitches = keys.isEmpty ? nil : keys
            }
            if let ks = p.json("keyframes")?.arrayValue {
                clip.keyframes = try keyframes(ks, rest: tr, video: video, clip: cid, command: id)
            }
            if p.has("brightness") || p.has("contrast") || p.has("saturation") {
                var col = clip.color ?? ColorAdjust()
                if let v = p.number("brightness") { col.brightness = v }
                if let v = p.number("contrast") { col.contrast = v }
                if let v = p.number("saturation") { col.saturation = v }
                clip.color = col.isIdentity ? nil : col
            }
            let sound = project.tracks[t].kind == .audio
            if !(mixed && !sound) {
                if let f = p.time("fadeIn") { clip.fadeIn = f > .zero ? min(f, clip.duration) : nil }
                if let f = p.time("fadeOut") { clip.fadeOut = f > .zero ? min(f, clip.duration) : nil }
            }
            if p.has("pictureFadeIn") || p.has("pictureFadeOut"), !sound {
                guard project.tracks[t].kind != .caption else { throw CommandError.conflict("\(id): clip \(cid) is on a caption track: picture fades are for video and overlay clips") }
                if let f = p.time("pictureFadeIn") { clip.pictureFadeIn = f > .zero ? min(f, clip.duration) : nil }
                if let f = p.time("pictureFadeOut") { clip.pictureFadeOut = f > .zero ? min(f, clip.duration) : nil }
            }
            if let g = p.number("gain") {
                guard project.tracks[t].kind == .audio else { throw CommandError.conflict("\(id): clip \(cid) is not on an audio track: gain is for sound") }
                guard (-60...24).contains(g) else { throw CommandError.invalid("\(id): gain must be −60…24 dB") }
                clip.gain = abs(g) < 0.005 ? nil : g
            }
            if let text = p.string("text") {
                guard clip.title != nil else { throw CommandError.conflict("\(id): clip \(cid) is not a title: text is for titles") }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommandError.invalid("\(id): text is empty") }
                clip.title?.text = text
            }
            if let given = p.json("fields")?.objectValue {
                guard let layer = clip.motion, let spec = MotionRegistry.spec(layer.template) else {
                    throw CommandError.conflict("\(id): clip \(cid) is not a motion template: fields are for motion.add clips")
                }
                for (k, v) in given.sorted(by: { $0.key < $1.key }) {
                    guard let f = spec.field(k) else {
                        throw CommandError.invalid("\(id): \(layer.template) has no field \"\(k)\" (fields: \(spec.fields.map(\.name).joined(separator: ", ")))")
                    }
                    if let problem = MotionAdd.check(v, f) { throw CommandError.invalid("\(id): field \(k): \(problem)") }
                    clip.motion?.fields[k] = v
                }
            }
            if let eid = p.string("effectId") {
                guard let amount = p.number("effectAmount") else { throw CommandError.invalid("\(id): effectId needs effectAmount") }
                guard let k = clip.effects?.firstIndex(where: { $0.id == eid }) else { throw CommandError.notFound("\(id): clip \(cid) has no effect \(eid)") }
                clip.effects?[k].amount = min(max(amount, 0), 1)
            } else if p.has("effectAmount") {
                throw CommandError.invalid("\(id): effectAmount needs effectId")
            }
            project.tracks[t].clips[c] = clip
        }
        ctx.project = project
        let clips = ids.compactMap { project.locate(clip: $0) }.map { project.tracks[$0.track].clips[$0.clip] }
        return ["clips": .array(clips.map(ProjectState.summary(of:)))]
    }

    /// Keyframes from JSON objects {time, crop?, scale?, x?, y?, rotation?, opacity?, easing?}, each starting from `rest`.
    static func keyframes(_ ks: [JSONValue], rest: Transform, video: VideoInfo?, clip: String, command: String) throws -> [Keyframe]? {
        let out = try ks.map { k -> Keyframe in
            guard let o = k.objectValue, let time = o["time"]?.doubleValue, time >= 0 else {
                throw CommandError.invalid("\(command): every keyframe needs a time ≥ 0 (seconds from the clip start)")
            }
            var easing: Easing?
            if let e = o["easing"]?.stringValue {
                guard let v = Easing(rawValue: e) else { throw CommandError.invalid("\(command): easing must be one of \(Easing.names.joined(separator: ", "))") }
                easing = v
            }
            var kt = rest
            try apply(o.filter { $0.key != "time" && $0.key != "easing" }, to: &kt, video: video, clip: clip)
            return Keyframe(time: MediaTime(seconds: time), transform: kt, easing: easing)
        }.sorted { $0.time < $1.time }
        return out.isEmpty ? nil : out
    }

    /// Transform fields of a params or keyframe object.
    static func apply(_ o: [String: JSONValue], to tr: inout Transform, video: VideoInfo?, clip: String) throws {
        if let crop = o["crop"]?.arrayValue?.compactMap(\.doubleValue) {
            guard let video else { throw CommandError.conflict("\(id): clip \(clip) has no picture to crop") }
            guard crop.count == 4, crop[0] > 0, crop[1] > 0, crop[2] >= 0, crop[3] >= 0,
                  crop[0] + crop[2] <= Double(video.width) + 0.5, crop[1] + crop[3] <= Double(video.height) + 0.5 else {
                throw CommandError.invalid("\(id): crop must be [w, h, x, y] inside the \(video.width)×\(video.height) source")
            }
            let keep = (tr.scale, tr.x, tr.y, tr.rotation, tr.opacity)
            tr = Transform(crop: crop, sourceWidth: video.width, sourceHeight: video.height)
            (tr.scale, tr.x, tr.y, tr.rotation, tr.opacity) = keep
        }
        if let v = o["scale"]?.doubleValue { guard v > 0 else { throw CommandError.invalid("\(id): scale must be > 0") }; tr.scale = v }
        if let v = o["x"]?.doubleValue { tr.x = v }
        if let v = o["y"]?.doubleValue { tr.y = v }
        if let v = o["rotation"]?.doubleValue { tr.rotation = v }
        if let v = o["opacity"]?.doubleValue { tr.opacity = min(max(v, 0), 1) }
        if let v = o["anchorX"]?.doubleValue { tr.anchorX = v }
        if let v = o["anchorY"]?.doubleValue { tr.anchorY = v }
        if let v = o["rotationX"]?.doubleValue { tr.rotationX = v }
        if let v = o["rotationY"]?.doubleValue { tr.rotationY = v }
        if let v = o["perspective"]?.doubleValue { guard v > 50 else { throw CommandError.invalid("\(id): perspective must be > 50 px") }; tr.perspective = v }
    }
}
