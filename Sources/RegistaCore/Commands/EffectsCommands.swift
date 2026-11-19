import Foundation

// Effects for users (issue #16): looks and adjustments, speed, stickers, callouts, progress bar, logo motions.
// Each is an ordinary edit command (undo, agent log, MCP), so the app's gallery and Claude do the same thing.

enum EffectsJSON {
    static func speed(_ s: Speed) -> JSONValue {
        var o: [String: JSONValue] = ["rate": .number(s.rate), "duration": ProjectState.seconds(s.duration), "audio": .string(s.effectiveAudio.rawValue)]
        if let r = s.ramp, !r.isEmpty { o["ramp"] = .array(r.map { ["time": ProjectState.seconds($0.time), "rate": .number($0.value)] }) }
        if s.reverse == true { o["reverse"] = true }
        if s.freeze == true { o["freeze"] = true }
        return .object(o)
    }

    static func grade(_ g: Grade) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if let l = g.look { o["look"] = .string(l); o["amount"] = .number(g.amount ?? 1) }
        if let a = g.adjust, !a.isIdentity {
            var adj: [String: JSONValue] = [:]
            for n in Adjustments.names where a[n] != 0 { adj[n] = .number((a[n] * 1000).rounded() / 1000) }
            o["adjust"] = .object(adj)
        }
        if let k = g.keys, !k.isEmpty { o["keyframed"] = .array(k.keys.sorted().map { .string($0) }) }
        return .object(o)
    }

    /// Clip ids from clipId / clipIds.
    static func clipIDs(_ p: CommandParams) -> [String] {
        var ids = p.strings("clipIds") ?? []
        if let one = p.string("clipId") { ids.insert(one, at: 0) }
        return ids
    }

    /// Keyframes {time (timeline s), value, easing} as clip-relative scalar keys.
    static func keys(_ v: JSONValue, offset: MediaTime, rate: Rational, command: String) throws -> [ScalarKey] {
        guard let arr = v.arrayValue else { throw CommandError.invalid("\(command): keyframes are arrays of {time, value, easing?}") }
        return try arr.map { k in
            guard let o = k.objectValue, let t = o["time"]?.doubleValue, let value = o["value"]?.doubleValue else {
                throw CommandError.invalid("\(command): keyframes are {time, value, easing?}")
            }
            let local = max(MediaTime(seconds: t).snapped(to: rate) - offset, .zero)
            return ScalarKey(time: local, value: value, easing: o["easing"]?.stringValue.flatMap(Easing.init(rawValue:)))
        }.sorted { $0.time < $1.time }
    }
}

/// Shifts the edit after a retime or a freeze frame.
enum Retime {
    /// Every clip (all tracks) starting at or after `from` moves by `delta`, except `except`; unanchored transitions
    /// and markers follow.
    static func ripple(_ project: inout Project, from: MediaTime, by delta: MediaTime, except: Set<String>) {
        guard delta != .zero else { return }
        for t in project.tracks.indices {
            for c in project.tracks[t].clips.indices where !except.contains(project.tracks[t].clips[c].id) && project.tracks[t].clips[c].start >= from {
                project.tracks[t].clips[c].start += delta
            }
            project.tracks[t].sortClips()
        }
        if var trs = project.transitions {
            for i in trs.indices where trs[i].clipID == nil && trs[i].at >= from { trs[i].at += delta }
            project.transitions = trs
        }
        for i in project.markers.indices where project.markers[i].time >= from { project.markers[i].time += delta }
    }

    static func captionWarning(_ project: Project) -> [JSONValue] {
        project.tracks.contains { $0.captions != nil }
            ? [.string("captions were timed before this change: run captions.generate again so they follow the new timing")] : []
    }
}

// MARK: - Looks & adjustments

enum LookList: Command {
    static let id = "look.list"
    static let summary = "List the colour looks (filters) for look.apply — id, Italian name, what it does — and the Photos-style adjustments for adjust.set with their ranges. Returns looks and adjustments."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        ["looks": .array(Look.all.map { ["id": .string($0.id), "label": .string($0.label), "summary": .string($0.summary)] }),
         "adjustments": .array(Adjustments.properties.map { ["name": .string($0.name), "label": .string($0.label),
                                                             "min": .number($0.range.lowerBound), "max": .number($0.range.upperBound)] }),
         "project": ctx.project?.grade.map(EffectsJSON.grade) ?? .null]
    }
}

