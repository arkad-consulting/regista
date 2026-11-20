import Foundation

enum ScriptSet: Command {
    static let id = "script.set"
    static let summary = "Give Regista the script the speaker reads, one line per take: pass the text, or a file path (a script.md: the numbered lines of its \"## Testo\" section are used). The same text drives the teleprompter (markup from script.prepare — continuation lines, \" / \" breath marks, *keywords* — is understood). Needed by takes.list. Clears computed takes. Returns the lines and keywords."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("text", .string, "Script text: numbered lines (\"1. …\") or one sentence per line."),
        .optional("path", .string, "Read the script from this file instead."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        var text = p.string("text")
        if let path = p.string("path") {
            let url = URL(fileURLWithPath: EngineConfig.expand(path))
            guard let data = FileManager.default.contents(atPath: url.path) else { throw CommandError.notFound("\(id): no file at \(url.path)") }
            text = String(decoding: data, as: UTF8.self)
        }
        guard let text else { throw CommandError.invalid("\(id): pass text or path") }
        var script = Script.parse(text)
        guard !script.lines.isEmpty else { throw CommandError.invalid("\(id): no script lines found") }
        let keywords = PromptScript(text).keywords
        script.prompt = text
        script.keywords = keywords.isEmpty ? nil : keywords
        project.script = script
        project.takes = nil
        ctx.project = project
        return ["lines": .array(script.lines.map { .string($0) }), "count": .number(Double(script.lines.count)),
                "keywords": .array(keywords.map { .string($0) })]
    }
}

enum ScriptFromTranscriptCommand: Command {
    static let id = "script.fromTranscript"
    static let summary = "No script file? Build the script from the transcript: one line per sentence (punctuation, or pauses when the transcript has none), repeated readings of the same sentence (restarts, second takes, false starts) folded into one line so takes.list finds them as takes of it. Each line reports its readings and its level against the take's speech (relativeDB far below 0 = an off-mic voice: another speaker, or chatter between takes). Call it with dryRun: true, read the lines, then again with drop: [line numbers] to leave out chatter that is not part of the video. Sets the script (like script.set) and clears computed takes; then takes.list and edit.autoCut work as with a script. Returns the lines."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("assetId", .string, "Transcribed asset (default: the only one with a transcript)."),
        .optional("pause", .number, "Silence that ends a sentence, seconds (default 0.6 without punctuation, 1.0 with)."),
        .optional("drop", .array(.integer), "Line numbers (1-based, as listed by a dry run) to leave out of the script."),
        .optional("dryRun", .boolean, "Only list the lines, change nothing."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let asset: MediaAsset
        if let assetID = p.string("assetId") {
            asset = project.assets[try Analysis.assetIndex(assetID, in: project, command: id)]
        } else {
            let usable = project.assets.filter { $0.analysis?.transcript != nil }
            guard usable.count == 1 else {
                throw CommandError.invalid("\(id): \(usable.isEmpty ? "no transcribed asset — run transcript.run" : "several transcribed assets — pass assetId")")
            }
            asset = usable[0]
        }
        let transcript = try Analysis.transcript(of: asset, command: id)
        let lines = ScriptFromTranscript.lines(transcript.words, language: transcript.language, pause: p.number("pause"))
        guard !lines.isEmpty else { throw CommandError.conflict("\(id): no sentences in the transcript of \(asset.id)") }
        let envelope = try asset.analysis?.audio.map { try Envelope.read(URL(fileURLWithPath: $0.speech)) }
        let levels = envelope.map { ScriptFromTranscript.relativeLevels(lines, envelope: $0) }
        let drop = Set((p.numbers("drop") ?? []).map { Int($0) })
        if let bad = drop.first(where: { !(1...lines.count).contains($0) }) {
            throw CommandError.invalid("\(id): drop \(bad) is not a line (1…\(lines.count))")
        }
        let kept = lines.enumerated().filter { !drop.contains($0.offset + 1) }.map(\.element)
        guard !kept.isEmpty else { throw CommandError.invalid("\(id): every line dropped") }
        let dryRun = p.bool("dryRun") ?? false
        let text = kept.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        if !dryRun {
            var script = Script(lines: kept.map(\.text))
            script.prompt = text
            project.script = script
            project.takes = nil
            ctx.project = project
        }
        func r2(_ x: Double) -> JSONValue { .number((x * 100).rounded() / 100) }
        return ["assetId": .string(asset.id), "language": .string(transcript.language), "count": .number(Double(kept.count)),
                "dropped": .array(drop.sorted().map { .number(Double($0)) }), "set": .bool(!dryRun), "text": .string(text),
                "lines": .array(lines.enumerated().map { i, l -> JSONValue in
                    var o: [String: JSONValue] = [
                        "line": .number(Double(i + 1)), "text": .string(l.text), "dropped": .bool(drop.contains(i + 1)),
                        "readings": .array(l.readings.map { ["start": r2($0.start), "end": r2($0.end), "text": .string($0.text)] }),
                    ]
                    if let levels { o["relativeDB"] = .number(levels[i]) }
                    return .object(o)
                })]
    }
}

enum Takes {
    static func summary(_ set: TakeSet) -> JSONValue {
        let lines = set.lines.enumerated().map { li, line -> JSONValue in
            let takes = line.takes.enumerated().map { k, t -> JSONValue in
                [
                    "take": .number(Double(k + 1)), "label": .string("\(k + 1)/\(line.takes.count)"),
                    "start": ProjectState.seconds(t.start), "end": ProjectState.seconds(t.end), "text": .string(t.text),
                    "coverage": .number(t.coverage), "wer": .number(t.wer), "complete": .bool(t.complete),
                    "longPauses": .array(t.longPauses.map { .array($0.map { .number($0) }) }),
                    "parts": .array(t.parts.map { ["in": ProjectState.seconds($0.start), "out": ProjectState.seconds($0.end), "note": .string($0.note)] }),
                ]
            }
            return [
                "line": .number(Double(li + 1)), "text": .string(line.text), "takes": .array(takes),
                "auto": line.auto.map { .number(Double($0 + 1)) } ?? .null,
                "chosen": line.chosen.map { .number(Double($0 + 1)) } ?? .null,
                "chosenLabel": line.chosen.map { .string("\($0 + 1)/\(line.takes.count)") } ?? .null,
            ]
        }
        let read = set.lines.filter { $0.chosen != nil }.count
        return ["assetId": .string(set.assetID), "source": .string(set.source ?? "transcript"), "lines": .array(lines), "read": .number(Double(read)),
                "missing": .array(set.lines.indices.filter { set.lines[$0].chosen == nil }.map { .number(Double($0 + 1)) })]
    }

