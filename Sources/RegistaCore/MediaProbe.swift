import Foundation

/// Reads media metadata. The real one runs ffprobe; tests use a fake.
public protocol MediaProber {
    func probe(_ url: URL) throws -> ProbedMedia
}

public struct ProbedMedia: Hashable, Sendable {
    public var duration: MediaTime
    public var video: VideoInfo?
    public var audio: AudioInfo?

    public init(duration: MediaTime, video: VideoInfo? = nil, audio: AudioInfo? = nil) {
        self.duration = duration
        self.video = video
        self.audio = audio
    }
}

/// `ffprobe -show_format -show_streams` in a subprocess.
public struct FFProbe: MediaProber {
    public let executable: URL

    public init(executable: URL? = nil) {
        self.executable = executable ?? Self.locate()
    }

    /// Where every tool is found (#107): $REGISTA_FFPROBE, then the ffprobe the app ships, then the one engines.json names,
    /// then the usual Homebrew locations.
    static func locate() -> URL {
        if let env = ProcessInfo.processInfo.environment["REGISTA_FFPROBE"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let shipped = ShippedTools.path("ffprobe") { return URL(fileURLWithPath: shipped) }
        let configured = EngineConfig.expand(EngineConfig.loadOrDefault().config.ffprobe)
        let candidates = [configured, "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        return URL(fileURLWithPath: found ?? configured)
    }

    public func probe(_ url: URL) throws -> ProbedMedia {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CommandError(.io, "ffprobe not found at \(executable.path): it ships inside Regista.app (reinstall the app), or set ffprobe in engines.json or REGISTA_FFPROBE")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting: a full pipe would block ffprobe forever.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError(.io, "ffprobe failed on \(url.lastPathComponent): \(msg)")
        }
        return try Self.parse(data)
    }

    /// Parses ffprobe's JSON. Uses the first video and first audio stream.
    public static func parse(_ data: Data) throws -> ProbedMedia {
        let json = try JSONValue.parse(data)
        let streams = json["streams"]?.arrayValue ?? []
        let videoStream = streams.first { $0["codec_type"]?.stringValue == "video" && !isAttachedPicture($0) }
        let audioStream = streams.first { $0["codec_type"]?.stringValue == "audio" }

        var video: VideoInfo?
        if let v = videoStream, let w = intField(v["width"]), let h = intField(v["height"]) {
            let rotation = Self.rotation(of: v)
            let swap = abs(rotation) % 180 == 90
            let rate = v["r_frame_rate"]?.stringValue.flatMap(Rational.init(parsing:))
                ?? v["avg_frame_rate"]?.stringValue.flatMap(Rational.init(parsing:))
                ?? Rational(30)
            video = VideoInfo(width: swap ? h : w, height: swap ? w : h, frameRate: rate,
                              codec: v["codec_name"]?.stringValue ?? "?", rotation: rotation)
            let pix = v["pix_fmt"]?.stringValue ?? ""
            if ["yuva", "rgba", "argb", "bgra", "abgr", "gbrap", "ya8", "ya16", "rgba64"].contains(where: pix.hasPrefix)
                || v["tags"]?["alpha_mode"]?.stringValue == "1" || v["tags"]?["ALPHA_MODE"]?.stringValue == "1" {
                video?.alpha = true
            }
        }
        var audio: AudioInfo?
        if let a = audioStream {
            audio = AudioInfo(sampleRate: intField(a["sample_rate"]) ?? 0, channels: intField(a["channels"]) ?? 0,
                              codec: a["codec_name"]?.stringValue ?? "?")
        }

        // Prefer the exact stream duration (duration_ts × time_base), then the container's.
        var duration: MediaTime?
        if let s = videoStream ?? audioStream, let ts = intField(s["duration_ts"]),
           let tb = s["time_base"]?.stringValue.flatMap(Rational.init(parsing:)), tb.num == 1 {
            duration = MediaTime(value: Int64(ts), timescale: tb.den)
        }
        if duration == nil, let d = json["format"]?["duration"]?.stringValue.flatMap(Double.init) {
            duration = MediaTime(seconds: d)
        }
        // A still image has no duration: it lasts as long as it is placed for.
        if duration == nil, let v = videoStream, audioStream == nil,
           ["png", "mjpeg", "webp", "tiff", "bmp", "gif", "jpegxl", "heic"].contains(v["codec_name"]?.stringValue ?? "") {
            duration = ImageSource.stillDuration
        }
        guard let duration, video != nil || audio != nil else {
            throw CommandError(.io, "ffprobe: no audio or video stream with a duration")
        }
        return ProbedMedia(duration: duration, video: video, audio: audio)
    }

    private static func isAttachedPicture(_ s: JSONValue) -> Bool {
        s["disposition"]?["attached_pic"]?.doubleValue == 1
    }

    /// Display matrix rotation (side data) or the legacy "rotate" tag, normalized to -180...180.
    private static func rotation(of s: JSONValue) -> Int {
        var r = 0
        for side in s["side_data_list"]?.arrayValue ?? [] {
            if let v = intField(side["rotation"]) { r = v }
        }
        if r == 0, let tag = intField(s["tags"]?["rotate"]) { r = -tag }
        return r
    }

    /// ffprobe prints some numbers as strings ("48000").
    private static func intField(_ v: JSONValue?) -> Int? {
        switch v {
        case .number(let n): Int(n)
        case .string(let s): Int(s)
        default: nil
        }
    }
}
