import Foundation

/// `AudioToolkit` on the ffmpeg CLI.
public struct FFmpegAudio: AudioToolkit {
    public let executable: URL

    public init(config: EngineConfig) {
        executable = config.url(config.ffmpeg)
    }

    static let quiet = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]

    /// Mono downmix filter for a source with `channels` channels (0.5 L + 0.5 R, like voice.py).
    static func monoFilter(_ channels: Int) -> String {
        switch channels {
        case 1: "aformat=channel_layouts=mono"
        case 2: "pan=mono|c0=0.5*c0+0.5*c1"
        default: "aformat=channel_layouts=mono"
        }
    }

    public func extractAudio(from source: URL, channels: Int, speech: URL, working: URL) throws {
        // first_pts=0 pads (or trims) so sample 0 sits at t = 0 even if the audio track starts late.
        let align = "aresample=async=1:first_pts=0"
        let mono = Self.monoFilter(channels)
        // -progress pipe:1: the position in the source on stdout, for the job's progress (CommandJob).
        try CommandJob.stage(0, 0.5) {
            try Subprocess.check(executable, Self.quiet + ["-progress", "pipe:1", "-i", source.path, "-map", "0:a:0", "-af", "\(align),\(mono)",
                                                           "-ar", "16000", "-c:a", "pcm_s16le", speech.path], progress: .ffmpeg)
        }
        try CommandJob.stage(0.5, 1) {
            try Subprocess.check(executable, Self.quiet + ["-progress", "pipe:1", "-i", source.path, "-map", "0:a:0", "-af", "\(align),\(mono)",
                                                           "-ar", "48000", "-c:a", "pcm_s16le", working.path], progress: .ffmpeg)
        }
    }

    public func loudness(of spans: [AudioSpan]) throws -> Loudness {
        guard !spans.isEmpty else { throw CommandError.invalid("loudness: nothing to measure") }
        var args = ["-nostdin", "-hide_banner", "-nostats"]
        var graph = ""
        for (k, s) in spans.enumerated() {
            if let start = s.start { args += ["-ss", String(format: "%.6f", start.seconds)] }
            if let end = s.end { args += ["-t", String(format: "%.6f", (end - (s.start ?? .zero)).seconds)] }
            args += ["-i", s.url.path]
            let stereo = s.channels == 1 ? "pan=stereo|c0=c0|c1=c0" : "aformat=channel_layouts=stereo"
            graph += "[\(k):a:0]\(stereo),aresample=48000[s\(k)];"
        }
        graph += (0..<spans.count).map { "[s\($0)]" }.joined() + "concat=n=\(spans.count):v=0:a=1,ebur128=peak=true:framelog=quiet"
        let r = try Subprocess.check(executable, args + ["-filter_complex", graph, "-f", "null", "-"])
        return try Self.parseEBUR128(r.stderrText)
    }

    public func mix(_ clips: [AudioMixClip], length: Int, rate: Int, gain: Double = 0, ceiling: Double, to output: URL) throws {
        guard length > 0 else { throw CommandError.invalid("mix: empty timeline") }
        let work = TemporaryFolder.url.appendingPathComponent("regista-stretch-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: work) }
        let clips = try prestretched(clips, rate: rate, in: work)
        var args = Self.quiet
        var inputs: [String: Int] = [:]
        for c in clips where inputs[c.path] == nil {
            inputs[c.path] = inputs.count
            args += ["-i", c.path]
        }
        // Gain envelopes (ducking): one input each, split per clip that uses it.
        var envInputs: [String: Int] = [:]
        for c in clips { if let e = c.envelope?.path, envInputs[e] == nil { envInputs[e] = inputs.count + envInputs.count; args += ["-i", e] } }
        // Silence of the full length underneath: the mix always has the timeline's duration.
        let silence = inputs.count + envInputs.count
        args += ["-f", "lavfi", "-t", String(format: "%.6f", Double(length) / Double(rate)), "-i", "anullsrc=r=\(rate):cl=stereo"]
        var uses: [String: Int] = [:]
        for c in clips { uses[c.path, default: 0] += 1 }
        var graph = ""
        var split: [String: [String]] = [:]
        for (path, n) in uses {
            let i = inputs[path]!
            let channels = clips.first { $0.path == path }!.channels
            let stereo = channels == 1 ? "pan=stereo|c0=c0|c1=c0" : "aformat=channel_layouts=stereo"
            let labels = (0..<n).map { "i\(i)s\($0)" }
            graph += "[\(i):a:0]aresample=\(rate):async=1:first_pts=0,\(stereo),asplit=\(n)" + labels.map { "[\($0)]" }.joined() + ";"
            split[path] = labels
        }
        var envSplit: [String: [String]] = [:]
        for (path, i) in envInputs {
            let n = clips.filter { $0.envelope?.path == path }.count
            let labels = (0..<n).map { "e\(i)s\($0)" }
            graph += "[\(i):a:0]aresample=\(rate),pan=stereo|c0=c0|c1=c0,asplit=\(n)" + labels.map { "[\($0)]" }.joined() + ";"
            envSplit[path] = labels
        }
        var mixed: [String] = []
        for (k, c) in clips.enumerated() {
            let label = split[c.path]!.removeFirst()   // one split output per clip
            let d = Double(c.timelineLength) / Double(rate)
            var chain = "[\(label)]atrim=start_sample=\(c.sourceStart):end_sample=\(c.sourceEnd),asetpts=N/SR/TB"

            if c.fadeIn > 0 { chain += String(format: ",afade=t=in:st=0:d=%.6f", c.fadeIn) }
            if c.fadeOut > 0 { chain += String(format: ",afade=t=out:st=%.6f:d=%.6f", max(d - c.fadeOut, 0), c.fadeOut) }
            if c.gain != 0 { chain += String(format: ",volume=%.4fdB", c.gain) }
            chain += ",adelay=delays=\(c.timelineStart)S:all=1"
            if let e = c.envelope?.path, let env = envSplit[e]?.removeFirst() {
                chain += ",apad=whole_len=\(length),atrim=end_sample=\(length)[p\(k)];[p\(k)][\(env)]amultiply"
            }
            graph += chain + "[m\(k)];"
            mixed.append("[m\(k)]")
        }
        let limit = String(format: "%.5f", pow(10, ceiling / 20))
        let master = gain != 0 ? String(format: "volume=%.4fdB,", gain) : ""
        graph += "[\(silence):a]" + mixed.joined() + "amix=inputs=\(clips.count + 1):normalize=0:duration=first:dropout_transition=0,"
            + master + "alimiter=limit=\(limit):attack=5:release=50:level=false:latency=true,atrim=end_sample=\(length)[out]"
        try Subprocess.check(executable, args + ["-filter_complex", graph, "-map", "[out]", "-ar", String(rate), "-c:a", "pcm_s24le", output.path])
    }

    /// Retimed clips (clip.speed) become stretched wav files first (TimeStretch: sample-accurate time map, pitch kept),
    /// placed like any clip. Each source is decoded once per mix.
    func prestretched(_ clips: [AudioMixClip], rate: Int, in dir: URL) throws -> [AudioMixClip] {
        guard clips.contains(where: \.isStretched) else { return clips }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var decoded: [String: WAVAudio] = [:]
        return try clips.enumerated().map { k, c in
            guard c.isStretched else { return c }
            if decoded[c.path] == nil {
                let wav = dir.appendingPathComponent("src-\(decoded.count).wav")
                try Subprocess.check(executable, Self.quiet + ["-i", c.path, "-map", "0:a:0", "-ac", "2", "-ar", String(rate), "-c:a", "pcm_s16le", wav.path])
                decoded[c.path] = try WAVAudio.read(wav)
                try? FileManager.default.removeItem(at: wav)
            }
            let src = decoded[c.path]!
            let a = max(c.sourceStart - rate / 10, 0), b = min(c.sourceEnd + rate / 10, src.frameCount)   // margin for the search
            let slice = Array(src.samples[(a * 2)..<(max(b, a) * 2)])
            let offset = Double(c.sourceStart - a)
            let out = TimeStretch.stretch(slice, channels: 2, length: c.timelineLength, rate: rate) { offset + c.sourceOffset(atOutput: $0) }
            let url = dir.appendingPathComponent("stretched-\(k).wav")
            try WAVAudio(sampleRate: rate, channels: 2, samples: out).write16(to: url)
            var s = c
            s.path = url.path
            s.channels = 2
            s.sourceStart = 0
            s.sourceEnd = c.timelineLength
            s.tempo = 1
            s.timeMap = nil
            s.mapLength = nil
            return s
        }
    }

    /// Reads the "Summary:" block ebur128 prints at the end.
    static func parseEBUR128(_ log: String) throws -> Loudness {
        guard let summary = log.range(of: "Summary:", options: .backwards).map({ String(log[$0.upperBound...]) }) else {
            throw CommandError(.io, "ffmpeg ebur128: no summary in output")
        }
        func value(_ label: String, after section: String) -> Double? {
            guard let s = summary.range(of: section) else { return nil }
            let rest = summary[s.upperBound...]
            guard let l = rest.range(of: label) else { return nil }
            let tail = rest[l.upperBound...].trimmingCharacters(in: .whitespaces)
            return Double(tail.prefix { $0 == "-" || $0 == "." || $0.isNumber || $0 == "i" || $0 == "n" || $0 == "f" }
                .replacingOccurrences(of: "inf", with: "infinity"))
        }
        guard let i = value("I:", after: "Integrated loudness"), let tp = value("Peak:", after: "True peak") else {
            throw CommandError(.io, "ffmpeg ebur128: unreadable summary")
        }
        return Loudness(integrated: i, truePeak: tp, range: value("LRA:", after: "Loudness range") ?? 0,
                        threshold: value("Threshold:", after: "Integrated loudness") ?? -70)
    }
}
