import Foundation

enum CaptionsCommon {
    /// The caption track named by `trackId`, else the first one holding captions, else the first caption track.
    static func trackIndex(_ p: CommandParams, _ project: Project, command: String) throws -> Int {
        if let tid = p.string("trackId") {
            let t = try Timeline.trackIndex(tid, in: project)
            guard project.tracks[t].kind == .caption else { throw CommandError.conflict("\(command): \(tid) is not a caption track") }
            return t
        }
        if let t = project.tracks.firstIndex(where: { $0.kind == .caption && $0.captions != nil }) { return t }
        guard let t = project.tracks.firstIndex(where: { $0.kind == .caption }) else {
            throw CommandError.conflict("\(command): no caption track — run captions.generate")
        }
        return t
    }

    static func require(_ track: Track, command: String) throws -> Captions {
        guard let c = track.captions else { throw CommandError.conflict("\(command): track \(track.name) has no captions — run captions.generate") }
        return c
    }

    /// Moves chunks off the faces of the picture (when it has a face track): see `CaptionPlacement`.
    @discardableResult
    static func place(_ captions: inout Captions, _ project: Project, renderer: VideoRenderer?) -> CaptionPlacement.Report? {
        for i in captions.chunks.indices { captions.chunks[i].bandY = nil; captions.chunks[i].offsetX = nil }
        guard captions.avoidFaces != false, !captions.chunks.isEmpty else { return nil }
        var job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project))
        job.captions = captions
        var faces = OutputFaces(job: job)
        guard faces.available else { return nil }
        let toRef = captions.style.referenceWidth / Double(job.width)
        let style = captions.style
        let base = captions
        func ink(_ chunks: [CaptionChunk]) -> [[[Double]]] {
            if let renderer {
                var j = job, c = base
                c.chunks = chunks
                j.captions = c
                if let layout = try? renderer.captionLayout(j), layout.count == chunks.count {
                    let top = j.captionBandTop
                    return layout.map { boxes in boxes.map { [$0[0] * toRef, ($0[1] - top) * toRef, $0[2] * toRef, $0[3] * toRef] } }
                }
            }
            return CaptionPlacement.estimatedInk(chunks, style: style)
        }
        let frame = MediaTime.frameDuration(at: job.frameRate)
        let profile = LanguageProfile.named(captions.style.language ?? project.tracks.first { $0.id == captions.sourceTrack }.flatMap { language(of: $0, in: project) })
        return CaptionPlacement.place(&captions, ink: ink, frame: frame, isStop: profile.isStopWord) { t in
            faces.boxes(at: t).map { FaceFraming.captionZone($0).map { $0 * toRef } }
        }
    }

    static func placementJSON(_ r: CaptionPlacement.Report?) -> JSONValue {
        guard let r else { return ["faces": false] }
        return ["faces": true, "moved": .number(Double(r.moved)), "shifted": .number(Double(r.shifted)), "split": .number(Double(r.split)),
                "overlapping": .array(r.overlapping.map { .number(Double($0)) })]
    }

    /// Rebuilds the chunks from the source track's timeline words.
    static func rebuild(_ captions: inout Captions, _ project: Project, command: String) throws {
        guard let source = project.tracks.first(where: { $0.id == captions.sourceTrack }) else {
            throw CommandError.notFound("\(command): source track \(captions.sourceTrack) is gone")
        }
        let words = TimelineTranscript.words(of: source, in: project)
        guard !words.isEmpty else { throw CommandError.conflict("\(command): no transcribed words on track \(source.name) — run transcript.run") }
        // A pause in the source (kept or cut out by the edit) ends a sentence: chunks never run across it.
        let pause = sentencePause(words.map(\.text))
        var pauses = Set<Int>()
        for k in words.indices.dropLast() where (words[k + 1].sourceStart - words[k].sourceEnd).seconds >= pause {
            pauses.insert(k)
        }
        let placed = placedChunks(captions)
        captions.chunks = CaptionBuilder.build(words: words.map { ($0.text, $0.start, $0.end) }, style: captions.style,
                                               keywords: captions.keywords, fixes: captions.fixes,
                                               language: language(of: source, in: project), pauses: pauses)
        captions.sourceSignature = Captions.signature(of: source)
        carryPlaces(placed, into: &captions)
    }

    static func placedChunks(_ c: Captions) -> [(start: MediaTime, place: CaptionPlace)] {
        c.chunks.compactMap { ch in ch.place.map { (start: ch.words.first?.start ?? ch.end, place: $0) } }
    }

    /// Chunks placed by hand keep their placement across a rebuild: it goes to the new chunk starting at the same time,
    /// else to the one showing at that time.
    static func carryPlaces(_ placed: [(start: MediaTime, place: CaptionPlace)], into captions: inout Captions) {
        for p in placed {
            let i = captions.chunks.firstIndex { $0.words.first?.start == p.start } ?? captions.chunk(at: p.start)
            if let i, captions.chunks[i].place == nil { captions.chunks[i].place = p.place }
        }
    }

    /// Source pause that ends a caption sentence, seconds: 0.6 s when the transcript has (almost) no
    /// punctuation, else 1 s — take joins and long silences, where the transcriber put no full stop
    /// because the next take starts a new sentence ("…RÉPÉTITIVES | DES OUTILS…", "ET SI | VOUS ÊTES…").
    static func sentencePause(_ words: [String]) -> Double {
        let marks = words.filter { $0.last.map { ".?!…".contains($0) } ?? false }.count
        return words.count >= 12 && marks * 30 < words.count ? 0.6 : 1.0
    }

    /// The spoken language of a track: its first transcribed clip's transcript language.
    static func language(of track: Track, in project: Project) -> String? {
        for c in track.clips {
            if let a = project.asset(c.assetID), let t = TimelineTranscript.transcript(of: a, in: project) { return t.language }
        }
        return nil
    }

    static func summary(_ c: Captions, trackID: String, project: Project) -> JSONValue {
        let source = project.tracks.first { $0.id == c.sourceTrack }
        let stale = source.map { Captions.signature(of: $0) != c.sourceSignature } ?? true
        let language = c.style.language ?? source.flatMap { self.language(of: $0, in: project) } ?? "it"
        return ["trackId": .string(trackID), "style": .string(c.style.id), "chunks": .number(Double(c.chunks.count)),
                "language": .string(LanguageProfile.named(language).code),
                "stopWordEnds": .array(CaptionBuilder.stopWordEnds(c, language: language).map { .string($0) }),
                "words": .number(Double(c.chunks.map(\.words.count).reduce(0, +))),
                "keywordsShown": .number(Double(c.chunks.flatMap(\.words).filter(\.keyword).count)),
                "sourceTrack": .string(c.sourceTrack), "stale": .bool(stale),
                "trackPlace": Placing.placeJSON(c.place), "placedChunks": .number(Double(c.chunks.filter { $0.place != nil }.count))]
    }

    static func chunkJSON(_ ch: CaptionChunk) -> JSONValue {
        ["text": .string(ch.text), "start": ProjectState.seconds(ch.words.first?.start ?? .zero), "end": ProjectState.seconds(ch.end),
         "bandY": ch.bandY.map { .number($0) } ?? .null, "offsetX": ch.offsetX.map { .number($0) } ?? .null,
         "place": Placing.placeJSON(ch.place),
         "words": .array(ch.words.map { w in
             ["text": .string(w.text), "start": ProjectState.seconds(w.start), "end": ProjectState.seconds(w.end), "keyword": .bool(w.keyword)]
         })]
    }

    /// keywords.json: {"keywords": [...], "fixes": {...}}.
    static func readKeywordsFile(_ path: String, command: String) throws -> (keywords: [String], fixes: [String: String]) {
        let url = URL(fileURLWithPath: EngineConfig.expand(path))
        guard let data = FileManager.default.contents(atPath: url.path) else { throw CommandError.notFound("\(command): no file at \(url.path)") }
        let json = try JSONValue.parse(data)
        let fixes = (json["fixes"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        return (json["keywords"]?.arrayValue?.compactMap(\.stringValue) ?? [], fixes)
    }
}

enum CaptionsGenerate: Command {
    static let id = "captions.generate"
    static let summary = "Add the burned-in captions: word-by-word chunks built from the transcript of the edited timeline, on a caption track (created if missing), in a style preset (talking-head-v1 = the approved look), with your keywords on a pink box (default: the script's keywords from script.prepare) and fixes for misheard words. Run it after the picture edit is final (re-run after any cut: captions go stale). Re-running keeps the track's keywords, fixes and style unless new ones are given. Returns chunk/word counts, how many keywords are shown and a preview of the first chunks."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Caption track (default: the first one, created if missing)."),
        .optional("sourceTrackId", .string, "Track whose words are captioned (default: the first video track with clips)."),
        .optional("keywords", .array(.string), "Keywords (display form, e.g. uppercase)."),
        .optional("keywordsPath", .string, "keywords.json with {\"keywords\": [...], \"fixes\": {...}}."),
        .optional("fixes", .object, "Replacements of displayed words, {\"AL\": \"ALL'IA\", \"IA\": \"\"} (empty removes the word)."),
        .optional("style", .oneOf(CaptionStyle.all.map(\.id)), "Style preset (default talking-head-v1; elegant-serif, bold-keyword, ghost-karaoke: effects.catalog category captions)."),
        .optional("avoidFaces", .boolean, "Move chunks off every face of the picture (needs faces.track; default true): another band inside the Instagram safe zones, shifted aside, or split shorter."),
        .optional("dryRun", .boolean, "Change nothing: return the chunks it would build and suggestedKeywords (the keywords it would use, then numbers, names and the longest word of each sentence, never stop words) for a person to accept or edit before generating."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var work = ctx
        var log: [JSONValue] = []
        var project = try work.requireProject()
        var t: Int
        if p.has("trackId") { t = try CaptionsCommon.trackIndex(p, project, command: id) }
        else if let existing = project.tracks.firstIndex(where: { $0.kind == .caption }) { t = existing }
        else {
            try work.perform(TrackAdd.self, ["kind": "caption"], log: &log)
            project = work.project!
            t = project.tracks.count - 1
        }
        let old = project.tracks[t].captions
        let source: Track
        if let sid = p.string("sourceTrackId") { source = project.tracks[try Timeline.trackIndex(sid, in: project, editable: false)] }
        else if let sid = old?.sourceTrack, let s = project.tracks.first(where: { $0.id == sid }) { source = s }
        else {
            guard let s = TimelineTranscript.defaultTrack(in: project) else { throw CommandError.conflict("\(id): no track with clips to caption") }
            source = s
        }
        var keywords = old?.keywords ?? [], fixes = old?.fixes ?? [:]
        if let path = p.string("keywordsPath") { (keywords, fixes) = try CaptionsCommon.readKeywordsFile(path, command: id) }
        if let k = p.strings("keywords") { keywords = k }
        if let f = p.json("fixes")?.objectValue { fixes = f.compactMapValues(\.stringValue) }
        let style = p.string("style").flatMap { CaptionStyle.presets[$0] } ?? old?.style ?? .talkingHeadV1
        // First run without keywords: the ones flagged in the teleprompter script (script.prepare), in caption form.
        if old == nil, !p.has("keywords"), !p.has("keywordsPath"), let k = project.script?.keywords, !k.isEmpty {
            keywords = k.flatMap { kw -> [String] in
                let ws = kw.split(separator: " ").enumerated().map { i, w in
                    (text: String(w), start: MediaTime(seconds: Double(i) * 0.1), end: MediaTime(seconds: Double(i) * 0.1 + 0.1))
                }
                return CaptionBuilder.build(words: ws, style: style, keywords: [], fixes: fixes).flatMap { $0.words.map(\.text) }
            }
        }
        var captions = Captions(style: style, keywords: keywords, fixes: fixes, sourceTrack: source.id, sourceSignature: "", chunks: [])
        captions.avoidFaces = p.bool("avoidFaces") ?? old?.avoidFaces
        captions.place = old?.place
        try CaptionsCommon.rebuild(&captions, project, command: id)
        if p.bool("dryRun") == true {
            var r = CaptionsCommon.summary(captions, trackID: project.tracks[t].id, project: project).objectValue!
            r["preview"] = .array(captions.chunks.prefix(12).map { .string($0.text) })
            r["suggestedKeywords"] = .array(suggestions(captions, source: source, project: project).map { .string($0) })
            r["dryRun"] = true
            return .object(r)
        }
        if let old { CaptionsCommon.carryPlaces(CaptionsCommon.placedChunks(old), into: &captions) }
        let placement = CaptionsCommon.place(&captions, project, renderer: ctx.services.renderer)
        project.tracks[t].captions = captions
        work.project = project
        ctx = work
        var r = CaptionsCommon.summary(captions, trackID: project.tracks[t].id, project: project).objectValue!
        r["commands"] = .array(log)
        r["placement"] = CaptionsCommon.placementJSON(placement)
        r["preview"] = .array(captions.chunks.prefix(12).map { .string($0.text) })
        return .object(r)
    }

    /// The keywords to propose: those the captions would use, then one or two per spoken sentence, in display form.
    static func suggestions(_ c: Captions, source: Track, project: Project) -> [String] {
        let raw = TimelineTranscript.words(of: source, in: project).map(\.text)
        let shown = Dictionary(c.chunks.flatMap(\.words).map { ($0.text.uppercased(), $0.text) }, uniquingKeysWith: { a, _ in a })
        let marks = CaptionBuilder.punctuation
        func display(_ w: String) -> String {
            var d = String(w.drop { marks.contains($0) }.reversed().drop { marks.contains($0) }.reversed()).replacingOccurrences(of: "’", with: "'")
            if c.style.uppercase { d = d.uppercased() }
            d = c.fixes[d] ?? d
            return shown[d.uppercased()] ?? ""   // only words the captions really show
        }
        return KeywordSuggest.suggest(sentences: KeywordSuggest.sentences(raw), language: CaptionsCommon.language(of: source, in: project),
                                      display: display, first: c.keywords)
    }
}

enum CaptionsGet: Command {
    static let id = "captions.get"
    static let summary = "Proof-read the captions: every chunk with its words, timeline times and keyword flags, the keywords, fixes and style, and whether they are stale (the timeline changed since captions.generate). Returns that list."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Caption track (default: the first one with captions)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let t = try CaptionsCommon.trackIndex(p, project, command: id)
        let c = try CaptionsCommon.require(project.tracks[t], command: id)
        var r = CaptionsCommon.summary(c, trackID: project.tracks[t].id, project: project).objectValue!
        r["keywords"] = .array(c.keywords.map { .string($0) })
        r["fixes"] = .object(c.fixes.mapValues { .string($0) })
        r["styleDetail"] = try JSONValue.from(c.style)
        r["list"] = .array(c.chunks.map(CaptionsCommon.chunkJSON))
        return .object(r)
    }
}

