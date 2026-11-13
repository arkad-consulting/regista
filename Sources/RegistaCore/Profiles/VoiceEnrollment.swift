import Foundation

// Recording and cloning one's own voice (issue #41): the script, the takes, the clips, the training.
// Layout of a profile's voice folder, per language:
//   voice/<lang>/script.md          the script with the person's name, to read from a phone
//   voice/<lang>/takes/<tone>-N.wav 48 kHz mono copies of the recordings
//   voice/<lang>/clips/…wav         one clip per accepted script line (+ clips.json, train.jsonl)
//   voice/<lang>/refs/<tone>.wav    8–15 s of consecutive lines: the reference clip of the tone
//   voice/<lang>/lora/              training job (train.json, stdout/stderr/exit) and checkpoints step_NNNNNNN

/// A recording script: consent sentence + one block of lines per tone (`engines/voxcpm/scripts/<lang>.md`).
public struct RecordingScript: Hashable, Sendable {
    public static let tones = ["neutral", "enthusiastic", "serious", "calm", "playful", "alarmed", "sad"]

    public var language: String
    /// With the `{name}` placeholder.
    public var consent: String
    public var blocks: [(tone: String, lines: [String])]

    public static func == (a: RecordingScript, b: RecordingScript) -> Bool {
        a.language == b.language && a.consent == b.consent && a.blocks.map(\.tone) == b.blocks.map(\.tone) && a.blocks.map(\.lines) == b.blocks.map(\.lines)
    }

    public func hash(into h: inout Hasher) {
        h.combine(language)
        h.combine(consent)
        for b in blocks { h.combine(b.tone); h.combine(b.lines) }
    }

    public func lines(_ tone: String) -> [String] { blocks.first { $0.tone == tone }?.lines ?? [] }

    public func consent(name: String) -> String { consent.replacingOccurrences(of: "{name}", with: name) }

    /// Reading time at ~2.4 words per second plus a pause per line.
    public var minutes: Double {
        let words = blocks.flatMap(\.lines).reduce(0) { $0 + $1.split(separator: " ").count }
        return (Double(words) / 2.4 + Double(blocks.flatMap(\.lines).count) * 1.5) / 60
    }

    public static func parse(_ text: String, language: String) throws -> RecordingScript {
        var consent: String?, blocks: [(String, [String])] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("# ") { continue }
            if line.hasPrefix("consent:") { consent = line.dropFirst("consent:".count).trimmingCharacters(in: .whitespaces); continue }
            if line.hasPrefix("## ") { blocks.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])); continue }
            if line.hasPrefix("- "), !blocks.isEmpty { blocks[blocks.count - 1].1.append(String(line.dropFirst(2))); continue }
            throw CommandError(.io, "script \(language): unexpected line «\(line.prefix(60))»")
        }
        guard let c = consent, c.contains("{name}") else { throw CommandError(.io, "script \(language): no consent line with {name}") }
        guard blocks.map(\.0) == tones else { throw CommandError(.io, "script \(language): blocks must be \(tones.joined(separator: ", "))") }
        return RecordingScript(language: language, consent: c, blocks: blocks)
    }

    /// The shipped script of a language (next to vox_say.py).
    public static func load(language: String, config: EngineConfig) throws -> RecordingScript {
        let f = config.url(config.voxcpmProject).appendingPathComponent("scripts/\(language).md")
        guard let t = try? String(contentsOf: f, encoding: .utf8) else {
            let have = ((try? FileManager.default.contentsOfDirectory(atPath: f.deletingLastPathComponent().path)) ?? [])
                .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
            throw CommandError.notFound("no recording script for \(language) (\(f.path)); available: \(have.isEmpty ? "none" : have.joined(separator: ", "))")
        }
        return try parse(t, language: language)
    }

    /// Markdown to read aloud: how to record, the consent first, then one section per tone.
    public func readable(name: String) -> String {
        var s = "# \(name) — voice recording (\(language), ~\(Int(minutes.rounded())) min)\n\n"
        s += "- One file per block below, named after its tone. Quiet, soft room; the same mic, place and distance every time.\n"
        s += "- 5 s of silence at the start, 1–2 s between lines. On a mistake: pause and read the whole line again.\n"
        s += "- Stay in the block's tone for the whole block, a little exaggerated.\n\n"
        s += "**Start the first file with:** \(consent(name: name))\n"
        for b in blocks {
            s += "\n## \(b.tone)\n\n" + b.lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return s
    }
}