enum LookApply: Command {
    static let id = "look.apply"
    static let summary = "Apply a colour look (filter) with an intensity, to clips or — with no clip — to the whole picture (video, inserts and layout boxes; titles, stickers, logos keep their colours). Looks: golden (Dorato), frost (Brina), film (Pellicola), graphite (Grafite, b&w), ink (Inchiostro, hard b&w), vivid (Vivido), velvet (Velluto), riviera (Riviera, teal & orange), archive (Archivio), matte (Opaco), sunset (Tramonto), fjord (Fiordo), night (Notte), airy (Luce); none removes it. Intensity 0 draws exactly the original. Taste: one look for the whole reel, 40–70 %. Returns the grade."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("look", .oneOf(Look.ids + ["none"]), "Look id (look.list), or none."),
        .optional("amount", .number, "Intensity 0…1 (default 1; 0.5 is often enough)."),
        .optional("clipId", .string, "Clip (default: the whole picture)."),
        .optional("clipIds", .array(.string), "Several clips."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let look = p.requiredString("look")
        if let a = p.number("amount"), !(0...1).contains(a) { throw CommandError.invalid("\(id): amount is 0…1") }
        func update(_ g: Grade?) -> Grade? {
            var g = g ?? Grade()
            g.look = look == "none" ? nil : look
            g.amount = look == "none" ? nil : p.number("amount") ?? 1
            if look == "none" { g.keys?["amount"] = nil }
            return g.isEmpty ? nil : g
        }
        let ids = EffectsJSON.clipIDs(p)
        if ids.isEmpty {
            project.grade = update(project.grade)
            ctx.project = project
            return ["scope": "project", "grade": project.grade.map(EffectsJSON.grade) ?? .null]
        }
        var out: [JSONValue] = []
        for cid in ids {
            let (t, c) = try Timeline.locate(clip: cid, in: project)
            try visual(project.tracks[t].clips[c], project, command: id)
            project.tracks[t].clips[c].grade = update(project.tracks[t].clips[c].grade)
            out.append(["clipId": .string(cid), "grade": project.tracks[t].clips[c].grade.map(EffectsJSON.grade) ?? .null])
        }
        ctx.project = project
        return ["scope": "clips", "clips": .array(out)]
    }

    static func visual(_ clip: Clip, _ project: Project, command: String) throws {
        guard !clip.isGenerated, project.asset(clip.assetID)?.video != nil else {
            throw CommandError.conflict("\(command): clip \(clip.id) has no picture to grade (titles and stickers keep their colours)")
        }
    }
}

enum AdjustSet: Command {
    static let id = "adjust.set"
    static let summary = "Photos-style adjustments on clips or — with no clip — the whole picture: exposure, brilliance, highlights, shadows, contrast, saturation, warmth, tint (each −1…1, 0 = untouched), sharpness and vignette (0…1). Only the values passed change; reset: true clears them first. keyframes animate any of them (or the look intensity, \"amount\") over timeline time: {\"exposure\": [{time, value, easing}]}. Returns the grade."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("clipId", .string, "Clip (default: the whole picture)."),
        .optional("clipIds", .array(.string), "Several clips."),
        .optional("reset", .boolean, "Set every adjustment back to 0 (and drop their keyframes) before applying the values passed."),
        .optional("keyframes", .object, "Per property: [{time (timeline s), value, easing}] — replaces that property's keyframes; [] removes them."),
    ] + Adjustments.properties.map { .optional($0.name, .number, "\($0.label): \($0.range.lowerBound == 0 ? "0…1" : "−1…1").") }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        var values: [String: Double] = [:]
        for prop in Adjustments.properties {
            guard let v = p.number(prop.name) else { continue }
            guard prop.range.contains(v) else {
                throw CommandError.invalid("\(id): \(prop.name) must be in \(prop.range.lowerBound)…\(prop.range.upperBound), got \(v)")
            }
            values[prop.name] = v
        }
        let keyframes = p.json("keyframes")?.objectValue ?? [:]
        for name in keyframes.keys where name != "amount" && Adjustments.range(of: name) == nil {
            throw CommandError.invalid("\(id): keyframes for unknown property \"\(name)\" (properties: \(Adjustments.names.joined(separator: ", ")), amount)")
        }
        guard !values.isEmpty || !keyframes.isEmpty || p.bool("reset") == true else {
            throw CommandError.invalid("\(id): pass at least one adjustment, keyframes or reset")
        }
        let rate = project.settings.frameRate
        func update(_ g: Grade?, offset: MediaTime) throws -> Grade? {
            var g = g ?? Grade()
            var a = g.adjust ?? Adjustments()
            if p.bool("reset") == true {
                a = Adjustments()
                for n in Adjustments.names { g.keys?[n] = nil }
            }
            for (n, v) in values { a[n] = v }
            g.adjust = a.isIdentity ? nil : a
            for (n, v) in keyframes {
                let ks = try EffectsJSON.keys(v, offset: offset, rate: rate, command: id)
                if let r = n == "amount" ? 0...1 : Adjustments.range(of: n), let bad = ks.first(where: { !r.contains($0.value) }) {
                    throw CommandError.invalid("\(id): keyframe value \(bad.value) of \(n) is outside \(r.lowerBound)…\(r.upperBound)")
                }
                var all = g.keys ?? [:]
                all[n] = ks.isEmpty ? nil : ks
                g.keys = all.isEmpty ? nil : all
            }
            return g.isEmpty ? nil : g
        }
        let ids = EffectsJSON.clipIDs(p)
        if ids.isEmpty {
            project.grade = try update(project.grade, offset: .zero)
            ctx.project = project
            return ["scope": "project", "grade": project.grade.map(EffectsJSON.grade) ?? .null]
        }
        var out: [JSONValue] = []
        for cid in ids {
            let (t, c) = try Timeline.locate(clip: cid, in: project)
            let clip = project.tracks[t].clips[c]
            try LookApply.visual(clip, project, command: id)
            project.tracks[t].clips[c].grade = try update(clip.grade, offset: clip.start)
            out.append(["clipId": .string(cid), "grade": project.tracks[t].clips[c].grade.map(EffectsJSON.grade) ?? .null])
        }
        ctx.project = project
        return ["scope": "clips", "clips": .array(out)]
    }
}