enum CaptionsSetKeywords: Command {
    static let id = "captions.setKeywords"
    static let summary = "Change which words get the keyword box (display form, uppercase as shown): replace the list, add or remove words, or load a keywords.json (keywords and fixes; new fixes rebuild the chunks). Returns the caption summary."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Caption track (default: the first one with captions)."),
        .optional("keywords", .array(.string), "Replace the keyword list."),
        .optional("add", .array(.string), "Add keywords."),
        .optional("remove", .array(.string), "Remove keywords."),
        .optional("path", .string, "keywords.json to load."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let t = try CaptionsCommon.trackIndex(p, project, command: id)
        var c = try CaptionsCommon.require(project.tracks[t], command: id)
        if let path = p.string("path") {
            let (k, f) = try CaptionsCommon.readKeywordsFile(path, command: id)
            c.keywords = k
            if f != c.fixes { c.fixes = f; try CaptionsCommon.rebuild(&c, project, command: id) }
        }
        if let k = p.strings("keywords") { c.keywords = k }
        if let a = p.strings("add") { c.keywords += a.filter { w in !c.keywords.contains { $0.uppercased() == w.uppercased() } } }
        if let r = p.strings("remove") { let gone = Set(r.map { $0.uppercased() }); c.keywords.removeAll { gone.contains($0.uppercased()) } }
        let keys = Set(c.keywords.map { $0.uppercased() })
        for i in c.chunks.indices { for k in c.chunks[i].words.indices { c.chunks[i].words[k].keyword = keys.contains(c.chunks[i].words[k].text.uppercased()) } }
        if c.chunks.contains(where: { $0.bandY != nil || $0.offsetX != nil }) || c.avoidFaces != false {
            // Keyword boxes change the line's width: place again (splits from the last placement are rebuilt first).
            if c.chunks.contains(where: { $0.bandY != nil || $0.offsetX != nil }) { try CaptionsCommon.rebuild(&c, project, command: id) }
            CaptionsCommon.place(&c, project, renderer: ctx.services.renderer)
        }
        project.tracks[t].captions = c
        ctx.project = project
        var r = CaptionsCommon.summary(c, trackID: project.tracks[t].id, project: project).objectValue!
        r["keywords"] = .array(c.keywords.map { .string($0) })
        return .object(r)
    }
}

