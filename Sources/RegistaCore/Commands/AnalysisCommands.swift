import Foundation

/// Shared helpers of the engine-backed commands.
enum Analysis {
    static func assetIndex(_ id: String, in project: Project, command: String) throws -> Int {
        guard let i = project.assets.firstIndex(where: { $0.id == id }) else {
            let ids = project.assets.map(\.id).joined(separator: ", ")
            throw CommandError.notFound("\(command): no asset '\(id)' (assets: \(ids.isEmpty ? "none" : ids))")
        }
        return i
    }

    /// The asset's extracted audio, extracting it first when missing (or when its files are gone).
    static func ensureAudio(_ index: Int, _ project: inout Project, _ ctx: inout CommandContext, force: Bool = false) throws -> ExtractedAudio {
        let asset = project.assets[index]
        if !force, let a = asset.analysis?.audio,
           FileManager.default.fileExists(atPath: a.speech), FileManager.default.fileExists(atPath: a.working) {
            return a
        }
        guard let info = asset.audio else { throw CommandError.conflict("\(asset.name) has no audio track") }
        let dir = try ctx.mediaDirectory()
        let audio = ExtractedAudio(speech: dir.appendingPathComponent("\(asset.id)-speech16k.wav").path,
                                   working: dir.appendingPathComponent("\(asset.id)-work48k.wav").path)
        do {
            try CommandJob.stage(0, 1, media: asset.duration.seconds) {
                try ctx.services.audio.extractAudio(from: URL(fileURLWithPath: asset.path), channels: info.channels,
                                                    speech: URL(fileURLWithPath: audio.speech), working: URL(fileURLWithPath: audio.working))
            }
        } catch {
            // Cancelled or failed half way: no partial wav is left behind (the next run would take it for a good one).
            for f in [audio.speech, audio.working] { try? FileManager.default.removeItem(atPath: f) }
            throw error
        }
        project.assets[index].analysis = project.assets[index].analysis ?? AssetAnalysis()
        project.assets[index].analysis?.audio = audio
        return audio
    }

    static func transcript(of asset: MediaAsset, command: String) throws -> Transcript {
        guard let t = asset.analysis?.transcript else {
            throw CommandError.conflict("\(command): \(asset.id) has no transcript — run transcript.run first")
        }
        return t
    }

    static func seconds(_ x: Double, places: Double = 1000) -> JSONValue { .number((x * places).rounded() / places) }

    static func wordJSON(_ w: Word) -> JSONValue {
        var o: [String: JSONValue] = ["text": .string(w.text), "start": seconds(w.start.seconds), "end": seconds(w.end.seconds)]
        if let p = w.probability { o["p"] = seconds(p) }
        return .object(o)
    }
}

extension CommandContext {
    /// Runs another command inside this one (same snapshot, so the whole thing is one undo step)
    /// and records it, so automation is always expressed as ordinary commands.
    @discardableResult
    mutating func perform(_ command: any Command.Type, _ params: JSONValue, log: inout [JSONValue]) throws -> JSONValue {
        let result = try command.run(try CommandParams(validating: params, for: command.descriptor), &self)
        log.append(["command": .string(command.id), "params": params])
        return result
    }
}

