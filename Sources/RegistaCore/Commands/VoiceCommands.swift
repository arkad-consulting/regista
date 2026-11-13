import Foundation

// profile.* and voice.* (issues #38, #41): voice-over in the active profile's own cloned voice. A fresh Regista has no
// profile: each person creates theirs and records their own voice. Switching, adopting and deleting profiles are
// human-only, so an agent can never use someone else's voice.

enum Profiles {
    static func summary(_ e: ProfileEntry, active: Bool) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(e.profile.id), "name": .string(e.profile.name), "active": .bool(active),
                                      "languages": .array(e.profile.voices.keys.sorted().map { .string($0) })]
        if e.locked { o["locked"] = "created on another Mac: its owner adopts it in the Regista app (Settings → Profile)" }
        return .object(o)
    }
}

enum ProfileGet: Command {
    static let id = "profile.get"
    static let summary = "Who this Regista belongs to: the active profile (the person whose voice voice-overs use) and the other profiles on this Mac. A fresh Regista has none: create one with profile.create {name}. Returns {active, profiles}."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let store = ctx.services.profiles
        let all = try store.all()
        let active = store.activeID
        var r: [String: JSONValue] = ["profiles": .array(all.map { Profiles.summary($0, active: $0.profile.id == active) })]
        if let a = all.first(where: { $0.profile.id == active }) { r["active"] = Profiles.summary(a, active: true) } else { r["active"] = .null }
        if all.isEmpty { r["note"] = "no profile yet: ask the person their first name and run profile.create {name}; then voice.enroll.script to record their voice" }
        return .object(r)
    }
}

enum ProfileCreate: Command {
    static let id = "profile.create"
    static let summary = "Create the profile of the person using Regista (their first name). It becomes active when no profile is active; otherwise the person switches to it in the Regista app (switching is human-only). A profile starts with no voice: they record theirs with voice.enroll.*. Returns the profile and whether it is active."
    static let kind = CommandKind.session
    static let params: [ParamSpec] = [.required("name", .string, "The person's first name (also said in the consent sentence).")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let (e, activated) = try ctx.services.profiles.create(name: p.requiredString("name"))
        var r = Profiles.summary(e, active: activated).objectValue!
        r["folder"] = .string(e.directory.path)
        if !activated { r["note"] = "another profile is active: the person switches to this one in the Regista app (Settings → Profile)" }
        return .object(r)
    }
}

enum ProfileSwitch: Command {
    static let id = "profile.switch"
    static let summary = "Human only: make another profile active (the Regista app's Settings → Profile, or `regista-engine exec profile.switch '{\"id\": \"…\"}'` in the owner's terminal). Agents cannot call it: a voice belongs to its person."
    static let kind = CommandKind.session
    static let humanOnly = true
    static let params: [ParamSpec] = [.required("id", .string, "Profile id (profile.get).")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        try ctx.services.profiles.setActive(p.requiredString("id"))
        return ["active": .string(p.requiredString("id"))]
    }
}

enum ProfileAdopt: Command {
    static let id = "profile.adopt"
    static let summary = "Human only: bind a profile copied from another Mac to this one (the owner moving to a new Mac). Until then a copied profile is locked and its voice unusable."
    static let kind = CommandKind.session
    static let humanOnly = true
    static let params: [ParamSpec] = [.required("id", .string, "Profile id.")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let prof = try ctx.services.profiles.adopt(p.requiredString("id"))
        return ["id": .string(prof.id), "name": .string(prof.name), "locked": false]
    }
}

enum ProfileDelete: Command {
    static let id = "profile.delete"
    static let summary = "Human only: delete a profile and its voice data (recordings, clips, LoRAs) by moving its folder to the Trash."
    static let kind = CommandKind.session
    static let humanOnly = true
    static let params: [ParamSpec] = [.required("id", .string, "Profile id.")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let trashed = try ctx.services.profiles.delete(p.requiredString("id"))
        return ["deleted": .string(p.requiredString("id")), "trash": trashed.map { .string($0.path) } ?? .null]
    }
}

