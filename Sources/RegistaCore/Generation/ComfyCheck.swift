import Foundation

/// generate.check (#36): before a ComfyUI job, the workflow a model runs (shipped in the app, #6) is checked against the
/// running server's `/object_info`, and every missing node pack, model file or renamed value is listed in plain words with
/// the folder it goes in. The check never starts ComfyUI: with the server off it says where Regista would start it from
/// (or that it knows of none) and that the rest was not checked.
public enum ComfyCheck {
    /// One thing a workflow needs that this ComfyUI does not have.
    public struct Missing: Equatable, Sendable {
        /// "node" (class not registered), "model" (a model file ComfyUI does not see), "value" (any other combo value it
        /// does not accept), "server" (no server answers and Regista knows none to start).
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
        /// Every model file the workflow loads and whether the running ComfyUI sees it (empty when it is off).
        public var files: [FileState] = []

        public var json: JSONValue {
            var o: [String: JSONValue] = ["model": .string(model), "state": .string(state)]
            if !missing.isEmpty { o["missing"] = .array(missing.map(\.json)) }
            if let reason { o["reason"] = .string(reason) }
            if !files.isEmpty { o["files"] = .array(files.map(\.json)) }
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

    /// A value Regista fills per request into a workflow input.
    public enum Value: Sendable {
        case prompt, width, height, seed, bpm, seconds, startImage, inputClip
        /// Wan's frame count for the seconds asked: 16 frames a second plus the first one.
        case frames
    }

    /// One shipped workflow (#6): the model it runs, its API-format graph compiled into the app
    /// (`Generation/Workflows/<model>.json`), the node whose outputs are the result, and what Regista fills per request
    /// (node id, input name, value).
    public struct Workflow: Sendable {
        public let model: String
        /// The manifest entry that lists its model files (Settings › Motori's row).
        public let engine: String
        public let kind: GenerationKind
        let bytes: [UInt8]
        public let output: String
        public let fills: [(node: String, input: String, value: Value)]

        public var graph: JSONValue { (try? JSONValue.parse(Data(bytes))) ?? .object([:]) }
    }

    public static let workflows: [Workflow] = [
        Workflow(model: "z-image-turbo", engine: "comfyui-z-image", kind: .image, bytes: PackageResources.z_image_turbo_json, output: "10",
                 fills: [("5", "text", .prompt), ("7", "width", .width), ("7", "height", .height), ("8", "seed", .seed)]),
        Workflow(model: "wan2.2-i2v-14b-lightning", engine: "comfyui-wan22", kind: .video, bytes: PackageResources.wan2_2_i2v_14b_lightning_json, output: "17",
                 fills: [("9", "text", .prompt), ("11", "image", .startImage), ("12", "width", .width), ("12", "height", .height),
                         ("12", "length", .frames), ("13", "noise_seed", .seed)]),
        Workflow(model: "ace-step-1.5-turbo", engine: "comfyui-ace-step", kind: .music, bytes: PackageResources.ace_step_1_5_turbo_json, output: "SAVE",
                 fills: [("PROMPT", "tags", .prompt), ("PROMPT", "seed", .seed), ("PROMPT", "bpm", .bpm), ("PROMPT", "duration", .seconds),
                         ("LATENT", "seconds", .seconds), ("SAMPLER", "seed", .seed)]),
        Workflow(model: "realesrgan-x4plus+rife-4.26", engine: "comfyui-upscale", kind: .upscale, bytes: PackageResources.realesrgan_x4plus_rife_4_26_json, output: "12",
                 fills: [("1", "file", .inputClip)]),
    ]
    public static var models: [String] { workflows.map(\.model) }

    /// A model file of the manifest and whether the running ComfyUI sees it.
    public struct FileState: Equatable, Sendable {
        public let file: EngineManifest.ModelFile
        public let present: Bool

        public var json: JSONValue {
            ["name": .string(file.name), "folder": .string("models/\(file.folder)"), "size": .string(file.sizeText), "bytes": .number(Double(file.bytes)),
             "licence": .string(file.licence), "url": .string(file.url), "present": .bool(present)]
        }
    }

    /// The model files of a manifest entry (comfyui-z-image…) and whether `objectInfo` offers each to the loader that
    /// reads it in the shipped workflows.
    public static func files(engine: String, objectInfo info: JSONValue) -> [FileState] {
        let files = EngineManifest.shared.entry(engine)?.modelFiles ?? []
        return files.map { f in
            var present = false
            for w in workflows {
                for (_, node) in w.graph.objectValue ?? [:] {
                    guard let cls = node["class_type"]?.stringValue else { continue }
                    for (name, v) in node["inputs"]?.objectValue ?? [:] where v.stringValue == f.name {
                        let spec = info[cls]?.value(at: "input.required.\(name)") ?? info[cls]?.value(at: "input.optional.\(name)")
                        if allowed(spec)?.contains(f.name) == true { present = true }
                    }
                }
            }
            return FileState(file: f, present: present)
        }
    }
    public static func workflow(_ model: String) -> Workflow? { workflows.first { $0.model == model } }

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
    /// Inputs Regista sets per request (the start image, the input clip): never checked.
    static let perRequest: Set<String> = ["LoadImage.image", "LoadVideo.file"]

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
                out.append(Missing(kind: "node", node: cls, input: nil, value: nil, folder: nil, hint: nodeHint(cls)))
                continue
            }
            for (name, value) in (node["inputs"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let v = value.stringValue, !perRequest.contains("\(cls).\(name)") else { continue }   // links are arrays
                let spec = info.value(at: "input.required.\(name)") ?? info.value(at: "input.optional.\(name)")
                guard let values = allowed(spec), !values.contains(v) else { continue }
                // A loader's file input (unet_name, clip_name, lora_name, ckpt_name…), not a sampler_name or scheduler.
                let isModel = (folders[cls] != nil || cls.contains("Loader")) && (name.hasSuffix("_name") || name.contains("ckpt") || name.hasPrefix("clip_name"))
                if isModel {
                    out.append(Missing(kind: "model", node: cls, input: name, value: v, folder: folders[cls], hint: modelHint(cls: cls, value: v)))
                } else {
                    out.append(Missing(kind: "value", node: cls, input: name, value: v, folder: nil, hint: valueHint(cls: cls, input: name, value: v)))
                }
            }
        }
        return out
    }

