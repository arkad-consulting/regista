import Foundation

// The two real providers: local ComfyUI (free, Pro tier) and Higgsfield (paid, hard budget). Both are CLIs run as
// separate processes in the job folder.

/// Local ComfyUI through `comfy-gen` (Z-Image Turbo stills, Wan 2.2 14B lightning image-to-video) and the
/// `comfy_run.py` runner (ACE-Step 1.5 music, Real-ESRGAN x4plus + RIFE 4.26 upscale to 1080×1920 at 30 fps).
/// Free and unlimited, but heavy (Wan 14B, ACE-Step; sizes in scripts/engines.manifest.json): Pro tier only, and the server is stopped after
/// each waited-for run unless the caller chains more jobs (`keepRunning`).
public struct ComfyUIProvider: GeneratorProvider {
    public let config: EngineConfig
    public init(config: EngineConfig) { self.config = config }

    public let id = "comfyui"
    public let title = "ComfyUI (local, free)"
    public let paid = false
    public var minimumTier: MachineTier { EngineManifest.shared.minimumTier(id) }
    public let models = [
        GeneratorModel("z-image-turbo", .image, "Z-Image Turbo, ~25 s per megapixel; default 720×1280 (sizes are multiples of 16)", isDefault: true),
        GeneratorModel("wan2.2-i2v-14b-lightning", .video, "Wan 2.2 I2V 14B Q6_K + lightx2v 4 steps, from a start frame (refs[0]); 1–5 s at 464×832, 32 fps, ~5 min per 3 s", isDefault: true),
        GeneratorModel("ace-step-1.5-turbo", .music, "ACE-Step 1.5 turbo text-to-music, instrumental FLAC 48 kHz; options.bpm (default 100); ~70 s", isDefault: true),
        GeneratorModel("realesrgan-x4plus+rife-4.26", .upscale, "Real-ESRGAN x4plus + RIFE to 1080×1920 at 30 fps (generate.upscale); ~4 min per 3 s clip", isDefault: true),
    ]

    var comfyGen: URL { config.url(config.comfyGen) }
    var comfyRun: URL { config.url(config.comfyRun) }

    public func unavailableReason(_ kind: GenerationKind) -> String? {
        let fm = FileManager.default
        switch kind {
        case .image, .video:
            return fm.isExecutableFile(atPath: comfyGen.path) ? nil : "comfy-gen not found at \(comfyGen.path): ComfyUI is not set up on this Mac (Pro tier, set up by hand). Steps:\n\(ComfyCheck.setupSteps)"
        case .music, .upscale:
            if !fm.fileExists(atPath: comfyRun.path) { return "comfy_run.py not found at \(comfyRun.path): set comfyRun in engines.json to the runner of the ComfyUI setup (Pro tier, set up by hand). Steps:\n\(ComfyCheck.setupSteps)" }
            return fm.isExecutableFile(atPath: config.url(config.python3).path) ? nil : "python3 not found at \(config.python3)"
        case .voice:
            return "ComfyUI makes no voice-over: use the voxcpm provider"
        }
    }

    public func estimate(_ request: GenerationRequest) throws -> Double { 0 }

    static func size(_ r: GenerationRequest, default d: (Int, Int)) throws -> String {
        let w = r.width ?? d.0, h = r.height ?? d.1
        guard w > 0, h > 0, w % 16 == 0, h % 16 == 0 else { throw CommandError.invalid("ComfyUI sizes must be multiples of 16 (got \(w)×\(h))") }
        return "\(w)x\(h)"
    }

    public func process(_ r: GenerationRequest, job: URL) throws -> GenerationProcess {
        let seed = String(r.seed ?? GenerationRequest.defaultSeed(r.prompt))
        let python = config.url(config.python3)
        switch r.kind {
        case .image:
            return GenerationProcess(comfyGen, ["image", "--prompt", r.prompt, "--size", try Self.size(r, default: (720, 1280)), "--seed", seed])
        case .video:
            guard let start = r.refs.first else {
                throw CommandError.invalid("ComfyUI video is image-to-video: generate the start frame first (kind image, same 9:16 aspect) and pass it in refs")
            }
            let seconds = min(max(Int((r.duration ?? 3).rounded()), 1), 5)
            return GenerationProcess(comfyGen, ["video", "--image", start, "--prompt", r.prompt, "--seconds", String(seconds),
                                                "--size", try Self.size(r, default: (464, 832)), "--seed", seed])
        case .music:
            let seconds = r.duration ?? 45
            return GenerationProcess(python, ["-I", comfyRun.path, "music", "--prompt", r.prompt, "--seconds", String(format: "%.1f", seconds),
                                              "--bpm", r.options?["bpm"] ?? "100", "--seed", seed, "--out", job.path])
        case .upscale:
            guard let clip = r.refs.first else { throw CommandError.invalid("upscale needs the clip (refs[0])") }
            return GenerationProcess(python, ["-I", comfyRun.path, "upscale", clip, "--out", job.path])
        case .voice:
            throw CommandError.invalid("ComfyUI makes no voice-over: use the voxcpm provider")
        }
    }

