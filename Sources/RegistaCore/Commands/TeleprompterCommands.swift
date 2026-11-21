import Foundation

enum ScriptPrepare: Command {
    static let id = "script.prepare"
    static let summary = "Format a script for reading aloud on the teleprompter, before the shoot: one numbered sentence per take, short display lines (≤ maxChars, default 32), a breath mark \" / \" after mid-sentence commas/colons/dashes (shown as a subtle gap), keywords flagged *like this* (subtly emphasized; pass the same keywords you will give captions.generate — they are kept in the project for it). Sets the project script (like script.set) unless set: false. Returns the prepared text, its sentences with their display lines, and the keywords."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("text", .string, "Script text: one sentence (take) per line, or numbered lines."),
        .optional("path", .string, "Read the script from this file instead (a script.md with a \"## Testo\" section works)."),
        .optional("maxChars", .integer, "Longest display line in characters (default 32)."),
        .optional("keywords", .array(.string), "Words to emphasize, as written in the script (multi-word ok, e.g. \"nove virgola due\"). Default: the ones already flagged, else numbers, acronyms and names."),
        .optional("set", .boolean, "Also make it the project script (default true when a project is open)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var text = p.string("text")
        if let path = p.string("path") {
            let url = URL(fileURLWithPath: EngineConfig.expand(path))
            guard let data = FileManager.default.contents(atPath: url.path) else { throw CommandError.notFound("\(id): no file at \(url.path)") }
            text = String(decoding: data, as: UTF8.self)
        }
        guard let text else { throw CommandError.invalid("\(id): pass text or path") }
        let maxChars = p.int("maxChars") ?? 32
        guard (12...80).contains(maxChars) else { throw CommandError.invalid("\(id): maxChars is 12…80") }
        let prepared = PromptScript.prepare(text, maxChars: maxChars, keywords: p.strings("keywords"))
        let prompt = PromptScript(prepared)
        guard !prompt.sentences.isEmpty else { throw CommandError.invalid("\(id): no script lines found") }
        var applied = false
        if p.bool("set") ?? true, var project = ctx.project {
            project.script = Script(lines: prompt.sentences.map(\.text), prompt: prepared, keywords: prompt.keywords.isEmpty ? nil : prompt.keywords)
            project.takes = nil
            ctx.project = project
            applied = true
        }
        let longest = prompt.sentences.flatMap(\.lines).map { PromptScript.plain($0).count }.max() ?? 0
        return [
            "text": .string(prepared),
            "sentences": .array(prompt.sentences.enumerated().map { i, s in
                ["line": .number(Double(i + 1)), "text": .string(s.text), "display": .array(s.lines.map { .string($0) })]
            }),
            "keywords": .array(prompt.keywords.map { .string($0) }),
            "longestLine": .number(Double(longest)),
            "set": .bool(applied),
        ]
    }
}

enum TakesLive: Command {
    static let id = "takes.live"
    static let summary = "Attach the teleprompter's live take markers to a recording (normally automatic: media.import reads the <name>.takes.json the app writes next to each recording). Pass a markers file (the app's sidecar or a teleprompter.simulate output), or clear: true. takes.list then prefers them. Returns the markers per line and whether they match the project script."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("assetId", .string, "Recording asset (default: the only video asset)."),
        .optional("path", .string, "JSON with {sentences, markers: [{sentence, take, start, end, complete}]}."),
        .optional("clear", .boolean, "Remove the asset's live markers."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let index: Int
        if let a = p.string("assetId") {
            index = try Analysis.assetIndex(a, in: project, command: id)
        } else {
            let videos = project.assets.indices.filter { project.assets[$0].video != nil && project.assets[$0].origin == nil }
            guard videos.count == 1 else { throw CommandError.invalid("\(id): \(videos.isEmpty ? "no video asset" : "several video assets — pass assetId")") }
            index = videos[0]
        }
        if p.bool("clear") == true {
            project.assets[index].analysis?.liveTakes = nil
        } else if let path = p.string("path") {
            let url = URL(fileURLWithPath: EngineConfig.expand(path))
            let log: LiveTakeLog
            do { log = try LiveTakeLog.read(url) } catch { throw CommandError.invalid("\(id): cannot read markers from \(url.path): \(error)") }
            if project.assets[index].analysis == nil { project.assets[index].analysis = AssetAnalysis() }
            project.assets[index].analysis?.liveTakes = log
        } else if project.assets[index].analysis?.liveTakes == nil {
            throw CommandError.invalid("\(id): pass path or clear")
        }
        ctx.project = project
        let asset = project.assets[index]
        guard let log = asset.analysis?.liveTakes else { return ["assetId": .string(asset.id), "markers": 0] }
        return ["assetId": .string(asset.id), "markers": .number(Double(log.markers.count)),
                "matchesScript": project.script.map { .bool(log.matches($0)) } ?? .null,
                "recognizer": log.recognizer.map { .string($0) } ?? .null,
                "lines": .array(Dictionary(grouping: log.markers, by: \.sentence).sorted { $0.key < $1.key }.map { line, ms in
                    ["line": .number(Double(line)), "takes": .number(Double(ms.count)),
                     "complete": .array(ms.filter(\.complete).map { .number(Double($0.take)) })]
                })]
    }
}

