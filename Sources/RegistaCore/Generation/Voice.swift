import Foundation

// Voice-over in a cloned voice (issue #38): VoxCPM2 with one LoRA per
// language, in its own uv environment (engines/voxcpm). Voices belong to the person who recorded them: they live in
// that person's profile (Profiles.swift, #41) and are never shipped — recordings, LoRAs and renders are biometric data.

/// A reference clip of the real voice and its exact transcript (ultimate cloning: prompt audio + prompt text).
public struct VoiceReference: Codable, Hashable, Sendable {
    public var wav: String
    public var text: String

    public init(wav: String, text: String) {
        self.wav = wav
        self.text = text
    }
}

/// One language of a voice: the LoRA trained on it (nil: zero-shot from the reference) and its reference clips by tone.
public struct VoiceLanguage: Codable, Hashable, Sendable {
    /// LoRA checkpoint folder (lora_weights.safetensors + lora_config.json); nil = zero-shot cloning.
    public var lora: String?
    /// Reference clips by tone; `neutral` is required.
    public var refs: [String: VoiceReference]
    /// Tones the LoRA was trained on with a style tag (default: neutral only).
    public var tones: [String]?

    public init(lora: String? = nil, refs: [String: VoiceReference], tones: [String]? = nil) {
        self.lora = lora
        self.refs = refs
        self.tones = tones
    }

    /// Tones this language can say: the trained ones, plus any tone that has its own reference clip.
    public var availableTones: [String] {
        var all = tones ?? [VoiceTone.neutral]
        for t in refs.keys.sorted() where !all.contains(t) { all.append(t) }
        if !all.contains(VoiceTone.neutral) { all.insert(VoiceTone.neutral, at: 0) }
        return all
    }
}

/// The style tags of the tone-labelled training blocks (brain: 10-projects/voice-clone, decision D3).
public enum VoiceTone {
    public static let neutral = "neutral"
    public static let tags: [String: String] = [
        "enthusiastic": "(enthusiastic, happy)",
        "serious": "(serious, authoritative)",
        "calm": "(calm, confidential)",
        "playful": "(playful, ironic, smiling)",
        "alarmed": "(alarmed, urgent)",
        "sad": "(sad, disappointed)",
    ]
}

/// Pronunciation lexicon of one language in a profile: `voice/lexicon-<lang>.json`, `{"entries": [{word, say, status}]}`.
/// Applied only to the text sent to the model; script, transcript and captions keep the real spelling.
public struct VoiceLexicon: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var word: String
        public var say: String
        /// "confirmed" (approved by ear) or "pending" (chosen by Whisper read-back, waiting for the owner's ear).
        public var status: String?

        public init(word: String, say: String, status: String? = nil) {
            self.word = word
            self.say = say
            self.status = status
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    /// Missing file = empty lexicon; a malformed one is an error (a silent empty lexicon would mispronounce brands).
    public static func load(_ f: URL) throws -> VoiceLexicon {
        guard let d = FileManager.default.contents(atPath: f.path) else { return VoiceLexicon() }
        do { return try JSONDecoder().decode(VoiceLexicon.self, from: d) }
        catch { throw CommandError(.io, "unreadable lexicon \(f.path): \(error)") }
    }

    /// Whole words only, longest first (so "Claude Code" wins over "Claude").
    public func apply(_ text: String) -> String {
        var out = text
        for e in entries.sorted(by: { $0.word.count > $1.word.count }) where !e.word.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: e.word) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: e.say))
        }
        return out
    }
}

/// What one voice request resolves to: who speaks, in which language and tone, from which files, saying what.
public struct VoiceSetup: Hashable, Sendable {
    public var voice: String
    public var language: String
    public var tone: String
    public var lora: String?
    public var ref: VoiceReference
    /// The text the model receives: tone tag + lexicon applied.
    public var modelText: String

