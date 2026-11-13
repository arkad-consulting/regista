import Foundation

/// generate.check (#36, spec 2026-11-03-openjutsu-ideas part A): before a ComfyUI job, the workflow a model runs is checked
/// against the running server's `/object_info`, and every missing node pack, model file or renamed value is listed in plain
/// words with the folder it goes in. The check never starts ComfyUI: with the server off it checks what it can see (the
/// runner and the workflow files) and says the rest was not checked.
public enum ComfyCheck {
    /// One thing a workflow needs that this ComfyUI does not have.
    public struct Missing: Equatable, Sendable {
        /// "node" (class not registered), "model" (a model file ComfyUI does not see), "value" (any other combo value it
        /// does not accept), "file" (the runner or the workflow file itself).
        public let kind: String
        public let node: String
        public let input: String?
        public let value: String?
        /// The ComfyUI models folder a missing model file goes in, when known.
        public let folder: String?
        public let hint: String

        var json: JSONValue {
            var o: [String: JSONValue] = ["kind": .string(kind), "node": .string(node), "hint": .string(hint)]
            if let input { o["input"] = .string(input) }
            if let value { o["value"] = .string(value) }
            if let folder { o["folder"] = .string(folder) }
            return .object(o)
        }
    }

    public struct Result: Equatable, Sendable {
        public let model: String
        /// "ready", "missing" or "notChecked".
        public let state: String
        public let missing: [Missing]
        public let reason: String?

        public var json: JSONValue {
            var o: [String: JSONValue] = ["model": .string(model), "state": .string(state)]
            if !missing.isEmpty { o["missing"] = .array(missing.map(\.json)) }
            if let reason { o["reason"] = .string(reason) }
            return .object(o)
        }

        /// The reply a person reads: what is missing and how to fix it, one line each.
        public var summary: String {
            switch state {
            case "ready": return "\(model): ready"
            case "notChecked": return "\(model): not checked — \(reason ?? "")"
            default: return "\(model) cannot run, ComfyUI is missing:\n" + missing.map { "- \($0.hint)" }.joined(separator: "\n")
            }
        }
    }

    enum Runner { case comfyGen, comfyRun }

    /// The workflow each ComfyUI model runs, next to its runner (`<runner dir>/workflows/<file>`).
    static let workflows: [(model: String, runner: Runner, file: String)] = [
        ("z-image-turbo", .comfyGen, "zimage-turbo.json"),
        ("wan2.2-i2v-14b-lightning", .comfyGen, "wan22-i2v-14b-lightning.json"),
        ("ace-step-1.5-turbo", .comfyRun, "ace-step-1.5-music.json"),
        ("realesrgan-x4plus+rife-4.26", .comfyRun, "esrgan-rife-30fps.json"),
    ]
    public static var models: [String] { workflows.map(\.model) }

    /// The ComfyUI models folder each loader reads.
    static let folders: [String: String] = [
        "UNETLoader": "diffusion_models", "UnetLoaderGGUF": "unet", "CheckpointLoaderSimple": "checkpoints",
        "CLIPLoader": "text_encoders", "DualCLIPLoader": "text_encoders", "VAELoader": "vae",
        "LoraLoader": "loras", "LoraLoaderModelOnly": "loras", "UpscaleModelLoader": "upscale_models",
        "FrameInterpolationModelLoader": "frame_interpolation",
    ]
    /// Node classes that come from a pack, not from ComfyUI itself.
    static let packs: [String: (name: String, url: String)] = [
        "UnetLoaderGGUF": ("ComfyUI-GGUF", "https://github.com/city96/ComfyUI-GGUF"),
    ]
    /// Inputs the runner sets per request (the start image, the input clip): never checked.
    static let perRequest: Set<String> = ["LoadImage.image", "LoadVideo.file"]

    /// The server comfy-gen starts (127.0.0.1:8188).
    public static let server = URL(string: "http://127.0.0.1:8188")!

    // MARK: the check

    /// The allowed values of a combo input, in either `/object_info` format (`[[values], {…}]` or `["COMBO", {"options": […]}]`).
    static func allowed(_ spec: JSONValue?) -> [String]? {
        guard let a = spec?.arrayValue, let first = a.first else { return nil }
        if let values = first.arrayValue { return values.compactMap(\.stringValue) }
        if first.stringValue == "COMBO", a.count > 1, let options = a[1]["options"]?.arrayValue { return options.compactMap(\.stringValue) }
        return nil
    }

