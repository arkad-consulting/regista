import Foundation

/// Where the external engines live. Defaults are where scripts/install.sh puts them
/// (`~/Library/Application Support/Regista/engines`); any key can be overridden in
/// `~/Library/Application Support/Regista/engines.json` (or the file named by `$REGISTA_ENGINES`), which the
/// installer writes. Paths may start with `~`. Large models are referenced in place, never copied.
/// ffmpeg, ffprobe, whisper-cli and deep-filter shipped inside the app (`ShippedTools`, #107) win over engines.json and the
/// defaults, so a downloaded app always runs its own; a developer's build ships none.
public struct EngineConfig: Codable, Hashable, Sendable {
    public var ffmpeg = ShippedTools.path("ffmpeg") ?? EngineConfig.developerDefaults["ffmpeg"]!
    public var ffprobe = ShippedTools.path("ffprobe") ?? EngineConfig.developerDefaults["ffprobe"]!
    /// whisper.cpp CLI: shipped in the app, else built from the pinned tag by scripts/build-whisper.sh.
    public var whisperCpp = ShippedTools.path("whisper-cli") ?? EngineConfig.developerDefaults["whisperCpp"]!
    /// ggml copy of openai/whisper-large-v3-turbo (sha256 = the Hugging Face LFS hash of ggerganov/whisper.cpp, from engines.lock).
    public var whisperModel = "\(EngineConfig.managedDirectory)/models/ggml-large-v3-turbo.bin"
    public var whisperModelSha256 = EngineManifest.shared.artifact("ggml-large-v3-turbo")!.sha256
    public var whisperThreads = 8
    /// WhisperX runs in the uv environment of engines/whisperx, set up by the installer (Medium tier and up).
    /// The pinned uv the installer puts in the engines folder (#109: no Homebrew), with the pinned Python beside it.
    public var uv = "\(EngineConfig.managedDirectory)/uv/uv-\(EngineManifest.shared.artifact("uv-bin")!.version)/uv"
    public var whisperXProject = "\(EngineConfig.managedDirectory)/whisperx"
    public var whisperXScript = "\(EngineConfig.managedDirectory)/whisperx/wx_align.py"
    /// DeepFilterNet3 release binary (model embedded; version and hash from engines.lock). The release publishes no
    /// checksum: this is the hash of the downloaded asset, checked by engines.status.
    public var deepFilter = ShippedTools.path("deep-filter") ?? EngineConfig.developerDefaults["deepFilter"]!
    public var deepFilterSha256 = EngineManifest.shared.artifact("deep-filter")!.sha256
    /// Transcripts are cached here by audio hash + engine (re-running a scenario costs nothing).
    public var cacheDirectory = "~/Library/Caches/Regista"
    /// Sound-effect library listed by sfx.library (mp3 files + manifest.json); `name` in sfx.add resolves here. Not
    /// shipped (Pixabay's licence forbids redistributing the files): put your own library there or point this key at it.
    public var sfxLibrary = "~/Library/Application Support/Regista/sfx"
    /// Blender (graphics.blenderTitle; the version installer pins in engines.lock), separate process.
    public var blender = "~/Applications/Blender.app/Contents/MacOS/Blender"
    /// Node.js and the HyperFrames CLI that scripts/install.sh puts in the engines folder (Medium tier): the official Node
    /// build pinned in engines.lock and engines/hyperframes/package-lock.json installed with `npm ci --ignore-scripts`.
    public var node = "\(EngineConfig.managedDirectory)/node/node-v\(EngineManifest.shared.artifact("node")!.version)-darwin-arm64/bin/node"
    public var hyperframes = "\(EngineConfig.managedDirectory)/hyperframes/node_modules/hyperframes/bin/hyperframes.mjs"
    /// npx for graphics.hyperframes when the installed CLI above is missing (nil: searched in PATH, fnm and Homebrew).
    public var npx: String?
    /// ComfyUI CLI `comfy-gen`: Z-Image stills and Wan 2.2 image-to-video (generate.run, Pro tier, manual setup).
    public var comfyGen = "~/.local/bin/comfy-gen"
    /// ComfyUI workflow runner: Real-ESRGAN + RIFE upscale to 1080×1920 30 fps, ACE-Step 1.5 music (Pro tier, manual setup).
    public var comfyRun = "\(EngineConfig.managedDirectory)/comfy/comfy_run.py"
    public var python3 = "/usr/bin/python3"
    /// Higgsfield CLI (paid; nil: searched in PATH, fnm's default alias, ~/.local/bin, Homebrew).
    public var higgsfield: String?
    /// The only HyperFrames CLI version graphics.hyperframes runs (supply-chain rule: pinned, ≥ 2 weeks old; not configurable;
    /// from engines.lock, the version engines/hyperframes/package-lock.json resolves).
    public static let hyperframesVersion = EngineManifest.shared.artifact("hyperframes-env")!.version
    /// VoxCPM2 voice-over (generate.run kind voice, Medium tier): the uv environment of engines/voxcpm, its script and
    /// the base weights (openbmb/VoxCPM2).
    public var voxcpmProject = "\(EngineConfig.managedDirectory)/voxcpm"
    public var voxcpmScript = "\(EngineConfig.managedDirectory)/voxcpm/vox_say.py"
    public var voxcpmModel = "\(EngineConfig.managedDirectory)/voxcpm/VoxCPM2"
    /// Force a tier ("base", "medium", "pro") instead of detecting it from the RAM.
    public var tier: String?
    /// Default transcription engine per tier, e.g. {"base": "whisper.cpp", "medium": "whisperx"}.
    public var transcription: [String: String]?