// MARK: - Speed

enum SpeedPreset: String, CaseIterable {
    case normal, slowmo, superSlowmo, fast, timelapse, hero, rampIn, rampOut, reverse
    static let names = allCases.map(\.rawValue)

    /// The speed for a source span of `span` seconds (duration filled in by the command).
    func speed(span: Double) -> Speed? {
        var s = Speed(duration: .zero)
        func key(_ f: Double, _ r: Double, _ e: Easing? = .easeInOut) -> ScalarKey { ScalarKey(time: MediaTime(seconds: f * span), value: r, easing: e) }
        switch self {
        case .normal: return nil
        case .slowmo: s.rate = 0.5
        case .superSlowmo: s.rate = 0.25
        case .fast: s.rate = 2
        case .timelapse: s.rate = 4
        case .hero: s.ramp = [key(0, 1), key(0.3, 0.3, .linear), key(0.6, 0.3), key(1, 1, nil)]
        case .rampIn: s.ramp = [key(0, 2), key(0.65, 0.5, nil)]
        case .rampOut: s.ramp = [key(0, 0.5), key(0.65, 2, nil)]
        case .reverse: s.reverse = true
        }
        return s
    }
}

enum ClipSpeed: Command {
    static let id = "clip.speed"
    static let summary = "Change a clip's speed: a constant rate (0.5 = slow motion, 2 = double), a preset (slowmo, superSlowmo 0.25×, fast, timelapse 4×, hero = normal → slow → normal, rampIn = fast → slow, rampOut = slow → fast, reverse, normal = reset), an explicit ramp of rates [{time (s into the clip's source), rate, easing}], reverse (plays backwards, ≤ 30 s, a reversed proxy is made with ffmpeg), or a freeze frame (freezeAt + freezeDuration: the clip is cut there and that frame holds). The linked sound follows: pitch kept (time-stretched) between 0.25× and 4×, muted outside, when reversed or frozen. Later clips on every track move to make room (ripple, default true). Run captions.generate again afterwards. Returns the clip(s) and the new duration."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("clipId", .string, "Clip to retime (its linked sound follows unless linked: false)."),
        .optional("rate", .number, "Constant speed 0.1…16 (1 = normal)."),
        .optional("preset", .oneOf(SpeedPreset.names), "Ready-made speed."),
        .optional("ramp", .array(.object), "Rate keyframes [{time (s from the clip's source start), rate, easing}] (a speed ramp)."),
        .optional("reverse", .boolean, "Play backwards (with rate, at that speed)."),
        .optional("freezeAt", .time, "Timeline time of a freeze frame inside the clip."),
        .optional("freezeDuration", .time, "How long the frame holds (default 1 s)."),
        .optional("audio", .oneOf(Speed.AudioMode.allCases.map(\.rawValue)), "pitch (time-stretched, pitch kept) or mute; default: pitch between 0.25× and 4×, else mute."),
        .optional("ripple", .boolean, "Move later clips (all tracks) by the length change (default true; false fails if the clip would overlap the next)."),
        Timeline.linkedParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let cid = p.requiredString("clipId")
        let (t, c) = try Timeline.locate(clip: cid, in: project)
        let clip = project.tracks[t].clips[c]
        guard !clip.isGenerated, let asset = project.asset(clip.assetID), asset.image == nil else {
            throw CommandError.conflict("\(id): \(cid) is not a video or sound clip")
        }
        if let at = p.time("freezeAt") { return try freeze(clip, track: t, at: at, p, &project, &ctx) }