    /// Every node, model file and combo value of an API-format workflow that `/object_info` does not offer.
    public static func check(workflow: JSONValue, objectInfo: JSONValue) -> [Missing] {
        var out: [Missing] = []
        let nodes = workflow.objectValue ?? [:]
        for key in nodes.keys.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
            guard let node = nodes[key], let cls = node["class_type"]?.stringValue else { continue }
            guard let info = objectInfo[cls] else {
                let pack = packs[cls]
                out.append(Missing(kind: "node", node: cls, input: nil, value: nil, folder: nil,
                                   hint: pack.map { "node \(cls) is not in ComfyUI: install the \($0.name) node pack (\($0.url)) and restart ComfyUI" }
                                       ?? "node \(cls) is not in ComfyUI: install the node pack that provides it (ComfyUI Manager searches by node name) and restart ComfyUI"))
                continue
            }
            for (name, value) in (node["inputs"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let v = value.stringValue, !perRequest.contains("\(cls).\(name)") else { continue }   // links are arrays
                let spec = info.value(at: "input.required.\(name)") ?? info.value(at: "input.optional.\(name)")
                guard let values = allowed(spec), !values.contains(v) else { continue }
                // A loader's file input (unet_name, clip_name, lora_name, ckpt_name…), not a sampler_name or scheduler.
                let isModel = (folders[cls] != nil || cls.contains("Loader")) && (name.hasSuffix("_name") || name.contains("ckpt") || name.hasPrefix("clip_name"))
                if isModel {
                    let folder = folders[cls]
                    let stem = (v as NSString).deletingPathExtension
                    out.append(Missing(kind: "model", node: cls, input: name, value: v, folder: folder,
                                       hint: "model file \(v) is missing: put it in ComfyUI's models/\(folder ?? "<folder \(cls) reads>") folder (find it: https://huggingface.co/models?search=\(stem.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? stem)), then restart ComfyUI"))
                } else {
                    out.append(Missing(kind: "value", node: cls, input: name, value: v, folder: nil,
                                       hint: "\(cls) no longer accepts \(name) \"\(v)\" (a newer or older ComfyUI): update ComfyUI or the comfy-gen setup so they match"))
                }
            }
        }
        return out
    }

    // MARK: running it

    static func runnerURL(_ r: Runner, _ config: EngineConfig) -> URL {
        r == .comfyGen ? config.url(config.comfyGen) : config.url(config.comfyRun)
    }

    /// `<directory of the runner, symlinks resolved>/workflows/<file>`.
    static func workflowURL(_ w: (model: String, runner: Runner, file: String), _ config: EngineConfig) -> URL {
        runnerURL(w.runner, config).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("workflows/\(w.file)")
    }

    /// The setup steps of the manifest, numbered (the guided steps the reply and Settings › Motori show).
    public static var setupSteps: String {
        (EngineManifest.shared.entry("comfyui")?.install.steps ?? []).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// `GET /object_info`, nil when the server does not answer within `timeout` seconds.
    public static func fetchObjectInfo(_ base: URL = server, timeout: TimeInterval = 3) -> Data? {
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: base.appendingPathComponent("object_info"))
        request.timeoutInterval = timeout
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { box.data = data }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut { task.cancel(); return nil }
        return box.data
    }

    /// Checks one model (or all four). `objectInfo` nil = the server is off: only the files are checked.
    public static func run(model: String? = nil, config: EngineConfig, objectInfo: Data?) -> [Result] {
        let info = objectInfo.flatMap { try? JSONValue.parse($0) }
        let results = workflows.filter { model == nil || $0.model == model }.map { w -> Result in
            let fm = FileManager.default
            let runner = runnerURL(w.runner, config)
            var files: [Missing] = []
            if w.runner == .comfyGen, !fm.isExecutableFile(atPath: runner.path) {
                files.append(Missing(kind: "file", node: "comfy-gen", input: nil, value: nil, folder: nil,
                                     hint: "comfy-gen not found at \(runner.path): ComfyUI is not set up on this Mac. Steps:\n\(setupSteps)"))
            } else if w.runner == .comfyRun, !fm.fileExists(atPath: runner.path) {
                files.append(Missing(kind: "file", node: "comfy_run.py", input: nil, value: nil, folder: nil,
                                     hint: "comfy_run.py not found at \(runner.path): set comfyRun in engines.json to the runner of the ComfyUI setup. Steps:\n\(setupSteps)"))
            }
            let wf = workflowURL(w, config)
            let workflow = fm.contents(atPath: wf.path).flatMap { try? JSONValue.parse($0) }
            if files.isEmpty, workflow == nil {
                files.append(Missing(kind: "file", node: w.file, input: nil, value: nil, folder: nil,
                                     hint: "workflow \(wf.path) is missing or unreadable: update the ComfyUI setup (comfy-gen) to a version that has it"))
            }
            if !files.isEmpty { return Result(model: w.model, state: "missing", missing: files, reason: nil) }
            guard let info else {
                return Result(model: w.model, state: "notChecked", missing: [],
                              reason: "ComfyUI is off (nothing answers at \(server.absoluteString)): its node packs and model files are checked when it runs; comfy-gen starts it at the next generation")
            }
            let missing = check(workflow: workflow!, objectInfo: info)
            return Result(model: w.model, state: missing.isEmpty ? "ready" : "missing", missing: missing, reason: nil)
        }
        last.withLock { cache in for r in results { cache[r.model] = r } }
        return results
    }

    /// The last result per model in this process (generate.providers shows it without calling the server).
    public static func lastResult(_ model: String) -> Result? { last.withLock { $0[model] } }
    private static let last = LockedValue<[String: Result]>([:])

    /// generate.run's fail-fast: a model whose check finds something missing throws the list, before anything is queued.
    /// A server that is off does not block (comfy-gen starts it; ComfyUI then validates the workflow itself).
    static func gate(model: String, config: EngineConfig, command: String, fetch: () -> Data? = { fetchObjectInfo() }) throws {
        guard workflows.contains(where: { $0.model == model }) else { return }
        guard let r = run(model: model, config: config, objectInfo: fetch()).first, r.state == "missing" else { return }
        throw CommandError(.io, "\(command): \(r.summary)\nNothing was queued.")
    }
}

/// A value behind a lock.
final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}