    /// Resolves `options` {language, tone} against the **active profile's** voice: no option reaches another
    /// profile (`voice`, if given, must name the active one). Every referenced file must exist.
    public static func resolve(text: String, options: [String: String]?, profiles: ProfileStore, config: EngineConfig) throws -> VoiceSetup {
        let entry = try profiles.requireActive(command: "voice")
        let name = entry.profile.id
        let o = options ?? [:]
        if let v = o["voice"], v != name, v != entry.profile.name {
            throw CommandError.invalid("only the active profile's voice can be used (\(entry.profile.name)); switching profile is up to the person, in the Regista app")
        }
        let langs = entry.profile.voices
        guard !langs.isEmpty else {
            throw CommandError.invalid("\(entry.profile.name) has no voice yet: the person records it in Regista: the Voce panel's button to clone the voice, or Settings › Profile and voice (voice.enroll.script gives the text to read for a recording made elsewhere)")
        }
        let language: String
        if let l = o["language"]?.lowercased() { language = l }
        else if langs.count == 1 { language = langs.keys.first! }
        else { throw CommandError.invalid("voice \(name) speaks \(langs.keys.sorted().joined(separator: ", ")): pass options.language") }
        guard let setup = langs[language] else {
            throw CommandError.notFound("voice \(name) has no \(language) (it speaks \(langs.keys.sorted().joined(separator: ", "))): the person records it in Regista: the Voce panel's button to clone the voice, or Settings › Profile and voice (voice.enroll.script {language: \"\(language)\"} gives the text to read for a recording made elsewhere)")
        }
        let tone = o["tone"]?.lowercased() ?? VoiceTone.neutral
        guard setup.availableTones.contains(tone) else {
            throw CommandError.invalid("voice \(name) in \(language) has no tone \(tone) (it has: \(setup.availableTones.joined(separator: ", ")))")
        }
        guard let ref = setup.refs[tone] ?? setup.refs[VoiceTone.neutral] else {
            throw CommandError.invalid("voice \(name) in \(language) has no neutral reference clip (refs.neutral {wav, text})")
        }
        let problems = Self.missingFiles(setup, ref: ref, config: config)
        guard problems.isEmpty else { throw CommandError.notFound("voice \(name) in \(language): \(problems.joined(separator: "; "))") }

        var said = try VoiceLexicon.load(profiles.lexiconFile(entry, language: language)).apply(text)
        // A style tag only where the LoRA learned it; otherwise the tone comes from that tone's reference clip.
        if setup.lora != nil, (setup.tones ?? []).contains(tone), let tag = VoiceTone.tags[tone] { said = "\(tag)\(said)" }
        return VoiceSetup(voice: name, language: language, tone: tone, lora: setup.lora.map { config.url($0).path },
                          ref: VoiceReference(wav: config.url(ref.wav).path, text: ref.text), modelText: said)
    }

    /// Missing files of a language setup, each naming its path (empty: all there).
    static func missingFiles(_ setup: VoiceLanguage, ref: VoiceReference? = nil, config: EngineConfig) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        if let l = setup.lora {
            let w = config.url(l).appendingPathComponent("lora_weights.safetensors")
            let c = config.url(l).appendingPathComponent("lora_config.json")
            if !fm.fileExists(atPath: w.path) { out.append("LoRA weights missing: \(w.path)") }
            if !fm.fileExists(atPath: c.path) { out.append("LoRA config missing: \(c.path)") }
        }
        let refs = ref.map { [$0] } ?? setup.refs.keys.sorted().map { setup.refs[$0]! }
        for r in refs where !fm.fileExists(atPath: config.url(r.wav).path) { out.append("reference clip missing: \(config.url(r.wav).path)") }
        return out
    }
}

/// VoxCPM2 in the uv environment of engines/voxcpm (vox_say.py). Free and local; its RAM in use and tier are in scripts/engines.manifest.json.
public struct VoxCPMProvider: GeneratorProvider {
    public let config: EngineConfig
    public let profiles: ProfileStore
    public init(config: EngineConfig, profiles: ProfileStore) {
        self.config = config
        self.profiles = profiles
    }

