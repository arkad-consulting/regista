import Foundation

enum HandsTrack: Command {
    static let id = "hands.track"
    static let summary = "Track the hands of a video asset over a source range (Apple Vision hand pose): per frame each hand's palm centre, wrist, index tip, box, how open it is (0 fist … 1 open) and left/right, saved as a sidecar JSON. Needed by clip.follow target: hand (an object, logo or sticker sitting on the open palm). Keep the range short (the seconds where the gesture happens): ~40 frames/s on the Base tier. Returns frames, frames with a hand, open-palm frames and where the palm is on average."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("assetId", .string, "Video asset."),
        .optional("from", .time, "Source start, seconds (default 0)."),
        .optional("to", .time, "Source end, seconds (default: from + 10 s, at most the asset's end)."),
        .optional("maxHands", .integer, "Hands per frame (default 2)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let i = try Analysis.assetIndex(p.requiredString("assetId"), in: project, command: id)
        let asset = project.assets[i]
        guard asset.video != nil, asset.image == nil else { throw CommandError.conflict("\(id): \(asset.name) is not a video") }
        guard let tracker = ctx.services.hands else {
            throw CommandError(.io, "\(id): no hand engine in this host (use regista-engine / regista-mcp, which include Apple Vision)")
        }
        let from = max(p.time("from")?.seconds ?? 0, 0)
        let to = min(p.time("to")?.seconds ?? from + 10, asset.duration.seconds)
        guard to > from else { throw CommandError.invalid("\(id): the range is empty") }
        let started = Date()
        let track = try tracker.track(URL(fileURLWithPath: asset.path), from: from, to: to, maxHands: p.int("maxHands") ?? 2)
        let file = try ctx.mediaDirectory().appendingPathComponent("\(asset.id)-hands.json")
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { try e.encode(track).write(to: file, options: .atomic) }
        catch { throw CommandError(.io, "\(id): cannot write \(file.path): \(error.localizedDescription)") }
        project.assets[i].analysis = project.assets[i].analysis ?? AssetAnalysis()
        project.assets[i].analysis?.hands = HandTrackSummary(path: file.path, frames: track.frames.count, detected: track.detected, from: from, to: to)
        ctx.project = project
        let palms = track.frames.compactMap { HandTrack.pick($0.hands, chirality: nil, minOpen: 0)?.palm }
        let open = track.frames.filter { HandTrack.pick($0.hands, chirality: nil, minOpen: 0.45) != nil }.count
        func mean(_ k: Int) -> JSONValue { palms.isEmpty ? .null : .number((palms.map { $0[k] }.reduce(0, +) / Double(palms.count)).rounded()) }
        return ["assetId": .string(asset.id), "sidecar": .string(file.path), "from": .number(from), "to": .number(to),
                "frames": .number(Double(track.frames.count)), "withHand": .number(Double(track.detected)), "openPalm": .number(Double(open)),
                "meanPalm": .array([mean(0), mean(1)]), "engine": .string(track.engine),
                "seconds": Analysis.seconds(Date().timeIntervalSince(started), places: 10)]
    }
}