    static func require(_ project: Project, command: String) throws -> TakeSet {
        guard let t = project.takes else { throw CommandError.conflict("\(command): no takes — run takes.list first") }
        return t
    }
}

enum TakesList: Command {
    static let id = "takes.list"
    static let summary = "Find every reading of every script line (the speaker repeats a line until it comes out right), pick the best per line (complete, no restart; the last complete one by default) and compute its cut points on the speech envelope. A teleprompter recording's live take markers are used first (the restarts were seen live); otherwise the transcript is aligned to the script. Show this list to the user as text. Returns the source (live / transcript) and per line: the takes (text, start/end, complete or not, word error rate) and the chosen one; then use takes.select to override and edit.autoCut to build."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("assetId", .string, "Transcribed asset (default: the only one with a transcript or live take markers)."),
        .optional("source", .oneOf(["auto", "live", "transcript"]), "auto (default): live markers when the asset has them for this script, else the transcript."),
        .optional("maxWer", .number, "Word error rate still counted as complete (default 0.3)."),
        .optional("maxPause", .number, "Pauses longer than this inside a take are cut out, seconds (default 0.7)."),
        .optional("keepPause", .number, "Silence kept on each side of a removed pause, seconds (default 0.12)."),
        .optional("pre", .number, "Lead-in before speech, seconds (default 0.10)."),
        .optional("post", .number, "Tail after speech, seconds (default 0.20)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        guard let script = project.script else { throw CommandError.conflict("\(id): no script — run script.set first") }
        let asset: MediaAsset
        if let assetID = p.string("assetId") {
            asset = project.assets[try Analysis.assetIndex(assetID, in: project, command: id)]
        } else {
            var usable = project.assets.filter { $0.analysis?.transcript != nil }
            if usable.isEmpty { usable = project.assets.filter { $0.analysis?.liveTakes != nil } }
            guard usable.count == 1 else {
                throw CommandError.invalid("\(id): \(usable.isEmpty ? "no transcribed asset — run transcript.run" : "several transcribed assets — pass assetId")")
            }
            asset = usable[0]
        }
        var options = TakeOptions()
        if let v = p.number("maxWer") { options.maxWer = v }
        if let v = p.number("maxPause") { options.maxPause = v }
        if let v = p.number("keepPause") { options.keepPause = v }
        if let v = p.number("pre") { options.pre = v }
        if let v = p.number("post") { options.post = v }
        project.takes = try compute(asset: asset, script: script, options: options, source: p.string("source") ?? "auto")
        ctx.project = project
        return Takes.summary(project.takes!)
    }

    /// Every reading of every line of `script` in `asset`, from its live take markers (`source` auto or live) or its
    /// transcript, with the cut points `options` give.
    static func compute(asset: MediaAsset, script: Script, options: TakeOptions, source: String) throws -> TakeSet {
        let live = asset.analysis?.liveTakes.flatMap { $0.matches(script) ? $0 : nil }
        if source == "live", live == nil {
            throw CommandError.conflict("\(id): \(asset.id) has no live take markers for this script\(asset.analysis?.liveTakes != nil ? " (they were logged against another script)" : "")")
        }
        let useLive = live != nil && source != "transcript"
        let transcript = useLive ? asset.analysis?.transcript : try Analysis.transcript(of: asset, command: id)
        // Cut points snap to speech onsets/offsets when the extracted audio is there.
        let envelope = try asset.analysis?.audio.map { try Envelope.read(URL(fileURLWithPath: $0.speech)) }
        if useLive, let live {
            return TakeFinder.fromMarkers(script: script, log: live, words: transcript?.words, envelope: envelope, assetID: asset.id, options: options)
        }
        return TakeFinder.find(script: script, words: transcript!.words, envelope: envelope, assetID: asset.id, options: options)
    }
}

enum TakesSelect: Command {
    static let id = "takes.select"
    static let summary = "Override the take edit.autoCut uses for a script line (1-based line and take, as in takes.list) when the automatic pick has a stumble, a cut-off ending or a weaker reading; auto: true restores the automatic pick. Then run edit.autoCut with replace: true. Returns the line's choice."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("line", .integer, "Script line, 1-based."),
        .optional("take", .integer, "Take number, 1-based."),
        .optional("auto", .boolean, "Restore the automatic pick."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        var set = try Takes.require(project, command: id)
        let line = p.int("line") ?? 0
        guard set.lines.indices.contains(line - 1) else { throw CommandError.invalid("\(id): line must be 1…\(set.lines.count)") }
        if p.bool("auto") == true {
            set.lines[line - 1].chosen = set.lines[line - 1].auto
        } else {
            guard let take = p.int("take") else { throw CommandError.invalid("\(id): pass take or auto") }
            let count = set.lines[line - 1].takes.count
            guard (1...max(count, 1)).contains(take), count > 0 else {
                throw CommandError.invalid("\(id): line \(line) has \(count) take\(count == 1 ? "" : "s")")
            }
            set.lines[line - 1].chosen = take - 1
        }
        project.takes = set
        ctx.project = project
        let l = set.lines[line - 1]
        return ["line": .number(Double(line)), "chosen": l.chosen.map { .number(Double($0 + 1)) } ?? .null,
                "auto": l.auto.map { .number(Double($0 + 1)) } ?? .null]
    }
}