/// One training clip.
public struct VoiceClip: Codable, Hashable, Sendable {
    public var file: String
    /// The script line, exactly (what the model learns to say).
    public var text: String
    public var tone: String
    public var take: String
    /// Share of the line's words heard, 0…1.
    public var score: Double
    public var seconds: Double
}

/// A script line found in a transcript: word indices and match score.
struct LineMatch: Equatable {
    var line: Int
    var first: Int
    var last: Int
    var score: Double
}

public enum VoiceEnrollment {
    /// Lines must be heard at least this well to become clips.
    static let acceptScore = 0.8
    /// Tones with at least this many clips are trained with their style tag.
    public static let minimumClipsPerTone = 10

    static func keys(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).flatMap { ScriptAligner.keys(of: String($0)) }.filter { !$0.isEmpty }
    }

    /// Longest common subsequence of `a` and `b` with fuzzy word equality: (length, first and last matched index in b).
    static func lcs(_ a: [String], _ b: ArraySlice<String>) -> (count: Int, first: Int, last: Int)? {
        guard !a.isEmpty, !b.isEmpty else { return nil }
        let bs = Array(b), base = b.startIndex
        var dp = [[Int]](repeating: [Int](repeating: 0, count: bs.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...bs.count {
                dp[i][j] = ScriptAligner.similarity(a[i - 1], bs[j - 1]) >= 0.8 ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        guard dp[a.count][bs.count] > 0 else { return nil }
        var i = a.count, j = bs.count, first = -1, last = -1
        while i > 0, j > 0 {
            if ScriptAligner.similarity(a[i - 1], bs[j - 1]) >= 0.8, dp[i][j] == dp[i - 1][j - 1] + 1 {
                if last < 0 { last = j - 1 }
                first = j - 1
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 } else { j -= 1 }
        }
        return (dp[a.count][bs.count], base + first, base + last)
    }

    /// Finds each line in the heard keys, in order. A line read twice (a slip, then again) keeps its best reading,
    /// the later one on a tie. Lines not found are skipped without moving on.
    static func align(lines: [String], heard: [String], from start: Int = 0) -> [LineMatch] {
        var out: [LineMatch] = [], cursor = start
        for (n, line) in lines.enumerated() {
            let t = keys(line)
            guard !t.isEmpty else { continue }
            let limit = min(heard.count, cursor + 3 * t.count + 60)
            var best: LineMatch?
            var s = cursor
            while s < limit {
                if t.prefix(3).contains(where: { ScriptAligner.similarity($0, heard[s]) >= 0.8 }),
                   let m = lcs(t, heard[s..<min(heard.count, s + t.count + 4)]) {
                    let score = Double(m.count) / Double(t.count)
                    if score >= (best?.score ?? 0) { best = LineMatch(line: n, first: m.first, last: m.last, score: score) }
                }
                s += 1
            }
            if let b = best, b.score >= acceptScore {
                out.append(b)
                cursor = b.last + 1
            }
        }
        return out
    }

    /// Whether the consent sentence (without the name, which recognizers misspell) is heard in the first 40 words.
    static func consentHeard(_ consent: String, name: String, heard: [String]) -> Bool {
        let nameKeys = Set(keys(name))
        let t = keys(consent.replacingOccurrences(of: "{name}", with: "")).filter { !nameKeys.contains($0) }
        guard let m = lcs(t, heard.prefix(40)) else { return false }
        return Double(m.count) / Double(t.count) >= 0.75
    }

    /// Clip boundaries around words [first, last]: a little air, never into the neighbouring words.
    static func bounds(_ words: [Word], first: Int, last: Int, duration: Double) -> (Double, Double) {
        var a = words[first].start.seconds - 0.15, b = words[last].end.seconds + 0.25
        if first > 0 { a = max(a, (words[first - 1].end.seconds + words[first].start.seconds) / 2) }
        if last + 1 < words.count { b = min(b, (words[last].end.seconds + words[last + 1].start.seconds) / 2) }
        return (max(0, a), min(duration, b))
    }

    static func write(_ audio: WAVAudio, from a: Double, to b: Double, _ url: URL) throws {
        let r = Double(audio.sampleRate)
        let i = max(0, Int(a * r)), j = min(audio.frameCount, Int(b * r))
        guard j > i else { throw CommandError(.io, "empty clip \(url.lastPathComponent)") }
        try WAVAudio(sampleRate: audio.sampleRate, channels: 1, samples: Array(audio.samples[i..<j])).write16(to: url)
    }

    public static func languageFolder(_ entry: ProfileEntry, _ language: String) -> URL {
        entry.directory.appendingPathComponent("voice/\(language)")
    }

    static func loadClips(_ folder: URL) -> [VoiceClip] {
        guard let d = FileManager.default.contents(atPath: folder.appendingPathComponent("clips/clips.json").path) else { return [] }
        return (try? JSONDecoder().decode([VoiceClip].self, from: d)) ?? []
    }

    /// clips.json + train.jsonl (the trainer's manifest: audio path + text, with the tone tag on non-neutral lines).
    static func saveClips(_ clips: [VoiceClip], _ folder: URL) throws {
        let dir = folder.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(clips).write(to: dir.appendingPathComponent("clips.json"), options: .atomic)
        let lines = clips.map { c -> String in
            let text = (VoiceTone.tags[c.tone].map { "\($0)" } ?? "") + c.text
            return JSONValue.object(["audio": .string(c.file), "text": .string(text)]).text()
        }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("train.jsonl"), atomically: true, encoding: .utf8)
    }

    public struct AddResult: Sendable {
        public var take: String
        public var accepted: Int
        public var total: Int
        public var missing: [String]
        public var reference: String?
        public var consent: Bool
    }

    /// Imports one take of a tone block: copy, transcription, consent check (first take of the language), alignment,
    /// clips, reference clip, and the language registered in the profile (zero-shot until trained).
    public static func add(path: String, language: String, tone: String, profiles: ProfileStore, script: RecordingScript,
                           audio: AudioToolkit, transcriber: Transcriber, command: String) throws -> AddResult {
        let entry = try profiles.requireActive(command: command)
        guard RecordingScript.tones.contains(tone) else {
            throw CommandError.invalid("\(command): tone is one of \(RecordingScript.tones.joined(separator: ", "))")
        }
        let source = URL(fileURLWithPath: EngineConfig.expand(path)).standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else { throw CommandError.notFound("\(command): no file at \(source.path)") }
        let folder = languageFolder(entry, language)
        let takes = folder.appendingPathComponent("takes")
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
        var n = 1
        while FileManager.default.fileExists(atPath: takes.appendingPathComponent("\(tone)-\(n).wav").path) { n += 1 }
        let take = "\(tone)-\(n)"
        let working = takes.appendingPathComponent("\(take).wav")
        let speech = FileManager.default.temporaryDirectory.appendingPathComponent("regista-enroll-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: speech) }
        try audio.extractAudio(from: source, channels: 2, speech: speech, working: working)
        if let why = transcriber.unavailableReason() { throw CommandError(.io, "\(command): \(why)") }
        let words = try transcriber.transcribe(speech, language: language).words
        // One key per heard word part ("l'IA" → l, ia); wordOf maps a key back to its word.
        var heardKeys: [String] = [], wordOf: [Int] = []
        for (i, w) in words.enumerated() { for k in ScriptAligner.keys(of: w.text) { heardKeys.append(k); wordOf.append(i) } }

        // Consent: the first take of a language opens with it, said by the profile's owner.
        let hadConsent = entry.profile.consents?[language] != nil
        var consentNow = false
        if !hadConsent {
            guard consentHeard(script.consent, name: entry.profile.name, heard: heardKeys) else {
                try? FileManager.default.removeItem(at: working)
                throw CommandError.invalid("\(command): the first recording of \(language) must start with the consent sentence, said by \(entry.profile.name): «\(script.consent(name: entry.profile.name))». It was not heard at the start of \(source.lastPathComponent).")
            }
            consentNow = true
        }

        let lines = script.lines(tone)
        let matches = align(lines: lines, heard: heardKeys)
        let wav = try WAVAudio.read(working)
        let duration = Double(wav.frameCount) / Double(wav.sampleRate)
        let clipDir = folder.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
        var clips = loadClips(folder).filter { $0.take != take }
        var made: [(LineMatch, Double, Double)] = []
        for m in matches {
            let (a, b) = bounds(words, first: wordOf[m.first], last: wordOf[m.last], duration: duration)
            guard b - a >= 0.8, b - a <= 20 else { continue }
            let file = clipDir.appendingPathComponent("\(take)-\(String(format: "%03d", m.line)).wav")
            try write(wav, from: a, to: b, file)
            clips.append(VoiceClip(file: file.path, text: lines[m.line], tone: tone, take: take, score: m.score, seconds: b - a))
            made.append((m, a, b))
        }
        try saveClips(clips, folder)

        // Reference clip: the first run of consecutive lines lasting 8–15 s (else the longest run under 15 s).
        var reference: (Double, Double, String)?
        var best: (Double, Double, String)?
        for i in made.indices {
            var j = i, text = [lines[made[i].0.line]]
            while j + 1 < made.count, made[j + 1].0.line == made[j].0.line + 1, made[j + 1].2 - made[i].1 <= 15 {
                j += 1
                text.append(lines[made[j].0.line])
            }
            let span = (made[i].1, made[j].2, text.joined(separator: " "))
            if span.1 - span.0 >= 8 { reference = span; break }
            if span.1 - span.0 > (best.map { $0.1 - $0.0 } ?? 0) { best = span }
        }
        var refPath: String?
        let current = entry.profile.voices[language]?.refs[tone]
        if let r = reference ?? (current == nil ? best : nil), r.1 - r.0 >= 3 {
            let refs = folder.appendingPathComponent("refs")
            try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
            let file = refs.appendingPathComponent("\(tone).wav")
            try write(wav, from: r.0, to: r.1, file)
            refPath = file.path
            try profiles.update(entry.profile.id) { p in
                var v = p.voices[language] ?? VoiceLanguage(refs: [:])
                v.refs[tone] = VoiceReference(wav: file.path, text: r.2)
                p.voices[language] = v
            }
        }
        if consentNow {
            try profiles.update(entry.profile.id) { p in
                var c = p.consents ?? [:]
                c[language] = VoiceConsent(text: script.consent(name: p.name), take: take, date: Generation.now())
                p.consents = c
            }
        }
        let found = Set(made.map(\.0.line))
        return AddResult(take: take, accepted: made.count, total: lines.count,
                         missing: lines.indices.filter { !found.contains($0) }.map { lines[$0] }, reference: refPath, consent: consentNow || hadConsent)
    }

    // MARK: - Training

    public static func trainingDirectory(_ entry: ProfileEntry, _ language: String) -> URL {
        languageFolder(entry, language).appendingPathComponent("lora")
    }

    /// The upstream trainer's config (YAML is a superset of JSON). Pilot-size data → the pilot recipe that worked
    /// (300 steps × 4); a full set → 1000 × 16.
    static func trainingConfig(manifest: URL, out: URL, model: String, seconds: Double) -> (JSONValue, steps: Int, accum: Int) {
        let full = seconds >= 300
        let steps = full ? 1000 : 300, accum = full ? 16 : 4
        let config: JSONValue = [
            "pretrained_path": .string(model), "train_manifest": .string(manifest.path), "val_manifest": .null,
            "sample_rate": 16000, "out_sample_rate": 48000, "batch_size": 1, "grad_accum_steps": .number(Double(accum)),
            "num_workers": 0, "preprocessing_num_workers": 1, "num_iters": .number(Double(steps)), "max_steps": .number(Double(steps)),
            "log_interval": 25, "valid_interval": 100000, "save_interval": .number(Double(full ? 250 : 150)),
            "learning_rate": 0.0001, "weight_decay": 0.01, "warmup_steps": .number(Double(full ? 60 : 30)),
            "max_batch_tokens": 8192, "max_grad_norm": 1.0,
            "save_path": .string(out.path), "tensorboard": .string(out.appendingPathComponent("logs").path),
            "lambdas": ["loss/diff": 1.0, "loss/stop": 1.0],
            "lora": ["enable_lm": true, "enable_dit": true, "enable_proj": false, "r": 32, "alpha": 32, "dropout": 0.0],
        ]
        return (config, steps, accum)
    }

    /// Clips needed before a language can be trained.
    public static let minimumTrainingSeconds = 90.0

    /// About how long a training of `seconds` of clips takes (the recipe's steps × accumulation, ~0.4 s each).
    public static func estimatedTrainingMinutes(seconds: Double) -> Double {
        let full = seconds >= 300
        return Double((full ? 1000 : 300) * (full ? 16 : 4)) * 0.4 / 60
    }

    /// Where a running training is, from its log ("[train] step 125: …, log interval: 39.2s" every 25 steps) and the
    /// run's config (num_iters): the last step, the total and the minutes left at the last interval's pace.
    static func trainingProgress(log: String, config: JSONValue?) -> (step: Int?, steps: Int?, minutesLeft: Double?) {
        let steps = config?["num_iters"]?.doubleValue.map { Int($0) }
        var step: Int?, interval: Double?
        for line in log.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: "[train] step ") else { continue }
            let rest = line[r.upperBound...]
            if let n = Int(rest.prefix { $0.isNumber }) { step = n }
            if let i = line.range(of: "log interval: ") {
                interval = Double(line[i.upperBound...].prefix { $0.isNumber || $0 == "." })
            }
        }
        var left: Double?
        if let step, let steps, let interval { left = Double(max(0, steps - 1 - step)) * interval / 25 / 60 }
        return (step, steps, left)
    }

    /// The newest checkpoint folder (step_NNNNNNN with LoRA weights).
    static func lastCheckpoint(_ dir: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("step_") }.sorted().reversed()
            .map { dir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("lora_weights.safetensors").path) }
    }

    /// Starts the training in the background. Throws when the data is too thin or a training already runs.
    public static func train(language: String, profiles: ProfileStore, config: EngineConfig, command: String) throws -> JSONValue {
        let entry = try profiles.requireActive(command: command)
        guard entry.profile.consents?[language] != nil else {
            throw CommandError.invalid("\(command): no consent recorded for \(language): add the first take (it starts with the consent sentence)")
        }
        let folder = languageFolder(entry, language)
        let clips = loadClips(folder)
        let seconds = clips.reduce(0) { $0 + $1.seconds }
        guard seconds >= minimumTrainingSeconds else {
            throw CommandError.invalid("\(command): \(Int(seconds)) s of clips in \(language); at least 90 s are needed (the neutral block alone gives ~10 min)")
        }
        let dir = trainingDirectory(entry, language)
        let job = GenerationJobDir(dir.appendingPathComponent("job"))
        if FileManager.default.fileExists(atPath: job.stdoutFile.path), job.exitStatus == nil {
            throw CommandError.conflict("\(command): a training of \(language) is already running: poll voice.enroll.status")
        }
        let out = dir.appendingPathComponent("run-\(Generation.now().replacingOccurrences(of: ":", with: "-"))")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (cfg, steps, accum) = trainingConfig(manifest: folder.appendingPathComponent("clips/train.jsonl"), out: out,
                                                 model: config.url(config.voxcpmModel).path, seconds: seconds)
        let cfgFile = out.appendingPathComponent("train.yaml")
        try cfg.text().write(to: cfgFile, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: job.url, withIntermediateDirectories: true)
        try Data(out.path.utf8).write(to: job.url.appendingPathComponent("run"))
        let trainer = config.url(config.voxcpmProject).appendingPathComponent("train_voxcpm_finetune.py")
        try job.launch(GenerationProcess(config.url(config.uv),
                                         ["run", "--frozen", "--project", config.url(config.voxcpmProject).path, "python", "-I",
                                          trainer.path, "--config_path", cfgFile.path],
                                         environment: ["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"]), wait: false)
        let minutes = estimatedTrainingMinutes(seconds: seconds)
        return ["status": "running", "language": .string(language), "steps": .number(Double(steps)), "gradAccum": .number(Double(accum)),
                "clips": .number(Double(clips.count)), "audioMinutes": .number((seconds / 6).rounded() / 10),
                "estimatedMinutes": .number(minutes.rounded()), "folder": .string(out.path),
                "note": "runs in the background (keep the Mac awake and plugged in); voice.enroll.status collects it when it ends"]
    }

    /// Training state of a language; a finished run registers its last checkpoint as the language's LoRA.
    public static func trainingStatus(_ entry: ProfileEntry, language: String, profiles: ProfileStore) throws -> JSONValue {
        let job = GenerationJobDir(trainingDirectory(entry, language).appendingPathComponent("job"))
        guard FileManager.default.fileExists(atPath: job.stdoutFile.path) else { return ["state": "never trained"] }
        let run = (try? String(contentsOf: job.url.appendingPathComponent("run"), encoding: .utf8)).map { URL(fileURLWithPath: $0) }
        let tail = (job.stdout + "\n" + job.stderrTail).split(separator: "\n").suffix(3).joined(separator: "\n")
        guard let status = job.exitStatus else {
            let log = job.stdout + "\n" + ((try? String(contentsOf: job.stderrFile, encoding: .utf8)) ?? "")
            let config = run.flatMap { try? JSONValue.parse(String(contentsOf: $0.appendingPathComponent("train.yaml"), encoding: .utf8)) }
            let progress = trainingProgress(log: log, config: config)
            var o: [String: JSONValue] = ["state": "running", "lastCheckpoint": run.flatMap(lastCheckpoint).map { .string($0.lastPathComponent) } ?? .null,
                                          "log": .string(tail)]
            if let s = progress.step { o["step"] = .number(Double(s)) }
            if let s = progress.steps { o["steps"] = .number(Double(s)) }
            if let m = progress.minutesLeft { o["minutesLeft"] = .number(m.rounded()) }
            if let started = (try? FileManager.default.attributesOfItem(atPath: job.stdoutFile.path))?[.creationDate] as? Date {
                o["started"] = .string(ISO8601DateFormatter().string(from: started))
            }
            return .object(o)
        }
        guard status == 0, let run, let ckpt = lastCheckpoint(run) else {
            return ["state": "failed", "exit": .number(Double(status)), "log": .string(job.stderrTail)]
        }
        let clips = loadClips(languageFolder(entry, language))
        let trained = RecordingScript.tones.filter { t in clips.filter { $0.tone == t }.count >= minimumClipsPerTone }
        if entry.profile.voices[language]?.lora != ckpt.path {
            try profiles.update(entry.profile.id) { p in
                var v = p.voices[language] ?? VoiceLanguage(refs: [:])
                v.lora = ckpt.path
                v.tones = trained.isEmpty ? [VoiceTone.neutral] : trained
                p.voices[language] = v
            }
        }
        return ["state": "done", "lora": .string(ckpt.path), "tones": .array(trained.map { .string($0) })]
    }
}
