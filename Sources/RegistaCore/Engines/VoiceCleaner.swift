import Foundation

/// DeepFilterNet3 (release binary, model embedded) + the Python prototype's voice.py chain, on the whole
/// source so the result is a drop-in replacement of its audio: same length, sample-aligned.
/// 1. deep-filter -D (delay compensated) with an attenuation limit (18 dB keeps some room tone).
/// 2. Per-range gain so every take used by the timeline sits at −30 LUFS (gain of the nearest
///    range in between, so extending a clip later keeps a sensible level), then per-segment level
///    matching (`LevelMatch`): a speech segment more than 6 dB from the main speaker — a second voice
///    off the microphone — is gained toward it, at most 12 dB. Both as one per-sample gain curve.
/// 3. highpass 90 Hz, EQ −3 dB @ 300 Hz / +3 dB @ 4.5 kHz, gentle gate, 2.5:1 compressor
///    (no lookahead anywhere: no delay against the picture).
/// 4. Two-pass linear normalization: measure the timeline (the ranges played in order, as dual
///    mono), then one static gain to the target — what loudnorm linear=true does. If that gain
///    would push the true peak over the limit, a limiter without auto-level follows the gain (and
///    the gain is corrected once for the loudness the limiter took away). Speech at −30 LUFS
///    has peaks ~18 dB above its loudness, so on real takes the limiter is the usual case.
/// Output: 48 kHz stereo (dual mono) 24-bit wav.
public struct DeepFilterVoiceCleaner: VoiceCleaner {
    public let deepFilter: URL
    public let ffmpeg: URL
    let audio: AudioToolkit
    /// Its speed on this Mac: DeepFilterNet prints no progress, the job estimates it (#13).
    public var speeds = EngineSpeeds()
    public static let engineID = "deep-filter"

    public init(config: EngineConfig, audio: AudioToolkit) {
        deepFilter = config.url(config.deepFilter)
        ffmpeg = config.url(config.ffmpeg)
        self.audio = audio
    }

    public func unavailableReason() -> String? {
        if !FileManager.default.isExecutableFile(atPath: deepFilter.path) { return "deep-filter not found at \(deepFilter.path)" }
        if !FileManager.default.isExecutableFile(atPath: ffmpeg.path) { return "ffmpeg not found at \(ffmpeg.path)" }
        return nil
    }

