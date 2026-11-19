import Foundation

/// whisper.cpp (`whisper-cli`, Metal) with DTW token timestamps: the Base-tier engine, no Python.
/// Whole file in one pass (30 s windows) with `-mc 0`: no text context carried between windows,
/// so repeated takes are not merged away. Word start = DTW time of its first token; word end =
/// DTW time of its last spoken (non-punctuation) token + 0.10 s, capped at the next word's start
/// and pulled back out of trailing silence (see `clampEnds`).
public struct WhisperCppTranscriber: Transcriber {
    public static let engineID = "whisper.cpp"
    public let id = Self.engineID
    public let executable: URL
    public let modelURL: URL
    public let threads: Int

    public init(config: EngineConfig) {
        executable = config.url(config.whisperCpp)
        modelURL = config.url(config.whisperModel)
        threads = config.whisperThreads
    }

    public var model: String { modelURL.deletingPathExtension().lastPathComponent }

    /// whisper.cpp's DTW alignment-head preset for the model, from its file name.
    var dtwPreset: String? {
        let name = modelURL.lastPathComponent
        for (key, preset) in [("large-v3-turbo", "large.v3.turbo"), ("large-v3", "large.v3"), ("large-v2", "large.v2"),
                              ("medium", "medium"), ("small", "small"), ("base", "base"), ("tiny", "tiny")]
        where name.contains(key) {
            return preset
        }
        return nil
    }

    public func unavailableReason() -> String? {
        if !FileManager.default.isExecutableFile(atPath: executable.path) {
            return "whisper-cli not found at \(executable.path)" + ReleaseBuild.sourceHint(" (run scripts/build-whisper.sh)", release: " (install Regista again from its disk image)")
        }
        if !FileManager.default.fileExists(atPath: modelURL.path) { return "whisper model not found at \(modelURL.path)" }
        return nil
    }

