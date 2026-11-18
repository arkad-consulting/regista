import Foundation

// motion.add (issue #22): one command for every motion template. The templates themselves are listed by
// effects.catalog (category templates) with their fields, description, useWhen and avoid.

enum MotionAdd: Command {
    static let id = "motion.add"
    static let summary = "Add a motion template — an animated, branded graphic drawn by the compositor: an orbit carousel of photos around the speaker, an iOS-style checklist whose ticks land on the words, a counter or clock, a swing tag, scrolling marquee rows, the shot shrinking into a phone frame, floating cards behind the speaker, a HUD viewfinder, animated charts… effects.catalog {category: \"templates\"} lists every template with its fields (types, example values), description, useWhen and avoid; effects.preview shows one before adding it. Colours and fonts come from the applied brand kit (fields accept #RRGGBB or colour roles: ink, paper, primary, accent, highlight). Templates that go behind the person (layering behind/split) need matte.track over their window. sync: true times a list field (e.g. checklist rows) to the transcript: each entry lands when its first word is spoken. Without band or position, over a face-tracked picture (faces.track), it takes the first place the template allows that leaves the face free for its whole time; a place given is kept, with a warning when it covers the face. Returns the clip, the fields used, the place and faceCheck (whether the place was checked against a face, or why not) and warnings."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("template", .string, "Template id (effects.catalog category templates: orbit-carousel, checklist, counter, …)."),
        .required("start", .time, "Timeline start (land it on the word)."),
        .optional("duration", .time, "Seconds on screen (default: the template's). Left out, the graphic ends with the main video at the latest: shortened, or started earlier to keep 1 s (the result's timing says so)."),
        .optional("end", .time, "Timeline end instead of duration."),
        .optional("fields", .object, "Template fields (names from effects.catalog; omitted ones keep their example/default)."),
        .optional("band", .oneOf(SafeZones.bandNames), "Vertical band for templates that sit in one (top y 110–640, middle, lower). Without band and position, a template over a face-tracked picture takes the first of its places (its band, then the others; or its point, then the point mirrored) that leaves the face free."),
        .optional("position", .array(.number), "Centre [x, y] on a 1080×1920 frame (overrides band). Kept even over a face (the result warns)."),
        .optional("sync", .boolean, "Time the template's list entries to the transcript words (checklist ticks, script lines)."),
        .optional("behind", .boolean, "Draw the whole template behind the speaker (needs matte.track), e.g. a kicker headline the head passes in front of."),
        .optional("trackId", .string, "Overlay track (default: a free one)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let name = p.requiredString("template")
        guard let spec = MotionRegistry.spec(name) else {
            let known = MotionRegistry.all.map(\.id)
            throw CommandError.invalid("\(id): no template \"\(name)\"" + (known.isEmpty ? " (this host has no motion templates)" : " (templates: \(known.joined(separator: ", ")))"))
        }
        let given = p.json("fields")?.objectValue ?? [:]
        for k in given.keys.sorted() where spec.field(k) == nil {
            throw CommandError.invalid("\(id): \(name) has no field \"\(k)\" (fields: \(spec.fields.map(\.name).joined(separator: ", ")))")
        }
        var fields = spec.defaults
        for (k, v) in given {
            if let f = spec.field(k), let problem = check(v, f) { throw CommandError.invalid("\(id): field \(k): \(problem)") }
            fields[k] = v
        }
        if let b = p.string("band") ?? spec.band { fields["band"] = .string(b) }
        if let pos = p.numbers("position") {
            guard pos.count == 2 else { throw CommandError.invalid("\(id): position is [x, y]") }
            fields["position"] = .array(pos.map { .number($0) })
        }
        var warnings: [JSONValue] = []
        // Images: the paths must exist (a missing photo is drawn as a placeholder panel).
        for f in spec.fields where f.type == "images" || f.type == "image" {
            let paths = f.type == "image" ? [fields[f.name]?.stringValue ?? ""] : (fields[f.name]?.arrayValue ?? []).compactMap(\.stringValue)
            for path in paths where !path.isEmpty && !FileManager.default.fileExists(atPath: EngineConfig.expand(path)) {
                warnings.append(.string("\(f.name): no file at \(path) (drawn as a placeholder)"))
            }
        }
        let defaultDuration = MediaTime(seconds: spec.duration)
        let span = try Graphics.range(p, project, defaultDuration: defaultDuration, what: "the template")
        let (start, end) = (span.start, span.end)
        if p.bool("sync") == true {
            guard let list = spec.syncField else { throw CommandError.invalid("\(id): \(name) has nothing to sync to the transcript") }
            let (times, missed) = syncTimes(fields[list]?.arrayValue?.compactMap(\.stringValue) ?? [], project: project, from: start, to: end)
            fields["times"] = .array(times.map { .number(($0 * 1000).rounded() / 1000) })
            for m in missed { warnings.append(.string("sync: \"\(m)\" not found in the transcript inside the clip window (timed evenly)")) }
        }
        // Real edit data (receipt, cut-visualizer, sfx-callout, logo-tile…) for the fields the caller did not set.
        if let resolve = MotionData.resolvers[name] { try resolve(&fields, Set(given.keys), start, end, &ctx); project = try ctx.requireProject() }
        var layering = spec.layering
        if let b = p.bool("behind") { layering = b ? (spec.layering == .split ? .split : .behind) : (spec.layering == .behind ? .front : spec.layering) }
        var layer = MotionLayer(template: name, fields: fields, style: MotionStyle.from(project.brand), layering: layering)
        if spec.consumesBelow { layer.consumesBelow = true }
        let t = try Graphics.track("overlays", in: &project, start: start, end: end, preferred: p.string("trackId"))
        var clip = Clip(id: project.makeID("c"), assetID: "", sourceIn: .zero, sourceOut: end - start, start: start)
        clip.motion = layer
        // Off the speaker's face (#16): the first free place it allows, unless a place was given.
        let explicit = p.has("position") || p.has("band") || given["position"] != nil || given["band"] != nil
        let placed = MotionPlacement.choose(spec, clip: clip, track: t, in: project, explicit: explicit, renderer: ctx.services.renderer)
        clip.motion?.fields = placed.fields
        fields = placed.fields
        warnings += placed.warnings.map { .string($0) }
        if layering != .front {
            var probe = clip
            probe.behindSubject = true
            warnings += Matte.warnings(probe, project)
        }
        project.tracks[t].clips.append(clip)
        project.tracks[t].sortClips()
        ctx.project = project
        if let w = span.warning { warnings.append(.string(w)) }
        return ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id), "template": .string(name),
                "fields": .object(fields), "place": placed.place.map { .string($0) } ?? .null,
                "faceCheck": placed.faceCheck.map { .string($0) } ?? .null, "warnings": .array(warnings),
                "timing": span.note.map { .string($0) } ?? .null]
    }

    /// A type problem with a field value, nil when it fits.
    static func check(_ v: JSONValue, _ f: EffectsCatalog.Field) -> String? {
        switch f.type {
        case "number", "time": return v.doubleValue == nil ? "expected a number" : nil
        case "boolean": return v.boolValue == nil ? "expected true or false" : nil
        case "text", "color", "image", "symbol": return v.stringValue == nil ? "expected a string" : nil
        case "choice":
            guard let s = v.stringValue else { return "expected a string" }
            return f.choices.map { $0.contains(s) ? nil : "one of \($0.joined(separator: ", "))" } ?? nil
        case "list", "images": return v.arrayValue?.allSatisfy({ $0.stringValue != nil }) == true ? nil : "expected a list of strings"
        case "numbers": return v.arrayValue?.allSatisfy({ $0.doubleValue != nil }) == true ? nil : "expected a list of numbers"
        default: return nil
        }
    }

    /// Clip-relative seconds when each entry's first word is spoken inside [from, to) (evenly spaced when not found).
    static func syncTimes(_ entries: [String], project: Project, from: MediaTime, to: MediaTime) -> ([Double], [String]) {
        let words = TimelineTranscript.defaultTrack(in: project).map { TimelineTranscript.words(of: $0, in: project) } ?? []
        let inside = words.filter { $0.start >= from && $0.start < to }
        func norm(_ s: String) -> String { TextNorm.stripAccents(s.lowercased()).filter { $0.isLetter || $0.isNumber } }
        var times: [Double] = [], missed: [String] = []
        var cursor = 0
        let span = (to - from).seconds
        for (i, e) in entries.enumerated() {
            let key = e.split(separator: " ").map { norm(String($0)) }.first { $0.count >= 3 } ?? norm(e)
            if let k = inside.indices.first(where: { $0 >= cursor && !key.isEmpty && norm(inside[$0].text).hasPrefix(key) }) {
                times.append((inside[k].start - from).seconds)
                cursor = k + 1
            } else {
                times.append(span * (0.15 + 0.7 * Double(i) / Double(max(entries.count, 1))))
                missed.append(e)
            }
        }
        return (times, missed)
    }
}