enum EditAutoCut: Command {
    static let id = "edit.autoCut"
    static let summary = "Build the rough cut from the chosen takes: one clip per kept range (each chosen take, the pauses longer than maxPause inside it cut out; filler words stay: transcript.fillers lists them, transcript.deleteWords removes them) on a video track and the same ranges on an audio track, linked and frame-snapped so picture and sound cut together; 15 ms audio fades. replace: true rebuilds after takes.select. Expressed as ordinary track.add / timeline.delete / timeline.place commands, undone as one step. Returns the segments (line, take, source in/out, timeline start), track ids and duration."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("videoTrackId", .string, "Video track (default: the first one, created if missing)."),
        .optional("audioTrackId", .string, "Audio track (default: the first one, created if missing)."),
        .optional("replace", .boolean, "Remove the clips already on those tracks first (default false: fail if they are not empty)."),
        .optional("fades", .time, "Audio micro-fade at both edges of every sound clip, seconds (default 0.015; 0 = none)."),
        .optional("maxPause", .number, "Pauses longer than this inside a take are cut out, seconds: recomputes the takes' cut points (as takes.list maxPause), keeping the picks made with takes.select."),
        .optional("keepPause", .number, "Breath kept on each side of a removed pause, seconds: recomputes the cut points (as takes.list keepPause), keeping the picks."),
        .optional("picks", .array(.object), "Takes to use, applied first as takes.select would: [{line, take}] (1-based, as in takes.list), so a new pick and the cut it needs are one undo step."),
        .optional("dryRun", .boolean, "Only return the commands, change nothing."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        var set = try Takes.require(project, command: id)
        guard let asset = project.asset(set.assetID) else { throw CommandError.notFound("\(id): asset \(set.assetID) is gone") }
        var work = ctx
        var options = set.options
        if let v = p.number("maxPause") { options.maxPause = v }
        if let v = p.number("keepPause") { options.keepPause = v }
        if options != set.options {
            guard let script = project.script else { throw CommandError.conflict("\(id): no script — run script.set first") }
            set = try TakesList.compute(asset: asset, script: script, options: options, source: set.source == "live" ? "live" : "transcript")
            set.keepPicks(of: project.takes!)
            work.project?.takes = set
        }
        for pick in p.json("picks")?.arrayValue ?? [] {
            guard let line = pick["line"]?.doubleValue.map({ Int($0) }), set.lines.indices.contains(line - 1) else {
                throw CommandError.invalid("\(id): picks: line must be 1…\(set.lines.count)")
            }
            let count = set.lines[line - 1].takes.count
            guard let take = pick["take"]?.doubleValue.map({ Int($0) }), count > 0, (1...count).contains(take) else {
                throw CommandError.invalid("\(id): picks: line \(line) has \(count) take\(count == 1 ? "" : "s")")
            }
            set.lines[line - 1].chosen = take - 1
            work.project?.takes = set
        }
        let segments = set.segments()
        guard !segments.isEmpty else { throw CommandError.conflict("\(id): no take chosen for any line") }
        let replace = p.bool("replace") ?? false
        let dryRun = p.bool("dryRun") ?? false
        var log: [JSONValue] = []

        func track(_ param: String, _ kind: TrackKind) throws -> String {
            if let id = p.string(param) { _ = try Timeline.trackIndex(id, in: work.project!); return id }
            if let t = work.project!.tracks.first(where: { $0.kind == kind }) { return t.id }
            let r = try work.perform(TrackAdd.self, ["kind": .string(kind.rawValue)], log: &log)
            return r.value(at: "track.id")?.stringValue ?? ""
        }
        let v = try track("videoTrackId", .video)
        let a = try track("audioTrackId", .audio)
        let existing = [v, a].flatMap { id in work.project!.tracks.first { $0.id == id }!.clips.map(\.id) }
        if !existing.isEmpty {
            guard replace else { throw CommandError.conflict("\(id): tracks \(v)/\(a) already have clips — pass replace: true") }
            try work.perform(TimelineDelete.self, ["clipIds": .array(existing.map { .string($0) }), "linked": false], log: &log)
        }
        // Cut points on the source's frame grid, the same for picture and sound; clips butt end to end.
        let rate = asset.video?.frameRate ?? project.settings.frameRate
        var start = MediaTime.zero
        var placed: [JSONValue] = []
        for (line, range) in segments {
            let sIn = range.start.snapped(to: rate)
            let sOut = min(range.end.snapped(to: rate), asset.duration)
            guard sOut > sIn else { continue }
            // Picture and sound of a range are linked: they move, trim and delete together.
            let pv = try work.perform(TimelinePlace.self, ["assetId": .string(asset.id), "trackId": .string(v), "start": .number(start.seconds),
                                                           "sourceIn": .number(sIn.seconds), "sourceOut": .number(sOut.seconds)], log: &log)
            try work.perform(TimelinePlace.self, ["assetId": .string(asset.id), "trackId": .string(a), "start": .number(start.seconds),
                                                  "sourceIn": .number(sIn.seconds), "sourceOut": .number(sOut.seconds),
                                                  "linkTo": pv.value(at: "clip.id") ?? .null], log: &log)
            placed.append(["line": .number(Double(line)), "sourceIn": ProjectState.seconds(sIn), "sourceOut": ProjectState.seconds(sOut),
                           "start": ProjectState.seconds(start), "note": .string(range.note)])
            start += sOut - sIn
        }
        let fade = p.time("fades") ?? MediaTime(seconds: 0.015)
        if fade > .zero, !placed.isEmpty {
            try work.perform(ClipSet.self, ["trackId": .string(a), "fadeIn": .number(fade.seconds), "fadeOut": .number(fade.seconds)], log: &log)
        }
        if !dryRun { ctx = work }
        return ["commands": .array(log), "segments": .array(placed), "videoTrackId": .string(v), "audioTrackId": .string(a),
                "duration": ProjectState.seconds(start), "dryRun": .bool(dryRun)]
    }
}