enum VoiceList: Command {
    static let id = "voice.list"
    static let summary = "The active profile's cloned voice before a voice-over: per language, LoRA or zero-shot, the tones it can say, the reference clips, the pronunciation lexicon and any missing file; plus whether the VoxCPM2 engine can run here. Only the active profile's voice is ever usable. Then render with generate.run {kind: \"voice\", prompt: <text>, options: {language, tone}}. Returns {profile, languages, engine}."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let config = ctx.services.config
        let store = ctx.services.profiles
        let provider = ctx.services.generators["voxcpm"]
        var engine: [String: JSONValue] = ["provider": "voxcpm", "tier": .string(ctx.services.tier.rawValue)]
        if let provider {
            let why = ctx.services.tier < provider.minimumTier ? "needs the \(provider.minimumTier.rawValue) tier" : provider.unavailableReason(.voice)
            engine["available"] = .bool(why == nil)
            if let why { engine["reason"] = .string(why) }
        } else {
            engine["available"] = false
            engine["reason"] = "this host has no voxcpm provider"
        }
        guard let entry = try store.active() else {
            return ["profile": .null, "languages": [], "engine": .object(engine),
                    "note": "no profile on this Mac: profile.create {name}, then the person records their own voice (voice.enroll.script)"]
        }
        if entry.locked {
            return ["profile": Profiles.summary(entry, active: true), "languages": [], "engine": .object(engine)]
        }
        for lang in entry.profile.voices.keys { _ = try? VoiceEnrollment.trainingStatus(entry, language: lang, profiles: store) }
        let fresh = try store.active() ?? entry
        let languages = fresh.profile.voices.keys.sorted().map { lang -> JSONValue in
            let s = fresh.profile.voices[lang]!
            var o: [String: JSONValue] = [
                "language": .string(lang),
                "mode": .string(s.lora == nil ? "zero-shot" : "lora"),
                "tones": .array(s.availableTones.map { .string($0) }),
                "refs": .array(s.refs.keys.sorted().map { .string($0) }),
            ]
            if let l = s.lora { o["lora"] = .string(config.url(l).path) }
            var problems = VoiceSetup.missingFiles(s, config: config)
            if s.refs[VoiceTone.neutral] == nil { problems.append("no neutral reference clip yet: add the neutral block (voice.enroll.add)") }
            let lexFile = store.lexiconFile(fresh, language: lang)
            do {
                let lex = try VoiceLexicon.load(lexFile)
                o["lexicon"] = ["entries": .number(Double(lex.entries.count)),
                                "pending": .number(Double(lex.entries.filter { $0.status == "pending" }.count)),
                                "file": .string(lexFile.path)]
            } catch {
                problems.append("\(error)")
            }
            o["ready"] = .bool(problems.isEmpty)
            if !problems.isEmpty { o["problems"] = .array(problems.map { .string($0) }) }
            return .object(o)
        }
        var r: [String: JSONValue] = ["profile": Profiles.summary(fresh, active: true), "languages": .array(languages), "engine": .object(engine)]
        if languages.isEmpty { r["note"] = .string("\(fresh.profile.name) has no voice yet: voice.enroll.script {language}") }
        return .object(r)
    }
}