    public let id = "voxcpm"
    public let title = "VoxCPM2 (local, free: your cloned voice)"
    public let paid = false
    public var minimumTier: MachineTier { EngineManifest.shared.minimumTier(id) }
    public let models = [
        GeneratorModel("voxcpm2", .voice, "VoxCPM2 2B, 48 kHz mono, + the voice's LoRA for the language; options {voice, language, tone}; ~15 s to load, then ~1× real time", isDefault: true),
    ]

    public func unavailableReason(_ kind: GenerationKind) -> String? {
        guard kind == .voice else { return "VoxCPM2 makes voice-over only" }
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: config.url(config.uv).path) { return "uv not found at \(config.uv)" }
        if !fm.fileExists(atPath: config.url(config.voxcpmProject).appendingPathComponent("pyproject.toml").path) {
            return "no VoxCPM environment at \(config.voxcpmProject) (engines/voxcpm: uv sync --frozen)"
        }
        if !fm.fileExists(atPath: config.url(config.voxcpmScript).path) { return "vox_say.py not found at \(config.voxcpmScript)" }
        if !fm.fileExists(atPath: config.url(config.voxcpmModel).appendingPathComponent("config.json").path) {
            return "VoxCPM2 weights not found at \(config.voxcpmModel) (openbmb/VoxCPM2, \(EngineManifest.shared.diskText("voxcpm-weights")))"
        }
        return nil
    }

    public func estimate(_ request: GenerationRequest) throws -> Double { 0 }

    /// Resolves the voice and records what the model will get in the options, so the cache key follows the
    /// lexicon, the LoRA and the reference clip — not only the words.
    public func prepare(_ request: GenerationRequest) throws -> GenerationRequest {
        guard request.kind == .voice else { throw CommandError.invalid("voxcpm makes voice only (kind voice)") }
        let s = try VoiceSetup.resolve(text: request.prompt, options: request.options, profiles: profiles, config: config)
        var r = request
        var o = request.options ?? [:]
        o["voice"] = s.voice
        o["language"] = s.language
        o["tone"] = s.tone
        o["modelText"] = s.modelText
        o["ref"] = s.ref.wav
        o["refText"] = s.ref.text
        o["lora"] = s.lora ?? "none"
        r.options = o
        r.seed = request.seed ?? GenerationRequest.defaultSeed(request.prompt)
        return r
    }

    /// The JSON vox_say.py reads (one item: generate.run renders one take per request).
    func input(_ r: GenerationRequest, job: URL) throws -> String {
        guard let o = r.options, let text = o["modelText"], let ref = o["ref"], let refText = o["refText"] else {
            throw CommandError.invalid("voxcpm: the request was not prepared (no modelText)")
        }
        let lora = o["lora"].flatMap { $0 == "none" ? nil : $0 }
        let value: JSONValue = [
            "model": .string(config.url(config.voxcpmModel).path),
            "lora": lora.map { .string($0) } ?? .null,
            "ref": ["wav": .string(ref), "text": .string(refText)],
            "items": [["text": .string(text), "seed": .number(Double(r.seed ?? 0)), "out": .string(job.appendingPathComponent("result.wav").path)]],
        ]
        return value.text()
    }

    public func process(_ r: GenerationRequest, job: URL) throws -> GenerationProcess {
        EngineScripts.refresh([id])   // the app's vox_say.py, if an update changed it (#61)
        return GenerationProcess(config.url(config.uv),
                          ["run", "--frozen", "--project", config.url(config.voxcpmProject).path, "python", "-I",
                           config.url(config.voxcpmScript).path, try input(r, job: job)],
                          environment: ["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"])
    }

    public func collect(_ r: GenerationRequest, job: URL, stdout: String) throws -> GenerationOutput {
        guard let json = Generation.lastJSON(stdout), let file = json["files"]?.arrayValue?.first?.stringValue,
              FileManager.default.fileExists(atPath: file) else {
            throw CommandError(.io, "vox_say.py printed no result file")
        }
        return GenerationOutput(file: file, model: "voxcpm2", seed: r.seed, remoteID: nil, seconds: json["wall_seconds"]?.doubleValue)
    }
}