/// Test footage without a camera (issue #22): a synthetic talking head with its exact person matte attached, so the
/// motion-gallery scenario checks behind/in-front layering anywhere (no Vision, no test take).
enum MediaSynthesize: Command {
    static let id = "media.synthesize"
    static let summary = "Test helper: write a synthetic talking head (1080×1920 30 fps H.264: a wall, a speaker silhouette that sways and nods) with its exact person matte, import it and attach the matte (as matte.track would), so behind-the-speaker graphics can be tested without footage or Vision; optionally its exact face track (as faces.track would) and spoken words (as transcript.run would). Returns the asset."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("path", .string, "Output .mov."),
        .optional("duration", .time, "Seconds (default 8, at most 240)."),
        .optional("faces", .boolean, "Also attach the face track of the drawn head."),
        .optional("words", .array(.object), "Also attach a transcript: [{text, start, end}] (seconds of the take)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        guard let synth = ctx.services.screenSynth else { throw CommandError(.io, "\(id): this host cannot draw (no RegistaEngines)") }
        let url = URL(fileURLWithPath: EngineConfig.expand(p.requiredString("path"))).standardizedFileURL
        let seconds = min(max(p.time("duration")?.seconds ?? 8, 1), 240)
        let frames = Int((seconds * 30).rounded())
        let matte = url.deletingPathExtension().appendingPathExtension("matte")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try synth.writeTalkingHead(SyntheticTalkingHead(frames: frames, output: url, matteDirectory: matte))
        let imported = try Nested.run(MediaImport.self, ["path": .string(url.path)], &ctx)
        var project = try ctx.requireProject()
        guard let aid = imported.value(at: "asset.id")?.stringValue, let i = project.assets.firstIndex(where: { $0.id == aid }) else {
            throw CommandError(.io, "\(id): import failed")
        }
        var analysis = project.assets[i].analysis ?? AssetAnalysis()
        analysis.matte = MatteTrack(directory: matte.path, width: 270, height: 480, frameRate: 30, ranges: [[0, frames - 1]], engine: "synthetic")
        if p.bool("faces") == true {
            let track = FaceTrack(video: url.path, engine: "synthetic", width: 1080, height: 1920, fps: 30, minCutoff: 0, beta: 0, cuts: [],
                                  frames: (0..<frames).map { k in
                                      let box = SyntheticTalkingHead.face(t: Double(k) / 30, W: 1080, H: 1920)
                                      return FaceTrack.Frame(t: Double(k) / 30, raw: box, smooth: box)
                                  })
            let file = url.deletingPathExtension().appendingPathExtension("faces.json")
            do { try JSONEncoder().encode(track).write(to: file, options: .atomic) }
            catch { throw CommandError(.io, "\(id): cannot write \(file.path)") }
            analysis.faces = FaceTrackSummary(path: file.path, frames: frames, detected: frames, cuts: 0, jitterPx: 0, rawJitterPx: 0)
        }
        if let list = p.json("words")?.arrayValue {
            let words = try list.map { w -> Word in
                guard let text = w["text"]?.stringValue, let s = w["start"]?.doubleValue, let e = w["end"]?.doubleValue, e > s, s >= 0 else {
                    throw CommandError.invalid("\(id): each word is {text, start, end} with end > start ≥ 0")
                }
                return Word(text: text, start: MediaTime(seconds: s), end: MediaTime(seconds: e))
            }
            analysis.transcript = Transcript(engine: "synthetic", model: "synthetic", language: "en", words: words)
        }
        project.assets[i].analysis = analysis
        ctx.project = project
        return ["asset": ProjectState.summary(of: project.assets[i]), "frames": .number(Double(frames)), "matte": .string(matte.path)]
    }
}