    /// A node class ComfyUI does not have: the pack that provides it (with its URL) when Regista knows it.
    static func nodeHint(_ cls: String) -> String {
        packs[cls].map { "node \(cls) is not in ComfyUI: install the \($0.name) node pack (\($0.url)) in ComfyUI's custom_nodes folder and restart ComfyUI" }
            ?? "node \(cls) is not in ComfyUI: update ComfyUI (the node is part of a newer ComfyUI), or install the node pack that provides it, then restart ComfyUI"
    }

    /// A model file ComfyUI does not see: the folder it goes in and where to get it (the manifest's facts when it lists it).
    static func modelHint(cls: String, value v: String) -> String {
        let folder = folders[cls] ?? "<folder \(cls) reads>"
        if let f = EngineManifest.shared.modelFile(v) {
            let fetch = f.download != nil ? " (generate.fetch {\"file\": \"\(v)\"} downloads it there, after the user agreed to its size)" : ""
            return "model file \(v) is missing: put it in ComfyUI's models/\(f.folder) folder (\(f.sizeText), \(f.licence), from \(f.url))\(fetch), then restart ComfyUI"
        }
        let stem = (v as NSString).deletingPathExtension
        return "model file \(v) is missing: put it in ComfyUI's models/\(folder) folder (find it: https://huggingface.co/models?search=\(stem.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? stem)), then restart ComfyUI"
    }

    static func valueHint(cls: String, input: String, value: String) -> String {
        "\(cls) does not accept \(input) \"\(value)\" (a newer or older ComfyUI than Regista's workflows): update ComfyUI, then check again"
    }

    // MARK: running it

    /// The setup steps of the manifest, numbered (the guided steps the reply and Settings › Motori show).
    public static var setupSteps: String {
        (EngineManifest.shared.entry("comfyui")?.install.steps ?? []).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// `GET /object_info` of the server at `base`, nil when it does not answer within `timeout` seconds.
    public static func fetchObjectInfo(_ base: URL = URL(string: ComfyServer.defaultAddress)!, timeout: TimeInterval = 3) -> Data? {
        ComfyClient(base: base).objectInfo(timeout: timeout)
    }

    /// Checks one model (or all four) against `objectInfo` (nil = the server is off: nothing is checked, and the reason
    /// says where Regista would start it from, or that it does not know).
    public static func run(model: String? = nil, location: ComfyServer.Location, objectInfo: Data?) -> [Result] {
        let info = objectInfo.flatMap { try? JSONValue.parse($0) }
        let results = workflows.filter { model == nil || $0.model == model }.map { w -> Result in
            guard let info else {
                if location.start == nil {
                    return Result(model: w.model, state: "missing", missing: [Missing(kind: "server", node: "ComfyUI", input: nil, value: nil, folder: nil,
                                                                                      hint: ComfyServer.notRunning(location))], reason: nil)
                }
                let from = location.configured ? "the ComfyUI set in Regista" : "the ComfyUI found"
                return Result(model: w.model, state: "notChecked", missing: [],
                              reason: "ComfyUI is off (nothing answers at \(location.server.absoluteString)): its node packs and model files are checked when it runs; Regista starts \(from) (\(location.start!.path)) at the next generation")
            }
            let missing = check(workflow: w.graph, objectInfo: info)
            return Result(model: w.model, state: missing.isEmpty ? "ready" : "missing", missing: missing, reason: nil,
                          files: files(engine: w.engine, objectInfo: info))
        }
        last.withLock { cache in for r in results { cache[r.model] = r } }
        return results
    }

    /// The last result per model in this process (generate.providers shows it without calling the server).
    public static func lastResult(_ model: String) -> Result? { last.withLock { $0[model] } }
    private static let last = LockedValue<[String: Result]>([:])

    /// generate.run's fail-fast: a model whose check finds a missing node or model file throws the list, before anything
    /// is queued. A server that is off does not block (Regista starts it; ComfyUI then validates the workflow itself).
    static func gate(model: String, location: ComfyServer.Location, command: String, fetch: () -> Data?) throws {
        guard workflow(model) != nil, let info = fetch() else { return }
        guard let r = run(model: model, location: location, objectInfo: info).first, r.state == "missing" else { return }
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
