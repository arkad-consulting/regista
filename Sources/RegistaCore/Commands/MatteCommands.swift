import Foundation

// Text behind the person (issue #5, X2): person mattes of the camera frames (Apple Vision) let a title or overlay
// marked `behindSubject` sit between the background and the speaker.

enum Matte {
    /// The camera asset: the asset of the first clip on the bottom video track.
    static func defaultAsset(_ project: Project) -> String? {
        project.tracks.first { $0.kind == .video && !$0.clips.isEmpty }?.clips.first?.assetID
    }

    /// Source frame indices of `asset` shown by timeline clips over [from, to), with one frame of margin.
    static func frames(of asset: MediaAsset, in project: Project, from: MediaTime, to: MediaTime, fps: Double) -> Set<Int> {
        var out = Set<Int>()
        // The margin frame never goes past the file's last frame (a clip that runs to the end of its source).
        let last = max(Int((asset.duration.seconds * fps + 1e-6).rounded(.down)) - 1, 0)
        for track in project.tracks where track.kind == .video || track.kind == .overlay {
            for c in track.clips where c.assetID == asset.id && c.start < to && from < c.end {
                let a = max(c.start, from), b = min(c.end, to)
                let s0 = (c.sourceIn + (a - c.start)).seconds, s1 = (c.sourceIn + (b - c.start)).seconds
                let i0 = Int((s0 * fps).rounded(.down)) - 1, i1 = min(Int((s1 * fps).rounded(.up)) + 1, last)
                if i1 >= i0 { out.formUnion(max(i0, 0)...i1) }
            }
        }
        return out
    }

    /// Frames whose matte is missing for the behind-subject clip `clip` (empty: it is covered).
    static func missing(for clip: Clip, in project: Project) -> Int {
        guard let id = defaultAsset(project), let asset = project.asset(id), let v = asset.video else { return 0 }
        let fps = asset.analysis?.matte?.frameRate ?? v.frameRate.doubleValue
        let need = frames(of: asset, in: project, from: clip.start, to: clip.end, fps: fps)
        guard let m = asset.analysis?.matte else { return need.count }
        return need.filter { !m.has($0) }.count
    }

    /// Result warnings for a layer added with behindSubject.
    static func warnings(_ clip: Clip, _ project: Project) -> [JSONValue] {
        guard clip.behindSubject == true else { return [] }
        let n = missing(for: clip, in: project)
        return n > 0 ? [.string("behindSubject: \(n) frames under this layer have no person matte yet — run matte.track {from: \(clip.start.displaySeconds), to: \(clip.end.displaySeconds)} (until then the layer is drawn over the person)")] : []
    }
}

enum MatteTrackCommand: Command {
    static let id = "matte.track"
    static let summary = "Track the speaker's person matte (Apple Vision person segmentation, quality balanced, on-device, any tier) on the camera frames the timeline shows between from and to (default the whole timeline), smoothed over neighbouring frames and cached as a sidecar (frames already tracked are skipped). Needed for behindSubject: true on title.add / overlay.add (text behind the person: the hook title, once per reel). Returns frames tracked, coverage and timing."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("assetId", .string, "Camera asset (default: the asset of the bottom video track)."),
        .optional("from", .time, "Timeline start (default 0)."),
        .optional("to", .time, "Timeline end (default: the end of the timeline)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        guard let aid = p.string("assetId") ?? Matte.defaultAsset(project) else {
            throw CommandError.conflict("\(id): no video clip on the timeline: pass assetId")
        }
        let i = try Analysis.assetIndex(aid, in: project, command: id)
        let asset = project.assets[i]
        guard let video = asset.video, asset.image == nil else { throw CommandError.conflict("\(id): \(asset.name) is not a video") }
        guard let segmenter = ctx.services.segmenter else {
            throw CommandError(.io, "\(id): no person segmentation in this host (use regista-engine / regista-mcp, which include Apple Vision)")
        }
        let fps = video.frameRate.doubleValue
        let from = p.time("from") ?? .zero, to = p.time("to") ?? project.duration
        guard to > from else { throw CommandError.invalid("\(id): to must be after from") }
        var frames = Matte.frames(of: asset, in: project, from: from, to: to, fps: fps)
        if frames.isEmpty {
            // Not on the timeline: the whole asset (or the window in source time).
            let last = Int((asset.duration.seconds * fps).rounded(.down)) - 1
            frames = Set(Int((from.seconds * fps).rounded(.down))...max(Int((from.seconds * fps).rounded(.down)), min(last, Int((to.seconds * fps).rounded(.up)))))
        }
        let dir = try ctx.mediaDirectory().appendingPathComponent("\(asset.id)-matte")
        let started = Date()
        let report = try segmenter.segment(MatteRequest(video: URL(fileURLWithPath: asset.path), frames: frames.sorted(), frameRate: fps, directory: dir))
        let seconds = Date().timeIntervalSince(started)
        var existing = Set<Int>()
        for r in asset.analysis?.matte?.ranges ?? [] { existing.formUnion(r[0]...r[1]) }
        let present = Set(frames.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent(String(format: "%06d.png", $0)).path) })
        let all = existing.union(present)
        let old = asset.analysis?.matte
        let matte = MatteTrack(directory: dir.path, width: report.width > 0 ? report.width : old?.width ?? 0,
                               height: report.height > 0 ? report.height : old?.height ?? 0, frameRate: fps,
                               ranges: MatteTrack.ranges(all), engine: report.engine)
        project.assets[i].analysis = project.assets[i].analysis ?? AssetAnalysis()
        project.assets[i].analysis?.matte = matte
        ctx.project = project
        return ["assetId": .string(asset.id), "directory": .string(dir.path), "frames": .number(Double(frames.count)),
                "segmented": .number(Double(report.segmented)), "cached": .number(Double(frames.count - report.segmented)),
                "missing": .number(Double(frames.count - present.count)), "tracked": .number(Double(matte.frameCount)),
                "matteSize": [.number(Double(matte.width)), .number(Double(matte.height))],
                "coverage": Analysis.seconds(report.coverage, places: 1000), "engine": .string(report.engine),
                "seconds": Analysis.seconds(seconds, places: 10),
                "fps": Analysis.seconds(seconds > 0 ? Double(report.segmented) / seconds : 0, places: 10)]
    }
}

