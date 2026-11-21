import Foundation

enum Render {
    static func renderer(_ ctx: CommandContext, command: String) throws -> VideoRenderer {
        guard let r = ctx.services.renderer else {
            throw CommandError(.io, "\(command): no compositor in this host (use regista-engine / regista-mcp, which include it)")
        }
        return r
    }

    static func output(_ path: String, command: String) throws -> URL {
        let url = URL(fileURLWithPath: EngineConfig.expand(path)).standardizedFileURL
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw CommandError(.io, "\(command): cannot create \(url.deletingLastPathComponent().path)") }
        return url
    }

    static let presetParam = ParamSpec.optional("preset", .oneOf(ExportPreset.all.map(\.id)),
                                                "9:16 (1080×1920), 4:5 (1080×1350, feed portrait), 1:1 (1080×1080) or 16:9 (1920×1080); another aspect than the project's reframes every clip by crop (default: the project size).")

    /// Warnings worth returning with a render.
    static func warnings(_ job: RenderJob, _ project: Project) -> [JSONValue] {
        var w: [JSONValue] = []
        for t in project.tracks where t.kind == .caption {
            guard let c = t.captions else { continue }
            if let s = project.tracks.first(where: { $0.id == c.sourceTrack }), Captions.signature(of: s) != c.sourceSignature {
                w.append(.string("captions on \(t.name) are stale (the timeline changed): run captions.generate"))
            }
        }
        return w
    }
}