enum CaptionsSetStyle: Command {
    static let id = "captions.setStyle"
    static let summary = "Apply a caption style preset (talking-head-v1 = the approved WeSites look; elegant-serif = cream serif italic, one calm phrase at a time; bold-keyword = bold white sans on up to two lines, keyword in the brand accent; ghost-karaoke = whole phrase shown, upcoming words ghosted, lit word by word — effects.catalog category captions says when to use each) and/or override fields: font, fontSize, strokeWidth, colors, gap, bandY, bandHeight, maxWords, maxChars, hold, reveal (word|chunk), keywordMode (box|color), upcomingOpacity, shadowOpacity/shadowBlur/shadowY, maxLineWidth, lineSpacing, wordAlign (center|baseline); null clears an optional field. Chunking fields rebuild the chunks. Only change the approved style when asked. Returns the caption summary."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Caption track (default: the first one with captions)."),
        .optional("style", .oneOf(CaptionStyle.all.map(\.id)), "Preset to start from (default: the current style)."),
        .optional("overrides", .object, "Style fields to change, e.g. {\"bandY\": 1200, \"keywordBoxColor\": \"#FFD400\"}."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let t = try CaptionsCommon.trackIndex(p, project, command: id)
        var c = try CaptionsCommon.require(project.tracks[t], command: id)
        var style = p.string("style").flatMap { CaptionStyle.presets[$0] } ?? c.style
        if let o = p.json("overrides")?.objectValue {
            guard case .object(var current) = try JSONValue.from(style) else { throw CommandError.invalid("\(id): bad style") }
            for (k, v) in o {
                // Optional fields (shadow, wrapping, ghosted words…) are absent while nil; null clears them.
                if let optional = CaptionStyle.optionalFields[k], v == .null || current[k] == nil {
                    guard v == .null || v.typeName == optional else { throw CommandError.invalid("\(id): \(k) must be a \(optional)") }
                    current[k] = v == .null ? nil : v
                    continue
                }
                guard let existing = current[k] else {
                    let fields = Set(current.keys).union(CaptionStyle.optionalFields.keys).sorted()
                    throw CommandError.invalid("\(id): unknown style field '\(k)' (fields: \(fields.joined(separator: ", ")))")
                }
                guard existing.typeName == v.typeName else { throw CommandError.invalid("\(id): \(k) must be a \(existing.typeName)") }
                current[k] = v
            }
            if o["id"] == nil, !o.isEmpty, !style.id.hasSuffix("+custom") { current["id"] = .string(style.id + "+custom") }
            do { style = try JSONDecoder().decode(CaptionStyle.self, from: JSONValue.object(current).data()) }
            catch { throw CommandError.invalid("\(id): invalid overrides: \(error)") }
        }
        let rechunk = style.maxWords != c.style.maxWords || style.maxChars != c.style.maxChars || style.hold != c.style.hold
            || style.stopWords != c.style.stopWords || style.uppercase != c.style.uppercase
        c.style = style
        if rechunk || c.chunks.contains(where: { $0.bandY != nil || $0.offsetX != nil }) { try CaptionsCommon.rebuild(&c, project, command: id) }
        let keys = Set(c.keywords.map { $0.uppercased() })
        for i in c.chunks.indices { for k in c.chunks[i].words.indices { c.chunks[i].words[k].keyword = keys.contains(c.chunks[i].words[k].text.uppercased()) } }
        let placement = CaptionsCommon.place(&c, project, renderer: ctx.services.renderer)
        project.tracks[t].captions = c
        ctx.project = project
        var r = CaptionsCommon.summary(c, trackID: project.tracks[t].id, project: project).objectValue!
        r["rechunked"] = .bool(rechunk)
        r["placement"] = CaptionsCommon.placementJSON(placement)
        return .object(r)
    }
}

enum ExportSRT: Command {
    static let id = "export.srt"
    static let summary = "Write the captions as a SubRip .srt file (one cue per chunk, timeline times) for the platform's own subtitles. Returns the path and cue count."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("path", .string, "Output .srt path."),
        .optional("trackId", .string, "Caption track (default: the first one with captions)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let t = try CaptionsCommon.trackIndex(p, project, command: id)
        let c = try CaptionsCommon.require(project.tracks[t], command: id)
        let url = URL(fileURLWithPath: EngineConfig.expand(p.requiredString("path")))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CaptionBuilder.srt(c).write(to: url, atomically: true, encoding: .utf8)
        } catch { throw CommandError(.io, "\(id): cannot write \(url.path): \(error.localizedDescription)") }
        return ["path": .string(url.path), "cues": .number(Double(c.chunks.count))]
    }
}