enum VoiceEnrollScript: Command {
    static let id = "voice.enroll.script"
    static let summary = "Start recording the active profile's own voice: the recording script of a language (consent sentence with their name, then 7 tone blocks: neutral ~10 min, enthusiastic, serious, calm, playful, alarmed, sad ~2 min each), also written to script.md in the profile so they can read it from a phone. Recording advice: a phone with an external mic in a soft, quiet room is best; one file per block. Then voice.enroll.add per file. Returns {consent, blocks, file, minutes}."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [.required("language", .string, "fr, it, en or pt.")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let entry = try ctx.services.profiles.requireActive(command: id)
        let lang = p.requiredString("language").lowercased()
        let script = try RecordingScript.load(language: lang, config: ctx.services.config)
        let folder = VoiceEnrollment.languageFolder(entry, lang)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("script.md")
        try script.readable(name: entry.profile.name).write(to: file, atomically: true, encoding: .utf8)
        return ["profile": .string(entry.profile.name), "language": .string(lang), "consent": .string(script.consent(name: entry.profile.name)),
                "blocks": .array(script.blocks.map { ["tone": .string($0.tone), "lines": .array($0.lines.map { .string($0) })] }),
                "file": .string(file.path), "minutes": .number(script.minutes.rounded()),
                "steps": "1) the first file starts with the consent sentence, then the neutral block; 2) one file per other tone; 3) voice.enroll.add {path, language, tone} for each file (zero-shot works after the neutral one); 4) voice.enroll.train {language} for the best result (Pro tier, ~2 h)"]
    }
}

enum VoiceEnrollAdd: Command {
    static let id = "voice.enroll.add"
    static let summary = "Add one recording of a tone block to the active profile's voice: transcribes it, checks the consent sentence (first take of a language), finds each script line, cuts one clip per line heard and picks a reference clip for the tone. After the neutral block the language works at once in zero-shot. Takes a minute or two per 10 min of audio. Returns {accepted, total, missing, reference, minutes}."
    static let kind = CommandKind.session
    static let params: [ParamSpec] = [
        .required("path", .string, "The recording (any audio or video file: phone memo, Regista take)."),
        .required("language", .string, "Language of the script read."),
        .required("tone", .oneOf(RecordingScript.tones), "The block read in this file."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let s = ctx.services
        let lang = p.requiredString("language").lowercased()
        let script = try RecordingScript.load(language: lang, config: s.config)
        var engine = s.tier.defaultTranscriber(s.config)
        if s.transcribers[engine]?.unavailableReason() != nil || (s.transcribers[engine] as? WhisperXTranscriber)?.alignerReason(lang) != nil {
            engine = WhisperCppTranscriber.engineID
        }
        guard let transcriber = s.transcribers[engine] else { throw CommandError.notFound("\(id): no transcription engine") }
        let r = try VoiceEnrollment.add(path: p.requiredString("path"), language: lang, tone: p.requiredString("tone"), profiles: s.profiles,
                                        script: script, audio: s.audio, transcriber: transcriber, command: id)
        let entry = try s.profiles.requireActive(command: id)
        let clips = VoiceEnrollment.loadClips(VoiceEnrollment.languageFolder(entry, lang))
        return ["take": .string(r.take), "accepted": .number(Double(r.accepted)), "total": .number(Double(r.total)),
                "missing": .array(r.missing.prefix(20).map { .string($0) }), "reference": r.reference.map { .string($0) } ?? .null,
                "consent": .bool(r.consent), "languageMinutes": .number((clips.reduce(0) { $0 + $1.seconds } / 6).rounded() / 10),
                "note": .string(r.accepted < r.total * 7 / 10 ? "fewer than 70% of the lines were heard: re-record the missing ones (a new file of the same tone adds to this one)" : "ok")]
    }
}

enum VoiceEnrollStatus: Command {
    static let id = "voice.enroll.status"
    static let summary = "Where the active profile's voice stands per language: consent, minutes and clips per tone, zero-shot ready, training running / done / failed. A finished training registers its LoRA here. Returns {profile, languages}."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [.optional("language", .string, "One language (default: all recorded).")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let store = ctx.services.profiles
        let entry = try store.requireActive(command: id)
        let base = entry.directory.appendingPathComponent("voice")
        var langs = Set(entry.profile.voices.keys)
        for d in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] where !d.hasPrefix(".") && !d.hasSuffix(".json") { langs.insert(d) }
        if let l = p.string("language")?.lowercased() { langs = [l] }
        let out = try langs.sorted().map { lang -> JSONValue in
            let training = try VoiceEnrollment.trainingStatus(entry, language: lang, profiles: store)
            let fresh = try store.requireActive(command: id)
            let clips = VoiceEnrollment.loadClips(VoiceEnrollment.languageFolder(fresh, lang))
            var tones: [String: JSONValue] = [:]
            for t in RecordingScript.tones {
                let c = clips.filter { $0.tone == t }
                guard !c.isEmpty else { continue }
                tones[t] = ["clips": .number(Double(c.count)), "minutes": .number((c.reduce(0) { $0 + $1.seconds } / 6).rounded() / 10)]
            }
            let v = fresh.profile.voices[lang]
            let seconds = clips.reduce(0) { $0 + $1.seconds }
            return ["language": .string(lang), "consent": .bool(fresh.profile.consents?[lang] != nil), "tones": .object(tones),
                    "zeroShotReady": .bool(v?.refs[VoiceTone.neutral] != nil), "lora": v?.lora.map { .string($0) } ?? .null,
                    "trainedTones": .array((v?.lora == nil ? [] : (v?.tones ?? [VoiceTone.neutral])).map { .string($0) }),
                    "seconds": .number(seconds.rounded()), "minutes": .number((seconds / 6).rounded() / 10),
                    "trainMinimumSeconds": .number(VoiceEnrollment.minimumTrainingSeconds),
                    "trainEstimateMinutes": .number(VoiceEnrollment.estimatedTrainingMinutes(seconds: seconds).rounded()),
                    "training": training]
        }
        return ["profile": .string(entry.profile.name), "languages": .array(out), "trainer": VoiceEnrollTrain.availability(ctx)]
    }
}