        // The speed asked for.
        let span = clip.sourceDuration.seconds
        var speed: Speed?
        if let name = p.string("preset"), let preset = SpeedPreset(rawValue: name) { speed = preset.speed(span: span) }
        if let r = p.number("rate") {
            guard (Speed.minRate...Speed.maxRate).contains(r) else { throw CommandError.invalid("\(id): rate must be \(Speed.minRate)…\(Speed.maxRate)") }
            speed = speed ?? Speed(duration: .zero)
            speed!.rate = r
            if speed!.ramp != nil, !p.has("preset") { speed!.ramp = nil }
        }
        if let ks = p.json("ramp")?.arrayValue {
            let keys = try ks.map { k -> ScalarKey in
                guard let o = k.objectValue, let tm = o["time"]?.doubleValue, let r = o["rate"]?.doubleValue else {
                    throw CommandError.invalid("\(id): ramp keys are {time, rate, easing?}")
                }
                guard (Speed.minRate...Speed.maxRate).contains(r) else { throw CommandError.invalid("\(id): ramp rate \(r) outside \(Speed.minRate)…\(Speed.maxRate)") }
                return ScalarKey(time: MediaTime(seconds: min(max(tm, 0), span)), value: r, easing: o["easing"]?.stringValue.flatMap(Easing.init(rawValue:)))
            }.sorted { $0.time < $1.time }
            guard !keys.isEmpty else { throw CommandError.invalid("\(id): ramp is empty") }
            speed = speed ?? Speed(duration: .zero)
            speed!.ramp = keys
        }
        if let rev = p.bool("reverse") {
            speed = speed ?? Speed(duration: .zero)
            speed!.reverse = rev ? true : nil
        }
        if let a = p.string("audio") {
            speed = speed ?? Speed(duration: clip.duration)
            speed!.audio = Speed.AudioMode(rawValue: a)
        }
        guard p.has("preset") || p.has("rate") || p.has("ramp") || p.has("reverse") || p.has("audio") else {
            throw CommandError.invalid("\(id): pass rate, preset, ramp, reverse, audio or freezeAt")
        }
        if var s = speed {
            if s.reverse == true, s.isRamp { throw CommandError.invalid("\(id): a reversed clip plays at one constant rate (no ramp)") }
            if s.reverse == true, span > 30 { throw CommandError.invalid("\(id): reverse works on clips up to 30 s (this one has \(Int(span)) s): cut it first") }
            let rate = project.settings.frameRate
            let frame = MediaTime.frameDuration(at: rate)
            s.duration = max(MediaTime(seconds: s.timelineSeconds(forSource: span)).snapped(to: rate), frame)
            let identity = s.rate == 1 && !s.isRamp && s.reverse != true && s.audio == nil
            speed = identity ? nil : s
        }