enum ClipFollow: Command {
    static let id = "clip.follow"
    static let summary = "Make an overlay (sticker, logo, image, title) follow a tracked point of the speaker: target face (its centre or just above the head; needs faces.track) or hand (the palm, index tip or wrist; needs hands.track over the clip's window). Writes dense transform keyframes (every 2 frames, smoothed), keeping the clip's own animation, so it stays an ordinary undoable edit. For an object held in the hand: hover lifts it above the palm with a gentle float, spin turns it in depth (rotationY, or flat with spinAxis z), halo adds a glowing ellipse under it, openOnly shows it only while the palm is open (fading in and out). Returns the keyframes written and how much of the window the target was visible."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("clipId", .string, "The follower (a placed overlay: sticker, logo, image, title)."),
        .required("target", .oneOf(["face", "hand"]), "What it follows."),
        .optional("assetId", .string, "Tracked video asset (default: the main video under the clip)."),
        .optional("point", .oneOf(["center", "top", "palm", "index", "wrist"]), "face: center (default) or top (above the head); hand: palm (default), index or wrist."),
        .optional("hand", .oneOf(["left", "right", "any"]), "Which hand (default any: the most open one)."),
        .optional("openOnly", .boolean, "hand: show only while the palm is open (default true)."),
        .optional("offset", .array(.number), "[dx, dy] px at 1080×1920 from the point (default [0, 0])."),
        .optional("hover", .number, "Px above the point with a slow ±6 px float (default 0; 60–120 for an object over the palm)."),
        .optional("spin", .number, "Seconds per turn (default 0 = no spin; 2.5 reads as a slow showcase turn)."),
        .optional("spinAxis", .oneOf(["y", "z"]), "y (default): turns in depth around its vertical axis, like a coin on a turntable; z: spins flat."),
        .optional("halo", .boolean, "Add a glowing ellipse under the object, following the point (default false)."),
        .optional("haloColor", .string, "Halo colour (#RRGGBB or a brand role; default the kit's highlight, else #FFB066)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let (t0, c) = try Timeline.locate(clip: p.requiredString("clipId"), in: project)
        var t = t0
        var clip = project.tracks[t].clips[c]
        guard clip.placement.map({ $0.fit != .fill }) ?? clip.isGenerated, clip.shape == nil, !clip.isFullFramePicture else {
            throw CommandError.conflict("\(id): \(clip.id) fills the frame: follow moves placed overlays (stickers, logos, images, titles)")
        }
        let target = p.requiredString("target")
        let rate = project.settings.frameRate
        let W = Double(project.settings.width), H = Double(project.settings.height)
        let kx = W / SafeZones.referenceWidth, ky = H / SafeZones.referenceHeight
        // The tracked asset: given, else the main video's clip under the follower's start.
        let assetID: String
        if let a = p.string("assetId") { assetID = a }
        else {
            guard let main = EffectsCatalog.mainClip(at: clip.start, in: project) else { throw CommandError.conflict("\(id): no video under the clip: pass assetId") }
            assetID = main.assetID
        }
        guard let asset = project.asset(assetID) else { throw CommandError.notFound("\(id): no asset \(assetID)") }
        let point = p.string("point") ?? (target == "face" ? "center" : "palm")
        let openOnly = target == "hand" && (p.bool("openOnly") ?? true)
        // Source point (and size) at a source time.
        let locate: (Double) -> (pt: [Double], size: Double)?
        if target == "face" {
            guard let path = asset.analysis?.faces?.path, let data = FileManager.default.contents(atPath: path),
                  let track = try? JSONDecoder().decode(FaceTrack.self, from: data) else {
                throw CommandError.conflict("\(id): \(asset.name) has no face track — run faces.track {assetId: \"\(asset.id)\"}")
            }
            locate = { s in
                guard let f = track.frame(at: s), let b = f.smooth ?? f.raw else { return nil }
                return ([b[0] + b[2] / 2, point == "top" ? b[1] - 0.55 * b[3] : b[1] + b[3] / 2], b[2])
            }
        } else {
            guard let path = asset.analysis?.hands?.path, let data = FileManager.default.contents(atPath: path),
                  let track = try? JSONDecoder().decode(HandTrack.self, from: data) else {
                throw CommandError.conflict("\(id): \(asset.name) has no hand track — run hands.track {assetId: \"\(asset.id)\", from, to} over the gesture")
            }
            let which = p.string("hand")
            locate = { s in
                guard let f = track.frame(at: s), let h = HandTrack.pick(f.hands, chirality: which, minOpen: openOnly ? 0.45 : 0) else { return nil }
                return (h.point(point), max(h.box[2], h.box[3]))
            }
        }
        // Every frame of the follower's window, through the layer that shows the asset (full frame or a layout box).
        let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: false)
        let frame = MediaTime.frameDuration(at: rate)
        var samples: [FollowPath.Sample] = []
        var at = clip.start
        while at < clip.end {
            var s = FollowPath.Sample(t: at, point: nil, size: nil)
            if let layer = job.layers(at: at).last(where: { $0.assetID == assetID && $0.opacity > 0.01 && $0.placement?.fit != .native }),
               let found = locate(layer.sourceTime.seconds), let o = FollowPath.toOutput(found.pt, layer: layer, width: Int(W), height: Int(H)) {
                s.point = o
                s.size = found.size * ((layer.placement == nil ? W : layer.baseSize(width: Int(W), height: Int(H)).0) / max(layer.crop[0], 1))
            }
            samples.append(s)
            at = at + frame
        }
        samples = FollowPath.smooth(samples, rate: rate.doubleValue)
        let visible = samples.filter { $0.point != nil }.count
        guard visible > 0 else {
            throw CommandError.conflict("\(id): the \(target) is never visible during the clip (\(clip.start.displaySeconds)–\(clip.end.displaySeconds) s)\(openOnly ? " with an open palm (openOnly: false to follow a closed hand)" : "")")
        }
        let home = clip.placement.map { ($0.x, $0.y) } ?? (0.5, 0.5)
        let off = p.numbers("offset") ?? [0, 0]
        let hover = (p.number("hover") ?? 0) * ky
        let spin = p.number("spin") ?? 0
        // Fade in/out over ~0.15 s where the target appears or is lost.
        let fadeFrames = max(Int((0.15 * rate.doubleValue).rounded()), 1)
        let vis = samples.map { $0.point != nil }
        func fade(_ i: Int) -> Double {
            guard vis[i] else { return 0 }
            var d = fadeFrames
            for k in 1...fadeFrames { if i - k < 0 || !vis[i - k] || i + k >= vis.count || !vis[i + k] { d = min(d, k - 1); break } }
            if i - fadeFrames < 0, (0..<i).allSatisfy({ vis[$0] }) { d = fadeFrames }   // visible from the clip start: no fade-in
            return min(Double(d) / Double(fadeFrames), 1)
        }
        // The animation before the first follow (or move by hand) is the base, so running clip.follow again replaces its
        // own keyframes instead of stacking on them; clip.place reset goes back to it.
        if clip.placeOrigin == nil { clip.placeOrigin = PlaceOrigin(placement: clip.placement, transform: clip.transform, keyframes: clip.keyframes) }
        var original = clip
        original.transform = clip.placeOrigin?.transform
        original.keyframes = clip.placeOrigin?.keyframes
        var keys: [Keyframe] = []
        var lastPoint = samples.first { $0.point != nil }!.point!
        var haloKeys: [Keyframe] = []
        for (i, s) in samples.enumerated() where i % 2 == 0 || i == samples.count - 1 || vis[i] != vis[max(i - 1, 0)] {
            let local = s.t - clip.start
            var tr = original.transform(at: local)
            let pt = s.point ?? lastPoint
            lastPoint = pt
            let bob = hover > 0 ? 6 * ky * sin(2 * .pi * local.seconds / 2.4) : 0
            tr.x = (pt.x + off[0] * kx) / W - home.0
            tr.y = (pt.y + (off[safe: 1] ?? 0) * ky - hover + bob) / H - home.1
            if spin > 0 {
                var a = (360 * local.seconds / spin).truncatingRemainder(dividingBy: 360)
                if p.string("spinAxis") == "z" { tr.rotation += a }
                else {
                    // Never exactly edge-on (a degenerate quad for the projection).
                    if abs(cos(a * .pi / 180)) < 0.03 { a += 2 }
                    tr.rotationY += a
                }
            }
            tr.opacity *= openOnly || target == "face" ? fade(i) : 1
            keys.append(Keyframe(time: local, transform: tr))
            var h = Transform()
            h.x = (pt.x + off[0] * kx) / W - 0.5
            h.y = (pt.y + (off[safe: 1] ?? 0) * ky) / H - 0.5
            h.opacity = openOnly ? fade(i) : 1
            haloKeys.append(Keyframe(time: local, transform: h))
        }
        clip.keyframes = keys
        project.tracks[t].clips[c] = clip
        var haloID: JSONValue = .null
        // A halo of an earlier follow of this clip (the track right under it) is replaced (or removed).
        if t > 0, project.tracks[t - 1].name == "Halo", project.tracks[t - 1].clips.count == 1, project.tracks[t - 1].clips[0].start == clip.start {
            project.tracks.remove(at: t - 1)
            t -= 1
        }
        if p.bool("halo") == true {
            // The halo goes on its own overlay track just under the follower's.
            let brand = project.brand
            let color = p.string("haloColor").map { brand?.color($0) ?? $0 } ?? brand?.colors["highlight"] ?? "#FFB066"
            let size = (samples.compactMap(\.size).sorted().dropFirst(samples.count / 2).first ?? 220 * kx)
            let hw = min(max(size * 1.5, 220 * kx), 560 * kx), hh = hw * 0.28
            var shape = ShapeLayer(kind: .halo, rect: [0.5 - hw / W / 2, 0.5 - hh / H / 2, hw / W, hh / H], color: color, width: 5, drawOn: 0.3)
            shape.trackColor = nil
            let track = Track(id: project.makeID("t"), kind: .overlay, name: "Halo", clips: [], role: "overlays")
            project.tracks.insert(track, at: t)
            let hid = project.makeID("c")
            project.tracks[t].clips = [Clip(id: hid, assetID: "", sourceIn: .zero, sourceOut: clip.duration, start: clip.start, keyframes: haloKeys, shape: shape)]
            haloID = .string(hid)
        }
        ctx.project = project
        return ["clipId": .string(clip.id), "target": .string(target), "point": .string(point), "assetId": .string(assetID),
                "keyframes": .number(Double(keys.count)), "frames": .number(Double(samples.count)), "visibleFrames": .number(Double(visible)),
                "visibleRatio": .number((Double(visible) / Double(samples.count) * 1000).rounded() / 1000), "haloClip": haloID]
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