enum VoiceEnrollTrain: Command {
    static let id = "voice.enroll.train"
    static let summary = "Train the active profile's voice LoRA for a language in the background (VoxCPM2 trainer, Pro tier): ~10 min of clips → about 2 h on an M5 Pro; a 2-minute pilot → ~10 min. Poll voice.enroll.status; when it ends the LoRA is used automatically. Returns {status, estimatedMinutes}."
    static let kind = CommandKind.session
    static let params: [ParamSpec] = [.required("language", .string, "Language to train.")]

    /// Whether this Mac can train ({available, tier, reason?: "tier" | "trainer" | "engine", detail?}); voice.enroll.status reports it.
    static func availability(_ ctx: CommandContext) -> JSONValue {
        let s = ctx.services
        let needed = EngineManifest.shared.minimumTier("voice-training")
        var o: [String: JSONValue] = ["tier": .string(s.tier.rawValue), "minimumTier": .string(needed.rawValue)]
        let trainer = s.config.url(s.config.voxcpmProject).appendingPathComponent("train_voxcpm_finetune.py")
        if s.tier < needed {
            o["reason"] = "tier"
            o["detail"] = .string("training needs the \(needed.rawValue) tier (\(Int(EngineManifest.shared.info(needed).ramGB)) GB); this Mac is \(s.tier.rawValue) — the voice keeps working in zero-shot from the reference clips")
        } else if !FileManager.default.fileExists(atPath: trainer.path) {
            o["reason"] = "trainer"
            o["detail"] = .string("trainer not found at \(trainer.path)")
        } else if let provider = s.generators["voxcpm"], let why = provider.unavailableReason(.voice) {
            o["reason"] = "engine"
            o["detail"] = .string(why)
        }
        o["available"] = .bool(o["reason"] == nil)
        return .object(o)
    }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let s = ctx.services
        if let why = availability(ctx)["detail"]?.stringValue { throw CommandError(.io, "\(id): \(why)") }
        return try VoiceEnrollment.train(language: p.requiredString("language").lowercased(), profiles: s.profiles, config: s.config, command: id)
    }
}

