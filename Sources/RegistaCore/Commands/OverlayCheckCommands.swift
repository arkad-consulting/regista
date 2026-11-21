import Foundation

// Checks and helpers for graphics built against a reference edit (issue #9, L3).

enum ReferenceMap {
    /// A reference edit's segments.json (source in/out per segment, concatenated): ffmpeg trim=in:out keeps the source
    /// frames ceil(in·fps) ..< ceil(out·fps).
    static func load(_ path: String, fps: Double) throws -> [(src0: Int, src1: Int, ref0: Int)] {
        guard let data = FileManager.default.contents(atPath: EngineConfig.expand(path)) else { throw CommandError.notFound("no file at \(path)") }
        var out: [(Int, Int, Int)] = []
        var ref0 = 0
        for s in try JSONValue.parse(data)["segments"]?.arrayValue ?? [] {
            guard let a = s["in"]?.doubleValue, let b = s["out"]?.doubleValue else { continue }
            let f0 = Int(((a * fps * 1e6).rounded() / 1e6).rounded(.up)), f1 = Int(((b * fps * 1e6).rounded() / 1e6).rounded(.up))
            out.append((f0, f1, ref0)); ref0 += f1 - f0
        }
        return out
    }
}

enum TimelineMapTimes: Command {
    static let id = "timeline.mapTimes"
    static let summary = "Translate times between a reference edit (its segments.json: source ranges played back to back) and this timeline through the source frames they show — to put graphics, inserts and SFX of a hand-made edit at the same moments of the speech (toTimeline), or to find the reference frame of a timeline moment (toReference). A time whose source frame was cut goes to the nearest kept frame (exact: false). Returns the mapped times."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("referenceSegments", .string, "The reference's segments.json."),
        .required("times", .array(.number), "Times to map, seconds."),
        .optional("direction", .oneOf(["toTimeline", "toReference"]), "Default toTimeline."),
        .optional("trackId", .string, "Video track of this timeline (default: the first video track)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let fps = project.settings.frameRate.doubleValue
        let segs = try ReferenceMap.load(p.requiredString("referenceSegments"), fps: fps)
        let track: Track
        if let tid = p.string("trackId") { track = project.tracks[try Timeline.trackIndex(tid, in: project, editable: false)] }
        else {
            guard let v = project.tracks.first(where: { $0.kind == .video && !$0.clips.isEmpty }) else { throw CommandError.conflict("\(id): no video track") }
            track = v
        }
        // Timeline clips as (source frame range, timeline frame of its first frame).
        let clips = track.clips.map { c -> (src0: Int, src1: Int, t0: Int) in
            let s0 = Int((c.sourceIn.seconds * fps).rounded()), n = Int((c.duration.seconds * fps).rounded())
            return (s0, s0 + n, Int((c.start.seconds * fps).rounded()))
        }
        let toTimeline = (p.string("direction") ?? "toTimeline") == "toTimeline"
        var out: [JSONValue] = [], exact: [JSONValue] = []
        for t in p.numbers("times") ?? [] {
            let f = t * fps   // fractional frame keeps sub-frame precision (SFX are placed to the sample)
            let k = Int(f.rounded(.down)), frac = f - Double(k)
            let from = toTimeline ? segs.map { ($0.src0, $0.src1, $0.ref0) } : clips.map { ($0.src0, $0.src1, $0.t0) }
            let to = toTimeline ? clips.map { ($0.src0, $0.src1, $0.t0) } : segs.map { ($0.src0, $0.src1, $0.ref0) }
            // Source frame shown at k.
            guard let seg = from.first(where: { k >= $0.2 && k < $0.2 + ($0.1 - $0.0) }) ?? from.last(where: { k >= $0.2 }) else {
                out.append(.number(t)); exact.append(false); continue
            }
            let src = seg.0 + min(k - seg.2, seg.1 - seg.0 - 1)
            if let hit = to.first(where: { src >= $0.0 && src < $0.1 }) {
                out.append(.number(((Double(hit.2 + src - hit.0) + frac) / fps * 1e6).rounded() / 1e6))
                exact.append(true)
            } else {
                // Cut away: the next kept frame (or the last one).
                let next = to.filter { $0.0 > src }.min { $0.0 < $1.0 } ?? to.max { $0.1 < $1.1 }!
                let frame = next.0 > src ? next.2 : next.2 + (next.1 - next.0) - 1
                out.append(.number(Double(frame) / fps))
                exact.append(false)
            }
        }
        return ["times": .array(out), "exact": .array(exact)]
    }
}