enum EnginesStatus: Command {
    static let id = "engines.status"
    static let summary = "Check what this Mac can run before analysing: RAM tier (\(EngineManifest.shared.tiers.map { "\($0.id) \(Int($0.ramGB)) GB" }.joined(separator: " / "))+), each engine's path, availability and checksum (ffmpeg, whisper.cpp, WhisperX, DeepFilterNet, Vision, compositor, Blender, HyperFrames, SFX library, the generation providers ComfyUI / Higgsfield), and the default transcription engine (an engine installed in the engines folder also says scriptsCurrent: false, with scriptsDiffer, when its helper scripts differ from the app's and could not be replaced), plus the build id (when served by the app through regista-mcp: appBuild, mcpBuild and buildWarning when they differ). Every entry also carries the engine manifest's facts (name, unlocks, minRamGB, diskGB, licence, install method, state installed / missing / notChecked / planned, tierReason when the tier is too low); `components` lists the rest of the manifest (models, aligners, build tools, voice training, ComfyUI models, planned engines). Returns that report."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("verify", .boolean, "Also hash the large model files (slow, ~2 s per GB). Binaries are always hashed."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let s = ctx.services, c = s.config
        let verify = p.bool("verify") ?? false
        let fm = FileManager.default
        let manifest = EngineManifest.shared
        // The manifest facts the Motori screen shows, added to every entry (state: installed / missing / notChecked / planned).
        func facts(_ id: String, state: String, into o: inout [String: JSONValue]) {
            guard let m = manifest.entry(id) else { return }
            o["name"] = .string(m.name)
            o["unlocks"] = .array(m.unlocks.map { .string($0) })
            o["minRamGB"] = m.minRamGB.map { .number($0) } ?? .null
            if let r = m.ramInUseGB { o["ramInUseGB"] = .number(r) }
            o["diskGB"] = manifest.diskBytes(m).map { .number((Double($0) / 1e7).rounded() / 100) } ?? .null
            o["licence"] = .string(m.licence)
            if m.nonCommercial { o["nonCommercial"] = true }
            if m.paid { o["paid"] = true }
            o["install"] = .string(m.install.method)
            if m.optional { o["optional"] = true }
            o["state"] = .string(state)
            if let t = manifest.tier(of: m), s.tier < t {
                o["tierReason"] = .string("needs the \(t.rawValue) tier (\(Int(manifest.info(t).ramGB)) GB); this Mac: \(s.tier.rawValue)")
            }
        }
        func entry(_ id: String, _ role: String, path: String?, available: Bool, reason: String? = nil,
                   expected: String? = nil, hash: Bool = false, installed: Bool? = nil) -> JSONValue {
            let tier = manifest.minimumTier(id)
            var o: [String: JSONValue] = ["id": .string(id), "role": .string(role), "minimumTier": .string(tier.rawValue),
                                          "available": .bool(available), "enabled": .bool(available && s.tier >= tier)]
            if let path { o["path"] = .string(EngineConfig.expand(path)) }
            // Shipped inside the app (#107): part of the app, nothing to install. Its bytes carry the app's signature, so a
            // shipped deep-filter is not compared with the release binary's hash.
            let shipped = path.map { ShippedTools.isShipped($0) } ?? false
            if shipped { o["shipped"] = true }
            let expected = shipped ? nil : expected
            if let reason { o["reason"] = .string(reason) }
            if hash, let path, available, let digest = try? FileDigest.sha256(c.url(path)) {
                o["sha256"] = .string(digest)
                if let expected { o["verified"] = .bool(digest == expected) }
            } else if let expected {
                o["expectedSha256"] = .string(expected)
            }
            facts(id, state: (installed ?? available) ? "installed" : "missing", into: &o)
            // The build inside the app, not the installable one (#114).
            if shipped, let sh = manifest.entry(id)?.shipped {
                o["licence"] = .string(sh.licence)
                o["diskGB"] = .number((Double(sh.bytes) / 1e7).rounded() / 100)
            }
            return .object(o)
        }
        let whisper = s.transcribers[WhisperCppTranscriber.engineID]
        let whisperX = s.transcribers[WhisperXTranscriber.engineID]
        let ffmpegOK = fm.isExecutableFile(atPath: EngineConfig.expand(c.ffmpeg))
        let modelOK = fm.fileExists(atPath: EngineConfig.expand(c.whisperModel))
        let cleanReason = s.cleaner.unavailableReason()
        let hyperframes = GraphicsEngines.hyperframes(c)
        let engines: [JSONValue] = [
            entry("ffmpeg", "audio extraction, voice chain, loudness", path: c.ffmpeg, available: ffmpegOK),
            entry("ffprobe", "media metadata", path: c.ffprobe, available: fm.isExecutableFile(atPath: EngineConfig.expand(c.ffprobe))),
            entry("whisper.cpp", "transcription (DTW word timings)", path: c.whisperCpp,
                  available: whisper?.unavailableReason() == nil, reason: whisper?.unavailableReason(), hash: true),
            entry("whisper-model", "ggml large-v3-turbo", path: c.whisperModel, available: modelOK,
                  expected: c.whisperModelSha256, hash: verify),
            entry("whisperx", "transcription (wav2vec2 forced alignment, Python/uv)", path: c.whisperXScript,
                  available: whisperX?.unavailableReason() == nil, reason: whisperX?.unavailableReason()),
            entry("deepfilternet", "voice denoise (DeepFilterNet3)", path: c.deepFilter,
                  available: cleanReason == nil, reason: cleanReason, expected: c.deepFilterSha256, hash: true),
            entry("vision", "face tracking (Apple Vision)", path: nil, available: s.faces != nil,
                  reason: s.faces == nil ? "this host was built without RegistaEngines" : nil),
            entry("compositor", "titles, overlays, effects (Core Image / Core Text)", path: nil, available: s.renderer != nil,
                  reason: s.renderer == nil ? "this host was built without RegistaEngines" : nil),
            entry("blender", "3D titles (graphics.blenderTitle, EEVEE, Blender \(manifest.artifact("blender")!.version))", path: c.blender,
                  available: fm.isExecutableFile(atPath: EngineConfig.expand(c.blender)), reason: fm.isExecutableFile(atPath: EngineConfig.expand(c.blender)) ? nil : "not installed"),
            // Runs through a Node.js found on this Mac (npx) too, but only the pinned CLI in the engines folder is installed (#11).
            entry("hyperframes", "HTML motion graphics (graphics.hyperframes, hyperframes \(EngineConfig.hyperframesVersion)\(hyperframes?.source == "npx" ? " through npx" : ""), scripts off)",
                  path: hyperframes.map { $0.source == "installed" ? c.hyperframes : $0.executable.path },
                  available: hyperframes != nil,
                  reason: hyperframes == nil ? "not installed (Node.js and the pinned HyperFrames CLI: " + ReleaseBuild.sourceHint("scripts/install.sh --only hyperframes", release: "Settings › Motori") + ")"
                      : GraphicsEngines.hyperframesInstalled(c) ? nil
                      : "not installed: runs through npx with a Node.js found on this Mac, not the pinned copy (" + ReleaseBuild.sourceHint("scripts/install.sh --only hyperframes", release: "Settings › Motori") + ")",
                  installed: GraphicsEngines.hyperframesInstalled(c)),
            entry("sfx-bank", "sound effects made in code (earshot, MIT), shipped with Regista", path: SoundLibrary.bankDirectory.path,
                  available: !SoundLibrary.bank().isEmpty, reason: SoundLibrary.bank().isEmpty ? "the app was built without Resources/SFX" : nil),
            entry("sfx-library", "your own sound effects (sfx.library, next to the bank)", path: c.sfxLibrary,
                  available: fm.fileExists(atPath: EngineConfig.expand(c.sfxLibrary))),
        ] + s.generators.values.sorted { $0.id < $1.id }.map { g in
            // Check each provider on a kind it actually makes (VoxCPM: voice only).
            let why = g.unavailableReason(g.models.first?.kind ?? .image)
            var e = entry(g.id, g.paid ? "generation, paid (\(g.title); budget left: \((try? GenerationBudget(directory: s.generationState).remaining(g.id)).map(String.init) ?? "?"))"
                                      : "generation (\(g.title): generate.run / generate.upscale)",
                          path: nil, available: why == nil, reason: why)
            if g.id == "voxcpm" {
                e = entry(g.id, "voice-over in the active profile's own voice (generate.run kind voice, voice.*, profile.*)",
                          path: c.voxcpmProject, available: why == nil, reason: why)
            }
            if g.id == "comfyui" {
                // Where ComfyUI is: the folder (or start command) Regista starts when nothing answers at its address.
                let location = (g as? ComfyUIProvider)?.location ?? s.comfyLocation
                e = entry(g.id, "generation (\(g.title): Z-Image stills, Wan 2.2 clips, ACE-Step music, ESRGAN/RIFE upscale; server \(location.server.absoluteString))",
                          path: location.start?.path, available: why == nil, reason: why)
            }
            return e
        }
        // The rest of the manifest: what the entries above do not report (models, aligners, tools, capabilities, planned).
        let reported = Set(engines.compactMap { $0["id"]?.stringValue })
        let components: [JSONValue] = manifest.entries.filter { !reported.contains($0.id) }.map { m in
            var o: [String: JSONValue] = ["id": .string(m.id), "role": .string(m.role)]
            if let t = manifest.tier(of: m) { o["minimumTier"] = .string(t.rawValue) }
            var probe = Self.probe(m, s)
            if probe.state == "notNeeded" { probe.state = "installed"; o["notNeeded"] = true }
            if let path = probe.path { o["path"] = .string(EngineConfig.expand(path)) }
            facts(m.id, state: probe.state, into: &o)
            o["enabled"] = .bool(probe.state == "installed" && o["tierReason"] == nil)
            let reason = m.planned ? "planned, not built yet"
                : probe.state == "missing" ? "not installed" + (m.install.method == "firstUse" ? " (downloaded on first use)" : "")
                : probe.state == "notChecked" ? "Regista cannot check this one yet" : nil
            if let reason { o["reason"] = .string(reason) }
            return .object(o)
        }
        // An engine installed in the engines folder whose helper scripts are the app's own (#61): scriptsCurrent, and the
        // ones that differ (replaced at launch and when the engine is used; still there means they could not be written).
        func scripts(_ list: [JSONValue]) -> [JSONValue] {
            list.map { v in
                guard let folder = s.enginesFolder, case .object(var o) = v, let id = o["id"]?.stringValue,
                      let m = manifest.entry(id), EngineScripts.installed(m, in: folder) else { return v }
                let differ = EngineScripts.differing(m, in: folder)
                o["scriptsCurrent"] = .bool(differ.isEmpty)
                if !differ.isEmpty { o["scriptsDiffer"] = .array(differ.map { .string($0) }) }
                return .object(o)
            }
        }
        var result: [String: JSONValue] = [
            "tier": .string(s.tier.rawValue),
            "memoryGB": .number((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
            "configFile": .string(EngineConfig.defaultFile.path),
            "configLoaded": .bool(fm.fileExists(atPath: EngineConfig.defaultFile.path) && s.configWarning == nil),
            "defaults": ["transcription": .string(s.defaultTranscription().engine)],
            "engines": .array(scripts(engines)),
            "components": .array(scripts(components)),
        ]
        if let w = s.configWarning { result["configWarning"] = .string(w) }
        // The build of the process that ran this (the app when attached; regista-mcp adds its own and compares).
        result.merge(BuildStamp.current.json) { _, new in new }
        return .object(result)
    }

    /// Where a manifest component lives on this Mac and whether it is there (installed / missing / notChecked / planned).
    static func probe(_ m: EngineManifest.Entry, _ s: EngineServices) -> (path: String?, state: String) {
        let c = s.config, fm = FileManager.default
        if m.planned { return (nil, "planned") }
        func file(_ path: String) -> (path: String?, state: String) {
            (path, fm.fileExists(atPath: EngineConfig.expand(path)) ? "installed" : "missing")
        }
        let wx = c.whisperXProject, brew = (EngineConfig.expand(c.ffmpeg) as NSString).deletingLastPathComponent
        let lockFile = { (id: String) in EngineManifest.shared.artifacts(of: m).first { $0.id == id }.map { ($0.url as NSString).lastPathComponent } ?? id }
        switch m.id {
        // Only builds whisper.cpp: not needed when the app ships whisper-cli (#107).
        case "cmake": return ShippedTools.isShipped(c.whisperCpp) ? (nil, "notNeeded") : file("\(brew)/cmake")
        case "uv": return file(c.uv)
        case "speech": return (nil, s.speech != nil ? "installed" : "missing")
        case "faster-whisper-model": return file("\(wx)/models/ct2-whisper-large-v3-turbo/model.bin")
        case "aligner-it": return file("\(wx)/models/torchaudio/\(lockFile("wav2vec2-voxpopuli-it"))")
        case "aligner-fr": return file("\(wx)/models/torchaudio/\(lockFile("wav2vec2-voxpopuli-fr"))")
        case "aligner-en", "aligner-pt": return file("\(wx)/\(WhisperXTranscriber.aligners[String(m.id.dropFirst("aligner-".count))]!)")
        case "punkt-tab": return file("\(wx)/.venv/nltk_data/tokenizers/punkt_tab")
        case "voxcpm-weights": return file("\(c.voxcpmModel)/model.safetensors")
        case "voxcpm": return file(c.voxcpmScript)
        case "voice-training": return file("\(c.voxcpmProject)/train_voxcpm_finetune.py")
        case "comfyui": return (s.comfyLocation.start?.path, s.comfyLocation.start != nil ? "installed" : "missing")
        case "shotcut":
            let apps = ["/Applications/Shotcut.app", "~/Applications/Shotcut.app"]
            return file(apps.first { fm.fileExists(atPath: EngineConfig.expand($0)) } ?? apps[0])
        // The pinned build in the engines folder (or the one engines.json names); a system node is not installed (#11).
        case "node": return (c.node, GraphicsEngines.nodeInstalled(c) ? "installed" : "missing")
        default: return (nil, "notChecked")   // ComfyUI model families (their folders are the user's setup), cloud
        }
    }
}

enum MediaExtractAudio: Command {
    static let id = "media.extractAudio"
    static let summary = "Step 1 of the analysis: extract an asset's audio — a 16 kHz mono wav (speech engines) and a 48 kHz mono working wav (voice chain), sample-aligned with the video, into the project's media folder. Run it right after media.import. Returns the wav paths."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("assetId", .string, "Asset with an audio track."),
        .optional("force", .boolean, "Extract again even if the files exist (default false)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let i = try Analysis.assetIndex(p.requiredString("assetId"), in: project, command: id)
        let audio = try Analysis.ensureAudio(i, &project, &ctx, force: p.bool("force") ?? false)
        ctx.project = project
        let speech = try WAVAudio.read(URL(fileURLWithPath: audio.speech))
        return ["assetId": .string(project.assets[i].id),
                "speech": ["path": .string(audio.speech), "sampleRate": .number(Double(speech.sampleRate)),
                           "duration": Analysis.seconds(speech.duration)],
                "working": ["path": .string(audio.working), "sampleRate": 48000]]
    }
}

enum MediaMeasureLoudness: Command {
    static let id = "media.measureLoudness"
    static let summary = "Measure EBU R128 loudness (integrated LUFS, true peak dBTP, LRA) of an asset's audio, or of a track as it plays (its clips one after the other). Mono is measured as dual-mono stereo, like the export. Returns the measurement."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("assetId", .string, "Measure this asset's whole audio."),
        .optional("trackId", .string, "Measure this audio track's clips in timeline order."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        var spans: [AudioSpan] = []
        if let trackID = p.string("trackId") {
            let t = try Timeline.trackIndex(trackID, in: project, editable: false)
            for clip in project.tracks[t].clips {
                guard let a = project.asset(clip.assetID), let info = a.audio else { continue }
                spans.append(AudioSpan(url: URL(fileURLWithPath: a.path), start: clip.sourceIn, end: clip.sourceOut, channels: info.channels))
            }
            guard !spans.isEmpty else { throw CommandError.conflict("\(id): track \(trackID) has no audio clips") }
        } else if let assetID = p.string("assetId") {
            let a = project.assets[try Analysis.assetIndex(assetID, in: project, command: id)]
            guard let info = a.audio else { throw CommandError.conflict("\(id): \(a.name) has no audio") }
            spans = [AudioSpan(url: URL(fileURLWithPath: a.path), channels: info.channels)]
        } else {
            throw CommandError.invalid("\(id): pass assetId or trackId")
        }
        let l = try ctx.services.audio.loudness(of: spans)
        guard case .object(var o) = l.json else { return l.json }
        o["spans"] = .number(Double(spans.count))
        return .object(o)
    }
}

enum TranscriptRun: Command {
    static let id = "transcript.run"
    static let summary = "Transcribe an asset with word timings (extracts its audio first if needed): needed by takes.list, captions and text-based editing. Engines: whisper.cpp (Base tier) or whisperx (Medium tier and up, more precise word timings); the default depends on the RAM tier (whisper.cpp, with a note, when the tier's engine is not installed). Cached by audio hash. Returns word count, engine, the text and a note when the engine was not the one expected."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("assetId", .string, "Asset to transcribe."),
        .optional("engine", .oneOf([WhisperCppTranscriber.engineID, WhisperXTranscriber.engineID]), "Transcription engine (default: per tier)."),
        .optional("language", .string, "Spoken language code (default \"it\"); \"auto\" detects it (whisper.cpp; with whisperx the language is detected first, then aligned)."),
        .optional("cache", .boolean, "Reuse a cached transcript of the same audio and engine (default true)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let i = try Analysis.assetIndex(p.requiredString("assetId"), in: project, command: id)
        let s = ctx.services
        // No engine asked for: the tier's default, or whisper.cpp when the default is not installed here (#112).
        let fallback = s.defaultTranscription()
        var engine = p.string("engine") ?? fallback.engine
        var note = p.string("engine") == nil ? fallback.note : nil
        guard var transcriber = s.transcribers[engine] else { throw CommandError.notFound("\(id): no engine '\(engine)'") }
        let needed = EngineServices.minimumTier(transcriber: engine)
        guard s.tier >= needed else {
            throw CommandError.conflict("\(id): \(engine) needs the \(needed.rawValue) tier, this Mac is \(s.tier.rawValue) — use whisper.cpp")
        }
        if let reason = transcriber.unavailableReason() { throw CommandError(.io, "\(id): \(reason)") }
        // In a job (the app's Trascrivi): extracting the audio is the first tenth, the transcription the rest.
        let audio = try CommandJob.stage(0, 0.1) { try Analysis.ensureAudio(i, &project, &ctx) }
        var language = p.string("language") ?? "it"
        let speechURL = URL(fileURLWithPath: audio.speech)
        if language == "auto", engine != WhisperCppTranscriber.engineID {
            // WhisperX aligns with one model per language: detect it first with whisper.cpp.
            guard let detector = s.transcribers[WhisperCppTranscriber.engineID] as? WhisperCppTranscriber, detector.unavailableReason() == nil else {
                throw CommandError.invalid("\(id): \(engine) cannot detect the language here — pass language (it, fr, en, pt…)")
            }
            language = try CommandJob.stage(0.1, 0.15) { try detector.detectLanguage(speechURL) }
        }
        // WhisperX aligns with the pinned aligner of the language; without it (Italian / French are opt-in, #20) the
        // default falls back to whisper.cpp and says so, an explicit engine "whisperx" fails with the reason.
        if let wx = transcriber as? WhisperXTranscriber, let why = wx.alignerReason(language) {
            guard p.string("engine") == nil, let cpp = s.transcribers[WhisperCppTranscriber.engineID], cpp.unavailableReason() == nil else {
                throw CommandError(.io, "\(id): \(why)")
            }
            engine = WhisperCppTranscriber.engineID
            transcriber = cpp
            note = "transcribed with whisper.cpp (word timings less precise): \(why)"
        }

        let started = Date()
        let speech = URL(fileURLWithPath: audio.speech)
        let cacheDir = s.config.url(s.config.cacheDirectory).appendingPathComponent("transcripts")
        let key = "\(try FileDigest.sha256(speech))-\(engine)-\(transcriber.model)-\(language)"
        let cacheFile = cacheDir.appendingPathComponent(key + ".json")
        var transcript: Transcript?
        var cached = false
        if p.bool("cache") ?? true, let data = FileManager.default.contents(atPath: cacheFile.path) {
            transcript = try? JSONDecoder().decode(Transcript.self, from: data)
            cached = transcript != nil
        }
        if transcript == nil {
            let t = try CommandJob.stage(0.15, 1) { try transcriber.transcribe(speech, language: language) }
            guard !t.words.isEmpty else { throw CommandError(.io, "\(id): \(engine) returned no words") }
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? JSONEncoder().encode(t).write(to: cacheFile, options: .atomic)
            transcript = t
        }
        let t = transcript!
        project.assets[i].analysis?.transcript = t
        ctx.project = project
        var result: [String: JSONValue] = [
            "assetId": .string(project.assets[i].id), "engine": .string(t.engine), "model": .string(t.model),
            "language": .string(t.language), "words": .number(Double(t.words.count)), "cached": .bool(cached),
            "seconds": Analysis.seconds(Date().timeIntervalSince(started), places: 10), "text": .string(t.text)]
        if let note { result["note"] = .string(note) }
        return .object(result)
    }
}

enum TranscriptGet: Command {
    static let id = "transcript.get"
    static let summary = "Read the transcript of an asset: words with start/end seconds (asset/source time) and the full text, optionally only [from, to]. Use it to find a stumble or a misheard name. Returns {words, text}."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("assetId", .string, "Transcribed asset."),
        .optional("from", .time, "Only words starting at or after this time."),
        .optional("to", .time, "Only words ending at or before this time."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let asset = project.assets[try Analysis.assetIndex(p.requiredString("assetId"), in: project, command: id)]
        let t = try Analysis.transcript(of: asset, command: id)
        let from = p.time("from") ?? .zero, to = p.time("to")
        let words = t.words.filter { $0.start >= from && (to == nil || $0.end <= to!) }
        return ["assetId": .string(asset.id), "engine": .string(t.engine), "model": .string(t.model),
                "language": .string(t.language), "count": .number(Double(words.count)),
                "text": .string(words.map(\.text).joined(separator: " ")), "words": .array(words.map(Analysis.wordJSON))]
    }
}

enum TranscriptEvaluate: Command {
    static let id = "transcript.evaluate"
    static let summary = "Diagnostics: word-timing accuracy of an asset's transcript against the audio energy envelope at every pause (word starts vs speech onsets, ends vs offsets). For tuning engines, not needed in a normal edit. Returns medians and percentiles in ms."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("assetId", .string, "Transcribed asset."),
        .optional("minGap", .number, "Shortest pause considered, seconds (default 0.25)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let asset = project.assets[try Analysis.assetIndex(p.requiredString("assetId"), in: project, command: id)]
        let t = try Analysis.transcript(of: asset, command: id)
        guard let speech = asset.analysis?.audio?.speech else { throw CommandError.conflict("\(id): run media.extractAudio first") }
        let r = TimingEvaluation.evaluate(words: t.words, envelope: try Envelope.read(URL(fileURLWithPath: speech)),
                                          minGap: p.number("minGap") ?? 0.25)
        return ["assetId": .string(asset.id), "engine": .string(t.engine), "pauses": .number(Double(r.pauses)),
                "starts": r.starts.json, "ends": r.ends.json]
    }
}

enum AudioClean: Command {
    static let id = "audio.clean"
    static let summary = "Make the voice broadcast-ready after edit.autoCut: DeepFilterNet denoise + voice chain (per-take level match, per-segment level match — a second voice off the microphone more than 6 dB under the speaker is raised toward it, at most 12 dB —, EQ, gate, compressor, one linear normalization to −15 LUFS, true peak ≤ −1.5 dBTP). The cleaned file becomes a new asset and replaces the source on the track's clips with the same ranges, so sync is unchanged. Re-run after a new edit.autoCut; restore: true puts the original sound back. Returns the loudness, the A/V lag and the commands it ran."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Audio track to clean (default: the first audio track)."),
        .optional("attenuation", .number, "DeepFilterNet attenuation limit, dB (default 18)."),
        .optional("target", .number, "Integrated loudness target, LUFS (default \(LoudnessTarget.text(LoudnessTarget.integrated)))."),
        .optional("truePeak", .number, "True-peak ceiling, dBTP (default \(LoudnessTarget.text(LoudnessTarget.truePeak)))."),
        .optional("gate", .boolean, "Gentle gate in the chain (default true)."),
        .optional("levelMatch", .number, "Speech segments further than this from the main speaker are gained toward it, dB (default 6; 0 = off): a second voice off the microphone."),
        .optional("levelMatchMax", .number, "Largest level-match gain, dB (default 12)."),
        .optional("restore", .boolean, "Put the original sound back on the track's clips (same ranges, edge fades kept): the cleaning switched off, one undo step. Needs no engine."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let t: Int
        if let trackID = p.string("trackId") { t = try Timeline.trackIndex(trackID, in: project) }
        else {
            guard let first = project.tracks.firstIndex(where: { $0.kind == .audio }) else { throw CommandError.conflict("\(id): no audio track") }
            t = first
        }
        let track = project.tracks[t]
        guard !track.clips.isEmpty else { throw CommandError.conflict("\(id): track \(track.name) has no clips") }
        // Clips may already point at an earlier cleaned version: go back to its source.
        let sourceIDs = Set(track.clips.map { project.asset($0.assetID)?.origin?.assetID ?? $0.assetID })
        guard sourceIDs.count == 1, let sourceID = sourceIDs.first else {
            throw CommandError.conflict("\(id): track \(track.name) mixes several sources (\(sourceIDs.sorted().joined(separator: ", ")))")
        }
        if p.bool("restore") == true {
            let source = project.assets[try Analysis.assetIndex(sourceID, in: project, command: id)]
            guard track.clips.contains(where: { $0.assetID != sourceID }) else { throw CommandError.conflict("\(id): the voice on \(track.name) is not cleaned") }
            var log: [JSONValue] = []
            try swapClips(of: track, to: source.id, length: source.duration, ctx: &ctx, log: &log)
            return ["trackId": .string(track.id), "restored": true, "asset": ProjectState.summary(of: source), "commands": .array(log)]
        }
        if let reason = ctx.services.cleaner.unavailableReason() { throw CommandError(.io, "\(id): \(reason)") }
        let si = try Analysis.assetIndex(sourceID, in: project, command: id)
        let audio = try CommandJob.stage(0, 0.05) { try Analysis.ensureAudio(si, &project, &ctx) }

        let dir = try ctx.mediaDirectory()
        var output = dir.appendingPathComponent("\(sourceID)-voice.wav")
        var n = 2
        while FileManager.default.fileExists(atPath: output.path) || project.assets.contains(where: { $0.path == output.path }) {
            output = dir.appendingPathComponent("\(sourceID)-voice-\(n).wav"); n += 1
        }
        let target = p.number("target") ?? LoudnessTarget.integrated, peak = p.number("truePeak") ?? LoudnessTarget.truePeak
        let ranges = track.clips.map { (start: $0.sourceIn, end: $0.sourceOut) }
        let request = VoiceCleanRequest(
            input: URL(fileURLWithPath: audio.working), ranges: ranges, output: output, attenuation: p.number("attenuation") ?? 18,
            targetLUFS: target, truePeak: peak, gate: p.bool("gate") ?? true, workDirectory: dir,
            levelMatch: p.number("levelMatch") ?? 6, levelMatchMax: p.number("levelMatchMax") ?? 12)
        // Cancelled or failed anywhere from here: no (half-)written voice file stays behind (the edit is unchanged).
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: output) } }
        let report = try CommandJob.stage(0.05, 0.9) { try ctx.services.cleaner.clean(request) }