enum VoiceSay: Command {
    static let id = "voice.say"
    static let summary = "Voice-over in the active profile's own voice, placed on the timeline: splits the text into paragraphs (blank lines), renders each one whole (VoxCPM2, cached), lays them on the «Voce» audio track from `at` with `gap` seconds between paragraphs, and gives every clip word timings with the real spelling of the text, so captions.generate {sourceTrackId: <Voce track>} needs no transcription. Write numbers in words and brand names as they are spelled (the pronunciation lexicon fixes how they are said). One undo step. Returns the track, clips, total duration and the AI-disclosure reminder."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("text", .string, "What to say. Paragraphs separated by a blank line."),
        .required("language", .string, "Language of the text (fr, it, en, pt): the profile must have that voice (voice.list)."),
        .optional("tone", .string, "neutral (default) or a tone the voice has (voice.list)."),
        .optional("at", .time, "Timeline start (default: the end of the Voce track, or 0)."),
        .optional("gap", .number, "Seconds of silence between paragraphs (default 0.35)."),
        .optional("trackId", .string, "Audio track to use (default: the «Voce» track, created if missing)."),
        .optional("seed", .integer, "Seed of the first paragraph (+1 per paragraph); default derived from each paragraph's text."),
    ]

    /// The render request of paragraph `index` (voice.preview builds the same one, so its renders are reused here).
    static func request(_ text: String, index: Int, language: String, tone: String?, seed: Int?) -> GenerationRequest {
        var options = ["language": language]
        if let tone { options["tone"] = tone }
        return GenerationRequest(provider: "voxcpm", kind: .voice, prompt: text, seed: seed.map { $0 + index }, options: options)
    }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        _ = try ctx.requireProject()
        let paragraphs = VoiceScript.paragraphs(p.requiredString("text"))
        guard !paragraphs.isEmpty else { throw CommandError.invalid("\(id): text is empty") }
        let language = p.requiredString("language").lowercased()

        // Render (or reuse) every paragraph first: nothing is placed if one fails.
        var assets: [String] = []
        for (i, text) in paragraphs.enumerated() {
            let request = Self.request(text, index: i, language: language, tone: p.string("tone"), seed: p.int("seed"))
            let r = try Generate.execute(request, sourceAssetID: nil, approval: nil, wait: true, keepRunning: false, &ctx, command: id)
            guard let a = r["assetId"]?.stringValue else { throw CommandError(.io, "\(id): paragraph \(i + 1) produced no asset") }
            assets.append(a)
        }

        var project = try ctx.requireProject()
        // Word timings with the real spelling (kept on the asset: a cached render reuses them).
        let s = ctx.services
        var engine = s.tier.defaultTranscriber(s.config)
        if s.transcribers[engine]?.unavailableReason() != nil || (s.transcribers[engine] as? WhisperXTranscriber)?.alignerReason(language) != nil {
            engine = WhisperCppTranscriber.engineID
        }
        for (i, aid) in assets.enumerated() {
            let k = project.assets.firstIndex { $0.id == aid }!
            if project.assets[k].analysis?.transcript != nil { continue }
            guard let transcriber = s.transcribers[engine], transcriber.unavailableReason() == nil else { break }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("regista-vo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let speech = tmp.appendingPathComponent("speech.wav")
            try s.audio.extractAudio(from: URL(fileURLWithPath: project.assets[k].path), channels: 1, speech: speech,
                                     working: tmp.appendingPathComponent("working.wav"))
            let heard = try transcriber.transcribe(speech, language: language).words
            let words = VoiceScript.timedWords(paragraphs[i], heard: heard, duration: project.assets[k].duration.seconds)
            var analysis = project.assets[k].analysis ?? AssetAnalysis()
            analysis.transcript = Transcript(engine: transcriber.id, model: "\(transcriber.model)+script", language: language, words: words)
            project.assets[k].analysis = analysis
        }

        // The Voce track and the clips, back to back with the gaps.
        let rate = project.settings.frameRate
        let t: Int
        if let tid = p.string("trackId") { t = try Timeline.trackIndex(tid, in: project) }
        else if let i = project.tracks.firstIndex(where: { $0.kind == .audio && $0.name == "Voce" && !$0.locked }) { t = i }
        else {
            project.tracks.append(Track(id: project.makeID("t"), kind: .audio, name: "Voce"))
            t = project.tracks.count - 1
        }
        guard project.tracks[t].kind == .audio else { throw CommandError.invalid("\(id): \(project.tracks[t].id) is not an audio track") }
        var cursor = (p.time("at") ?? project.tracks[t].clips.map(\.end).max() ?? .zero).snapped(to: rate)
        let gap = MediaTime(seconds: max(0, p.number("gap") ?? 0.35))
        var placed: [JSONValue] = []
        let fade = MediaTime(seconds: 0.01)
        for aid in assets {
            let asset = project.asset(aid)!
            let end = cursor + asset.duration
            if let other = project.tracks[t].overlap(start: cursor, end: end) {
                throw CommandError.conflict("\(id): \(project.tracks[t].name) is occupied at \(cursor.seconds) s by clip \(other.id): pass `at` or another trackId")
            }
            var c = Clip(id: project.makeID("c"), assetID: aid, sourceIn: .zero, sourceOut: asset.duration, start: cursor)
            c.fadeIn = fade
            c.fadeOut = fade
            project.tracks[t].clips.append(c)
            placed.append(["clipId": .string(c.id), "assetId": .string(aid), "start": ProjectState.seconds(cursor),
                           "duration": ProjectState.seconds(asset.duration), "text": .string(String(asset.generated?.prompt.prefix(80) ?? ""))])
            cursor = (end + gap).snapped(to: rate)
        }
        project.tracks[t].clips.sort { $0.start < $1.start }
        ctx.project = project
        return ["trackId": .string(project.tracks[t].id), "clips": .array(placed), "paragraphs": .number(Double(paragraphs.count)),
                "end": ProjectState.seconds(cursor - gap),
                "captions": .string("captions.generate {sourceTrackId: \"\(project.tracks[t].id)\"}"),
                "aiDisclosure": "AI-generated voice: say so in the post description (EU AI Act art. 50)."]
    }
}

