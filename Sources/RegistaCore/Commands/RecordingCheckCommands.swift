import Foundation

// recording.check (issue #6): measures an exported screen-recording edit against the session it came from —
// sync slates (screen flash, camera flash, mic beep), the face where the layout put it (Vision faces on the
// export), zooms at the clicks, and the cut-out showing the screen around the person.

enum RecordingCheck: Command {
    static let id = "recording.check"
    static let summary = "Check an exported screen-recording edit: sync (the session's slates: the camera flash frame, the screen flash frame and the mic beep found in the mp4 — camera↔mic and screen↔camera must be within one frame and on the expected frames), faces (Apple Vision on the export: the face inside the camera box the layout says, near its expected spot), zoom (at each click the export matches the zoomed render, not the unzoomed one) and cutout (around the person the screen shows through, the person covers it). Returns each check with numbers and pass."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("path", .string, "The exported mp4."),
        .optional("checks", .array(.oneOf(["sync", "faces", "zoom", "cutout"])), "Which checks (default: all that apply)."),
        Recording.recordingParam,
    ]

    struct Context {
        var project: Project
        var link: RecordingLink
        var session: RecordingSession
        var job: RenderJob
        var path: String
        var ffmpeg: URL
        var fps: Double
        var W: Int { job.width }
        var H: Int { job.height }
    }

    static func run(_ p: CommandParams, _ cctx: inout CommandContext) throws -> JSONValue {
        let project = try cctx.requireProject()
        let (_, link) = try Recording.link(p, project, command: id)
        let path = EngineConfig.expand(p.requiredString("path"))
        guard FileManager.default.fileExists(atPath: path) else { throw CommandError.notFound("\(id): no file at \(path)") }
        let info = try cctx.prober.probe(URL(fileURLWithPath: path))
        guard let v = info.video else { throw CommandError.invalid("\(id): \(path) has no video") }
        let preset = ExportPreset.all.first { $0.width == v.width && $0.height == v.height }
            ?? ExportPreset(id: "export", width: v.width, height: v.height)
        let session = try RecordingSession.load(URL(fileURLWithPath: link.session))
        let c = Context(project: project, link: link, session: session, job: RenderJob(project: project, preset: preset, captions: false),
                        path: path, ffmpeg: cctx.services.config.url(cctx.services.config.ffmpeg), fps: project.settings.frameRate.doubleValue)
        let wanted = Set(p.strings("checks") ?? ["sync", "faces", "zoom", "cutout"])
        var out: [String: JSONValue] = ["path": .string(path), "width": .number(Double(c.W)), "height": .number(Double(c.H))]
        var passes: [Bool] = []
        if wanted.contains("sync"), !(session.syncMarks ?? []).isEmpty {
            let r = try sync(c)
            out["sync"] = r
            passes.append(r["pass"]?.boolValue == true)
        }
        if wanted.contains("faces"), let faces = cctx.services.faces {
            let r = try facesCheck(c, faces)
            if r != .null { out["faces"] = r; passes.append(r["pass"]?.boolValue == true) }
        }
        if wanted.contains("zoom") || wanted.contains("cutout") {
            guard let renderer = cctx.services.renderer, let images = cctx.services.images else {
                throw CommandError(.io, "\(id): zoom and cutout need the compositor (regista-engine / regista-mcp)")
            }
            if wanted.contains("zoom") {
                let r = try zoom(c, renderer, images)
                if r != .null { out["zoom"] = r; passes.append(r["pass"]?.boolValue == true) }
            }
            if wanted.contains("cutout") {
                let r = try cutout(c, renderer, images)
                if r != .null { out["cutout"] = r; passes.append(r["pass"]?.boolValue == true) }
            }
        }
        out["pass"] = .bool(!passes.isEmpty && passes.allSatisfy { $0 })
        return .object(out)
    }

    // MARK: Helpers

    /// Picture layer of an asset at frame `n`.
    static func layer(_ c: Context, asset: String?, frame n: Int) -> VideoLayer? {
        guard let asset else { return nil }
        let t = MediaTime(ticks: MediaTime.frameDuration(at: c.project.settings.frameRate).ticks * Int64(n))
        return c.job.layers(at: t).first { $0.assetID == asset && $0.opacity > 0.01 }
    }

    /// Output box [x, y, w, h] of a layer, clamped to the frame.
    static func box(_ c: Context, _ l: VideoLayer) -> [Double] {
        let b = l.box(width: c.W, height: c.H)
        let x0 = max(b[0], 0), y0 = max(b[1], 0), x1 = min(b[0] + b[2], Double(c.W)), y1 = min(b[1] + b[3], Double(c.H))
        return [x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)]
    }

    /// Output position of a camera-source point, through the layer's crop and box (no rotation).
    static func project(_ c: Context, _ l: VideoLayer, u: Double, v: Double) -> (Double, Double) {
        let (bw, bh) = l.baseSize(width: c.W, height: c.H)
        let (cx, cy) = l.centre(width: c.W, height: c.H)
        let fx = (u - l.crop[2]) / l.crop[0] - 0.5, fy = (v - l.crop[3]) / l.crop[1] - 0.5
        return (cx + fx * bw * l.scale, cy + fy * bh * l.scale)
    }

    /// The camera's face box (camera pixels) at a source time, from its faces.track sidecar.
    static func cameraFace(_ c: Context, at source: Double) -> [Double]? {
        guard let path = c.link.camera.flatMap({ c.project.asset($0)?.analysis?.faces?.path }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let track = try? JSONDecoder().decode(FaceTrack.self, from: data),
              !track.frames.isEmpty else { return nil }
        let k = min(max(Int((source * track.fps).rounded()), 0), track.frames.count - 1)
        return track.frames[k].smooth ?? track.frames[k].raw
    }

    /// Mean luma (0…255) of a region over `count` frames from frame `first` of the mp4.
    static func lumaSeries(_ c: Context, region r: [Double], first: Int, count: Int) throws -> [Double] {
        let crop = String(format: "crop=%d:%d:%d:%d,scale=8:8:flags=area,format=gray", max(Int(r[2]), 2), max(Int(r[3]), 2), Int(r[0]), Int(r[1]))
        let start = max((Double(first) - 0.25) / c.fps, 0)
        let res = try Subprocess.check(c.ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-ss", String(format: "%.6f", start), "-i", c.path,
                                                  "-frames:v", "\(count)", "-vf", crop, "-f", "rawvideo", "-"])
        let bytes = [UInt8](res.stdout)
        return stride(from: 0, to: bytes.count - 63, by: 64).map { o in Double(bytes[o..<o + 64].reduce(0) { $0 + Int($1) }) / 64 }
    }

    /// Frame (index into the series) where the luma jumps up the most, nil when no jump exceeds 20 levels.
    static func flash(_ s: [Double]) -> Int? {
        guard s.count > 1 else { return nil }
        let jumps = (1..<s.count).map { s[$0] - s[$0 - 1] }
        guard let k = jumps.indices.max(by: { jumps[$0] < jumps[$1] }), jumps[k] > 20 else { return nil }
        return k + 1
    }

    /// Onset (seconds from `start`) of the 1 kHz slate beep in the mp4's sound: the centre of the first 4 ms window
    /// whose 1 kHz power reaches half the beep's plateau.
    static func beepOnset(_ c: Context, start: Double, duration: Double) throws -> Double? {
        let res = try Subprocess.check(c.ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-ss", String(format: "%.6f", max(start, 0)), "-t",
                                                  String(format: "%.6f", duration), "-i", c.path, "-vn", "-ac", "1", "-ar", "48000", "-f", "f32le", "-"])
        let x: [Float] = res.stdout.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = 192, hop = 24
        guard x.count > n else { return nil }
        let w = 2 * Double.pi * 1000 / 48000
        var power: [Double] = []
        var i = 0
        while i + n <= x.count {
            var re = 0.0, im = 0.0
            for k in 0..<n { let v = Double(x[i + k]); re += v * cos(w * Double(k)); im -= v * sin(w * Double(k)) }
            power.append((re * re + im * im) / Double(n * n))
            i += hop
        }
        let sorted = power.sorted()
        guard let plateau = sorted.last, plateau > 1e-4 else { return nil }
        let ref = sorted[max(sorted.count - 20, 0)]   // the beep lasts 80 ms: its top windows
        guard let k = power.firstIndex(where: { $0 >= ref / 2 }) else { return nil }
        return (Double(k * hop) + Double(n) / 2) / 48000
    }

    /// One frame of the mp4 as a PNG at the output size.
    static func exportFrame(_ c: Context, frame n: Int, to url: URL) throws {
        try Subprocess.check(c.ffmpeg, FFmpegAudio.quiet + ["-ss", String(format: "%.6f", (Double(n) + 0.5) / c.fps), "-i", c.path, "-frames:v", "1",
                                                            "-vf", "scale=\(c.W):\(c.H)", url.path])
    }

    static func dist(_ p: [UInt8], _ q: [UInt8], _ k: Int) -> Int {
        abs(Int(p[4 * k]) - Int(q[4 * k])) + abs(Int(p[4 * k + 1]) - Int(q[4 * k + 1])) + abs(Int(p[4 * k + 2]) - Int(q[4 * k + 2]))
    }

    static func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-reccheck-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Sync

    static func sync(_ c: Context) throws -> JSONValue {
        guard let cam = c.link.camera, let scr = c.link.screen else { return ["pass": false, "error": "the recording needs a screen and a camera"] }
        let oC = c.link.offsets["camera"] ?? 0, oS = c.link.offsets["screen"] ?? 0
        let frame = 1 / c.fps
        var rows: [JSONValue] = []
        var ok = true
        for s in c.session.syncMarks ?? [] {
            guard let tc = SessionSync.timelineTime(session: s, offset: oC, asset: cam, in: c.project),
                  let ts = SessionSync.timelineTime(session: s, offset: oS, asset: scr, in: c.project) else {
                rows.append(["mark": .number(s), "skipped": "cut out of the timeline"])
                continue
            }
            // First timeline frame showing the slate content of each source.
            let nc = Int((tc.seconds * c.fps - 1e-6).rounded(.up)), ns = Int((ts.seconds * c.fps - 1e-6).rounded(.up))
            guard let cl = layer(c, asset: cam, frame: nc), let sl = layer(c, asset: scr, frame: ns) else {
                rows.append(["mark": .number(s), "skipped": "camera or screen hidden at the slate"])
                continue
            }
            // Camera region: the face (or the box centre), half size. Screen region: the quarter of the screen box farthest from the camera.
            let cb = box(c, cl)
            var camRegion = [cb[0] + cb[2] * 0.3, cb[1] + cb[3] * 0.3, cb[2] * 0.4, cb[3] * 0.4]
            if let f = cameraFace(c, at: cl.sourceTime.seconds) {
                let (x0, y0) = project(c, cl, u: f[0] + f[2] * 0.25, v: f[1] + f[3] * 0.25)
                let (x1, y1) = project(c, cl, u: f[0] + f[2] * 0.75, v: f[1] + f[3] * 0.75)
                if x1 - x0 > 4, y1 - y0 > 4 { camRegion = [x0, y0, x1 - x0, y1 - y0] }
            }
            let sb = box(c, sl)
            let quarters = [[sb[0], sb[1]], [sb[0] + sb[2] / 2, sb[1]], [sb[0], sb[1] + sb[3] / 2], [sb[0] + sb[2] / 2, sb[1] + sb[3] / 2]].map {
                [$0[0] + sb[2] * 0.05, $0[1] + sb[3] * 0.05, sb[2] * 0.4, sb[3] * 0.4]
            }
            func overlap(_ a: [Double], _ b: [Double]) -> Double {
                max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])) * max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
            }
            let scrRegion = quarters.min { overlap($0, cb) < overlap($1, cb) }!
            let first = min(nc, ns) - 8
            let camSeries = try lumaSeries(c, region: camRegion, first: first, count: 17)
            let scrSeries = try lumaSeries(c, region: scrRegion, first: first, count: 17)
            let mc = flash(camSeries).map { first + $0 }, ms = flash(scrSeries).map { first + $0 }
            let beepStart = tc.seconds - 0.5
            let onset = try beepOnset(c, start: beepStart, duration: 1).map { beepStart + $0 }
            guard let mc, let ms, let onset else {
                ok = false
                rows.append(["mark": .number(s), "cameraFrame": mc.map { .number(Double($0)) } ?? .null, "screenFrame": ms.map { .number(Double($0)) } ?? .null,
                             "beep": onset.map { .number($0) } ?? .null, "pass": false])
                continue
            }
            // Content times on the timeline: exact from the clips, moved by any frame the export shows them off by.
            let camTime = tc.seconds + Double(mc - nc) * frame, scrTime = ts.seconds + Double(ms - ns) * frame
            let camMic = (camTime - onset) * 1000, scrCam = (scrTime - camTime) * 1000
            let pass = mc == nc && ms == ns && abs(camMic) < frame * 1000 && abs(scrCam) < frame * 1000
            ok = ok && pass
            rows.append(["mark": Analysis.seconds(s, places: 1000), "timeline": Analysis.seconds(tc.seconds, places: 1000),
                         "expectedFrame": .number(Double(nc)), "cameraFrame": .number(Double(mc)), "screenFrame": .number(Double(ms)),
                         "beep": Analysis.seconds(onset, places: 10000), "cameraMicMs": Analysis.seconds(camMic, places: 10),
                         "screenCameraMs": Analysis.seconds(scrCam, places: 10), "pass": .bool(pass)])
        }
        let measured = rows.filter { $0["cameraMicMs"] != nil }
        func worst(_ key: String) -> JSONValue {
            .number(measured.compactMap { $0[key]?.doubleValue }.map(abs).max() ?? -1)
        }
        return ["marks": .array(rows), "frameMs": Analysis.seconds(frame * 1000, places: 10), "worstCameraMicMs": worst("cameraMicMs"),
                "worstScreenCameraMs": worst("screenCameraMs"), "pass": .bool(ok && !measured.isEmpty)]
    }

    // MARK: Faces

    static func facesCheck(_ c: Context, _ tracker: FaceTracker) throws -> JSONValue {
        guard let cam = c.link.camera else { return .null }
        let track = try tracker.track(URL(fileURLWithPath: c.path), options: FaceTrackOptions())
        let sx = Double(c.W) / Double(max(track.width, 1)), sy = Double(c.H) / Double(max(track.height, 1))
        // Camera clip starts (layout switches): skip the move-in.
        let starts = Recording.clips(of: cam, in: c.project).map { c.project.tracks[$0.track].clips[$0.clip].start.seconds }
        var rows: [JSONValue] = []
        var byLayout: [String: (Int, Int)] = [:]
        var total = 0, good = 0
        let end = c.project.duration.seconds
        for t in stride(from: 0.25, to: end - 0.1, by: 0.5) where !starts.contains(where: { t >= $0 && t < $0 + 0.5 }) {
            let n = Int(t * c.fps)
            guard let l = layer(c, asset: cam, frame: n) else { continue }
            let k = min(Int((t * track.fps).rounded()), track.frames.count - 1)
            guard k >= 0 else { continue }
            let label = c.link.layouts?.last { $0.from.seconds <= t && t < $0.to.seconds }?.layout.label ?? "?"
            let b = box(c, l)
            var expected: (Double, Double)?
            if let f = cameraFace(c, at: l.sourceTime.seconds) { expected = project(c, l, u: f[0] + f[2] / 2, v: f[1] + f[3] / 2) }
            let found = track.frames[k].raw.map { [$0[0] * sx, $0[1] * sy, $0[2] * sx, $0[3] * sy] }
            var inside = false, near = false
            var distance = -1.0
            if let f = found {
                let cx = f[0] + f[2] / 2, cy = f[1] + f[3] / 2
                inside = cx >= b[0] && cx <= b[0] + b[2] && cy >= b[1] && cy <= b[1] + b[3]
                if let e = expected {
                    distance = hypot(cx - e.0, cy - e.1)
                    near = distance <= 0.15 * min(b[2], b[3])
                } else { near = inside }
            }
            let pass = inside && near
            total += 1
            if pass { good += 1 }
            var agg = byLayout[label] ?? (0, 0)
            agg.0 += 1
            if pass { agg.1 += 1 }
            byLayout[label] = agg
            rows.append(["time": .number(t), "layout": .string(label), "cameraBox": Graphics.boxJSON(b),
                         "face": found.map { Graphics.boxJSON($0) } ?? .null, "distancePx": Analysis.seconds(distance, places: 10), "pass": .bool(pass)])
        }
        guard total > 0 else { return .null }
        let ratio = Double(good) / Double(total)
        return ["samples": .number(Double(total)), "ratio": Analysis.seconds(ratio, places: 1000),
                "byLayout": .object(byLayout.mapValues { ["samples": .number(Double($0.0)), "ok": .number(Double($0.1))] }),
                "failures": .array(rows.filter { $0["pass"]?.boolValue == false }.prefix(8).map { $0 }),
                "pass": .bool(ratio >= 0.9)]
    }

    // MARK: Zoom

    static func zoom(_ c: Context, _ renderer: VideoRenderer, _ images: ImageToolkit) throws -> JSONValue {
        guard let scr = c.link.screen, let sv = c.project.asset(scr)?.video else { return .null }
        let oS = c.link.offsets["screen"] ?? 0
        let clicks = c.session.clicks.compactMap { e -> (Double, Int)? in
            guard let tl = SessionSync.timelineTime(session: e.t, offset: oS, asset: scr, in: c.project) else { return nil }
            return (e.t, Int((tl.seconds * c.fps).rounded()))
        }.filter { Double($0.1) / c.fps < c.project.duration.seconds - 0.05 }
        guard !clicks.isEmpty else { return .null }
        var flat = c.project
        for t in flat.tracks.indices { for k in flat.tracks[t].clips.indices where flat.tracks[t].clips[k].assetID == scr { flat.tracks[t].clips[k].keyframes = nil } }
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let times = clicks.map { MediaTime(ticks: MediaTime.frameDuration(at: c.project.settings.frameRate).ticks * Int64($0.1)) }
        let zoomed = times.indices.map { dir.appendingPathComponent("z\($0).png") }, plain = times.indices.map { dir.appendingPathComponent("p\($0).png") }
        let preset = ExportPreset(id: "check", width: c.W, height: c.H)
        try renderer.renderFrames(RenderJob(project: c.project, preset: preset, captions: false), at: times, to: zoomed)
        try renderer.renderFrames(RenderJob(project: flat, preset: preset, captions: false), at: times, to: plain)
        var rows: [JSONValue] = []
        var ok = true
        for (i, (s, n)) in clicks.enumerated() {
            guard let l = layer(c, asset: scr, frame: n) else { continue }
            let restW = AutoZoom.crop(zoom: 1, centre: [0, 0], aspect: l.crop[0] / max(l.crop[1], 1),
                                      area: (c.project.locate(clip: l.clipID).map { c.project.tracks[$0.track].clips[$0.clip].transform ?? Transform() } ?? Transform())
                                        .cropRect(sourceWidth: sv.width, sourceHeight: sv.height))[0]
            let planned = restW / max(l.crop[0], 1)
            let exp = dir.appendingPathComponent("e\(i).png")
            try exportFrame(c, frame: n, to: exp)
            let ge = try images.rgba(of: exp, width: c.W, height: c.H), gz = try images.rgba(of: zoomed[i], width: c.W, height: c.H)
            let gp = try images.rgba(of: plain[i], width: c.W, height: c.H)
            let sb = box(c, l)
            let cb = layer(c, asset: c.link.camera, frame: n).map { box(c, $0) }
            var dz = 0, dp = 0, count = 0
            for y in stride(from: Int(sb[1]), to: Int(sb[1] + sb[3]), by: 3) {
                for x in stride(from: Int(sb[0]), to: Int(sb[0] + sb[2]), by: 3) {
                    if let b = cb, Double(x) >= b[0] - 30, Double(x) <= b[0] + b[2] + 30, Double(y) >= b[1] - 30, Double(y) <= b[1] + b[3] + 30 { continue }
                    let k = y * c.W + x
                    dz += dist(ge, gz, k); dp += dist(ge, gp, k); count += 1
                }
            }
            let mz = Double(dz) / Double(max(count, 1)), mp = Double(dp) / Double(max(count, 1))
            let pass = planned >= 1.2 && mz < 0.5 * mp
            ok = ok && pass
            rows.append(["click": Analysis.seconds(s, places: 1000), "time": Analysis.seconds(Double(n) / c.fps, places: 1000),
                         "plannedZoom": Analysis.seconds(planned, places: 100), "diffZoomed": Analysis.seconds(mz, places: 10),
                         "diffUnzoomed": Analysis.seconds(mp, places: 10), "pass": .bool(pass)])
        }
        return ["clicks": .array(rows), "pass": .bool(ok && !rows.isEmpty)]
    }

    // MARK: Cut-out

    static func cutout(_ c: Context, _ renderer: VideoRenderer, _ images: ImageToolkit) throws -> JSONValue {
        guard let cam = c.link.camera else { return .null }
        // Frames whose camera layer is a cut-out with a matte, away from clip starts (the pop-in).
        let clips = Recording.clips(of: cam, in: c.project).map { c.project.tracks[$0.track].clips[$0.clip] }.filter { $0.mask?.cutout == true }
        var frames: [Int] = []
        for clip in clips {
            let a = clip.start.seconds + 0.6, b = clip.end.seconds - 0.2
            guard b > a else { continue }
            for k in 0..<3 { frames.append(Int((a + (b - a) * (Double(k) + 0.5) / 3) * c.fps)) }
        }
        frames = frames.filter { layer(c, asset: cam, frame: $0)?.matte != nil }
        guard !frames.isEmpty else { return clips.isEmpty ? .null : ["pass": false, "error": "no person matte on the cut-out frames: run matte.track on the camera"] }
        var hidden = c.project, whole = c.project
        for t in c.project.tracks.indices {
            for k in c.project.tracks[t].clips.indices where c.project.tracks[t].clips[k].assetID == cam {
                hidden.tracks[t].clips[k].transform = { var tr = c.project.tracks[t].clips[k].transform ?? Transform(); tr.opacity = 0; return tr }()
                hidden.tracks[t].clips[k].keyframes = nil
                whole.tracks[t].clips[k].mask?.cutout = nil
                whole.tracks[t].clips[k].mask?.shadow = nil
            }
        }
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = c.project.settings.frameRate
        let times = frames.map { MediaTime(ticks: MediaTime.frameDuration(at: rate).ticks * Int64($0)) }
        let preset = ExportPreset(id: "check", width: c.W, height: c.H)
        let hu = frames.indices.map { dir.appendingPathComponent("h\($0).png") }, wu = frames.indices.map { dir.appendingPathComponent("w\($0).png") }
        try renderer.renderFrames(RenderJob(project: hidden, preset: preset, captions: false), at: times, to: hu)
        try renderer.renderFrames(RenderJob(project: whole, preset: preset, captions: false), at: times, to: wu)
        var rows: [JSONValue] = []
        var tb = 0, tv = 0, tp = 0, tc = 0
        for (i, n) in frames.enumerated() {
            guard let l = layer(c, asset: cam, frame: n), let mpath = l.matte, let m = c.project.asset(cam)?.analysis?.matte else { continue }
            let exp = dir.appendingPathComponent("e\(i).png")
            try exportFrame(c, frame: n, to: exp)
            let ge = try images.rgba(of: exp, width: c.W, height: c.H), gh = try images.rgba(of: hu[i], width: c.W, height: c.H)
            let gw = try images.rgba(of: wu[i], width: c.W, height: c.H)
            let mg = try images.rgba(of: URL(fileURLWithPath: mpath), width: m.width, height: m.height)
            let b = box(c, l)
            let (bw, bh) = l.baseSize(width: c.W, height: c.H)
            let (cx, cy) = l.centre(width: c.W, height: c.H)
            var background = 0, visible = 0, person = 0, covered = 0
            for y in stride(from: Int(b[1]), to: Int(b[1] + b[3]), by: 2) {
                for x in stride(from: Int(b[0]), to: Int(b[0] + b[2]), by: 2) {
                    let k = y * c.W + x
                    // Output pixel → camera source pixel → matte pixel.
                    let u = l.crop[2] + ((Double(x) - cx) / (bw * l.scale) + 0.5) * l.crop[0]
                    let v = l.crop[3] + ((Double(y) - cy) / (bh * l.scale) + 0.5) * l.crop[1]
                    let mx = Int(u * Double(m.width) / Double(l.sourceWidth)), my = Int(v * Double(m.height) / Double(l.sourceHeight))
                    guard mx >= 0, my >= 0, mx < m.width, my < m.height else { continue }
                    let mv = mg[4 * (my * m.width + mx)]
                    // Only where the screen and the camera's own background differ can the pixel tell them apart.
                    guard dist(gh, gw, k) > 30 else { continue }
                    if mv <= 25 {
                        background += 1
                        if dist(ge, gh, k) < dist(ge, gw, k) { visible += 1 }
                    } else if mv >= 230 {
                        person += 1
                        if dist(ge, gw, k) < dist(ge, gh, k) { covered += 1 }
                    }
                }
            }
            tb += background; tv += visible; tp += person; tc += covered
            rows.append(["time": Analysis.seconds(Double(n) / c.fps, places: 1000), "backgroundPixels": .number(Double(background)),
                         "screenVisibleRatio": Analysis.seconds(background > 0 ? Double(visible) / Double(background) : 0, places: 1000),
                         "personPixels": .number(Double(person)),
                         "personCoversRatio": Analysis.seconds(person > 0 ? Double(covered) / Double(person) : 0, places: 1000)])
        }
        let vr = tb > 0 ? Double(tv) / Double(tb) : 0, pr = tp > 0 ? Double(tc) / Double(tp) : 0
        return ["samples": .array(rows), "screenVisibleRatio": Analysis.seconds(vr, places: 1000), "personCoversRatio": Analysis.seconds(pr, places: 1000),
                "backgroundPixels": .number(Double(tb)), "personPixels": .number(Double(tp)),
                "pass": .bool(tb > 1000 && tp > 1000 && vr >= 0.9 && pr >= 0.9)]
    }
}