enum TakesCompare: Command {
    static let id = "takes.compare"
    static let summary = "Test helper: compare the video track's cuts with a hand edit (a segments.json of source in/out per segment): for every script line, whether the same take was used and the in/out error in ms. Returns the per-line comparison."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("reference", .string, "Path of the reference segments.json."),
        .optional("trackId", .string, "Video track holding the cut (default: the first video track)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let set = try Takes.require(project, command: id)
        let path = EngineConfig.expand(p.requiredString("reference"))
        guard let data = FileManager.default.contents(atPath: path) else { throw CommandError.notFound("\(id): no file at \(path)") }
        let reference = try JSONValue.parse(data)
        let track: Track
        if let tid = p.string("trackId") { track = project.tracks[try Timeline.trackIndex(tid, in: project, editable: false)] }
        else {
            guard let t = project.tracks.first(where: { $0.kind == .video }) else { throw CommandError.conflict("\(id): no video track") }
            track = t
        }
        // Each clip belongs to the line whose chosen take it overlaps most.
        let kept = track.clips.filter { $0.assetID == set.assetID }.compactMap { c -> (line: Int, start: Double, end: Double)? in
            var best: (line: Int, overlap: Double)?
            for (li, line) in set.lines.enumerated() {
                guard let k = line.chosen else { continue }
                for part in line.takes[k].parts {
                    let o = min(part.end, c.sourceOut).seconds - max(part.start, c.sourceIn).seconds
                    if o > 0, o > (best?.overlap ?? 0) { best = (li + 1, o) }
                }
            }
            return best.map { ($0.line, c.sourceIn.seconds, c.sourceOut.seconds) }
        }
        let rows = TakeComparison.compare(takes: set, kept: kept, reference: reference)
        let errors = rows.flatMap { [$0.inErrMs, $0.outErrMs].compactMap { $0 }.map(abs) }
        let rowJSON: [JSONValue] = rows.map { r in
            func opt(_ x: Double?) -> JSONValue { x.map { .number(($0 * 1000).rounded() / 1000) } ?? .null }
            return ["line": .number(Double(r.line)), "autoTake": r.autoTake.map { .string($0) } ?? .null,
                    "manualTake": r.manualTake.map { .string($0) } ?? .null, "sameTake": .bool(r.sameTake),
                    "autoIn": opt(r.autoIn), "autoOut": opt(r.autoOut), "manualIn": opt(r.manualIn), "manualOut": opt(r.manualOut),
                    "inErrMs": r.inErrMs.map { .number($0) } ?? .null, "outErrMs": r.outErrMs.map { .number($0) } ?? .null]
        }
        let compared = rows.filter { $0.manualTake != nil || $0.manualIn != nil || $0.manualOut != nil }.count
        return ["summary": ["lines": .number(Double(compared)), "sameTake": .number(Double(rows.filter(\.sameTake).count)),
                            "boundaries": .number(Double(errors.count)),
                            "maxAbsErrMs": .number(errors.max() ?? 0), "medianAbsErrMs": .number(Envelope.percentile(errors, 50)),
                            "within100ms": .number(errors.isEmpty ? 0 : Double(errors.filter { $0 <= 100 }.count) / Double(errors.count))],
                "lines": .array(rowJSON)]
    }
}

enum TranscriptTimeline: Command {
    static let id = "transcript.timeline"
    static let summary = "The words as the timeline now plays them, with an index per word and the clip it belongs to. Use it to find a repeated word, a filler or a stumble left in the edit (transcript.fillers lists the filler candidates), then remove it with transcript.deleteWords. Returns {count, text, words: [{i, text, start, end, clip}]}."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Track to read (default: the first video track with clips)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let track = try TranscriptTimeline.track(p, project, command: id)
        let words = TimelineTranscript.words(of: track, in: project)
        return ["trackId": .string(track.id), "count": .number(Double(words.count)),
                "text": .string(words.map(\.text).joined(separator: " ")),
                "words": .array(words.map { w in
                    ["i": .number(Double(w.index)), "text": .string(w.text), "start": ProjectState.seconds(w.start),
                     "end": ProjectState.seconds(w.end), "clip": .string(w.clipID)]
                })]
    }

    static func track(_ p: CommandParams, _ project: Project, command: String) throws -> Track {
        if let tid = p.string("trackId") { return project.tracks[try Timeline.trackIndex(tid, in: project, editable: false)] }
        guard let t = TimelineTranscript.defaultTrack(in: project) else { throw CommandError.conflict("\(command): no track with clips") }
        return t
    }
}