enum VoicePreview: Command {
    static let id = "voice.preview"
    static let summary = "Hear a voice-over before placing it: renders the paragraphs of `text` (or only paragraph `paragraph`) in the active profile's voice, without touching the project or the timeline, and returns the audio files. voice.say with the same text, language and tone reuses these renders (nothing is rendered twice). `estimate: true` renders nothing: the paragraphs with their estimated duration and whether each is already rendered. Returns {paragraphs: [{index, text, file?, seconds, cached}], seconds, renderSeconds}."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("text", .string, "What to say. Paragraphs separated by a blank line (as voice.say)."),
        .required("language", .string, "Language of the text (fr, it, en, pt)."),
        .optional("tone", .string, "neutral (default) or a tone the voice has (voice.list)."),
        .optional("seed", .integer, "As voice.say."),
        .optional("paragraph", .integer, "Only this paragraph (0-based)."),
        .optional("estimate", .boolean, "Render nothing: estimated durations and what is already rendered."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let paragraphs = VoiceScript.paragraphs(p.requiredString("text"))
        guard !paragraphs.isEmpty else { throw CommandError.invalid("\(id): text is empty") }
        let language = p.requiredString("language").lowercased()
        let only = p.int("paragraph")
        if let only, !paragraphs.indices.contains(only) {
            throw CommandError.invalid("\(id): paragraph \(only) does not exist (the text has \(paragraphs.count))")
        }
        let provider = try Generate.provider("voxcpm", ctx, command: id)
        try Generate.check(provider, .voice, ctx, command: id)
        var items: [JSONValue] = [], speech = 0.0, toRender = 0, toRenderSpeech = 0.0
        for (i, text) in paragraphs.enumerated() where only == nil || only == i {
            let request = try Generate.prepare(provider, VoiceSay.request(text, index: i, language: language, tone: p.string("tone"), seed: p.int("seed")),
                                               command: id)
            let dir = Generate.jobDir(ctx, provider.id, try request.hash())
            let estimated = VoiceScript.estimatedSeconds(text)
            var item: [String: JSONValue] = ["index": .number(Double(i)), "text": .string(text)]
            var out = dir.output
            item["cached"] = .bool(out != nil)
            if out == nil, p.bool("estimate") != true {
                if FileManager.default.fileExists(atPath: dir.stdoutFile.path), dir.exitStatus == nil {
                    throw CommandError.conflict("\(id): paragraph \(i + 1) is already being rendered: try again when it is done")
                }
                try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try enc.encode(request).write(to: dir.url.appendingPathComponent("request.json"))
                try dir.launch(provider.process(request, job: dir.url), wait: true, cancellation: ctx.services.cancellation)
                provider.finish(keepRunning: false)
                if dir.exitStatus != 0, ctx.services.cancellation?.isCancelled == true { throw CommandError(.io, "\(id): cancelled") }
                guard dir.exitStatus == 0 else {
                    throw CommandError(.io, "\(id): \(provider.id) failed on paragraph \(i + 1) (exit \(dir.exitStatus.map(String.init) ?? "?")):\n\(dir.stderrTail)")
                }
                out = try Generate.collect(provider, request, dir, cost: 0)
            }
            var seconds = estimated
            if let o = out {
                item["file"] = .string(o.file)
                if let d = try? ctx.prober.probe(URL(fileURLWithPath: o.file)).duration.seconds, d > 0 { seconds = d }
            } else {
                toRender += 1
                toRenderSpeech += estimated
            }
            item["seconds"] = .number((seconds * 10).rounded() / 10)
            speech += seconds
            items.append(.object(item))
        }
        return ["paragraphs": .array(items), "seconds": .number((speech * 10).rounded() / 10),
                "renderSeconds": .number(VoiceScript.estimatedRenderSeconds(speech: toRenderSpeech, paragraphs: toRender).rounded())]
    }
}

