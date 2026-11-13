import Foundation

/// Test helper for the effects gates (issue #16): every effect is visible in its window, a look at intensity 0 draws
/// exactly the original, nothing generated enters the caption band, retimed clips last what their speed says and
/// their (stretched) sound stays on the picture.
enum EffectsCheck: Command {
    static let id = "effects.check"
    static let summary = "Test helper: verify the effects of the timeline. For every clip effect, sticker, callout, title, transition and look it renders the frame where it is strongest with and without it (quarter size, same compositor) and measures the difference (visible = a clear difference over at least 0.2 % of the frame); renders a look at intensity 0 against no look (must be identical); checks sticker/callout boxes against the caption band; checks each retimed clip's duration against its speed; with path (a render), measures the A/V offset of retimed clips with stretched sound (energy envelopes, must be under one frame). Returns per-item results and pass."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("path", .string, "Rendered mp4: also check A/V sync of the retimed clips."),
        .optional("minDiff", .number, "Mean difference (0…255) over the changed pixels for an effect to count as visible (default 8)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        guard let renderer = ctx.services.renderer, let images = ctx.services.images else { throw CommandError(.io, "\(id): needs the compositor") }
        let minDiff = p.number("minDiff") ?? 8
        let rate = project.settings.frameRate
        let frame = MediaTime.frameDuration(at: rate)
        let preset = ExportPreset(id: "check", width: project.settings.width / 4, height: project.settings.height / 4)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-fxcheck-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var n = 0
        func pixels(_ pr: Project, at t: MediaTime) throws -> [UInt8] {
            n += 1
            let url = dir.appendingPathComponent("f\(n).png")
            try renderer.renderFrames(RenderJob(project: pr, preset: preset, captions: false), at: [t.snapped(to: rate)], to: [url])
            return try images.rgba(of: url, width: preset.width, height: preset.height)
        }
        /// Mean difference over the pixels that changed at all (an effect's own area), and the largest one.
        func diff(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, max: Int, changed: Double) {
            var s = 0, m = 0, changed = 0
            for px in 0..<(a.count / 4) {
                var dp = 0
                for c in 0..<3 { let d = abs(Int(a[4 * px + c]) - Int(b[4 * px + c])); dp += d; m = max(m, d) }
                if dp > 6 { changed += 1; s += dp }
            }
            return (changed == 0 ? 0 : Double(s) / Double(changed * 3), m, Double(changed) / Double(a.count / 4))
        }
        var items: [JSONValue] = []
        var pass = true
        var motionBand: [JSONValue] = []
        func check(_ kind: String, _ clipID: String?, at t: MediaTime, without: Project, bandCheck: Bool = false) throws {
            let a = try pixels(project, at: t), b = try pixels(without, at: t)
            let d = diff(a, b)
            if bandCheck, let clipID {
                // Motion templates: no ink of theirs in the caption band (rows of the quarter-size render).
                let (c0, c1) = SafeZones.captionBand(height: preset.height)
                let rows = Int(c0.rounded())..<min(Int(c1.rounded()), preset.height)
                let inBand = diff(Array(a[(rows.lowerBound * preset.width * 4)..<(rows.upperBound * preset.width * 4)]),
                                  Array(b[(rows.lowerBound * preset.width * 4)..<(rows.upperBound * preset.width * 4)]))
                if inBand.changed > 0.004 { motionBand.append(["clipId": .string(clipID), "time": ProjectState.seconds(t), "area": .number((inBand.changed * 10000).rounded() / 100)]) }
            }
            // Visible: a clear difference over at least 0.2 % of the frame (a thin progress bar is ~0.5 %).
            let visible = d.mean >= minDiff && d.changed >= 0.002
            pass = pass && visible
            var o: [String: JSONValue] = ["kind": .string(kind), "time": ProjectState.seconds(t), "diff": .number((d.mean * 100).rounded() / 100),
                                          "area": .number((d.changed * 10000).rounded() / 100), "visible": .bool(visible)]
            if let clipID { o["clipId"] = .string(clipID) }
            items.append(.object(o))
        }

        for (ti, track) in project.tracks.enumerated() where track.kind == .video || track.kind == .overlay {
            for (ci, clip) in track.clips.enumerated() {
                for e in clip.effects ?? [] {
                    // The frame where it is strongest (9 samples over its window).
                    let a = e.start ?? .zero, b = e.end ?? clip.duration
                    let samples = (0..<9).map { k in a + MediaTime(seconds: (b - a).seconds * (Double(k) + 0.5) / 9) }
                    let best = samples.max { e.strength(at: $0, clipDuration: clip.duration) < e.strength(at: $1, clipDuration: clip.duration) } ?? a
                    var w = project
                    w.tracks[ti].clips[ci].effects?.removeAll { $0.id == e.id }
                    try check("effect:\(e.kind.rawValue)", clip.id, at: min(clip.start + best, clip.end - frame), without: w)
                }
                if clip.sticker != nil || clip.shape != nil || clip.title != nil {
                    var w = project
                    w.tracks[ti].clips.remove(at: ci)
                    let kind = clip.sticker != nil ? "sticker" : clip.shape.map { "callout:\($0.kind.rawValue)" } ?? "title"
                    var t = clip.shape?.kind == .progressBar ? clip.start + MediaTime(seconds: clip.duration.seconds * 0.6)
                        : clip.start + MediaTime(seconds: min(0.7, clip.duration.seconds / 2))
                    // A layer that is hidden there by its own keyframes (clip.follow fading out where the hand is lost):
                    // the first keyframe where it is fully shown instead.
                    if let keys = clip.keyframes, clip.transform(at: t - clip.start).opacity < 0.5,
                       let shown = keys.first(where: { $0.transform.opacity >= 0.99 && $0.time < clip.duration - frame }) {
                        t = clip.start + shown.time
                    }
                    try check(kind, clip.id, at: t, without: w)
                }
                if let m = clip.motion {
                    var w = project
                    w.tracks[ti].clips.remove(at: ci)
                    let covers = MotionRegistry.spec(m.template)?.coversFrame ?? false
                    for f in [0.35, 0.6, 0.85] {
                        try check("motion:\(m.template)", clip.id, at: clip.start + MediaTime(seconds: clip.duration.seconds * f), without: w, bandCheck: !covers)
                    }
                }
                if clip.grade?.resolved(at: MediaTime(seconds: clip.duration.seconds / 2)) != nil {
                    var w = project
                    w.tracks[ti].clips[ci].grade = nil
                    try check("look:clip", clip.id, at: clip.start + MediaTime(seconds: clip.duration.seconds / 2), without: w)
                }
            }
        }
        for tr in project.transitions ?? [] {
            var w = project
            w.transitions?.removeAll { $0.id == tr.id }
            try check("transition:\(tr.kind.rawValue)", tr.clipID, at: min(tr.time(in: project), project.duration - frame), without: w)
        }
        let main = project.tracks.first { $0.kind == .video && !$0.clips.isEmpty }
        let probe = main.map { c in c.clips[c.clips.count / 2] }.map { $0.start + MediaTime(seconds: $0.duration.seconds / 2) } ?? .zero
        if project.grade?.resolved(at: probe) != nil {
            var w = project
            w.grade = nil
            try check("look:project", nil, at: probe, without: w)
        }

        // A look at intensity 0 = no look, pixel for pixel.
        var none = project
        none.grade = nil
        for t in none.tracks.indices { for c in none.tracks[t].clips.indices { none.tracks[t].clips[c].grade = nil } }
        var zero = none
        zero.grade = Grade(look: Look.all[2].id, amount: 0)
        let identity = diff(try pixels(zero, at: probe), try pixels(none, at: probe))
        pass = pass && identity.max == 0

        // Generated boxes against the caption band.
        var band: [JSONValue] = []
        let (c0, c1) = SafeZones.captionBand(height: project.settings.height)
        let W = Double(project.settings.width), H = Double(project.settings.height)
        for track in project.tracks {
            for clip in track.clips {
                var box: [Double]?
                if let s = clip.shape, s.kind != .progressBar {
                    let r = s.rect
                    box = [min(r[0], r[0] + r[2]) * W, min(r[1], r[1] + r[3]) * H, abs(r[2]) * W, abs(r[3]) * H]
                } else if clip.sticker != nil {
                    box = Graphics.restBox(clip, track: track, project: project, renderer: renderer)
                }
                if let b = box, b[1] < c1, b[1] + b[3] > c0 { band.append(.string(clip.id)) }
            }
        }
        band += motionBand
        pass = pass && band.isEmpty

        // Retimed clips: duration from the speed, and (with a render) the stretched sound on the picture.
        var speeds: [JSONValue] = []
        for track in project.tracks where track.kind == .video || track.kind == .audio {
            for clip in track.clips {
                guard let sp = clip.speed else { continue }
                let expected = sp.freeze == true ? sp.duration.seconds : sp.timelineSeconds(forSource: clip.sourceDuration.seconds)
                let ok = abs(clip.duration.seconds - expected) <= frame.seconds / 2 + 1e-9
                pass = pass && ok
                speeds.append(["clipId": .string(clip.id), "track": .string(track.id), "duration": ProjectState.seconds(clip.duration),
                               "expected": .number((expected * 1000).rounded() / 1000), "ok": .bool(ok)])
            }
        }
        var sync: [JSONValue] = []
        if p.has("path") {
            let url = try MediaCheck.file(p, "path", command: id)
            sync = try syncOfRetimed(project, render: url, &ctx, dir: dir)
            for s in sync where s["ok"]?.boolValue == false { pass = false }
        }
        return ["pass": .bool(pass), "items": .array(items), "identity": ["maxDiff": .number(Double(identity.max)), "mean": .number(identity.mean)],
                "captionBand": .array(band), "speeds": .array(speeds), "sync": .array(sync)]
    }

