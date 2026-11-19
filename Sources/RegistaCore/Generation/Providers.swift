import Foundation

// The two real providers: local ComfyUI (free, Pro tier) over its HTTP API, run in this process, and Higgsfield (paid,
// hard budget), a CLI run as a separate process in the job folder.

/// Local ComfyUI, driven over its own HTTP API (#6): Z-Image Turbo stills, Wan 2.2 14B lightning image-to-video,
/// ACE-Step 1.5 music, Real-ESRGAN x4plus + RIFE 4.26 upscale to 1080×1920 at 30 fps. The workflows ship in the app
/// (`ComfyCheck.workflows`). Free and unlimited, but heavy (sizes in scripts/engines.manifest.json): Pro tier only. A
/// server Regista started is stopped after each waited-for run unless the caller chains more jobs (`keepRunning`).
public struct ComfyUIProvider: GeneratorProvider {
    public let config: EngineConfig
    /// Where a ComfyUI folder is looked for when `comfyStart` is not set (the tests' rig: none).
    public var places: [String]
    /// Seconds a server Regista starts has to answer, and between two looks at a running prompt.
    var startTimeout: TimeInterval = 300
    var poll: TimeInterval = 1

    public init(config: EngineConfig, places: [String] = ComfyServer.usualPlaces) {
        self.config = config
        self.places = places
    }

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

    /// The server, and what Regista would start when it does not answer.
    public var location: ComfyServer.Location { ComfyServer.locate(config, places: places) }

    public func unavailableReason(_ kind: GenerationKind) -> String? {
        if kind == .voice { return "ComfyUI makes no voice-over: use the voxcpm provider" }
        let loc = location
        if loc.start != nil || ComfyClient(base: loc.server).answers(timeout: 1) { return nil }
        return ComfyServer.notRunning(loc)
    }

    public func estimate(_ request: GenerationRequest) throws -> Double { 0 }

    /// From the model notes: stills ~25 s per megapixel (plus loading), clips ~100 s per second of clip, music ~70 s for a
    /// 45 s bed, upscale ~80 s per second of clip.
    public func seconds(_ r: GenerationRequest, sourceSeconds: Double?) -> Double? {
        switch r.kind {
        case .image: return 10 + 25 * Double((r.width ?? 720) * (r.height ?? 1280)) / 1_000_000
        case .video: return 100 * Double(Self.clipSeconds(r))
        case .music: return 30 + 0.9 * (r.duration ?? 45)
        case .upscale: return sourceSeconds.map { 80 * max($0, 1) }
        case .voice: return nil
        }
    }

    /// Sizes in multiples of 16, about one megapixel for a still and the Wan 2.2 size for a clip.
    public func formats(_ kind: GenerationKind) -> [GenerationFormat] {
        switch kind {
        case .image: return [.init("9:16", 720, 1280), .init("4:5", 832, 1040), .init("1:1", 1024, 1024), .init("16:9", 1280, 720)]
        case .video: return [.init("9:16", 464, 832), .init("4:5", 576, 720), .init("1:1", 624, 624), .init("16:9", 832, 464)]
        default: return []
        }
    }

    static func size(_ r: GenerationRequest, default d: (Int, Int)) throws -> (Int, Int) {
        let w = r.width ?? d.0, h = r.height ?? d.1
        guard w > 0, h > 0, w % 16 == 0, h % 16 == 0 else { throw CommandError.invalid("ComfyUI sizes must be multiples of 16 (got \(w)×\(h))") }
        return (w, h)
    }

    static func clipSeconds(_ r: GenerationRequest) -> Int { min(max(Int((r.duration ?? 3).rounded()), 1), 5) }

    /// The shipped workflow with this request's values in its inputs (by node id and input name), and the files to upload
    /// (input name → local file) for the start image or the clip.
    func workflow(_ r: GenerationRequest) throws -> (ComfyCheck.Workflow, JSONValue, uploads: [(node: String, input: String, file: String)]) {
        let model = model(for: r)
        guard let w = ComfyCheck.workflow(model) else { throw CommandError.invalid("ComfyUI has no model \(model) (generate.providers lists them)") }
        let seed = r.seed ?? GenerationRequest.defaultSeed(r.prompt)
        var size = (0, 0)
        switch r.kind {
        case .image: size = try Self.size(r, default: (720, 1280))
        case .video:
            guard r.refs.first != nil else {
                throw CommandError.invalid("ComfyUI video is image-to-video: generate the start frame first (kind image, same 9:16 aspect) and pass it in refs")
            }
            size = try Self.size(r, default: (464, 832))
        case .upscale: guard r.refs.first != nil else { throw CommandError.invalid("upscale needs the clip (refs[0])") }
        case .music: break
        case .voice: throw CommandError.invalid("ComfyUI makes no voice-over: use the voxcpm provider")
        }
        var graph = w.graph.objectValue ?? [:]
        var uploads: [(String, String, String)] = []
        for f in w.fills {
            let value: JSONValue
            switch f.value {
            case .prompt: value = .string(r.prompt)
            case .width: value = .number(Double(size.0))
            case .height: value = .number(Double(size.1))
            case .seed: value = .number(Double(seed))
            case .bpm: value = .number(Double(Int(r.options?["bpm"] ?? "") ?? 100))
            case .seconds: value = .number(r.duration ?? 45)
            case .frames: value = .number(Double(Self.clipSeconds(r) * 16 + 1))
            case .startImage, .inputClip: uploads.append((f.node, f.input, r.refs[0])); continue
            }
            guard var node = graph[f.node]?.objectValue, var inputs = node["inputs"]?.objectValue else {
                throw CommandError(.io, "the shipped workflow of \(model) has no node \(f.node) with inputs")
            }
            inputs[f.input] = value
            node["inputs"] = .object(inputs)
            graph[f.node] = .object(node)
        }
        return (w, .object(graph), uploads)
    }