        // The clip and its linked partners covering the same span.
        var targets = [(t, c)]
        var skipped: [JSONValue] = []
        if p.bool("linked") ?? true {
            for q in Timeline.partners(of: clip, in: project) {
                let other = project.tracks[q.track].clips[q.clip]
                if other.start == clip.start && other.sourceIn == clip.sourceIn && other.sourceOut == clip.sourceOut { targets.append(q) }
                else { skipped.append(.string("linked clip \(other.id) covers a different span: not retimed")) }
            }
        }
        if let s = speed, s.reverse == true {
            // One reversed proxy of the source range, read by the picture.
            let proxy = try reversedProxy(asset, clip: clip, &ctx)
            speed!.proxy = proxy
            _ = s
        }
        let oldEnd = clip.end
        let newDuration = speed?.duration ?? clip.sourceDuration
        let ids = Set(targets.map { project.tracks[$0.0].clips[$0.1].id })
        for (tt, cc) in targets {
            var s = speed
            if project.asset(project.tracks[tt].clips[cc].assetID)?.video == nil { s?.proxy = nil }
            project.tracks[tt].clips[cc].speed = s
        }
        let delta = newDuration - clip.duration
        if p.bool("ripple") ?? true {
            Retime.ripple(&project, from: oldEnd, by: delta, except: ids)
        } else {
            for (tt, cc) in targets {
                let x = project.tracks[tt].clips[cc]
                try Timeline.checkFree(project.tracks[tt], start: x.start, end: x.end, except: x.id)
            }
        }
        ctx.project = project
        let retimed = targets.map { ProjectState.summary(of: project.tracks[$0.0].clips[$0.1]) }
        return ["clip": retimed[0], "linked": .array(Array(retimed.dropFirst())), "duration": ProjectState.seconds(newDuration),
                "delta": .number(delta.displaySeconds), "speed": speed.map(EffectsJSON.speed) ?? .null,
                "warnings": .array(skipped + (delta != .zero ? Retime.captionWarning(project) : []))]
    }

    /// Cuts the clip (and its linked partners) at `at`, inserts a frozen frame of `freezeDuration` and moves the rest.
    static func freeze(_ clip: Clip, track t: Int, at raw: MediaTime, _ p: CommandParams, _ project: inout Project, _ ctx: inout CommandContext) throws -> JSONValue {
        let rate = project.settings.frameRate
        let at = raw.snapped(to: rate)
        guard at >= clip.start, at < clip.end else {
            throw CommandError.invalid("\(id): freezeAt must be inside \(clip.id) [\(clip.start.displaySeconds), \(clip.end.displaySeconds))s")
        }
        guard project.asset(clip.assetID)?.video != nil else { throw CommandError.conflict("\(id): \(clip.id) has no picture to freeze") }
        let hold = (p.time("freezeDuration") ?? MediaTime(seconds: 1)).snapped(to: rate)
        guard hold > .zero else { throw CommandError.invalid("\(id): freezeDuration must be > 0") }
        let local = at - clip.start
        var frozen = clip
        frozen.id = project.makeID("c")
        frozen.link = nil
        frozen.sourceIn = clip.sourceTime(atLocal: local)
        frozen.sourceOut = frozen.sourceIn + MediaTime.frameDuration(at: rate)
        frozen.start = at
        let rest = clip.transform(at: local)
        frozen.transform = rest == Transform() ? nil : rest
        frozen.keyframes = nil
        frozen.effects = nil
        frozen.fadeIn = nil
        frozen.fadeOut = nil
        var sp = Speed(duration: hold)
        sp.freeze = true
        frozen.speed = sp

        // Cut everything linked that runs through the freeze point, like timeline.cut.
        var cuts = [(t, project.tracks[t].clips.firstIndex { $0.id == clip.id }!)]
        if p.bool("linked") ?? true { cuts += Timeline.partners(of: clip, in: project) }
        var rightLinks: [String: String] = [:]
        for (tt, _) in cuts {
            guard let ci = project.tracks[tt].clips.firstIndex(where: { $0.start < at && at < $0.end && ($0.id == clip.id || ($0.link != nil && $0.link == clip.link)) }) else { continue }
            let original = project.tracks[tt].clips[ci]
            var (left, right) = original.split(at: at - original.start, rightID: project.makeID("c"))
            if let link = left.link {
                if rightLinks[link] == nil { rightLinks[link] = project.makeID("l") }
                right.link = rightLinks[link]
            }
            project.tracks[tt].clips[ci] = left
            project.tracks[tt].clips.insert(right, at: ci + 1)
        }
        Retime.ripple(&project, from: at, by: hold, except: [])
        project.tracks[t].clips.append(frozen)
        project.tracks[t].sortClips()
        ctx.project = project
        return ["clip": ProjectState.summary(of: frozen), "duration": ProjectState.seconds(hold), "delta": .number(hold.displaySeconds),
                "warnings": .array(Retime.captionWarning(project))]
    }

    /// The clip's source range reversed by ffmpeg into the project's media folder (reused when it exists).
    static func reversedProxy(_ asset: MediaAsset, clip: Clip, _ ctx: inout CommandContext) throws -> String {
        let dir = try ctx.mediaDirectory()
        let stem = URL(fileURLWithPath: asset.path).deletingPathExtension().lastPathComponent
        let url = dir.appendingPathComponent("\(stem)-reversed-\(clip.sourceIn.ticks)-\(clip.sourceOut.ticks).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        let tmp = dir.appendingPathComponent("tmp-\(UUID().uuidString.prefix(6)).mp4")
        let ffmpeg = ctx.services.config.url(ctx.services.config.ffmpeg)
        do {
            try Subprocess.check(ffmpeg, FFmpegAudio.quiet + ["-ss", String(format: "%.6f", clip.sourceIn.seconds), "-i", asset.path,
                                                               "-t", String(format: "%.6f", clip.sourceDuration.seconds), "-vf", "reverse", "-an",
                                                               "-c:v", "h264_videotoolbox", "-q:v", "75", "-pix_fmt", "yuv420p", tmp.path])
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw CommandError(.io, "\(id): cannot make the reversed copy of \(asset.name): \(error)")
        }
        return url.path
    }
}

// MARK: - Stickers, callouts, progress bar