enum TranscriptFillers: Command {
    static let id = "transcript.fillers"
    static let summary = "Find the filler words left in the edit (changes nothing): the candidates of the timeline's transcript, each with its word index (as transcript.timeline), text, start/end, the pause before and after it and a class — sure (pure hesitations: «ehm», «uhm», «euh», «um», «hã»…), maybe (words that are fillers only when they stand alone: «allora», «cioè», «so», «like», «du coup», «então», «né»…, listed only when they open a take or a pause separates them on both sides) or repeat (a word said twice in a row, «the the»: the first one). Per class: the seconds removing them would save and delete, the exact parameters of transcript.deleteWords that removes them all in one undo step (for maybe, send only the ranges the person named). Speech engines often leave hesitations out of the text: an empty sure list does not mean the speaker never hesitated (the long pauses edit.autoCut removes are where they were). Returns {language, count, fillers, seconds, delete}."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Track to read (default: as transcript.timeline)."),
        .optional("language", .string, "Language of the tables (it, en, fr, pt; default: the transcript's)."),
        .optional("pause", .number, "Shortest silence that sets a maybe word apart, seconds (default 0.25)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let track = try TranscriptTimeline.track(p, project, command: id)
        let words = TimelineTranscript.words(of: track, in: project)
        let language = p.string("language") ?? transcriptLanguage(track, project) ?? "it"
        let pause = MediaTime(seconds: p.number("pause") ?? 0.25)
        let found = Fillers.candidates(words, track: track, language: language, pause: pause)
        let rate = project.settings.frameRate
        func seconds(_ c: Fillers.Candidate) -> MediaTime {
            let s = TranscriptDeleteWords.span(words, from: c.from, to: c.to, track: track, rate: rate)
            return s.end - s.start
        }
        var perClass: [String: JSONValue] = [:], delete: [String: JSONValue] = [:]
        for kind in Fillers.Kind.allCases {
            let of = found.filter { $0.kind == kind }
            let spans = TranscriptDeleteWords.merged(of.map { TranscriptDeleteWords.span(words, from: $0.from, to: $0.to, track: track, rate: rate) })
            perClass[kind.rawValue] = ProjectState.seconds(spans.reduce(MediaTime.zero) { $0 + ($1.end - $1.start) })
            guard !of.isEmpty else { continue }
            delete[kind.rawValue] = ["trackId": .string(track.id), "ranges": .array(of.map { c in
                ["from": .number(Double(c.from)), "to": .number(Double(c.to)), "expect": .string(c.text)]
            })]
        }
        return ["trackId": .string(track.id), "language": .string(language), "count": .number(Double(found.count)),
                "fillers": .array(found.map { c in
                    ["i": .number(Double(c.from)), "to": .number(Double(c.to)), "text": .string(c.text), "class": .string(c.kind.rawValue),
                     "start": ProjectState.seconds(c.start), "end": ProjectState.seconds(c.end),
                     "pauseBefore": ProjectState.seconds(c.pauseBefore), "pauseAfter": ProjectState.seconds(c.pauseAfter),
                     "seconds": ProjectState.seconds(seconds(c))]
                }),
                "seconds": .object(perClass), "delete": .object(delete)]
    }

    /// The language of the transcript under the track's first clip that has one.
    static func transcriptLanguage(_ track: Track, _ project: Project) -> String? {
        for c in track.clips {
            if let a = project.asset(c.assetID), let t = TimelineTranscript.transcript(of: a, in: project) { return t.language }
        }
        return nil
    }
}

enum TranscriptDeleteWords: Command {
    static let id = "transcript.deleteWords"
    static let summary = "Text-based editing: remove a range of words (indices from transcript.timeline, inclusive) from the timeline — a stumble, a filler, a repeated word — or several ranges in one go (ranges: what transcript.fillers gives under delete). Cuts every video/audio track at the range edges (frame-snapped) and ripple-deletes the pieces in between, one undo step; each sound piece keeps its clip's edge fades (edit.autoCut's 15 ms) at the new cuts; captions, if any, are regenerated. Re-run edit.punchIns afterwards if the clip pattern changed. Returns the commands it ran."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("from", .integer, "First word index to remove (or ranges)."),
        .optional("to", .integer, "Last word index to remove (default: from)."),
        .optional("ranges", .array(.object), "Several ranges instead of from/to, removed in one undo step: [{from, to?, expect?}], every index as transcript.timeline gives it before this call."),
        .optional("trackId", .string, "Track whose words the indices refer to (default: as transcript.timeline)."),
        .optional("expect", .string, "Safety check: the removed words must read this (case and punctuation ignored)."),
    ]

    /// The timeline span removing words `from`…`to` takes: from the first word's start (its clip's start when it opens the
    /// clip) to the next word's start in the same clip (the clip's end when it closes it), frame-snapped.
    static func span(_ words: [TimelineWord], from: Int, to: Int, track: Track, rate: Rational) -> (start: MediaTime, end: MediaTime) {
        func clip(_ id: String) -> Clip? { track.clips.first { $0.id == id } }
        let first = words[from], last = words[to]
        var a = first.start, b = last.end
        if from == 0 || words[from - 1].clipID != first.clipID { a = clip(first.clipID)?.start ?? a }
        if to + 1 < words.count, words[to + 1].clipID == last.clipID { b = words[to + 1].start }
        else { b = clip(last.clipID)?.end ?? b }
        return (a.snapped(to: rate), b.snapped(to: rate))
    }

    /// Spans in timeline order, the ones that touch or overlap made one.
    static func merged(_ spans: [(start: MediaTime, end: MediaTime)]) -> [(start: MediaTime, end: MediaTime)] {
        var out: [(start: MediaTime, end: MediaTime)] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end { out[out.count - 1].end = max(last.end, s.end) } else { out.append(s) }
        }
        return out
    }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let track = try TranscriptTimeline.track(p, project, command: id)
        let words = TimelineTranscript.words(of: track, in: project)
        var asked: [(from: Int, to: Int, expect: String?)] = []
        if let ranges = p.json("ranges")?.arrayValue {
            guard p.int("from") == nil, p.int("to") == nil, p.string("expect") == nil else {
                throw CommandError.invalid("\(id): pass from/to/expect or ranges, not both")
            }
            guard !ranges.isEmpty else { throw CommandError.invalid("\(id): ranges is empty") }
            for r in ranges {
                guard let from = r["from"]?.doubleValue.map({ Int($0) }) else { throw CommandError.invalid("\(id): every range needs from") }
                asked.append((from, r["to"]?.doubleValue.map { Int($0) } ?? from, r["expect"]?.stringValue))
            }
        } else {
            guard let from = p.int("from") else { throw CommandError.invalid("\(id): pass from (and to), or ranges") }
            asked = [(from, p.int("to") ?? from, p.string("expect"))]
        }
        var removed: [String] = []
        for r in asked {
            guard r.from <= r.to, words.indices.contains(r.from), words.indices.contains(r.to) else {
                throw CommandError.invalid("\(id): need 0 ≤ from ≤ to < \(words.count)")
            }
            let text = words[r.from...r.to].map(\.text).joined(separator: " ")
            if let expected = r.expect, TextNorm.tokens(expected) != TextNorm.tokens(text) {
                throw CommandError.conflict("\(id): words \(r.from)…\(r.to) read \"\(text)\", not \"\(expected)\"")
            }
            removed.append(text)
        }
        let rate = project.settings.frameRate
        let spans = merged(asked.map { span(words, from: $0.from, to: $0.to, track: track, rate: rate) })
        for s in spans where s.end <= s.start { throw CommandError.invalid("\(id): the range at \(s.start.displaySeconds)s is shorter than a frame") }

        var work = ctx
        var log: [JSONValue] = []
        let edited = project.tracks.filter { ($0.kind == .video || $0.kind == .audio || $0.kind == .overlay) && !$0.locked }.map(\.id)
        // The last span first: a ripple delete moves only what comes after it, so the earlier spans keep their times.
        for (a, b) in spans.reversed() {
            for at in [a, b] {
                for tid in edited {
                    let tr = work.project!.tracks.first { $0.id == tid }!
                    if tr.clips.contains(where: { $0.start < at && at < $0.end }) {
                        try work.perform(TimelineCut.self, ["at": .number(at.seconds), "trackId": .string(tid), "linked": false], log: &log)
                    }
                }
            }
            let doomed = work.project!.tracks.filter { edited.contains($0.id) }.flatMap(\.clips).filter { $0.start >= a && $0.end <= b }.map(\.id)
            guard !doomed.isEmpty else { throw CommandError.conflict("\(id): nothing on the timeline between \(a.displaySeconds)s and \(b.displaySeconds)s") }
            try work.perform(TimelineDelete.self, ["clipIds": .array(doomed.map { .string($0) }), "ripple": true, "linked": false], log: &log)
        }
        if let captions = work.project!.tracks.first(where: { $0.kind == .caption && $0.captions != nil }) {
            try work.perform(CaptionsGenerate.self, ["trackId": .string(captions.id)], log: &log)
        }
        ctx = work
        let total = spans.reduce(MediaTime.zero) { $0 + ($1.end - $1.start) }
        var out: [String: JSONValue] = ["removed": .string(removed.joined(separator: " … ")), "from": ProjectState.seconds(spans[0].start),
                                        "to": ProjectState.seconds(spans[spans.count - 1].end), "duration": ProjectState.seconds(total),
                                        "commands": .array(log)]
        if p.json("ranges") != nil {
            out["ranges"] = .array(spans.map { ["from": ProjectState.seconds($0.start), "to": ProjectState.seconds($0.end)] })
        }
        return .object(out)
    }
}