        // The cleaned file is an ordinary asset; the track's clips are swapped with ordinary commands.
        let info = try ctx.prober.probe(output)
        let cleaned = MediaAsset(id: project.makeID("a"), name: output.lastPathComponent, path: output.path, duration: info.duration,
                                 video: nil, audio: info.audio, origin: AssetOrigin(assetID: sourceID, process: id))
        project.assets.append(cleaned)
        ctx.project = project
        var log: [JSONValue] = []
        try swapClips(of: track, to: cleaned.id, length: info.duration, ctx: &ctx, log: &log)

        // Sync: the cleaned file against the original, over (up to) six of the used ranges.
        let original = try WAVAudio.read(URL(fileURLWithPath: audio.working))
        let processed = try WAVAudio.read(output)
        let windows = ranges.prefix(6).map { r -> (start: Double, end: Double) in
            let mid = (r.start.seconds + r.end.seconds) / 2
            return (max(mid - 1, r.start.seconds), min(mid + 1, r.end.seconds))
        }
        let sync = SyncCheck.lag(original: original.mono(), processed: processed.mono(channel: 0),
                                 sampleRate: original.sampleRate, windows: windows)
        let frameRate = project.assets[si].video?.frameRate.doubleValue ?? ctx.project!.settings.frameRate.doubleValue
        let finalTrack = ctx.project!.tracks[t]
        let loudness = try ctx.services.audio.loudness(of: finalTrack.clips.map {
            AudioSpan(url: output, start: $0.sourceIn, end: $0.sourceOut, channels: info.audio?.channels ?? 2)
        })
        finished = true
        return ["asset": ProjectState.summary(of: cleaned), "trackId": .string(track.id), "commands": .array(log),
                "rangeGains": .array(report.rangeGains.map { Analysis.seconds($0, places: 10) }),
                "measuredBefore": report.measured.json, "gain": Analysis.seconds(report.gain, places: 100), "mode": .string(report.mode),
                "levelMatch": ["mainDB": Analysis.seconds(report.mainLevel, places: 10),
                               "segments": .number(Double(report.levelMatch.count)),
                               "gained": .array(report.levelMatch.filter { $0.gain != 0 }.map { s in
                                   ["start": Analysis.seconds(s.start, places: 100), "end": Analysis.seconds(s.end, places: 100),
                                    "relativeDB": .number(s.relative), "gainDB": .number(s.gain)]
                               })],
                "denoiseSeconds": Analysis.seconds(report.denoiseSeconds, places: 10),
                "sync": ["lagMs": Analysis.seconds(sync.lagSeconds * 1000, places: 10),
                         "lagFrames": Analysis.seconds(sync.lagSeconds * frameRate, places: 100),
                         "correlation": Analysis.seconds(sync.correlation)],
                "loudness": loudness.json]
    }

    /// The track's clips swapped for the same ranges of `assetID` with ordinary commands: only these clips go (not their
    /// linked pictures), each new clip rejoins its old clip's link and keeps its edge fades.
    private static func swapClips(of track: Track, to assetID: String, length: MediaTime, ctx: inout CommandContext, log: inout [JSONValue]) throws {
        let project = try ctx.requireProject()
        let partners = track.clips.map { c in Timeline.partners(of: c, in: project).first.map { project.tracks[$0.track].clips[$0.clip].id } }
        try ctx.perform(TimelineDelete.self, ["clipIds": .array(track.clips.map { .string($0.id) }), "linked": false], log: &log)
        for (c, partner) in zip(track.clips, partners) {
            // A clip that runs to the container's end can outlast the sound by a few frames: it stops where the file does.
            var params: JSONValue = ["assetId": .string(assetID), "trackId": .string(track.id), "start": .number(c.start.seconds),
                                     "sourceIn": .number(c.sourceIn.seconds), "sourceOut": .number(min(c.sourceOut, length).seconds)]
            if let partner, case .object(var o) = params { o["linkTo"] = .string(partner); params = .object(o) }
            let placed = try ctx.perform(TimelinePlace.self, params, log: &log)
            if c.fadeIn != nil || c.fadeOut != nil, let newID = placed.value(at: "clip.id") {   // keep the edge fades
                try ctx.perform(ClipSet.self, ["clipId": newID, "fadeIn": .number(c.fadeIn?.seconds ?? 0),
                                               "fadeOut": .number(c.fadeOut?.seconds ?? 0)], log: &log)
            }
        }
    }
}