enum StickerAdd: Command {
    static let id = "sticker.add"
    static let summary = "Pop an emoji or an SF Symbol over the video: a library sticker (fire, sparkles, eyes, idea, check, cross, rocket, point, laugh, target, heart, clap; symbols seal, star, bolt, arrowDown, tap, warning, bulb, click, bell, thumbsUp), any emoji, or any SF Symbol name, with a size, colour (symbols), optional round badge, position (top band by default) and a pop (default) or bounce entrance. Taste: one sticker on a punchline, short (1–1.5 s), never in the caption band. Returns the clip and its box with layout warnings."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("sticker", .oneOf(StickerLibrary.items.map(\.id)), "Library sticker."),
        .optional("emoji", .string, "An emoji instead."),
        .optional("symbol", .string, "An SF Symbol name instead (e.g. checkmark.seal.fill)."),
        .required("start", .time, "Timeline start."),
        .optional("duration", .time, "Seconds on screen (default 1.4). Left out, the graphic ends with the main video at the latest: shortened, or started earlier to keep 1 s (the result's timing says so)."),
        .optional("end", .time, "Timeline end instead of duration."),
        .optional("size", .number, "Glyph height, px at 1080 wide (default 160)."),
        .optional("color", .string, "Symbol colour (#RRGGBB or a brand colour role)."),
        .optional("badge", .string, "Round badge colour behind the glyph (#RRGGBB or a brand role)."),
        .optional("trackId", .string, "Overlay track (default: a free one)."),
    ] + Graphics.positionParams + Graphics.animationParams

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        var sticker: Sticker
        if let name = p.string("sticker") { sticker = StickerLibrary.named(name)!.sticker }
        else if let e = p.string("emoji"), !e.isEmpty { sticker = Sticker(kind: .emoji, value: e) }
        else if let s = p.string("symbol"), !s.isEmpty { sticker = Sticker(kind: .symbol, value: s, size: 140, color: "#FFFFFF") }
        else { throw CommandError.invalid("\(id): pass sticker, emoji or symbol") }
        let kit = project.brand
        if let v = p.number("size") { guard v > 0 else { throw CommandError.invalid("\(id): size must be > 0") }; sticker.size = v }
        if let c = p.string("color") { sticker.color = kit?.color(c) ?? c }
        if let b = p.string("badge") { sticker.badge = kit?.color(b) ?? b }
        let span = try Graphics.range(p, project, defaultDuration: MediaTime(seconds: 1.4), what: "the sticker")
        let (start, end) = (span.start, span.end)
        let (placement, rest) = try Graphics.place(p, size: (sticker.box, sticker.box), defaultBand: "top", fit: .native)
        let t = try Graphics.track("overlays", in: &project, start: start, end: end, preferred: p.string("trackId"))
        var clip = Clip(id: project.makeID("c"), assetID: "", sourceIn: .zero, sourceOut: end - start, start: start)
        clip.sticker = sticker
        clip.placement = placement
        clip.transform = rest == Transform() ? nil : rest
        let a = p.string("animIn").flatMap(AnimationPreset.init(rawValue:)) ?? .pop
        let b = p.string("animOut").flatMap(AnimationPreset.init(rawValue:)) ?? .fade
        clip.keyframes = AnimationPreset.combined(in: a, out: b, rest: rest, duration: end - start, inDuration: p.number("inDuration"), outDuration: p.number("outDuration"))
        project.tracks[t].clips.append(clip)
        project.tracks[t].sortClips()
        ctx.project = project
        var result: [String: JSONValue] = ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id)]
        if let box = Graphics.restBox(clip, track: project.tracks[t], project: project, renderer: ctx.services.renderer) {
            result["box"] = Graphics.boxJSON(box)
            result["warnings"] = .array(Graphics.zoneWarnings(box, project: project, what: "sticker"))
        }
        Graphics.report(span, into: &result)
        return .object(result)
    }
}