    public func process(_ r: GenerationRequest, job: URL) throws -> GenerationProcess {
        let (w, prepared, uploads) = try workflow(r)
        let seed: Int? = r.kind == .upscale ? nil : r.seed ?? GenerationRequest.defaultSeed(r.prompt)
        let (config, places, startTimeout, poll) = (config, places, startTimeout, poll)
        let timeout: TimeInterval = [.image: 15, .video: 45, .music: 15, .upscale: 60][r.kind, default: 30] * 60
        return GenerationProcess(name: "ComfyUI") { job, cancellation in
            let began = Date()
            let client = try ComfyServer.ensure(config, places: places, timeout: startTimeout, cancellation: cancellation)
            var graph = prepared.objectValue ?? [:]
            for u in uploads {
                let file = URL(fileURLWithPath: u.file)
                let name = "\(try FileDigest.sha256(file).prefix(16)).\(file.pathExtension.lowercased())"
                let value = try client.upload(file, as: name, subfolder: "regista")
                var node = graph[u.node]?.objectValue ?? [:]
                var inputs = node["inputs"]?.objectValue ?? [:]
                inputs[u.input] = .string(value)
                node["inputs"] = .object(inputs)
                graph[u.node] = .object(node)
            }
            let promptID = UUID().uuidString.lowercased()
            try promptID.write(to: job.appendingPathComponent("comfyui-prompt"), atomically: true, encoding: .utf8)
            func cancelled() -> Bool { cancellation?.isCancelled == true || CommandJob.current?.isCancelled == true }
            if cancelled() { throw CommandError(.io, "cancelled") }
            try client.queue(.object(graph), promptID: promptID)
            var entry: JSONValue?, misses = 0
            while entry == nil {
                if cancelled() { client.cancel(promptID); throw CommandError(.io, "cancelled") }
                if Date().timeIntervalSince(began) > timeout {
                    client.cancel(promptID)
                    throw CommandError(.io, "ComfyUI did not finish \(w.model) within \(Int(timeout / 60)) min: Regista interrupted it")
                }
                do { entry = try client.history(promptID); misses = 0 } catch {
                    misses += 1   // a busy server can miss a beat; one that stays silent is gone
                    if misses >= 10 { throw CommandError(.io, "ComfyUI stopped answering while it ran \(w.model): \((error as? CommandError)?.message ?? "\(error)")") }
                }
                if entry == nil { Thread.sleep(forTimeInterval: poll) }
            }
            guard entry!.value(at: "status.status_str")?.stringValue == "success" else { throw CommandError(.io, ComfyErrors.execution(entry!)) }
            let files = (entry!.value(at: "outputs.\(w.output)")?.objectValue ?? [:]).values.flatMap { $0.arrayValue ?? [] }
                .filter { $0["filename"]?.stringValue != nil && ($0["type"]?.stringValue ?? "output") == "output" }
            guard let f = files.first, let filename = f["filename"]?.stringValue else {
                throw CommandError(.io, "ComfyUI finished \(w.model) without an output file (node \(w.output))")
            }
            let dest = job.appendingPathComponent("result.\((filename as NSString).pathExtension.lowercased())")
            try client.download(filename: filename, subfolder: f["subfolder"]?.stringValue ?? "", type: "output", to: dest)
            var out: [String: JSONValue] = ["files": [.string(dest.path)], "model": .string(w.model),
                                            "seconds_taken": .number((Date().timeIntervalSince(began) * 10).rounded() / 10)]
            if let seed { out["seed"] = .number(Double(seed)) }
            return JSONValue.object(out).text()
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
        return GenerationOutput(file: dest.path, model: json["model"]?.stringValue ?? model(for: r),
                                seed: json["seed"]?.doubleValue.map { Int($0) } ?? (r.kind == .upscale ? nil : r.seed ?? GenerationRequest.defaultSeed(r.prompt)),
                                remoteID: nil, seconds: json["seconds_taken"]?.doubleValue)
    }

    /// The server Regista started is stopped (its process group); one someone else started only gets `POST /free`.
    public func finish(keepRunning: Bool) {
        guard !keepRunning else { return }
        ComfyServer.finish(config)
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

    /// The aspect ratios `arguments` passes (the size only picks one of them).
    public func formats(_ kind: GenerationKind) -> [GenerationFormat] {
        switch kind {
        case .image, .video: return [.init("9:16", 1080, 1920), .init("1:1", 1080, 1080), .init("16:9", 1920, 1080)]
        default: return []
        }
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
