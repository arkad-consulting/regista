import Foundation

/// The engines a release build of the app ships inside itself (#107): ffmpeg, ffprobe, whisper-cli and deep-filter in
/// `Regista.app/Contents/Helpers`, built by scripts/build-engines.sh and copied by `scripts/build-app.sh --bundle-engines`.
/// Where Regista finds a tool, in one place: an environment override (as today: `REGISTA_FFPROBE`), then the helper the
/// app ships, then the path engines.json names or today's default. A shipped helper wins over engines.json, so everybody
/// who downloaded the same version runs the same tools; a developer's build ships none and finds them where it always did.
public enum ShippedTools {
    /// The helpers a release build ships, by file name.
    public static let names = ["ffmpeg", "ffprobe", "whisper-cli", "deep-filter"]

    /// `$REGISTA_HELPERS` (a folder holding the helpers: the tests and checks point it at scripts/build-engines.sh's
    /// output), else the `Contents/Helpers` folder of the app this process belongs to (the app itself, or regista-mcp /
    /// regista-engine in its Contents/MacOS), nil when there is none.
    public static var directory: URL? {
        if let env = ProcessInfo.processInfo.environment["REGISTA_HELPERS"], !env.isEmpty {
            return URL(fileURLWithPath: EngineConfig.expand(env), isDirectory: true)
        }
        return bundled
    }

    /// `Contents/Helpers` next to this executable's `Contents/MacOS`, when it exists.
    static let bundled: URL? = {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let macOS = exe.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", macOS.deletingLastPathComponent().lastPathComponent == "Contents" else { return nil }
        let helpers = macOS.deletingLastPathComponent().appendingPathComponent("Helpers", isDirectory: true)
        return FileManager.default.fileExists(atPath: helpers.path) ? helpers : nil
    }()

    /// The shipped helper with that name, when there is one (in `directory`: the app's by default).
    public static func path(_ name: String, in directory: URL? = directory) -> String? {
        guard let dir = directory else { return nil }
        let p = dir.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// Whether `path` is one of the shipped helpers.
    public static func isShipped(_ path: String, in directory: URL? = directory) -> Bool {
        guard let dir = directory?.standardizedFileURL.path else { return false }
        let p = URL(fileURLWithPath: EngineConfig.expand(path)).standardizedFileURL.path
        return p.hasPrefix(dir + "/") && names.contains((p as NSString).lastPathComponent)
    }
}