enum TranscriptEditText: Command {
    static let id = "transcript.editText"
    static let summary = "Correct what was said in the text (a misheard name, a typo): replace the words from…to (indices from transcript.timeline, inclusive) with new text. Only the text changes — the picture and the timing stay; the new words share the old words' time span in proportion to their length. Captions, if any, are regenerated. Empty text hides those words from the captions. Returns the old and new text."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("from", .integer, "First word index."),
        .optional("to", .integer, "Last word index (default: from)."),
        .required("text", .string, "The corrected text for that range."),
        .optional("trackId", .string, "Track whose words the indices refer to (default: as transcript.timeline)."),
        .optional("expect", .string, "Safety check: the words being replaced must read this (case and punctuation ignored)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let track = try TranscriptTimeline.track(p, project, command: id)
        let words = TimelineTranscript.words(of: track, in: project)
        let from = p.int("from") ?? 0, to = p.int("to") ?? from
        guard from <= to, words.indices.contains(from), words.indices.contains(to) else {
            throw CommandError.invalid("\(id): need 0 ≤ from ≤ to < \(words.count)")
        }
        let old = words[from...to].map(\.text).joined(separator: " ")
        if let expected = p.string("expect"), TextNorm.tokens(expected) != TextNorm.tokens(old) {
            throw CommandError.conflict("\(id): words \(from)…\(to) read \"\(old)\", not \"\(expected)\"")
        }
        // The source transcript the range comes from (one asset: a range across two different files is refused).
        func holder(_ w: TimelineWord) -> Int? {
            guard let clip = track.clips.first(where: { $0.id == w.clipID }), let a = project.asset(clip.assetID) else { return nil }
            let owner = a.analysis?.transcript != nil ? a.id : a.origin?.assetID
            return project.assets.firstIndex { $0.id == owner }
        }
        guard let ai = holder(words[from]), holder(words[to]) == ai, var transcript = project.assets[ai].analysis?.transcript else {
            throw CommandError.invalid("\(id): the words \(from)…\(to) do not come from one transcribed file")
        }
        let a = words[from].sourceStart, b = words[to].sourceEnd
        guard let i0 = transcript.words.firstIndex(where: { $0.start >= a }),
              let i1 = transcript.words.lastIndex(where: { $0.end <= b }), i0 <= i1 else {
            throw CommandError.conflict("\(id): the words \(from)…\(to) are no longer in the transcript")
        }
        let tokens = p.requiredString("text").split(whereSeparator: \.isWhitespace).map(String.init)
        // The new words share the time the old words are heard on the timeline, not the whole source span: a range
        // across a cut would otherwise put some of them in the removed part, where they are never shown.
        var spans: [(Double, Double)] = []
        var lastClip: String?
        for w in words[from...to] {
            // Clamped to the part of the source the clip shows (a word is shown when its middle is inside).
            let clip = track.clips.first { $0.id == w.clipID }
            let s = Double(max(w.sourceStart, clip?.sourceIn ?? w.sourceStart).ticks)
            let e = Double(min(w.sourceEnd, clip?.sourceOut ?? w.sourceEnd).ticks)
            if w.clipID == lastClip, let open = spans.popLast() { spans.append((open.0, e)) }
            else { spans.append((s, e)) }
            lastClip = w.clipID
        }
        let heard = spans.reduce(0) { $0 + max($1.1 - $1.0, 0) }
        func place(_ u: Double) -> (time: Double, span: Int) {
            var left = u
            for (k, s) in spans.enumerated() {
                let d = max(s.1 - s.0, 0)
                if left < d || k == spans.count - 1 { return (s.0 + min(left, d), k) }
                left -= d
            }
            return (Double(b.ticks), spans.count - 1)
        }
        let total = Double(max(tokens.reduce(0) { $0 + $1.count }, 1))
        var replacement: [Word] = []
        var cursor = 0.0
        for t in tokens {
            let next = cursor + heard * Double(t.count) / total
            let start = place(cursor), end = place(next)
            // A word never straddles a cut: it ends where its first heard span ends.
            let stop = end.span == start.span ? end.time : spans[start.span].1
            replacement.append(Word(text: t, start: MediaTime(ticks: Int64(start.time.rounded())), end: MediaTime(ticks: Int64(stop.rounded()))))
            cursor = next
        }
        transcript.words.replaceSubrange(i0...i1, with: replacement)
        project.assets[ai].analysis?.transcript = transcript
        var work = ctx
        work.project = project
        var log: [JSONValue] = []
        if let captions = project.tracks.first(where: { $0.kind == .caption && $0.captions != nil }) {
            try work.perform(CaptionsGenerate.self, ["trackId": .string(captions.id)], log: &log)
        }
        ctx = work
        return ["old": .string(old), "new": .string(tokens.joined(separator: " ")), "commands": .array(log)]
    }
}