enum ExportRender: Command {
    static let id = "export.render"
    static let summary = "Render the final video: the timeline to an mp4 with the same compositor frame.render uses (crops/keyframes/grade, captions drawn natively); H.264 High yuv420p 30 fps, faststart, AAC 48 kHz 192 kb/s; preset \"9:16\" for a reel. The sound is the mix of the unmuted audio tracks through a limiter. It runs rules.check first and refuses while a rule of the project's kind fails, with the list and the fixes (rules.fix {all: true} applies the safe ones). Returns frames, duration, the measured loudness (expect −15 ±0.5 LUFS, true peak ≤ −1.5), the rule check and warnings (e.g. stale captions)."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("path", .string, "Output .mp4."),
        Render.presetParam,
        .optional("captions", .boolean, "Draw the caption track (default true)."),
        .optional("bitrate", .number, "Video bit rate, Mb/s (default 14)."),
        .optional("ceiling", .number, "True-peak ceiling of the mix, dBTP (default \(LoudnessTarget.text(LoudnessTarget.truePeak)))."),
        .optional("loudness", .number, "Integrated loudness target of the final mix, LUFS (e.g. -15 once music and SFX are added): the mix is measured and re-made with one static gain before the limiter. Default: no correction (the voice is already at -15)."),
        .optional("exportAnyway", .boolean, "Export although an editing rule fails. Only when the user said to export anyway, after being told what fails; never on your own."),
        .optional("appendCover", .boolean, "Hold the reel's cover (cover.set) for the last \(Cover.appendedFrames) frames, silent, so that it can be picked as the thumbnail frame in a phone app (default false). The rules read the edit without it."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let renderer = try Render.renderer(ctx, command: id)
        guard project.duration > .zero else { throw CommandError.conflict("\(id): the timeline is empty") }
        // The editing rules (#31): no delivery while a check fails, unless the person said to export anyway.
        let rules = RuleCheck.run(project, book: ctx.services.rules, language: RuleBook.interfaceLanguage(), renderer: renderer)
        let anyway = p.bool("exportAnyway") == true
        if !rules.pass && !anyway {
            let failures = rules.failures
            throw CommandError.conflict("\(id): the edit breaks \(failures.count) editing rule\(failures.count == 1 ? "" : "s") of its kind (\(rules.kind)):\n"
                + failures.map { "- " + $0.line }.joined(separator: "\n")
                + "\nFix them first — rules.fix {all: true} applies every safe fix in one undo step; the others need an edit — then export "
                + "again. Pass exportAnyway: true only if the user, told what fails, said to export anyway.")
        }
        // The cover held at the end (#42): drawn after the rules, which read the edit as it is.
        var coverPNG: URL?
        defer { if let coverPNG { try? FileManager.default.removeItem(at: coverPNG) } }
        if p.bool("appendCover") == true {
            try Cover.requireVertical(project, command: id)
            guard let cover = project.cover else { throw CommandError.conflict("\(id): appendCover needs the reel's cover: cover.set {time, title} first") }
            let png = TemporaryFolder.url.appendingPathComponent("regista-cover-end-\(UUID().uuidString.prefix(8)).png")
            coverPNG = png
            _ = try CoverRender.render(project, cover, to: png, ctx, command: id)
            project = CoverRender.appended(project, cover: png)
        }
        let preset = ExportPreset.named(p.string("preset"), project: project)
        let job = RenderJob(project: project, preset: preset, captions: p.bool("captions") ?? true)
        let output = try Render.output(p.requiredString("path"), command: id)
        let started = Date()

        // The mix: sample-exact clips with their fades, limited 0.5 dB under the true-peak ceiling (inter-sample overs).
        let rate = project.settings.sampleRate
        var wav: URL?
        defer { if let wav { try? FileManager.default.removeItem(at: wav) } }
        let ceiling = p.number("ceiling") ?? LoudnessTarget.truePeak
        var masterGain = 0.0
        let media = try ctx.mediaDirectory()
        let envelopes = try AudioPlan.writeEnvelopes(project, rate: rate, to: media)
        defer { for e in envelopes.values { try? FileManager.default.removeItem(at: e) } }
        let clips = AudioPlan.clips(project, rate: rate, envelopes: envelopes)
        // In a job (the app's export): the mix is the first tenth, the frames the rest.
        if !clips.isEmpty { try CommandJob.stage(0, 0.1, detail: nil) {
            let mixURL = media.appendingPathComponent("mix-\(UUID().uuidString.prefix(8)).wav")
            wav = mixURL   // removed by the defer above whatever happens (a cancelled mix leaves no partial wav)
            let length = Int((project.duration.seconds * Double(rate)).rounded())
            try ctx.services.audio.mix(clips, length: length, rate: rate, gain: 0, ceiling: ceiling - 0.5, to: mixURL)
            if let target = p.number("loudness") {
                // One static correction (twice at most: the limiter takes back a little of a positive gain).
                for _ in 0..<2 {
                    let m = try ctx.services.audio.loudness(of: [AudioSpan(url: mixURL, channels: 2)])
                    guard abs(m.integrated - target) > 0.2, m.integrated.isFinite else { break }
                    masterGain += target - m.integrated
                    try ctx.services.audio.mix(clips, length: length, rate: rate, gain: masterGain, ceiling: ceiling - 0.5, to: mixURL)
                }
            }
        } }
        let report = try CommandJob.stage(0.1, 1) { try renderer.export(job, audio: wav, to: output, bitrate: Int((p.number("bitrate") ?? 14) * 1_000_000)) }
        var result: [String: JSONValue] = [
            "path": .string(output.path), "preset": .string(preset.id), "width": .number(Double(preset.width)),
            "height": .number(Double(preset.height)), "fps": .number(job.frameRate.doubleValue), "frames": .number(Double(report.frames)),
            "duration": ProjectState.seconds(project.duration), "audioClips": .number(Double(clips.count)),
            "captions": .bool(job.captions != nil), "seconds": Analysis.seconds(Date().timeIntervalSince(started), places: 10),
            "warnings": .array(Render.warnings(job, project)),
            "rules": ["kind": .string(rules.kind), "pass": .bool(rules.pass), "exportedAnyway": .bool(anyway && !rules.pass),
                      "violations": .array(rules.violations.map(\.json))],
        ]
        // EU AI Act art. 50: a cloned voice in the video must be disclosed where it is published.
        if project.hasAudibleGeneratedVoice {
            result["aiDisclosure"] = "This video has an AI-generated voice (cloned, VoxCPM2): say so in the post description (e.g. «voix générée par IA» / «voce generata con IA»)."
        }
        // Said, not hidden: the first attempt stopped moving before the first second and the export started again once.
        if let frame = report.restartedAtFrame { result["restartedAtFrame"] = .number(Double(frame)) }
        if coverPNG != nil { result["coverFrames"] = .number(Double(Cover.appendedFrames)) }
        if masterGain != 0 { result["masterGain"] = .number((masterGain * 100).rounded() / 100) }
        if wav != nil { result["loudness"] = try ctx.services.audio.loudness(of: [AudioSpan(url: output, channels: 2)]).json }
        return .object(result)
    }
}

/// Images a command hands to the client: listed under "images" in the result as {path, mimeType, width, height};
/// the MCP server inlines each one as image content, so an agent sees what it rendered.
public enum Previews {
    /// Width of a single-frame preview (a 9:16 frame becomes 540×960).
    public static let frameWidth = 540
    /// At most this many frames of one frame.render are inlined (use frame.contactSheet for more).
    public static let maxFrames = 6
    /// A contact sheet fits in this box.
    public static let sheetSize = 1600