enum TeleprompterSimulate: Command {
    static let id = "teleprompter.simulate"
    static let summary = "Test the teleprompter without a speaker: replays an audio/video file through the live on-device recognizer (Apple SpeechTranscriber, else SFSpeechRecognizer) at speed× real time and drives the take tracker with it, as if the speaker were reading the script. Returns the cursor lag (median/p90 ms between a word ending and the confirmed cursor / the drawn highlight, with its lead, reaching it), the restarts seen, the live take markers and, with a reference segments.json, which lines got the same take as the hand edit. Writes the full log (cursor moves, restarts, markers; usable by takes.live) to output."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("audio", .string, "Audio or video file (the take)."),
        .optional("replay", .string, "Instead of audio: an earlier simulate log — replays its recognizer updates offline (deterministic, no speech engine needed)."),
        .required("script", .string, "Script file (script.md works) or the script text."),
        .optional("language", .string, "Recognizer locale (default it-IT; fr-FR for French)."),
        .optional("speed", .number, "Feed speed, 1 = real time (default; lag numbers are only meaningful at 1)."),
        .optional("engine", .oneOf(["DictationTranscriber", "SpeechTranscriber", "SFSpeechRecognizer"]), "Recognizer (default: the teleprompter's, DictationTranscriber on macOS 26)."),
        .optional("reference", .string, "segments.json of the hand edit (source in/out per segment), to compare the takes."),
        .optional("output", .string, "Where to write the log JSON (default: a temporary file)."),
    ]

    /// The tracker fed from the recognizer's thread.
    final class Session: @unchecked Sendable {
        let lock = NSLock()
        var tracker: TakeTracker
        var moves: [(t: Double, cursor: Int)] = []
        /// After every update: confirmed cursor, when it last moved forward, pace, on script.
        var states: [(t: Double, cursor: Int, movedAt: Double, wpm: Double?, onScript: Bool)] = []
        var movedAt = 0.0
        var restarts: [(t: Double, sentence: Int)] = []
        var commands: [(t: Double, command: String)] = []
        var recorded: [SpeechHypothesis] = []
        init(_ t: TakeTracker) { tracker = t }

        func ingest(_ h: SpeechHypothesis) {
            lock.withLock {
                recorded.append(h)
                let before = tracker.cursor
                defer {
                    if tracker.cursor > before { movedAt = h.audioTime }
                    states.append((h.audioTime, tracker.cursor, movedAt, tracker.pace.wordsPerMinute(at: h.audioTime), tracker.state == .onScript))
                }
                for e in tracker.update(h.words, epoch: h.epoch, now: h.audioTime) {
                    switch e {
                    case .moved(let c): moves.append((h.audioTime, c))
                    case .restart(let s): restarts.append((h.audioTime, s + 1))
                    case .command(let c): commands.append((h.audioTime, c.rawValue))
                    case .take: break
                    }
                }
            }
        }
    }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let scriptArg = p.requiredString("script")
        let scriptPath = EngineConfig.expand(scriptArg)
        let text = FileManager.default.contents(atPath: scriptPath).map { String(decoding: $0, as: UTF8.self) } ?? scriptArg
        let prompt = PromptScript(text)
        guard !prompt.sentences.isEmpty else { throw CommandError.invalid("\(id): no script lines found") }
        let language = p.string("language") ?? "it-IT"
        let speed = p.number("speed") ?? 1
        guard speed > 0, speed <= 50 else { throw CommandError.invalid("\(id): speed is 0…50") }
        let commands = VoiceCommandSet.defaults(language: language)

        let session = Session(TakeTracker(script: prompt, commands: commands))
        let result: SpeechStreamResult
        if let replay = p.string("replay") {
            let path = EngineConfig.expand(replay)
            guard let data = FileManager.default.contents(atPath: path) else { throw CommandError.notFound("\(id): no file at \(path)") }
            let log = try JSONValue.parse(data)
            let updates: [SpeechHypothesis]
            do { updates = try JSONDecoder().decode([SpeechHypothesis].self, from: Data((log["updates"] ?? []).text().utf8)) }
            catch { throw CommandError.invalid("\(id): \(path) has no recognizer updates: \(error)") }
            for u in updates { session.ingest(u) }
            let words = (log["words"]?.arrayValue ?? []).compactMap { w -> Word? in
                guard let t = w["text"]?.stringValue, let s = w["start"]?.doubleValue, let e = w["end"]?.doubleValue else { return nil }
                return Word(t, s, e)
            }
            result = SpeechStreamResult(engine: log["recognizer"]?.stringValue ?? "replay", locale: language, words: words,
                                        audioSeconds: log.value(at: "summary.audioSeconds")?.doubleValue ?? (updates.last?.audioTime ?? 0), wallSeconds: 0)
        } else {
            guard let speech = ctx.services.speech else {
                throw CommandError(.io, "\(id): this host has no live speech recognizer (use regista-engine, regista-mcp or the app)")
            }
            guard let a = p.string("audio") else { throw CommandError.invalid("\(id): pass audio or replay") }
            let audio = URL(fileURLWithPath: EngineConfig.expand(a))
            guard FileManager.default.fileExists(atPath: audio.path) else { throw CommandError.notFound("\(id): no file at \(audio.path)") }
            do {
                result = try speech.stream(file: audio, locale: language, engine: p.string("engine"), speed: speed,
                                           contextualStrings: rareWords(prompt.sentences.map(\.text))) { session.ingest($0) }
            } catch {
                throw CommandError(.io, "\(id): recognition failed: \(error)")
            }
        }
        let markers = session.lock.withLock { session.tracker.finish() }

        // The ideal follower: the same tracker fed each finalized word the moment it ends.
        var ideal = TakeTracker(script: prompt, commands: commands)
        var heard: [HeardWord] = []
        var idealMoves: [(t: Double, from: Int, to: Int)] = []
        for w in result.words {
            heard.append(HeardWord(w.text, start: w.start.seconds, end: w.end.seconds))
            let from = ideal.cursor
            for case .moved(let c) in ideal.update(heard, epoch: 0, now: w.end.seconds) { idealMoves.append((w.end.seconds, from, c)) }
        }
        // Lag: for every word the ideal follower reads in order, when the live cursor got there — the
        // confirmed cursor, and the highlight as drawn (with the lead, sampled every 50 ms like frames).
        let lead = CursorLead()
        var drawn: [(t: Double, cursor: Int)] = []
        var si = 0
        var tick = 0.0
        while tick <= result.audioSeconds + 1 {
            while si + 1 < session.states.count, session.states[si + 1].t <= tick { si += 1 }
            if let st = session.states.first, st.t <= tick {
                let s = session.states[si]
                drawn.append((tick, lead.cursor(in: prompt, confirmed: s.cursor, movedAt: s.movedAt, now: tick, wpm: s.wpm, onScript: s.onScript)))
            }
            tick += 0.05
        }
        func lagStats(_ trail: [(t: Double, cursor: Int)]) -> (lags: [Double], misses: Int) {
            var lags: [Double] = [], misses = 0
            for m in idealMoves where m.to > m.from && m.to <= m.from + 3 {
                if let live = trail.first(where: { $0.t >= m.t - 0.3 && $0.t <= m.t + 3 && $0.cursor >= m.to && $0.cursor <= m.to + 3 }) {
                    lags.append((live.t - m.t) * 1000)
                } else {
                    misses += 1
                }
            }
            return (lags, misses)
        }
        let (lags, misses) = lagStats(session.moves)
        let (drawnLags, drawnMisses) = lagStats(drawn)
        // How often the drawn highlight is ahead of the voice (the ideal cursor at that moment).
        var ahead = 0
        for d in drawn {
            let spoken = idealMoves.last(where: { $0.t <= d.t })?.to ?? 0
            if d.cursor > spoken { ahead += 1 }
        }

        let script = Script(lines: prompt.sentences.map(\.text))
        let log = LiveTakeLog(sentences: script.lines, markers: markers, recognizer: result.engine, language: language)
        var comparison: JSONValue = .null
        if let ref = p.string("reference") {
            let path = EngineConfig.expand(ref)
            guard let data = FileManager.default.contents(atPath: path) else { throw CommandError.notFound("\(id): no file at \(path)") }
            let set = TakeFinder.fromMarkers(script: script, log: log, words: result.words, envelope: nil, assetID: "simulation")
            let kept = set.segments().map { (line: $0.line, start: $0.range.start.seconds, end: $0.range.end.seconds) }
            let rows = TakeComparison.compare(takes: set, kept: kept, reference: try JSONValue.parse(data))
            let compared = rows.filter { $0.manualTake != nil }
            comparison = ["lines": .number(Double(compared.count)), "sameTake": .number(Double(compared.filter(\.sameTake).count)),
                          "rows": .array(rows.map { r in
                              ["line": .number(Double(r.line)), "live": r.autoTake.map { .string($0) } ?? .null,
                               "manual": r.manualTake.map { .string($0) } ?? .null, "sameTake": .bool(r.sameTake)]
                          })]
        }

        let ms = { (x: Double) -> JSONValue in .number(x.rounded()) }
        let markerJSON = try JSONValue.from(markers)
        let summary: JSONValue = [
            "engine": .string(result.engine), "language": .string(language), "speed": .number(speed),
            "audioSeconds": Analysis.seconds(result.audioSeconds), "wallSeconds": Analysis.seconds(result.wallSeconds),
            "updates": .number(Double(session.recorded.count)), "finalWords": .number(Double(result.words.count)),
            "cursorLagMs": ["median": ms(Envelope.percentile(lags, 50)), "p90": ms(Envelope.percentile(lags, 90)),
                            "words": .number(Double(lags.count)), "missed": .number(Double(misses))],
            "highlightLagMs": ["median": ms(Envelope.percentile(drawnLags, 50)), "p90": ms(Envelope.percentile(drawnLags, 90)),
                               "words": .number(Double(drawnLags.count)), "missed": .number(Double(drawnMisses)),
                               "aheadOfVoice": .number((Double(ahead) / Double(max(drawn.count, 1)) * 1000).rounded() / 1000)],
            "restarts": .array(session.restarts.map { ["t": Analysis.seconds($0.t, places: 100), "sentence": .number(Double($0.sentence))] }),
            "commands": .array(session.commands.map { ["t": Analysis.seconds($0.t, places: 100), "command": .string($0.command)] }),
            "takesPerLine": .array(script.lines.indices.map { li in .number(Double(markers.filter { $0.sentence == li + 1 }.count)) }),
            "comparison": comparison,
        ]
        // The log: a LiveTakeLog (takes.live reads it) plus the cursor trail.
        let output: URL
        if let o = p.string("output") { output = try Render.output(o, command: id) }
        else { output = TemporaryFolder.url.appendingPathComponent("teleprompter-sim-\(UUID().uuidString.prefix(8)).json") }
        let full: JSONValue = [
            "sentences": .array(script.lines.map { .string($0) }), "markers": markerJSON,
            "recognizer": .string(result.engine), "language": .string(language), "summary": summary,
            "moves": .array(session.moves.map { ["t": Analysis.seconds($0.t), "cursor": .number(Double($0.cursor))] }),
            "words": .array(result.words.map { ["text": .string($0.text), "start": Analysis.seconds($0.start.seconds), "end": Analysis.seconds($0.end.seconds)] }),
            "updates": try JSONValue.from(session.recorded),
        ]
        do { try Data(full.text(pretty: true).utf8).write(to: output) } catch { throw CommandError(.io, "\(id): cannot write \(output.path)") }
        var out = summary
        if case .object(var o) = out { o["log"] = .string(output.path); o["markers"] = markerJSON; out = .object(o) }
        return out
    }

    /// Long, distinctive words help the recognizer with names and jargon.
    static func rareWords(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.flatMap { $0.split(separator: " ") }.map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 7 && seen.insert($0.lowercased()).inserted }.prefix(100).map { $0 }
    }
}