enum GraphicsCheckBehindSubject: Command {
    static let id = "graphics.checkBehindSubject"
    static let summary = "Check a behindSubject title/overlay: at sample times it renders the frame with the layer, without it, and with it in front, then reads the person matte where the layer has pixels. Inside the person (matte ≥ 0.9) the frame must equal the render without the layer (the person hides it); outside (matte ≤ 0.1) it must equal the layer in front (it shows normally). With path, the frames come from the exported mp4 (a pixel then counts when it is closer to the expected render than to the other). Returns per-time pixel counts, hiddenRatio, visibleRatio and pass."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("clipId", .string, "The behindSubject clip."),
        .optional("samples", .integer, "Sample times inside the clip (default 5)."),
        .optional("path", .string, "Exported mp4 to read the frames with the layer from (default: rendered by the export compositor)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        guard let renderer = ctx.services.renderer, let images = ctx.services.images else {
            throw CommandError(.io, "\(id): needs the compositor (regista-engine / regista-mcp)")
        }
        let cid = p.requiredString("clipId")
        let (t, c) = try Timeline.locate(clip: cid, in: project)
        let clip = project.tracks[t].clips[c]
        guard clip.behindSubject == true else { throw CommandError.conflict("\(id): \(cid) is not behindSubject") }
        let rate = project.settings.frameRate
        let n = max(p.int("samples") ?? 5, 1)
        let frame = MediaTime.frameDuration(at: rate).seconds
        let span = clip.duration.seconds - 4 * frame
        let times: [MediaTime] = (0..<n).map { k in
            let offset: Double = 2 * frame + span * (Double(k) + 0.5) / Double(n)
            return (clip.start + MediaTime(seconds: offset)).snapped(to: rate)
        }

        var without = project
        without.tracks[t].clips.remove(at: c)
        var inFront = project
        inFront.tracks[t].clips[c].behindSubject = nil
        let preset = ExportPreset.named(nil, project: project)
        let W = preset.width, H = preset.height
        let dir = TemporaryFolder.url.appendingPathComponent("regista-behind-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func render(_ pr: Project, _ tag: String) throws -> [URL] {
            let urls = times.indices.map { dir.appendingPathComponent("\(tag)-\($0).png") }
            try renderer.renderFrames(RenderJob(project: pr, preset: preset, captions: false), at: times, to: urls)
            return urls
        }
        let path = p.string("path").map(EngineConfig.expand)
        let a: [URL]
        if let path {
            let ffmpeg = ctx.services.config.url(ctx.services.config.ffmpeg)
            a = try times.enumerated().map { i, time in
                let out = dir.appendingPathComponent("a-\(i).png")
                try Subprocess.check(ffmpeg, FFmpegAudio.quiet + ["-i", path, "-ss", String(format: "%.4f", time.seconds + frame / 2),
                                                                  "-frames:v", "1", "-vf", "scale=\(W):\(H)", out.path])
                return out
            }
        } else {
            a = try render(project, "a")
        }
        let b = try render(without, "b"), f = try render(inFront, "c")
        let tolerance = 9   // over R+G+B
        let job = RenderJob(project: project, preset: preset, captions: false)