    public func collect(_ r: GenerationRequest, job: URL, stdout: String) throws -> GenerationOutput {
        guard let json = Generation.lastJSON(stdout), let file = json["files"]?.arrayValue?.first?.stringValue else {
            throw CommandError(.io, "ComfyUI printed no result file")
        }
        let src = URL(fileURLWithPath: file)
        let dest = job.appendingPathComponent("result.\(src.pathExtension.lowercased())")
        if src.standardizedFileURL.path != dest.path {
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: src, to: dest) }
            catch { throw CommandError(.io, "cannot copy \(file): \(error.localizedDescription)") }
        }
        return GenerationOutput(file: dest.path, model: json["model"]?.stringValue.map { m in m.contains("z-image") ? "z-image-turbo" : m } ?? model(for: r),
                                seed: json["seed"]?.doubleValue.map { Int($0) } ?? (r.kind == .upscale ? nil : r.seed ?? GenerationRequest.defaultSeed(r.prompt)),
                                remoteID: nil, seconds: json["seconds_taken"]?.doubleValue ?? json["wall_seconds"]?.doubleValue)
    }

    public func finish(keepRunning: Bool) {
        guard !keepRunning, FileManager.default.isExecutableFile(atPath: comfyGen.path) else { return }
        _ = try? Subprocess.run(comfyGen, ["stop"])
    }
}

/// Higgsfield through its CLI (`higgsfield generate cost|create`). Paid: every run needs a human approval of its
/// estimate and draws on the hard budget (GenerationBudget, 2 calls in total).
public struct HiggsfieldProvider: GeneratorProvider {
    public let config: EngineConfig
    public init(config: EngineConfig) { self.config = config }

    public let id = "higgsfield"
    public let title = "Higgsfield (paid, approval + hard budget)"
    public let paid = true
    public var minimumTier: MachineTier { EngineManifest.shared.minimumTier(id) }
    public let models = [
        GeneratorModel("z_image", .image, "Z Image: fast and cheap still (0.15 credits at 9:16)", isDefault: true),
        GeneratorModel("gpt_image_2", .image, "GPT Image 2: high-fidelity stills, text on image"),
        GeneratorModel("seedance1_5", .video, "Seedance 1.5 Pro: clean single shot; options resolution 480p|720p|1080p, generate_audio false; 4/8/12 s (480p 4 s ≈ 2.4 credits)", isDefault: true),
        GeneratorModel("seedance_2_0", .video, "Seedance 2.0: the hero-quality shot (multi-shot, motion, up to 4K)"),
        GeneratorModel("kling3_0_turbo", .video, "Kling 3.0 Turbo: cheaper single-plane scene (720p 5 s ≈ 7.5 credits)"),
    ]