enum FacesTrack: Command {
    static let id = "faces.track"
    static let summary = "Track the faces in every frame of a video asset (Apple Vision): the main face smoothed (One-Euro, reset at cuts) and every other face (a child in the arms, a second person), saved as a sidecar JSON. Needed by edit.punchIns (face-aware crops, the default) and by captions, which then keep clear of every face. Returns detection rate, frames with several faces and jitter."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("assetId", .string, "Video asset."),
        .optional("minCutoff", .number, "One-Euro minimum cutoff, Hz (default 0.3: steadier)."),
        .optional("beta", .number, "One-Euro speed coefficient (default 0.01; higher = less lag on fast moves, more shake)."),
        .optional("landmarks", .boolean, "Also store eye, nose and mouth points (slower; default false)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let i = try Analysis.assetIndex(p.requiredString("assetId"), in: project, command: id)
        let asset = project.assets[i]
        guard asset.video != nil else { throw CommandError.conflict("\(id): \(asset.name) has no video") }
        guard let tracker = ctx.services.faces else {
            throw CommandError(.io, "\(id): no face engine in this host (use regista-engine / regista-mcp, which include Apple Vision)")
        }
        let options = FaceTrackOptions(minCutoff: p.number("minCutoff") ?? 0.3, beta: p.number("beta") ?? 0.01,
                                       landmarks: p.bool("landmarks") ?? false)
        let started = Date()
        var track = try tracker.track(URL(fileURLWithPath: asset.path), options: options)
        track.smooth()
        let file = try ctx.mediaDirectory().appendingPathComponent("\(asset.id)-faces.json")
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { try e.encode(track).write(to: file, options: .atomic) }
        catch { throw CommandError(.io, "\(id): cannot write \(file.path): \(error.localizedDescription)") }
        let summary = FaceTrackSummary(path: file.path, frames: track.frames.count, detected: track.detected, cuts: track.cuts.count,
                                       jitterPx: (track.jitter(smoothed: true) * 100).rounded() / 100,
                                       rawJitterPx: (track.jitter(smoothed: false) * 100).rounded() / 100)
        project.assets[i].analysis = project.assets[i].analysis ?? AssetAnalysis()
        project.assets[i].analysis?.faces = summary
        ctx.project = project
        let ratio = summary.frames > 0 ? Double(summary.detected) / Double(summary.frames) : 0
        return ["assetId": .string(asset.id), "sidecar": .string(file.path), "frames": .number(Double(summary.frames)),
                "detected": .number(Double(summary.detected)), "detectedRatio": Analysis.seconds(ratio, places: 10000),
                "multiFaceFrames": .number(Double(track.multiFace)),
                "cuts": .number(Double(summary.cuts)), "engine": .string(track.engine),
                "jitterPx": ["smooth": .number(summary.jitterPx), "raw": .number(summary.rawJitterPx)],
                "meanStepPx": ["smooth": Analysis.seconds(track.meanStep(smoothed: true), places: 100),
                               "raw": Analysis.seconds(track.meanStep(smoothed: false), places: 100)],
                "seconds": Analysis.seconds(Date().timeIntervalSince(started), places: 10)]
    }
}
