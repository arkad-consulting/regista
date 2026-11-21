import Foundation

// Golden-media checks (issue #9, L3): measurements on rendered files, through ffmpeg/ffprobe.

enum MediaCheck {
    static func ffmpeg(_ ctx: CommandContext) -> URL { ctx.services.config.url(ctx.services.config.ffmpeg) }
    static func ffprobe(_ ctx: CommandContext) -> URL { ctx.services.config.url(ctx.services.config.ffprobe) }

    static func file(_ p: CommandParams, _ name: String, command: String) throws -> URL {
        let url = URL(fileURLWithPath: EngineConfig.expand(p.requiredString(name)))
        guard FileManager.default.fileExists(atPath: url.path) else { throw CommandError.notFound("\(command): no file at \(url.path)") }
        return url
    }

    /// Top-level MP4 atoms in file order (to tell faststart: moov before mdat).
    static func atoms(_ url: URL) -> [String] {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return [] }
        defer { try? h.close() }
        var out: [String] = [], offset: UInt64 = 0
        let size = (try? h.seekToEnd()) ?? 0
        while offset + 8 <= size, out.count < 64 {
            try? h.seek(toOffset: offset)
            guard let head = try? h.read(upToCount: 16), head.count >= 8 else { break }
            var len = head.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            out.append(String(decoding: head[4..<8], as: UTF8.self))
            if len == 1, head.count >= 16 { len = head[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            if len == 0 { break }
            offset += len
        }
        return out
    }

    /// Mean SSIM (Y, All) and PSNR (average) of one frame of each file.
    static func compareFrame(_ ffmpeg: URL, _ a: URL, _ ta: Double, _ b: URL, _ tb: Double, frame: Double) throws -> (ssimY: Double, ssim: Double, psnr: Double) {
        // Seek a quarter frame early: the first frame at or after the seek point is the one at ta.
        let graph = "[0:v]setpts=PTS-STARTPTS,split[a1][a2];[1:v]setpts=PTS-STARTPTS,split[b1][b2];[a1][b1]ssim;[a2][b2]psnr"
        let r = try Subprocess.check(ffmpeg, ["-nostdin", "-hide_banner", "-nostats", "-ss", String(format: "%.6f", max(ta - frame / 4, 0)), "-i", a.path,
                                              "-ss", String(format: "%.6f", max(tb - frame / 4, 0)), "-i", b.path,
                                              "-frames:v", "1", "-lavfi", graph, "-f", "null", "-"])
        let log = r.stderrText
        func value(_ key: String, in line: String) -> Double? {
            guard let k = line.range(of: key) else { return nil }
            return Double(line[k.upperBound...].prefix { $0 == "." || $0.isNumber || $0 == "-" || $0 == "i" || $0 == "n" || $0 == "f" }
                .replacingOccurrences(of: "inf", with: "99"))
        }
        let ssimLine = log.split(separator: "\n").last { $0.contains("SSIM Y:") }.map(String.init) ?? ""
        let psnrLine = log.split(separator: "\n").last { $0.contains("PSNR y:") }.map(String.init) ?? ""
        guard let y = value("SSIM Y:", in: ssimLine), let all = value("All:", in: ssimLine) else {
            throw CommandError(.io, "media.compare: no SSIM in ffmpeg output")
        }
        return (y, all, value("average:", in: psnrLine) ?? 0)
    }
}

enum MediaProbe: Command {
    static let id = "media.probe"
    static let summary = "Check an exported file's technical facts: duration, frame count, codec/profile, pixel format, colour, frame rate, audio rate/bit rate, and whether the moov atom comes first (faststart). Returns them."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [.required("path", .string, "File to inspect.")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let url = try MediaCheck.file(p, "path", command: id)
        let r = try Subprocess.check(MediaCheck.ffprobe(ctx), ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
        let j = try JSONValue.parse(r.stdout)
        func num(_ v: JSONValue?) -> JSONValue { v?.stringValue.flatMap(Double.init).map { .number($0) } ?? v ?? .null }
        var out: [String: JSONValue] = ["path": .string(url.path), "duration": num(j.value(at: "format.duration"))]
        for s in j["streams"]?.arrayValue ?? [] {
            switch s["codec_type"]?.stringValue {
            case "video" where out["video"] == nil:
                out["video"] = ["codec": s["codec_name"] ?? .null, "profile": s["profile"] ?? .null, "width": s["width"] ?? .null,
                                "height": s["height"] ?? .null, "pixFmt": s["pix_fmt"] ?? .null, "colorSpace": s["color_space"] ?? .null,
                                "colorRange": s["color_range"] ?? .null, "fps": s["r_frame_rate"] ?? .null, "frames": num(s["nb_frames"]),
                                "duration": num(s["duration"]), "bitRate": num(s["bit_rate"])]
            case "audio" where out["audio"] == nil:
                out["audio"] = ["codec": s["codec_name"] ?? .null, "sampleRate": num(s["sample_rate"]), "channels": s["channels"] ?? .null,
                                "bitRate": num(s["bit_rate"]), "duration": num(s["duration"])]
            default: break
            }
        }
        let atoms = MediaCheck.atoms(url)
        out["atoms"] = .array(atoms.map { .string($0) })
        if let m = atoms.firstIndex(of: "moov"), let d = atoms.firstIndex(of: "mdat") { out["faststart"] = .bool(m < d) }
        return .object(out)
    }
}

enum MediaCompare: Command {
    static let id = "media.compare"
    static let summary = "Test helper: compare a render with a reference video frame by frame (ffmpeg SSIM and PSNR on sampled frames). align \"time\" compares the same timestamps; align \"source\" maps each sampled frame of the candidate (this project's video track) and of the reference (its segments.json) to the source frame it shows and compares frames showing the same source frame, away from cuts in both. Returns SSIM/PSNR statistics."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("candidate", .string, "The render to judge."),
        .required("reference", .string, "The reference video."),
        .optional("samples", .integer, "Number of sampled frames (default 30)."),
        .optional("times", .array(.number), "Candidate times to compare instead of evenly spaced samples."),
        .optional("align", .oneOf(["time", "source"]), "time (default) or source (needs referenceSegments)."),
        .optional("referenceSegments", .string, "The reference's segments.json (source in/out per segment, concatenated at 30 fps)."),
        .optional("trackId", .string, "Candidate video track for align source (default: the first video track)."),
        .optional("cutMargin", .integer, "align source: frames kept away from every cut (default 5)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let cand = try MediaCheck.file(p, "candidate", command: id), ref = try MediaCheck.file(p, "reference", command: id)
        let source = p.string("align") == "source"
        let fps = ctx.project?.settings.frameRate.doubleValue ?? 30
        let frame = 1 / fps
        let probe = try Subprocess.check(MediaCheck.ffprobe(ctx), ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", cand.path])
        let duration = Double(probe.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let total = Int((duration * fps).rounded())
        var pairs: [(Double, Double)] = []
        var skipped = 0

        if source {
            let project = try ctx.requireProject()
            guard let segPath = p.string("referenceSegments") else { throw CommandError.invalid("\(id): align source needs referenceSegments") }
            guard let data = FileManager.default.contents(atPath: EngineConfig.expand(segPath)) else { throw CommandError.notFound("\(id): no file at \(segPath)") }
            let segs = try JSONValue.parse(data)["segments"]?.arrayValue ?? []
            // Reference: ffmpeg trim=in:out keeps the source frames ceil(in·fps) ..< ceil(out·fps), concatenated.
            var refMap: [(src0: Int, src1: Int, ref0: Int)] = []
            var ref0 = 0
            for s in segs {
                guard let a = s["in"]?.doubleValue, let b = s["out"]?.doubleValue else { continue }
                let f0 = Int(((a * fps * 1e6).rounded() / 1e6).rounded(.up)), f1 = Int(((b * fps * 1e6).rounded() / 1e6).rounded(.up))
                refMap.append((f0, f1, ref0)); ref0 += f1 - f0
            }
            let track: Track
            if let tid = p.string("trackId") { track = project.tracks[try Timeline.trackIndex(tid, in: project, editable: false)] }
            else {
                guard let v = project.tracks.first(where: { $0.kind == .video }) else { throw CommandError.conflict("\(id): no video track") }
                track = v
            }
            let margin = p.int("cutMargin") ?? 5
            func refFrame(src: Int) -> Int? {
                for m in refMap where src >= m.src0 + margin && src < m.src1 - margin { return m.ref0 + src - m.src0 }
                return nil
            }
            func srcFrame(candidate f: Int) -> Int? {
                let t = MediaTime(seconds: Double(f) * frame + frame / 2)
                guard let c = track.clips.first(where: { $0.start <= t && t < $0.end }) else { return nil }
                let k = Int(((t - c.start).seconds * fps).rounded(.down))
                let n = Int((c.duration.seconds * fps).rounded())
                guard k >= margin, k < n - margin else { return nil }
                return Int((c.sourceIn.seconds * fps).rounded()) + k
            }
            let wanted = p.numbers("times").map { $0.map { Int(($0 * fps).rounded()) } }
                ?? (0..<(p.int("samples") ?? 30)).map { (2 * $0 + 1) * total / (2 * (p.int("samples") ?? 30)) }
            for f0 in wanted {
                var found: (Int, Int)?
                for d in [0] + (1...20).flatMap({ [$0, -$0] }) {
                    let f = f0 + d
                    guard f >= 0, f < total, let s = srcFrame(candidate: f), let r = refFrame(src: s) else { continue }
                    found = (f, r); break
                }
                if let (f, r) = found { pairs.append((Double(f) * frame, Double(r) * frame)) } else { skipped += 1 }
            }
        } else {
            let times = p.numbers("times") ?? (0..<(p.int("samples") ?? 30)).map { Double((2 * $0 + 1) * total / (2 * (p.int("samples") ?? 30))) * frame }
            pairs = times.map { ($0, $0) }
        }
        guard !pairs.isEmpty else { throw CommandError.conflict("\(id): no frame could be paired") }

        let ffmpeg = MediaCheck.ffmpeg(ctx)
        var results = [(ssimY: Double, ssim: Double, psnr: Double)?](repeating: nil, count: pairs.count)
        var failure: Error?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pairs.count) { i in
            do {
                let r = try MediaCheck.compareFrame(ffmpeg, cand, pairs[i].0, ref, pairs[i].1, frame: frame)
                lock.lock(); results[i] = r; lock.unlock()
            } catch { lock.lock(); failure = error; lock.unlock() }
        }
        if let failure { throw failure }
        let rs = results.compactMap { $0 }
        func r4(_ x: Double) -> JSONValue { .number((x * 10000).rounded() / 10000) }
        let ssim = rs.map(\.ssim), ssimY = rs.map(\.ssimY), psnr = rs.map(\.psnr)
        let rows: [JSONValue] = zip(pairs, rs).map { pr, r in
            ["t": r4(pr.0), "refT": r4(pr.1), "ssim": r4(r.ssim), "ssimY": r4(r.ssimY), "psnr": .number((r.psnr * 100).rounded() / 100)]
        }
        return ["align": .string(source ? "source" : "time"), "samples": .number(Double(rs.count)), "skipped": .number(Double(skipped)),
                "ssim": ["mean": r4(ssim.reduce(0, +) / Double(ssim.count)), "min": r4(ssim.min()!), "median": r4(Envelope.percentile(ssim, 50))],
                "ssimY": ["mean": r4(ssimY.reduce(0, +) / Double(ssimY.count)), "min": r4(ssimY.min()!)],
                "psnr": ["mean": .number((psnr.reduce(0, +) / Double(psnr.count) * 100).rounded() / 100), "min": .number((psnr.min()! * 100).rounded() / 100)],
                "frames": .array(rows)]
    }
}

enum CaptionsCheckTiming: Command {
    static let id = "captions.checkTiming"
    static let summary = "Verify the captions in an exported mp4: for every word, the first frame where it is visibly there vs the frame of its timeline word start (pass = within ±1 frame), and whether every word box lies inside the caption band. Run it on the final export. Returns pass, errors per word and the band check."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("path", .string, "Rendered video (export.render output, same preset)."),
        .optional("trackId", .string, "Caption track (default: the first one with captions)."),
        Render.presetParam,
        .optional("window", .integer, "Search ±frames around each expected reveal (default 6)."),
        .optional("tolerance", .integer, "Frames of error still passing (default 1)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let renderer = try Render.renderer(ctx, command: id)
        let url = try MediaCheck.file(p, "path", command: id)
        let t = try CaptionsCommon.trackIndex(p, project, command: id)
        let captions = try CaptionsCommon.require(project.tracks[t], command: id)
        var job = RenderJob(project: project, preset: ExportPreset.named(p.string("preset"), project: project))
        job.captions = captions
        let boxes = try renderer.captionLayout(job).flatMap { $0 }
        let reveals = captions.revealFrames(rate: job.frameRate)
        guard boxes.count == reveals.count, !boxes.isEmpty else { throw CommandError.conflict("\(id): no caption words") }
        let k = 2
        let templates = try renderer.captionStates(job, downscale: k)
        let states = captions.states
        // State in which each word first shows (reading order).
        var firstState: [Int] = []
        for (ci, ch) in captions.chunks.enumerated() {
            for wi in ch.words.indices {
                firstState.append(states.firstIndex { $0.chunk == ci && (captions.style.reveal == "chunk" || $0.count == wi + 1) } ?? 0)
            }
        }

        // The region holding every chunk's band (chunks moved off a face or by hand have their own, scaled ones),
        // downscaled the same way, luma, every frame of the file.
        let bands = try renderer.captionBands(job)
        guard bands.count == captions.chunks.count else { throw CommandError.conflict("\(id): caption bands do not match the chunks") }
        let tops = bands.map { Int($0[1].rounded()) }, heights = bands.map { Int($0[3].rounded()) }
        let top = max(tops.min() ?? 0, 0) / k * k
        let bottom = min(zip(tops, heights).map { $0 + $1 }.max() ?? 0, job.height)
        let regionH = (bottom - top) / k * k
        let w = job.width / k, rh = regionH / k
        let r = try Subprocess.check(MediaCheck.ffmpeg(ctx), ["-nostdin", "-v", "error", "-i", url.path, "-vf",
                                                              "crop=\(job.width):\(regionH):0:\(top),scale=\(w):\(rh):flags=area,format=gray",
                                                              "-f", "rawvideo", "-"])
        let pixels = [UInt8](r.stdout)
        let frames = pixels.count / (w * rh)
        // Which chunk each word belongs to (reading order), for its band and shift.
        let chunkOf = captions.chunks.enumerated().flatMap { ci, ch in ch.words.map { _ in ci } }
        let window = p.int("window") ?? 6, tolerance = p.int("tolerance") ?? 1

        var errors: [Int] = []
        var rows: [JSONValue] = []
        var undetected = 0
        for (i, (word, expected)) in reveals.enumerated() {
            let b = boxes[i], tpl = templates[firstState[i]]
            // Template coordinates are the chunk's own band; the frame region starts at `top`.
            let ci = chunkOf[i]
            let tw = tpl.width, th = tpl.height
            let chunkTop = Double(tops[ci]), dx = Int((bands[ci][0] / Double(k)).rounded())
            let dy = (tops[ci] - top) / k
            let x0 = max(Int(b[0]) / k - dx, 0), x1 = min(Int(b[0] + b[2]) / k - dx, tw)
            let y0 = max(Int(b[1] - chunkTop) / k, 0), y1 = min(Int(b[1] + b[3] - chunkTop) / k, th)
            var mask: [Int] = [], at: [Int] = [], ring: [Int] = []
            for y in y0..<max(y1, y0) {
                for x in x0..<max(x1, x0) where x + dx >= 0 && x + dx < w && y + dy >= 0 && y + dy < rh {
                    if tpl.alpha[y * tw + x] == 255 { mask.append(y * tw + x); at.append((y + dy) * w + x + dx) }
                    else { ring.append((y + dy) * w + x + dx) }
                }
            }
            let tv = mask.map { Double(tpl.luma[$0]) }
            let tm = tv.reduce(0, +) / Double(max(tv.count, 1))
            let tn = tv.map { ($0 - tm) * ($0 - tm) }.reduce(0, +).squareRoot()
            func ncc(_ f: Int) -> Double {
                guard f >= 0, f < frames, tn > 0 else { return 0 }
                let fv = at.map { Double(pixels[f * w * rh + $0]) }
                let fm = fv.reduce(0, +) / Double(fv.count)
                var dot = 0.0, fn = 0.0
                for (a, c) in zip(fv, tv) { dot += (a - fm) * (c - tm); fn += (a - fm) * (a - fm) }
                return fn > 0 ? dot / (fn.squareRoot() * tn) : 0
            }
            // Styles without an outline have a flat fill (no pattern to correlate) and ghost-karaoke words are already
            // there, dimmed, before they are spoken: the score is then how much brighter the glyph pixels are than the
            // rest of the word box (its shadow, the picture), 0…1.
            func contrast(_ f: Int) -> Double {
                guard f >= 0, f < frames, !at.isEmpty, !ring.isEmpty else { return 0 }
                let base = f * w * rh
                let g = at.reduce(0.0) { $0 + Double(pixels[base + $1]) } / Double(at.count)
                let r = ring.reduce(0.0) { $0 + Double(pixels[base + $1]) } / Double(ring.count)
                return (g - r) / 255
            }
            let flat = captions.style.strokeWidth < 0.5 || (captions.style.upcomingOpacity ?? 0) > 0
            // Search up to the last frame the word is still on (its chunk's end), so it must be present at the end.
            let lastOn = Int((captions.chunks[states[firstState[i]].chunk].end.seconds * job.frameRate.doubleValue - 1e-6).rounded(.up)) - 1
            let range = max(expected - window, 0)...max(min(expected + window, lastOn, frames - 1), max(expected - window, 0))
            let scores = range.map(flat ? contrast : ncc)
            let hi = scores.max() ?? 0, lo = scores.min() ?? 0
            let (present, step) = flat ? (0.05, 0.035) : (0.5, 0.2)
            // Start of the trailing run above the midpoint between "absent" and "present" (a look-alike in the
            // previous chunk, e.g. IL under ALL'IA, can match earlier but is interrupted by the change of chunk).
            var observed: Int?
            if hi > present, hi - lo > step, let last = scores.last, last >= (hi + lo) / 2 {
                let thr = (hi + lo) / 2
                var j = scores.count - 1
                while j > 0, scores[j - 1] >= thr { j -= 1 }
                observed = range.lowerBound + j
            }
            guard let observed else {
                undetected += 1
                rows.append(["word": .string(word.text), "expected": .number(Double(expected)), "observed": .null, "ncc": .number((hi * 100).rounded() / 100)])
                continue
            }
            let err = observed - expected
            errors.append(err)
            if abs(err) > tolerance {
                rows.append(["word": .string(word.text), "expected": .number(Double(expected)), "observed": .number(Double(observed)), "error": .number(Double(err))])
            }
        }
        // Every word inside its own chunk's band.
        let minY = boxes.map { $0[1] }.min()!, maxY = boxes.map { $0[1] + $0[3] }.max()!
        let band = (Double(tops.min() ?? 0), Double(zip(tops, heights).map { $0 + $1 }.max() ?? 0))
        let within = errors.filter { abs($0) <= tolerance }.count
        let inside = boxes.indices.allSatisfy { i in
            let t0 = Double(tops[chunkOf[i]])
            return boxes[i][1] >= t0 && boxes[i][1] + boxes[i][3] <= t0 + Double(heights[chunkOf[i]])
        }
        return ["words": .number(Double(reveals.count)), "framesDecoded": .number(Double(frames)), "detected": .number(Double(errors.count)),
                "undetected": .number(Double(undetected)), "withinTolerance": .number(Double(within)),
                "maxAbsError": .number(Double(errors.map(abs).max() ?? 0)), "exact": .number(Double(errors.filter { $0 == 0 }.count)),
                "meanError": .number(errors.isEmpty ? 0 : (Double(errors.reduce(0, +)) / Double(errors.count) * 1000).rounded() / 1000),
                "pass": .bool(undetected == 0 && within == errors.count && inside),
                "band": ["top": .number(band.0), "bottom": .number(band.1), "inkTop": .number(minY), "inkBottom": .number(maxY), "inside": .bool(inside),
                         "movedChunks": .number(Double(captions.chunks.filter { $0.bandY != nil || $0.offsetX != nil }.count)),
                         "placedChunks": .number(Double(captions.chunks.indices.filter(captions.isManual).count))],
                "outliers": .array(rows)]
    }
}

enum MediaCheckSync: Command {
    static let id = "media.checkSync"
    static let summary = "Verify A/V sync of an exported mp4: its sound cross-correlated with the camera sound of the clips laid out on the timeline, over windows in the middle of the longest clips. Positive lag = sound late; pass = under one frame. Returns lag (ms, frames) and correlation."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("path", .string, "Rendered video."),
        .optional("trackId", .string, "Audio track whose clips define the layout (default: the first audio track)."),
        .optional("windows", .integer, "Number of 2 s windows (default 8)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let url = try MediaCheck.file(p, "path", command: id)
        let track: Track
        if let tid = p.string("trackId") { track = project.tracks[try Timeline.trackIndex(tid, in: project, editable: false)] }
        else {
            guard let a = project.tracks.first(where: { $0.kind == .audio && !$0.clips.isEmpty }) else { throw CommandError.conflict("\(id): no audio track") }
            track = a
        }
        let rate = 48000
        let dir = TemporaryFolder.url.appendingPathComponent("regista-sync-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("render.wav")
        try Subprocess.check(MediaCheck.ffmpeg(ctx), FFmpegAudio.quiet + ["-i", url.path, "-map", "0:a:0", "-af", "pan=mono|c0=0.5*c0+0.5*c1",
                                                                          "-ar", String(rate), "-c:a", "pcm_s16le", wav.path])
        let rendered = try WAVAudio.read(wav).mono()
        var reference = [Float](repeating: 0, count: rendered.count)
        var cache: [String: [Float]] = [:]
        // Retimed clips (clip.speed) are left out: their sound is stretched or muted (effects.check measures them).
        for c in track.clips where c.speed == nil {
            guard let asset = project.asset(c.assetID) else { continue }
            let camera = asset.origin.flatMap { project.asset($0.assetID) } ?? asset
            guard let working = camera.analysis?.audio?.working else {
                throw CommandError.conflict("\(id): \(camera.id) has no extracted audio — run media.extractAudio")
            }
            if cache[working] == nil { cache[working] = try WAVAudio.read(URL(fileURLWithPath: working)).mono() }
            let src = cache[working]!
            let s0 = Int((c.sourceIn.seconds * Double(rate)).rounded()), t0 = Int((c.start.seconds * Double(rate)).rounded())
            let n = Int((c.duration.seconds * Double(rate)).rounded())
            for i in 0..<n where s0 + i < src.count && t0 + i < reference.count { reference[t0 + i] = src[s0 + i] }
        }
        let longest = track.clips.filter { $0.speed == nil }.sorted { $0.duration > $1.duration }.prefix(p.int("windows") ?? 8)
        let windows = longest.map { c -> (start: Double, end: Double) in
            let mid = (c.start.seconds + c.end.seconds) / 2
            return (max(mid - 1, c.start.seconds + 0.15), min(mid + 1, c.end.seconds - 0.15))
        }
        let sync = SyncCheck.lag(original: reference, processed: rendered, sampleRate: rate, windows: windows)
        let fps = project.settings.frameRate.doubleValue
        return ["lagMs": .number((sync.lagSeconds * 10000).rounded() / 10), "lagFrames": .number((sync.lagSeconds * fps * 100).rounded() / 100),
                "correlation": .number((sync.correlation * 1000).rounded() / 1000), "windows": .number(Double(windows.count))]
    }
}
