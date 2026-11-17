import Foundation

/// How long the engines that print no progress took on this Mac (#13): seconds of work per second of audio, from the
/// last run of each, kept in `engine-speed.json` of Regista's support folder. A job estimates its progress from it
/// (`CommandJob.estimating`): the audio's length times the speed the engine had last time here.
public struct EngineSpeeds: Sendable {
    /// nil: `defaultFile`, resolved at each use (a test process points the support folder elsewhere first).
    public var file: URL?

    public init(file: URL? = nil) { self.file = file }

    /// `$REGISTA_SUPPORT_DIR/engine-speed.json`, else `~/Library/Application Support/Regista/engine-speed.json`.
    public static var defaultFile: URL {
        if let s = ProcessInfo.processInfo.environment["REGISTA_SUPPORT_DIR"], !s.isEmpty {
            return URL(fileURLWithPath: EngineConfig.expand(s)).appendingPathComponent("engine-speed.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Regista/engine-speed.json")
    }

    /// Before an engine's first run here: a little slower than a recent Apple silicon Mac, so a first estimate rather
    /// waits at 95 % than jumps at the end.
    public static let fallback: [String: Double] = ["whisperx": 0.6, "deep-filter": 0.05]

    private var url: URL { file ?? Self.defaultFile }

    /// Seconds of work per second of audio: the last run's, else the fallback.
    public func speed(_ engine: String) -> Double? {
        let kept = FileManager.default.contents(atPath: url.path).flatMap { try? JSONValue.parse($0) }?[engine]?.doubleValue
        return kept ?? Self.fallback[engine]
    }

    /// The seconds `engine` should take on `audio` seconds of audio (at least a second); nil when nothing is known.
    public func expected(_ engine: String, audio: Double?) -> Double? {
        guard let audio, audio > 0, let s = speed(engine) else { return nil }
        return max(1, s * audio)
    }

    /// Keeps the speed of a run that ended well (a failed or very short run says nothing about the engine's speed).
    public func record(_ engine: String, seconds: Double, audio: Double?) {
        guard let audio, audio >= 1, seconds > 0 else { return }
        var all = FileManager.default.contents(atPath: url.path).flatMap { try? JSONValue.parse($0) }?.objectValue ?? [:]
        all[engine] = .number((seconds / audio * 1000).rounded() / 1000)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONValue.object(all).data().write(to: url, options: .atomic)
    }
}

extension WAVAudio {
    /// The length of a PCM wav in seconds, from its header and the file's size (without reading the samples); nil when
    /// it is not one.
    public static func duration(of url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8](handle.readData(ofLength: 4096))
        guard head.count >= 12, String(decoding: head[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: head[8..<12], as: UTF8.self) == "WAVE",
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil else { return nil }
        func u16(_ o: Int) -> Int { Int(head[o]) | Int(head[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var bytesPerSecond = 0
        var offset = 12
        while offset + 8 <= head.count {
            let id = String(decoding: head[offset..<offset + 4], as: UTF8.self)
            let body = offset + 8
            if id == "fmt ", body + 12 <= head.count { bytesPerSecond = u32(body + 8) }
            if id == "data" {
                guard bytesPerSecond > 0 else { return nil }
                return Double(size - body) / Double(bytesPerSecond)
            }
            offset = body + u32(offset + 4) + (u32(offset + 4) & 1)
        }
        return nil
    }
}