enum CalloutAdd: Command {
    static let id = "callout.add"
    static let summary = "Draw attention to something on screen with a hand-drawn callout that draws itself on: arrow (from → to), circle, underline, box (rounded rectangle) or highlight (translucent marker band). Coordinates are pixels of the project frame (1080×1920 for a reel, 1920×1080 for a screen recording). Colour defaults to the brand kit's accent. Fades out at the end. Taste: one callout at a time, on the thing the voice is talking about; tutorials: on clicks. Returns the clip and warnings."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("kind", .oneOf(["arrow", "circle", "underline", "box", "highlight"]), "Callout shape."),
        .required("start", .time, "Timeline start."),
        .optional("duration", .time, "Seconds on screen (default 2). Left out, the graphic ends with the main video at the latest: shortened, or started earlier to keep 1 s (the result's timing says so)."),
        .optional("end", .time, "Timeline end instead of duration."),
        .optional("rect", .array(.number), "[x, y, w, h] of the thing to mark, pixels of the project frame (circle, underline, box, highlight)."),
        .optional("from", .array(.number), "arrow: tail [x, y], pixels."),
        .optional("to", .array(.number), "arrow: head [x, y], pixels."),
        .optional("color", .string, "#RRGGBB or a brand colour role (default: the kit's accent, else #FFD43B)."),
        .optional("width", .number, "Stroke width, px at 1080 wide (default 10; highlight ignores it)."),
        .optional("drawOn", .number, "Seconds to draw it on (default 0.45; 0 = appears whole)."),
        .optional("trackId", .string, "Overlay track (default: a free one)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let kind = ShapeLayer.Kind(rawValue: p.requiredString("kind"))!
        let W = Double(project.settings.width), H = Double(project.settings.height)
        var px: [Double]
        if kind == .arrow {
            guard let a = p.numbers("from"), let b = p.numbers("to"), a.count == 2, b.count == 2 else { throw CommandError.invalid("\(id): arrow needs from [x, y] and to [x, y]") }
            px = [a[0], a[1], b[0] - a[0], b[1] - a[1]]
        } else {
            guard let r = p.numbers("rect"), r.count == 4, r[2] > 0, r[3] > 0 else { throw CommandError.invalid("\(id): \(kind.rawValue) needs rect [x, y, w, h] with w, h > 0") }
            px = r
        }
        let color = p.string("color").map { project.brand?.color($0) ?? $0 } ?? project.brand?.colors["accent"] ?? "#FFD43B"
        var shape = ShapeLayer(kind: kind, rect: [px[0] / W, px[1] / H, px[2] / W, px[3] / H], color: color,
                               width: p.number("width") ?? 10, drawOn: max(p.number("drawOn") ?? 0.45, 0))
        if kind == .highlight { shape.width = 0 }
        let span = try Graphics.range(p, project, defaultDuration: MediaTime(seconds: 2), what: "the callout")
        let (start, end) = (span.start, span.end)
        let t = try Graphics.track("overlays", in: &project, start: start, end: end, preferred: p.string("trackId"))
        var clip = Clip(id: project.makeID("c"), assetID: "", sourceIn: .zero, sourceOut: end - start, start: start)
        clip.shape = shape
        clip.keyframes = fadeOut(duration: end - start)
        project.tracks[t].clips.append(clip)
        project.tracks[t].sortClips()
        ctx.project = project
        // Box in pixels (arrow: its bounds) against the caption band.
        let box = [min(px[0], px[0] + px[2]), min(px[1], px[1] + px[3]), abs(px[2]), max(abs(px[3]), 1)]
        var result: [String: JSONValue] = ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id), "box": Graphics.boxJSON(box),
                                           "warnings": .array(Graphics.zoneWarnings(box, project: project, what: "callout"))]
        Graphics.report(span, into: &result)
        return .object(result)
    }

    /// Rest, then a 0.25 s fade at the end.
    static func fadeOut(duration: MediaTime) -> [Keyframe]? {
        let d = duration.seconds, f = min(0.25, d / 3)
        var gone = Transform()
        gone.opacity = 0
        return [Keyframe(time: .zero, transform: Transform()), Keyframe(time: MediaTime(seconds: d - f), transform: Transform(), easing: .easeIn),
                Keyframe(time: duration, transform: gone)]
    }
}

enum ProgressAdd: Command {
    static let id = "progress.add"
    static let summary = "A thin progress bar that fills from left to right while the video plays (tutorials, lists, long reels): at the top or bottom edge, brand colour by default, over the whole picture or a range. Returns the clip."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("position", .oneOf(["top", "bottom"]), "Edge (default top)."),
        .optional("start", .time, "Timeline start (default 0)."),
        .optional("end", .time, "Timeline end (default: the end of the picture)."),
        .optional("thickness", .number, "Bar height, px at 1080 wide (default 8)."),
        .optional("color", .string, "Fill colour (#RRGGBB or brand role; default the kit's primary, else white)."),
        .optional("trackColor", .string, "Colour of the unfilled part, drawn at 35 % (default white; \"none\" hides it)."),
        .optional("trackId", .string, "Overlay track (default: a free one)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let rate = project.settings.frameRate
        let start = (p.time("start") ?? .zero).snapped(to: rate)
        let end = (p.time("end") ?? project.pictureEnd).snapped(to: rate)
        guard end > start else { throw CommandError.invalid("\(id): end must be after start (is there a picture on the timeline?)") }
        let thick = p.number("thickness") ?? 8
        guard thick > 0 else { throw CommandError.invalid("\(id): thickness must be > 0") }
        let H = Double(project.settings.height), k = Double(project.settings.width) / SafeZones.referenceWidth
        let h = thick * k / H
        let y = p.string("position") == "bottom" ? 1 - h : 0
        let color = p.string("color").map { project.brand?.color($0) ?? $0 } ?? project.brand?.colors["primary"] ?? "#FFFFFF"
        var shape = ShapeLayer(kind: .progressBar, rect: [0, y, 1, h], color: color, width: thick, drawOn: 0)
        let track = p.string("trackColor") ?? "#FFFFFF"
        shape.trackColor = track == "none" ? nil : (project.brand?.color(track) ?? track)
        let t = try Graphics.track("overlays", in: &project, start: start, end: end, preferred: p.string("trackId"))
        var clip = Clip(id: project.makeID("c"), assetID: "", sourceIn: .zero, sourceOut: end - start, start: start)
        clip.shape = shape
        project.tracks[t].clips.append(clip)
        project.tracks[t].sortClips()
        ctx.project = project
        return ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id)]
    }
}