/// Splitting a voice-over and timing its words (voice.say).
public enum VoiceScript {
    /// Paragraphs (blank-line separated, whitespace collapsed). A paragraph longer than `limit` characters is split at
    /// sentence ends: VoxCPM renders whole paragraphs well, very long ones drift.
    public static func paragraphs(_ text: String, limit: Int = 450) -> [String] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }.filter { !$0.isEmpty }
        return blocks.flatMap { p -> [String] in
            guard p.count > limit else { return [p] }
            var out: [String] = [], current = ""
            for s in sentences(p) {
                if !current.isEmpty, current.count + s.count + 1 > limit { out.append(current); current = s }
                else { current = current.isEmpty ? s : current + " " + s }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
    }

    /// About how long `text` takes to say (~2.5 words per second, as the cloned voices speak): shown before rendering.
    public static func estimatedSeconds(_ text: String) -> Double {
        let words = text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
        return words == 0 ? 0 : Double(words) / 2.5 + 0.4
    }

    /// About how long rendering takes: one model load per paragraph (~20 s) plus about 1.3× the speech.
    public static func estimatedRenderSeconds(speech: Double, paragraphs: Int) -> Double {
        Double(paragraphs) * 20 + speech * 1.3
    }

    static func sentences(_ p: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(p)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            if ".!?…".contains(ch), i + 1 == chars.count || chars[i + 1] == " " {
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur.trimmingCharacters(in: .whitespaces)) }
        return out
    }

    /// The words of `text` (real spelling, punctuation attached) with times from what a recognizer heard in the
    /// rendered audio: matched words take the heard times, unmatched runs ("We Sites" heard as "8 sites") share the
    /// gap between their matched neighbours by length.
    public static func timedWords(_ text: String, heard: [Word], duration: Double) -> [Word] {
        // French typography spaces « ? ! : ; » off the word: such a mark joins the previous word (no-break space).
        var tokens: [String] = []
        for t in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if !tokens.isEmpty, !t.contains(where: { $0.isLetter || $0.isNumber }) { tokens[tokens.count - 1] += "\u{00A0}" + t }
            else { tokens.append(t) }
        }
        guard !tokens.isEmpty else { return [] }
        let a = tokens.map { ScriptAligner.normalize($0) }, b = heard.map { ScriptAligner.normalize($0.text) }
        func same(_ i: Int, _ j: Int) -> Bool { !a[i].isEmpty && ScriptAligner.similarity(a[i], b[j]) >= 0.75 }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if !b.isEmpty {
            for i in 1...a.count { for j in 1...b.count { dp[i][j] = same(i - 1, j - 1) ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1]) } }
        }
        var match = [Int?](repeating: nil, count: a.count)
        var i = a.count, j = b.count
        while i > 0, j > 0 {
            if same(i - 1, j - 1), dp[i][j] == dp[i - 1][j - 1] + 1 { match[i - 1] = j - 1; i -= 1; j -= 1 }
            else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 } else { j -= 1 }
        }
        var out: [Word] = []
        var k = 0
        while k < tokens.count {
            if let m = match[k] {
                out.append(Word(text: tokens[k], start: heard[m].start, end: heard[m].end, probability: heard[m].probability))
                k += 1
                continue
            }
            var e = k
            while e < tokens.count, match[e] == nil { e += 1 }
            let from = out.last?.end.seconds ?? (heard.first.map { min($0.start.seconds, 0.1) } ?? 0.1)
            let to = e < tokens.count ? heard[match[e]!].start.seconds : max(from, (heard.last?.end.seconds ?? duration))
            let span = max(0.05 * Double(e - k), to - from)
            let weights = tokens[k..<e].map { Double(max($0.count, 1)) }, total = weights.reduce(0, +)
            var t = from
            for (n, w) in weights.enumerated() {
                let d = span * w / total
                out.append(Word(text: tokens[k + n], start: MediaTime(seconds: t), end: MediaTime(seconds: min(t + d, max(t + 0.05, duration)))))
                t += d
            }
            k = e
        }
        return out
    }
}