    static func directory() throws -> URL {
        let dir = TemporaryFolder.url.appendingPathComponent("regista-previews")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw CommandError(.io, "cannot create \(dir.path)") }
        return dir
    }

    static func entry(_ url: URL, _ size: (width: Int, height: Int)) -> JSONValue {
        ["path": .string(url.path), "mimeType": "image/jpeg", "width": .number(Double(size.width)), "height": .number(Double(size.height))]
    }

    /// JPEG previews of the first `maxFrames` PNGs, 540 px wide.
    static func frames(_ pngs: [URL], _ ctx: CommandContext) throws -> [JSONValue] {
        guard let images = ctx.services.images else { return [] }
        let dir = try directory()
        return try pngs.prefix(maxFrames).map { png in
            let out = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(png.deletingPathExtension().lastPathComponent).jpg")
            return entry(out, try images.writePreview(of: png, maxWidth: frameWidth, maxHeight: frameWidth * 4, to: out))
        }
    }
}

enum FrameRender: Command {
    static let id = "frame.render"
    static let summary = "Look at one or a few frames of the edit at full quality, rendered by the export's compositor (what you see is what export.render writes: crops, punch-ins, grade, captions). Use it to inspect a precise moment (a caption, a cut, the framing); for an overview of the whole reel use frame.contactSheet. Writes PNGs (one time to path, several into directory) and returns their paths plus up to 6 previews (540 px wide) as images you can see."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("time", .time, "Timeline time (snapped to the frame grid)."),
        .optional("times", .array(.number), "Several timeline times."),
        .optional("path", .string, "Output .png for a single time (default: a temporary file)."),
        .optional("directory", .string, "Folder for several frames (frame-<seconds>.png; default: a temporary folder)."),
        Render.presetParam,
        .optional("captions", .boolean, "Draw the caption track (default true)."),
        .optional("inline", .boolean, "Return the previews as images (default true)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let renderer = try Render.renderer(ctx, command: id)
        var times = (p.numbers("times") ?? []).map { MediaTime(seconds: $0) }
        if let t = p.time("time") { times.insert(t, at: 0) }
        guard !times.isEmpty else { throw CommandError.invalid("\(id): pass time or times") }
        let rate = project.settings.frameRate
        let frame = MediaTime.frameDuration(at: rate)
        times = times.map { min($0.snapped(to: rate), max(project.duration - frame, .zero)) }
        let outputs: [URL]
        if times.count == 1, let path = p.string("path") { outputs = [try Render.output(path, command: id)] }
        else {
            let folder = try p.string("directory").map { URL(fileURLWithPath: EngineConfig.expand($0)) }
                ?? Previews.directory().appendingPathComponent("frames-\(UUID().uuidString.prefix(8))")
            outputs = try times.map { try Render.output(folder.appendingPathComponent(String(format: "frame-%08.3f.png", $0.seconds)).path, command: id) }
        }
        let job = RenderJob(project: project, preset: ExportPreset.named(p.string("preset"), project: project), captions: p.bool("captions") ?? true)
        try renderer.renderFrames(job, at: times, to: outputs)
        var result: [String: JSONValue] = [
            "frames": .array(zip(times, outputs).map { ["time": ProjectState.seconds($0), "path": .string($1.path)] }),
            "width": .number(Double(job.width)), "height": .number(Double(job.height)), "warnings": .array(Render.warnings(job, project))]
        if p.bool("inline") ?? true { result["images"] = .array(try Previews.frames(outputs, ctx)) }
        return .object(result)
    }
}