enum VoiceLexiconCommand: Command {
    static let id = "voice.lexicon"
    static let summary = "The active profile's pronunciation lexicon for a language: how words the model mispronounces must be written for it (brand names keep their original pronunciation, never translated or adapted). Lists entries; `add` {word, say} with status confirmed (approved by ear) or pending (chosen by a Whisper read-back, waiting for the person's ear); `remove` a word. Applied only to the text sent to the model; captions keep the real spelling. Returns the entries."
    static let kind = CommandKind.session
    static let params: [ParamSpec] = [
        .required("language", .string, "fr, it, en, pt…"),
        .optional("add", .object, "{\"word\": \"WeSites\", \"say\": \"We Sites\"}."),
        .optional("status", .oneOf(["confirmed", "pending"]), "Status of the added entry (default pending: confirmed only after the person listened)."),
        .optional("remove", .string, "Word to remove."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let store = ctx.services.profiles
        let entry = try store.requireActive(command: id)
        let lang = p.requiredString("language").lowercased()
        let file = store.lexiconFile(entry, language: lang)
        var lex = try VoiceLexicon.load(file)
        var changed = false
        if let add = p.json("add")?.objectValue {
            guard let word = add["word"]?.stringValue?.trimmingCharacters(in: .whitespaces), !word.isEmpty,
                  let say = add["say"]?.stringValue?.trimmingCharacters(in: .whitespaces), !say.isEmpty else {
                throw CommandError.invalid("\(id): add is {word, say}")
            }
            lex.entries.removeAll { $0.word == word }
            lex.entries.append(.init(word: word, say: say, status: p.string("status") ?? "pending"))
            changed = true
        }
        if let w = p.string("remove") {
            let before = lex.entries.count
            lex.entries.removeAll { $0.word == w }
            guard lex.entries.count < before else { throw CommandError.notFound("\(id): no entry \(w)") }
            changed = true
        }
        if changed {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(lex).write(to: file, options: .atomic)
        }
        return ["language": .string(lang), "file": .string(file.path),
                "entries": .array(lex.entries.map { ["word": .string($0.word), "say": .string($0.say), "status": .string($0.status ?? "confirmed")] })]
    }
}