enum MediaCheckOverlay: Command {
    static let id = "media.checkOverlay"
    static let summary = "Verify that overlay clips (e.g. full-frame inserts) are visible exactly in their windows in a rendered file: frames decoded from the render are compared (luma PSNR) with the same timeline drawn without those clips, at each clip's first and last frame (must differ) and at the frame before and after (must match). Returns per-clip PSNRs and pass."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("path", .string, "Rendered video."),
        .required("trackId", .string, "The overlay track to check."),
        .optional("clipIds", .array(.string), "Only these clips of the track (default: all)."),
        .optional("differ", .number, "Inside the window the PSNR must be below this, dB (default 25)."),
        .optional("match", .number, "Outside it must be above this, dB (default 30)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let renderer = try Render.renderer(ctx, command: id)
        let url = try MediaCheck.file(p, "path", command: id)
        let t = try Timeline.trackIndex(p.requiredString("trackId"), in: project, editable: false)
        let only = p.strings("clipIds").map(Set.init)
        let clips = project.tracks[t].clips.filter { only?.contains($0.id) ?? true }
        guard !clips.isEmpty else { throw CommandError.conflict("\(id): no clip to check") }
        // The same timeline without the checked clips.
        var base = project
        base.tracks[t].clips.removeAll { c in clips.contains { $0.id == c.id } }
        let rate = project.settings.frameRate
        let frame = MediaTime.frameDuration(at: rate)
        var probes: [(clip: String, role: String, time: MediaTime)] = []
        // Before/after probes that fall inside another checked clip (adjacent inserts) are covered by that clip's own probes.
        func insideChecked(_ t: MediaTime) -> Bool { clips.contains { $0.start <= t && t < $0.end } }
        for c in clips {
            probes.append((c.id, "first", c.start)); probes.append((c.id, "last", c.end - frame))
            if c.start >= frame, !insideChecked(c.start - frame) { probes.append((c.id, "before", c.start - frame)) }
            if c.end < project.duration, !insideChecked(c.end) { probes.append((c.id, "after", c.end)) }
        }
        let dir = TemporaryFolder.url.appendingPathComponent("regista-overlay-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pngs = probes.indices.map { dir.appendingPathComponent("b\($0).png") }
        try renderer.renderFrames(RenderJob(project: base, preset: ExportPreset.named(nil, project: project)), at: probes.map(\.time), to: pngs)
        let ffmpeg = MediaCheck.ffmpeg(ctx)
        var psnr = [Double](repeating: 0, count: probes.count)
        var failure: Error?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: probes.count) { i in
            do {
                // One decoded frame of the render against one drawn frame (two stills: a single comparison).
                let still = dir.appendingPathComponent("r\(i).png")
                try Subprocess.check(ffmpeg, FFmpegAudio.quiet + ["-ss", String(format: "%.6f", max(probes[i].time.seconds - frame.seconds / 4, 0)),
                                                                  "-i", url.path, "-frames:v", "1", still.path])
                let r = try Subprocess.check(ffmpeg, ["-nostdin", "-hide_banner", "-nostats", "-i", still.path, "-i", pngs[i].path,
                                                      "-lavfi", "[0:v]format=gray[a];[1:v]format=gray[b];[a][b]psnr", "-f", "null", "-"])
                guard let line = r.stderrText.split(separator: "\n").last(where: { $0.contains("PSNR") }),
                      let k = line.range(of: "average:") else { throw CommandError(.io, "\(id): no PSNR in ffmpeg output") }
                let v = Double(line[k.upperBound...].prefix { $0 == "." || $0.isNumber || $0 == "-" || $0 == "i" || $0 == "n" || $0 == "f" }
                    .replacingOccurrences(of: "inf", with: "99")) ?? 0
                lock.lock(); psnr[i] = v; lock.unlock()
            } catch { lock.lock(); failure = error; lock.unlock() }
        }
        if let failure { throw failure }
        let differ = p.number("differ") ?? 25, match = p.number("match") ?? 30
        var pass = true
        var rows: [String: [String: JSONValue]] = [:]
        for (i, pr) in probes.enumerated() {
            let inside = pr.role == "first" || pr.role == "last"
            let ok = inside ? psnr[i] < differ : psnr[i] > match
            pass = pass && ok
            rows[pr.clip, default: ["clipId": .string(pr.clip)]][pr.role] = ["time": ProjectState.seconds(pr.time),
                                                                            "psnr": .number((psnr[i] * 100).rounded() / 100), "ok": .bool(ok)]
        }
        return ["pass": .bool(pass), "clips": .array(clips.compactMap { rows[$0.id].map { .object($0) } }),
                "differBelow": .number(differ), "matchAbove": .number(match)]
    }
}