enum FrameContactSheet: Command {
    static let id = "frame.contactSheet"
    static let summary = "See the whole edit at a glance: renders N frames (evenly spaced over the timeline or a range, or at the times you give) with the export's compositor and tiles them in one JPEG sheet (at most 1600 px), each labelled with its timeline time. Use it after building the edit and after every fix to judge framing, punch-in alternation, caption position, wording and keyword boxes. Returns the sheet as an image you can see, its path and the times."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("count", .integer, "Number of evenly spaced frames (default 12, at most 30)."),
        .optional("times", .array(.number), "Timeline times instead of evenly spaced ones."),
        .optional("from", .time, "Start of the sampled range (default 0)."),
        .optional("to", .time, "End of the sampled range (default: the end of the timeline)."),
        .optional("path", .string, "Output .jpg (default: <project>.regista/previews/contact-<n>.jpg, or a temporary file)."),
        Render.presetParam,
        .optional("captions", .boolean, "Draw the caption track (default true)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let renderer = try Render.renderer(ctx, command: id)
        guard let images = ctx.services.images else { throw CommandError(.io, "\(id): no image toolkit in this host (use regista-engine / regista-mcp)") }
        guard project.duration > .zero else { throw CommandError.conflict("\(id): the timeline is empty") }
        let rate = project.settings.frameRate
        let frame = MediaTime.frameDuration(at: rate)
        let last = max(project.duration - frame, .zero)
        var seconds = p.numbers("times") ?? []
        if seconds.isEmpty {
            let n = min(max(p.int("count") ?? 12, 1), 30)
            let a = p.number("from") ?? 0, b = min(p.number("to") ?? project.duration.seconds, project.duration.seconds)
            guard b > a else { throw CommandError.invalid("\(id): to must be after from") }
            seconds = (0..<n).map { a + (Double($0) + 0.5) * (b - a) / Double(n) }
        }
        guard seconds.count <= 30 else { throw CommandError.invalid("\(id): at most 30 frames per sheet") }
        let times = seconds.map { min(MediaTime(seconds: $0).snapped(to: rate), last) }

        let tmp = try Previews.directory().appendingPathComponent("sheet-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pngs = times.indices.map { tmp.appendingPathComponent("f\($0).png") }
        let job = RenderJob(project: project, preset: ExportPreset.named(p.string("preset"), project: project), captions: p.bool("captions") ?? true)
        try renderer.renderFrames(job, at: times, to: pngs)

        let output: URL
        if let path = p.string("path") { output = try Render.output(path, command: id) }
        else if let folder = ctx.projectURL?.appendingPathComponent("previews") {
            var n = 1
            while FileManager.default.fileExists(atPath: folder.appendingPathComponent("contact-\(n).jpg").path) { n += 1 }
            output = try Render.output(folder.appendingPathComponent("contact-\(n).jpg").path, command: id)
        } else {
            output = try Previews.directory().appendingPathComponent("contact-\(UUID().uuidString.prefix(8)).jpg")
        }
        let labels = times.map { String(format: "%.2f s", $0.seconds) }
        let size = try images.writeContactSheet(pngs, labels: labels, maxWidth: Previews.sheetSize, maxHeight: Previews.sheetSize, to: output)
        return ["path": .string(output.path), "times": .array(times.map { ProjectState.seconds($0) }),
                "width": .number(Double(size.width)), "height": .number(Double(size.height)),
                "warnings": .array(Render.warnings(job, project)), "images": [Previews.entry(output, size)]]
    }
}

enum ExportMLT: Command {
    static let id = "export.mlt"
    static let summary = "Write the timeline as a Shotcut/MLT project so a human can retouch it: one clip per timeline clip with its crop and grade, overlays (stills, PNG sequences, inserts) placed with Size/Position, titles as transparent PNGs, the sound clips with fades, gain and the music ducking as volume keyframes, and the captions as one PNG per caption state on their own track (images written next to the .mlt). Returns the path, image counts and warnings (what Shotcut cannot represent: animations, effects, blends, transitions)."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("path", .string, "Output .mlt."),
        .optional("captions", .boolean, "Export the caption track as images (default true)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let url = try Render.output(p.requiredString("path"), command: id)
        let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: p.bool("captions") ?? true)
        var images: [URL] = []
        var warnings: [String] = []
        if job.captions != nil {
            if let renderer = ctx.services.renderer {
                let dir = url.deletingPathExtension().appendingPathExtension("captions")
                try? FileManager.default.removeItem(at: dir)
                images = try renderer.writeCaptionImages(job, to: dir)
            } else {
                warnings.append("no caption renderer in this host: captions not exported")
            }
        }
        // Titles: one full-frame transparent PNG each, at rest, drawn by the compositor.
        var layers: [String: URL] = [:]
        let titleClips = project.tracks.filter { $0.kind == .overlay || $0.kind == .video }.flatMap(\.clips).filter(\.isGenerated)
        if !titleClips.isEmpty, let renderer = ctx.services.renderer {
            let dir = url.deletingPathExtension().appendingPathExtension("titles")
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var rest = project
            rest.transitions = nil
            for t in rest.tracks.indices { for c in rest.tracks[t].clips.indices where rest.tracks[t].clips[c].isGenerated {
                rest.tracks[t].clips[c].keyframes = nil; rest.tracks[t].clips[c].effects = nil
            } }
            let restJob = RenderJob(project: rest, preset: ExportPreset.named(nil, project: project), captions: false)
            for c in titleClips {
                let png = dir.appendingPathComponent("\(c.id).png")
                try renderer.writeLayerImage(restJob, clipID: c.id, at: (c.start + MediaTime(seconds: c.duration.seconds / 2)).snapped(to: project.settings.frameRate), to: png)
                layers[c.id] = png
            }
        }
        var writer = MLTWriter(project: project, captions: job.captions, captionImages: images, layerImages: layers)
        let xml = writer.xml()
        do { try xml.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw CommandError(.io, "\(id): cannot write \(url.path): \(error.localizedDescription)") }
        warnings += writer.warnings
        return ["path": .string(url.path), "captionImages": .number(Double(images.count)), "titleImages": .number(Double(layers.count)),
                "frames": .number((project.duration.seconds * project.settings.frameRate.doubleValue).rounded()),
                "warnings": .array(warnings.map { .string($0) })]
    }
}