    /// Lag of the render's sound against the camera sound mapped through each retimed clip's speed (energy envelopes,
    /// 5 ms hops, ±150 ms), for clips whose sound is stretched (not muted, reversed or frozen).
    static func syncOfRetimed(_ project: Project, render: URL, _ ctx: inout CommandContext, dir: URL) throws -> [JSONValue] {
        guard let track = project.tracks.first(where: { $0.kind == .audio && $0.clips.contains { $0.speed?.effectiveAudio == .pitch } }) else { return [] }
        let rate = 48000, hop = 240
        let wav = dir.appendingPathComponent("render.wav")
        try Subprocess.check(MediaCheck.ffmpeg(ctx), FFmpegAudio.quiet + ["-i", render.path, "-map", "0:a:0", "-af", "pan=mono|c0=0.5*c0+0.5*c1",
                                                                          "-ar", String(rate), "-c:a", "pcm_s16le", wav.path])
        func envelope(_ x: [Float]) -> [Double] {
            stride(from: 0, to: max(x.count - hop, 0), by: hop).map { i in
                var s = 0.0
                for k in i..<(i + hop) { s += Double(x[k] * x[k]) }
                return log(1e-7 + s / Double(hop))
            }
        }
        /// 40 ms moving mean: stretched sound smears transients a little; compare the syllable rhythm.
        func smooth(_ e: [Double]) -> [Double] {
            let w = 8
            var out = [Double](repeating: 0, count: e.count), acc = 0.0
            for i in e.indices {
                acc += e[i]
                if i >= w { acc -= e[i - w] }
                out[i] = acc / Double(min(i + 1, w))
            }
            return out
        }
        let rendered = smooth(envelope(try WAVAudio.read(wav).mono()))
        var out: [JSONValue] = []
        var cache: [String: [Double]] = [:]
        for clip in track.clips where clip.speed?.effectiveAudio == .pitch {
            guard let asset = project.asset(clip.assetID) else { continue }
            let camera = asset.origin.flatMap { project.asset($0.assetID) } ?? asset
            guard let working = camera.analysis?.audio?.working else { throw CommandError.conflict("\(id): \(camera.id) has no extracted audio — run media.extractAudio") }
            if cache[working] == nil { cache[working] = smooth(envelope(try WAVAudio.read(URL(fileURLWithPath: working)).mono())) }
            let src = cache[working]!
            let hopS = Double(hop) / Double(rate)
            let k0 = Int((clip.start.seconds + 0.1) / hopS), k1 = Int((clip.end.seconds - 0.1) / hopS)
            guard k1 - k0 > 40 else { continue }
            // Reference: the source envelope where each timeline hop shows its source.
            let ref = (k0..<k1).map { k -> Double in
                let s = clip.sourceTime(atLocal: MediaTime(seconds: Double(k) * hopS - clip.start.seconds)).seconds / hopS
                let i = min(max(Int(s), 0), src.count - 2), f = s - Double(i)
                return src[i] * (1 - f) + src[i + 1] * f
            }
            let maxLag = 30
            var best = (lag: 0, r: -2.0)
            var scores: [Int: Double] = [:]
            for lag in -maxLag...maxLag {
                var a: [Double] = [], b: [Double] = []
                for (j, k) in (k0..<k1).enumerated() where k + lag >= 0 && k + lag < rendered.count { a.append(ref[j]); b.append(rendered[k + lag]) }
                let r = Self.correlation(a, b)
                scores[lag] = r
                if r > best.r { best = (lag, r) }
            }
            var lag = Double(best.lag)
            if let l = scores[best.lag - 1], let r = scores[best.lag + 1] {
                let d = l - 2 * best.r + r
                if abs(d) > 1e-12 { lag += min(max(0.5 * (l - r) / d, -0.5), 0.5) }
            }
            let ms = lag * hopS * 1000, frames = ms / 1000 * project.settings.frameRate.doubleValue
            out.append(["clipId": .string(clip.id), "lagMs": .number(ms.rounded()), "lagFrames": .number((frames * 100).rounded() / 100),
                        "correlation": .number((best.r * 1000).rounded() / 1000), "ok": .bool(abs(frames) < 1 && best.r > 0.3)])
        }
        return out
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count > 2 else { return -1 }
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in a.indices { let x = a[i] - ma, y = b[i] - mb; sab += x * y; saa += x * x; sbb += y * y }
        return sab / max(sqrt(saa * sbb), 1e-12)
    }
}