    public func transcribe(_ speech16k: URL, language: String) throws -> Transcript {
        if let reason = unavailableReason() { throw CommandError(.io, reason) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("out")
        // -pp: "progress = N%" on stderr after each 30 s window (the job's progress); "auto" lets whisper detect the language.
        var args = ["-m", modelURL.path, "-f", speech16k.path, "-l", language, "-t", String(threads),
                    "-mc", "0", "-ojf", "-of", base.path, "-np", "-pp"]
        if let dtwPreset { args += ["-nfa", "-dtw", dtwPreset] }   // DTW needs flash attention off
        try Subprocess.check(executable, args, progress: .whisper)
        guard let data = FileManager.default.contents(atPath: base.path + ".json") else {
            throw CommandError(.io, "whisper-cli wrote no JSON")
        }
        let envelope = try Envelope.read(speech16k)
        let spoken = language == "auto" ? (try? JSONValue.parse(data))?.value(at: "result.language")?.stringValue ?? language : language
        return Transcript(engine: id, model: model, language: spoken, words: Self.clampEnds(try Self.parse(data), envelope))
    }

    /// The spoken language of a 16 kHz wav ("it", "fr"…), detected by whisper on its first 30 s.
    public func detectLanguage(_ speech16k: URL) throws -> String {
        if let reason = unavailableReason() { throw CommandError(.io, reason) }
        let r = try Subprocess.check(executable, ["-m", modelURL.path, "-f", speech16k.path, "-l", "auto", "-dl", "-t", String(threads)])
        let text = r.stderrText + r.stdoutText
        guard let m = text.range(of: #"auto-detected language: [a-z]+"#, options: .regularExpression),
              let code = text[m].split(separator: " ").last else {
            throw CommandError(.io, "whisper-cli did not detect the language")
        }
        return String(code)
    }

    /// DTW puts the last token before a pause at the END of the pause ("tuoi" 56.66–58.30 s when the
    /// voice stops at 56.83 s). A word cannot run through ≥ 150 ms of silence: its end is pulled back
    /// to where that silence starts. Starts are left alone.
    public static func clampEnds(_ words: [Word], _ envelope: Envelope) -> [Word] {
        let (threshold, _) = envelope.speechThreshold()
        let minSilence = 15   // frames of 10 ms
        return words.map { w in
            var w = w
            var f = envelope.frame(w.start.seconds + 0.05)
            let last = min(envelope.frame(w.end.seconds), envelope.db.count)
            var run = 0
            while f < last {
                run = envelope.db[f] < threshold ? run + 1 : 0
                if run == minSilence {
                    let silenceStart = Double(f - minSilence + 1) * Envelope.hop
                    w.end = MediaTime(seconds: max(silenceStart, w.start.seconds + 0.05))
                    break
                }
                f += 1
            }
            return w
        }
    }

    /// Tokens → words: a token starting with a space opens a word; special tokens ([_BEG_]…) are
    /// skipped; punctuation-only words are dropped.
    public static func parse(_ data: Data) throws -> [Word] {
        let json = try JSONValue.parse(data)
        struct Tok { var dtw: Double?; var from: Double; var to: Double; var spoken: Bool }
        var raw: [(text: String, toks: [Tok])] = []
        for seg in json["transcription"]?.arrayValue ?? [] {
            for t in seg["tokens"]?.arrayValue ?? [] {
                guard let text = t["text"]?.stringValue, !text.hasPrefix("[_") else { continue }
                let dtw = t["t_dtw"]?.doubleValue.flatMap { $0 >= 0 ? $0 / 100 : nil }
                let tok = Tok(dtw: dtw, from: (t["offsets"]?["from"]?.doubleValue ?? 0) / 1000,
                              to: (t["offsets"]?["to"]?.doubleValue ?? 0) / 1000,
                              spoken: text.contains { $0.isLetter || $0.isNumber })
                if text.hasPrefix(" ") || raw.isEmpty { raw.append((text.trimmingCharacters(in: .whitespaces), [tok])) }
                else { raw[raw.count - 1].text += text; raw[raw.count - 1].toks.append(tok) }
            }
        }
        let kept = raw.filter { $0.text.contains { $0.isLetter || $0.isNumber } }
        var words: [Word] = []
        for (k, w) in kept.enumerated() {
            // Punctuation tokens closing a segment get late DTW times: time the word by its spoken tokens.
            let first = w.toks.first!, last = w.toks.last(where: \.spoken) ?? w.toks.last!
            var start = first.dtw ?? first.from
            var end = last.dtw.map { $0 + 0.10 } ?? last.to
            if k + 1 < kept.count, let next = kept[k + 1].toks.first.map({ $0.dtw ?? $0.from }) { end = min(end, next) }
            if let prev = words.last { start = max(start, prev.start.seconds) }
            end = max(end, start + 0.02)
            words.append(Word(text: w.text, start: MediaTime(seconds: start), end: MediaTime(seconds: end),
                              probability: nil))
        }
        return words
    }
}

/// WhisperX (faster-whisper large-v3-turbo + pyannote VAD + wav2vec2 forced alignment) in the uv
/// environment scripts/install.sh sets up (engines/whisperx): Medium tier and up. 8 s VAD chunks
/// (longer chunks merge repeated takes) and numbers spelled out in the take's language before
/// alignment are done by wx_align.py; the aligner is the pinned VoxPopuli model of the language.
public struct WhisperXTranscriber: Transcriber {
    public static let engineID = "whisperx"
    public let id = Self.engineID
    /// Id in transcript cache keys (kept from the Italian-only version so cached takes stay valid; the key also
    /// has the language). Each transcript records the aligner of its language.
    public let model = "large-v3-turbo+wav2vec2-voxpopuli-it"
    public let uv: URL
    public let project: URL
    public let script: URL
    /// The folder of the ffmpeg Regista uses: WhisperX runs a bare `ffmpeg` from the PATH to read audio, so on a Mac
    /// without Homebrew it must find the app's own (#109).
    public let ffmpegFolder: String
    /// Its speed on this Mac, for the estimate that fills the job until WhisperX prints its first number (#13).
    public var speeds = EngineSpeeds()

    public init(config: EngineConfig) {
        uv = config.url(config.uv)
        project = config.url(config.whisperXProject)
        script = config.url(config.whisperXScript)
        ffmpegFolder = config.url(config.ffmpeg).deletingLastPathComponent().path
    }

    /// The PATH WhisperX runs with: Regista's ffmpeg first, then this process's, then the system's.
    var environment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        return ["PATH": ([ffmpegFolder] + (inherited.map { [$0] } ?? []) + ["/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":"),
                // Only the pinned Python the installer put beside uv: never a download of another one at run time.
                "UV_PYTHON_DOWNLOADS": "never"]
    }

    public func unavailableReason() -> String? {
        if !FileManager.default.isExecutableFile(atPath: uv.path) { return "uv not found at \(uv.path)" }
        if !FileManager.default.fileExists(atPath: project.appendingPathComponent("pyproject.toml").path) {
            return "no uv project at \(project.path)"
        }
        if !FileManager.default.fileExists(atPath: script.path) { return "wx_align.py not found at \(script.path)" }
        return nil
    }

    /// The pinned aligner of each language, relative to the WhisperX project (scripts/engines.manifest.json `aligner-<lang>`,
    /// put there by scripts/install.sh; wx_align.py never downloads one). English and Portuguese are installed with WhisperX;
    /// Italian and French are CC BY-NC 4.0 and installed only on request (#20).
    public static let aligners: [String: String] = [
        "en": "models/torchaudio/wav2vec2_fairseq_base_ls960_asr_ls960.pth",
        "pt": "models/wav2vec2-large-xlsr-53-portuguese/pytorch_model.bin",
        "it": "models/torchaudio/wav2vec2_voxpopuli_base_10k_asr_it.pt",
        "fr": "models/torchaudio/wav2vec2_voxpopuli_base_10k_asr_fr.pt",
    ]

    /// Why WhisperX cannot align this language here (nil: its pinned aligner is installed).
    public func alignerReason(_ language: String) -> String? {
        guard let rel = Self.aligners[language] else {
            return "WhisperX has no pinned aligner for \"\(language)\" (Regista pins \(Self.aligners.keys.sorted().joined(separator: ", ")))"
        }
        if FileManager.default.fileExists(atPath: project.appendingPathComponent(rel).path) { return nil }
        let id = "aligner-\(language)"
        let e = EngineManifest.shared.entry(id)
        let name = e?.name ?? id
        if e?.nonCommercial == true {
            return "the \(name) is not installed: it is licensed \(e!.licence) (non-commercial use only), so it is installed only on request — Settings › Motori › \(name)" + ReleaseBuild.sourceHint(", or scripts/install.sh --only \(id)")
        }
        return "the \(name) is not installed — Settings › Motori › \(name)" + ReleaseBuild.sourceHint(", or scripts/install.sh --only \(id)")
    }

    public func transcribe(_ speech16k: URL, language: String) throws -> Transcript {
        if let reason = unavailableReason() { throw CommandError(.io, reason) }
        if let reason = alignerReason(language) { throw CommandError(.io, reason) }
        EngineScripts.refresh([Self.engineID])   // the app's wx_align.py / textnorm.py, if an update changed them (#61)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("regista-wx-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        // --frozen: use the locked environment as is, never re-resolve. -u: WhisperX's progress lines arrive as printed
        // (one per batch it transcribed, #13); until the first one — loading, voice detection — and with a wx_align.py
        // installed before it printed any, the job shows an estimate from the take's length and the last run's speed.
        let audio = WAVAudio.duration(of: speech16k)
        let started = Date()
        try CommandJob.estimating(speeds.expected(Self.engineID, audio: audio)) {
            try Subprocess.check(uv, ["run", "--frozen", "--project", project.path, "python", "-I", "-u", script.path,
                                      speech16k.path, out.path, "--lang", language, "--chunk", "8"],
                                 environment: environment, currentDirectory: project, progress: .whisperX)
        }
        speeds.record(Self.engineID, seconds: Date().timeIntervalSince(started), audio: audio)
        guard let data = FileManager.default.contents(atPath: out.path) else { throw CommandError(.io, "wx_align.py wrote no JSON") }
        return Transcript(engine: id, model: "large-v3-turbo+wav2vec2-voxpopuli-\(language)", language: language, words: try Self.parse(data))
    }

    /// `{"words": [{"w", "s", "e", "p"}]}`; words the aligner could not place (s = null) are dropped.
    public static func parse(_ data: Data) throws -> [Word] {
        try (JSONValue.parse(data)["words"]?.arrayValue ?? []).compactMap { w in
            guard let text = w["w"]?.stringValue, let s = w["s"]?.doubleValue, let e = w["e"]?.doubleValue else { return nil }
            return Word(text: text, start: MediaTime(seconds: s), end: MediaTime(seconds: e), probability: w["p"]?.doubleValue)
        }
    }
}