    public func clean(_ r: VoiceCleanRequest) throws -> VoiceCleanReport {
        if let reason = unavailableReason() { throw CommandError(.io, reason) }
        guard !r.ranges.isEmpty else { throw CommandError.invalid("audio.clean: no ranges") }
        let fm = FileManager.default
        let dir = r.workDirectory.appendingPathComponent("clean-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // 1. DeepFilterNet. It names its output after the input.
        let input = dir.appendingPathComponent("voice.wav")
        try fm.copyItem(at: r.input, to: input)
        let dfnDir = dir.appendingPathComponent("dfn")
        // In a job: denoising is most of the time, the chain and the loudness the rest.
        let denoiseSeconds = try CommandJob.stage(0, 0.6) { try denoise(input, into: dfnDir, attenuation: r.attenuation) }
        let denoised = dfnDir.appendingPathComponent("voice.wav")

        // 2. Per-range gains to −30 LUFS (a silent range keeps 0 dB).
        let gains = try r.ranges.map { range -> Double in
            let l = try audio.loudness(of: [AudioSpan(url: denoised, start: range.start, end: range.end, channels: 1)])
            return l.integrated > -60 ? -30 - l.integrated : 0
        }
        // One gain curve over source time: the take gains (switching halfway between ranges) and the level match.
        let wav = try WAVAudio.read(denoised)
        let mono = wav.mono()
        let ranges = r.ranges.map { (start: $0.start.seconds, end: $0.end.seconds) }
        let envelope = Envelope(samples: mono, sampleRate: wav.sampleRate)
        let segs = LevelMatch.segments(envelope, ranges: ranges).map { seg -> (start: Double, end: Double, level: Double) in
            let k = ranges.firstIndex { seg.start >= $0.start - 0.02 && seg.start < $0.end } ?? 0
            return (seg.start, seg.end, seg.level + gains[k])
        }
        let matched = LevelMatch.match(segs, threshold: r.levelMatch, cap: r.levelMatchMax)
        let curve = LevelMatch.curve(count: mono.count, rate: wav.sampleRate, ranges: ranges, rangeGains: gains, segments: matched.segments)
        let gained = dir.appendingPathComponent("gained.wav")
        try WAVAudio(sampleRate: wav.sampleRate, channels: 1, samples: zip(mono, curve).map { $0 * $1 }).writeFloat(to: gained)
        let chain = ["highpass=f=90", "equalizer=f=300:t=q:w=1:g=-3", "equalizer=f=4500:t=q:w=1.2:g=3"]
            + (r.gate ? ["agate=threshold=0.012:ratio=1.8:attack=5:release=150:range=0.25"] : [])
            + ["acompressor=threshold=-20dB:ratio=2.5:attack=8:release=120"]
        let pre = dir.appendingPathComponent("pre.wav")
        try Subprocess.check(ffmpeg, FFmpegAudio.quiet + ["-i", gained.path, "-af", chain.joined(separator: ","),
                                                          "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", pre.path])

        CommandJob.report(0.8)
        // 3. Measure the timeline, then one static gain (+ limiter only if the peak needs it).
        let measured = try audio.loudness(of: r.ranges.map { AudioSpan(url: pre, start: $0.start, end: $0.end, channels: 1) })
        var gain = r.targetLUFS - measured.integrated
        let mode = measured.truePeak + gain > r.truePeak - 0.1 ? "limited" : "linear"
        // DeepFilterNet's delay compensation drops the last few ms: pad back to the source length.
        let frames = try WAVAudio.read(r.input).frameCount
        func render() throws {
            var filters = [String(format: "volume=%.3fdB", gain)]
            if mode == "limited" {
                // alimiter works on sample peaks: leave 0.5 dB for inter-sample overs. latency=true: no delay.
                filters.append(String(format: "alimiter=limit=%.5f:attack=5:release=50:level=false:latency=true", pow(10, (r.truePeak - 0.5) / 20)))
            }
            filters += ["apad=whole_len=\(frames)", "atrim=end_sample=\(frames)", "pan=stereo|c0=c0|c1=c0"]
            try Subprocess.check(ffmpeg, FFmpegAudio.quiet + ["-i", pre.path, "-af", filters.joined(separator: ","),
                                                              "-ar", "48000", "-c:a", "pcm_s24le", r.output.path])
        }
        try render()
        if mode == "limited" {
            // The limiter takes a little loudness away: one correction pass on the measured result.
            let after = try audio.loudness(of: r.ranges.map { AudioSpan(url: r.output, start: $0.start, end: $0.end, channels: 2) })
            if abs(after.integrated - r.targetLUFS) > 0.1 {
                gain += r.targetLUFS - after.integrated
                try render()
            }
        }
        var report = VoiceCleanReport(rangeGains: gains, measured: measured, gain: gain, mode: mode, denoiseSeconds: denoiseSeconds)
        report.mainLevel = matched.main
        report.levelMatch = matched.segments
        return report
    }

    /// DeepFilterNet on `input` (its output is named after it, in `directory`); returns the seconds it took. It prints
    /// no progress: the job shows an estimate from the audio's length and the speed of the last run here, kept for the next.
    func denoise(_ input: URL, into directory: URL, attenuation: Double) throws -> Double {
        let audio = WAVAudio.duration(of: input)
        let t0 = Date()
        try CommandJob.estimating(speeds.expected(Self.engineID, audio: audio)) {
            try Subprocess.check(deepFilter, ["-D", "-a", String(attenuation), "-o", directory.path, input.path])
        }
        let seconds = Date().timeIntervalSince(t0)
        speeds.record(Self.engineID, seconds: seconds, audio: audio)
        return seconds
    }
}