    /// The CLI: the config, then PATH, fnm's default alias, ~/.local/bin, Homebrew.
    var binary: URL? {
        let fm = FileManager.default
        if let c = config.higgsfield { return fm.isExecutableFile(atPath: EngineConfig.expand(c)) ? config.url(c) : nil }
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/higgsfield" }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/.local/share/fnm/aliases/default/bin/higgsfield", "\(home)/.local/bin/higgsfield",
                       "/opt/homebrew/bin/higgsfield", "/usr/local/bin/higgsfield"]
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// The CLI is a Node script (`#!/usr/bin/env node`): node sits next to it.
    var environment: [String: String] {
        guard let b = binary else { return [:] }
        return ["PATH": b.deletingLastPathComponent().path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")]
    }

    public func unavailableReason(_ kind: GenerationKind) -> String? {
        guard binary != nil else { return "higgsfield CLI not found (npm i -g @higgsfield/cli, then `higgsfield auth login`)" }
        switch kind {
        case .image, .video: return nil
        case .music, .upscale: return "Higgsfield is used here for stills and clips only: music and upscale run on ComfyUI"
        case .voice: return "Higgsfield is used here for stills and clips only: voice-over runs on voxcpm"
        }
    }

    func arguments(_ r: GenerationRequest) -> [String] {
        var a = [model(for: r), "--prompt", r.prompt]   // Higgsfield models take no seed
        var opts = r.options ?? [:]
        let aspect = opts.removeValue(forKey: "aspect_ratio") ?? {
            guard let w = r.width, let h = r.height else { return "9:16" }
            return w == h ? "1:1" : w < h ? "9:16" : "16:9"
        }()
        a += ["--aspect_ratio", aspect]
        if r.kind == .video {
            if let start = r.refs.first { a += ["--start-image", start] }
            if let d = r.duration { a += ["--duration", String(Int(d.rounded()))] }
        } else {
            for ref in r.refs { a += ["--image", ref] }
        }
        for k in opts.keys.sorted() { a += ["--\(k)", opts[k]!] }
        return a
    }

    func run(_ args: [String]) throws -> Subprocess.Result {
        guard let b = binary else { throw CommandError(.io, unavailableReason(.image)!) }
        return try Subprocess.run(b, args, environment: environment)
    }

    static func authHint(_ text: String) -> String? {
        let t = text.lowercased()
        if t.contains("not authenticated") || t.contains("session expired") || t.contains("auth login") {
            return "Higgsfield is not logged in: the human runs `higgsfield auth login` (Regista never logs in by itself)"
        }
        return nil
    }

    public func estimate(_ r: GenerationRequest) throws -> Double {
        let res = try run(["generate", "cost"] + arguments(r) + ["--json"])
        let all = res.stdoutText + res.stderrText
        if let hint = Self.authHint(all) { throw CommandError(.io, hint) }
        guard res.status == 0, let credits = Generation.lastJSON(res.stdoutText)?["credits"]?.doubleValue else {
            throw CommandError(.io, "higgsfield generate cost failed (exit \(res.status)): \(all.split(separator: "\n").suffix(6).joined(separator: "\n"))")
        }
        return credits
    }

    public func process(_ r: GenerationRequest, job: URL) throws -> GenerationProcess {
        guard let b = binary else { throw CommandError(.io, unavailableReason(.image)!) }
        return GenerationProcess(b, ["generate", "create"] + arguments(r) + ["--wait", "--wait-timeout", "20m", "--json"], environment: environment)
    }

    /// The finished job object(s) printed by `create --wait --json`: the first completed one with a result URL.
    static func result(_ json: JSONValue) -> (url: String, id: String?, seed: Int?)? {
        let items = json.arrayValue ?? json["jobs"]?.arrayValue ?? [json]
        for item in items {
            if let s = item["status"]?.stringValue, s != "completed" { continue }
            let url = item["result_url"]?.stringValue ?? item.value(at: "result.url")?.stringValue
                ?? item["results"]?.arrayValue?.first?["url"]?.stringValue ?? item["url"]?.stringValue
            if let url { return (url, item["id"]?.stringValue, item.value(at: "params.seed")?.doubleValue.map { Int($0) }) }
        }
        return nil
    }

    public func collect(_ r: GenerationRequest, job: URL, stdout: String) throws -> GenerationOutput {
        if let hint = Self.authHint(stdout) { throw CommandError(.io, hint) }
        guard let json = Generation.lastJSON(stdout), let found = Self.result(json) else {
            throw CommandError(.io, "higgsfield printed no completed job with a result URL (see \(job.appendingPathComponent("stdout.txt").path))")
        }
        var ext = URL(string: found.url)?.pathExtension.lowercased() ?? ""
        if ext.isEmpty { ext = r.kind == .video ? "mp4" : "png" }
        let dest = job.appendingPathComponent("result.\(ext)")
        try Subprocess.check(URL(fileURLWithPath: "/usr/bin/curl"), ["-fsSL", "--retry", "3", "-o", dest.path, found.url])
        return GenerationOutput(file: dest.path, model: model(for: r), seed: found.seed, remoteID: found.id, seconds: nil)
    }
}