        var rows: [JSONValue] = []
        var totalPerson = 0, totalHidden = 0, totalBackground = 0, totalVisible = 0
        for (i, time) in times.enumerated() {
            let layers = job.layers(at: time)
            guard let li = layers.firstIndex(where: { $0.clipID == cid }), case .some(.some(let si)) = RenderJob.subjects(layers)[li],
                  let mattePath = layers[si].matte, let m = project.asset(layers[si].assetID)?.analysis?.matte else {
                rows.append(["time": .number(time.displaySeconds), "matte": false])
                continue
            }
            let s = layers[si]
            let mg = try images.rgba(of: URL(fileURLWithPath: mattePath), width: m.width, height: m.height)
            let ga = try images.rgba(of: a[i], width: W, height: H), gb = try images.rgba(of: b[i], width: W, height: H)
            let gc = try images.rgba(of: f[i], width: W, height: H)
            /// L1 distance of two pixels over R, G, B.
            func dist(_ p: [UInt8], _ q: [UInt8], _ k: Int) -> Int {
                abs(Int(p[4 * k]) - Int(q[4 * k])) + abs(Int(p[4 * k + 1]) - Int(q[4 * k + 1])) + abs(Int(p[4 * k + 2]) - Int(q[4 * k + 2]))
            }
            var person = 0, hidden = 0, background = 0, visible = 0, layerPixels = 0
            for y in stride(from: 0, to: H, by: 2) {
                for x in stride(from: 0, to: W, by: 2) {
                    let k = y * W + x
                    guard dist(gc, gb, k) > 36 else { continue }
                    layerPixels += 1
                    // Output pixel → source pixel of the subject layer (crop, scale, offset; no rotation) → matte pixel.
                    let fw = Double(W), fh = Double(H)
                    let xc: Double = (Double(x) - fw / 2 - s.x * fw) / s.scale + fw / 2
                    let yc: Double = (Double(y) - fh / 2 - s.y * fh) / s.scale + fh / 2
                    let u: Double = s.crop[2] + xc * s.crop[0] / fw
                    let v: Double = s.crop[3] + yc * s.crop[1] / fh
                    let mx = Int(u * Double(m.width) / Double(s.sourceWidth))
                    let my = Int(v * Double(m.height) / Double(s.sourceHeight))
                    guard mx >= 0, my >= 0, mx < m.width, my < m.height else { continue }
                    let mv = mg[4 * (my * m.width + mx)]
                    let toB = dist(ga, gb, k), toC = dist(ga, gc, k)
                    // Render: exact (within 3 levels). mp4: the codec moves fine texture (hair) by more than the
                    // layer's contrast allows, so a pixel counts when it is closer to the expected render than to the other.
                    if mv >= 230 {
                        person += 1
                        if path == nil ? toB <= tolerance : toB < toC { hidden += 1 }
                    } else if mv <= 25 {
                        background += 1
                        if path == nil ? toC <= tolerance : toC < toB { visible += 1 }
                    }
                }
            }
            totalPerson += person; totalHidden += hidden; totalBackground += background; totalVisible += visible
            rows.append(["time": .number(time.displaySeconds), "layerPixels": .number(Double(layerPixels)), "personPixels": .number(Double(person)),
                         "backgroundPixels": .number(Double(background)),
                         "hiddenRatio": Analysis.seconds(person > 0 ? Double(hidden) / Double(person) : 1, places: 1000),
                         "visibleRatio": Analysis.seconds(background > 0 ? Double(visible) / Double(background) : 1, places: 1000)])
        }
        let hiddenRatio = totalPerson > 0 ? Double(totalHidden) / Double(totalPerson) : 0
        let visibleRatio = totalBackground > 0 ? Double(totalVisible) / Double(totalBackground) : 0
        let threshold = path == nil ? 0.97 : 0.9
        return ["clipId": .string(cid), "source": .string(path ?? "render"), "samples": .array(rows),
                "personPixels": .number(Double(totalPerson)), "backgroundPixels": .number(Double(totalBackground)),
                "hiddenRatio": Analysis.seconds(hiddenRatio, places: 1000), "visibleRatio": Analysis.seconds(visibleRatio, places: 1000),
                "pass": .bool(totalPerson > 0 && totalBackground > 0 && hiddenRatio >= threshold && visibleRatio >= threshold)]
    }
}