    /// Where scripts/install.sh puts the engines.
    public static let managedDirectory = "~/Library/Application Support/Regista/engines"

    /// The defaults of the keys a release build ships a helper for (#107), as a build without them uses them: Homebrew's
    /// ffmpeg, the installer's whisper.cpp build and DeepFilterNet download.
    public static let developerDefaults: [String: String] = [
        "ffmpeg": "/opt/homebrew/bin/ffmpeg",
        "ffprobe": "/opt/homebrew/bin/ffprobe",
        "whisperCpp": "\(EngineConfig.managedDirectory)/whisper.cpp-\(EngineManifest.shared.artifact("whisper-src")!.version)/bin/whisper-cli",
        "deepFilter": "\(EngineConfig.managedDirectory)/deepfilternet/deep-filter-\(EngineManifest.shared.artifact("deep-filter")!.version)-aarch64-apple-darwin",
    ]

    public init() {}

    /// The engines.json that is read, if any.
    public static var defaultFile: URL {
        if let env = ProcessInfo.processInfo.environment["REGISTA_ENGINES"], !env.isEmpty {
            return URL(fileURLWithPath: expand(env))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Regista/engines.json")
    }

    /// Defaults overlaid with the file (missing file = defaults). A malformed file is an error, not ignored.
    public static func load(from file: URL = defaultFile) throws -> EngineConfig {
        guard let data = FileManager.default.contents(atPath: file.path) else { return EngineConfig() }
        do { return try JSONDecoder().decode(EngineConfig.self, from: data) }
        catch { throw CommandError(.io, "Unreadable engine config \(file.path): \(error)") }
    }

    /// Loads, falling back to the defaults (with the reason) when the file is broken.
    public static func loadOrDefault() -> (config: EngineConfig, warning: String?) {
        do { return (try load(), nil) } catch { return (EngineConfig(), "\(error)") }
    }

    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
    public func url(_ path: String) -> URL { URL(fileURLWithPath: Self.expand(path)) }

    // Every key optional in the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineConfig()
        // A shipped helper wins over the file (#107).
        ffmpeg = try ShippedTools.path("ffmpeg") ?? c.decodeIfPresent(String.self, forKey: .ffmpeg) ?? d.ffmpeg
        ffprobe = try ShippedTools.path("ffprobe") ?? c.decodeIfPresent(String.self, forKey: .ffprobe) ?? d.ffprobe
        whisperCpp = try ShippedTools.path("whisper-cli") ?? c.decodeIfPresent(String.self, forKey: .whisperCpp) ?? d.whisperCpp
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        whisperModelSha256 = try c.decodeIfPresent(String.self, forKey: .whisperModelSha256) ?? d.whisperModelSha256
        whisperThreads = try c.decodeIfPresent(Int.self, forKey: .whisperThreads) ?? d.whisperThreads
        uv = try c.decodeIfPresent(String.self, forKey: .uv) ?? d.uv
        whisperXProject = try c.decodeIfPresent(String.self, forKey: .whisperXProject) ?? d.whisperXProject
        whisperXScript = try c.decodeIfPresent(String.self, forKey: .whisperXScript) ?? d.whisperXScript
        deepFilter = try ShippedTools.path("deep-filter") ?? c.decodeIfPresent(String.self, forKey: .deepFilter) ?? d.deepFilter
        deepFilterSha256 = try c.decodeIfPresent(String.self, forKey: .deepFilterSha256) ?? d.deepFilterSha256
        cacheDirectory = try c.decodeIfPresent(String.self, forKey: .cacheDirectory) ?? d.cacheDirectory
        sfxLibrary = try c.decodeIfPresent(String.self, forKey: .sfxLibrary) ?? d.sfxLibrary
        blender = try c.decodeIfPresent(String.self, forKey: .blender) ?? d.blender
        node = try c.decodeIfPresent(String.self, forKey: .node) ?? d.node
        hyperframes = try c.decodeIfPresent(String.self, forKey: .hyperframes) ?? d.hyperframes
        npx = try c.decodeIfPresent(String.self, forKey: .npx)
        comfyGen = try c.decodeIfPresent(String.self, forKey: .comfyGen) ?? d.comfyGen
        comfyRun = try c.decodeIfPresent(String.self, forKey: .comfyRun) ?? d.comfyRun
        python3 = try c.decodeIfPresent(String.self, forKey: .python3) ?? d.python3
        higgsfield = try c.decodeIfPresent(String.self, forKey: .higgsfield)
        voxcpmProject = try c.decodeIfPresent(String.self, forKey: .voxcpmProject) ?? d.voxcpmProject
        voxcpmScript = try c.decodeIfPresent(String.self, forKey: .voxcpmScript) ?? d.voxcpmScript
        voxcpmModel = try c.decodeIfPresent(String.self, forKey: .voxcpmModel) ?? d.voxcpmModel
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        transcription = try c.decodeIfPresent([String: String].self, forKey: .transcription)
    }
}