enum EditPunchIns: Command {
    static let id = "edit.punchIns"
    static let summary = "Hide jump cuts by alternating two framings over the clips of a video track (a base crop and a tighter punch-in), switching at every clip or only when the script line changes (by \"line\"). Default (no crops given): face-aware crops per shot from the face track (run faces.track first) — every detected face kept in frame (a child in the arms too), room above the hair, never a head cut, static when one crop holds the shot, else smoothed and speed-limited; zoom sets how tight base and punch are. preset \"wesites-selfie\" = the fixed crops approved on the WeSites 1080×1920 selfie take (2026-10-26) (base [864,1536,152,384], punch [760,1351,204,487]); base/punch = your own fixed crops; mode \"face\" = fixed sizes centred on the main face. Expressed as clip.set commands, one undo step. Returns each clip's framing, crop, whether every head fits, and the face count."
    static let kind = CommandKind.edit
    static let presets: [String: (base: [Double], punch: [Double])] = [
        "wesites-selfie": ([864, 1536, 152, 384], [760, 1351, 204, 487]),
    ]
    static let params: [ParamSpec] = [
        .optional("base", .array(.number), "Fixed base crop [w, h, x, y] in source pixels (face mode: only w, h are used)."),
        .optional("punch", .array(.number), "Fixed punch-in crop [w, h, x, y] (face mode: only w, h are used)."),
        .optional("preset", .oneOf(Array(presets.keys).sorted()), "Named fixed crops (wesites-selfie: the approved WeSites selfie take)."),
        .optional("trackId", .string, "Video track (default: the first one)."),
        .optional("mode", .oneOf(["auto", "alternate", "face"]), "auto (default without crops): face-aware crops; alternate: the fixed crops; face: fixed sizes centred on the main face."),
        .optional("zoom", .array(.number), "auto: crop height of base and punch as fractions of the largest crop (default [0.8, 0.7]); grown when the heads need it."),
        .optional("headroom", .number, "auto: room above the hair, fraction of the crop height (default 0.05)."),
        .optional("by", .oneOf(["clip", "line"]), "Switch framing at every clip (default) or only when the script line changes (needs takes)."),
        .optional("startWith", .oneOf(["base", "punch"]), "Framing of the first clip (default base)."),
        .optional("pad", .number, "Face mode: room added above the face box, fraction of its height (default 0.25)."),
        .optional("smooth", .number, "Face/auto mode: moving-average window on the crop position, seconds (default 0.5 face, 0.6 auto)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let t: Int
        if let tid = p.string("trackId") { t = try Timeline.trackIndex(tid, in: project) }
        else {
            guard let v = project.tracks.firstIndex(where: { $0.kind == .video }) else { throw CommandError.conflict("\(id): no video track") }
            t = v
        }
        let clips = project.tracks[t].clips
        guard !clips.isEmpty else { throw CommandError.conflict("\(id): track \(project.tracks[t].name) has no clips") }
        var crops: [[Double]] = []
        if let name = p.string("preset"), let preset = presets[name] { crops = [preset.base, preset.punch] }
        if p.has("base") || p.has("punch") { crops = [p.numbers("base") ?? [], p.numbers("punch") ?? []] }
        let mode = p.string("mode") ?? (crops.isEmpty ? "auto" : "alternate")
        if mode != "auto" {
            guard crops.count == 2, crops.allSatisfy({ $0.count == 4 && $0[0] > 0 && $0[1] > 0 }) else {
                throw CommandError.invalid("\(id): \(mode) needs base and punch [w, h, x, y] (or a preset)")
            }
        }
        let zoom = p.numbers("zoom") ?? [0.8, 0.7]
        guard zoom.count == 2, zoom.allSatisfy({ $0 > 0.2 && $0 <= 1 }) else { throw CommandError.invalid("\(id): zoom must be [base, punch] in 0.2…1") }
        let byLine = p.string("by") == "line"
        var parity = p.string("startWith") == "punch" ? 1 : 0

        // Framing per clip: flips when the group (clip, or script line) changes.
        var lines: [Int?] = clips.map { _ in nil }
        if byLine {
            let set = try Takes.require(project, command: id)
            lines = clips.map { Takes.line(of: $0, in: set) }
        }
        var choice: [Int] = []
        for (k, line) in lines.enumerated() {
            if k > 0, !byLine || line == nil || line != lines[k - 1] { parity ^= 1 }
            choice.append(parity)
        }

        var tracks: [String: FaceTrack] = [:]
        func faceTrack(_ asset: MediaAsset) throws -> FaceTrack {
            guard let path = asset.analysis?.faces?.path else { throw CommandError.conflict("\(id): \(asset.id) has no face track — run faces.track first (or pass a preset / base and punch)") }
            if let f = tracks[path] { return f }
            guard let data = FileManager.default.contents(atPath: path) else { throw CommandError.notFound("\(id): face sidecar missing: \(path)") }
            let f = try JSONDecoder().decode(FaceTrack.self, from: data)
            tracks[path] = f
            return f
        }
        let aspect = Double(project.settings.width) / Double(project.settings.height)
        var work = ctx
        var log: [JSONValue] = []
        var rows: [JSONValue] = []
        for (clip, which) in zip(clips, choice) {
            guard let asset = project.asset(clip.assetID), let video = asset.video else { throw CommandError.conflict("\(id): clip \(clip.id) has no picture") }
            var params: [String: JSONValue] = ["clipId": .string(clip.id), "clearKeyframes": true]
            var row: [String: JSONValue] = ["clip": .string(clip.id), "framing": .string(which == 0 ? "base" : "punch"),
                                            "line": lines[rows.count].map { .number(Double($0)) } ?? .null]
            var path0: [(time: Double, crop: [Double])] = []
            switch mode {
            case "auto":
                let options = FaceFraming.Options(zoom: zoom[which], headroom: p.number("headroom") ?? 0.05, smooth: p.number("smooth") ?? 0.6,
                                                  maxHead: which == 0 ? 0.6 : 0.66)
                if let path = FaceFraming.cropPath(try faceTrack(asset), from: clip.sourceIn.seconds, to: clip.sourceOut.seconds,
                                                   frame: (video.width, video.height), aspect: aspect, options: options) {
                    path0 = path.points
                    row["fits"] = .bool(path.fits)
                    row["faces"] = .number(Double(path.faces))
                } else {
                    // No face in this shot: a centred crop at the zoom, slightly high (where heads usually are).
                    let W = Double(video.width), H = Double(video.height)
                    let (mw, mh) = W / H > aspect ? (H * aspect, H) : (W, W / aspect)
                    let (w, h) = (mw * zoom[which], mh * zoom[which])
                    path0 = [(0, [w, h, ((W - w) / 2).rounded(), ((H - h) * 0.3).rounded()])]
                    row["faces"] = 0
                }
            case "face":
                let path = FacePunch.path(try faceTrack(asset), clip: clip, size: (crops[which][0], crops[which][1]),
                                          frame: (video.width, video.height), pad: p.number("pad") ?? 0.25, smooth: p.number("smooth") ?? 0.5)
                guard !path.isEmpty else { throw CommandError.conflict("\(id): no face found in clip \(clip.id)") }
                path0 = path.map { ($0.time, $0.crop) }
            default:
                path0 = [(0, crops[which])]
            }
            params["crop"] = .array(path0[0].crop.map { .number($0) })
            if path0.count > 1 {
                params["keyframes"] = .array(path0.map { ["time": .number($0.time), "crop": .array($0.crop.map { .number($0) })] })
            }
            try work.perform(ClipSet.self, .object(params), log: &log)
            row["crop"] = .array(path0[0].crop.map { .number($0) })
            row["keyframes"] = .number(Double(path0.count > 1 ? path0.count : 0))
            rows.append(.object(row))
        }
        ctx = work
        return ["trackId": .string(project.tracks[t].id), "mode": .string(mode), "clips": .array(rows), "commands": .array(log),
                "allFit": .bool(rows.allSatisfy { $0["fits"]?.boolValue != false })]
    }
}

/// Face-centred crop path for one clip: the smoothed face box centre, moved up by half the hair
/// padding, averaged over a window, sampled every 5 frames; a static crop when it barely moves.
enum FacePunch {
    struct Point { var time: Double; var crop: [Double] }