// MARK: - Logo motions

enum LogoAnimate: Command {
    static let id = "logo.animate"
    static let summary = "Animate a logo: spin (one turn growing in), orbit (slow drift on a small circle), pulse (gentle breathing) or sting (a ~1.5 s intro/outro hit: pops in past full size with a short glow, settles, lifts away). Adds the brand kit's logo (or `path`) as an overlay, or animates an existing overlay clip (clipId). Taste: short and once — a sting at the very end (outro) or the first second; long logo intros are out of fashion. Returns the clip."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("motion", .oneOf(LogoMotion.names), "Motion (none removes it)."),
        .optional("clipId", .string, "Existing image overlay to animate (instead of adding the logo)."),
        .optional("path", .string, "Logo file (SVG/PNG; default: the applied brand kit's logo)."),
        .optional("start", .time, "Timeline start of a new logo (default: 1.6 s before the end of the picture = outro)."),
        .optional("duration", .time, "Seconds (defaults: sting 1.6, spin 2, orbit and pulse 3)."),
        .optional("svgWidth", .integer, "Raster width of an SVG logo, px (default 360)."),
        .optional("band", .oneOf(SafeZones.bandNames), "Band (default middle)."),
        .optional("position", .array(.number), "Centre [x, y], pixels of a 1080×1920 frame."),
        .optional("scale", .number, "Size factor (default 1)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let motion = LogoMotion(rawValue: p.requiredString("motion"))!
        var clipID = p.string("clipId")
        if clipID == nil {
            let project = try ctx.requireProject()
            guard let path = p.string("path") ?? project.brand?.logoPath() else {
                if let kit = project.brand { throw LogoOverlay.noLogo(kit, command: id) }
                throw CommandError.invalid("\(id): pass path, clipId, or apply a brand kit with a logo first")
            }
            let def: Double = motion == .sting ? 1.6 : motion == .spin ? 2 : 3
            let d = p.time("duration") ?? MediaTime(seconds: def)
            let start = p.time("start") ?? max(project.pictureEnd - d, .zero)
            var params: [String: JSONValue] = ["path": .string(path), "start": .number(start.seconds), "duration": .number(d.seconds),
                                               "svgWidth": .number(Double(p.int("svgWidth") ?? 360)), "band": .string(p.string("band") ?? "middle")]
            if let pos = p.json("position") { params["position"] = pos }
            if let s = p.number("scale") { params["scale"] = .number(s) }
            let added = try OverlayAdd.run(try CommandParams(validating: .object(params), for: OverlayAdd.descriptor), &ctx)
            clipID = added.value(at: "clip.id")?.stringValue
        }
        var project = try ctx.requireProject()
        guard let cid = clipID else { throw CommandError(.io, "\(id): the logo was not added") }
        let (t, c) = try Timeline.locate(clip: cid, in: project)
        var clip = project.tracks[t].clips[c]
        guard project.asset(clip.assetID)?.image != nil || clip.title != nil || clip.sticker != nil else {
            throw CommandError.conflict("\(id): \(cid) is not an image, title or sticker overlay")
        }
        clip.keyframes = motion.keyframes(rest: clip.transform ?? Transform(), duration: clip.duration)
        clip.effects?.removeAll { $0.id.hasPrefix("logo-") }
        if motion == .sting {
            var glow = Effect(id: "logo-\(project.makeID("fx"))", kind: .glow, amount: 0.7)
            glow.start = MediaTime(seconds: 0.08)
            glow.end = MediaTime(seconds: min(0.6, clip.duration.seconds))
            glow.attack = 0.05
            glow.release = 0.35
            glow.radius = 18
            clip.effects = (clip.effects ?? []) + [glow]
        }
        if clip.effects?.isEmpty == true { clip.effects = nil }
        project.tracks[t].clips[c] = clip
        ctx.project = project
        return ["clip": ProjectState.summary(of: clip), "motion": .string(motion.rawValue)]
    }
}