/// What the machine can run, from its RAM. Base must produce a full reel without Python.
public enum MachineTier: String, Codable, CaseIterable, Comparable, Sendable {
    /// whisper.cpp, DeepFilterNet, Vision, ffmpeg (RAM thresholds and every engine's tier: scripts/engines.manifest.json).
    case base
    /// + WhisperX precise alignment, VoxCPM2 voice-over (Python, uv envs).
    case medium
    /// + voice training and heavy generative engines (ComfyUI stills, clips, upscale, music).
    case pro

    /// The manifest's thresholds (`detectFromGB`, a little below the nominal sizes, which the OS under-reports on some models).
    public static func detect(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> MachineTier {
        EngineManifest.shared.tier(forMemoryGB: Double(physicalMemory) / 1_073_741_824)
    }

    /// `$REGISTA_TIER`, then the config, then the RAM.
    public static func resolve(_ config: EngineConfig) -> MachineTier {
        if let env = ProcessInfo.processInfo.environment["REGISTA_TIER"], let t = MachineTier(rawValue: env) { return t }
        if let c = config.tier, let t = MachineTier(rawValue: c) { return t }
        return detect()
    }

    public static func < (a: MachineTier, b: MachineTier) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Default transcription engine, chosen from the benchmark in the README (WhisperX: 97% of word
    /// starts within 100 ms at pauses; whisper.cpp DTW: 69%).
    public func defaultTranscriber(_ config: EngineConfig) -> String {
        if let configured = config.transcription?[rawValue] { return configured }
        return self >= EngineManifest.shared.minimumTier(WhisperXTranscriber.engineID) ? WhisperXTranscriber.engineID : WhisperCppTranscriber.engineID
    }
}