    static func path(_ track: FaceTrack, clip: Clip, size: (Double, Double), frame: (Int, Int), pad: Double, smooth: Double) -> [Point] {
        let s0 = clip.sourceIn.seconds, s1 = clip.sourceOut.seconds
        let samples = track.frames.filter { $0.t >= s0 - 1e-6 && $0.t < s1 - 1e-6 }
            .compactMap { f -> (t: Double, x: Double, y: Double)? in
                guard let b = f.smooth ?? f.raw else { return nil }
                return (f.t, b[0] + b[2] / 2, b[1] + b[3] / 2 - pad * b[3] / 2)
            }
        guard !samples.isEmpty else { return [] }
        let half = max(Int((smooth * track.fps / 2).rounded()), 0)
        let (w, h) = (min(size.0, Double(frame.0)), min(size.1, Double(frame.1)))
        func crop(_ k: Int) -> [Double] {
            let lo = max(0, k - half), hi = min(samples.count - 1, k + half)
            let n = Double(hi - lo + 1)
            let cx = samples[lo...hi].map(\.x).reduce(0, +) / n, cy = samples[lo...hi].map(\.y).reduce(0, +) / n
            let x = min(max(cx - w / 2, 0), Double(frame.0) - w), y = min(max(cy - h / 2, 0), Double(frame.1) - h)
            return [w, h, (x * 10).rounded() / 10, (y * 10).rounded() / 10]
        }
        var picks = Array(stride(from: 0, to: samples.count, by: 5))
        if picks.last != samples.count - 1 { picks.append(samples.count - 1) }
        let points = picks.map { Point(time: max(samples[$0].t - s0, 0), crop: crop($0)) }
        let xs = points.map { $0.crop[2] }, ys = points.map { $0.crop[3] }
        if xs.max()! - xs.min()! < 2, ys.max()! - ys.min()! < 2 {
            let n = Double(points.count)
            return [Point(time: 0, crop: [w, h, (xs.reduce(0, +) / n).rounded(), (ys.reduce(0, +) / n).rounded()])]
        }
        return points
    }
}

extension Takes {
    /// Script line (1-based) whose chosen take overlaps the clip's source range most.
    static func line(of c: Clip, in set: TakeSet) -> Int? {
        guard c.assetID == set.assetID else { return nil }
        var best: (line: Int, overlap: Double)?
        for (li, line) in set.lines.enumerated() {
            guard let k = line.chosen else { continue }
            for part in line.takes[k].parts {
                let o = min(part.end, c.sourceOut).seconds - max(part.start, c.sourceIn).seconds
                if o > 0, o > (best?.overlap ?? 0) { best = (li + 1, o) }
            }
        }
        return best?.line
    }
}
